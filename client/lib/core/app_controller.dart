import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import 'api_client.dart';
import 'attachments.dart';
import 'models.dart';
import 'recurrence.dart';
import 'storage.dart';
import 'ticktick_import.dart';

const _uuid = Uuid();
const _recurrenceNamespace = '6ba7b811-9dad-11d1-80b4-00c04fd430c8';
const _inbox = ProjectList(id: 'inbox', name: '收件箱', icon: 'inbox');
// The API allows 2 MiB per request. Leave room below that transport limit
// while measuring the actual UTF-8 JSON, including escaping and the envelope.
const _syncBatchBytes = 1536 * 1024;

class TickTickImportResult {
  final int importedTasks;
  final int importedLists;
  final int skippedTasks;
  final int skippedLists;
  const TickTickImportResult({
    required this.importedTasks,
    required this.importedLists,
    required this.skippedTasks,
    required this.skippedLists,
  });
}

class AppController extends ChangeNotifier {
  final AppStorage _storage;
  final ApiClient Function(String) _apiFactory;
  final DateTime Function() _now;
  final AttachmentBytesStore _attachmentBytes;
  final AttachmentPicker _attachmentPicker;
  final Map<String, TaskItem> _tasks = {};
  final Map<String, ProjectList> _lists = {};
  final Map<String, Map<String, dynamic>> _outbox = {};
  final Map<String, SyncConflict> _conflicts = {};
  final Map<String, String> _occurrences = {};
  Future<void> _writes = Future<void>.value();
  Future<void>? _syncFuture;
  Future<void>? _refreshFuture;
  Future<TickTickImportResult>? _importFuture;
  Timer? _syncTimer;
  ApiClient? _api;
  String? _accountKey;
  String? _accessToken;
  String? _refreshToken;
  int _cursor = 0;
  int _generation = 0;
  bool _disposed = false;
  bool _authBusy = false;
  bool _workspaceReady = false;

  AppUser? user;
  bool demoMode = false;
  bool loading = false;
  bool syncing = false;
  String? syncError;
  String serverUrl;

  AppController({
    AppStorage? storage,
    ApiClient Function(String)? apiFactory,
    DateTime Function()? now,
    AttachmentBytesStore? attachmentBytes,
    AttachmentPicker? attachmentPicker,
  }) : _storage = storage ?? LocalStorage(),
       _apiFactory = apiFactory ?? ((url) => ApiClient(url)),
       _now = now ?? DateTime.now,
       _attachmentBytes = attachmentBytes ?? LocalAttachmentBytesStore(),
       _attachmentPicker = attachmentPicker ?? SystemAttachmentPicker(),
       serverUrl = _defaultServerUrl();

  static String _defaultServerUrl() {
    const configured = String.fromEnvironment('API_BASE_URL');
    if (configured.isNotEmpty) return configured;
    if (kIsWeb && kReleaseMode) return Uri.base.origin;
    return 'http://127.0.0.1:8000';
  }

  bool get authenticated => user != null && !demoMode;
  bool get requiresLogin =>
      authenticated && _accessToken == null && _refreshToken == null;
  int get pendingCount => _outbox.length;
  // Capture before choosing a backup file. A preview belongs to that workspace,
  // even when the user signs out and signs back in to the same account.
  int get workspaceRevision => _generation;
  bool get importing => _importFuture != null;
  Set<String> get knownTaskIds => Set.unmodifiable(_tasks.keys);
  List<TaskItem> get tasks =>
      List.unmodifiable(_tasks.values.where((task) => !task.deleted));
  List<ProjectList> get lists =>
      List.unmodifiable(_lists.values.where((list) => !list.deleted));
  List<SyncConflict> get conflicts => List.unmodifiable(_conflicts.values);

  TaskItem? getTask(String id) {
    final task = _tasks[id];
    return task == null || task.deleted ? null : task;
  }

  ProjectList? taskList(String id) {
    final list = _lists[id];
    return list == null || list.deleted ? _lists['inbox'] : list;
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  String _key(String kind, String id) => '$kind:$id';
  String _cacheKey(String server, String id) => '$server|$id';

  Future<void> initialize() async {
    loading = true;
    _notify();
    try {
      final active = await _storage.readActiveAccount();
      if (active != null) {
        if (active['demo'] == true) {
          await _loadDemo();
        } else {
          serverUrl = normalizeServerUrl(active['serverUrl'] as String);
          user = AppUser.fromJson(
            Map<String, dynamic>.from(active['user'] as Map),
          );
          _accountKey = _cacheKey(serverUrl, user!.id);
          _api = _apiFactory(serverUrl);
          _restore(await _storage.readWorkspace(_accountKey!));
          try {
            _refreshToken = await _storage.readRefreshToken(_accountKey!);
          } catch (_) {
            syncError = '无法读取安全登录凭据；缓存仍可编辑，请重新登录同步。';
          }
          if (requiresLogin && syncError == null) {
            syncError = '离线缓存已载入。请重新登录后同步。';
          }
        }
      }
      _lists.putIfAbsent('inbox', () => _inbox);
    } catch (error) {
      syncError = '读取本机数据失败：$error';
    } finally {
      loading = false;
      _notify();
    }
    if (authenticated && !requiresLogin) unawaited(sync());
  }

  Future<void> enterDemo() async {
    if (_authBusy) return;
    if (_importFuture != null) await _waitForImport();
    await _persist();
    _switchWorkspace();
    await _loadDemo();
    await _storage.writeActiveAccount({'demo': true});
    await _persist();
    _notify();
  }

  Future<void> _loadDemo() async {
    demoMode = true;
    user = null;
    _accountKey = 'demo';
    final cached = await _storage.readWorkspace('demo');
    _restore(cached);
    if (cached == null) _seedDemo();
    // Demo edits are intentionally never part of an account's upload queue.
    _outbox.clear();
    _conflicts.clear();
  }

  void _seedDemo() {
    final today = _now();
    DateTime day(int offset) =>
        DateTime(today.year, today.month, today.day + offset);
    const work = ProjectList(
      id: 'demo-work',
      name: '工作',
      color: 0xFF7C88DE,
      icon: 'work',
    );
    const life = ProjectList(
      id: 'demo-life',
      name: '生活',
      color: 0xFF6D9C83,
      icon: 'home',
    );
    _lists.addAll({'inbox': _inbox, work.id: work, life.id: life});
    final examples = [
      TaskItem(
        id: 'demo-plan',
        title: '梳理本周的三件重要事项',
        listId: work.id,
        dueDate: day(0),
        dueTime: '09:30',
        priority: 3,
        tags: const ['计划'],
        notes: '这是一份独立示例。可以自由编辑，登录后不会自动上传。',
        subtasks: const [
          SubTask(id: 'demo-outline', title: '整理待办'),
          SubTask(id: 'demo-select', title: '选出优先事项'),
        ],
      ),
      TaskItem(
        id: 'demo-review',
        title: '整理项目反馈',
        listId: work.id,
        dueDate: day(1),
        dueTime: '14:00',
        priority: 2,
      ),
      TaskItem(
        id: 'demo-walk',
        title: '傍晚散步 30 分钟',
        listId: life.id,
        dueDate: day(0),
        dueTime: '18:30',
        recurrence: 'daily',
        tags: const ['健康'],
      ),
      TaskItem(
        id: 'demo-read',
        title: '读完下一章',
        listId: life.id,
        dueDate: day(2),
        priority: 1,
      ),
      TaskItem(
        id: 'demo-weekend',
        title: '给周末留一点空白',
        listId: life.id,
        dueDate: day(5),
      ),
      TaskItem(
        id: 'demo-next',
        title: '下一阶段方案草稿',
        listId: work.id,
        dueDate: day(8),
        priority: 2,
      ),
      TaskItem(
        id: 'demo-inbox',
        title: '记录一个想到的小点子',
        notes: '收件箱适合先记下来，之后再安排日期与清单。',
      ),
      TaskItem(
        id: 'demo-done',
        title: '整理桌面',
        listId: life.id,
        dueDate: day(-1),
        completed: true,
        completedAt: day(-1),
      ),
    ];
    for (final task in examples) {
      _tasks[task.id] = task;
    }
  }

  Future<void> signIn({
    required String email,
    required String password,
    required String serverUrl,
  }) => _authenticate(email: email, password: password, server: serverUrl);

  Future<void> register({
    required String email,
    required String password,
    required String name,
    required String serverUrl,
  }) => _authenticate(
    email: email,
    password: password,
    server: serverUrl,
    name: name,
  );

  Future<void> _authenticate({
    required String email,
    required String password,
    required String server,
    String? name,
  }) async {
    if (_authBusy) throw StateError('登录正在进行，请稍候。');
    if (_importFuture != null) await _waitForImport();
    if (_authBusy) throw StateError('登录正在进行，请稍候。');
    _authBusy = true;
    loading = true;
    syncError = null;
    _notify();
    ApiClient? candidate;
    try {
      final normalized = normalizeServerUrl(server);
      candidate = _apiFactory(normalized);
      final result = name == null
          ? await candidate.signIn(email: email.trim(), password: password)
          : await candidate.register(
              email: email.trim(),
              password: password,
              name: name.trim(),
            );
      await _persist();
      _switchWorkspace();
      serverUrl = normalized;
      _api = candidate;
      candidate = null;
      user = result.user;
      _accountKey = _cacheKey(serverUrl, user!.id);
      _restore(await _storage.readWorkspace(_accountKey!));
      _accessToken = result.accessToken;
      _refreshToken = result.refreshToken;
      await _storage.writeRefreshToken(_accountKey!, result.refreshToken);
      await _storage.writeActiveAccount({
        'serverUrl': serverUrl,
        'user': user!.toJson(),
      });
      await _persist();
    } catch (error) {
      syncError = error.toString();
      rethrow;
    } finally {
      candidate?.close();
      loading = false;
      _authBusy = false;
      _notify();
    }
    await sync();
  }

  Future<void> signOut() async {
    if (_authBusy) return;
    if (_importFuture != null) await _waitForImport();
    // Let an already-started refresh settle before revoking its rotated token.
    try {
      await _refreshFuture;
    } catch (_) {
      // Local sign-out must work when the server is offline.
    }
    await _persist();
    final key = _accountKey;
    final token = _refreshToken;
    final oldApi = _api;
    _api = null;
    _switchWorkspace();
    await _storage.writeActiveAccount(null);
    if (key != null && key != 'demo') {
      await _storage.writeRefreshToken(key, null);
    }
    _notify();
    try {
      if (token != null && oldApi != null) await oldApi.logout(token);
    } catch (_) {
      syncError = '已退出本机账号；服务器暂不可达，远端会话未确认撤销。';
      _notify();
    } finally {
      oldApi?.close();
    }
  }

  void _switchWorkspace() {
    _generation++;
    _syncTimer?.cancel();
    _syncTimer = null;
    _syncFuture = null;
    _refreshFuture = null;
    _api?.close();
    _api = null;
    _accessToken = null;
    _refreshToken = null;
    _accountKey = null;
    _workspaceReady = false;
    _cursor = 0;
    _tasks.clear();
    _lists
      ..clear()
      ..['inbox'] = _inbox;
    _outbox.clear();
    _conflicts.clear();
    _occurrences.clear();
    user = null;
    demoMode = false;
    syncing = false;
    syncError = null;
  }

  void _restore(Map<String, dynamic>? data) {
    _workspaceReady = false;
    _tasks.clear();
    _lists
      ..clear()
      ..['inbox'] = _inbox;
    _outbox.clear();
    _conflicts.clear();
    _occurrences.clear();
    _cursor = (data?['cursor'] as num?)?.toInt() ?? 0;
    if (data == null) {
      _workspaceReady = true;
      return;
    }
    for (final raw in data['tasks'] as List? ?? []) {
      final task = TaskItem.fromEntity(Map<String, dynamic>.from(raw as Map));
      _tasks[task.id] = task;
    }
    for (final raw in data['lists'] as List? ?? []) {
      final list = ProjectList.fromEntity(
        Map<String, dynamic>.from(raw as Map),
      );
      _lists[list.id] = list;
    }
    _lists['inbox'] = (_lists['inbox'] ?? _inbox).copyWith(deleted: false);
    for (final raw in data['outbox'] as List? ?? []) {
      final mutation = Map<String, dynamic>.from(raw as Map);
      _outbox[_key(mutation['kind'] as String, mutation['id'] as String)] =
          mutation;
    }
    for (final raw in data['conflicts'] as List? ?? []) {
      final conflict = SyncConflict.fromJson(
        Map<String, dynamic>.from(raw as Map),
      );
      _conflicts[_key(conflict.kind, conflict.entityId)] = conflict;
    }
    final occurrences = data['occurrences'] as Map? ?? {};
    for (final entry in occurrences.entries) {
      _occurrences[entry.key.toString()] = entry.value.toString();
    }
    _workspaceReady = true;
  }

  Map<String, dynamic> _snapshot() => {
    'cursor': _cursor,
    'tasks': _tasks.values.map((task) => task.toEntity()).toList(),
    'lists': _lists.values.map((list) => list.toEntity()).toList(),
    'outbox': _outbox.values.toList(),
    'conflicts': _conflicts.values.map((c) => c.toJson()).toList(),
    'occurrences': Map<String, String>.from(_occurrences),
  };

  Future<void> _persist() {
    final key = _accountKey;
    if (key == null || !_workspaceReady) return Future<void>.value();
    return _persistSnapshot(key, _snapshot());
  }

  Future<void> _persistSnapshot(String key, Map<String, dynamic> data) {
    // Capture a deep snapshot now. Serial writes cannot regress newer edits.
    final snapshot = jsonDecode(jsonEncode(data)) as Map<String, dynamic>;
    final next = _writes
        .catchError((Object _) {})
        .then((_) => _storage.writeWorkspace(key, snapshot));
    _writes = next;
    return next;
  }

  void _requireWorkspace() {
    if (_accountKey == null) throw StateError('请登录或进入示例空间。');
    if (!_workspaceReady) {
      throw StateError('本机数据尚未成功载入，已停止写入以保护原数据。请重新登录或重启应用。');
    }
  }

  Future<void> _waitForImport() async {
    final generation = _generation;
    try {
      await _importFuture;
    } catch (_) {
      // A failed import has not changed the workspace, so other operations may
      // proceed normally after its transaction has finished.
    }
    if (generation != _generation || _disposed) {
      throw StateError('账号已切换，请重新操作。');
    }
  }

  /// Import is one local transaction, then normal sync batches upload its
  /// outbox. Existing identities (including tombstones) always win. Historical
  /// completions bypass saveTask so they never spawn new recurring tasks.
  Future<TickTickImportResult> importTickTick(
    TickTickImportPreview preview, {
    required int expectedWorkspaceRevision,
  }) {
    _requireWorkspace();
    if (_authBusy || _disposed || expectedWorkspaceRevision != _generation) {
      return Future.error(StateError('账号已切换，请重新选择备份文件。'));
    }
    if (_importFuture != null) {
      return Future.error(StateError('正在导入，请等待本次导入完成。'));
    }
    final operation = _applyTickTickImport(preview, _generation);
    _importFuture = operation;
    _notify();
    void finished() {
      if (identical(_importFuture, operation)) {
        _importFuture = null;
        _notify();
      }
    }

    operation.then(
      (_) => finished(),
      onError: (Object _, StackTrace _) => finished(),
    );
    return operation;
  }

  Future<TickTickImportResult> _applyTickTickImport(
    TickTickImportPreview preview,
    int generation,
  ) async {
    // A response already in flight must be merged before checking identities.
    // New syncs and edits wait for this transaction until it is durable.
    await _syncFuture;
    if (generation != _generation || _disposed) {
      throw StateError('账号已切换，请重新选择备份文件。');
    }
    final key = _accountKey!;
    final nextTasks = Map<String, TaskItem>.from(_tasks);
    final nextLists = Map<String, ProjectList>.from(_lists);
    final nextOutbox = Map<String, Map<String, dynamic>>.from(_outbox);
    var importedTasks = 0;
    var importedLists = 0;
    var skippedTasks = 0;
    var skippedLists = 0;
    final stamp = _now();
    void enqueue(String kind, String id, Map<String, dynamic> payload) {
      if (demoMode) return;
      nextOutbox[_key(kind, id)] = {
        'mutationId': _uuid.v4(),
        'kind': kind,
        'id': id,
        'baseVersion': 0,
        'deleted': false,
        'payload': payload,
      };
    }

    for (final list in preview.lists) {
      if (nextLists.containsKey(list.id)) {
        skippedLists++;
        continue;
      }
      final saved = list.copyWith(version: 0, deleted: false, updatedAt: stamp);
      nextLists[saved.id] = saved;
      enqueue('list', saved.id, saved.toPayload());
      importedLists++;
    }
    for (final task in preview.tasks) {
      if (nextTasks.containsKey(task.id)) {
        skippedTasks++;
        continue;
      }
      final saved = task.copyWith(
        listId: nextLists[task.listId]?.deleted == false
            ? task.listId
            : 'inbox',
        version: 0,
        deleted: false,
        updatedAt: stamp,
      );
      nextTasks[saved.id] = saved;
      enqueue('task', saved.id, saved.toPayload());
      importedTasks++;
    }
    if (importedTasks > 0 || importedLists > 0) {
      final staged = {
        ..._snapshot(),
        'tasks': nextTasks.values.map((task) => task.toEntity()).toList(),
        'lists': nextLists.values.map((list) => list.toEntity()).toList(),
        'outbox': nextOutbox.values.toList(),
      };
      try {
        await _persistSnapshot(key, staged);
      } catch (error) {
        if (generation == _generation) {
          syncError = '导入未写入本机，原有数据未更改：$error';
          _notify();
        }
        rethrow;
      }
      if (generation != _generation || _disposed) {
        throw StateError('账号已切换；导入已保存在原账号，请返回该账号查看。');
      }
      _tasks
        ..clear()
        ..addAll(nextTasks);
      _lists
        ..clear()
        ..addAll(nextLists);
      _outbox
        ..clear()
        ..addAll(nextOutbox);
      if (syncError?.startsWith('导入未写入本机') == true) syncError = null;
      _notify();
      _scheduleSync();
    }
    return TickTickImportResult(
      importedTasks: importedTasks,
      importedLists: importedLists,
      skippedTasks: skippedTasks,
      skippedLists: skippedLists,
    );
  }

  // Attachment operations are separate from task mutations. A cloud attachment
  // is returned to the editor only after the server has confirmed its bytes.
  Future<T> _withAttachmentSession<T>(
    Future<T> Function(ApiClient api, String accessToken) operation,
  ) async {
    final generation = _generation;
    if (!authenticated || requiresLogin || _api == null) {
      throw const ApiException(401, '请先登录后传输附件。本机草稿已保留。');
    }
    if (_accessToken == null) await _refreshSession(generation);
    if (generation != _generation) throw const ApiException(0, '账号已切换，请重试。');
    try {
      final result = await operation(_api!, _accessToken!);
      if (generation != _generation) throw const ApiException(0, '账号已切换，请重试。');
      return result;
    } on ApiException catch (error) {
      if (generation != _generation) rethrow;
      if (error.statusCode != 401) rethrow;
      await _refreshSession(generation);
      if (generation != _generation) throw const ApiException(0, '账号已切换，请重试。');
      final result = await operation(_api!, _accessToken!);
      if (generation != _generation) throw const ApiException(0, '账号已切换，请重试。');
      return result;
    }
  }

  Future<AttachmentItem?> pickAttachment({bool imagesOnly = false}) async {
    _requireWorkspace();
    final generation = _generation;
    final picked = await _attachmentPicker.pick(imagesOnly: imagesOnly);
    if (picked == null) return null;
    if (generation != _generation) {
      throw const ApiException(0, '账号已切换，请重新选择附件。');
    }
    return addAttachmentBytes(name: picked.name, bytes: picked.bytes);
  }

  Future<AttachmentItem> addAttachmentBytes({
    required String name,
    required Uint8List bytes,
  }) async {
    _requireWorkspace();
    final scope = _accountKey!;
    final generation = _generation;
    final item = localAttachment(scope, name, bytes);
    if (bytes.isEmpty) throw const ApiException(0, '不能添加空附件。');
    if (demoMode) {
      if (bytes.length > demoAttachmentMaxBytes) {
        throw const ApiException(0, '示例空间每个附件最多 10 MiB。');
      }
      await _attachmentBytes.write(scope, item.id, bytes);
      if (generation != _generation) throw const ApiException(0, '空间已切换，请重试。');
      return item;
    }
    final limits = await _withAttachmentSession(
      (api, token) => api.attachmentLimits(accessToken: token),
    );
    final maximum = (limits['maxFileBytes'] as num).toInt();
    if (bytes.length > maximum) {
      throw ApiException(
        413,
        '附件超过服务器限制（${(maximum / 1024 / 1024).toStringAsFixed(1)} MiB）。',
      );
    }
    if (generation != _generation) throw const ApiException(0, '账号已切换，请重试。');
    final uploaded = await _withAttachmentSession(
      (api, token) => api.uploadAttachment(
        accessToken: token,
        id: item.id,
        name: name,
        bytes: bytes,
      ),
    );
    verifyAttachmentBytes(uploaded, bytes);
    if (uploaded.id != item.id || uploaded.name != name) {
      throw const ApiException(0, '服务器返回了不匹配的附件。');
    }
    try {
      await _attachmentBytes.write(scope, uploaded.id, bytes);
    } catch (_) {
      // Upload succeeded; optional offline caching must not misreport it as a
      // failed upload or add a second copy on retry.
    }
    if (generation != _generation) throw const ApiException(0, '账号已切换，请重试。');
    return uploaded;
  }

  Future<Uint8List> downloadAttachment(AttachmentItem attachment) async {
    _requireWorkspace();
    final scope = _accountKey!;
    final generation = _generation;
    Uint8List? cached;
    try {
      cached = await _attachmentBytes.read(scope, attachment.id);
      if (cached != null) verifyAttachmentBytes(attachment, cached);
    } catch (_) {
      cached = null;
    }
    if (generation != _generation) throw const ApiException(0, '账号已切换，请重试。');
    if (cached != null) return cached;
    if (demoMode) throw const ApiException(404, '本机附件已被清理，请重新选择文件。');
    final bytes = await _withAttachmentSession(
      (api, token) =>
          api.downloadAttachment(accessToken: token, id: attachment.id),
    );
    verifyAttachmentBytes(attachment, bytes);
    try {
      await _attachmentBytes.write(scope, attachment.id, bytes);
    } catch (_) {
      // A full local cache does not prevent a verified network download.
    }
    if (generation != _generation) throw const ApiException(0, '账号已切换，请重试。');
    return bytes;
  }

  Future<void> saveAttachmentToDevice(AttachmentItem attachment) async {
    final generation = _generation;
    final bytes = await downloadAttachment(attachment);
    if (generation != _generation) throw const ApiException(0, '账号已切换，请重试。');
    await _attachmentPicker.save(attachment.name, bytes);
  }

  void _enqueue(
    String kind,
    String id,
    int version,
    bool deleted,
    Map<String, dynamic> payload,
  ) {
    if (demoMode) return;
    final key = _key(kind, id);
    _outbox[key] = {
      'mutationId': _uuid.v4(),
      'kind': kind,
      'id': id,
      'baseVersion': version,
      'deleted': deleted,
      'payload': payload,
    };
    final conflict = _conflicts[key];
    if (conflict != null) {
      _conflicts[key] = SyncConflict(
        entityId: id,
        kind: kind,
        localPayload: payload,
        localDeleted: deleted,
        server: conflict.server,
      );
    }
  }

  Future<void> _saveChanges() async {
    _notify();
    try {
      await _persist();
    } catch (error) {
      syncError = '更改暂未写入本机：$error';
      _notify();
      rethrow;
    }
    _scheduleSync();
  }

  void _scheduleSync() {
    if (!authenticated || requiresLogin) return;
    _syncTimer?.cancel();
    _syncTimer = Timer(const Duration(milliseconds: 650), () {
      unawaited(sync());
    });
  }

  Future<void> saveTask(TaskItem task) async {
    if (_importFuture != null) await _waitForImport();
    _requireWorkspace();
    if (task.title.trim().isEmpty) throw ArgumentError('任务名称不能为空。');
    final current = _tasks[task.id];
    final normalized = task.copyWith(
      title: task.title.trim(),
      listId: _lists[task.listId]?.deleted == false ? task.listId : 'inbox',
      completed: task.itemType == 'note' ? false : task.completed,
      completedAt: task.itemType != 'note' && task.completed
          ? (task.completedAt ?? _now())
          : null,
      version: current?.version ?? task.version,
      deleted: false,
      updatedAt: _now(),
    );
    // Calculate first: an unsupported holiday year must not partially mark the
    // original completed while failing to create its successor.
    if (normalized.completed && !(current?.completed ?? false)) {
      _createNextOccurrence(normalized);
    }
    _tasks[task.id] = normalized;
    _enqueue(
      'task',
      task.id,
      normalized.version,
      false,
      normalized.toPayload(),
    );
    await _saveChanges();
  }

  Future<void> deleteTask(String id) async {
    if (_importFuture != null) await _waitForImport();
    _requireWorkspace();
    final task = getTask(id);
    if (task == null) return;
    final deleted = task.copyWith(deleted: true, updatedAt: _now());
    _tasks[id] = deleted;
    _enqueue('task', id, task.version, true, deleted.toPayload());
    await _saveChanges();
  }

  Future<void> toggleTask(String id) async {
    final task = getTask(id);
    if (task == null || task.itemType == 'note') return;
    await saveTask(
      task.copyWith(
        completed: !task.completed,
        completedAt: task.completed ? null : _now(),
      ),
    );
  }

  Future<void> moveTask(String id, DateTime date) async {
    final task = getTask(id);
    if (task == null) return;
    final moved = dateOnly(date);
    final shiftedEnd = task.endDate == null
        ? null
        : addCalendarDays(
            moved,
            calendarDaysBetween(task.dueDate ?? task.endDate!, task.endDate!),
          );
    await saveTask(task.copyWith(dueDate: moved, endDate: shiftedEnd));
  }

  void _createNextOccurrence(TaskItem task) {
    if (recurrenceFor(task).frequency == 'none') return;
    final anchor = task.dueDate ?? _now();
    final occurrenceKey =
        '${task.id}|${calendarDate(anchor)}|${task.recurrence}';
    if (_occurrences.containsKey(occurrenceKey)) return;
    final schedule = nextOccurrence(
      task,
      completedAt: task.completedAt ?? _now(),
    );
    if (schedule == null) return;
    // Two offline devices completing the same occurrence must address the same
    // successor entity, so the sync protocol can detect a conflict, not create
    // duplicate recurring tasks.
    final nextId = _uuid.v5(
      _recurrenceNamespace,
      'dayflow-occurrence:$occurrenceKey',
    );
    final next = task.copyWith(
      id: nextId,
      dueDate: schedule.date,
      endDate: schedule.endDate,
      recurrenceRule: schedule.rule,
      completed: false,
      completedAt: null,
      version: 0,
      updatedAt: _now(),
      subtasks: task.subtasks
          .map(
            (s) => s.copyWith(
              id: _uuid.v5(_recurrenceNamespace, '$nextId:${s.id}'),
              completed: false,
            ),
          )
          .toList(),
    );
    _occurrences[occurrenceKey] = nextId;
    _tasks[next.id] = next;
    _enqueue('task', next.id, 0, false, next.toPayload());
  }

  Future<void> saveList(ProjectList list) async {
    if (_importFuture != null) await _waitForImport();
    _requireWorkspace();
    if (list.name.trim().isEmpty) throw ArgumentError('清单名称不能为空。');
    final saved = list.copyWith(
      name: list.name.trim(),
      version: _lists[list.id]?.version ?? list.version,
      deleted: false,
      updatedAt: _now(),
    );
    _lists[list.id] = saved;
    _enqueue('list', saved.id, saved.version, false, saved.toPayload());
    await _saveChanges();
  }

  Future<void> deleteList(String id) async {
    if (_importFuture != null) await _waitForImport();
    _requireWorkspace();
    if (id == 'inbox') throw ArgumentError('收件箱不能删除。');
    final list = _lists[id];
    if (list == null || list.deleted) return;
    final deleted = list.copyWith(deleted: true, updatedAt: _now());
    _lists[id] = deleted;
    _enqueue('list', id, list.version, true, deleted.toPayload());
    for (final task in tasks.where((task) => task.listId == id)) {
      final moved = task.copyWith(listId: 'inbox', updatedAt: _now());
      _tasks[task.id] = moved;
      _enqueue('task', task.id, task.version, false, moved.toPayload());
    }
    await _saveChanges();
  }

  Future<void> sync() {
    if (_importFuture != null) return _syncAfterImport();
    if (_syncFuture != null) return _syncFuture!;
    if (!_workspaceReady) return Future<void>.value();
    if (!authenticated || _api == null) return Future<void>.value();
    if (requiresLogin) {
      syncError = '请重新登录后同步。本机更改已保留。';
      _notify();
      return Future<void>.value();
    }
    final generation = _generation;
    final operation = _runSync(generation);
    _syncFuture = operation;
    operation.whenComplete(() {
      if (generation == _generation && identical(_syncFuture, operation)) {
        _syncFuture = null;
      }
    });
    return operation;
  }

  Future<void> _syncAfterImport() async {
    if (_importFuture != null) await _waitForImport();
    await sync();
  }

  List<Map<String, dynamic>> _nextSyncBatch() {
    final batch = <Map<String, dynamic>>[];
    var bytes = utf8
        .encode(jsonEncode({'cursor': _cursor, 'mutations': []}))
        .length;
    for (final entry in _outbox.entries) {
      if (_conflicts.containsKey(entry.key)) continue;
      final mutation = Map<String, dynamic>.from(entry.value);
      final additional =
          utf8.encode(jsonEncode(mutation)).length + (batch.isEmpty ? 0 : 1);
      if (bytes + additional > _syncBatchBytes) {
        if (batch.isEmpty) {
          throw const ApiException(0, '单项更改过大，请缩短内容后再同步。本机更改已保留。');
        }
        break;
      }
      batch.add(mutation);
      bytes += additional;
      if (batch.length == 500) break;
    }
    return batch;
  }

  Future<void> _runSync(int generation) async {
    syncing = true;
    syncError = null;
    _notify();
    try {
      var passes = 0;
      var more = true;
      var recoveredServerRollback = false;
      while (more && generation == _generation && passes++ < 30) {
        await _persist();
        if (generation != _generation) return;
        if (_accessToken == null) await _refreshSession(generation);
        if (generation != _generation) return;
        final sent = _nextSyncBatch();
        final api = _api!;
        Map<String, dynamic> response;
        try {
          response = await api.sync(
            accessToken: _accessToken!,
            cursor: _cursor,
            mutations: sent,
          );
        } on ApiException catch (error) {
          if (error.statusCode == 400 &&
              error.message ==
                  'Sync cursor is ahead of this server; pull from cursor 0.' &&
              _cursor > 0 &&
              !recoveredServerRollback) {
            if (generation != _generation) return;
            recoveredServerRollback = true;
            _cursor = 0;
            // A restored server can have lower entity versions too. Rehydrate
            // its cached entities while retaining every unsent local edit.
            _tasks.updateAll(
              (id, task) => _outbox.containsKey(_key('task', id))
                  ? task
                  : task.copyWith(version: 0),
            );
            _lists.updateAll(
              (id, list) => _outbox.containsKey(_key('list', id))
                  ? list
                  : list.copyWith(version: 0),
            );
            // Existing conflict snapshots belong to the old server history.
            // Their mutations remain queued and will be checked again.
            _conflicts.clear();
            await _persist();
            continue;
          }
          if (error.statusCode != 401) rethrow;
          await _refreshSession(generation);
          if (generation != _generation) return;
          response = await api.sync(
            accessToken: _accessToken!,
            cursor: _cursor,
            mutations: sent,
          );
        }
        if (generation != _generation) return;
        _mergeSync(response, sent);
        await _persist();
        _notify();
        more =
            response['hasMore'] == true ||
            _outbox.keys.any((key) => !_conflicts.containsKey(key));
        // A malformed response must not repeatedly submit an unchanged batch.
        if (sent.isNotEmpty &&
            (response['accepted'] as List? ?? []).isEmpty &&
            (response['conflicts'] as List? ?? []).isEmpty) {
          throw const ApiException(0, '服务器未确认本批更改，请检查服务端版本。');
        }
      }
      if (generation == _generation && _conflicts.isNotEmpty) {
        syncError = '有 ${_conflicts.length} 项同步冲突，请选择保留本机或服务器版本。';
      }
      if (more && generation == _generation) _scheduleSync();
    } catch (error) {
      if (generation == _generation) {
        syncError = error.toString();
        if (error is ApiException &&
            (error.statusCode == 401 || error.statusCode == 403)) {
          _accessToken = null;
          _refreshToken = null;
          try {
            await _storage.writeRefreshToken(_accountKey!, null);
          } catch (_) {}
          syncError = '登录已过期，请重新登录。本机更改已保留。';
        }
      }
    } finally {
      if (generation == _generation) {
        syncing = false;
        _notify();
      }
    }
  }

  Future<void> _refreshSession(int generation) {
    if (_refreshFuture != null) return _refreshFuture!;
    final api = _api!;
    final token = _refreshToken;
    final key = _accountKey!;
    if (token == null) {
      return Future<void>.error(const ApiException(401, '请重新登录。'));
    }
    final operation = () async {
      try {
        final result = await api.refresh(token);
        if (generation != _generation) return;
        if (result.user.id != user?.id) {
          throw const ApiException(401, '登录账户不匹配，请重新登录。');
        }
        _accessToken = result.accessToken;
        _refreshToken = result.refreshToken;
        user = result.user;
        await _storage.writeRefreshToken(key, result.refreshToken);
      } catch (error) {
        if (generation == _generation) {
          // A lost response may already have rotated the server token. Never
          // replay the old token automatically: this server revokes on replay.
          _accessToken = null;
          _refreshToken = null;
          try {
            await _storage.writeRefreshToken(key, null);
          } catch (_) {}
        }
        if (error is ApiException && error.statusCode == 0) {
          throw const ApiException(401, '刷新登录状态未完成，请重新登录。本机更改已保留。');
        }
        rethrow;
      }
    }();
    _refreshFuture = operation;
    operation.then(
      (_) {
        if (generation == _generation && identical(_refreshFuture, operation)) {
          _refreshFuture = null;
        }
      },
      onError: (Object _, StackTrace _) {
        if (generation == _generation && identical(_refreshFuture, operation)) {
          _refreshFuture = null;
        }
      },
    );
    return operation;
  }

  Map<String, dynamic>? _localEntity(String kind, String id) =>
      kind == 'task' ? _tasks[id]?.toEntity() : _lists[id]?.toEntity();

  void _applyEntity(Map<String, dynamic> entity) {
    if (entity['kind'] == 'task') {
      final task = TaskItem.fromEntity(entity);
      _tasks[task.id] = task;
    } else if (entity['kind'] == 'list') {
      final list = ProjectList.fromEntity(entity);
      if (list.id == 'inbox' && list.deleted) return;
      _lists[list.id] = list;
    }
  }

  void _mergeSync(
    Map<String, dynamic> response,
    List<Map<String, dynamic>> sent,
  ) {
    final sentById = {for (final m in sent) m['mutationId'] as String: m};
    for (final raw in response['accepted'] as List? ?? []) {
      final accepted = Map<String, dynamic>.from(raw as Map);
      final entity = Map<String, dynamic>.from(accepted['entity'] as Map);
      final kind = entity['kind'] as String;
      final id = entity['id'] as String;
      final key = _key(kind, id);
      final pending = _outbox[key];
      if (pending?['mutationId'] == accepted['mutationId']) {
        _outbox.remove(key);
        if (!_conflicts.containsKey(key)) _applyEntity(entity);
      } else if (pending != null) {
        // A newer edit happened during this request. Preserve its payload and
        // use a fresh mutation identity with the acknowledged server version.
        final version = (entity['version'] as num).toInt();
        _outbox[key] = {
          ...pending,
          'mutationId': _uuid.v4(),
          'baseVersion': version,
        };
        final local = _localEntity(kind, id);
        if (local != null) _applyEntity({...local, 'version': version});
      } else if (!_conflicts.containsKey(key)) {
        final localVersion =
            (_localEntity(kind, id)?['version'] as num?)?.toInt() ?? 0;
        if ((entity['version'] as num).toInt() >= localVersion) {
          _applyEntity(entity);
        }
      }
    }
    for (final raw in response['conflicts'] as List? ?? []) {
      final item = Map<String, dynamic>.from(raw as Map);
      final mutation = sentById[item['mutationId']];
      if (mutation == null) continue;
      final server = Map<String, dynamic>.from(item['server'] as Map);
      final kind = mutation['kind'] as String;
      final id = mutation['id'] as String;
      _recordConflict(kind, id, server);
    }
    for (final raw in response['changes'] as List? ?? []) {
      final entity = Map<String, dynamic>.from(raw as Map);
      final kind = entity['kind'] as String;
      final id = entity['id'] as String;
      final key = _key(kind, id);
      final version = (entity['version'] as num).toInt();
      final conflict = _conflicts[key];
      if (conflict != null) {
        if (version > conflict.serverVersion) {
          _recordConflict(kind, id, entity);
        }
        continue;
      }
      final localVersion =
          (_localEntity(kind, id)?['version'] as num?)?.toInt() ?? 0;
      if (version <= localVersion) continue;
      if (_outbox.containsKey(key)) {
        _recordConflict(kind, id, entity);
      } else {
        _applyEntity(entity);
      }
    }
    _cursor = (response['cursor'] as num?)?.toInt() ?? _cursor;
  }

  void _recordConflict(String kind, String id, Map<String, dynamic> server) {
    final key = _key(kind, id);
    final local = _localEntity(kind, id);
    final mutation = _outbox[key];
    final payload = Map<String, dynamic>.from(
      (local?['payload'] ?? mutation?['payload'] ?? {}) as Map,
    );
    _conflicts[key] = SyncConflict(
      entityId: id,
      kind: kind,
      localPayload: payload,
      localDeleted: local?['deleted'] == true,
      server: server,
    );
  }

  Future<void> resolveConflict(
    String entityId, {
    required bool keepLocal,
  }) async {
    if (_importFuture != null) await _waitForImport();
    _requireWorkspace();
    final matches = _conflicts.entries
        .where((entry) => entry.value.entityId == entityId)
        .toList();
    if (matches.isEmpty) return;
    for (final entry in matches) {
      final conflict = entry.value;
      _conflicts.remove(entry.key);
      _outbox.remove(entry.key);
      if (keepLocal) {
        final entity = {
          'kind': conflict.kind,
          'id': conflict.entityId,
          'version': conflict.serverVersion,
          'deleted': conflict.localDeleted,
          'updatedAt': _now().toUtc().toIso8601String(),
          'payload': conflict.localPayload,
        };
        _applyEntity(entity);
        _enqueue(
          conflict.kind,
          conflict.entityId,
          conflict.serverVersion,
          conflict.localDeleted,
          conflict.localPayload,
        );
      } else {
        _applyEntity(conflict.server);
      }
    }
    syncError = _conflicts.isEmpty
        ? null
        : '还有 ${_conflicts.length} 项同步冲突需要处理。';
    await _saveChanges();
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    _syncTimer?.cancel();
    _api?.close();
    super.dispose();
  }
}
