# 日序 Dayflow — implementation contract

Original task planner inspired by familiar list/calendar workflows. Flutter clients: Windows, Web, Android, iOS. Self-hosted Python FastAPI + SQLite service (persistent volume, single instance). All user content remains isolated by authenticated user. Demo workspace is separate and never uploaded automatically.

## HTTP /api/v1

- POST `/auth/register` `{email,password,name}` → auth result.
- POST `/auth/login` `{email,password}` → auth result.
- POST `/auth/refresh` `{refreshToken}` → rotated auth result.
- POST `/auth/logout` `{refreshToken}` → `{ok:true}` (idempotent).
- GET `/auth/me` bearer → `{id,email,name}`.
- POST `/sync` bearer, request below → response below.
- GET `/health` → `{status:"ok"}`.
- GET `/attachments` bearer → `{maxFileBytes,quotaBytes,usedBytes,allowedExtensions}`.
- POST `/attachments/{id}?name=<URL-encoded filename>` bearer, raw binary request body → AttachmentItem (201).
- GET `/attachments/{id}` bearer → binary download, always `Content-Disposition: attachment`.

Auth result: `{accessToken,refreshToken,user:{id,email,name}}`. Access expires after 15 minutes, refresh after 30 days, revocable and rotated. Email/password login; email is an identifier, not a verified ownership claim. Password minimum 10 characters. Errors `{detail:"..."}`.

Sync request:
```json
{"cursor":0,"mutations":[{"mutationId":"uuid","kind":"task","id":"uuid","baseVersion":0,"deleted":false,"payload":{}}]}
```
Sync response:
```json
{"cursor":12,"hasMore":false,"accepted":[{"mutationId":"uuid","entity":{"kind":"task","id":"uuid","version":1,"deleted":false,"updatedAt":"UTC ISO","payload":{}}}],"conflicts":[{"mutationId":"uuid","server":{"kind":"task","id":"uuid","version":2,"deleted":false,"updatedAt":"UTC ISO","payload":{}}}],"changes":[{"kind":"task","id":"uuid","version":1,"deleted":false,"updatedAt":"UTC ISO","payload":{}}]}
```
- `mutationId` idempotent per user, retry returns same acceptance; do not duplicate changes.
- `version` per entity, global integer change sequence serves as cursor, append-only change events including tombstones.
- `baseVersion=0` creates. Existing writes must match current version. Conflicts never overwrite automatically.
- Changes filtered by user, ordered by global sequence. Limit 500, cursor is last returned change (or high-water when no more); hasMore permits next pull.
- Entity kinds `task` and `list`. Client UUIDs. Lists may also use reserved `inbox` id; tasks default to inbox, available locally on all clients.
- Client outbox persisted, in-flight saves must not erase newer local mutations. Account-specific cache; logout must not expose previous user's content.
- ISO UTC server timestamps, due date is a local calendar date independent of timezone.

Task payload:
```json
{"title":"Prepare proposal","notes":"","listId":"inbox","dueDate":"2026-10-20","dueTime":"14:00","priority":2,"completed":false,"completedAt":null,"tags":["work"],"subtasks":[{"id":"uuid","title":"Outline","completed":false}],"recurrence":"none","reminderMinutes":null}
```
`dueDate`, `dueTime`, `completedAt`, `reminderMinutes` nullable. `priority` 0 none, 1 low, 2 medium, 3 high. recurrence none/daily/weekly/monthly. Bounded text/array lengths. Reminder metadata synced; actual notification capability reported honestly per platform.

V2 task fields (old entities and clients may omit them):

- `itemType`: `"task"` or `"note"`, default `"task"`.
- `richContent`: Quill document Delta `List<Map<String,dynamic>>`, default `[]`. At most 2000 insert operations and 100000 text characters. Plain `notes` remains a search projection of at most 20000 characters.
- `attachments`: at most 50 AttachmentItem objects, default `[]`.
- `endDate` / `endTime`: nullable local date/time in the same formats as dueDate/dueTime. End requires a start date, must not precede the start, and endTime requires endDate.
- `recurrenceRule`: nullable object; new advanced recurrence goes here, while legacy `recurrence` stays in its original enum.
- `importData` (1.2): original imported CSV fields and `__source` metadata, default `{}`. Flat string map, at most 128 keys, each key 1..200 characters and each value at most 100000 characters; compact UTF-8 JSON at most 256 KiB. Saved and synced without interpreting HTML/URLs. Empty defaults are excluded from mutation hashes to preserve old idempotent retries. Update API and clients together for this new field.

RecurrenceRule fields: `frequency` = none/daily/weekly/monthly/yearly/workdays/holidays/lunar/ebbinghaus/dates; `interval` 1..999 default 1; `weekdays` list of 1..7; `monthDays` list of 1..31; `ordinal` nullable -1 or 1..5; `ordinalWeekday` nullable 1..7; `month` nullable 1..12; `basis` due/completion default due; `anchorDate` and `until` nullable YYYY-MM-DD; `count` nullable 1..100000; `occurrence` 1..100000 default 1; `workdayMode` weekdays/china2026 default weekdays; `lunarMonth` nullable 1..12; `lunarDay` nullable 1..30; `lunarLeap` bool default false; `lunarMode` yearly/monthly default yearly; `dates` up to 1000 YYYY-MM-DD strings; `reviewDays` up to 100 strictly increasing positive integers ≤3650 starting at 1, default `[1,2,4,7,15]`.

Document Delta contains only `insert` plus optional `attributes`, never patch operations (`retain`/`delete`). Image inserts are exactly `{"insert":{"image":"attachment:<uuid>"}}`; the same ID must occur in this task's attachment metadata as a validated image. Remote/data/file URLs and arbitrary embeds are rejected. Supported attributes: bold/italic/underline/strike/code/blockquote/code-block booleans, header/indent integers 0..8, font/size/color/background/align/direction/script/list/link strings. Link schemes are HTTP, HTTPS or mailto.

AttachmentItem is exactly:
```json
{"id":"uuid","name":"report.pdf","mimeType":"application/octet-stream","size":1234,"sha256":"64 lowercase hexadecimal characters"}
```

Uploads use a client UUID, have a default 10 MiB per-file limit and 100 MiB per-account quota (server configurable), and require an active Bearer session. Re-uploading the same ID, filename and contents returns the original metadata; changing contents for that ID returns 409. The server computes size/SHA-256 and MIME. Stored names never become filesystem paths. PNG/JPEG/WebP must pass image verification and a 25-million-pixel limit. PDF, UTF-8 text/Markdown/CSV/JSON, DOC/DOCX/XLS/XLSX/PPT/PPTX, ZIP, MP3/WAV and RTF are opaque `application/octet-stream` downloads; common binary signatures are checked, files are not executed or unpacked. Executable/HTML/SVG uploads are unsupported. File-type checks are not a malware scanner.

Downloads require ownership, return 404 to other accounts, and use attachment/nosniff/no-store headers even for images. Sync validates the exact attachment metadata against files owned by that account. Upload failure never creates a task reference on the client. Quota is charged once for idempotent retries. Removing a task reference does not immediately delete a blob: immutable files remain available to offline devices and conflict/history recovery, and continue counting toward quota. No public/static attachment URL exists.

SQLite schema v2 adds the attachment metadata table without changing v1 task/history/session data. Old default-only mutations retain their v1 request hash so an upgrade cannot break pending idempotent retries. Attachment files must be backed up with the database; use the server's `dayflow.backup_bundle` command.

List payload: `{name:"工作",color:4284117730,icon:"work"}`. Color is a 32-bit ARGB integer.

## UI / core Dart interface

Models in `lib/core/models.dart`: TaskItem, ProjectList, SubTask, AppUser, SyncConflict. Named constructors and immutable fields; copyWith + toPayload/fromEntity. TaskItem dates as DateTime?; dueTime as String?; recurrence String; reminderMinutes int?.

AppController in `lib/core/app_controller.dart` extends ChangeNotifier:
- tasks, lists (nondeleted); conflicts; user; authenticated; demoMode; loading; syncing; syncError; serverUrl
- initialize(), enterDemo(), signIn({email,password,serverUrl}), register({email,password,name,serverUrl}), signOut()
- saveTask(TaskItem), deleteTask(String), toggleTask(String), moveTask(String,DateTime)
- saveList(ProjectList), deleteList(String), sync(), resolveConflict(String entityId,{required bool keepLocal})
- getTask(String), taskList(String)
- pickAttachment({bool imagesOnly=false}) → Future<AttachmentItem?>; cancel returns null, failure throws.
- downloadAttachment(AttachmentItem) → Future<Uint8List>, SHA-256 and size checked.
- saveAttachmentToDevice(AttachmentItem) → Future<void>, native/browser save dialog.
- addAttachmentBytes({required String name, required Uint8List bytes}) → Future<AttachmentItem>.

Demo attachment bytes persist locally in IndexedDB on Web or application support storage on native clients. Account-specific attachment cache keys include server and account identity. Demo files do not upload on sign-in. Authenticated attachments are returned to the editor only after successful server confirmation; cached downloads remain available offline. Re-selecting the same file after a lost upload response retries the same account-specific deterministic upload UUID.

UI root owns navigation/filter/search/selection. UI components receive controller and callbacks. No dependency on proprietary app binaries, decompiled source, branding, icons, or bundled images.
