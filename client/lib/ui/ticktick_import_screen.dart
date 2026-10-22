import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../core/app_controller.dart';
import '../core/attachments.dart';
import '../core/models.dart';
import '../core/ticktick_import.dart';
import 'import_source_dialog.dart';
import 'calendar_view.dart' show dayflowAccent;

TickTickImportPreview _parseBackup((Uint8List, String, String) input) =>
    TickTickImport.parseBytes(
      input.$1,
      sourceName: input.$2,
      sourceAccount: input.$3,
    );

class TickTickImportScreen extends StatefulWidget {
  const TickTickImportScreen({
    super.key,
    required this.controller,
    this.pickBackupFile,
  });
  final AppController controller;
  final Future<PickedAttachment?> Function()? pickBackupFile;

  @override
  State<TickTickImportScreen> createState() => _TickTickImportScreenState();
}

class _TickTickImportScreenState extends State<TickTickImportScreen> {
  final account = TextEditingController(text: '个人');
  final search = TextEditingController();
  final scroll = ScrollController();
  late final int workspaceRevision;
  TickTickImportPreview? preview;
  TickTickImportResult? result;
  String? fileName;
  String? error;
  bool busy = false;
  bool onlyWarnings = false;
  AppController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    workspaceRevision = c.workspaceRevision;
  }

  @override
  void dispose() {
    account.dispose();
    search.dispose();
    scroll.dispose();
    super.dispose();
  }

  Future<void> pickBackup() async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final selected = await (widget.pickBackupFile ?? _pickCsv)();
      if (selected == null) return;
      final parsed = await compute(_parseBackup, (
        selected.bytes,
        selected.name,
        account.text.trim().isEmpty ? '个人' : account.text.trim(),
      ));
      if (!mounted) return;
      setState(() {
        preview = parsed;
        result = null;
        fileName = selected.name;
        search.clear();
        onlyWarnings = false;
      });
      _showTop();
    } catch (e) {
      if (mounted) {
        setState(() {
          error = e is FormatException ? e.message : '读取备份失败：$e';
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          busy = false;
        });
      }
    }
  }

  Future<PickedAttachment?> _pickCsv() async {
    final file = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: const ['csv'],
    );
    if (file == null) return null;
    const limit = 20 * 1024 * 1024;
    final length = file.lengthSync() ?? await file.length();
    if (length != null && length > limit) {
      throw const FormatException('备份文件超过 20 MiB，请按清单拆分后再导入。');
    }
    final buffer = BytesBuilder(copy: false);
    await for (final chunk in file.readAsByteStream()) {
      if (buffer.length + chunk.length > limit) {
        throw const FormatException('备份文件超过 20 MiB。');
      }
      buffer.add(chunk);
    }
    return PickedAttachment(file.name, buffer.takeBytes());
  }

  Future<void> importBackup() async {
    final data = preview;
    if (data == null || busy) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final imported = await c.importTickTick(
        data,
        expectedWorkspaceRevision: workspaceRevision,
      );
      if (mounted) {
        setState(() {
          result = imported;
        });
        _showTop();
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          error = '导入未完成：$e';
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          busy = false;
        });
      }
    }
  }

  Future<void> saveReport() async {
    try {
      await SystemAttachmentPicker().save(
        'dayflow-ticktick-import-report.json',
        Uint8List.fromList(
          utf8.encode(
            const JsonEncoder.withIndent('  ').convert({
              ...preview!.toReportJson(),
              if (result != null)
                'result': {
                  'importedTasks': result!.importedTasks,
                  'importedLists': result!.importedLists,
                  'skippedTasks': result!.skippedTasks,
                  'skippedLists': result!.skippedLists,
                },
            }),
          ),
        ),
      );
    } catch (e) {
      if (mounted) {
        setState(() {
          error = '保存报告失败：$e';
        });
      }
    }
  }

  void _showTop() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && scroll.hasClients) scroll.jumpTo(0);
    });
  }

  @override
  Widget build(BuildContext context) {
    final data = preview;
    final existing = c.knownTaskIds;
    final duplicates =
        data?.tasks.where((e) => existing.contains(e.id)).length ?? 0;
    final filtered =
        data?.records
            .where(
              (r) =>
                  (!onlyWarnings || r.warnings.isNotEmpty) &&
                  ('${r.task.title}\n${r.task.notes}\n${r.listName}'
                      .toLowerCase()
                      .contains(search.text.toLowerCase())),
            )
            .toList() ??
        [];
    return PopScope(
      canPop: !busy,
      child: Scaffold(
        appBar: AppBar(
          title: const Text(
            '从滴答清单导入',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
          ),
          automaticallyImplyLeading: !busy,
        ),
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 920),
            child: ListView(
              controller: scroll,
              padding: const EdgeInsets.fromLTRB(24, 14, 24, 32),
              children: [
                Text(
                  c.demoMode ? '导入到独立体验空间' : '导入到 ${c.user?.email ?? "当前离线空间"}',
                  style: const TextStyle(
                    fontSize: 13,
                    color: Color(0xFF6C7B7E),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  result != null
                      ? '数据已保存'
                      : data != null
                      ? '核对备份，确认后导入'
                      : '把清单与记录带到日序',
                  style: const TextStyle(
                    fontSize: 25,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 12),
                if (data == null) ...[
                  const Text(
                    '在滴答清单 Web 端打开「头像 → 设置 → 账户与安全 → 备份与还原」，生成并下载 CSV 备份，然后在这里选择文件。',
                    style: TextStyle(height: 1.8),
                  ),
                  const SizedBox(height: 20),
                  const _Info(
                    '可迁移备份中的任务、笔记、清单、正文、日期、标签、优先级、已完成状态、检查项和可识别的重复规则。先预览，再导入。',
                  ),
                  const SizedBox(height: 12),
                  const _Info(
                    'CSV 没有提供的图片／附件文件、习惯打卡、专注记录和评论无法凭空恢复。未完整转换的字段会提示，并保留导入原文；文件夹按清单路径呈现，父子任务保留来源关系。',
                  ),
                  const SizedBox(height: 24),
                  TextField(
                    controller: account,
                    enabled: !busy,
                    maxLength: 80,
                    decoration: const InputDecoration(
                      labelText: '滴答账号标记',
                      helperText: '同一滴答账号保持同一标记，以便识别重复；导入另一个账号时请更换。',
                    ),
                  ),
                  const SizedBox(height: 16),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: FilledButton.icon(
                      onPressed: busy ? null : pickBackup,
                      icon: const Icon(Icons.file_upload_outlined, size: 18),
                      label: const Text('选择滴答备份 CSV'),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    c.demoMode
                        ? '体验空间的数据仅保存在本机，不会随登录转入账号。正式迁移请先登录。'
                        : '文件在本机解析；确认导入后，任务会进入当前账号的同步队列。',
                    style: const TextStyle(
                      fontSize: 12,
                      color: Color(0xFF7D898C),
                      height: 1.7,
                    ),
                  ),
                ],
                if (data != null) ...[
                  Text(
                    fileName ?? '',
                    style: const TextStyle(
                      color: Color(0xFF7D898C),
                      fontSize: 12,
                    ),
                  ),
                  const SizedBox(height: 16),
                  if (result != null)
                    _Info(
                      '新增 ${result!.importedTasks} 条任务／笔记、${result!.importedLists} 个清单；跳过 ${result!.skippedTasks} 条已导入记录。${c.demoMode ? "数据保存在本机体验空间。" : "数据已保存到本机，云同步状态可在侧栏查看。"}',
                    )
                  else
                    _Info(
                      '${data.tasks.length} 条任务／笔记 · ${data.lists.length} 个清单 · ${data.tasks.where((t) => t.completed).length} 条已完成\n其中 $duplicates 条已存在，将跳过；已有内容不会被覆盖。',
                    ),
                  const SizedBox(height: 12),
                  if (data.warnings.isNotEmpty)
                    ExpansionTile(
                      tilePadding: EdgeInsets.zero,
                      title: Text(
                        '需要留意 · ${data.warnings.length} 条提示',
                        style: const TextStyle(fontSize: 14),
                      ),
                      subtitle: const Text(
                        '原始字段会保留，可在任务「更多 → 查看导入原文」查看。',
                        style: TextStyle(fontSize: 11),
                      ),
                      children: [
                        for (final warning in data.warnings.take(100))
                          ListTile(
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            leading: const Icon(Icons.info_outline, size: 17),
                            title: Text(
                              '${warning.row == null ? "备份" : "第 ${warning.row} 行"} · ${warning.message}',
                              style: const TextStyle(fontSize: 12),
                            ),
                          ),
                        if (data.warnings.length > 100)
                          const Text('更多提示见完整导入报告。'),
                      ],
                    ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      if (result == null)
                        FilledButton.icon(
                          onPressed: busy || data.tasks.isEmpty
                              ? null
                              : importBackup,
                          icon: const Icon(Icons.download_done, size: 18),
                          label: Text(
                            duplicates == data.tasks.length
                                ? '确认导入（跳过重复）'
                                : '确认导入 ${data.tasks.length - duplicates} 条',
                          ),
                        ),
                      if (result != null)
                        FilledButton(
                          onPressed: () => Navigator.pop(context, true),
                          child: const Text('查看导入内容'),
                        ),
                      OutlinedButton(
                        onPressed: busy ? null : saveReport,
                        child: const Text('保存完整报告'),
                      ),
                      TextButton(
                        onPressed: busy
                            ? null
                            : () => setState(() {
                                preview = null;
                                result = null;
                                error = null;
                              }),
                        child: const Text('重新选择'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),
                  const Divider(),
                  const SizedBox(height: 16),
                  TextField(
                    controller: search,
                    onChanged: (_) => setState(() {}),
                    decoration: const InputDecoration(
                      hintText: '搜索备份中的标题、正文或清单',
                      prefixIcon: Icon(Icons.search),
                    ),
                  ),
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    value: onlyWarnings,
                    onChanged: (v) => setState(() {
                      onlyWarnings = v!;
                    }),
                    title: const Text(
                      '仅查看有提示的记录',
                      style: TextStyle(fontSize: 12),
                    ),
                  ),
                  for (final record in filtered.take(100))
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(
                        record.task.itemType == 'note'
                            ? Icons.article_outlined
                            : record.task.completed
                            ? Icons.check_circle_outline
                            : Icons.circle_outlined,
                        size: 19,
                        color: dayflowAccent,
                      ),
                      title: Text(
                        record.task.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 14),
                      ),
                      subtitle: Text(
                        '${record.listName}${record.task.dueDate == null ? "" : " · ${calendarDate(record.task.dueDate)}"}${existing.contains(record.task.id) ? " · 已存在" : ""}${record.warnings.isEmpty ? "" : " · 有转换提示"}',
                        style: const TextStyle(fontSize: 11),
                      ),
                      trailing: const Icon(Icons.chevron_right, size: 18),
                      onTap: () => showImportSourceDialog(
                        context,
                        record.task.importData,
                      ),
                    ),
                  if (filtered.length > 100)
                    Text(
                      '显示前 100 条，共 ${filtered.length} 条。可搜索其余记录，全部记录均会导入。',
                      style: const TextStyle(fontSize: 12),
                    ),
                ],
                if (busy)
                  const Padding(
                    padding: EdgeInsets.only(top: 20),
                    child: LinearProgressIndicator(),
                  ),
                if (error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 16),
                    child: SelectableText(
                      error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Info extends StatelessWidget {
  const _Info(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: const Color(0xFFF0F7F7),
      borderRadius: BorderRadius.circular(10),
    ),
    child: Text(
      text,
      style: const TextStyle(
        fontSize: 13,
        height: 1.8,
        color: Color(0xFF51676A),
      ),
    ),
  );
}
