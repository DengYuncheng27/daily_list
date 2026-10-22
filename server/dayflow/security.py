from collections import deque
import hashlib
import secrets
import threading
import time
from uuid import uuid4

from argon2 import PasswordHasher
from argon2.exceptions import InvalidHashError, VerificationError, VerifyMismatchError
import jwt
from fastapi import HTTPException
from starlette.responses import JSONResponse

from .config import Settings


ACCESS_SECONDS = 15 * 60
REFRESH_SECONDS = 30 * 24 * 60 * 60


def token_hash(token: str) -> str:
    return hashlib.sha256(token.encode("utf-8")).hexdigest()


class RateLimiter:
    """Bounded process-local sliding windows. Deploy exactly one API worker."""

    def __init__(self, window: int):
        self.window = window
        self.entries: dict[str, deque[float]] = {}
        self.lock = threading.Lock()

    def hit(self, key: str, limit: int):
        now = time.monotonic()
        cutoff = now - self.window
        with self.lock:
            if key not in self.entries and len(self.entries) >= 10000:
                self.entries = {
                    name: hits for name, hits in self.entries.items() if hits[-1] > cutoff
                }
                if len(self.entries) >= 10000:
                    raise HTTPException(429, "Too many requests.", headers={"Retry-After": str(self.window)})
            hits = self.entries.setdefault(key, deque())
            while hits and hits[0] <= cutoff:
                hits.popleft()
            if len(hits) >= limit:
                retry = max(1, int(self.window - (now - hits[0])) + 1)
                raise HTTPException(429, "Too many requests.", headers={"Retry-After": str(retry)})
            hits.append(now)


class Auth:
    def __init__(self, settings: Settings):
        self.settings = settings
        # Argon2id: 64 MiB, three passes. Never truncate passwords.
        self.hasher = PasswordHasher(time_cost=3, memory_cost=65536, parallelism=2)
        self.dummy_hash = self.hasher.hash(secrets.token_urlsafe(32))
        self.password_slots = threading.BoundedSemaphore(2)

    def hash_password(self, password: str):
        if not self.password_slots.acquire(timeout=1):
            raise HTTPException(503, "Authentication is busy; retry later.")
        try:
            return self.hasher.hash(password)
        finally:
            self.password_slots.release()

    def verify_password(self, password_hash: str | None, password: str):
        if not self.password_slots.acquire(timeout=1):
            raise HTTPException(503, "Authentication is busy; retry later.")
        try:
            matched = self.hasher.verify(password_hash or self.dummy_hash, password)
            return matched and password_hash is not None
        except (VerifyMismatchError, VerificationError, InvalidHashError):
            return False
        finally:
            self.password_slots.release()

    def issue(self, connection, user, *, session_id: str | None = None):
        now = int(time.time())
        expiry = now + REFRESH_SECONDS
        session_id = session_id or str(uuid4())
        connection.execute(
            """INSERT INTO sessions(id,user_id,created_at,expires_at) VALUES(?,?,?,?)
               ON CONFLICT(id) DO UPDATE SET expires_at=excluded.expires_at""",
            (session_id, user["id"], now, expiry),
        )
        refresh = secrets.token_urlsafe(48)
        connection.execute(
            "INSERT INTO refresh_tokens(token_hash,session_id,created_at,expires_at) VALUES(?,?,?,?)",
            (token_hash(refresh), session_id, now, expiry),
        )
        access = jwt.encode(
            {
                "sub": user["id"],
                "sid": session_id,
                "iss": self.settings.issuer,
                "aud": self.settings.audience,
                "iat": now,
                "nbf": now,
                "exp": now + ACCESS_SECONDS,
                "jti": str(uuid4()),
                "type": "access",
            },
            self.settings.jwt_secret,
            algorithm="HS256",
        )
        return {
            "accessToken": access,
            "refreshToken": refresh,
            "user": public_user(user),
        }

    def claims(self, token: str):
        try:
            claims = jwt.decode(
                token,
                self.settings.jwt_secret,
                algorithms=["HS256"],
                issuer=self.settings.issuer,
                audience=self.settings.audience,
                options={"require": ["sub", "sid", "exp", "iat", "nbf", "jti", "type"]},
            )
            if claims["type"] != "access":
                raise jwt.InvalidTokenError()
            return claims
        except jwt.InvalidTokenError:
            raise HTTPException(401, "Invalid or expired session.", headers={"WWW-Authenticate": "Bearer"})


def public_user(user):
    return {key: user[key] for key in ("id", "email", "name")}


class RequestGuard:
    """Bound bodies before JSON decoding; rate-limit auth before password hashing."""

    def __init__(self, app, settings: Settings, limiter: RateLimiter):
        self.app, self.settings, self.limiter = app, settings, limiter

    async def __call__(self, scope, receive, send):
        if scope["type"] != "http":
            return await self.app(scope, receive, send)

        async def secure_send(message):
            if message["type"] == "http.response.start":
                headers = list(message.get("headers", []))
                headers.extend([
                    (b"x-content-type-options", b"nosniff"),
                    (b"cache-control", b"no-store"),
                    (b"referrer-policy", b"no-referrer"),
                    (b"x-frame-options", b"DENY"),
                    (b"content-security-policy", b"default-src 'none'; frame-ancestors 'none'"),
                ])
                message["headers"] = headers
            await send(message)

        if scope["path"].startswith("/api/v1/auth/") and scope["method"] == "POST":
            client = scope.get("client")
            key = "auth-ip:" + (client[0] if client else "unknown")
            try:
                self.limiter.hit(key, self.settings.auth_rate_limit)
            except HTTPException as error:
                return await JSONResponse(
                    {"detail": error.detail}, error.status_code, headers=error.headers
                )(scope, receive, secure_send)
        # Authenticated upload routes stream into an exclusive temporary file
        # and enforce their own configured file limit without buffering 10 MiB.
        if scope["path"].startswith("/api/v1/attachments/") and scope["method"] == "POST":
            return await self.app(scope, receive, secure_send)
        chunks, size = [], 0
        while True:
            message = await receive()
            if message["type"] == "http.disconnect":
                return
            chunk = message.get("body", b"")
            size += len(chunk)
            if size > self.settings.max_request_bytes:
                return await JSONResponse({"detail": "Request body is too large."}, 413)(
                    scope, receive, secure_send
                )
            chunks.append(chunk)
            if not message.get("more_body", False):
                break
        delivered = False

        async def replay_receive():
            nonlocal delivered
            if not delivered:
                delivered = True
                return {"type": "http.request", "body": b"".join(chunks), "more_body": False}
            return await receive()

        await self.app(scope, replay_receive, secure_send)
