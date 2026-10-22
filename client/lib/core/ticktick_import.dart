import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;
import 'package:uuid/uuid.dart';

import 'models.dart';

class TickTickImportException implements Exception {
  final String message;
  const TickTickImportException(this.message);
  @override
  String toString() => message;
}

class TickTickImportWarning {
  final String code;
  final String message;
  final int? row;
  const TickTickImportWarning(this.code, this.message, {this.row});
  Map<String, dynamic> toJson() => {
    'code': code,
    'message': message,
    if (row != null) 'row': row,
  };
}

class TickTickImportRecord {
  final TaskItem task;
  final int row;
  final String sourceId;
  final String sourceParentId;
  final String folderName;
  final String listName;
  final Map<String, String> rawFields;
  final List<TickTickImportWarning> warnings;
  const TickTickImportRecord({
    required this.task,
    required this.row,
    required this.sourceId,
    required this.sourceParentId,
    required this.folderName,
    required this.listName,
    required this.rawFields,
    required this.warnings,
  });
  Map<String, dynamic> toJson() => {
    'dayflowId': task.id,
    'row': row,
    'sourceId': sourceId,
    'sourceParentId': sourceParentId,
    'folderName': folderName,
    'listName': listName,
    'rawFields': rawFields,
    'warnings': warnings.map((w) => w.toJson()).toList(),
  };
}

class TickTickImportPreview {
  final String sourceName;
  final String sourceAccount;
  final String fileSha256;
  final List<ProjectList> lists;
  final List<TickTickImportRecord> records;
  final List<TickTickImportWarning> warnings;
  final Map<String, String> metadata;
  const TickTickImportPreview({
    required this.sourceName,
    required this.sourceAccount,
    required this.fileSha256,
    required this.lists,
    required this.records,
    required this.warnings,
    required this.metadata,
  });
  List<TaskItem> get tasks => records.map((r) => r.task).toList();
  int get completedCount => records.where((r) => r.task.completed).length;
  int get noteCount => records.where((r) => r.task.itemType == 'note').length;
  int get checklistCount =>
      records.fold(0, (n, r) => n + r.task.subtasks.length);
  int get attachmentReferenceCount =>
      warnings.where((w) => w.code == 'attachment_reference').length;
  Map<String, dynamic> toReportJson() => {
    'format': 'dayflow.ticktick-import-report.v1',
    'sourceName': sourceName,
    'sourceAccount': sourceAccount,
    'fileSha256': fileSha256,
    'metadata': metadata,
    'counts': {
      'tasks': records.length,
      'lists': lists.length,
      'notes': noteCount,
      'completed': completedCount,
      'checklistItems': checklistCount,
      'attachmentReferences': attachmentReferenceCount,
    },
    'warnings': warnings.map((w) => w.toJson()).toList(),
    'records': records.map((r) => r.toJson()).toList(),
  };
}

/// Parses an exported backup locally. Never fetches attachment URLs or logs data.
/// See TICKTICK_IMPORT_FORMAT.md for the source schema and deliberate fallbacks.
abstract final class TickTickImport {
  static const maxBytes = 20 * 1024 * 1024;
  static const maxRows = 100000;
  static const _namespace = '450749c9-f12a-5ebc-bad1-ce8079d7713a';
  static bool _zonesReady = false;

  static TickTickImportPreview parseBytes(
    List<int> bytes, {
    String sourceName = '',
    String sourceAccount = 'default',
  }) {
    if (bytes.isEmpty) {
      throw const TickTickImportException('备份文件为空。');
    }
    if (bytes.length > maxBytes) {
      throw const TickTickImportException('备份文件超过 20 MiB，请拆分后导入。');
    }
    if (sourceAccount.trim().isEmpty || sourceAccount.length > 100) {
      throw const TickTickImportException('来源账号标识须为 1–100 个字符。');
    }
    final text = _decode(bytes);
    if (text.contains('\u0000')) {
      throw const TickTickImportException('文件含无效空字符，请选择滴答清单导出的 CSV 备份。');
    }
    final rows = _csv(text);
    var headerIndex = -1;
    for (var i = 0; i < rows.length && i < 64; i++) {
      final keys = rows[i].map(_key).toSet();
      if (keys.contains('title') && rows[i].length > 1) {
        headerIndex = i;
        break;
      }
    }
    if (headerIndex < 0) {
      throw const TickTickImportException('未找到滴答清单 CSV 表头，需要包含 Title（标题）等列。');
    }
    final headers = rows[headerIndex];
    if (headers.length > 100 || headers.any((h) => h.runes.length > 180)) {
      throw const TickTickImportException('CSV 列数超过 100 或列名超过 180 字符，无法安全导入。');
    }
    final body = rows.sublist(headerIndex + 1);
    if (body.length > maxRows) {
      throw const TickTickImportException('备份超过 100,000 条记录，请拆分后导入。');
    }
    final warnings = <TickTickImportWarning>[
      const TickTickImportWarning(
        'backup_scope',
        'CSV 只能恢复文件实际包含的数据；附件和图片文件、习惯打卡、专注统计、评论、历史版本及账户设置不保证包含。附件引用会保留，但不会自动下载。',
      ),
    ];
    final metadata = <String, String>{};
    for (var i = 0; i < headerIndex; i++) {
      metadata['preamble${i + 1}'] = rows[i].join(',');
    }
    final duplicates = <String, int>{};
    final usedHeaders = <String>{};
    final uniqueHeaders = <String>[];
    for (var i = 0; i < headers.length; i++) {
      final original = headers[i].trim().isEmpty
          ? 'Column ${i + 1}'
          : headers[i];
      var name = original;
      var n = 2;
      while (!usedHeaders.add(name)) {
        name = '$original [$n]';
        n++;
      }
      if (name != original) {
        warnings.add(
          TickTickImportWarning(
            'duplicate_header',
            '重复列「$original」已完整保留，字段映射使用第一列。',
          ),
        );
      }
      uniqueHeaders.add(name);
    }
    final lists = <String, ProjectList>{};
    final records = <TickTickImportRecord>[];
    var fallbackIdentity = false;
    for (var i = 0; i < body.length; i++) {
      final cells = body[i];
      final row = headerIndex + i + 2;
      final raw = <String, String>{};
      final values = <String, String>{};
      final localWarnings = <TickTickImportWarning>[];
      void warn(String code, String message) =>
          localWarnings.add(TickTickImportWarning(code, message, row: row));
      for (var c = 0; c < headers.length; c++) {
        raw[uniqueHeaders[c]] = c < cells.length ? cells[c] : '';
        values.putIfAbsent(
          _key(headers[c]),
          () => c < cells.length ? cells[c] : '',
        );
      }
      if (cells.length != headers.length) {
        warn(
          'column_count',
          '此行有 ${cells.length} 列，表头有 ${headers.length} 列；缺失列按空值处理，多余列保留在原始数据中。',
        );
        for (var c = headers.length; c < cells.length; c++) {
          raw['Extra column ${c + 1}'] = cells[c];
        }
      }
      if (raw.length > 100 ||
          utf8.encode(jsonEncode(raw)).length > 240 * 1024 ||
          raw.values.any((v) => v.runes.length > 100000)) {
        throw TickTickImportException(
          '第 $row 行原始数据过大（最多 100 列、每字段 100,000 字符、每行 240 KiB），请拆分该条目后重试。文件尚未导入。',
        );
      }
      String get(String key) => values[key]?.trim() ?? '';
      final title = get('title');
      final folder = get('folder');
      final listName = get('list');
      final sourceId = get('id');
      final parentId = get('parent');
      final kind = get('kind').toUpperCase();
      final itemType = kind == 'NOTE' || kind == '笔记' ? 'note' : 'task';
      if (kind.isNotEmpty &&
          !['TEXT', 'TASK', 'NOTE', 'CHECKLIST', '任务', '笔记'].contains(kind)) {
        warn('unknown_kind', '未知条目类型「$kind」按任务导入，原类型已保留。');
      }
      final stableId =
          sourceId.isNotEmpty && !RegExp(r'^\d+$').hasMatch(sourceId);
      final identity = stableId
          ? 'id:$sourceId'
          : 'fallback:${jsonEncode([folder, listName, title, kind, get('created')])}';
      if (!stableId) fallbackIdentity = true;
      final occurrence = duplicates.update(
        identity,
        (v) => v + 1,
        ifAbsent: () => 0,
      );
      if (occurrence > 0) {
        warn('duplicate_identity', '备份中存在相同来源标识的条目，已分别保留；重复导入仍按稳定顺序去重。');
      }
      final id = _id(sourceAccount, 'task:$identity:$occurrence');
      final isInbox =
          folder.isEmpty &&
          (listName.isEmpty ||
              ['inbox', '收集箱', '收件箱'].contains(listName.toLowerCase()));
      final listId = isInbox
          ? 'inbox'
          : _id(sourceAccount, 'list:${jsonEncode([folder, listName])}');
      if (!isInbox) {
        final fullName = [
          if (folder.isNotEmpty) folder,
          listName.isEmpty ? '未命名清单' : listName,
        ].join(' / ');
        lists.putIfAbsent(
          listId,
          () => ProjectList(
            id: listId,
            name: _cut(fullName, 100),
            color: 0xFF55ADB1,
          ),
        );
        if (fullName.runes.length > 100) {
          warn('list_name_length', '清单路径超过 100 字符，显示名称已缩短，原始文件夹和清单名已保留。');
        }
        if (folder.isNotEmpty) {
          warn('folder_flattened', '文件夹以「文件夹 / 清单」路径显示，原始层级名称已保留。');
        }
      }
      if (title.isEmpty) warn('missing_title', '空标题条目已保留为「未命名条目」。');
      if (title.runes.length > 300) {
        warn('title_length', '标题超过 300 字符，显示标题已缩短，原文已保留。');
      }
      final allDayValue = get('allDay');
      final allDay = _yes(allDayValue);
      final floating = _yes(get('floating'));
      final zone = get('timezone');
      final start = _date(get('start'), zone, allDay || floating, warn);
      final end = _date(get('due'), zone, allDay || floating, warn);
      final first = start ?? end;
      final hasTime = !allDay && (first?.hasTime ?? false);
      var rangeEnd = start != null && end != null && start.wall != end.wall
          ? end
          : null;
      if (rangeEnd != null && rangeEnd.wall.isBefore(start!.wall)) {
        warn('date_range', '截止时间早于开始时间；保留开始时间，原始截止时间保留在导入数据中。');
        rangeEnd = null;
      }
      final status = get('status').toLowerCase();
      final completed = [
        '1',
        '2',
        'completed',
        'done',
        '已完成',
        'archived',
        '已归档',
        'cancelled',
        'canceled',
        '-1',
      ].contains(status);
      if ([
        '2',
        'archived',
        '已归档',
        'cancelled',
        'canceled',
        '-1',
      ].contains(status)) {
        warn('archived_status', '已归档或取消条目按已完成导入，原始状态保留，避免重新出现在待办中。');
      } else if (![
        '',
        '0',
        '1',
        'normal',
        'completed',
        'done',
        '已完成',
        '未完成',
      ].contains(status)) {
        warn('unknown_status', '未知状态「$status」按未完成导入，原始状态已保留。');
      }
      final completedDate = _date(get('completed'), zone, false, warn);
      final priority = switch (get('priority').toLowerCase()) {
        '' || '0' || 'none' || '无' => 0,
        '1' || 'low' || '低' => 1,
        '3' || 'medium' || '中' => 2,
        '5' || 'high' || '高' => 3,
        _ => -1,
      };
      if (priority < 0) {
        warn('unknown_priority', '无法识别优先级「${get('priority')}」，按无优先级导入。');
      }
      final tagValues = _tags(get('tags'));
      if (tagValues.length > 20 || tagValues.any((t) => t.runes.length > 40)) {
        warn('tags_limit', '日序最多显示 20 个标签、每个 40 字符，超出部分保留在原始数据中。');
      }
      final tags = tagValues.take(20).map((t) => _cut(t, 40)).toSet().toList();
      final content = (values['content'] ?? '')
          .replaceAll('\r\n', '\n')
          .replaceAll('\r', '\n');
      final checklist = _yes(get('checklist')) || kind == 'CHECKLIST';
      final subtasks = <SubTask>[];
      if (checklist) {
        for (final line in content.split('\n')) {
          final match = RegExp(
            r'^\s*(?:([▫▪☐☑])\s*|[-*]\s+\[([ xX])\]\s*)(.*)$',
          ).firstMatch(line);
          if (match == null) continue;
          final name = match.group(3)!.trim();
          if (name.isEmpty) continue;
          if (subtasks.length >= 200) {
            warn('checklist_limit', '检查清单超过 200 项，其余项目保留在正文和原始数据中。');
            break;
          }
          if (name.runes.length > 300) {
            warn('checklist_title_length', '检查项标题超过 300 字符，完整文字保留在正文中。');
          }
          subtasks.add(
            SubTask(
              id: _id(sourceAccount, '$id:item:${subtasks.length}'),
              title: _cut(name, 300),
              completed:
                  ['▪', '☑'].contains(match.group(1)) ||
                  match.group(2)?.toLowerCase() == 'x',
            ),
          );
        }
        if (subtasks.isEmpty && content.trim().isNotEmpty) {
          warn('checklist_format', '未识别检查项标记，全部内容已保留在正文中。');
        }
      }
      if (content.runes.length > 20000) {
        warn('notes_length', '正文摘要超过 20,000 字符，完整内容保留在富文本和原始数据中。');
      }
      final bodyText = _cut(content, 99999);
      final rich = <Map<String, dynamic>>[
        {'insert': bodyText.endsWith('\n') ? bodyText : '$bodyText\n'},
      ];
      if (RegExp(
            r'!\[[^\]]*\]\(|\[附件\]|\[图片\]|attachment:|ticktick.*attachment|dida365.*attachment',
            caseSensitive: false,
          ).hasMatch(content) ||
          values.entries.any(
            (e) => e.key.contains('attachment') && e.value.trim().isNotEmpty,
          )) {
        warn(
          'attachment_reference',
          '此条目含附件或图片引用；CSV 不含文件本体，链接和原文字已保留，需另行上传文件。',
        );
      }
      if (RegExp(
        r'(^|\n)\s*#{1,6}\s|\*\*|!\[|\]\(',
        multiLine: true,
      ).hasMatch(content)) {
        warn(
          'markdown_preserved',
          '正文 Markdown 按原文保留，可在日序富文本编辑器继续整理；不会执行 HTML 或自动加载外部图片。',
        );
      }
      final rule = _repeat(get('repeat'), first?.wall, zone, warn);
      final reminder = _reminder(get('reminder'), hasTime, warn);
      final knownKeys = _aliases.keys.toSet();
      final extra = headers
          .where(
            (h) =>
                !knownKeys.contains(_normalize(h)) &&
                (raw[h]?.isNotEmpty ?? false),
          )
          .toList();
      if (extra.isNotEmpty) {
        warn('extra_fields', '未映射字段已完整保留：${extra.join('、')}。');
      }
      final importData = <String, String>{};
      for (final e in raw.entries) {
        var key = e.key.startsWith('__') ? 'CSV:${e.key}' : e.key;
        while (importData.containsKey(key)) {
          key = 'CSV:$key';
        }
        importData[key] = e.value;
      }
      importData.addAll({
        '__source': 'ticktick',
        '__sourceAccount': sourceAccount,
        '__sourceId': sourceId,
        '__sourceParentId': parentId,
        '__row': '$row',
      });
      final task = TaskItem(
        id: id,
        title: title.isEmpty ? '未命名条目' : _cut(title, 300),
        notes: _cut(content, 20000),
        itemType: itemType,
        richContent: rich,
        importData: importData,
        listId: listId,
        dueDate: first == null
            ? null
            : DateTime(first.wall.year, first.wall.month, first.wall.day),
        dueTime: hasTime ? _clock(first!.wall) : null,
        endDate: rangeEnd == null
            ? null
            : DateTime(
                rangeEnd.wall.year,
                rangeEnd.wall.month,
                rangeEnd.wall.day,
              ),
        endTime: rangeEnd != null && !allDay && rangeEnd.hasTime
            ? _clock(rangeEnd.wall)
            : null,
        priority: priority < 0 ? 0 : priority,
        completed: itemType == 'task' && completed,
        completedAt: itemType == 'task' && completed
            ? completedDate?.instant
            : null,
        tags: tags,
        subtasks: subtasks,
        recurrenceRule: itemType == 'task' ? rule : null,
        reminderMinutes: reminder,
      );
      records.add(
        TickTickImportRecord(
          task: task,
          row: row,
          sourceId: sourceId,
          sourceParentId: parentId,
          folderName: folder,
          listName: listName,
          rawFields: Map.unmodifiable(raw),
          warnings: localWarnings,
        ),
      );
      warnings.addAll(localWarnings);
    }
    if (fallbackIdentity) {
      warnings.add(
        const TickTickImportWarning(
          'fallback_identity',
          '部分 taskId 为备份内行号或为空，使用清单、标题、类型和创建时间生成稳定标识。重复导入同一内容会跳过；重新命名或移动清单后再导出可能被视为新条目。',
        ),
      );
    }
    final bySource = <String, List<TickTickImportRecord>>{};
    for (final r in records) {
      if (r.sourceId.isNotEmpty) {
        bySource.putIfAbsent(r.sourceId, () => []).add(r);
      }
    }
    for (final r in records) {
      if (r.sourceParentId.isEmpty) continue;
      final parents = bySource[r.sourceParentId] ?? [];
      final parent = parents.length == 1 ? parents.single : null;
      final w = TickTickImportWarning(
        'parent_relation',
        parent == null
            ? '父任务引用无法唯一匹配，当前条目作为独立任务保留；原始父任务 ID 已保留。'
            : '子任务作为完整独立条目导入，父任务「${parent.task.title}」及关联 ID 保留在原始数据中。',
        row: r.row,
      );
      r.task.importData['__parentDayflowId'] = parent?.task.id ?? '';
      r.task.importData['__parentTitle'] = parent?.task.title ?? '';
      r.warnings.add(w);
      warnings.add(w);
    }
    return TickTickImportPreview(
      sourceName: sourceName,
      sourceAccount: sourceAccount,
      fileSha256: sha256.convert(bytes).toString(),
      lists: List.unmodifiable(lists.values),
      records: List.unmodifiable(records),
      warnings: List.unmodifiable(warnings),
      metadata: Map.unmodifiable(metadata),
    );
  }

  static String _id(String account, String value) =>
      const Uuid().v5(_namespace, '$account\u0000$value');

  static String _decode(List<int> bytes) {
    if (bytes.length >= 2 &&
        ((bytes[0] == 255 && bytes[1] == 254) ||
            (bytes[0] == 254 && bytes[1] == 255))) {
      if (bytes.length.isOdd) {
        throw const TickTickImportException('UTF-16 备份文件不完整。');
      }
      final little = bytes[0] == 255;
      return String.fromCharCodes([
        for (var i = 2; i < bytes.length; i += 2)
          little ? bytes[i] | bytes[i + 1] << 8 : bytes[i] << 8 | bytes[i + 1],
      ]);
    }
    try {
      return utf8.decode(bytes).replaceFirst(RegExp('^\uFEFF'), '');
    } on FormatException {
      throw const TickTickImportException(
        '文件不是有效 UTF-8/UTF-16 CSV。请重新从滴答清单网页导出，避免 Excel 改变编码。',
      );
    }
  }

  static List<List<String>> _csv(String text) {
    final rows = <List<String>>[];
    var row = <String>[];
    var cell = StringBuffer();
    var quoted = false;
    var closed = false;
    void field() {
      row.add(cell.toString());
      if (row.length > 100) {
        throw const TickTickImportException('CSV 单行超过 100 列，无法安全导入。');
      }
      cell = StringBuffer();
      closed = false;
    }

    void record() {
      field();
      if (row.any((v) => v.trim().isNotEmpty)) rows.add(row);
      row = [];
      if (rows.length > maxRows + 65) {
        throw const TickTickImportException('备份超过 100,000 条记录，请拆分后导入。');
      }
    }

    for (var i = 0; i < text.length; i++) {
      final c = text[i];
      if (quoted) {
        if (c == '"') {
          if (i + 1 < text.length && text[i + 1] == '"') {
            cell.write('"');
            i++;
          } else {
            quoted = false;
            closed = true;
          }
        } else {
          cell.write(c);
        }
      } else if (c == ',') {
        field();
      } else if (c == '\n' || c == '\r') {
        if (c == '\r' && i + 1 < text.length && text[i + 1] == '\n') i++;
        record();
      } else if (c == '"' && cell.isEmpty && !closed) {
        quoted = true;
      } else if (closed && c.trim().isNotEmpty || c == '"') {
        throw TickTickImportException(
          'CSV 第 ${rows.length + 1} 条记录的引号格式无效，请使用原始备份文件。',
        );
      } else if (!closed) {
        cell.write(c);
      }
    }
    if (quoted) throw const TickTickImportException('CSV 中有未闭合的引号，文件可能不完整。');
    if (cell.isNotEmpty || row.isNotEmpty || closed) record();
    return rows;
  }

  static String _normalize(String value) =>
      value.trim().toLowerCase().replaceAll(RegExp(r'[\s_\-]'), '');
  static String _key(String value) =>
      _aliases[_normalize(value)] ?? _normalize(value);
  static const _aliases = {
    'title': 'title',
    'tasktitle': 'title',
    'name': 'title',
    '标题': 'title',
    '任务标题': 'title',
    'foldername': 'folder',
    'folder': 'folder',
    '文件夹名称': 'folder',
    '文件夹': 'folder',
    'listname': 'list',
    'list': 'list',
    'projectname': 'list',
    '清单名称': 'list',
    '清单': 'list',
    'kind': 'kind',
    'type': 'kind',
    '类型': 'kind',
    'tags': 'tags',
    'tag': 'tags',
    '标签': 'tags',
    'content': 'content',
    'description': 'content',
    'notes': 'content',
    '内容': 'content',
    '正文': 'content',
    '描述': 'content',
    'ischecklist': 'checklist',
    '是否检查清单': 'checklist',
    '是否检查项': 'checklist',
    'startdate': 'start',
    '开始日期': 'start',
    '开始时间': 'start',
    'duedate': 'due',
    '截止日期': 'due',
    '截止时间': 'due',
    'reminder': 'reminder',
    'reminders': 'reminder',
    '提醒': 'reminder',
    'repeat': 'repeat',
    'repeatflag': 'repeat',
    'rrule': 'repeat',
    '重复': 'repeat',
    'priority': 'priority',
    '优先级': 'priority',
    'status': 'status',
    '状态': 'status',
    'createdtime': 'created',
    'createdat': 'created',
    '创建时间': 'created',
    'completedtime': 'completed',
    'completedat': 'completed',
    '完成时间': 'completed',
    'timezone': 'timezone',
    '时区': 'timezone',
    'isallday': 'allDay',
    '全天': 'allDay',
    '是否全天': 'allDay',
    'isfloating': 'floating',
    '浮动时间': 'floating',
    'taskid': 'id',
    'id': 'id',
    '任务id': 'id',
    'parentid': 'parent',
    '父任务id': 'parent',
  };
  static bool _yes(String value) =>
      ['true', 'y', 'yes', '1', '是'].contains(value.toLowerCase());
  static String _cut(String value, int max) => value.runes.length <= max
      ? value
      : String.fromCharCodes(value.runes.take(max));
  static String _clock(DateTime value) =>
      '${value.hour.toString().padLeft(2, '0')}:${value.minute.toString().padLeft(2, '0')}';
  static List<String> _tags(String value) {
    if (value.isEmpty) return [];
    if (value.startsWith('[')) {
      try {
        final list = jsonDecode(value);
        if (list is List) {
          return list
              .map((v) => v.toString().replaceFirst(RegExp(r'^#'), '').trim())
              .where((v) => v.isNotEmpty)
              .toSet()
              .toList();
        }
      } on FormatException {
        /* Plain tags fall through. */
      }
    }
    return value
        .split(RegExp(r'[,，;；\n]'))
        .map((v) => v.trim().replaceFirst(RegExp(r'^#'), ''))
        .where((v) => v.isNotEmpty)
        .toSet()
        .toList();
  }

  static _ImportDate? _date(
    String value,
    String zone,
    bool wallOnly,
    void Function(String, String) warn,
  ) {
    if (value.isEmpty) return null;
    final match = RegExp(
      r'^(\d{4})-?(\d{2})-?(\d{2})(?:[T ](\d{2}):?(\d{2})(?::?(\d{2})(?:\.\d+)?)?)?(Z|[+-]\d{2}:?\d{2})?$',
    ).firstMatch(value);
    if (match == null) {
      warn('invalid_date', '无法识别日期「$value」，原值已保留。');
      return null;
    }
    final parts = [
      for (var i = 1; i <= 6; i++) int.tryParse(match.group(i) ?? '') ?? 0,
    ];
    final wall = DateTime.utc(
      parts[0],
      parts[1],
      parts[2],
      parts[3],
      parts[4],
      parts[5],
    );
    if (parts[0] < 1900 ||
        parts[0] > 9999 ||
        wall.year != parts[0] ||
        wall.month != parts[1] ||
        wall.day != parts[2] ||
        parts[3] > 23 ||
        parts[4] > 59 ||
        parts[5] > 59) {
      warn('invalid_date', '日期「$value」超出有效范围，原值已保留。');
      return null;
    }
    final offset = match.group(7);
    var instant = wall;
    if (offset != null && offset != 'Z') {
      final digits = offset.substring(1).replaceAll(':', '');
      final hours = int.parse(digits.substring(0, 2));
      final minutes = int.parse(digits.substring(2));
      if (hours > 23 || minutes > 59) {
        warn('invalid_date', '日期时区偏移无效，原值已保留。');
        return null;
      }
      instant = wall.subtract(
        Duration(
          minutes: (hours * 60 + minutes) * (offset.startsWith('-') ? -1 : 1),
        ),
      );
    }
    if (wallOnly) return _ImportDate(wall, instant, match.group(4) != null);
    var display = wall;
    if (zone.isNotEmpty) {
      try {
        if (!_zonesReady) {
          tzdata.initializeTimeZones();
          _zonesReady = true;
        }
        final location = tz.getLocation(zone);
        if (offset != null) {
          final local = tz.TZDateTime.from(instant, location);
          display = DateTime.utc(
            local.year,
            local.month,
            local.day,
            local.hour,
            local.minute,
            local.second,
          );
        } else {
          instant = tz.TZDateTime(
            location,
            wall.year,
            wall.month,
            wall.day,
            wall.hour,
            wall.minute,
            wall.second,
          ).toUtc();
        }
      } on Object {
        warn('unknown_timezone', '未知时区「$zone」，保留 CSV 写明的日期和时间，原时区保留在数据中。');
      }
    } else if (offset == null && match.group(4) != null) {
      warn('missing_timezone', '日期没有时区，按文件中的本地时间导入；完成时间按 UTC 保存以免跨设备变化。');
    }
    return _ImportDate(display, instant, match.group(4) != null);
  }

  static int? _reminder(
    String value,
    bool hasTime,
    void Function(String, String) warn,
  ) {
    if (value.isEmpty) return null;
    final match = RegExp(
      r'^(?:TRIGGER:)?(-?)P(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?)?$',
      caseSensitive: false,
    ).firstMatch(value);
    if (match == null ||
        !hasTime ||
        [2, 3, 4, 5].every((i) => match.group(i) == null)) {
      warn('unsupported_reminder', '提醒无法等价映射为单个提前提醒，原规则已保留，未自动启用。');
      return null;
    }
    final minutes =
        (int.tryParse(match.group(2) ?? '') ?? 0) * 1440 +
        (int.tryParse(match.group(3) ?? '') ?? 0) * 60 +
        (int.tryParse(match.group(4) ?? '') ?? 0);
    if (minutes > 525600 ||
        (int.tryParse(match.group(5) ?? '') ?? 0) != 0 ||
        (match.group(1) != '-' && minutes > 0)) {
      warn('unsupported_reminder', '提醒超过一年或含秒数，原规则已保留，未自动启用。');
      return null;
    }
    return minutes;
  }

  static RecurrenceRule? _repeat(
    String value,
    DateTime? anchor,
    String zone,
    void Function(String, String) warn,
  ) {
    if (value.isEmpty) return null;
    RecurrenceRule? unsupported() {
      warn('unsupported_recurrence', '重复规则无法完整等价转换，原规则已保留，未自动启用：$value');
      return null;
    }

    final text = value.trim().toUpperCase().replaceFirst(
      RegExp(r'^RRULE:'),
      '',
    );
    final map = <String, String>{};
    for (final part in text.split(';')) {
      final bits = part.split('=');
      if (bits.length != 2 || map.containsKey(bits[0])) return unsupported();
      map[bits[0]] = bits[1];
    }
    if (anchor == null ||
        map.keys.any(
          (k) => ![
            'FREQ',
            'INTERVAL',
            'BYDAY',
            'BYMONTHDAY',
            'BYMONTH',
            'COUNT',
            'UNTIL',
            'WKST',
          ].contains(k),
        )) {
      return unsupported();
    }
    final frequency = map['FREQ']?.toLowerCase();
    if (!['daily', 'weekly', 'monthly', 'yearly'].contains(frequency)) {
      return unsupported();
    }
    final interval = int.tryParse(map['INTERVAL'] ?? '1');
    final count = map['COUNT'] == null ? null : int.tryParse(map['COUNT']!);
    if (interval == null ||
        interval < 1 ||
        interval > 999 ||
        map.containsKey('COUNT') &&
            (count == null || count < 1 || count > 100000) ||
        map.containsKey('COUNT') && map.containsKey('UNTIL')) {
      return unsupported();
    }
    if (map['WKST'] != null &&
        map['WKST'] != 'MO' &&
        interval > 1 &&
        frequency == 'weekly') {
      return unsupported();
    }
    if (map['WKST'] != null &&
        !['MO', 'TU', 'WE', 'TH', 'FR', 'SA', 'SU'].contains(map['WKST'])) {
      return unsupported();
    }
    final weekdays = <int>[];
    int? ordinal;
    int? ordinalWeekday;
    if (map['BYDAY'] != null) {
      for (final day in map['BYDAY']!.split(',')) {
        final match = RegExp(r'^(-?[1-5])?(MO|TU|WE|TH|FR|SA|SU)$')
            .firstMatch(day);
        if (match == null) return unsupported();
        final weekday =
            [
              'MO',
              'TU',
              'WE',
              'TH',
              'FR',
              'SA',
              'SU',
            ].indexOf(match.group(2)!) +
            1;
        if (match.group(1) != null) {
          if (!['monthly', 'yearly'].contains(frequency) ||
              map['BYDAY']!.contains(',')) {
            return unsupported();
          }
          ordinal = int.parse(match.group(1)!);
          if (ordinal < -1) return unsupported();
          ordinalWeekday = weekday;
        } else {
          weekdays.add(weekday);
        }
      }
    }
    final days = map['BYMONTHDAY'] == null
        ? <int>[]
        : map['BYMONTHDAY']!
              .split(',')
              .map((s) => int.tryParse(s) ?? 0)
              .toSet()
              .toList();
    if (days.any((d) => d < 1 || d > 31) ||
        days.length > 31 ||
        days.isNotEmpty &&
            (frequency == 'daily' ||
                frequency == 'weekly' ||
                ordinal != null)) {
      return unsupported();
    }
    if (frequency != 'weekly' && weekdays.isNotEmpty) return unsupported();
    final month = map['BYMONTH'] == null ? null : int.tryParse(map['BYMONTH']!);
    if (map.containsKey('BYMONTH') &&
        (frequency != 'yearly' || month == null || month < 1 || month > 12)) {
      return unsupported();
    }
    // RFC 5545 skips invalid dates; Dayflow clamps a monthly day to month end.
    // Never silently turn "31st" into "last day of every month".
    if (frequency == 'monthly' &&
        ordinal == null &&
        (days.isEmpty ? [anchor.day] : days).any((d) => d > 28)) {
      return unsupported();
    }
    if (frequency == 'yearly') {
      if ((ordinal != null || days.isNotEmpty) && month == null) {
        return unsupported();
      }
      if (ordinal == null) {
        final m = month ?? anchor.month;
        final maxDay = DateTime(2025, m + 1, 0).day;
        if ((days.isEmpty ? [anchor.day] : days).any((d) => d > maxDay)) {
          return unsupported();
        }
      }
    }
    var until = map['UNTIL'] == null
        ? null
        : _date(map['UNTIL']!, zone, false, warn)?.wall;
    if (map.containsKey('UNTIL') && until == null) return unsupported();
    if (until != null &&
        map['UNTIL']!.contains('T') &&
        (until.hour * 60 + until.minute < anchor.hour * 60 + anchor.minute)) {
      until = until.subtract(const Duration(days: 1));
    }
    if (count != null) {
      warn('recurrence_count', '备份未包含已执行次数，重复次数将从当前条目开始计算；原 COUNT 规则已保留。');
    }
    return RecurrenceRule(
      frequency: frequency!,
      interval: interval,
      weekdays: weekdays.toSet().toList(),
      monthDays: days,
      ordinal: ordinal,
      ordinalWeekday: ordinalWeekday,
      month: month,
      anchorDate: DateTime(anchor.year, anchor.month, anchor.day),
      count: count,
      until: until == null
          ? null
          : DateTime(until.year, until.month, until.day),
    );
  }
}

class _ImportDate {
  final DateTime wall;
  final DateTime instant;
  final bool hasTime;
  const _ImportDate(this.wall, this.instant, this.hasTime);
}
