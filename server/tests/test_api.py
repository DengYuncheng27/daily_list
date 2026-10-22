from concurrent.futures import ThreadPoolExecutor
from dataclasses import replace
import json
import secrets
import time
from uuid import uuid4

from fastapi.testclient import TestClient
import jwt
import pytest
from uvicorn.middleware.proxy_headers import ProxyHeadersMiddleware

from dayflow.config import Settings
from dayflow.main import create_app
from dayflow.security import ACCESS_SECONDS, REFRESH_SECONDS, token_hash


PASSWORD = "correct horse battery staple"


@pytest.fixture
def settings(tmp_path):
    return Settings(
        database_path=str(tmp_path / "dayflow.sqlite3"),
        jwt_secret=secrets.token_hex(32),
        registration_enabled=True,
        allowed_origins=("https://planner.example.com",),
        auth_rate_limit=10000, sync_rate_limit=10000,
    )


@pytest.fixture
def client(settings):
    with TestClient(create_app(settings)) as client:
        yield client


def register(client, email="alice@example.com"):
    response = client.post("/api/v1/auth/register", json={"email": email, "password": PASSWORD, "name": "Alice"})
    assert response.status_code == 201, response.text
    return response.json()


def headers(auth):
    return {"Authorization": "Bearer " + auth["accessToken"]}


def mutation(*, entity_id=None, mutation_id=None, base=0, deleted=False, title="Example", kind="task", payload=None):
    return {
        "mutationId": mutation_id or str(uuid4()), "kind": kind, "id": entity_id or str(uuid4()),
        "baseVersion": base, "deleted": deleted,
        "payload": payload if payload is not None else ({} if deleted else {"title": title}),
    }


def sync(client, auth, mutations=(), cursor=0):
    response = client.post("/api/v1/sync", headers=headers(auth), json={"cursor": cursor, "mutations": list(mutations)})
    assert response.status_code == 200, response.text
    return response.json()


def test_register_login_hashes_and_claims(client, settings):
    auth = register(client, "ALICE@EXAMPLE.COM")
    assert auth["user"]["email"] == "alice@example.com"
    assert set(auth) == {"accessToken", "refreshToken", "user"}
    me = client.get("/api/v1/auth/me", headers=headers(auth))
    assert me.json() == auth["user"]
    with client.app.state.database.connection() as connection:
        user = connection.execute("SELECT * FROM users").fetchone()
        token = connection.execute("SELECT * FROM refresh_tokens").fetchone()
        assert user["password_hash"].startswith("$argon2id$")
        assert PASSWORD not in user["password_hash"]
        assert token["token_hash"] == token_hash(auth["refreshToken"])
        assert token["expires_at"] - token["created_at"] == REFRESH_SECONDS
        assert auth["refreshToken"] not in json.dumps(dict(token))
    claims = jwt.decode(auth["accessToken"], settings.jwt_secret, algorithms=["HS256"], audience=settings.audience)
    assert claims["exp"] - claims["iat"] == ACCESS_SECONDS
    assert claims["sub"] == auth["user"]["id"]
    assert client.post("/api/v1/auth/login", json={"email": "alice@example.com", "password": PASSWORD}).status_code == 200
    for email in ("alice@example.com", "unknown@example.com"):
        failed = client.post("/api/v1/auth/login", json={"email": email, "password": "not the password"})
        assert failed.status_code == 401
        assert failed.json() == {"detail": "Invalid email or password."}


def test_no_default_users_and_registration_switch(settings):
    with TestClient(create_app(replace(settings, registration_enabled=False))) as client:
        assert client.get("/api/v1/health").json() == {"status": "ok"}
        denied = client.post("/api/v1/auth/register", json={"email": "a@example.com", "password": PASSWORD, "name": "A"})
        assert denied.status_code == 403
        with client.app.state.database.connection() as connection:
            assert connection.execute("SELECT COUNT(*) FROM users").fetchone()[0] == 0


def test_refresh_rotates_and_replay_revokes_family(client):
    auth = register(client)
    rotated_response = client.post("/api/v1/auth/refresh", json={"refreshToken": auth["refreshToken"]})
    assert rotated_response.status_code == 200
    rotated = rotated_response.json()
    assert rotated["refreshToken"] != auth["refreshToken"]
    assert client.get("/api/v1/auth/me", headers=headers(rotated)).status_code == 200
    replay = client.post("/api/v1/auth/refresh", json={"refreshToken": auth["refreshToken"]})
    assert replay.status_code == 401
    assert client.post("/api/v1/auth/refresh", json={"refreshToken": rotated["refreshToken"]}).status_code == 401
    assert client.get("/api/v1/auth/me", headers=headers(rotated)).status_code == 401


def test_logout_is_idempotent_and_access_is_revoked(client):
    auth = register(client)
    other_session = client.post("/api/v1/auth/login", json={"email": "alice@example.com", "password": PASSWORD}).json()
    for _ in range(2):
        assert client.post("/api/v1/auth/logout", json={"refreshToken": auth["refreshToken"]}).json() == {"ok": True}
    assert client.get("/api/v1/auth/me", headers=headers(auth)).status_code == 401
    assert client.post("/api/v1/auth/refresh", json={"refreshToken": auth["refreshToken"]}).status_code == 401
    assert client.get("/api/v1/auth/me", headers=headers(other_session)).status_code == 200
    assert client.post("/api/v1/auth/logout", json={"refreshToken": "x" * 64}).json() == {"ok": True}


def test_expired_refresh_and_invalid_access(client, settings):
    auth = register(client)
    with client.app.state.database.connection(write=True) as connection:
        connection.execute("UPDATE refresh_tokens SET expires_at=?", (int(time.time()) - 1,))
    assert client.post("/api/v1/auth/refresh", json={"refreshToken": auth["refreshToken"]}).status_code == 401
    claims = jwt.decode(auth["accessToken"], settings.jwt_secret, algorithms=["HS256"], audience=settings.audience)
    expired = jwt.encode({**claims, "exp": int(time.time()) - 1}, settings.jwt_secret, algorithm="HS256")
    wrong_audience = jwt.encode({**claims, "aud": "other-service"}, settings.jwt_secret, algorithm="HS256")
    for access in (expired, wrong_audience, "invalid"):
        assert client.get("/api/v1/auth/me", headers={"Authorization": "Bearer " + access}).status_code == 401
    assert client.get("/api/v1/auth/me").status_code == 401
    assert client.post("/api/v1/sync", json={"cursor": 0, "mutations": []}).status_code == 401


def test_account_isolation_including_same_entity_and_mutation_ids(client):
    alice, bob = register(client), register(client, "bob@example.com")
    first = mutation(title="Alice's private task")
    alice_result = sync(client, alice, [first])
    assert sync(client, bob)["changes"] == []
    bob_write = {**first, "payload": {"title": "Bob's independent task"}}
    bob_result = sync(client, bob, [bob_write])
    assert bob_result["accepted"][0]["entity"]["version"] == 1
    assert [item["payload"]["title"] for item in bob_result["changes"]] == ["Bob's independent task"]
    alice_pull = sync(client, alice)
    assert alice_pull["changes"] == alice_result["changes"]
    assert alice_pull["cursor"] > alice_result["cursor"]  # Global sequence may contain other owners.


def test_idempotency_retry_preserves_original_acceptance_without_duplicate_change(client):
    auth = register(client)
    create = mutation()
    first = sync(client, auth, [create])
    second = sync(client, auth, [create], cursor=first["cursor"])
    assert second["accepted"] == first["accepted"]
    assert second["changes"] == []
    update = mutation(entity_id=create["id"], base=1, title="Version two")
    sync(client, auth, [update])
    replay = sync(client, auth, [create])
    assert replay["accepted"] == first["accepted"]
    assert len(replay["changes"]) == 2


def test_mutation_id_content_collision_rolls_back_whole_batch(client):
    auth = register(client)
    original = mutation()
    sync(client, auth, [original])
    rejected = client.post(
        "/api/v1/sync", headers=headers(auth),
        json={"cursor": 0, "mutations": [mutation(), {**original, "payload": {"title": "Changed request"}}]},
    )
    assert rejected.status_code == 409
    assert len(sync(client, auth)["changes"]) == 1


def test_conflict_no_overwrite_and_explicit_resolution(client):
    auth = register(client)
    create = mutation(title="Original")
    sync(client, auth, [create])
    update = mutation(entity_id=create["id"], base=1, title="Server edit")
    sync(client, auth, [update])
    stale = mutation(entity_id=create["id"], base=1, title="Offline edit")
    result = sync(client, auth, [stale])
    assert result["accepted"] == []
    assert result["conflicts"][0]["server"]["version"] == 2
    assert result["conflicts"][0]["server"]["payload"]["title"] == "Server edit"
    assert sync(client, auth, [stale])["conflicts"] == result["conflicts"]
    resolved = sync(client, auth, [mutation(entity_id=create["id"], base=2, title="Chosen local edit")])
    assert resolved["accepted"][0]["entity"]["version"] == 3


def test_unknown_stale_entity_returns_version_zero_tombstone(client):
    result = sync(client, register(client), [mutation(base=10)])
    assert result["accepted"] == []
    assert result["conflicts"][0]["server"]["deleted"]
    assert result["conflicts"][0]["server"]["version"] == 0
    assert result["changes"] == []


def test_tombstone_survives_late_client_and_can_be_explicitly_restored(client):
    auth = register(client)
    create = mutation()
    sync(client, auth, [create])
    tombstone = mutation(entity_id=create["id"], base=1, deleted=True)
    deleted = sync(client, auth, [tombstone])
    entity = deleted["accepted"][0]["entity"]
    assert entity["deleted"] and entity["version"] == 2 and entity["payload"] == {}
    old_create = mutation(entity_id=create["id"])
    conflict = sync(client, auth, [old_create])["conflicts"][0]["server"]
    assert conflict == entity
    assert sync(client, auth)["changes"][-1] == entity
    assert sync(client, auth, [mutation(entity_id=create["id"], base=2)])["accepted"][0]["entity"]["version"] == 3


def test_pagination_501_changes_with_owner_filter_and_high_water(client):
    alice, bob = register(client), register(client, "bob@example.com")
    first = sync(client, alice, [mutation(title=str(index)) for index in range(500)])
    assert len(first["changes"]) == 500 and first["hasMore"] is False
    sync(client, bob, [mutation(title="Never visible to Alice")])
    sync(client, alice, [mutation(title="500")], cursor=first["cursor"])
    page1 = sync(client, alice)
    assert len(page1["changes"]) == 500 and page1["hasMore"] is True
    page2 = sync(client, alice, cursor=page1["cursor"])
    assert len(page2["changes"]) == 1 and page2["hasMore"] is False
    assert page2["changes"][0]["payload"]["title"] == "500"
    assert len({item["id"] for item in page1["changes"] + page2["changes"]}) == 501
    assert sync(client, alice, cursor=page2["cursor"])["changes"] == []


def test_parallel_same_base_version_has_one_winner(client):
    auth = register(client)
    initial = mutation()
    sync(client, auth, [initial])
    updates = [mutation(entity_id=initial["id"], base=1, title=name) for name in ("Edit A", "Edit B")]
    with ThreadPoolExecutor(max_workers=2) as executor:
        responses = list(executor.map(lambda item: sync(client, auth, [item]), updates))
    assert sum(len(item["accepted"]) for item in responses) == 1
    assert sum(len(item["conflicts"]) for item in responses) == 1
    assert len(sync(client, auth)["changes"]) == 2


def test_concurrent_identical_retry_adds_one_change(client):
    auth = register(client)
    create = mutation()
    with ThreadPoolExecutor(max_workers=2) as executor:
        results = list(executor.map(lambda _: sync(client, auth, [create]), range(2)))
    assert results[0]["accepted"] == results[1]["accepted"]
    assert len(sync(client, auth)["changes"]) == 1


def test_data_and_sessions_survive_restart(client, settings):
    auth = register(client)
    created = sync(client, auth, [mutation()])
    with TestClient(create_app(settings)) as restarted:
        assert restarted.get("/api/v1/auth/me", headers=headers(auth)).status_code == 200
        assert sync(restarted, auth)["changes"] == created["changes"]


@pytest.mark.parametrize("payload", [
    {"title": " "}, {"title": "X", "priority": 4}, {"title": "X", "priority": True},
    {"title": "X", "dueDate": "2026-02-30"}, {"title": "X", "dueTime": "24:00"},
    {"title": "X", "completedAt": "2026-01-01T10:00:00"}, {"title": "X", "tags": ["a"] * 21},
    {"title": "X", "owner": "other"}, {"title": "X", "notes": "a" * 20001},
])
def test_invalid_payload_is_rejected_atomically(client, payload):
    auth = register(client)
    response = client.post(
        "/api/v1/sync", headers=headers(auth),
        json={"cursor": 0, "mutations": [mutation(), mutation(payload=payload)]},
    )
    assert response.status_code == 422
    assert isinstance(response.json()["detail"], str)
    assert sync(client, auth)["changes"] == []


def test_list_and_all_task_fields_roundtrip(client):
    auth = register(client)
    list_id = str(uuid4())
    task = {
        "title": "准备方案", "notes": "<script>stored as text</script>", "listId": list_id,
        "dueDate": "2026-10-20", "dueTime": "14:00", "priority": 2, "completed": True,
        "completedAt": "2026-10-20T08:00:00Z", "tags": ["work"],
        "subtasks": [{"id": str(uuid4()), "title": "Outline", "completed": False}],
        "recurrence": "monthly", "reminderMinutes": 10,
    }
    result = sync(client, auth, [
        mutation(kind="list", entity_id=list_id, payload={"name": "工作", "color": 4284117730, "icon": "work"}),
        mutation(payload=task),
        mutation(kind="list", entity_id="inbox", payload={"name": "收集箱"}),
    ])
    assert len(result["accepted"]) == 3
    assert result["accepted"][1]["entity"]["payload"] == {
        **task, "itemType": "task", "richContent": [], "attachments": [], "importData": {},
        "endDate": None, "endTime": None, "recurrenceRule": None,
    }


def test_request_limits_and_invalid_cursor(client):
    auth = register(client)
    too_many = client.post("/api/v1/sync", headers=headers(auth), json={"cursor": 0, "mutations": [mutation()] * 501})
    assert too_many.status_code == 422
    ahead = client.post("/api/v1/sync", headers=headers(auth), json={"cursor": 1, "mutations": []})
    assert ahead.status_code == 400
    oversized = client.post("/api/v1/sync", headers=headers(auth), content=b" " * (2 * 1024 * 1024 + 1))
    assert oversized.status_code == 413
    invalid_register = client.post("/api/v1/auth/register", json={"email": "x", "password": "SENSITIVE", "name": "X"})
    assert invalid_register.status_code == 422 and "SENSITIVE" not in invalid_register.text


def test_cors_allowlist_and_security_headers(client):
    good = client.options("/api/v1/sync", headers={
        "Origin": "https://planner.example.com", "Access-Control-Request-Method": "POST",
        "Access-Control-Request-Headers": "authorization,content-type",
    })
    assert good.status_code == 200
    assert good.headers["access-control-allow-origin"] == "https://planner.example.com"
    denied = client.options("/api/v1/sync", headers={
        "Origin": "https://evil.example", "Access-Control-Request-Method": "POST",
    })
    assert denied.status_code == 400 and "access-control-allow-origin" not in denied.headers
    health = client.get("/api/v1/health")
    assert health.headers["cache-control"] == "no-store"
    assert health.headers["x-content-type-options"] == "nosniff"


def test_rate_limit_cannot_be_bypassed_with_untrusted_forwarded_header(settings):
    with TestClient(create_app(replace(settings, auth_rate_limit=2))) as limited:
        for _ in range(2):
            assert limited.post("/api/v1/auth/login", json={"email": "none@example.com", "password": PASSWORD}).status_code == 401
        response = limited.post("/api/v1/auth/login", headers={"X-Forwarded-For": "1.2.3.4"}, json={
            "email": "other@example.com", "password": PASSWORD,
        })
        assert response.status_code == 429 and int(response.headers["retry-after"]) > 0


def test_trusted_proxy_preserves_separate_client_ip_limits(settings):
    proxy_ip = "172.30.72.3"
    app = ProxyHeadersMiddleware(
        create_app(replace(settings, auth_rate_limit=2)), trusted_hosts=proxy_ip,
    )
    with TestClient(app, client=(proxy_ip, 40000)) as limited:
        def attempt(ip, email):
            return limited.post("/api/v1/auth/login", headers={"X-Forwarded-For": ip}, json={
                "email": email, "password": PASSWORD,
            }).status_code

        assert attempt("198.51.100.10", "first@example.com") == 401
        assert attempt("198.51.100.10", "second@example.com") == 401
        assert attempt("198.51.100.10", "third@example.com") == 429
        assert attempt("198.51.100.11", "fourth@example.com") == 401


def test_enabled_proxy_headers_do_not_trust_direct_api_clients(settings):
    app = ProxyHeadersMiddleware(
        create_app(replace(settings, auth_rate_limit=2)), trusted_hosts="172.30.72.3",
    )
    with TestClient(app, client=("172.30.72.4", 40000)) as limited:
        statuses = [
            limited.post("/api/v1/auth/login", headers={
                "X-Forwarded-For": f"198.51.100.{index}",
            }, json={"email": f"account{index}@example.com", "password": PASSWORD}).status_code
            for index in range(1, 4)
        ]
        assert statuses == [401, 401, 429]


def test_configuration_fails_closed(settings):
    with pytest.raises(ValueError):
        replace(settings, jwt_secret="short")
    with pytest.raises(ValueError):
        replace(settings, allowed_origins=("*",))
    with pytest.raises(ValueError):
        replace(settings, allowed_origins=("https://example.com/path",))
