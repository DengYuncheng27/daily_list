"""Create a new verified SQLite + immutable attachment backup directory."""

import argparse
import hashlib
import json
from pathlib import Path
import shutil
import sqlite3
from uuid import UUID

from .backup import backup


def backup_bundle(source: Path, destination: Path, attachment_directory: Path | None = None):
    source = source.resolve(strict=True)
    destination = destination.resolve()
    attachments = (attachment_directory or source.parent / "attachments").resolve()
    if destination == attachments or attachments in destination.parents:
        raise ValueError("Backup destination must not be inside live attachment storage.")
    destination.mkdir(parents=True, exist_ok=False, mode=0o700)
    incomplete = destination / "INCOMPLETE"
    incomplete.write_text("Backup must not be restored until verification completes.", encoding="utf-8")
    snapshot = destination / "dayflow.sqlite3"
    # Blobs are immutable and never automatically pruned: every row captured in
    # this consistent database snapshot remains copyable after releasing SQLite.
    backup(source, snapshot)
    with sqlite3.connect(snapshot) as connection:
        exists = connection.execute("SELECT name FROM sqlite_master WHERE name='attachments'").fetchone()
        rows = connection.execute("SELECT user_id,id,size,sha256 FROM attachments").fetchall() if exists else []
    for owner, identifier, size, expected in rows:
        relative = Path(str(UUID(owner))) / (str(UUID(identifier)) + ".blob")
        target = destination / "attachments" / relative
        target.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        with open(attachments / relative, "rb") as reader, open(target, "xb") as writer:
            shutil.copyfileobj(reader, writer)
        with open(target, "rb") as reader:
            digest = hashlib.file_digest(reader, "sha256").hexdigest()
        if target.stat().st_size != size or digest != expected:
            raise RuntimeError("Attachment backup integrity verification failed.")
        target.chmod(0o600)
    (destination / "COMPLETE.json").write_text(
        json.dumps({"schema": 2, "attachments": len(rows), "verified": True}), encoding="utf-8",
    )
    incomplete.unlink()
    return len(rows)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("destination", type=Path)
    parser.add_argument("--attachments", type=Path)
    args = parser.parse_args()
    count = backup_bundle(args.source, args.destination, args.attachments)
    print(f"Verified database and {count} attachments: {args.destination}")


if __name__ == "__main__":
    main()
