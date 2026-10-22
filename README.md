# 日序 Dayflow

一个用 Flutter 实现的清单与月历应用，面向 **Windows、Web、Android 和 iOS**，配套可自行部署的账号与云同步服务。

本项目是独立实现，使用自己的账号、数据和服务器。源码没有包含滴答清单的专有代码、品牌素材或会员解锁逻辑，也不会连接或修改滴答清单账户。月历是本应用的基础功能。

## 1.2 新增：从滴答清单迁移

进入「左下角账号与同步 → 从滴答清单导入」，选择滴答清单 Web 端生成的 CSV 备份：

1. 在滴答清单 Web 端打开「头像 → 设置 → 账户与安全 → 备份与还原 → 生成备份」。[官方操作说明](https://help.dida365.com/articles/6950670128287580160)
2. 日序中先登录自己的账号；也可在独立体验空间试导入，体验数据不会随登录转入账号。
3. 选择 CSV、查看任务/笔记/已完成数量、搜索预览和转换提示，再点击「确认导入」。同一滴答账号请始终使用同一账号标记；重复导入跳过已存在及已删除的记录，不覆盖后续编辑。
4. 导入后按日序原有流程云同步。任务右下角「更多 → 查看导入原文」可查阅和保存原始字段；完整报告可在导入页下载。

支持清单、标题、正文、日期与时间段、时区、标签、优先级、完成历史、笔记、检查项、可识别的重复规则与提醒。文件夹以「文件夹 / 清单」路径呈现；具有独立正文的子任务保留为独立任务并记录父任务关联。正文 Markdown 保留原文。无法映射的规则会明确提示，原字段随任务保留和同步。

**导入范围由备份内容决定**：CSV 中未包含的附件/图片文件、习惯打卡、专注记录、评论、历史版本和设置不能恢复；附件引用会保留，可另行上传文件。CSV 不带稳定任务 ID 时使用内容身份，改名或移动清单后重新导出可能被视为新条目。格式说明、支持矩阵及边界见 [导入格式](TICKTICK_IMPORT_FORMAT.md)。

单次上限 20 MiB / 100,000 条。先完整解析，再一次写入本机；失败不会留下半份导入。Web 工作区使用 IndexedDB，原本的 localStorage 数据自动迁移，支持超过 5 MiB 的备份工作区。

代码仓库：[DengYuncheng27/daily_list](https://github.com/DengYuncheng27/daily_list)。

## 已实现的清单与日历功能

- 中心上方快速添加，右侧小日历入口；Enter 连续添加，Shift+Enter 添加并展开详情。
- 桌面常驻右侧详情，可拖动调整宽度；手机详情单独展开。内容自动保存，也支持 `Ctrl / ⌘ + Enter` 立即保存。
- 日期/时间段弹层、快捷日期、时间、提醒、复杂重复；日历显示 2026 年法定休假与调休补班标记。
- 每日、每周多星期、每月日期/第 N 个星期、每年、工作日/节假日、农历、艾宾浩斯、自选日期；支持间隔、计算基准和终止规则。完成后生成下一次。
- 任务与笔记、富文本、Markdown 快捷输入、`/` 命令、标题/列表/引用/代码/链接；图片嵌入和真实文件附件上传下载。
- 月历与当天任务；桌面拖动改期，跨日时间段整体平移；手机可选择日期查看当天安排。
- 今天（含逾期）、最近 7 天、全部、笔记、已完成、清单和标签；搜索、分组排序、右键、多选批量操作。
- 优先级、标签、子任务；保存失败保留草稿，切换任务、登录或退出前处理未保存修改。
- 邮箱与密码注册、登录；账号数据隔离；多设备增量同步、离线编辑、冲突选择。
- 独立体验空间，无需账号即可试用。体验数据不会自动上传到登录后的账号。
- 中文界面、适配手机与桌面的布局、自带 Noto Sans SC 字体和应用图标。

提醒目前是**应用开启时的应用内提醒**，不是后台推送；关闭应用或暂停浏览器标签页后不能保证准时提醒。邮箱目前用作登录名，没有邮箱所有权验证、忘记密码邮件或多因素认证。

详细的截图拆解、交互步骤、验收重点及未完成部分见 [交互对照](INTERACTION_REVIEW.md)。目前不提前在月历铺开全部未来重复实例；法定调休仅支持已核对的 2026 年；富文本外部剪贴板粘贴在 Web 上有编辑器限制。

附件默认单文件 10 MiB、每账号 100 MiB；新附件上传需要联网，下载需要本账号认证。本地体验空间的附件单独保存。服务器备份需同时包含数据库与附件，使用新增的 `dayflow.backup_bundle`，详见服务端说明。

## 目录

```text
dayflow/
├─ client/                  Flutter 应用与四个平台工程
│  ├─ lib/core/             模型、账号、存储、同步与重复任务
│  ├─ lib/ui/               快速录入、日期弹层、月历、列表与富文本编辑器
│  ├─ test/                 核心逻辑与界面回归
│  └─ assets/fonts/         随应用打包的中文字体与许可
├─ server/                  Python FastAPI + SQLite 后端
│  ├─ dayflow/              API、认证、数据库与备份工具
│  ├─ tests/                后端回归
│  └─ tools/e2e_sync.py     真实 HTTP 双设备同步与附件检查
├─ deploy/                  Docker Compose、Caddy 与环境配置示例
├─ scripts/preview.py       本机 Web 静态预览与同源 API 代理
├─ tools/generate_icons.py  应用图标生成源
├─ .github/workflows/ci.yml  测试与四端构建工作流
└─ API_CONTRACT.md          客户端与服务端接口约定
```

## 本机启动

客户端使用 **Flutter 3.47.7 / Dart 3.13.5**。将 Flutter 加入 `PATH`，先执行 `flutter doctor -v` 确认对应平台工具链。后端使用 Python 3.11 或 3.12。

先按 [服务端说明](server/README.md#本地运行) 启动 API，常用地址为 `http://127.0.0.1:8000`。服务首次使用时需要允许注册，应用不预置账号或默认密码。

在 `client` 目录安装依赖并构建 Web：

```sh
flutter pub get
flutter build web --release
```

回到 `dayflow` 根目录启动本机预览：

```sh
python scripts/preview.py --port 8080 --api http://127.0.0.1:8000
```

在浏览器打开 [本机预览](http://127.0.0.1:8080)，可选择“先体验一下”，也可以注册自己的账号。预览脚本把 `/api/` 转发到 `--api` 指定的服务，其他路径读取 `client/build/web`。API 使用其他端口时只需修改 `--api`。

该脚本只监听 `127.0.0.1`，用于本机预览。对外部署使用下文的 Caddy 配置。

### 本次开发电脑的预览状态

页面在 `http://127.0.0.1:8080/`，API 在 `http://127.0.0.1:50267`。页面会读取最新 Web 构建；API 已升级且保留旧数据。

本地预览已恢复，代理支持单文件 10 MiB，与默认 API 上限一致。手动启动命令：

```powershell
python scripts/preview.py --port 8080 --api http://127.0.0.1:50267
```

脚本使用排他端口绑定；若其他进程占用端口会明确报错，避免多个预览混用同一端口。

## 服务器地址

登录/注册页展开“服务器地址”即可填写 API origin，例如 `https://tasks.example.com`。客户端会自动追加 `/api/v1`；地址不应带 API 路径、查询参数或账号密码。

也可以在运行或构建时设置默认值：

```sh
flutter run -d windows --dart-define=API_BASE_URL=http://127.0.0.1:8000
flutter build web --release --dart-define=API_BASE_URL=https://tasks.example.com
```

| 场景 | 地址 |
|---|---|
| Windows 客户端访问同机 API | `http://127.0.0.1:8000` |
| Android 模拟器访问宿主机 API | `http://10.0.2.2:8000`，用于开发调试 |
| 手机真机、另一台电脑 | 能访问到的 HTTPS 服务域名 |
| Web release 未设置 `API_BASE_URL` | 默认使用网页当前 origin |

生产 Web 推荐页面与 API 使用同一个 HTTPS 域名，Caddy 将 `/api/` 代理给后端。若页面和 API 分开部署，需要在 `DAYFLOW_ALLOWED_ORIGINS` 中填写精确的网页 origin。手机上的 `127.0.0.1` 指手机自身，不能用它访问电脑或远端服务器。

## 四端构建

下面命令都在 `client` 目录执行。构建工程已提供；模拟器、真机安装、正式签名和商店发布需要各平台工具与账号。

### Windows

需要 Windows 和 Visual Studio 的“使用 C++ 的桌面开发”工作负载。

```powershell
flutter pub get
flutter run -d windows
flutter build windows --release --dart-define=API_BASE_URL=https://tasks.example.com
```

产物位于 `build/windows/x64/runner/Release/`。分发时保留整个目录中的 EXE、DLL 和 `data` 文件夹；不能只复制 EXE。运行环境需要 Windows x64 与 Microsoft Visual C++ 2015–2022 x64 运行库。

### Web

```sh
flutter build web --release
```

部署 `build/web/` 的完整内容。默认 origin 机制适合本文提供的同域部署。使用 `flutter run -d chrome` 做开发调试时，确保 API 的 CORS 配置与调试网页 origin 一致。

### Android

需要 Android SDK 与兼容的 JDK；CI 使用 JDK 21。先在 `flutter doctor -v` 中确认 Android 工具链与 SDK 许可。

```sh
flutter build apk --debug --dart-define=API_BASE_URL=https://tasks.example.com
```

调试安装包位于 `build/app/outputs/flutter-apk/app-debug.apk`。CI 的 Android 构建也生成调试 APK。

正式分发前，在 `android/app/build.gradle.kts` 配置自己的 application ID、keystore 与 release 签名，再构建 release APK 或 AAB。当前 release 配置仍引用开发用 debug 签名，不能把它当作正式发布签名。

### iOS

iOS 编译需要 **macOS、Xcode 和对应 iOS SDK**，不能在这台 Windows 主机上完成。模拟器可先进行无签名编译：

```sh
flutter pub get
flutter build ios --simulator --debug --no-codesign --dart-define=API_BASE_URL=https://tasks.example.com
```

模拟器产物位于 `build/ios/iphonesimulator/Runner.app`。真机安装、TestFlight 或 App Store 发布，需要在 Xcode 中设置自己的 Bundle Identifier、Development Team、证书与 provisioning profile；模拟器构建不验证这些发布配置。

## 本地数据与云同步

首次登录需要联网。登录后的任务与待提交修改会保存在本机，短暂断网时可以继续编辑；网络恢复并且登录状态有效时继续同步。应用也会在前台定期拉取其他设备的修改。

缓存按**服务器和账号**区分；退出后不会展示上个账号的任务。未同步编辑保留在该账号本地缓存中，下次登录同一服务器上的同一账号后继续提交。清除应用数据或浏览器站点数据会清除本机缓存，所以离线修改应在清除前完成同步。

原生端的 refresh token 使用系统安全存储；Web 的登录 token 只保留在当前应用进程内存中。**重新打开网页或刷新后，需要重新登录才能继续云同步**；已有任务缓存仍可查看和编辑。任务正文缓存本身不是端到端加密存储。

同步采用实体版本号、持久化待提交队列和幂等请求。同一个任务在两台离线设备上都被修改时，应用会显示冲突，让你选择“这台设备”或“服务器上的版本”，不会自动用其中一份覆盖另一份。详情见 [接口约定](API_CONTRACT.md) 和 [服务端同步语义](server/README.md#同步语义)。

## 自托管部署

API 使用 FastAPI 与 SQLite，当前部署形态是**单 API 实例、单 worker、持久化数据卷**。

完整 Web + API 部署使用：

- [deploy/compose.yml](deploy/compose.yml)：API、Caddy 和持久化卷。
- [deploy/Caddyfile](deploy/Caddyfile)：HTTPS、Web 静态文件与同源 `/api/` 代理。
- [deploy/.env.example](deploy/.env.example)：域名、随机服务密钥和注册开关示例。
- [server/README.md](server/README.md)：配置项、API 单独部署、账户行为、备份与恢复。

先完成 Web release 构建，将部署环境配置保存为 `deploy/.env`，填写实际域名和随机密钥，然后从 `dayflow` 根目录启动：

```sh
docker compose --env-file deploy/.env -f deploy/compose.yml up -d --build
```

Caddy 需要域名已解析到服务器，且服务器允许 80/443 入站。首次注册后可关闭公开注册。部署前按服务端文档设置持久化与备份；SQLite 运行中的一致备份应使用附带的 backup 工具。

只需要 API 时可使用 `deploy/compose.api.yml`，具体参数见服务端文档。本次交付没有连接或部署到你的外部服务器。

## 检查与 CI

本机检查命令：

```sh
# client 目录
flutter analyze
flutter test

# server 目录
python -m pip install -r requirements-dev.txt
python -m pytest -q
```

当前验证记录：

| 检查 | 结果 |
|---|---|
| 全库 Dart 静态检查 | `dart analyze` 通过，No issues found |
| Flutter 核心逻辑与 UI 测试 | 123 项通过；依赖本地服务的 1 项 HTTP 测试默认跳过，本轮已另行运行通过。涵盖 CSV 导入、失败回滚、原文保全、存储迁移、编辑与日期 |
| UI 布局与流程 | 覆盖 320×640、390×844、932×900、1024×768、1440×900；含日期弹层、自动保存竞态、任务/笔记转换、附件归属、多选、登录与退出 |
| 后端 pytest | 75 项通过 |
| 实际 HTTP 双设备同步检查 | 既有 9 项通过；本轮新增 503 条 CSV 导入跨设备字段一致、重复跳过、编辑后同步；附件另有大图与文本下载哈希和越权检查 |
| 本地预览代理回归 | 7 项通过，覆盖大小边界、二进制透传与 Windows 排他绑定 |
| Web 升级/离线启动模拟 | Node 10 项通过，覆盖旧/新 Worker 同 URL、等待接管、离线、失败和超时 |
| Windows release 构建 | 已在本机通过 |
| Web release 构建与浏览器操作 | 已通过；真实正文输入、图片文件选择、自动保存、刷新恢复图文已核对；账号及任务持久化另有实际 API 验证 |
| Web 离线启动 | Chrome 首次完整打开并保存任务后，停止独立 Web 源站再刷新，月历、中文字体与已保存任务仍显示；未覆盖 Safari |
| Android 构建 | 通用 debug APK 已编译，签名验证通过；未在实体手机运行 |
| iOS 原生构建 | 未在本机执行，需要 macOS |
| Docker Compose 配置 | `docker compose config --quiet` 通过；本机 Docker daemon 未运行，镜像和容器尚未实跑 |
| GitHub Actions | 已提供工作流；远程运行结果以仓库 Actions 页面为准 |

后端详细记录见 [server/VERIFICATION.md](server/VERIFICATION.md)。

本轮独立子 agent 的浏览器体验、修复与复测见 [QA 记录](qa/QA_REPORT.md)，包含桌面/手机导入、真实文件选择与报告下载、重复跳过、原文与离线持久化。修复了连续 Enter 添加失灵、隐藏已完成项被键盘误选，以及读取缓存失败后可能覆盖旧数据的问题。

在 Web、Windows、Android 都完成构建后，可从项目根目录运行 `python scripts/package.py`。它在 `releases/` 生成源码压缩包、Windows 完整运行目录、Web 静态文件包、Android 调试 APK 和 SHA-256 清单；源码包排除本机 SDK、构建缓存、数据库、环境密钥和绝对路径配置。部署预编译 Web 包时，将其内容解压到 `client/build/web/`，再运行 Compose。

[CI 工作流](.github/workflows/ci.yml) 在推送、拉取请求或手动触发时运行 Python 测试、Flutter 静态检查/测试，以及 Windows、Web、Android debug、iOS simulator 无签名构建。构建产物保存在该次 GitHub Actions 的 artifacts 中，默认保留 14 天。工作流不部署服务，不使用生产账号或签名秘密；配置文件本身不代表四端构建已经在 CI 通过。

CI 使用的 action 配置参考维护者文档：[Flutter action](https://github.com/subosito/flutter-action)、[GitHub checkout](https://github.com/actions/checkout)、[artifact upload](https://github.com/actions/upload-artifact)、[Python setup](https://github.com/actions/setup-python)、[Java setup](https://github.com/actions/setup-java)。

## 字体与素材

中文字体 Noto Sans SC 随应用打包，许可为 SIL Open Font License，见 [client/assets/fonts/OFL.txt](client/assets/fonts/OFL.txt)。应用图标的生成源在 `tools/generate_icons.py`；项目不依赖滴答清单的图片、图标或其他专有素材。
