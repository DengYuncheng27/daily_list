import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:hive_ce/hive.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import 'api_client.dart';
import 'models.dart';

const attachmentImageExtensions = ['png', 'jpg', 'jpeg', 'webp'];
const attachmentExtensions = [
  ...attachmentImageExtensions,
  'pdf',
  'txt',
  'md',
  'csv',
  'json',
  'doc',
  'docx',
  'xls',
  'xlsx',
  'ppt',
  'pptx',
  'zip',
  'mp3',
  'wav',
  'rtf',
];
const demoAttachmentMaxBytes = 10 * 1024 * 1024;

class PickedAttachment {
  final String name;
  final Uint8List bytes;
  const PickedAttachment(this.name, this.bytes);
}

abstract class AttachmentPicker {
  Future<PickedAttachment?> pick({bool imagesOnly = false});
  Future<void> save(String name, Uint8List bytes);
}

class SystemAttachmentPicker implements AttachmentPicker {
  @override
  Future<PickedAttachment?> pick({bool imagesOnly = false}) async {
    final file = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: imagesOnly
          ? attachmentImageExtensions
          : attachmentExtensions,
    );
    if (file == null) return null;
    final length = file.lengthSync() ?? await file.length();
    if (length != null && length > 100 * 1024 * 1024) {
      throw const ApiException(0, '附件不能超过 100 MiB。');
    }
    // Bound streaming reads even when a provider cannot report a file length.
    final builder = BytesBuilder(copy: false);
    await for (final chunk in file.readAsByteStream()) {
      if (builder.length + chunk.length > 100 * 1024 * 1024) {
        throw const ApiException(0, '附件不能超过 100 MiB。');
      }
      builder.add(chunk);
    }
    return PickedAttachment(file.name, builder.takeBytes());
  }

  @override
  Future<void> save(String name, Uint8List bytes) async {
    await FilePicker.saveFile(
      fileName: name,
      bytes: bytes,
      dialogTitle: '保存附件',
    );
  }
}

abstract class AttachmentBytesStore {
  Future<Uint8List?> read(String scope, String id);
  Future<void> write(String scope, String id, Uint8List bytes);
  Future<void> remove(String scope, String id);
}

/// IndexedDB on Web; an application support directory on native platforms.
/// A lazy box avoids loading every file into memory on application startup.
class LocalAttachmentBytesStore implements AttachmentBytesStore {
  static Future<LazyBox<Uint8List>>? _opening;
  Future<LazyBox<Uint8List>> _box() => _opening ??= _open();

  static Future<LazyBox<Uint8List>> _open() async {
    try {
      if (!kIsWeb) {
        final directory = await getApplicationSupportDirectory();
        Hive.init('${directory.path}/dayflow-attachments');
      }
      return await Hive.openLazyBox<Uint8List>(
        'dayflow-private-attachments-v1',
      );
    } catch (_) {
      _opening = null;
      rethrow;
    }
  }

  String _key(String scope, String id) =>
      '${sha256.convert(utf8.encode(scope))}:$id';

  @override
  Future<Uint8List?> read(String scope, String id) async =>
      (await _box()).get(_key(scope, id));

  @override
  Future<void> write(String scope, String id, Uint8List bytes) async {
    try {
      await (await _box()).put(_key(scope, id), bytes);
    } catch (_) {
      throw const ApiException(0, '无法保存本机附件，请检查存储空间。附件尚未加入任务。');
    }
  }

  @override
  Future<void> remove(String scope, String id) async =>
      (await _box()).delete(_key(scope, id));
}

String attachmentDigest(Uint8List bytes) => sha256.convert(bytes).toString();

AttachmentItem localAttachment(String scope, String name, Uint8List bytes) {
  final extension = name.split('.').last.toLowerCase();
  if (!attachmentExtensions.contains(extension) ||
      name.length > 180 ||
      name.trim() != name ||
      RegExp(r'[<>:"/\\|?*\x00-\x1f\x7f]').hasMatch(name)) {
    throw const ApiException(0, '不支持的附件类型或文件名。');
  }
  final digest = attachmentDigest(bytes);
  // Re-picking the same file retries the same immutable upload ID, including
  // when the server committed the first upload but its response was lost.
  final id = const Uuid().v5(
    '6ba7b811-9dad-11d1-80b4-00c04fd430c8',
    '$scope\n$name\n$digest',
  );
  final mime = switch (extension) {
    'png' => 'image/png',
    'jpg' || 'jpeg' => 'image/jpeg',
    'webp' => 'image/webp',
    _ => 'application/octet-stream',
  };
  return AttachmentItem(
    id: id,
    name: name,
    mimeType: mime,
    size: bytes.length,
    sha256: digest,
  );
}

void verifyAttachmentBytes(AttachmentItem item, Uint8List bytes) {
  if (bytes.length != item.size || attachmentDigest(bytes) != item.sha256) {
    throw const ApiException(0, '附件校验失败，文件大小或 SHA-256 不匹配。');
  }
}
