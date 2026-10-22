from dataclasses import dataclass
import os
from pathlib import Path
from urllib.parse import urlsplit


@dataclass(frozen=True)
class Settings:
    database_path: str
    jwt_secret: str
    allowed_origins: tuple[str, ...] = ()
    registration_enabled: bool = False
    auth_rate_limit: int = 20
    sync_rate_limit: int = 120
    rate_window_seconds: int = 60
    max_request_bytes: int = 2 * 1024 * 1024
    attachment_directory: str | None = None
    attachment_max_bytes: int = 10 * 1024 * 1024
    attachment_quota_bytes: int = 100 * 1024 * 1024
    issuer: str = "dayflow"
    audience: str = "dayflow-client"

    def __post_init__(self):
        if len(self.jwt_secret.encode("utf-8")) < 32 or self.jwt_secret.startswith("REPLACE"):
            raise ValueError("DAYFLOW_JWT_SECRET must contain at least 32 random bytes.")
        if not self.database_path or self.database_path == ":memory:":
            raise ValueError("DAYFLOW_DATABASE_PATH must identify a persistent SQLite file.")
        for origin in self.allowed_origins:
            parsed = urlsplit(origin)
            if (
                parsed.scheme not in {"http", "https"}
                or not parsed.netloc
                or parsed.username
                or parsed.password
                or parsed.path
                or parsed.query
                or parsed.fragment
                or "*" in origin
            ):
                raise ValueError("CORS origins must be explicit HTTP(S) origins without paths.")
        if min(self.auth_rate_limit, self.sync_rate_limit, self.rate_window_seconds) < 1:
            raise ValueError("Rate limits must be positive.")
        if self.max_request_bytes < 1024:
            raise ValueError("Request body limit must be at least 1024 bytes.")
        if not 1 <= self.attachment_max_bytes <= 100 * 1024 * 1024:
            raise ValueError("Attachment file limit must be between 1 byte and 100 MiB.")
        if self.attachment_quota_bytes < self.attachment_max_bytes:
            raise ValueError("Attachment quota must be at least the file limit.")

    @classmethod
    def from_env(cls):
        registration = os.getenv("DAYFLOW_REGISTRATION_ENABLED", "false").lower()
        if registration not in {"true", "false"}:
            raise ValueError("DAYFLOW_REGISTRATION_ENABLED must be true or false.")
        return cls(
            database_path=os.getenv("DAYFLOW_DATABASE_PATH", str(Path("data") / "dayflow.sqlite3")),
            jwt_secret=os.getenv("DAYFLOW_JWT_SECRET", ""),
            allowed_origins=tuple(
                origin.strip()
                for origin in os.getenv("DAYFLOW_ALLOWED_ORIGINS", "").split(",")
                if origin.strip()
            ),
            registration_enabled=registration == "true",
            auth_rate_limit=int(os.getenv("DAYFLOW_AUTH_RATE_LIMIT", "20")),
            sync_rate_limit=int(os.getenv("DAYFLOW_SYNC_RATE_LIMIT", "120")),
            attachment_directory=os.getenv("DAYFLOW_ATTACHMENT_DIRECTORY") or None,
            attachment_max_bytes=int(os.getenv("DAYFLOW_ATTACHMENT_MAX_BYTES", str(10 * 1024 * 1024))),
            attachment_quota_bytes=int(os.getenv("DAYFLOW_ATTACHMENT_QUOTA_BYTES", str(100 * 1024 * 1024))),
        )
