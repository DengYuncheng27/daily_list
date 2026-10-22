import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:hive_ce/hive.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

abstract class AppStorage {
  Future<Map<String, dynamic>?> readActiveAccount();
  Future<void> writeActiveAccount(Map<String, dynamic>? account);
  Future<Map<String, dynamic>?> readWorkspace(String key);
  Future<void> writeWorkspace(String key, Map<String, dynamic> workspace);
  Future<String?> readRefreshToken(String key);
  Future<void> writeRefreshToken(String key, String? token);
}

abstract class WorkspaceDocumentStore {
  Future<String?> read(String key);
  Future<void> write(String key, String document);
}

/// A workspace is one durable record, including its sync outbox. IndexedDB on
/// Web avoids the small localStorage quota; native platforms use Hive files.
class HiveWorkspaceDocumentStore implements WorkspaceDocumentStore {
  static Future<LazyBox<String>>? _opening;
  final Future<LazyBox<String>> Function() _openBox;

  HiveWorkspaceDocumentStore({Future<LazyBox<String>> Function()? openBox})
    : _openBox = openBox ?? _sharedBox;

  static Future<LazyBox<String>> _sharedBox() => _opening ??= _open();

  static Future<LazyBox<String>> _open() async {
    try {
      final directory = kIsWeb ? null : await getApplicationSupportDirectory();
      return await Hive.openLazyBox<String>(
        'dayflow-workspaces-v2',
        // Use an explicit path so the attachment store's Hive.init cannot
        // redirect workspace files depending on startup order.
        path: directory == null ? null : '${directory.path}/dayflow-workspaces',
      );
    } catch (_) {
      _opening = null;
      rethrow;
    }
  }

  @override
  Future<String?> read(String key) async => (await _openBox()).get(key);

  @override
  Future<void> write(String key, String document) async =>
      (await _openBox()).put(key, document);
}

/// Task caches are account-specific application data. Native refresh tokens use
/// OS-backed secure storage. Web tokens never enter localStorage: a reload needs
/// login again to sync, while its cached workspace remains editable offline.
class LocalStorage implements AppStorage {
  final FlutterSecureStorage _secure;
  final Future<SharedPreferences> Function() _preferences;
  final WorkspaceDocumentStore _workspaces;
  final Map<String, String> _webSessionTokens = {};
  LocalStorage({
    FlutterSecureStorage secureStorage = const FlutterSecureStorage(),
    Future<SharedPreferences> Function()? preferences,
    WorkspaceDocumentStore? workspaceStore,
  }) : _secure = secureStorage,
       _preferences = preferences ?? SharedPreferences.getInstance,
       _workspaces = workspaceStore ?? HiveWorkspaceDocumentStore();

  Map<String, dynamic> _decodeWorkspace(String raw) {
    final json = jsonDecode(raw);
    if (json is! Map) throw const FormatException('本机缓存格式不正确');
    return Map<String, dynamic>.from(json);
  }

  Future<Map<String, dynamic>?> _read(String key) async {
    final raw = (await _preferences()).getString(key);
    if (raw == null) return null;
    final json = jsonDecode(raw);
    if (json is! Map) throw const FormatException('本机缓存格式不正确');
    return Map<String, dynamic>.from(json);
  }

  Future<void> _write(String key, Map<String, dynamic>? value) async {
    final prefs = await _preferences();
    final ok = value == null
        ? await prefs.remove(key)
        : await prefs.setString(key, jsonEncode(value));
    if (!ok) throw StateError('无法写入本机存储，请检查剩余空间。');
  }

  @override
  Future<Map<String, dynamic>?> readActiveAccount() =>
      _read('dayflow.active-account.v1');

  @override
  Future<void> writeActiveAccount(Map<String, dynamic>? account) =>
      _write('dayflow.active-account.v1', account);

  @override
  Future<Map<String, dynamic>?> readWorkspace(String key) async {
    final current = await _workspaces.read(key);
    if (current != null) return _decodeWorkspace(current);
    final legacyKey = 'dayflow.workspace.v1.${Uri.encodeComponent(key)}';
    final legacy = await _read(legacyKey);
    if (legacy == null) return null;
    try {
      await _workspaces.write(key, jsonEncode(legacy));
      await (await _preferences()).remove(legacyKey);
    } catch (_) {
      // The original remains available if migration hits a full disk/quota.
      // A later edit/import still reports its own failed durable write.
    }
    return legacy;
  }

  @override
  Future<void> writeWorkspace(
    String key,
    Map<String, dynamic> workspace,
  ) async {
    await _workspaces.write(key, jsonEncode(workspace));
    // Removing an obsolete copy is cleanup, not part of the successful write.
    try {
      await (await _preferences()).remove(
        'dayflow.workspace.v1.${Uri.encodeComponent(key)}',
      );
    } catch (_) {}
  }

  @override
  Future<String?> readRefreshToken(String key) async {
    if (kIsWeb) return _webSessionTokens[key];
    return _secure.read(key: 'dayflow.refresh.${Uri.encodeComponent(key)}');
  }

  @override
  Future<void> writeRefreshToken(String key, String? token) async {
    if (kIsWeb) {
      if (token == null) {
        _webSessionTokens.remove(key);
      } else {
        _webSessionTokens[key] = token;
      }
      return;
    }
    final secureKey = 'dayflow.refresh.${Uri.encodeComponent(key)}';
    if (token == null) {
      await _secure.delete(key: secureKey);
    } else {
      await _secure.write(key: secureKey, value: token);
    }
  }
}
