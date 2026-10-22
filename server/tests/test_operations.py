import os
from pathlib import Path
import secrets
import socket
import sqlite3
import subprocess
import sys
import time
from uuid import uuid4

import httpx
import pytest

from dayflow.backup import backup
from dayflow.db import Database


def test_online_backup_includes_wal_and_refuses_overwrite(tmp_path):
    source, target = tmp_path / "live.sqlite3", tmp_path / "snapshot.sqlite3"
    database = Database(str(source))
    database.initialize()
    with database.connection() as keeper:
        keeper.execute("PRAGMA wal_autocheckpoint=0")
        keeper.execute("INSERT INTO users VALUES(?,?,?,?,?)", ("id", "x@example.com", "X", "hash", 0))
        backup(source, target)
        with sqlite3.connect(target) as restored:
            assert restored.execute("SELECT name FROM users").fetchone()[0] == "X"
        with pytest.raises(FileExistsError):
            backup(source, target)
        with pytest.raises(ValueError):
            backup(source, source)


def test_real_http_factory_startup_and_persistent_sync(tmp_path):
    # Start our own temporary service; never use a user's configured database.
    with socket.socket() as reservation:
        reservation.bind(("127.0.0.1", 0))
        port = reservation.getsockname()[1]
    env = {
        **os.environ,
        "DAYFLOW_JWT_SECRET": secrets.token_urlsafe(48),
        "DAYFLOW_DATABASE_PATH": str(tmp_path / "smoke.sqlite3"),
        "DAYFLOW_REGISTRATION_ENABLED": "true",
        "DAYFLOW_ALLOWED_ORIGINS": "",
    }
    process = subprocess.Popen(
        [sys.executable, "-m", "uvicorn", "dayflow.main:create_app", "--factory",
         "--host", "127.0.0.1", "--port", str(port), "--no-proxy-headers", "--no-access-log"],
        cwd=Path(__file__).resolve().parents[1], env=env,
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
        creationflags=subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0,
    )
    try:
        with httpx.Client(base_url=f"http://127.0.0.1:{port}", timeout=3, trust_env=False) as client:
            for _ in range(100):
                assert process.poll() is None, "Temporary uvicorn exited during startup."
                try:
                    if client.get("/api/v1/health").status_code == 200:
                        break
                except httpx.TransportError:
                    pass
                time.sleep(0.05)
            else:
                pytest.fail("Temporary service did not become ready.")
            response = client.post("/api/v1/auth/register", json={
                "email": "smoke@example.com", "password": "temporary-test-only", "name": "Smoke",
            })
            assert response.status_code == 201
            result = client.post("/api/v1/sync", json={"cursor": 0, "mutations": []}, headers={
                "Authorization": "Bearer " + response.json()["accessToken"],
            })
            assert result.status_code == 200
            assert result.json() == {"cursor": 0, "hasMore": False, "accepted": [], "conflicts": [], "changes": []}
            assert result.headers["cache-control"] == "no-store"
            auth_headers = {"Authorization": "Bearer " + response.json()["accessToken"]}
            identifier = str(uuid4())
            body = b"private attachment over actual HTTP\n" * 80000  # Exceeds the JSON 2 MiB limit.
            attached = client.post(
                "/api/v1/attachments/" + identifier, params={"name": "http-roundtrip.txt"},
                content=body, headers=auth_headers,
            )
            assert attached.status_code == 201, attached.text
            assert attached.json()["size"] == len(body)
            assert client.get("/api/v1/attachments/" + identifier, headers=auth_headers).content == body
            assert client.get("/api/v1/attachments/" + identifier).status_code == 401
        assert (tmp_path / "smoke.sqlite3").exists()
    finally:
        process.terminate()
        try:
            process.communicate(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.communicate(timeout=5)
