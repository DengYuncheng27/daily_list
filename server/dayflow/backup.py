"""Online SQLite backup including committed WAL contents; never overwrite a backup."""

import argparse
import os
from pathlib import Path
import sqlite3


def backup(source: Path, destination: Path):
    source, destination = source.resolve(strict=True), destination.resolve()
    if source == destination:
        raise ValueError("Backup destination must differ from the live database.")
    destination.parent.mkdir(parents=True, exist_ok=True)
    descriptor = os.open(destination, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    os.close(descriptor)
    try:
        reader = sqlite3.connect(source.as_uri() + "?mode=ro", uri=True, timeout=15)
        try:
            writer = sqlite3.connect(destination)
            try:
                reader.backup(writer)
                if writer.execute("PRAGMA integrity_check").fetchone()[0] != "ok":
                    raise RuntimeError("Backup integrity check failed.")
            finally:
                writer.close()
        finally:
            reader.close()
    except BaseException:
        # The exclusively created file belongs to this invocation.
        destination.unlink(missing_ok=True)
        raise


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("destination", type=Path)
    args = parser.parse_args()
    backup(args.source, args.destination)
    print(f"Verified SQLite backup created: {args.destination}")


if __name__ == "__main__":
    main()
