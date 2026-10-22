"""Explicit HTTP acceptance check. Creates random test accounts; prints no credentials."""

import argparse
import json
import hashlib
import secrets
from urllib.error import HTTPError
from urllib.request import ProxyHandler, Request, build_opener
from uuid import uuid4


def run(server_url: str):
    base = server_url.rstrip("/") + "/api/v1"
    opener = build_opener(ProxyHandler({}))
    checks = []

    def post(path, body, access=None, expected=200):
        request = Request(
            base + path, json.dumps(body).encode("utf-8"),
            headers={"Content-Type": "application/json", **(
                {"Authorization": "Bearer " + access} if access else {}
            )}, method="POST",
        )
        try:
            with opener.open(request, timeout=20) as response:
                code, result = response.status, json.load(response)
        except HTTPError as error:
            code, result = error.code, json.load(error)
        if code != expected:
            raise AssertionError(f"{path}: expected HTTP {expected}, got {code}: {result.get('detail', 'error')}")
        return result

    def change(entity_id, base_version, title="", deleted=False):
        return {
            "mutationId": str(uuid4()), "kind": "task", "id": entity_id,
            "baseVersion": base_version, "deleted": deleted,
            "payload": {} if deleted else {"title": title},
        }

    def sync(auth, changes=(), cursor=0):
        return post("/sync", {"cursor": cursor, "mutations": list(changes)}, auth["accessToken"])

    email = f"e2e-{uuid4().hex}@example.com"
    password = secrets.token_urlsafe(32)
    device_a = post("/auth/register", {"email": email, "password": password, "name": "HTTP validation"}, expected=201)
    device_b = post("/auth/login", {"email": email, "password": password})
    assert device_a["user"]["id"] == device_b["user"]["id"]
    checks.append("two-device registration/login")

    task_id = str(uuid4())
    created = sync(device_a, [change(task_id, 0, "Initial shared task")])
    pulled_b = sync(device_b)
    assert pulled_b["changes"][-1] == created["accepted"][0]["entity"]
    checks.append("device A create -> device B pull")

    offline_edit = change(task_id, 1, "Device B's offline edit")
    edited_a = sync(device_a, [change(task_id, 1, "Device A's edit")], created["cursor"])
    conflict = sync(device_b, [offline_edit], pulled_b["cursor"])
    assert conflict["accepted"] == [] and conflict["conflicts"][0]["server"]["version"] == 2
    assert conflict["conflicts"][0]["server"]["payload"]["title"] == "Device A's edit"
    checks.append("offline stale edit becomes conflict without overwrite")

    resolution = change(task_id, 2, "Explicitly chosen offline edit")
    resolved = sync(device_b, [resolution], conflict["cursor"])
    assert resolved["accepted"][0]["entity"]["version"] == 3
    pulled_a = sync(device_a, cursor=edited_a["cursor"])
    assert pulled_a["changes"][-1]["payload"]["title"] == "Explicitly chosen offline edit"
    checks.append("explicit conflict resolution propagates")

    retried = sync(device_b, [resolution], resolved["cursor"])
    assert retried["accepted"] == resolved["accepted"] and retried["changes"] == []
    checks.append("same mutation retry is idempotent")

    deleted = sync(device_a, [change(task_id, 3, deleted=True)], pulled_a["cursor"])
    tombstone_b = sync(device_b, cursor=resolved["cursor"])["changes"][-1]
    assert tombstone_b == deleted["accepted"][0]["entity"]
    assert tombstone_b["deleted"] and tombstone_b["payload"] == {}
    checks.append("delete tombstone reaches second device")

    isolated = post("/auth/register", {
        "email": f"e2e-isolated-{uuid4().hex}@example.com",
        "password": secrets.token_urlsafe(32), "name": "HTTP isolation validation",
    }, expected=201)
    assert sync(isolated)["changes"] == []
    checks.append("another account cannot read task history")

    attachment_id = str(uuid4())
    attachment_body = "Private attachment across two devices.\n".encode()
    attachment_path = "/attachments/" + attachment_id
    def binary(method, path, auth=None, body=None, expected=200):
        request = Request(base + path, data=body, method=method, headers={
            "Content-Type": "application/octet-stream",
            **({"Authorization": "Bearer " + auth["accessToken"]} if auth else {}),
        })
        try:
            with opener.open(request, timeout=20) as response:
                code, data, response_headers = response.status, response.read(), response.headers
        except HTTPError as error:
            code, data, response_headers = error.code, error.read(), error.headers
        assert code == expected, f"Attachment {method}: expected {expected}, got {code}"
        return data, response_headers
    uploaded, _ = binary("POST", attachment_path + "?name=private.txt", device_a, attachment_body, 201)
    item = json.loads(uploaded)
    assert item["sha256"] == hashlib.sha256(attachment_body).hexdigest()
    retried_file, _ = binary("POST", attachment_path + "?name=private.txt", device_a, attachment_body, 201)
    assert json.loads(retried_file) == item
    downloaded, download_headers = binary("GET", attachment_path, device_b)
    assert downloaded == attachment_body
    assert download_headers["Content-Disposition"].startswith("attachment;")
    binary("GET", attachment_path, isolated, expected=404)
    binary("GET", attachment_path, expected=401)
    file_task = change(str(uuid4()), 0, "Note with a real attachment")
    file_task["payload"].update({
        "itemType": "note", "attachments": [item],
        "richContent": [{"insert": "Attachment note", "attributes": {"bold": True}}, {"insert": "\n"}],
    })
    shared = sync(device_a, [file_task])
    pulled = sync(device_b)["changes"][-1]["payload"]
    assert pulled["attachments"] == [item] and pulled["itemType"] == "note"
    post("/sync", {"mutations": [{**file_task, "mutationId": str(uuid4()), "id": str(uuid4())}]},
         isolated["accessToken"], expected=422)
    sync(device_a, [change(file_task["id"], 1, deleted=True)], shared["cursor"])
    checks.append("real attachment upload/retry/download, note sync, and owner isolation")

    rotated = post("/auth/refresh", {"refreshToken": device_b["refreshToken"]})
    assert rotated["refreshToken"] != device_b["refreshToken"]
    post("/auth/logout", {"refreshToken": rotated["refreshToken"]})
    post("/sync", {"cursor": 0, "mutations": []}, rotated["accessToken"], expected=401)
    post("/auth/logout", {"refreshToken": device_a["refreshToken"]})
    post("/auth/logout", {"refreshToken": isolated["refreshToken"]})
    checks.append("refresh rotates and logout revokes access")
    return {"status": "passed", "server": server_url, "checks": checks}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--server", default="http://127.0.0.1:8000")
    args = parser.parse_args()
    print(json.dumps(run(args.server), ensure_ascii=False, indent=2))
