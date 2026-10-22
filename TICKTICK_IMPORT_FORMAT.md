# 滴答清单 / TickTick CSV 备份导入格式

核对日期：2026-10-22。解析实现：`client/lib/core/ticktick_import.dart`。全部解析在客户端进行，不请求滴答清单账户、不执行正文 HTML、不访问附件 URL。

## 格式证据

- [TickTick 官方备份说明](https://help.ticktick.com/articles/7055781405648748544)：网页头像 → 设置 → 账户 → 备份与导入，生成备份后选择该文件。
- [TickTeam 官方旧版导出指南](https://github.com/TickTeam/guide-tt/blob/master/how_to_generate_%26_import_data.md)：明确说明网页生成的是 CSV 文件。
- [实际 7.1 CSV 输出结构示例](https://gist.github.com/mitul45/5028226c709f2c6e555c40b28acdd565)：展示前导 Date/Version/多行 Status，以及 24 个列名、数字 taskId、parentId。它是第三方转换器作者提供的直接实现证据，并非官方格式规范。
- [CSV → CalDAV 转换器原始实现](https://gist.github.com/Terrance/0e21ef32801c846f07b28fc6fc3310e9)：交叉核对早期无 Kind 列的结构、优先级 0/1/3/5、▫ 未完成 / ▪ 已完成检查项标记。
- [另一导入器的原始说明](https://github.com/benbogart/TickTickToOmniFocus4)：交叉核对文件夹、清单、任务正文、标签、创建/完成日期和后续 Estimated Pomodoro 字段。
- [RFC 5545 重复规则](https://www.rfc-editor.org/rfc/rfc5545)：重复规则只在与日序行为等价时启用；未知参数绝不直接丢掉后启用较弱规则。

官方未发布固定版本 CSV 字段契约。程序按表头定位，不假定恰好跳过六行；支持旧版缺 Kind、新增未知列、英文及常见中文别名。测试 fixture 是根据上述格式独立制作的合成数据，不是用户实际导出文件。

## 输入与安全边界

- 最大 20 MiB、100,000 条非空逻辑记录；最多 100 列；列名最长 180 字符。
- UTF-8（含 BOM），以及带 BOM 的 UTF-16 LE/BE。无效编码、NUL、未闭合引号、异常引号导致整个预览失败，导入尚未开始。
- CSV 支持逗号分隔、双引号转义、带引号的换行、CRLF/LF/CR 和空行；不按物理行拆分正文。
- 单条原始字段不超过 100,000 Unicode 字符；原始行 JSON UTF-8 不超过 240 KiB，为服务器 256 KiB 元数据限制预留来源信息空间。
- 预览中的 `row` 是 CSV 非空逻辑记录序号（含前导元数据），不是带引号多行正文之后的物理文件行号。
- JSON 导入报告包含原始私密数据；应用提供下载和保留时应把它与任务数据同样保护。

## 字段映射

| CSV 字段 | 日序行为 |
| --- | --- |
| Title / Task Title / 标题 | 标题。空标题变成“未命名条目”并告知；超过 300 字符缩短显示，原文留存。 |
| Folder Name + List Name | 清单名显示为“文件夹 / 清单”，稳定清单 ID 包含两个独立名称，避免同名清单合并。没有文件夹的 Inbox / 收集箱 / 收件箱使用内置收集箱。 |
| Kind | NOTE 为笔记；TEXT/TASK/CHECKLIST 为任务。未知类型按任务保存并告知。 |
| Content | 保留原始 Markdown 文本并生成可编辑 Quill 文本 Delta，HTML 原样显示。正文摘要最长 20,000 字符，富文本最多 100,000 字符（含结尾换行）；完整原字段另行保留。 |
| Tags | 支持逗号/分号/换行分隔及 JSON 数组，去除前导 #；最多显示 20 个、每个 40 字符，超出内容保留并告知。 |
| Priority | 0→无，1→低，3→中，5→高。未知数值保留原值并告知。 |
| Status | 按备份 7.1 前导说明：0 Normal、1 Completed、2 Archived。1/2 都作为已完成保留，2 额外告知“归档/取消按已完成导入”，不删除历史数据。**这是 CSV 状态语义，不是 Open API 的数值映射。** |
| Start Date + Due Date | Start 映射日序日期，Due 映射结束日期；仅有一项时作为单日期。无效日期不被 DateTime 自动进位；逆序区间告知并保留原始字段。 |
| Is All Day | 全天保留 CSV 写明的年月日，不把 UTC 午夜转换成前一天。日期-only 输入也不产生时间。 |
| Is Floating | 保留原文墙上时间，不转换时区。 |
| Timezone | 使用内嵌 IANA 时区数据，将带偏移时间转换到原任务时区，包含夏令时；未知时区保留 CSV 墙上时间并告知。日序当前任务时间是固定本地显示时间，原时区保留供以后扩展。 |
| Completed Time | 转为 UTC 完成时间；没有时区的定时输入明确提示 fallback。 |
| Is Check list / Kind CHECKLIST | ▫/☐/- [ ] 未完成，▪/☑/- [x] 已完成。生成最多 200 项检查项，同时完整保留正文。 |
| taskId / parentId | 关联元数据保存原 ID、日序父任务 ID 及父标题。子任务以独立完整任务保留，避免降成一行检查项后丢失正文、日期和标签；当前不声称完整嵌套树体验。 |
| Reminder | 只有一个可等价表达的提前提醒才启用，如 -PT15M、-P1DT2H、零分钟。多提醒、正向/全天触发、不支持的规则留存并告知。 |
| Repeat | 见下文。 |
| Created Time / Order / Column Name / Column Order / View Mode / Estimated Pomodoro / 其他新增字段 | 保存到原始导入数据；没有对应日序行为的字段明确列出，避免无声丢弃。 |

每条任务持久化 `importData: Map<String,String>` 包含原始所有列，以及 `__source`、`__sourceAccount`、`__sourceId`、`__sourceParentId`、`__row`。父子匹配成功时补充 `__parentDayflowId` 和 `__parentTitle`。来源保留键与 CSV 自定义列重名时，CSV 列使用 `CSV:` 前缀避让，完整原始列名也保留在导入报告。重复列采用 `[2]` 等后缀保存；字段映射使用第一列。少列补空，多列以额外列保存。

## 重复导入标识

- UUID v5 namespace 隔离普通日序任务和滴答来源；来源账号名称参与 ID，所以两个滴答账号可以分别迁移。
- 非数字 taskId 作为源 ID。同一个源 ID 重新导入不会覆盖当前日序编辑。
- 数字 taskId 常是备份文件内行号，不能单独作为跨备份 ID。无真实 ID 时使用文件夹、清单、标题、类型、创建时间生成标识；排序、完成状态变化不会产生新任务。
- 同一文件内完全相同的身份字段按出现次序分开保留，并给出提示，避免将合法重复任务折叠为一条。
- 缺少真实 ID 的任务在改标题、移动清单后再次导出可能被视为新条目，预览会提前说明。这里不承诺 CSV 无条件跨版本双向同步。

## 重复规则边界

支持常见 DAILY、WEEKLY（星期集合）、MONTHLY（安全日期或第 N 个星期）、YEARLY（明确月份和安全日期）、INTERVAL、COUNT、UNTIL。UNTIL 为时间戳时先转换原任务时区；若最后截止时刻早于当天任务时刻，结束日向前一天，避免额外生成不该出现的一次。

COUNT 未包含已经执行的次数时，从当前条目起计数并告知。日序的每月日期会贴合月末，但标准 RRULE 的无效日期应跳过；因此每月 29/30/31 日、每年 2 月 29 日等无法保证等价的表达暂不自动启用。BYSETPOS、多个 RRULE、完成后重复、农历私有扩展、节假日私有扩展、未知字段、无起始日期等也保留原规则并告知，供用户在日序日期面板确认设置。

## CSV 本身不等于全部账户数据

图片/附件引用按原文保留，不自动下载远程文件；没有文件字节就不能恢复真实附件。习惯打卡、专注统计、评论、历史版本、清单权限、订阅日历和账户设置是否存在于 CSV 不可假定。未知列保全的含义是可查询/下载原始数据，**不代表已经实现了这些字段对应的业务功能**。

## 验证

`client/test/ticktick_import_test.dart` 的 27 项测试覆盖格式前导/BOM/UTF-16/多行/异常输入，稳定去重/来源隔离/父子关系，优先级/状态/检查项，日期区间/IANA 夏令时/全天/浮动时间，重复与提醒的保守转换，安全限额和原字段保全。

`client/test/fixtures/ticktick_backup_synthetic.csv` 的预期：5 条记录（1 笔记）、2 已完成、2 新清单、2 检查项、1 图片引用、1 父子关系。首条安排在 2026-10-22 09:00–10:30（Asia/Shanghai），周四重复，提前 15 分钟提醒。
