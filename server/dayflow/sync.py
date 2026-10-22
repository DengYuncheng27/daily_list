from datetime import datetime, timezone
import hashlib
import json

from fastapi import HTTPException

from .models import SyncRequest
from .attachments import validate_attachment_references


PAGE_SIZE = 500


def canonical(value) -> str:
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"), allow_nan=False)


def timestamp() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="microseconds").replace("+00:00", "Z")


def entity_from_row(row):
    return {
        "kind": row["kind"],
        "id": row["id"],
        "version": row["version"],
        "deleted": bool(row["deleted"]),
        "updatedAt": row["updated_at"],
        "payload": json.loads(row["payload"]),
    }

def mutation_hash(mutation):
    value = mutation.model_dump()
    # Preserve v1 receipt hashes when a pre-upgrade request is retried. Adding
    # optional schema defaults must not turn an identical retry into HTTP 409.
    if mutation.kind == "task" and not mutation.deleted:
        defaults = {"itemType": "task", "richContent": [], "attachments": [], "importData": {},
                    "endDate": None, "endTime": None, "recurrenceRule": None}
        for key, default in defaults.items():
            if value["payload"].get(key) == default:
                value["payload"].pop(key, None)
    return hashlib.sha256(canonical(value).encode("utf-8")).hexdigest()


def synchronize(database, user_id: str, request: SyncRequest):
    accepted, conflicts = [], []
    # One transaction serializes competing writes and atomically persists idempotency,
    # current entities and immutable change events. No accepted-but-unlogged writes.
    with database.connection(write=True) as connection:
        before = connection.execute("SELECT COALESCE(MAX(sequence),0) FROM changes").fetchone()[0]
        if request.cursor > before:
            raise HTTPException(400, "Sync cursor is ahead of this server; pull from cursor 0.")
        for mutation in request.mutations:
            request_hash = mutation_hash(mutation)
            prior = connection.execute(
                "SELECT request_hash,outcome,result FROM mutations WHERE user_id=? AND mutation_id=?",
                (user_id, mutation.mutationId),
            ).fetchone()
            if prior is not None:
                if prior["request_hash"] != request_hash:
                    raise HTTPException(409, "mutationId was already used for different content.")
                (accepted if prior["outcome"] == "accepted" else conflicts).append(json.loads(prior["result"]))
                continue
            current = connection.execute(
                "SELECT * FROM entities WHERE user_id=? AND kind=? AND id=?",
                (user_id, mutation.kind, mutation.id),
            ).fetchone()
            version = current["version"] if current else 0
            if mutation.baseVersion != version:
                # An absent entity has no persisted version. This explicit version-0
                # tombstone lets clients resolve stale-cache conflicts without data loss.
                server = entity_from_row(current) if current else {
                    "kind": mutation.kind, "id": mutation.id, "version": 0,
                    "deleted": True, "updatedAt": timestamp(), "payload": {},
                }
                result = {"mutationId": mutation.mutationId, "server": server}
                outcome = "conflicts"
                conflicts.append(result)
            else:
                if mutation.kind == "task" and not mutation.deleted:
                    validate_attachment_references(connection, user_id, mutation.payload)
                entity = {
                    "kind": mutation.kind, "id": mutation.id, "version": version + 1,
                    "deleted": mutation.deleted, "updatedAt": timestamp(), "payload": mutation.payload,
                }
                connection.execute(
                    """INSERT INTO entities(user_id,kind,id,version,deleted,updated_at,payload)
                       VALUES(?,?,?,?,?,?,?) ON CONFLICT(user_id,kind,id) DO UPDATE SET
                       version=excluded.version,deleted=excluded.deleted,
                       updated_at=excluded.updated_at,payload=excluded.payload""",
                    (user_id, mutation.kind, mutation.id, entity["version"],
                     int(entity["deleted"]), entity["updatedAt"], canonical(entity["payload"])),
                )
                connection.execute(
                    "INSERT INTO changes(user_id,entity) VALUES(?,?)", (user_id, canonical(entity))
                )
                result = {"mutationId": mutation.mutationId, "entity": entity}
                outcome = "accepted"
                accepted.append(result)
            connection.execute(
                "INSERT INTO mutations(user_id,mutation_id,request_hash,outcome,result) VALUES(?,?,?,?,?)",
                (user_id, mutation.mutationId, request_hash, outcome, canonical(result)),
            )
        high_water = connection.execute("SELECT COALESCE(MAX(sequence),0) FROM changes").fetchone()[0]
        rows = connection.execute(
            """SELECT sequence,entity FROM changes WHERE user_id=? AND sequence>? AND sequence<=?
               ORDER BY sequence LIMIT ?""",
            (user_id, request.cursor, high_water, PAGE_SIZE + 1),
        ).fetchall()
        more = len(rows) > PAGE_SIZE
        page = rows[:PAGE_SIZE]
        cursor = page[-1]["sequence"] if more else high_water
        return {
            "cursor": cursor,
            "hasMore": more,
            "accepted": accepted,
            "conflicts": conflicts,
            "changes": [json.loads(row["entity"]) for row in page],
        }
