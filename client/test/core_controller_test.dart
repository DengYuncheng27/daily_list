import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:dayflow/core/api_client.dart';
import 'package:dayflow/core/app_controller.dart';
import 'package:dayflow/core/models.dart';
import 'package:dayflow/core/storage.dart';

Map<String, dynamic> _clone(Map<String, dynamic> value) =>
    jsonDecode(jsonEncode(value)) as Map<String, dynamic>;

class MemoryStorage implements AppStorage {
  Map<String, dynamic>? active;
  final Map<String, Map<String, dynamic>> workspaces = {};
  final Map<String, String> tokens = {};
  @override
  Future<Map<String, dynamic>?> readActiveAccount() async =>
      active == null ? null : _clone(active!);
  @override
  Future<void> writeActiveAccount(Map<String, dynamic>? account) async {
    active = account == null ? null : _clone(account);
  }

  @override
  Future<Map<String, dynamic>?> readWorkspace(String key) async =>
      workspaces[key] == null ? null : _clone(workspaces[key]!);
  @override
  Future<void> writeWorkspace(
    String key,
    Map<String, dynamic> workspace,
  ) async {
    workspaces[key] = _clone(workspace);
  }

  @override
  Future<String?> readRefreshToken(String key) async => tokens[key];
  @override
  Future<void> writeRefreshToken(String key, String? token) async {
    if (token == null) {
      tokens.remove(key);
    } else {
      tokens[key] = token;
    }
  }
}

class FakeServer {
  final Map<String, Map<String, Map<String, dynamic>>> accounts = {};
  final List<Map<String, dynamic>> submitted = [];
  final Map<String, Map<String, dynamic>> receipts = {};
  int sequence = 0;
  bool offline = false;
  bool blockNextSync = false;
  bool expireAccessOnce = false;
  bool failRefresh = false;
  bool rejectAheadCursor = false;
  bool failNextSyncBadRequest = false;
  final List<int> syncCursors = [];
  final List<int> syncBodyBytes = [];
  final List<int> syncBatchCounts = [];
  int refreshCalls = 0;
  Completer<void>? entered;
  Completer<void>? release;
  late final http.Client client = MockClient(handle);

  ApiClient api(String url) => ApiClient(url, client: client);

  Map<String, dynamic> auth(String email, {String suffix = ''}) => {
    'accessToken': 'access:$email$suffix',
    'refreshToken': 'refresh:$email$suffix',
    'user': {'id': email, 'email': email, 'name': email.split('@').first},
  };

  Future<http.Response> handle(http.Request request) async {
    if (offline) throw http.ClientException('offline');
    final body = jsonDecode(request.body) as Map<String, dynamic>;
    http.Response respond(Object value, [int status = 200]) => http.Response(
      jsonEncode(value),
      status,
      headers: {'content-type': 'application/json'},
    );
    final path = request.url.path;
    if (path.endsWith('/login') || path.endsWith('/register')) {
      return respond(auth(body['email'] as String));
    }
    if (path.endsWith('/refresh')) {
      refreshCalls++;
      if (failRefresh) throw http.ClientException('refresh response lost');
      final email = (body['refreshToken'] as String).replaceFirst(
        'refresh:',
        '',
      );
      return respond(auth(email, suffix: '#rotated'));
    }
    if (path.endsWith('/logout')) return respond({'ok': true});
    syncBodyBytes.add(request.bodyBytes.length);
    syncBatchCounts.add((body['mutations'] as List).length);
    if (request.bodyBytes.length > 2 * 1024 * 1024) {
      return respond({'detail': 'Request body is too large.'}, 413);
    }
    syncCursors.add(body['cursor'] as int);
    if (failNextSyncBadRequest) {
      failNextSyncBadRequest = false;
      return respond({'detail': 'Another validation error.'}, 400);
    }
    if (rejectAheadCursor && (body['cursor'] as int) > sequence) {
      return respond({
        'detail': 'Sync cursor is ahead of this server; pull from cursor 0.',
      }, 400);
    }
    if (expireAccessOnce) {
      expireAccessOnce = false;
      return respond({'detail': 'expired'}, 401);
    }
    if (blockNextSync) {
      blockNextSync = false;
      entered!.complete();
      await release!.future;
    }
    final email =
        (request.headers['Authorization'] ??
                request.headers['authorization'] ??
                '')
            .replaceFirst('Bearer access:', '')
            .replaceAll('#rotated', '');
    final entities = accounts.putIfAbsent(email, () => {});
    final accepted = <Map<String, dynamic>>[];
    final conflicts = <Map<String, dynamic>>[];
    for (final raw in body['mutations'] as List) {
      final mutation = Map<String, dynamic>.from(raw as Map);
      submitted.add(_clone(mutation));
      final id = mutation['id'] as String;
      final mutationId = mutation['mutationId'] as String;
      final receiptKey = '$email:$mutationId';
      if (receipts.containsKey(receiptKey)) {
        final receipt = receipts[receiptKey]!;
        (receipt.containsKey('entity') ? accepted : conflicts).add(receipt);
        continue;
      }
      final existing = entities[id];
      if (mutation['baseVersion'] != (existing?['version'] ?? 0)) {
        final receipt = {
          'mutationId': mutationId,
          'server':
              existing ??
              {
                'kind': mutation['kind'],
                'id': id,
                'version': 0,
                'deleted': true,
                'payload': {},
              },
        };
        conflicts.add(receipt);
        receipts[receiptKey] = receipt;
      } else {
        sequence++;
        final entity = {
          'kind': mutation['kind'],
          'id': id,
          'version': ((existing?['version'] as int?) ?? 0) + 1,
          'deleted': mutation['deleted'],
          'updatedAt': DateTime.utc(2026, 10, 20).toIso8601String(),
          'payload': mutation['payload'],
        };
        entities[id] = entity;
        final receipt = {'mutationId': mutationId, 'entity': entity};
        accepted.add(receipt);
        receipts[receiptKey] = receipt;
      }
    }
    return respond({
      'cursor': sequence,
      'hasMore': false,
      'accepted': accepted,
      'conflicts': conflicts,
      'changes': entities.values.toList(),
    });
  }

  void pauseNextSync() {
    blockNextSync = true;
    entered = Completer<void>();
    release = Completer<void>();
  }

  void remoteEdit(String email, String id, String title) {
    final previous = accounts[email]![id]!;
    accounts[email]![id] = {
      ...previous,
      'version': (previous['version'] as int) + 1,
      'payload': {
        ...Map<String, dynamic>.from(previous['payload'] as Map),
        'title': title,
      },
    };
    sequence++;
  }
}

Future<void> login(AppController app, [String email = 'a@example.test']) =>
    app.signIn(
      email: email,
      password: 'test-password-123',
      serverUrl: 'http://localhost:8000',
    );

void main() {
  for (final fixture in [
    (
      name: 'UTF-8 notes and JSON escaping',
      count: 100,
      notes: '${'中' * 9000}${'\n' * 1000}',
    ),
    (name: '500 mutation limit', count: 501, notes: ''),
  ]) {
    test(
      'offline backlog is fully synchronized within ${fixture.name}',
      () async {
        final storage = MemoryStorage();
        final server = FakeServer();
        final initial = AppController(storage: storage, apiFactory: server.api);
        await login(initial);
        initial.dispose();
        final workspace = storage.workspaces.values.single;
        final tasks = [
          for (var index = 0; index < fixture.count; index++)
            TaskItem(
              id: 'queued-$index',
              title: 'Offline $index',
              notes: fixture.notes,
            ),
        ];
        workspace['tasks'] = tasks.map((task) => task.toEntity()).toList();
        workspace['outbox'] = [
          for (final task in tasks)
            {
              'mutationId': 'mutation-${task.id}',
              'kind': 'task',
              'id': task.id,
              'baseVersion': 0,
              'deleted': false,
              'payload': task.toPayload(),
            },
        ];
        server.syncBodyBytes.clear();
        server.syncBatchCounts.clear();
        final restarted = AppController(
          storage: storage,
          apiFactory: server.api,
        );
        addTearDown(restarted.dispose);
        await login(restarted);
        expect(restarted.syncError, isNull);
        expect(restarted.pendingCount, 0);
        expect(server.accounts['a@example.test'], hasLength(fixture.count));
        expect(server.submitted, hasLength(fixture.count));
        expect(server.syncBodyBytes.length, greaterThan(1));
        expect(
          server.syncBodyBytes,
          everyElement(lessThanOrEqualTo(1536 * 1024)),
        );
        expect(server.syncBatchCounts, everyElement(lessThanOrEqualTo(500)));
        for (final entity in server.accounts['a@example.test']!.values) {
          expect((entity['payload'] as Map)['notes'], fixture.notes);
        }
        expect(storage.workspaces.values.single['outbox'], isEmpty);
      },
    );
  }

  test(
    'server rollback resets cursor while preserving unsent local edits',
    () async {
      final storage = MemoryStorage();
      final server = FakeServer()..rejectAheadCursor = true;
      final app = AppController(storage: storage, apiFactory: server.api);
      addTearDown(app.dispose);
      await login(app);
      await app.saveTask(const TaskItem(id: 'cached', title: 'Backup cached'));
      await app.saveTask(
        const TaskItem(id: 'pending', title: 'Backup pending'),
      );
      await app.sync();
      final backupEntities = {
        for (final entry in server.accounts['a@example.test']!.entries)
          entry.key: _clone(entry.value),
      };
      final backupReceipts = {
        for (final entry in server.receipts.entries)
          entry.key: _clone(entry.value),
      };
      await app.saveTask(app.getTask('cached')!.copyWith(title: 'Newer cache'));
      await app.saveTask(
        app.getTask('pending')!.copyWith(title: 'Newer server'),
      );
      await app.sync();
      server.offline = true;
      await app.saveTask(
        app.getTask('pending')!.copyWith(title: 'Unsent local work'),
      );
      final originalMutationId =
          (storage.workspaces.values.single['outbox'] as List)
              .single['mutationId'];
      server.accounts['a@example.test'] = backupEntities;
      server.receipts
        ..clear()
        ..addAll(backupReceipts);
      server.sequence = 2;
      server.offline = false;
      server.syncCursors.clear();
      await app.sync();
      expect(server.syncCursors, [4, 0]);
      expect(app.getTask('cached')!.title, 'Backup cached');
      expect(app.getTask('cached')!.version, 1);
      expect(app.getTask('pending')!.title, 'Unsent local work');
      expect(app.pendingCount, 1);
      expect(app.conflicts.single.serverVersion, 1);
      final saved = storage.workspaces.values.single;
      expect(saved['cursor'], 2);
      expect(
        (saved['outbox'] as List).single['mutationId'],
        originalMutationId,
      );
    },
  );

  test(
    'unrelated HTTP 400 does not reset the sync cursor or silently retry',
    () async {
      final storage = MemoryStorage();
      final server = FakeServer();
      final app = AppController(storage: storage, apiFactory: server.api);
      addTearDown(app.dispose);
      await login(app);
      await app.saveTask(const TaskItem(id: 'cached', title: 'Cached'));
      await app.sync();
      server.syncCursors.clear();
      server.failNextSyncBadRequest = true;
      await app.sync();
      expect(server.syncCursors, [1]);
      expect(storage.workspaces.values.single['cursor'], 1);
      expect(app.syncError, 'Another validation error.');
    },
  );

  test('calendar recurrence clamps month ends, including leap year', () {
    expect(
      nextRecurrenceDate(DateTime(2026, 1, 31), 'monthly'),
      DateTime(2026, 2, 28),
    );
    expect(
      nextRecurrenceDate(DateTime(2028, 1, 31), 'monthly'),
      DateTime(2028, 2, 29),
    );
    expect(
      nextRecurrenceDate(DateTime(2026, 12, 31), 'monthly'),
      DateTime(2027, 1, 31),
    );
    expect(
      nextRecurrenceDate(DateTime(2026, 12, 31), 'daily'),
      DateTime(2027, 1, 1),
    );
  });

  test('copyWith can clear nullable fields and date payload is local', () {
    final task = TaskItem(
      id: 'test',
      title: 'Test',
      dueDate: DateTime(2026, 10, 20, 23, 59),
      dueTime: '23:59',
      reminderMinutes: 15,
    );
    expect(task.toPayload()['dueDate'], '2026-10-20');
    final cleared = task.copyWith(
      dueDate: null,
      dueTime: null,
      reminderMinutes: null,
    );
    expect(cleared.dueDate, isNull);
    expect(cleared.dueTime, isNull);
    expect(cleared.reminderMinutes, isNull);
  });

  test('inflight acceptance never erases a newer edit', () async {
    final storage = MemoryStorage();
    final server = FakeServer();
    final app = AppController(storage: storage, apiFactory: server.api);
    addTearDown(app.dispose);
    await login(app);
    await app.saveTask(const TaskItem(id: 'task', title: 'First'));
    server.pauseNextSync();
    final syncing = app.sync();
    await server.entered!.future;
    await app.saveTask(app.getTask('task')!.copyWith(title: 'Newer edit'));
    server.release!.complete();
    await syncing;
    expect(app.getTask('task')!.title, 'Newer edit');
    expect(app.getTask('task')!.version, 2);
    expect(app.pendingCount, 0);
    expect(server.submitted.last['baseVersion'], 1);
    expect(
      server.submitted.first['mutationId'],
      isNot(server.submitted.last['mutationId']),
    );
    final saved = storage.workspaces.values.single;
    expect((saved['outbox'] as List), isEmpty);
    expect((saved['tasks'] as List).single['payload']['title'], 'Newer edit');
  });

  test(
    'conflict keeps both versions and resolving local uses a fresh id',
    () async {
      final storage = MemoryStorage();
      final server = FakeServer();
      final app = AppController(storage: storage, apiFactory: server.api);
      addTearDown(app.dispose);
      await login(app);
      await app.saveTask(const TaskItem(id: 'task', title: 'Original'));
      await app.sync();
      server.remoteEdit('a@example.test', 'task', 'Other device');
      await app.saveTask(app.getTask('task')!.copyWith(title: 'Local edit'));
      await app.sync();
      expect(app.conflicts, hasLength(1));
      expect(app.conflicts.single.localTitle, 'Local edit');
      expect(app.conflicts.single.serverTitle, 'Other device');
      expect(app.getTask('task')!.title, 'Local edit');
      final conflictedMutation = server.submitted.last['mutationId'];
      await app.saveTask(
        app.getTask('task')!.copyWith(title: 'Latest local edit'),
      );
      expect(app.conflicts.single.localTitle, 'Latest local edit');
      await app.resolveConflict('task', keepLocal: true);
      await app.sync();
      expect(app.conflicts, isEmpty);
      expect(app.getTask('task')!.title, 'Latest local edit');
      expect(app.getTask('task')!.version, 3);
      expect(server.submitted.last['mutationId'], isNot(conflictedMutation));
      expect(server.submitted.last['baseVersion'], 2);
    },
  );

  test('accepting server conflict drops queued local version', () async {
    final server = FakeServer();
    final app = AppController(storage: MemoryStorage(), apiFactory: server.api);
    addTearDown(app.dispose);
    await login(app);
    await app.saveTask(const TaskItem(id: 'task', title: 'Original'));
    await app.sync();
    server.remoteEdit('a@example.test', 'task', 'Server chosen');
    await app.saveTask(app.getTask('task')!.copyWith(title: 'Local'));
    await app.sync();
    await app.resolveConflict('task', keepLocal: false);
    expect(app.pendingCount, 0);
    expect(app.conflicts, isEmpty);
    expect(app.getTask('task')!.title, 'Server chosen');
  });

  test('offline restart loads editable cache and persistent outbox', () async {
    final storage = MemoryStorage();
    final server = FakeServer();
    final first = AppController(storage: storage, apiFactory: server.api);
    await login(first);
    server.offline = true;
    await first.saveTask(
      const TaskItem(id: 'offline', title: 'Before restart'),
    );
    first.dispose();
    storage.tokens.clear();
    final second = AppController(storage: storage, apiFactory: server.api);
    addTearDown(second.dispose);
    await second.initialize();
    expect(second.authenticated, isTrue);
    expect(second.requiresLogin, isTrue);
    expect(second.getTask('offline')!.title, 'Before restart');
    expect(second.pendingCount, 1);
    await second.saveTask(
      second.getTask('offline')!.copyWith(title: 'Edited while offline'),
    );
    expect(second.getTask('offline')!.title, 'Edited while offline');
    expect(storage.workspaces.values.single['outbox'], hasLength(1));
  });

  test(
    'demo and accounts are isolated, logout clears visible content',
    () async {
      final storage = MemoryStorage();
      final server = FakeServer();
      final app = AppController(storage: storage, apiFactory: server.api);
      addTearDown(app.dispose);
      await app.enterDemo();
      expect(app.tasks, isNotEmpty);
      await app.saveTask(
        const TaskItem(id: 'demo-only', title: 'Example only'),
      );
      expect(app.pendingCount, 0);
      await login(app);
      expect(app.tasks, isEmpty);
      expect(server.submitted, isEmpty);
      await app.saveTask(const TaskItem(id: 'private-a', title: 'Account A'));
      await app.sync();
      await login(app, 'b@example.test');
      expect(app.getTask('private-a'), isNull);
      await app.saveTask(const TaskItem(id: 'private-b', title: 'Account B'));
      await app.sync();
      await login(app);
      expect(app.getTask('private-a')!.title, 'Account A');
      expect(app.getTask('private-b'), isNull);
      expect(app.getTask('demo-only'), isNull);
      await app.signOut();
      expect(app.user, isNull);
      expect(app.tasks, isEmpty);
      expect(storage.active, isNull);
    },
  );

  test(
    'completion makes one next occurrence and deleting list moves tasks',
    () async {
      final app = AppController(storage: MemoryStorage());
      addTearDown(app.dispose);
      await app.enterDemo();
      await app.saveList(const ProjectList(id: 'custom', name: 'Custom'));
      await app.saveTask(
        TaskItem(
          id: 'repeat',
          title: 'Monthly',
          listId: 'custom',
          dueDate: DateTime(2026, 1, 31),
          recurrence: 'monthly',
          subtasks: const [SubTask(id: 'sub', title: 'Part', completed: true)],
        ),
      );
      await app.toggleTask('repeat');
      final next = app.tasks
          .where((task) => task.title == 'Monthly' && task.id != 'repeat')
          .single;
      expect(next.dueDate, DateTime(2026, 2, 28));
      expect(next.completed, isFalse);
      expect(next.subtasks.single.completed, isFalse);
      await app.toggleTask('repeat');
      await app.toggleTask('repeat');
      expect(app.tasks.where((task) => task.title == 'Monthly'), hasLength(2));
      await app.deleteList('custom');
      expect(app.tasks.where((task) => task.listId == 'custom'), isEmpty);
      expect(app.getTask('repeat')!.listId, 'inbox');
    },
  );

  test(
    'concurrent sync calls share one refresh and rotate stored token',
    () async {
      final storage = MemoryStorage();
      final server = FakeServer();
      final app = AppController(storage: storage, apiFactory: server.api);
      addTearDown(app.dispose);
      await login(app);
      server.expireAccessOnce = true;
      await Future.wait([app.sync(), app.sync(), app.sync()]);
      expect(server.refreshCalls, 1);
      expect(storage.tokens.values.single, endsWith('#rotated'));
      expect(app.syncError, isNull);
    },
  );

  test(
    'uncertain refresh is not replayed with an already-used token',
    () async {
      final storage = MemoryStorage();
      final server = FakeServer();
      final app = AppController(storage: storage, apiFactory: server.api);
      addTearDown(app.dispose);
      await login(app);
      server.expireAccessOnce = true;
      server.failRefresh = true;
      await app.sync();
      expect(app.requiresLogin, isTrue);
      expect(storage.tokens, isEmpty);
      expect(app.syncError, contains('重新登录'));
      await app.sync();
      expect(server.refreshCalls, 1);
    },
  );

  test(
    'two offline devices create the same next recurrence identity',
    () async {
      final first = AppController(storage: MemoryStorage());
      final second = AppController(storage: MemoryStorage());
      addTearDown(first.dispose);
      addTearDown(second.dispose);
      await first.enterDemo();
      await second.enterDemo();
      final task = TaskItem(
        id: 'shared-parent-task',
        title: 'Shared recurring task',
        dueDate: DateTime(2026, 10, 20),
        recurrence: 'daily',
        subtasks: const [SubTask(id: 'shared-subtask', title: 'Part')],
      );
      for (final app in [first, second]) {
        await app.saveTask(task);
        await app.toggleTask(task.id);
      }
      TaskItem next(AppController app) => app.tasks.singleWhere(
        (t) => t.title == task.title && t.id != task.id,
      );
      expect(next(first).id, next(second).id);
      expect(next(first).subtasks.single.id, next(second).subtasks.single.id);
    },
  );
}
