import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:dayflow/core/api_client.dart';
import 'package:dayflow/core/app_controller.dart';
import 'package:dayflow/core/attachments.dart';
import 'package:dayflow/core/models.dart';

import 'core_controller_test.dart' show MemoryStorage, login;

class MemoryAttachmentBytes implements AttachmentBytesStore {
  final data = <String, Uint8List>{};
  @override
  Future<Uint8List?> read(String scope, String id) async => data['$scope/$id'];
  @override
  Future<void> write(String scope, String id, Uint8List bytes) async {
    data['$scope/$id'] = Uint8List.fromList(bytes);
  }

  @override
  Future<void> remove(String scope, String id) async {
    data.remove('$scope/$id');
  }
}

class MemoryPicker implements AttachmentPicker {
  PickedAttachment? selected;
  bool? imagesOnly;
  String? savedName;
  Uint8List? saved;
  @override
  Future<PickedAttachment?> pick({bool imagesOnly = false}) async {
    this.imagesOnly = imagesOnly;
    return selected;
  }

  @override
  Future<void> save(String name, Uint8List bytes) async {
    savedName = name;
    saved = bytes;
  }
}

class AttachmentServer {
  final files = <String, Uint8List>{};
  final items = <String, AttachmentItem>{};
  final uploadIds = <String>[];
  bool loseUploadResponse = false;
  bool offline = false;
  bool corruptDownload = false;
  late final http.Client client = MockClient(handle);
  ApiClient api(String url) => ApiClient(url, client: client);

  Future<http.Response> handle(http.Request request) async {
    if (offline) throw http.ClientException('offline');
    http.Response response(Object value, [int status = 200]) => http.Response(
      jsonEncode(value),
      status,
      headers: {'content-type': 'application/json'},
    );
    final path = request.url.path;
    if (path.endsWith('/login')) {
      final email = (jsonDecode(request.body) as Map)['email'] as String;
      return response({
        'accessToken': email,
        'refreshToken': 'refresh:$email',
        'user': {'id': email, 'email': email, 'name': 'Person'},
      });
    }
    if (path.endsWith('/sync')) {
      return response({
        'cursor': 0,
        'hasMore': false,
        'accepted': [],
        'conflicts': [],
        'changes': [],
      });
    }
    if (path.endsWith('/logout')) return response({'ok': true});
    final owner = (request.headers['authorization'] ?? '').replaceFirst(
      'Bearer ',
      '',
    );
    if (path.endsWith('/attachments')) {
      return response({
        'maxFileBytes': 10 * 1024 * 1024,
        'quotaBytes': 100 * 1024 * 1024,
        'usedBytes': 0,
      });
    }
    final id = request.url.pathSegments.last;
    final key = '$owner/$id';
    if (request.method == 'POST') {
      uploadIds.add(id);
      final bytes = request.bodyBytes;
      files[key] = Uint8List.fromList(bytes);
      final item = AttachmentItem(
        id: id,
        name: request.url.queryParameters['name']!,
        mimeType: 'application/octet-stream',
        size: bytes.length,
        sha256: attachmentDigest(bytes),
      );
      items[key] = item;
      if (loseUploadResponse) {
        loseUploadResponse = false;
        throw http.ClientException('response lost after commit');
      }
      return response(item.toJson(), 201);
    }
    if (!files.containsKey(key)) {
      return response({'detail': 'Attachment not found.'}, 404);
    }
    return http.Response.bytes(corruptDownload ? [0] : files[key]!, 200);
  }
}

void main() {
  test(
    'demo picker keeps real bytes across controller restart and saves the file',
    () async {
      final storage = MemoryStorage();
      final cache = MemoryAttachmentBytes();
      final picker = MemoryPicker()
        ..selected = PickedAttachment(
          '说明.txt',
          Uint8List.fromList(utf8.encode('内容')),
        );
      final first = AppController(
        storage: storage,
        attachmentBytes: cache,
        attachmentPicker: picker,
      );
      await first.enterDemo();
      final item = (await first.pickAttachment(imagesOnly: false))!;
      expect(item.name, '说明.txt');
      expect(item.sha256, attachmentDigest(picker.selected!.bytes));
      await first.saveTask(
        TaskItem(id: 'with-file', title: 'Local', attachments: [item]),
      );
      first.dispose();
      final second = AppController(
        storage: storage,
        attachmentBytes: cache,
        attachmentPicker: picker,
      );
      addTearDown(second.dispose);
      await second.enterDemo();
      final restored = second.getTask('with-file')!.attachments.single;
      expect(await second.downloadAttachment(restored), picker.selected!.bytes);
      await second.saveAttachmentToDevice(restored);
      expect(picker.savedName, '说明.txt');
      expect(picker.saved, picker.selected!.bytes);
      expect(second.pendingCount, 0);
    },
  );

  test(
    'failed cloud upload adds no metadata and retry reuses its immutable id',
    () async {
      final server = AttachmentServer();
      final app = AppController(
        storage: MemoryStorage(),
        apiFactory: server.api,
        attachmentBytes: MemoryAttachmentBytes(),
      );
      addTearDown(app.dispose);
      await login(app);
      final bytes = Uint8List.fromList(utf8.encode('真实附件'));
      server.loseUploadResponse = true;
      await expectLater(
        app.addAttachmentBytes(name: '附件.txt', bytes: bytes),
        throwsA(isA<ApiException>()),
      );
      expect(app.tasks, isEmpty);
      expect(app.pendingCount, 0);
      final item = await app.addAttachmentBytes(name: '附件.txt', bytes: bytes);
      expect(server.uploadIds, hasLength(2));
      expect(server.uploadIds.first, server.uploadIds.last);
      expect(server.files, hasLength(1));
      expect(item.sha256, attachmentDigest(bytes));
      expect(await app.downloadAttachment(item), bytes);
    },
  );

  test(
    'other account cannot reuse cached attachment and downloads verify digest',
    () async {
      final server = AttachmentServer();
      final cache = MemoryAttachmentBytes();
      final app = AppController(
        storage: MemoryStorage(),
        apiFactory: server.api,
        attachmentBytes: cache,
      );
      addTearDown(app.dispose);
      await login(app);
      final item = await app.addAttachmentBytes(
        name: 'private.txt',
        bytes: Uint8List.fromList([65, 66]),
      );
      await login(app, 'b@example.test');
      await expectLater(
        app.downloadAttachment(item),
        throwsA(isA<ApiException>().having((e) => e.statusCode, 'status', 404)),
      );
      await login(app);
      cache.data.clear();
      server.corruptDownload = true;
      await expectLater(
        app.downloadAttachment(item),
        throwsA(
          isA<ApiException>().having(
            (e) => e.message,
            'message',
            contains('SHA-256'),
          ),
        ),
      );
      expect(cache.data, isEmpty);
    },
  );

  test('offline upload fails explicitly while an already cached attachment remains available', () async {
    final server = AttachmentServer();
    final app = AppController(
      storage: MemoryStorage(),
      apiFactory: server.api,
      attachmentBytes: MemoryAttachmentBytes(),
    );
    addTearDown(app.dispose);
    await login(app);
    final bytes = Uint8List.fromList([65, 66]);
    final item = await app.addAttachmentBytes(name: 'cached.txt', bytes: bytes);
    server.offline = true;
    expect(await app.downloadAttachment(item), bytes);
    await expectLater(
      app.addAttachmentBytes(name: 'new.txt', bytes: bytes),
      throwsA(isA<ApiException>()),
    );
    expect(app.pendingCount, 0);
  });
}
