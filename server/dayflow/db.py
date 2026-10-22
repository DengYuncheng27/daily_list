from contextlib import contextmanager
import os
from pathlib import Path
import sqlite3


SCHEMA = """
CREATE TABLE IF NOT EXISTS users (
    id TEXT PRIMARY KEY,
    email TEXT NOT NULL UNIQUE,
    name TEXT NOT NULL,
    password_hash TEXT NOT NULL,
    created_at INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS sessions (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    created_at INTEGER NOT NULL,
    expires_at INTEGER NOT NULL,
    revoked_at INTEGER
);
CREATE INDEX IF NOT EXISTS sessions_owner ON sessions(user_id);
CREATE TABLE IF NOT EXISTS refresh_tokens (
    token_hash TEXT PRIMARY KEY,
    session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
    created_at INTEGER NOT NULL,
    expires_at INTEGER NOT NULL,
    used_at INTEGER
);
CREATE INDEX IF NOT EXISTS refresh_sessions ON refresh_tokens(session_id);
CREATE TABLE IF NOT EXISTS entities (
    user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    kind TEXT NOT NULL CHECK(kind IN ('task', 'list')),
    id TEXT NOT NULL,
    version INTEGER NOT NULL CHECK(version > 0),
    deleted INTEGER NOT NULL CHECK(deleted IN (0, 1)),
    updated_at TEXT NOT NULL,
    payload TEXT NOT NULL,
    PRIMARY KEY(user_id, kind, id)
);
CREATE TABLE IF NOT EXISTS changes (
    sequence INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    entity TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS changes_owner_sequence ON changes(user_id, sequence);
CREATE TABLE IF NOT EXISTS mutations (
    user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    mutation_id TEXT NOT NULL,
    request_hash TEXT NOT NULL,
    outcome TEXT NOT NULL CHECK(outcome IN ('accepted', 'conflicts')),
    result TEXT NOT NULL,
    PRIMARY KEY(user_id, mutation_id)
);
"""

ATTACHMENT_SCHEMA = """
CREATE TABLE IF NOT EXISTS attachments (
    user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    id TEXT NOT NULL,
    name TEXT NOT NULL,
    mime_type TEXT NOT NULL,
    size INTEGER NOT NULL CHECK(size > 0),
    sha256 TEXT NOT NULL,
    created_at INTEGER NOT NULL,
    PRIMARY KEY(user_id, id)
);
PRAGMA user_version = 2;
"""


class Database:
    def __init__(self, path: str):
        self.path = Path(path).resolve()

    def initialize(self):
        self.path.parent.mkdir(parents=True, exist_ok=True)
        # SQLite inherits the private service directory and this file's mode.
        if not self.path.exists():
            descriptor = os.open(self.path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
            os.close(descriptor)
        with self.connection() as connection:
            version = connection.execute("PRAGMA user_version").fetchone()[0]
            if version not in {0, 1, 2}:
                raise RuntimeError("Database schema is newer than this service.")
            connection.execute("PRAGMA journal_mode=WAL")
            # Additive, transactional migration retains all v1 entities,
            # append-only history, sessions and idempotency receipts.
            connection.executescript("BEGIN IMMEDIATE;\n" + SCHEMA + ATTACHMENT_SCHEMA + "\nCOMMIT;")

    @contextmanager
    def connection(self, *, write: bool = False):
        connection = sqlite3.connect(self.path, timeout=15, isolation_level=None)
        connection.row_factory = sqlite3.Row
        connection.execute("PRAGMA foreign_keys=ON")
        connection.execute("PRAGMA busy_timeout=15000")
        connection.execute("PRAGMA synchronous=FULL")
        try:
            if write:
                connection.execute("BEGIN IMMEDIATE")
            yield connection
            if connection.in_transaction:
                connection.commit()
        except BaseException:
            if connection.in_transaction:
                connection.rollback()
            raise
        finally:
            connection.close()
