const Object _unset = Object();

DateTime? parseDate(Object? value) =>
    value == null ? null : DateTime.tryParse(value.toString());

String? calendarDate(DateTime? date) => date == null
    ? null
    : '${date.year.toString().padLeft(4, '0')}-'
          '${date.month.toString().padLeft(2, '0')}-'
          '${date.day.toString().padLeft(2, '0')}';

class AppUser {
  final String id;
  final String email;
  final String name;
  const AppUser({required this.id, required this.email, required this.name});
  factory AppUser.fromJson(Map<String, dynamic> json) => AppUser(
    id: json['id'] as String,
    email: json['email'] as String,
    name: json['name'] as String? ?? '',
  );
  Map<String, dynamic> toJson() => {'id': id, 'email': email, 'name': name};
  AppUser copyWith({String? id, String? email, String? name}) => AppUser(
    id: id ?? this.id,
    email: email ?? this.email,
    name: name ?? this.name,
  );
}

class SubTask {
  final String id;
  final String title;
  final bool completed;
  const SubTask({
    required this.id,
    required this.title,
    this.completed = false,
  });
  factory SubTask.fromJson(Map<String, dynamic> json) => SubTask(
    id: json['id'] as String,
    title: json['title'] as String? ?? '',
    completed: json['completed'] == true,
  );
  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'completed': completed,
  };
  Map<String, dynamic> toPayload() => toJson();
  SubTask copyWith({String? id, String? title, bool? completed}) => SubTask(
    id: id ?? this.id,
    title: title ?? this.title,
    completed: completed ?? this.completed,
  );
}

class AttachmentItem {
  final String id;
  final String name;
  final String mimeType;
  final String sha256;
  final int size;
  const AttachmentItem({
    required this.id,
    required this.name,
    required this.mimeType,
    required this.sha256,
    required this.size,
  });
  factory AttachmentItem.fromJson(Map<String, dynamic> json) => AttachmentItem(
    id: json['id'] as String,
    name: json['name'] as String,
    mimeType: json['mimeType'] as String,
    sha256: json['sha256'] as String,
    size: (json['size'] as num).toInt(),
  );
  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'mimeType': mimeType,
    'sha256': sha256,
    'size': size,
  };
}

/// Persisted recurrence intent. Day numbers and weekdays use calendar dates,
/// never UTC timestamps. [count] includes the first occurrence.
class RecurrenceRule {
  final String frequency;
  final int interval;
  final List<int> weekdays;
  final List<int> monthDays;
  final int? ordinal;
  final int? ordinalWeekday;
  final int? month;
  final String basis;
  final DateTime? anchorDate;
  final DateTime? until;
  final int? count;
  final int occurrence;
  final String workdayMode;
  final int? lunarMonth;
  final int? lunarDay;
  final bool lunarLeap;
  final String lunarMode;
  final List<DateTime> dates;

  /// Study-day numbers: 1 is the initial day. After the final day, its number
  /// becomes the continuing interval (default: every 15 days).
  final List<int> reviewDays;

  const RecurrenceRule({
    this.frequency = 'none',
    this.interval = 1,
    this.weekdays = const [],
    this.monthDays = const [],
    this.ordinal,
    this.ordinalWeekday,
    this.month,
    this.basis = 'due',
    this.anchorDate,
    this.until,
    this.count,
    this.occurrence = 1,
    this.workdayMode = 'weekdays',
    this.lunarMonth,
    this.lunarDay,
    this.lunarLeap = false,
    this.lunarMode = 'yearly',
    this.dates = const [],
    this.reviewDays = const [1, 2, 4, 7, 15],
  });

  factory RecurrenceRule.fromJson(Map<String, dynamic> json) => RecurrenceRule(
    frequency: json['frequency'] as String? ?? 'none',
    interval: (json['interval'] as num?)?.toInt() ?? 1,
    weekdays: List<int>.from(json['weekdays'] as List? ?? const []),
    monthDays: List<int>.from(json['monthDays'] as List? ?? const []),
    ordinal: (json['ordinal'] as num?)?.toInt(),
    ordinalWeekday: (json['ordinalWeekday'] as num?)?.toInt(),
    month: (json['month'] as num?)?.toInt(),
    basis: json['basis'] as String? ?? 'due',
    anchorDate: parseDate(json['anchorDate']),
    until: parseDate(json['until']),
    count: (json['count'] as num?)?.toInt(),
    occurrence: (json['occurrence'] as num?)?.toInt() ?? 1,
    workdayMode: json['workdayMode'] as String? ?? 'weekdays',
    lunarMonth: (json['lunarMonth'] as num?)?.toInt(),
    lunarDay: (json['lunarDay'] as num?)?.toInt(),
    lunarLeap: json['lunarLeap'] == true,
    lunarMode: json['lunarMode'] as String? ?? 'yearly',
    dates: (json['dates'] as List? ?? const [])
        .map(parseDate)
        .whereType<DateTime>()
        .toList(),
    reviewDays: List<int>.from(
      json['reviewDays'] as List? ?? const [1, 2, 4, 7, 15],
    ),
  );
  Map<String, dynamic> toJson() => {
    'frequency': frequency,
    'interval': interval,
    'weekdays': weekdays,
    'monthDays': monthDays,
    'ordinal': ordinal,
    'ordinalWeekday': ordinalWeekday,
    'month': month,
    'basis': basis,
    'anchorDate': calendarDate(anchorDate),
    'until': calendarDate(until),
    'count': count,
    'occurrence': occurrence,
    'workdayMode': workdayMode,
    'lunarMonth': lunarMonth,
    'lunarDay': lunarDay,
    'lunarLeap': lunarLeap,
    'lunarMode': lunarMode,
    'dates': dates.map(calendarDate).toList(),
    'reviewDays': reviewDays,
  };
  RecurrenceRule copyWith({
    String? frequency,
    int? interval,
    List<int>? weekdays,
    List<int>? monthDays,
    Object? ordinal = _unset,
    Object? ordinalWeekday = _unset,
    Object? month = _unset,
    String? basis,
    Object? anchorDate = _unset,
    Object? until = _unset,
    Object? count = _unset,
    int? occurrence,
    String? workdayMode,
    Object? lunarMonth = _unset,
    Object? lunarDay = _unset,
    bool? lunarLeap,
    String? lunarMode,
    List<DateTime>? dates,
    List<int>? reviewDays,
  }) => RecurrenceRule(
    frequency: frequency ?? this.frequency,
    interval: interval ?? this.interval,
    weekdays: weekdays ?? this.weekdays,
    monthDays: monthDays ?? this.monthDays,
    ordinal: identical(ordinal, _unset) ? this.ordinal : ordinal as int?,
    ordinalWeekday: identical(ordinalWeekday, _unset)
        ? this.ordinalWeekday
        : ordinalWeekday as int?,
    month: identical(month, _unset) ? this.month : month as int?,
    basis: basis ?? this.basis,
    anchorDate: identical(anchorDate, _unset)
        ? this.anchorDate
        : anchorDate as DateTime?,
    until: identical(until, _unset) ? this.until : until as DateTime?,
    count: identical(count, _unset) ? this.count : count as int?,
    occurrence: occurrence ?? this.occurrence,
    workdayMode: workdayMode ?? this.workdayMode,
    lunarMonth: identical(lunarMonth, _unset)
        ? this.lunarMonth
        : lunarMonth as int?,
    lunarDay: identical(lunarDay, _unset) ? this.lunarDay : lunarDay as int?,
    lunarLeap: lunarLeap ?? this.lunarLeap,
    lunarMode: lunarMode ?? this.lunarMode,
    dates: dates ?? this.dates,
    reviewDays: reviewDays ?? this.reviewDays,
  );
}

class TaskItem {
  final String id;
  final String title;
  final String notes;
  final String itemType;
  final List<Map<String, dynamic>> richContent;
  final List<AttachmentItem> attachments;

  /// Original imported fields, retained independently from editable content.
  final Map<String, String> importData;
  final String listId;
  final DateTime? dueDate;
  final String? dueTime;
  final DateTime? endDate;
  final String? endTime;
  final int priority;
  final bool completed;
  final DateTime? completedAt;
  final List<String> tags;
  final List<SubTask> subtasks;
  final String recurrence;
  final RecurrenceRule? recurrenceRule;
  final int? reminderMinutes;
  final int version;
  final bool deleted;
  final DateTime? updatedAt;

  const TaskItem({
    required this.id,
    required this.title,
    this.notes = '',
    this.itemType = 'task',
    this.richContent = const [],
    this.attachments = const [],
    this.importData = const {},
    this.listId = 'inbox',
    this.dueDate,
    this.dueTime,
    this.endDate,
    this.endTime,
    this.priority = 0,
    this.completed = false,
    this.completedAt,
    this.tags = const [],
    this.subtasks = const [],
    this.recurrence = 'none',
    this.recurrenceRule,
    this.reminderMinutes,
    this.version = 0,
    this.deleted = false,
    this.updatedAt,
  });

  factory TaskItem.fromEntity(Map<String, dynamic> entity) {
    final p = Map<String, dynamic>.from(entity['payload'] as Map? ?? {});
    return TaskItem(
      id: entity['id'] as String,
      title: p['title'] as String? ?? '',
      notes: p['notes'] as String? ?? '',
      itemType: p['itemType'] as String? ?? 'task',
      richContent: (p['richContent'] as List? ?? const [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList(),
      attachments: (p['attachments'] as List? ?? const [])
          .map(
            (e) => AttachmentItem.fromJson(Map<String, dynamic>.from(e as Map)),
          )
          .toList(),
      importData: Map<String, String>.unmodifiable(
        Map<String, String>.from(p['importData'] as Map? ?? const {}),
      ),
      listId: p['listId'] as String? ?? 'inbox',
      dueDate: parseDate(p['dueDate']),
      dueTime: p['dueTime'] as String?,
      endDate: parseDate(p['endDate']),
      endTime: p['endTime'] as String?,
      priority: (p['priority'] as num?)?.toInt() ?? 0,
      completed: p['completed'] == true,
      completedAt: parseDate(p['completedAt']),
      tags: List<String>.unmodifiable(
        (p['tags'] as List? ?? []).map((e) => e.toString()),
      ),
      subtasks: List<SubTask>.unmodifiable(
        (p['subtasks'] as List? ?? []).map(
          (e) => SubTask.fromJson(Map<String, dynamic>.from(e as Map)),
        ),
      ),
      recurrence: p['recurrence'] as String? ?? 'none',
      recurrenceRule: p['recurrenceRule'] is Map
          ? RecurrenceRule.fromJson(
              Map<String, dynamic>.from(p['recurrenceRule']),
            )
          : null,
      reminderMinutes: (p['reminderMinutes'] as num?)?.toInt(),
      version: (entity['version'] as num?)?.toInt() ?? 0,
      deleted: entity['deleted'] == true,
      updatedAt: parseDate(entity['updatedAt']),
    );
  }

  Map<String, dynamic> toPayload() => {
    'title': title,
    'notes': notes,
    'itemType': itemType,
    'richContent': richContent,
    'attachments': attachments.map((e) => e.toJson()).toList(),
    'importData': importData,
    'listId': listId,
    'dueDate': calendarDate(dueDate),
    'dueTime': dueTime,
    'endDate': calendarDate(endDate),
    'endTime': endTime,
    'priority': priority,
    'completed': completed,
    'completedAt': completedAt?.toUtc().toIso8601String(),
    'tags': tags,
    'subtasks': subtasks.map((s) => s.toJson()).toList(),
    'recurrence': recurrence,
    'recurrenceRule': recurrenceRule?.toJson(),
    'reminderMinutes': reminderMinutes,
  };

  Map<String, dynamic> toEntity() => {
    'kind': 'task',
    'id': id,
    'version': version,
    'deleted': deleted,
    'updatedAt': updatedAt?.toUtc().toIso8601String(),
    'payload': toPayload(),
  };

  TaskItem copyWith({
    String? id,
    String? title,
    String? notes,
    String? itemType,
    List<Map<String, dynamic>>? richContent,
    List<AttachmentItem>? attachments,
    Map<String, String>? importData,
    String? listId,
    Object? dueDate = _unset,
    Object? dueTime = _unset,
    Object? endDate = _unset,
    Object? endTime = _unset,
    int? priority,
    bool? completed,
    Object? completedAt = _unset,
    List<String>? tags,
    List<SubTask>? subtasks,
    String? recurrence,
    Object? recurrenceRule = _unset,
    Object? reminderMinutes = _unset,
    int? version,
    bool? deleted,
    Object? updatedAt = _unset,
  }) => TaskItem(
    id: id ?? this.id,
    title: title ?? this.title,
    notes: notes ?? this.notes,
    itemType: itemType ?? this.itemType,
    richContent: richContent ?? this.richContent,
    attachments: attachments ?? this.attachments,
    importData: importData == null
        ? this.importData
        : Map<String, String>.unmodifiable(importData),
    listId: listId ?? this.listId,
    dueDate: identical(dueDate, _unset) ? this.dueDate : dueDate as DateTime?,
    dueTime: identical(dueTime, _unset) ? this.dueTime : dueTime as String?,
    endDate: identical(endDate, _unset) ? this.endDate : endDate as DateTime?,
    endTime: identical(endTime, _unset) ? this.endTime : endTime as String?,
    priority: priority ?? this.priority,
    completed: completed ?? this.completed,
    completedAt: identical(completedAt, _unset)
        ? this.completedAt
        : completedAt as DateTime?,
    tags: tags == null ? this.tags : List<String>.unmodifiable(tags),
    subtasks: subtasks == null
        ? this.subtasks
        : List<SubTask>.unmodifiable(subtasks),
    recurrence: recurrence ?? this.recurrence,
    recurrenceRule: identical(recurrenceRule, _unset)
        ? this.recurrenceRule
        : recurrenceRule as RecurrenceRule?,
    reminderMinutes: identical(reminderMinutes, _unset)
        ? this.reminderMinutes
        : reminderMinutes as int?,
    version: version ?? this.version,
    deleted: deleted ?? this.deleted,
    updatedAt: identical(updatedAt, _unset)
        ? this.updatedAt
        : updatedAt as DateTime?,
  );
}

class ProjectList {
  final String id;
  final String name;
  final int color;
  final String icon;
  final int version;
  final bool deleted;
  final DateTime? updatedAt;
  const ProjectList({
    required this.id,
    required this.name,
    this.color = 0xFF64748B,
    this.icon = 'list',
    this.version = 0,
    this.deleted = false,
    this.updatedAt,
  });
  factory ProjectList.fromEntity(Map<String, dynamic> entity) {
    final p = Map<String, dynamic>.from(entity['payload'] as Map? ?? {});
    return ProjectList(
      id: entity['id'] as String,
      name: p['name'] as String? ?? '',
      color: (p['color'] as num?)?.toInt() ?? 0xFF64748B,
      icon: p['icon'] as String? ?? 'list',
      version: (entity['version'] as num?)?.toInt() ?? 0,
      deleted: entity['deleted'] == true,
      updatedAt: parseDate(entity['updatedAt']),
    );
  }
  Map<String, dynamic> toPayload() => {
    'name': name,
    'color': color,
    'icon': icon,
  };
  Map<String, dynamic> toEntity() => {
    'kind': 'list',
    'id': id,
    'version': version,
    'deleted': deleted,
    'updatedAt': updatedAt?.toUtc().toIso8601String(),
    'payload': toPayload(),
  };
  ProjectList copyWith({
    String? id,
    String? name,
    int? color,
    String? icon,
    int? version,
    bool? deleted,
    Object? updatedAt = _unset,
  }) => ProjectList(
    id: id ?? this.id,
    name: name ?? this.name,
    color: color ?? this.color,
    icon: icon ?? this.icon,
    version: version ?? this.version,
    deleted: deleted ?? this.deleted,
    updatedAt: identical(updatedAt, _unset)
        ? this.updatedAt
        : updatedAt as DateTime?,
  );
}

class SyncConflict {
  final String entityId;
  final String kind;
  final Map<String, dynamic> localPayload;
  final bool localDeleted;
  final Map<String, dynamic> server;
  const SyncConflict({
    required this.entityId,
    required this.kind,
    required this.localPayload,
    required this.localDeleted,
    required this.server,
  });
  String get id => entityId;
  String get title => localTitle.isEmpty ? serverTitle : localTitle;
  int get serverVersion => (server['version'] as num?)?.toInt() ?? 0;
  String get localTitle =>
      (localPayload[kind == 'task' ? 'title' : 'name'] ?? '').toString();
  String get serverTitle =>
      ((server['payload'] as Map?)?[kind == 'task' ? 'title' : 'name'] ?? '')
          .toString();
  Map<String, dynamic> toJson() => {
    'entityId': entityId,
    'kind': kind,
    'localPayload': localPayload,
    'localDeleted': localDeleted,
    'server': server,
  };
  factory SyncConflict.fromJson(Map<String, dynamic> json) => SyncConflict(
    entityId: json['entityId'] as String,
    kind: json['kind'] as String,
    localPayload: Map<String, dynamic>.from(json['localPayload'] as Map? ?? {}),
    localDeleted: json['localDeleted'] == true,
    server: Map<String, dynamic>.from(json['server'] as Map),
  );
}

/// Calendar arithmetic avoids DST drift; month ends clamp to the target month.
DateTime nextRecurrenceDate(DateTime date, String recurrence) {
  switch (recurrence) {
    case 'daily':
      return DateTime(date.year, date.month, date.day + 1);
    case 'weekly':
      return DateTime(date.year, date.month, date.day + 7);
    case 'monthly':
      final lastDay = DateTime(date.year, date.month + 2, 0).day;
      return DateTime(
        date.year,
        date.month + 1,
        date.day > lastDay ? lastDay : date.day,
      );
    default:
      return DateTime(date.year, date.month, date.day);
  }
}
