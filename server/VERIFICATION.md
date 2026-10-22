# 服务验证记录

验证日期：2026-10-20（Asia/Hong_Kong）。

| 检查 | 结果 |
|---|---|
| Python 3.11.4 / `python -m pytest -q` | 67 passed，19.80 秒 |
| 最后调整 recurrenceRule 边界后的定向回归 | 11 passed，23 deselected |
| 锁定生产依赖 / `pip-audit -r requirements.txt --no-deps --disable-pip` | 22 个包，无已知漏洞 |
| `tools/e2e_sync.py` 连接实际 TCP/Uvicorn v2 服务 | 9 项通过 |
| Dart 附件与核心控制器回归（缓存、失败重试、账户隔离、字节分包） | 19 tests passed |
| 代理来源与限速定向回归 | 3 passed，28 deselected |
| 修改的 Dart 核心与测试静态分析 | No issues found |
| 完整生产 Compose 解析 | `docker compose ... config --quiet` 通过 |
| 本地预览代理回归 / `python -m unittest discover -s scripts -p test_preview.py -v` | 7 passed，0.258 秒 |
| Docker 镜像构建与容器运行 | 未执行：本机 Docker Linux daemon 未启动 |

后端回归使用独立临时数据库，包含密码和 refresh 哈希、15 分钟 access / 30 天 refresh、旧 token 重放撤销、注销立即失效、不同账户复用相同实体/请求 ID、乐观并发、幂等重试、501 条历史分页、墓碑与恢复、输入及大小边界、CORS、限速、重启持久化、SQLite 在线备份和实际 HTTP 启动。

HTTP 双设备检查在本机独立测试数据库中注册随机账户并建立两个登录会话，实际请求 API 验证：A 创建后 B 拉取、离线并发编辑成为冲突、明确选择本机版本再提交、原 mutation 重试不新增 change、删除墓碑传播、第二账户看不到第一账户历史，以及 refresh 轮换后注销。测试没有打印密码或 token，结尾注销了测试会话；服务启动本身不创建任何账户。

客户端修复仅识别 `HTTP 400` 且 `detail` 精确为 `Sync cursor is ahead of this server; pull from cursor 0.`，归零重拉并保留 outbox。无 pending 的服务端缓存重置版本以接受恢复库中的低版本；其他 400 不触发静默重试。测试验证未同步编辑和 mutation ID 保留。

最终协议边界审查增加两项修复。客户端以实际 UTF-8 编码后的 JSON 大小（包含转义、逗号及请求外壳）限制单批为 1.5 MiB，并继续遵守 500 条上限；测试用 100 条长中文/换行备注与 501 条小任务的离线积压验证分批后全部确认、内容保持和 outbox 清空。生产 Compose 仅信任独立内部网络中的 Caddy 固定 IP，API 不发布宿主端口，Caddy 覆盖外部提供的来源头；测试验证不同真实客户端各自限速，以及启用代理头后非可信直连仍无法通过伪造地址逃避限速。Dockerfile 的单独运行默认继续禁用代理头。

测试环境有一条 Starlette 关于 `httpx` 测试适配器的弃用提醒，不影响断言结果；生产依赖不包含该测试客户端。依赖审计是当日已知漏洞检查，不代表未来无漏洞。TLS、真实服务器卷备份、反向代理及最终 Docker 镜像仍需在提供服务器后部署验证。

## V2 附件与迁移实测

后端增加附件上传/下载、账户归属与精确 DTO 校验、相同 UUID 重试、文件大小边界（含无 Content-Length 流）、并发配额竞争、非法路径/类型/图片拒绝、Office/ZIP/音频不透明下载、富文本与私有图片引用、新日期及重复字段、v1 数据及回执兼容、数据库与附件组合备份恢复等测试。

在现有本机演示服务升级前，使用一致备份保存了 v1 数据库；迁移前后原始 users=3、entities=2、changes=6、mutations=7 数量完全相同，schema 从 1 升为 2。该演示实例已运行 v2，原账号与任务保留。临时签名密钥轮换后保存在 workspace 的私有 runtime 配置中，不出现在交付包或测试输出里。

对实际 `127.0.0.1:50267` HTTP 服务上传了 **3,245,457 字节 PNG** 和 **3,750,000 字节文本附件**，均超过 JSON 接口的 2 MiB 上限但低于附件上限。验证了：重试不重复计费、设备 2 拉取完整 richContent/附件元数据并下载相同 SHA-256 的文件、无认证返回 401、其他账户下载返回 404、伪造同步引用返回 422、删除任务后历史附件仍可读取。脚本只创建随机测试账号及合成文件，结尾注销测试会话。

Flutter 的示例缓存、重新进入示例后读取/保存、上传成功前不产生任务元数据、丢失响应后同文件重试复用 ID、账号切换不可读取前账号缓存、下载校验失败不缓存、离线已有附件可读及新上传明确报错均通过自动化测试。文件选择/保存系统对话框与 Web IndexedDB 的交互由最终 UI 验收覆盖；自动化测试使用可注入 picker 与 bytes store，未声称其替代了真实系统对话框验证。

预览代理回归使用随机回环端口及临时 HTTP 线程，测试结束全部关闭，未触碰现有 8080 服务。验证了重复 PreviewServer 绑定失败、带 SO_REUSEADDR 的第二个 socket 仍不能占用端口、Windows SO_EXCLUSIVEADDRUSE 已启用、超过 2 MiB 的附件及恰好 10 MiB 附件完整透传、超限请求在读取正文前返回 413 且不访问上游、JSON 恰好 2 MiB 允许而超过则 413，以及二进制内容和 Content-Disposition 保持原样。

当前运行的 8080 预览进程在实测中仍对 3.24 MiB 附件返回 413，源码修复尚未在该进程生效。已获用户重启许可，但停止并重启已核对进程的操作被自动审批拒绝，未给出具体原因；未重复或绕过该拒绝。50267 API 的大附件实测通过，8080 大附件使用需待预览进程正常重启后验证。
