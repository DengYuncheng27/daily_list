import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:uuid/uuid.dart';

import 'package:dayflow/core/app_controller.dart';
import 'package:dayflow/core/models.dart';
import 'package:dayflow/core/ticktick_import.dart';

import 'core_controller_test.dart' show MemoryStorage, FakeServer, login;

const _uuid = Uuid();
String _id(String seed) => _uuid.v5(Namespace.url.value, 'import-test:$seed');

TickTickImportPreview _preview(
  List<TaskItem> tasks, {
  List<ProjectList> lists = const [],
}) => TickTickImportPreview(
  sourceName: 'test.csv',
  sourceAccount: 'synthetic',
  fileSha256: 'synthetic',
  lists: lists,
  records: [
    for (var i = 0; i < tasks.length; i++)
      TickTickImportRecord(
        task: tasks[i],
        row: i + 2,
        sourceId: tasks[i].id,
        sourceParentId: '',
        folderName: '',
        listName: '',
        rawFields: const {},
        warnings: const [],
      ),
  ],
  warnings: const [],
  metadata: const {},
);

class _ImportStorage extends MemoryStorage {
  int writes = 0;
  bool failNextWrite = false;
  bool failRead = false;
  Completer<void>? entered;
  Completer<void>? release;

  void pauseNextWrite() {
    entered = Completer<void>();
    release = Completer<void>();
  }

  @override
  Future<Map<String, dynamic>?> readWorkspace(String key) async {
    if (failRead) throw StateError('workspace unavailable');
    return super.readWorkspace(key);
  }

  @override
  Future<void> writeWorkspace(
    String key,
    Map<String, dynamic> workspace,
  ) async {
    writes++;
    if (failNextWrite) {
      failNextWrite = false;
      throw StateError('storage full');
    }
    if (entered != null && !entered!.isCompleted) {
      entered!.complete();
      await release!.future;
    }
    await super.writeWorkspace(key, workspace);
  }
}

void main() {
  test(
    'failed workspace load cannot overwrite an unread offline cache',
    () async {
      final store = _ImportStorage();
      final server = FakeServer();
      final first = AppController(storage: store, apiFactory: server.api);
      await login(first);
      final original = TaskItem(id: _id('unread'), title: '唯一的未同步数据');
      await first.saveTask(original);
      first.dispose();
      final preserved = jsonEncode(store.workspaces);
      store.failRead = true;
      store.writes = 0;
      final restarted = AppController(storage: store, apiFactory: server.api);
      addTearDown(restarted.dispose);
      await restarted.initialize();
      expect(restarted.syncError, contains('读取本机数据失败'));
      await expectLater(
        restarted.saveTask(TaskItem(id: _id('unsafe-new'), title: '不应覆盖')),
        throwsStateError,
      );
      await restarted.sync();
      await restarted.signOut();
      expect(store.writes, 0);
      expect(jsonEncode(store.workspaces), preserved);
      store.failRead = false;
      await login(restarted);
      expect(restarted.getTask(original.id)!.title, original.title);
    },
  );

  test(
    'malformed cached entities cannot cause partial-cache overwrite',
    () async {
      final store = _ImportStorage();
      final server = FakeServer();
      final first = AppController(storage: store, apiFactory: server.api);
      await login(first);
      first.dispose();
      store.workspaces.values.single['tasks'] = [
        TaskItem(id: _id('valid'), title: '有效项').toEntity(),
        {
          'payload': {'title': '损坏的本地条目缺少 ID'},
        },
      ];
      final preserved = jsonEncode(store.workspaces);
      store.writes = 0;
      final restarted = AppController(storage: store, apiFactory: server.api);
      addTearDown(restarted.dispose);
      await restarted.initialize();
      expect(restarted.syncError, contains('读取本机数据失败'));
      await expectLater(restarted.deleteTask(_id('valid')), throwsStateError);
      await restarted.signOut();
      expect(store.writes, 0);
      expect(jsonEncode(store.workspaces), preserved);
    },
  );

  const tcpServer = String.fromEnvironment('DAYFLOW_IMPORT_E2E_URL');
  test(
    'real TCP CSV import reaches a second device without lost fields',
    () async {
      final first = AppController(storage: MemoryStorage());
      final second = AppController(storage: MemoryStorage());
      addTearDown(first.dispose);
      addTearDown(second.dispose);
      final email = 'dayflow-import-${_uuid.v4()}@example.com';
      final password = '${_uuid.v4()}-${_uuid.v4()}';
      await first.register(
        email: email,
        password: password,
        name: 'Synthetic CSV import validation',
        serverUrl: tcpServer,
      );
      final columns = [
        'Title',
        'Folder Name',
        'List Name',
        'Tags',
        'Content',
        'Is Check list',
        'Start Date',
        'Due Date',
        'Reminder',
        'Repeat',
        'Priority',
        'Status',
        'Completed Time',
        'Timezone',
        'Is All Day',
        'taskId',
        'parentId',
        'Kind',
        'Custom Export Field',
      ];
      String csvRow(List<String> values) =>
          values.map((value) => '"${value.replaceAll('"', '""')}"').join(',');
      final csv = [
        csvRow(columns),
        csvRow([
          '跨设备导入：日期、检查项、重复',
          '工作区',
          '研发',
          '产品,迁移',
          '▫ 待办子项\n▪ 已完成子项\n正文包含 "引号",逗号\n',
          'true',
          '2026-10-22T09:00:00+08:00',
          '2026-10-23T18:00:00+08:00',
          'TRIGGER:-PT30M',
          'FREQ=WEEKLY;BYDAY=MO,TH;INTERVAL=2',
          '5',
          '0',
          '',
          'Asia/Shanghai',
          'false',
          'abc123de4567890123456789',
          '',
          'CHECKLIST',
          '原字段必须保全',
        ]),
        csvRow([
          '已完成历史任务',
          '',
          '个人',
          '',
          '历史正文',
          'false',
          '2026-10-19T09:30:00+08:00',
          '',
          '',
          'FREQ=DAILY',
          '3',
          '1',
          '2026-10-19T10:00:00+08:00',
          'Asia/Shanghai',
          'false',
          'abc123de4567890123456790',
          '',
          'TEXT',
          '',
        ]),
        csvRow([
          '保留图片引用的笔记',
          '',
          '资料',
          '记录',
          '# 标题\n**粗体原文**\n![截图](https://example.com/private.png)',
          'false',
          '',
          '',
          '',
          '',
          '0',
          '0',
          '',
          'Asia/Shanghai',
          'true',
          'abc123de4567890123456791',
          '',
          'NOTE',
          '附件内容不伪造',
        ]),
        for (var i = 0; i < 500; i++)
          csvRow([
            '批量任务 $i',
            '',
            '批量',
            '',
            '',
            'false',
            '',
            '',
            '',
            '',
            '0',
            '0',
            '',
            '',
            'true',
            _id('tcp-$i'),
            '',
            'TEXT',
            '合成测试数据',
          ]),
      ].join('\r\n');
      final preview = TickTickImport.parseBytes(
        utf8.encode(csv),
        sourceName: 'synthetic-tcp.csv',
        sourceAccount: 'synthetic-tcp',
      );
      final applied = await first.importTickTick(
        preview,
        expectedWorkspaceRevision: first.workspaceRevision,
      );
      expect(applied.importedTasks, 503);
      await first.sync();
      expect(first.syncError, isNull);
      expect(first.pendingCount, 0);
      expect(first.tasks, hasLength(503));
      await second.signIn(
        email: email,
        password: password,
        serverUrl: tcpServer,
      );
      expect(second.syncError, isNull);
      expect(second.tasks, hasLength(503));
      for (final source in preview.tasks) {
        final received = second.getTask(source.id);
        expect(received, isNotNull);
        expect(received!.toPayload(), source.toPayload());
      }
      final repeat = await second.importTickTick(
        preview,
        expectedWorkspaceRevision: second.workspaceRevision,
      );
      expect(repeat.importedTasks, 0);
      expect(repeat.skippedTasks, 503);
      expect(second.pendingCount, 0);
      expect(
        second.tasks.firstWhere((t) => t.title == '保留图片引用的笔记').attachments,
        isEmpty,
      );
      final edited = second.tasks.first;
      await second.saveTask(edited.copyWith(title: '导入后由第二设备编辑'));
      await second.sync();
      await first.sync();
      expect(first.getTask(edited.id)!.title, '导入后由第二设备编辑');
      expect(first.getTask(edited.id)!.importData, edited.importData);
      await first.signOut();
      await second.signOut();
    },
    skip: tcpServer.isEmpty
        ? 'Set DAYFLOW_IMPORT_E2E_URL to an isolated/local test API.'
        : false,
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test('large import is one durable write then bounded sync batches', () async {
    final store = _ImportStorage();
    final server = FakeServer();
    final app = AppController(storage: store, apiFactory: server.api);
    addTearDown(app.dispose);
    await login(app);
    final list = ProjectList(id: _id('list'), name: '迁移工作清单');
    final imported = [
      for (var i = 0; i < 1001; i++)
        TaskItem(id: _id('large-$i'), title: '导入任务 $i', listId: list.id),
    ];
    final preview = _preview(imported, lists: [list]);
    store.writes = 0;
    final result = await app.importTickTick(
      preview,
      expectedWorkspaceRevision: app.workspaceRevision,
    );
    expect(store.writes, 1);
    expect(result.importedTasks, 1001);
    expect(result.importedLists, 1);
    expect(result.skippedTasks, 0);
    expect(app.pendingCount, 1002);
    expect((store.workspaces.values.single['outbox'] as List), hasLength(1002));

    server.syncBatchCounts.clear();
    await app.sync();
    expect(app.syncError, isNull);
    expect(app.pendingCount, 0);
    expect(server.syncBatchCounts, [500, 500, 2]);
    expect(server.syncBodyBytes, everyElement(lessThanOrEqualTo(1536 * 1024)));
    final second = AppController(
      storage: MemoryStorage(),
      apiFactory: server.api,
    );
    addTearDown(second.dispose);
    await login(second);
    expect(second.tasks, hasLength(1001));
    expect(second.tasks.every((task) => task.listId == list.id), isTrue);
  });

  test(
    'reimport preserves edited tasks, deleted tasks and deleted lists',
    () async {
      final store = _ImportStorage();
      final server = FakeServer();
      final app = AppController(storage: store, apiFactory: server.api);
      addTearDown(app.dispose);
      await login(app);
      final list = ProjectList(id: _id('removed-list'), name: '旧清单');
      final a = TaskItem(id: _id('edited'), title: '原始名称', listId: list.id);
      final b = TaskItem(id: _id('deleted'), title: '不要恢复');
      final preview = _preview([a, b], lists: [list]);
      await app.importTickTick(
        preview,
        expectedWorkspaceRevision: app.workspaceRevision,
      );
      await app.saveTask(app.getTask(a.id)!.copyWith(title: '用户已修改'));
      await app.deleteTask(b.id);
      await app.deleteList(list.id);
      store.writes = 0;
      final repeated = await app.importTickTick(
        preview,
        expectedWorkspaceRevision: app.workspaceRevision,
      );
      expect(repeated.importedTasks, 0);
      expect(repeated.skippedTasks, 2);
      expect(repeated.skippedLists, 1);
      expect(store.writes, 0);
      expect(app.getTask(a.id)!.title, '用户已修改');
      expect(app.getTask(a.id)!.listId, 'inbox');
      expect(app.getTask(b.id), isNull);
      expect(app.lists.any((entry) => entry.id == list.id), isFalse);

      final extra = TaskItem(
        id: _id('new-in-deleted-list'),
        title: '新任务',
        listId: list.id,
      );
      await app.importTickTick(
        _preview([extra], lists: [list]),
        expectedWorkspaceRevision: app.workspaceRevision,
      );
      expect(app.getTask(extra.id)!.listId, 'inbox');
    },
  );

  test('historical completed recurrence never creates a successor', () async {
    final app = AppController(storage: MemoryStorage());
    addTearDown(app.dispose);
    await app.enterDemo();
    final before = app.tasks.length;
    final completed = TaskItem(
      id: _id('completed-rule'),
      title: '已完成的历史任务',
      completed: true,
      completedAt: DateTime.utc(2027, 1, 5),
      dueDate: DateTime(2027, 1, 4),
      recurrenceRule: const RecurrenceRule(
        frequency: 'workdays',
        workdayMode: 'china2026',
      ),
    );
    await app.importTickTick(
      _preview([completed]),
      expectedWorkspaceRevision: app.workspaceRevision,
    );
    expect(app.tasks, hasLength(before + 1));
    expect(app.getTask(completed.id)!.completedAt, completed.completedAt);
    expect(app.getTask(completed.id)!.completed, isTrue);
    expect(app.pendingCount, 0);
  });

  test(
    'failed durable write leaves original workspace and outbox unchanged',
    () async {
      final store = _ImportStorage();
      final server = FakeServer();
      final app = AppController(storage: store, apiFactory: server.api);
      addTearDown(app.dispose);
      await login(app);
      await app.saveTask(TaskItem(id: _id('existing'), title: '原数据'));
      final before = jsonEncode(store.workspaces);
      final pending = app.pendingCount;
      final task = TaskItem(id: _id('write-failure'), title: '不能只导入一半');
      store.failNextWrite = true;
      await expectLater(
        app.importTickTick(
          _preview([task]),
          expectedWorkspaceRevision: app.workspaceRevision,
        ),
        throwsStateError,
      );
      expect(app.getTask(task.id), isNull);
      expect(app.pendingCount, pending);
      expect(jsonEncode(store.workspaces), before);
      expect(app.importing, isFalse);
      final retry = await app.importTickTick(
        _preview([task]),
        expectedWorkspaceRevision: app.workspaceRevision,
      );
      expect(retry.importedTasks, 1);
    },
  );

  test(
    'preview from a previous workspace cannot import into another account',
    () async {
      final server = FakeServer();
      final app = AppController(
        storage: MemoryStorage(),
        apiFactory: server.api,
      );
      addTearDown(app.dispose);
      await login(app);
      final revision = app.workspaceRevision;
      final preview = _preview([TaskItem(id: _id('private'), title: '旧账号备份')]);
      await login(app, 'b@example.test');
      await expectLater(
        app.importTickTick(preview, expectedWorkspaceRevision: revision),
        throwsStateError,
      );
      expect(app.tasks, isEmpty);
      await login(app);
      await expectLater(
        app.importTickTick(preview, expectedWorkspaceRevision: revision),
        throwsStateError,
      );
      expect(app.tasks, isEmpty);
    },
  );

  test(
    'import waits for in-flight cloud changes before duplicate detection',
    () async {
      final server = FakeServer();
      final app = AppController(
        storage: MemoryStorage(),
        apiFactory: server.api,
      );
      addTearDown(app.dispose);
      await login(app);
      final task = TaskItem(id: _id('remote'), title: '原始任务');
      await app.saveTask(task);
      await app.sync();
      server.remoteEdit('a@example.test', task.id, '另一设备的新内容');
      server.pauseNextSync();
      final syncing = app.sync();
      await server.entered!.future;
      final importing = app.importTickTick(
        _preview([task]),
        expectedWorkspaceRevision: app.workspaceRevision,
      );
      server.release!.complete();
      await syncing;
      final result = await importing;
      expect(result.skippedTasks, 1);
      expect(app.getTask(task.id)!.title, '另一设备的新内容');
      expect(app.pendingCount, 0);
    },
  );

  test(
    'concurrent edits wait for the import transaction and remain durable',
    () async {
      final store = _ImportStorage();
      final app = AppController(storage: store);
      addTearDown(app.dispose);
      await app.enterDemo();
      final old = app.tasks.first;
      final task = TaskItem(id: _id('concurrent'), title: '正在导入');
      store.pauseNextWrite();
      final importing = app.importTickTick(
        _preview([task]),
        expectedWorkspaceRevision: app.workspaceRevision,
      );
      await store.entered!.future;
      expect(app.getTask(task.id), isNull);
      final edit = app.saveTask(old.copyWith(title: '导入期间编辑'));
      store.release!.complete();
      await importing;
      await edit;
      expect(app.getTask(old.id)!.title, '导入期间编辑');
      expect(app.getTask(task.id), isNotNull);
      final cached = (store.workspaces['demo']!['tasks'] as List).map(
        (e) => TaskItem.fromEntity(Map<String, dynamic>.from(e)),
      );
      expect(cached.singleWhere((e) => e.id == old.id).title, '导入期间编辑');
      expect(cached.any((e) => e.id == task.id), isTrue);
    },
  );

  test('sign-out during import stores the transaction only in its original account', () async {
    final store = _ImportStorage();
    final server = FakeServer();
    final app = AppController(storage: store, apiFactory: server.api);
    addTearDown(app.dispose);
    await login(app);
    final account = store.workspaces.keys.single;
    final task = TaskItem(id: _id('logout'), title: '原账号导入');
    store.pauseNextWrite();
    final importing = app.importTickTick(
      _preview([task]),
      expectedWorkspaceRevision: app.workspaceRevision,
    );
    await store.entered!.future;
    final logout = app.signOut();
    store.release!.complete();
    await importing;
    await logout;
    expect(app.user, isNull);
    expect(app.tasks, isEmpty);
    expect(
      (store.workspaces[account]!['tasks'] as List).any(
        (e) => e['id'] == task.id,
      ),
      isTrue,
    );
    await login(app, 'b@example.test');
    expect(app.getTask(task.id), isNull);
  });

  test('parallel imports cannot race or overwrite one another', () async {
    final store = _ImportStorage();
    final app = AppController(storage: store);
    addTearDown(app.dispose);
    await app.enterDemo();
    final preview = _preview([TaskItem(id: _id('double'), title: '只导入一次')]);
    store.pauseNextWrite();
    final first = app.importTickTick(
      preview,
      expectedWorkspaceRevision: app.workspaceRevision,
    );
    await store.entered!.future;
    await expectLater(
      app.importTickTick(
        preview,
        expectedWorkspaceRevision: app.workspaceRevision,
      ),
      throwsStateError,
    );
    store.release!.complete();
    await first;
    expect(
      app.tasks.where((task) => task.id == preview.tasks.single.id),
      hasLength(1),
    );
  });
}
