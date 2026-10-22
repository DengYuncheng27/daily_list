from concurrent.futures import ThreadPoolExecutor
from dataclasses import replace
import hashlib
from io import BytesIO
import json
import secrets
from uuid import uuid4

from fastapi.testclient import TestClient
from PIL import Image
import pytest

from dayflow.config import Settings
from dayflow.main import create_app
from dayflow.sync import canonical
from dayflow.backup_bundle import backup_bundle


@pytest.fixture
def settings(tmp_path):
    return Settings(
        database_path=str(tmp_path / "v2.sqlite3"), jwt_secret=secrets.token_hex(32),
        registration_enabled=True, auth_rate_limit=10000, sync_rate_limit=10000,
    )


def account(client, email="a@example.com"):
    response = client.post("/api/v1/auth/register", json={
        "email": email, "name": "Test", "password": "private-test-password",
    })
    assert response.status_code == 201
    return {"Authorization": "Bearer " + response.json()["accessToken"]}


def upload(client, auth, body=b"private text", name="notes.txt", identifier=None):
    return client.post(
        "/api/v1/attachments/" + (identifier or str(uuid4())),
        params={"name": name}, content=body, headers=auth,
    )


def task(payload):
    return {"mutationId": str(uuid4()), "id": str(uuid4()), "kind": "task",
            "baseVersion": 0, "deleted": False, "payload": {"title": "Private", **payload}}


def image_bytes():
    buffer = BytesIO()
    Image.new("RGB", (4, 3), "blue").save(buffer, format="PNG")
    return buffer.getvalue()


def test_file_roundtrip_idempotency_owner_isolation_and_reference_validation(settings):
    with TestClient(create_app(settings)) as client:
        alice, bob = account(client), account(client, "b@example.com")
        identifier = str(uuid4())
        response = upload(client, alice, identifier=identifier)
        assert response.status_code == 201
        item = response.json()
        assert item == {
            "id": identifier, "name": "notes.txt", "mimeType": "application/octet-stream",
            "size": 12, "sha256": hashlib.sha256(b"private text").hexdigest(),
        }
        assert upload(client, alice, identifier=identifier).json() == item
        assert upload(client, alice, b"different", identifier=identifier).status_code == 409
        path = "/api/v1/attachments/" + identifier
        downloaded = client.get(path, headers=alice)
        assert downloaded.content == b"private text"
        assert downloaded.headers["content-type"] == "application/octet-stream"
        assert downloaded.headers["content-disposition"].startswith("attachment;")
        assert downloaded.headers["x-content-type-options"] == "nosniff"
        assert client.get(path).status_code == 401
        assert client.get(path, headers=bob).status_code == 404
        assert upload(client, {}, identifier=str(uuid4())).status_code == 401
        assert client.get("/api/v1/attachments", headers=alice).json()["usedBytes"] == 12
        assert client.get("/api/v1/attachments", headers=bob).json()["usedBytes"] == 0
        valid = task({"attachments": [item]})
        assert client.post("/api/v1/sync", headers=alice, json={"mutations": [valid]}).status_code == 200
        assert client.post("/api/v1/sync", headers=bob, json={"mutations": [task({"attachments": [item]})]}).status_code == 422
        forged = {**item, "sha256": "0" * 64}
        assert client.post("/api/v1/sync", headers=alice, json={"mutations": [task({"attachments": [forged]})]}).status_code == 422
        # Another owner can use the same UUID; disk and metadata remain separate.
        assert upload(client, bob, b"Bob bytes", identifier=identifier).status_code == 201
        assert client.get(path, headers=bob).content == b"Bob bytes"
        assert client.get(path, headers=alice).content == b"private text"


def test_private_image_delta_note_dates_and_rule_roundtrip(settings):
    with TestClient(create_app(settings)) as client:
        auth = account(client)
        body = image_bytes()
        response = upload(client, auth, body, "照片.png")
        assert response.status_code == 201
        item = response.json()
        assert item["mimeType"] == "image/png"
        rich = [
            {"insert": "Important ", "attributes": {"bold": True}},
            {"insert": "link", "attributes": {"link": "https://example.com"}},
            {"insert": "\n"},
            {"insert": {"image": "attachment:" + item["id"]}},
            {"insert": "\n"},
        ]
        payload = {
            "itemType": "note", "richContent": rich, "attachments": [item],
            "dueDate": "2026-10-20", "dueTime": "09:00",
            "endDate": "2026-10-22", "endTime": "17:00",
            "recurrenceRule": {"frequency": "dates", "dates": ["2026-10-20", "2026-11-02"]},
        }
        response = client.post("/api/v1/sync", headers=auth, json={"mutations": [task(payload)]})
        assert response.status_code == 200, response.text
        saved = response.json()["accepted"][0]["entity"]["payload"]
        for key in payload:
            if key != "recurrenceRule":
                assert saved[key] == payload[key]
        assert saved["recurrenceRule"]["dates"] == payload["recurrenceRule"]["dates"]
        assert saved["recurrenceRule"]["reviewDays"] == [1, 2, 4, 7, 15]
        path = "/api/v1/attachments/" + item["id"]
        assert client.get(path, headers=auth).content == body
        assert client.get(path, headers=auth).headers["content-disposition"].startswith("attachment;")


@pytest.mark.parametrize("name,body,status", [
    ("../escape.txt", b"abc", 422), ("bad\\path.txt", b"abc", 422),
    ("newline\n.txt", b"abc", 422), ("CON.txt", b"abc", 422),
    ("bad.svg", b"<svg/>", 415), ("page.html", b"<html/>", 415),
    ("app.exe", b"MZexec", 415), ("fake.png", b"not png", 415),
    ("fake.pdf", b"not PDF", 415), ("bad.txt", b"\xff\x00", 415),
    ("empty.txt", b"", 422), ("bad.json", b"{", 415),
])
def test_unsafe_names_types_and_contents_are_rejected(settings, name, body, status):
    with TestClient(create_app(settings)) as client:
        auth = account(client)
        assert upload(client, auth, body, name).status_code == status
        assert client.get("/api/v1/attachments", headers=auth).json()["usedBytes"] == 0
        assert not list(client.app.state.attachments.root.rglob("*.blob"))
        assert not list((client.app.state.attachments.root / ".staging").iterdir())


@pytest.mark.parametrize("name,body", [
    ("report.docx", b"PK\x03\x04document"), ("sheet.xlsx", b"PK\x03\x04sheet"),
    ("slides.pptx", b"PK\x03\x04slides"), ("archive.zip", b"PK\x05\x06archive"),
    ("recording.mp3", b"ID3recording"), ("recording.wav", b"RIFF1234WAVEbytes"),
    ("document.pdf", b"%PDF-1.7\ncontent"), ("notes.md", "文字".encode()),
])
def test_common_download_types_are_opaque_attachments(settings, name, body):
    with TestClient(create_app(settings)) as client:
        auth = account(client)
        response = upload(client, auth, body, name)
        assert response.status_code == 201
        item = response.json()
        assert item["mimeType"] == "application/octet-stream"
        downloaded = client.get("/api/v1/attachments/" + item["id"], headers=auth)
        assert downloaded.content == body
        assert downloaded.headers["content-disposition"].startswith("attachment;")


def test_file_size_boundary_and_quota_are_atomic(settings):
    with TestClient(create_app(replace(settings, attachment_max_bytes=10, attachment_quota_bytes=20))) as client:
        auth = account(client)
        assert upload(client, auth, b"a" * 11).status_code == 413
        assert upload(client, auth, b"a" * 10).status_code == 201
        with ThreadPoolExecutor(max_workers=2) as pool:
            statuses = list(pool.map(lambda _: upload(client, auth, b"b" * 10).status_code, range(2)))
        assert sorted(statuses) == [201, 413]
        assert client.get("/api/v1/attachments", headers=auth).json()["usedBytes"] == 20
        assert sum(path.stat().st_size for path in client.app.state.attachments.root.rglob("*.blob")) == 20
        assert not list((client.app.state.attachments.root / ".staging").iterdir())
        streamed = client.post(
            "/api/v1/attachments/" + str(uuid4()), params={"name": "streamed.txt"},
            content=iter([b"x" * 6, b"x" * 6]), headers=auth,
        )
        assert streamed.status_code == 413


@pytest.mark.parametrize("payload", [
    {"richContent": [{"insert": {"image": "https://external.example/image.png"}}]},
    {"richContent": [{"insert": "click", "attributes": {"link": "javascript:alert(1)"}}]},
    {"richContent": [{"insert": {"video": "file:///private"}}]},
    {"richContent": [{"delete": 1}]},
    {"richContent": [{"insert": "text", "attributes": {"unknown": {"script": "x"}}}]},
    {"richContent": [{"insert": {"image": "attachment:" + str(uuid4())}}]},
    {"endDate": "2026-10-20"},
    {"dueDate": "2026-10-20", "endDate": "2026-10-19"},
    {"recurrenceRule": {"frequency": "dates", "dates": ["2026-02-30"]}},
])
def test_invalid_v2_content_fails_before_sync_writes(settings, payload):
    with TestClient(create_app(settings)) as client:
        auth = account(client)
        assert client.post("/api/v1/sync", headers=auth, json={"mutations": [task(payload)]}).status_code == 422
        assert client.post("/api/v1/sync", headers=auth, json={"mutations": []}).json()["changes"] == []


def test_v1_database_migration_keeps_existing_history_and_receipt_retry(settings):
    application = create_app(settings)
    with TestClient(application) as client:
        auth = account(client)
        mutation = task({"notes": "Pre-upgrade task"})
        result = client.post("/api/v1/sync", headers=auth, json={"mutations": [mutation]}).json()
        legacy = result["accepted"][0]
        v2_fields = ("itemType", "richContent", "attachments", "importData", "endDate", "endTime", "recurrenceRule")
        for key in v2_fields:
            legacy["entity"]["payload"].pop(key)
        normalized = {**mutation, "payload": legacy["entity"]["payload"]}
        old_hash = hashlib.sha256(canonical(normalized).encode()).hexdigest()
        with application.state.database.connection(write=True) as connection:
            connection.execute("UPDATE entities SET payload=?", (canonical(legacy["entity"]["payload"]),))
            connection.execute("UPDATE changes SET entity=?", (canonical(legacy["entity"]),))
            connection.execute("UPDATE mutations SET request_hash=?,result=?", (old_hash, canonical(legacy)))
            connection.execute("DROP TABLE attachments")
            connection.execute("PRAGMA user_version=1")
    with TestClient(create_app(settings)) as restarted:
        retried = restarted.post("/api/v1/sync", headers=auth, json={"mutations": [mutation]})
        assert retried.status_code == 200
        assert retried.json()["accepted"] == [legacy]
        assert retried.json()["cursor"] == 1
        with restarted.app.state.database.connection() as connection:
            assert connection.execute("PRAGMA user_version").fetchone()[0] == 2
            assert connection.execute("SELECT COUNT(*) FROM users").fetchone()[0] == 1
        assert upload(restarted, auth).status_code == 201


def test_backup_bundle_restores_private_files_and_database(settings, tmp_path):
    with TestClient(create_app(settings)) as client:
        auth = account(client)
        item = upload(client, auth, b"backup bytes").json()
        source = client.app.state.database.path
        bundle = tmp_path / "bundle"
        assert backup_bundle(source, bundle) == 1
        assert (bundle / "COMPLETE.json").exists()
        assert not (bundle / "INCOMPLETE").exists()
        with pytest.raises(FileExistsError):
            backup_bundle(source, bundle)
    restored = replace(settings, database_path=str(bundle / "dayflow.sqlite3"))
    with TestClient(create_app(restored)) as client:
        assert client.get("/api/v1/attachments/" + item["id"], headers=auth).content == b"backup bytes"
