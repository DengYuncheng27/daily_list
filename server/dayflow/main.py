from contextlib import asynccontextmanager
import logging
import hashlib
import os
from pathlib import Path
import sqlite3
import time
from uuid import UUID, uuid4

from fastapi import Depends, FastAPI, HTTPException, Query, Request
from fastapi.exceptions import RequestValidationError
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse, JSONResponse
from starlette.concurrency import run_in_threadpool
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer

from .config import Settings
from .attachments import AttachmentStore, safe_name
from .db import Database
from .models import Login, Refresh, Register, SyncRequest
from .security import Auth, RateLimiter, RequestGuard, public_user, token_hash
from .sync import synchronize


def create_app(settings: Settings | None = None) -> FastAPI:
    settings = settings or Settings.from_env()
    database = Database(settings.database_path)
    auth = Auth(settings)
    limiter = RateLimiter(settings.rate_window_seconds)
    attachment_store = AttachmentStore(database, settings)

    @asynccontextmanager
    async def lifespan(app):
        database.initialize()
        attachment_store.initialize()
        yield

    app = FastAPI(
        title="Dayflow API", version="2.0.0", lifespan=lifespan,
        docs_url=None, redoc_url=None, openapi_url=None,
    )
    app.state.database = database
    app.state.auth = auth
    app.state.settings = settings
    app.state.attachments = attachment_store
    app.add_middleware(RequestGuard, settings=settings, limiter=limiter)
    app.add_middleware(
        CORSMiddleware, allow_origins=list(settings.allowed_origins),
        allow_methods=["GET", "POST"], allow_headers=["Authorization", "Content-Type"],
        allow_credentials=False, max_age=600,
    )
    bearer = HTTPBearer(auto_error=False)

    @app.exception_handler(RequestValidationError)
    async def invalid_request(request, error):
        # Avoid returning password/token/body contents embedded in validation errors.
        return JSONResponse({"detail": "Invalid request. Check required fields, formats and limits."}, 422)

    @app.exception_handler(sqlite3.OperationalError)
    async def database_error(request, error):
        logging.getLogger("dayflow").warning("Database operation unavailable (%s)", type(error).__name__)
        return JSONResponse({"detail": "Storage is temporarily unavailable; retry later."}, 503)

    def current_user(credentials: HTTPAuthorizationCredentials | None = Depends(bearer)):
        if credentials is None:
            raise HTTPException(401, "Authentication required.", headers={"WWW-Authenticate": "Bearer"})
        claims = auth.claims(credentials.credentials)
        with database.connection() as connection:
            row = connection.execute(
                """SELECT u.* FROM users u JOIN sessions s ON u.id=s.user_id
                   WHERE u.id=? AND s.id=? AND s.revoked_at IS NULL AND s.expires_at>?""",
                (claims["sub"], claims["sid"], int(time.time())),
            ).fetchone()
        if row is None:
            raise HTTPException(401, "Invalid or expired session.", headers={"WWW-Authenticate": "Bearer"})
        return row

    @app.get("/api/v1/attachments")
    def attachment_limits(user=Depends(current_user)):
        return attachment_store.limits(user["id"])

    @app.post("/api/v1/attachments/{attachment_id}", status_code=201)
    async def upload_attachment(
        attachment_id: UUID, request: Request, name: str = Query(min_length=1, max_length=180),
        user=Depends(current_user),
    ):
        limiter.hit("upload:" + user["id"], 30)
        safe_name(name)
        if attachment_id.int == 0:
            raise HTTPException(422, "A nonzero attachment UUID is required.")
        maximum = settings.attachment_max_bytes
        length = request.headers.get("content-length")
        if length is not None and (not length.isdecimal() or int(length) > maximum):
            raise HTTPException(413, "Attachment exceeds the file size limit.")
        temporary = attachment_store.temporary()
        temporary_path = Path(temporary.name)
        size, digest = 0, hashlib.sha256()
        try:
            async for chunk in request.stream():
                size += len(chunk)
                if size > maximum:
                    raise HTTPException(413, "Attachment exceeds the file size limit.")
                temporary.write(chunk)
                digest.update(chunk)
            if size == 0:
                raise HTTPException(422, "Attachment is empty.")
            temporary.flush()
            os.fsync(temporary.fileno())
            temporary.close()
            return await run_in_threadpool(
                attachment_store.commit, user["id"], str(attachment_id),
                name, temporary_path, size, digest.hexdigest(),
            )
        finally:
            temporary.close()
            temporary_path.unlink(missing_ok=True)

    @app.get("/api/v1/attachments/{attachment_id}")
    def download_attachment(attachment_id: UUID, user=Depends(current_user)):
        row, path = attachment_store.download(user["id"], str(attachment_id))
        return FileResponse(
            path, media_type=row["mime_type"], filename=row["name"],
            content_disposition_type="attachment",
        )

    @app.get("/api/v1/health")
    def health():
        with database.connection() as connection:
            connection.execute("SELECT 1").fetchone()
        return {"status": "ok"}

    @app.post("/api/v1/auth/register", status_code=201)
    def register(body: Register):
        if not settings.registration_enabled:
            raise HTTPException(403, "Registration is disabled.")
        password_hash = auth.hash_password(body.password)
        try:
            with database.connection(write=True) as connection:
                user = {"id": str(uuid4()), "email": body.email, "name": body.name}
                connection.execute(
                    "INSERT INTO users(id,email,name,password_hash,created_at) VALUES(?,?,?,?,?)",
                    (user["id"], user["email"], user["name"], password_hash, int(time.time())),
                )
                return auth.issue(connection, user)
        except sqlite3.IntegrityError:
            raise HTTPException(409, "Unable to register this email.")

    @app.post("/api/v1/auth/login")
    def login(body: Login):
        limiter.hit("login-account:" + token_hash(body.email), settings.auth_rate_limit)
        with database.connection() as connection:
            user = connection.execute("SELECT * FROM users WHERE email=?", (body.email,)).fetchone()
        if not auth.verify_password(user["password_hash"] if user else None, body.password):
            raise HTTPException(401, "Invalid email or password.")
        with database.connection(write=True) as connection:
            if auth.hasher.check_needs_rehash(user["password_hash"]):
                connection.execute(
                    "UPDATE users SET password_hash=? WHERE id=?",
                    (auth.hash_password(body.password), user["id"]),
                )
            return auth.issue(connection, user)

    @app.post("/api/v1/auth/refresh")
    def refresh(body: Refresh):
        now, result = int(time.time()), None
        with database.connection(write=True) as connection:
            row = connection.execute(
                """SELECT r.*,s.user_id,s.revoked_at,s.expires_at AS session_expires
                   FROM refresh_tokens r JOIN sessions s ON r.session_id=s.id WHERE r.token_hash=?""",
                (token_hash(body.refreshToken),),
            ).fetchone()
            if row is not None and row["used_at"] is not None:
                # Commit revocation before returning 401. A transaction rollback here
                # would silently defeat replay detection.
                connection.execute("UPDATE sessions SET revoked_at=? WHERE id=?", (now, row["session_id"]))
            elif row is not None and row["revoked_at"] is None and min(row["expires_at"], row["session_expires"]) > now:
                connection.execute("UPDATE refresh_tokens SET used_at=? WHERE token_hash=?", (now, row["token_hash"]))
                user = connection.execute("SELECT * FROM users WHERE id=?", (row["user_id"],)).fetchone()
                result = auth.issue(connection, user, session_id=row["session_id"])
        if result is None:
            raise HTTPException(401, "Invalid or expired refresh token.")
        return result

    @app.post("/api/v1/auth/logout")
    def logout(body: Refresh):
        with database.connection(write=True) as connection:
            connection.execute(
                """UPDATE sessions SET revoked_at=COALESCE(revoked_at,?)
                   WHERE id=(SELECT session_id FROM refresh_tokens WHERE token_hash=?)""",
                (int(time.time()), token_hash(body.refreshToken)),
            )
        return {"ok": True}

    @app.get("/api/v1/auth/me")
    def me(user=Depends(current_user)):
        return public_user(user)

    @app.post("/api/v1/sync")
    def sync(body: SyncRequest, user=Depends(current_user)):
        limiter.hit("sync:" + user["id"], settings.sync_rate_limit)
        return synchronize(database, user["id"], body)

    return app
