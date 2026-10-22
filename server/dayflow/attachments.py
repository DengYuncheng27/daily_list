"""Private immutable attachment blobs. Names are display metadata, never paths."""

import hashlib
import json
import os
from pathlib import Path
import re
import tempfile
import time
import warnings
from uuid import UUID

from fastapi import HTTPException
from PIL import Image, UnidentifiedImageError


IMAGE_TYPES = {"png": ("PNG", "image/png"), "jpg": ("JPEG", "image/jpeg"),
               "jpeg": ("JPEG", "image/jpeg"), "webp": ("WEBP", "image/webp")}
DOWNLOAD_TYPES = {"pdf", "txt", "md", "csv", "json", "doc", "docx", "xls", "xlsx",
                  "ppt", "pptx", "zip", "mp3", "wav", "rtf"}
ALLOWED_EXTENSIONS = sorted(set(IMAGE_TYPES) | DOWNLOAD_TYPES)


def attachment_dto(row):
    return {"id": row["id"], "name": row["name"], "mimeType": row["mime_type"],
            "size": row["size"], "sha256": row["sha256"]}


def safe_name(value):
    if (
        not value or len(value) > 180 or value.strip() != value
        or value in {".", ".."} or value.endswith(".")
        or re.search(r'[<>:"/\\|?*\x00-\x1f\x7f]', value)
        or any("\u202a" <= char <= "\u202e" or "\u2066" <= char <= "\u2069" for char in value)
        or value.split(".", 1)[0].upper() in {"CON", "PRN", "AUX", "NUL", *(f"COM{i}" for i in range(10)), *(f"LPT{i}" for i in range(10))}
    ):
        raise HTTPException(422, "Invalid attachment filename.")
    extension = value.rsplit(".", 1)[-1].lower() if "." in value else ""
    if extension not in ALLOWED_EXTENSIONS:
        raise HTTPException(415, "This attachment file type is not supported.")
    return extension


def validate_content(path, extension):
    if extension in IMAGE_TYPES:
        expected, mime = IMAGE_TYPES[extension]
        try:
            with warnings.catch_warnings():
                warnings.simplefilter("error", Image.DecompressionBombWarning)
                with Image.open(path) as image:
                    if image.format != expected or image.width * image.height > 25_000_000:
                        raise ValueError("Image format or pixel limit.")
                    image.verify()
        except (OSError, ValueError, UnidentifiedImageError, Image.DecompressionBombError, Image.DecompressionBombWarning):
            raise HTTPException(415, "Invalid image or image exceeds 25 million pixels.")
        return mime
    # Non-images are opaque downloads, never rendered inline or unpacked.
    # A filename alone is not allowed to disguise executables as a document.
    with open(path, "rb") as stream:
        head = stream.read(16)
        if extension in {"txt", "md", "csv", "json"}:
            stream.seek(0)
            try:
                text = stream.read().decode("utf-8-sig")
                if "\x00" in text:
                    raise ValueError()
                if extension == "json":
                    json.loads(text)
            except (UnicodeDecodeError, ValueError, RecursionError):
                raise HTTPException(415, "Text attachments must contain valid UTF-8 text.")
        elif extension == "pdf" and not head.startswith(b"%PDF-"):
            raise HTTPException(415, "Invalid PDF signature.")
        elif extension in {"docx", "xlsx", "pptx", "zip"} and not head.startswith((b"PK\x03\x04", b"PK\x05\x06", b"PK\x07\x08")):
            raise HTTPException(415, "Invalid document/archive signature.")
        elif extension in {"doc", "xls", "ppt"} and not head.startswith(b"\xd0\xcf\x11\xe0\xa1\xb1\x1a\xe1"):
            raise HTTPException(415, "Invalid office document signature.")
        elif extension == "wav" and not (head.startswith(b"RIFF") and head[8:12] == b"WAVE"):
            raise HTTPException(415, "Invalid WAV signature.")
        elif extension == "mp3" and not (head.startswith(b"ID3") or (len(head) >= 2 and head[0] == 255 and head[1] & 224 == 224)):
            raise HTTPException(415, "Invalid MP3 signature.")
        elif extension == "rtf" and not head.startswith(b"{\\rtf"):
            raise HTTPException(415, "Invalid RTF signature.")
    return "application/octet-stream"


class AttachmentStore:
    def __init__(self, database, settings):
        self.database, self.settings = database, settings
        self.root = Path(settings.attachment_directory or database.path.parent / "attachments").resolve()

    def initialize(self):
        self.root.mkdir(parents=True, exist_ok=True, mode=0o700)
        (self.root / ".staging").mkdir(exist_ok=True, mode=0o700)

    def temporary(self):
        return tempfile.NamedTemporaryFile(prefix="upload-", suffix=".part", dir=self.root / ".staging", delete=False)

    def path(self, owner, identifier):
        # Even internal callers cannot pass path segments in place of UUIDs.
        return self.root / str(UUID(owner)) / (str(UUID(identifier)) + ".blob")

    def limits(self, owner):
        with self.database.connection() as connection:
            used = connection.execute("SELECT COALESCE(SUM(size),0) FROM attachments WHERE user_id=?", (owner,)).fetchone()[0]
        return {"maxFileBytes": self.settings.attachment_max_bytes,
                "quotaBytes": self.settings.attachment_quota_bytes, "usedBytes": used,
                "allowedExtensions": ALLOWED_EXTENSIONS}

    def commit(self, owner, identifier, name, temporary, size, digest):
        extension = safe_name(name)
        mime = validate_content(temporary, extension)
        path = self.path(owner, identifier)
        created = False
        try:
            with self.database.connection(write=True) as connection:
                previous = connection.execute(
                    "SELECT * FROM attachments WHERE user_id=? AND id=?", (owner, identifier),
                ).fetchone()
                if previous is not None:
                    if previous["sha256"] != digest or previous["name"] != name or previous["size"] != size:
                        raise HTTPException(409, "Attachment ID was already used for different content.")
                    if not path.is_file():
                        raise HTTPException(503, "Attachment storage is unavailable.")
                    return attachment_dto(previous)
                used = connection.execute(
                    "SELECT COALESCE(SUM(size),0) FROM attachments WHERE user_id=?", (owner,),
                ).fetchone()[0]
                if used + size > self.settings.attachment_quota_bytes:
                    raise HTTPException(413, "Attachment storage quota exceeded.")
                path.parent.mkdir(exist_ok=True, mode=0o700)
                os.replace(temporary, path)
                created = True
                connection.execute(
                    "INSERT INTO attachments(user_id,id,name,mime_type,size,sha256,created_at) VALUES(?,?,?,?,?,?,?)",
                    (owner, identifier, name, mime, size, digest, int(time.time())),
                )
            return {"id": identifier, "name": name, "mimeType": mime, "size": size, "sha256": digest}
        except BaseException:
            if created:
                path.unlink(missing_ok=True)
            raise

    def download(self, owner, identifier):
        with self.database.connection() as connection:
            row = connection.execute(
                "SELECT * FROM attachments WHERE user_id=? AND id=?", (owner, identifier),
            ).fetchone()
        if row is None:
            raise HTTPException(404, "Attachment not found.")
        path = self.path(owner, identifier)
        if not path.is_file():
            raise HTTPException(503, "Attachment storage is unavailable.")
        return row, path


def validate_attachment_references(connection, owner, payload):
    for attachment in payload.get("attachments", []):
        row = connection.execute(
            "SELECT * FROM attachments WHERE user_id=? AND id=?", (owner, attachment["id"]),
        ).fetchone()
        if row is None or attachment != attachment_dto(row):
            raise HTTPException(422, "Attachment is unavailable or its metadata does not match this account.")
