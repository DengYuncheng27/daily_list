# 日序 Dayflow 自托管服务

FastAPI + SQLite 单实例后端，实现上级目录 `API_CONTRACT.md` 的全部 `/api/v1` 接口。服务不会创建演示账户，也不会自动导入客户端演示任务。Python 3.11 或 3.12；Docker 使用 3.12。

## 本地运行

在 `server` 目录执行：

```powershell
python -m venv .venv
.\.venv\Scripts\python.exe -m pip install -r requirements.txt
$env:DAYFLOW_JWT_SECRET = python -c "import secrets; print(secrets.token_urlsafe(48))"
$env:DAYFLOW_DATABASE_PATH = "$PWD\data\dayflow.sqlite3"
$env:DAYFLOW_REGISTRATION_ENABLED = "true"
$env:DAYFLOW_ALLOWED_ORIGINS = "http://localhost:8080"
.\.venv\Scripts\python.exe -m uvicorn dayflow.main:create_app --factory --host 127.0.0.1 --port 8000 --workers 1 --no-proxy-headers --no-access-log
```

客户端服务地址填写 `http://127.0.0.1:8000`（客户端追加 `/api/v1`）。同机 Android 模拟器使用 `http://10.0.2.2:8000`；真机需要可达的 HTTPS 域名。健康检查为 `GET /api/v1/health`。端口已被占用时选择空闲端口，并在客户端填写相同端口。

开发命令每次生成新密钥，会使旧 access token 失效；长期使用应生成一次并保存在服务器的私密环境配置中。不要将生产密钥写入源码。`.env` 仅为 Docker Compose 的输入；直接运行 Uvicorn 时需显式设置环境变量，服务不会隐式读取任意 `.env`。

## Docker

1. 将 `.env.example` 复制为 `server/.env`，用上面的生成命令替换 `DAYFLOW_JWT_SECRET`，设置真实 Web origin（协议、主机、可选端口；无路径或末尾 `/`）。
2. 首次注册时设置 `DAYFLOW_REGISTRATION_ENABLED=true`。启动后使用客户端注册自己的账户，再改为 `false` 并重建容器。此开关不影响现有账户登录。
3. 从 `dayflow` 根目录执行：

```sh
docker compose -f deploy/compose.api.yml up -d --build
docker compose -f deploy/compose.api.yml logs --tail=50 api
curl http://127.0.0.1:8000/api/v1/health
```

Compose 只发布服务器回环地址 `127.0.0.1:8000`，数据在 `dayflow-data` 命名卷。进程以 UID/GID 10001 运行，根文件系统只读、去除容器 capabilities，内存上限 512 MiB。请在前置反向代理上配置 HTTPS，再让客户端访问该域名。这个交付未连接或部署到任何外部服务器。

固定运行 **一个 API 容器、一个 Uvicorn worker**；SQLite 文件不得放在 NFS/SMB 共享盘。API 的 SQLite 事务可正确串行化同时到来的写入，但内存限速器是进程级。需要多副本时应迁移数据库与限速存储，不能仅增加 replicas。

镜像及 API 单独部署默认忽略 `X-Forwarded-For`，不会让客户端伪造 IP 绕过限速。完整生产配置 `deploy/compose.yml` 已将 API 放在独立内部网络、不发布 API 宿主端口；只有 Caddy 连接该网络并将来源地址写入 `X-Forwarded-For`。Uvicorn 仅信任 Caddy 的固定地址 `172.30.72.3`，因此不同真实客户端有各自的认证限速窗口，其他直连来源伪造头无效。若 `172.30.72.0/29` 与现有网络冲突，同时修改 `deploy/.env` 的 `DAYFLOW_PROXY_SUBNET` 与位于该网段内的 `DAYFLOW_PROXY_IP`；不要用 `*` 或整个网段代替单一可信地址。此配置预期 Caddy 直接面向客户端；如再接 CDN/其他代理，需要另行配置严格的代理信任链。

## 配置

| 环境变量 | 默认值 | 含义 |
|---|---|---|
| `DAYFLOW_JWT_SECRET` | 无，必须填写 | 至少 32 字节的随机秘密；短值或示例占位符会阻止启动 |
| `DAYFLOW_DATABASE_PATH` | `data/dayflow.sqlite3` | 持久化 SQLite 文件；Compose 固定 `/data/dayflow.sqlite3` |
| `DAYFLOW_ALLOWED_ORIGINS` | 空 | 逗号分隔的 Web origin 白名单；不允许 `*`，原生客户端无需 CORS |
| `DAYFLOW_REGISTRATION_ENABLED` | `false` | 是否允许新用户注册 |
| `DAYFLOW_AUTH_RATE_LIMIT` | `20` | 每 60 秒、每来源 IP 的认证 POST 上限；登录另有账户维度上限 |
| `DAYFLOW_SYNC_RATE_LIMIT` | `120` | 每 60 秒、每用户 sync 上限 |
| `DAYFLOW_ATTACHMENT_DIRECTORY` | 数据库同级 `attachments` | 私有附件目录；Docker 固定 `/data/attachments`，与数据库共用持久卷 |
| `DAYFLOW_ATTACHMENT_MAX_BYTES` | `10485760` | 每文件上限，默认 10 MiB，可设置 1 字节至 100 MiB |
| `DAYFLOW_ATTACHMENT_QUOTA_BYTES` | `104857600` | 每账户附件配额，默认 100 MiB，不能低于文件上限 |

密码至少 10、至多 128 字符，Argon2id（64 MiB、3 次迭代、2 并行度）存储；并发密码计算限制为两项。邮箱用作大小写不敏感的登录名，**未进行邮箱所有权验证**。目前无邮箱验证、忘记密码邮件或 MFA。

Access token 为 HS256 JWT，固定签名算法、issuer/audience 校验，有效期 15 分钟。Refresh token 是随机秘密，数据库只存 SHA-256，30 天有效、每次使用轮换；使用过的 token 再次出现会撤销同一登录会话的整条 token 链。注销立即撤销该会话，因此现存 access token 也立即失效；其他设备的会话继续有效。客户端应串行刷新，刷新请求结果丢失时重新登录，不能反复使用已轮换 token。

## 同步语义

- 每次 `/sync` 在单一 `BEGIN IMMEDIATE` 事务中提交实体、不可变 change event 与 mutation 回执。请求超时后可安全原样重试。
- `(user_id, kind, id)` 定位实体。不同账户可以使用相同客户端 UUID；所有实体、回执和 changes 查询均带 owner 限定。
- 同一用户的 `mutationId` 只绑定一份规范化请求；原样重试返回原始 accepted 或 conflict 回执。改内容必须换 ID，复用 ID 改内容返回 409 并回滚本次请求。
- `baseVersion=0` 创建；更新、删除和恢复均要求匹配当前版本。冲突不会自动覆盖。不存在的实体遇到 `baseVersion>0` 返回 `version=0, deleted=true` 的虚拟冲突实体，不写入 changes。
- 每批最多 500 条 mutation，每次最多返回 500 条 changes；`hasMore=true` 时使用响应 cursor 继续拉取。cursor 是全局递增序号，因此可能存在其他账户产生的序号间隙，但响应只包含本账户内容。最后一页 cursor 推进到事务高水位。超前 cursor 返回 400。
- 墓碑、历史 events 和回执不自动清理，避免离线设备复活已删除数据或重复执行请求。存储随使用增长，应监控卷空间。后续如需压缩，必须设计兼容旧 cursor 的全量重同步协议。
- 删除清单不级联删除任务；任务仍保留原 `listId`，客户端应显示为收集箱或提示重新归类。系统 `inbox` 可用，不依赖服务端预建清单。
- 请求上限 2 MiB。客户端按实际 UTF-8 JSON 字节数分批，每批最多 1.5 MiB 且不超过 500 条，长备注的离线积压会自动拆成多次同步。任务标题 300、备注 20000 字符；标签 20 个、每项 40 字符；子任务 200 个。清单名称 100 字符。日期为 `YYYY-MM-DD` 本地日历日期，时间为 `HH:MM`，完成时间要求带时区并规范化 UTC。
- Reminder 数据参与同步；后端不发送推送或系统通知。

## 附件、富文本与升级

V2 启动时在事务中增加附件表，将 `PRAGMA user_version` 从 1 升为 2，保留已有账户、会话、任务、历史和请求回执。任务新增 `itemType`、Quill Delta `richContent`、`attachments`、`endDate/endTime` 与结构化 `recurrenceRule`；缺省值兼容旧数据。旧版已提交请求的默认字段哈希保持兼容，升级后重复提交不会误判为内容变化。升级前做完整备份；回滚旧服务版本前应恢复与其对应的数据库备份，旧服务会拒绝 schema v2。

`POST /api/v1/attachments/{UUID}?name=<编码文件名>` 接收原始二进制，不使用 multipart；`GET /api/v1/attachments/{UUID}` 下载，两者都要求有效 Bearer token。`GET /api/v1/attachments` 返回当前限制与本人用量。文件在鉴权后流式写入私有临时文件，检查大小、内容类型与配额后才以生成的 UUID 路径保存。配额检查和元数据提交串行化，同 ID/同文件重试不会重复计费。上传限速为每用户每分钟 30 次。

PNG/JPEG/WebP 经 Pillow 校验格式，像素不得超过 2500 万；PDF、文本/Markdown/CSV/JSON、Office、ZIP、MP3/WAV、RTF 作为不透明下载，检查已知文件签名或 UTF-8 文本，不解压、不执行。下载始终 attachment/nosniff/no-store，非图片 MIME 为 `application/octet-stream`；HTML/SVG/可执行文件不在白名单。类型检查不替代恶意文件扫描，文档和压缩包只由用户主动下载打开。

同步会核验每项附件的 owner、ID、名称、大小、MIME、SHA-256；富文本图片只能引用同一任务元数据内的私有图片附件。任务或富文本引用移除后不会立刻删除文件，以免其他离线副本和冲突记录失效；这些文件继续占用账户配额。目前无用户侧垃圾回收界面，管理员可调整配额；不要直接删除仍被任务、历史或回执引用的文件。

Flutter 使用真实文件选择与保存对话框。示例空间将 bytes 存入本机 IndexedDB/应用数据目录；真实账户只在服务端确认后返回可加入任务的元数据。断网或上传失败会显示错误，重新选择同一文件可安全重试。附件缓存按服务器与账户隔离，演示文件不会随登录自动上传。

常规错误响应为 `{"detail":"..."}`，校验失败不会回显密码/token/请求正文。429 带 `Retry-After`。服务不记录访问日志或用户任务正文；反向代理也应避免记录 Authorization、请求体和认证响应。

## 备份与恢复

运行中的 SQLite 可能将已提交数据保存在 `-wal`，不要仅复制主数据库文件。使用附带的 SQLite backup API 工具生成一致快照：

```sh
docker compose -f deploy/compose.api.yml exec api python -m dayflow.backup /data/dayflow.sqlite3 /data/dayflow-backup-2026-10-20.sqlite3
docker compose -f deploy/compose.api.yml cp api:/data/dayflow-backup-2026-10-20.sqlite3 ./dayflow-backup-2026-10-20.sqlite3
```

工具不会覆盖已存在的备份，并运行 `PRAGMA integrity_check`。备份包含私密任务、密码哈希和会话哈希，应复制到加密且有访问限制的独立存储；同一数据卷内的副本不等于灾难恢复备份。

**V2 有附件时，单独的 SQLite 备份不完整。** 使用完整备份命令：

```sh
docker compose --env-file deploy/.env -f deploy/compose.yml exec api python -m dayflow.backup_bundle /data/dayflow.sqlite3 /data/backup-2026-10-20 --attachments /data/attachments
docker compose --env-file deploy/.env -f deploy/compose.yml cp api:/data/backup-2026-10-20 ./backup-2026-10-20
```

该工具先生成一致数据库快照，再复制快照中引用的不可变文件，逐一检查大小与 SHA-256。成功目录包含 `COMPLETE.json`；失败保留 `INCOMPLETE`，这种目录不可用作恢复。目标目录必须不存在，工具不会覆盖原备份。自定义附件目录时必须传 `--attachments`。恢复时同时恢复 `dayflow.sqlite3` 与 `attachments/`，保持 UID/GID 10001 的权限。

恢复时先停止 API，保留当前完整卷快照，再用验证过的备份替换主数据库并清除与被替换数据库对应的旧 WAL/SHM，文件所有者保持 UID/GID 10001，然后启动。只对明确选定的数据库执行这些操作。备份回滚后的旧客户端 cursor 可能超前；Dayflow 客户端识别服务端的精确错误后会归零重拉，保留本地 outbox，并将旧版本冲突重新提交核对。没有待提交编辑的缓存重新接受备份中的版本。不要运行 `docker compose down -v`，它会删除持久化卷。

## 验证

```sh
python -m pip install -r requirements-dev.txt
python -m pytest -q
python -m pip install pip-audit
python -m pip_audit -r requirements.txt --no-deps --disable-pip
```

对显式指定、允许注册的测试服务还可运行真实 HTTP 双设备验证：

```sh
python tools/e2e_sync.py --server http://127.0.0.1:8000
```

该脚本会创建两个随机测试账户，在同一账户的两次登录会话间验证创建、修改、离线冲突、明确解决、幂等重试、删除，以及跨账号隔离和 token 撤销；结束时注销测试会话，不打印密码或 token。请使用独立测试数据库，避免给生产账户库增加测试记录。

测试覆盖：注册与登录、hash/token 有效期、refresh 轮换与重放、注销、账户隔离、幂等回执、冲突及显式解决、墓碑恢复、501 条分页、并发竞争、重启持久化、输入限制、CORS、限速、在线备份，以及真实 TCP/Uvicorn 工厂启动。

`requirements.txt` 固定生产及其传递依赖版本；`requirements-dev.txt` 加固定测试依赖。升级先在隔离环境重新解析、运行测试与依赖审计，再更新这些锁定文件。容器基础镜像使用维护中的 `python:3.12-slim` 标签，部署前应构建和扫描镜像，若需要逐字节可复现部署，再锁定已验证镜像 digest。
