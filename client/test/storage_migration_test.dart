import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:dayflow/core/storage.dart';

class _MemoryDocuments implements WorkspaceDocumentStore {
  final records = <String, String>{};
  bool failWrite = false;
  bool failRead = false;

  @override
  Future<String?> read(String key) async {
    if (failRead) throw StateError('storage unavailable');
    return records[key];
  }

  @override
  Future<void> write(String key, String document) async {
    if (failWrite) throw StateError('storage full');
    records[key] = document;
  }
}

String _legacyKey(String account) =>
    'dayflow.workspace.v1.${Uri.encodeComponent(account)}';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('legacy workspace migrates before its old copy is removed', () async {
    const account = 'https://sync.example.com|person-a';
    final workspace = {
      'tasks': [
        {'id': 'preserved'},
      ],
      'outbox': [
        {'id': 'pending-offline-change'},
      ],
      'cursor': 7,
    };
    SharedPreferences.setMockInitialValues({
      _legacyKey(account): jsonEncode(workspace),
      'dayflow.active-account.v1': jsonEncode({'demo': true}),
    });
    final documents = _MemoryDocuments();
    final storage = LocalStorage(workspaceStore: documents);
    expect(await storage.readWorkspace(account), workspace);
    expect(jsonDecode(documents.records[account]!), workspace);
    expect(
      (await SharedPreferences.getInstance()).containsKey(_legacyKey(account)),
      isFalse,
    );
    expect(await storage.readActiveAccount(), {'demo': true});
    expect(await storage.readWorkspace(account), workspace);
  });

  test(
    'failed migration retains legacy data; failed edit cannot erase it',
    () async {
      const account = 'demo';
      final old = {
        'tasks': ['old'],
        'outbox': <dynamic>[],
      };
      SharedPreferences.setMockInitialValues({
        _legacyKey(account): jsonEncode(old),
      });
      final documents = _MemoryDocuments()..failWrite = true;
      final storage = LocalStorage(workspaceStore: documents);
      expect(await storage.readWorkspace(account), old);
      expect(documents.records, isEmpty);
      expect(
        (await SharedPreferences.getInstance()).getString(_legacyKey(account)),
        jsonEncode(old),
      );
      await expectLater(
        storage.writeWorkspace(account, {
          'tasks': ['new'],
        }),
        throwsStateError,
      );
      expect(await storage.readWorkspace(account), old);
      documents.failWrite = false;
      expect(await storage.readWorkspace(account), old);
      expect(
        (await SharedPreferences.getInstance()).containsKey(
          _legacyKey(account),
        ),
        isFalse,
      );
    },
  );

  test('new store always wins over obsolete legacy copy and never falls back after failure', () async {
    const account = 'server|a';
    SharedPreferences.setMockInitialValues({
      _legacyKey(account): jsonEncode({
        'tasks': ['obsolete'],
      }),
    });
    final documents = _MemoryDocuments();
    documents.records[account] = jsonEncode({
      'tasks': ['current'],
      'outbox': ['unsent'],
    });
    final storage = LocalStorage(workspaceStore: documents);
    expect(await storage.readWorkspace(account), {
      'tasks': ['current'],
      'outbox': ['unsent'],
    });
    documents.failRead = true;
    await expectLater(storage.readWorkspace(account), throwsStateError);
  });

  test(
    'workspace documents keep demo, accounts and different servers isolated',
    () async {
      SharedPreferences.setMockInitialValues({});
      final documents = _MemoryDocuments();
      final storage = LocalStorage(workspaceStore: documents);
      for (final key in [
        'demo',
        'https://a.example|same-user',
        'https://b.example|same-user',
        'https://a.example|other-user',
      ]) {
        await storage.writeWorkspace(key, {'owner': key});
      }
      for (final key in documents.records.keys) {
        expect(await storage.readWorkspace(key), {'owner': key});
      }
      expect(await storage.readWorkspace('unknown'), isNull);
      expect((await SharedPreferences.getInstance()).getKeys(), isEmpty);
    },
  );

  test(
    'real Hive workspace larger than localStorage quota survives reopening',
    () async {
      SharedPreferences.setMockInitialValues({});
      final directory = await Directory.systemTemp.createTemp(
        'dayflow-workspace-test-',
      );
      const boxName = 'large-import-storage-test';
      var box = await Hive.openLazyBox<String>(boxName, path: directory.path);
      addTearDown(() async {
        await box.close();
        final tempRoot = await Directory.systemTemp.resolveSymbolicLinks();
        final resolved = await directory.resolveSymbolicLinks();
        if (!resolved.startsWith(
          '$tempRoot${Platform.pathSeparator}dayflow-workspace-test-',
        )) {
          throw StateError('Refusing to remove an unexpected test directory.');
        }
        await directory.delete(recursive: true);
      });
      final storage = LocalStorage(
        workspaceStore: HiveWorkspaceDocumentStore(openBox: () async => box),
      );
      final large = {
        'notes': '中' * (2 * 1024 * 1024),
        'outbox': ['pending'],
      };
      expect(
        utf8.encode(jsonEncode(large)).length,
        greaterThan(5 * 1024 * 1024),
      );
      await storage.writeWorkspace('large', large);
      await box.close();
      box = await Hive.openLazyBox<String>(boxName, path: directory.path);
      expect(await storage.readWorkspace('large'), large);
      expect((await SharedPreferences.getInstance()).getKeys(), isEmpty);
    },
  );
}
