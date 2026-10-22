import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'models.dart';

class ApiException implements Exception {
  final int statusCode;
  final String message;
  const ApiException(this.statusCode, this.message);
  @override
  String toString() => message;
}

class AuthResult {
  final String accessToken;
  final String refreshToken;
  final AppUser user;
  const AuthResult({
    required this.accessToken,
    required this.refreshToken,
    required this.user,
  });
  factory AuthResult.fromJson(Map<String, dynamic> json) => AuthResult(
    accessToken: json['accessToken'] as String,
    refreshToken: json['refreshToken'] as String,
    user: AppUser.fromJson(Map<String, dynamic>.from(json['user'] as Map)),
  );
}

String normalizeServerUrl(String value) {
  var result = value.trim().replaceAll(RegExp(r'/+$'), '');
  if (result.endsWith('/api/v1')) {
    result = result.substring(0, result.length - 7);
  }
  final uri = Uri.tryParse(result);
  if (uri == null ||
      !['http', 'https'].contains(uri.scheme) ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment ||
      (uri.path.isNotEmpty && uri.path != '/')) {
    throw const ApiException(0, '请输入服务器地址，例如 https://tasks.example.com');
  }
  return uri.origin;
}

class ApiClient {
  final String baseUrl;
  final http.Client _client;
  final bool _ownsClient;
  ApiClient(String serverUrl, {http.Client? client})
    : baseUrl = normalizeServerUrl(serverUrl),
      _client = client ?? http.Client(),
      _ownsClient = client == null;

  Future<Map<String, dynamic>> _post(
    String path,
    Map<String, dynamic> body, {
    String? accessToken,
  }) async {
    http.Response response;
    try {
      response = await _client
          .post(
            Uri.parse('$baseUrl/api/v1$path'),
            headers: {
              'Content-Type': 'application/json',
              if (accessToken != null) 'Authorization': 'Bearer $accessToken',
            },
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 25));
    } on TimeoutException {
      throw const ApiException(0, '连接超时。更改已保存在本机，可稍后重试同步。');
    } on http.ClientException {
      throw const ApiException(0, '无法连接服务器。更改已保存在本机。');
    }
    Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(response.bodyBytes));
    } on FormatException {
      throw ApiException(response.statusCode, '服务器返回了无法识别的响应。');
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final detail = decoded is Map ? decoded['detail'] : null;
      throw ApiException(
        response.statusCode,
        detail is String ? detail : '请求失败（${response.statusCode}）',
      );
    }
    if (decoded is! Map) {
      throw ApiException(response.statusCode, '服务器响应格式不正确。');
    }
    return Map<String, dynamic>.from(decoded);
  }

  Future<AuthResult> signIn({
    required String email,
    required String password,
  }) async => AuthResult.fromJson(
    await _post('/auth/login', {'email': email, 'password': password}),
  );

  Future<AuthResult> register({
    required String email,
    required String password,
    required String name,
  }) async => AuthResult.fromJson(
    await _post('/auth/register', {
      'email': email,
      'password': password,
      'name': name,
    }),
  );

  Future<AuthResult> refresh(String token) async => AuthResult.fromJson(
    await _post('/auth/refresh', {'refreshToken': token}),
  );

  Future<void> logout(String token) async {
    await _post('/auth/logout', {'refreshToken': token});
  }

  Future<Map<String, dynamic>> sync({
    required String accessToken,
    required int cursor,
    required List<Map<String, dynamic>> mutations,
  }) => _post('/sync', {
    'cursor': cursor,
    'mutations': mutations,
  }, accessToken: accessToken);

  Future<http.Response> _attachmentRequest(
    String method,
    String path, {
    required String accessToken,
    Map<String, String>? query,
    Uint8List? bytes,
  }) async {
    final request = http.Request(
      method,
      Uri.parse('$baseUrl/api/v1$path').replace(queryParameters: query),
    )..headers['Authorization'] = 'Bearer $accessToken';
    if (bytes != null) {
      request.headers['Content-Type'] = 'application/octet-stream';
      request.bodyBytes = bytes;
    }
    http.Response response;
    try {
      response = await _client
          .send(request)
          .then(http.Response.fromStream)
          .timeout(const Duration(seconds: 90));
    } on TimeoutException {
      throw const ApiException(0, '附件传输超时，请重试。尚未将附件加入任务。');
    } on http.ClientException {
      throw const ApiException(0, '附件传输失败，请检查网络后重试。');
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      String message = '附件请求失败（${response.statusCode}），请重试。';
      try {
        final body = jsonDecode(utf8.decode(response.bodyBytes));
        if (body is Map && body['detail'] is String) {
          message = body['detail'] as String;
        }
      } on FormatException {
        // A proxy may return HTML; keep a bounded, useful error.
      }
      throw ApiException(response.statusCode, message);
    }
    return response;
  }

  Future<Map<String, dynamic>> attachmentLimits({
    required String accessToken,
  }) async {
    final response = await _attachmentRequest(
      'GET',
      '/attachments',
      accessToken: accessToken,
    );
    return Map<String, dynamic>.from(
      jsonDecode(utf8.decode(response.bodyBytes)) as Map,
    );
  }

  Future<AttachmentItem> uploadAttachment({
    required String accessToken,
    required String id,
    required String name,
    required Uint8List bytes,
  }) async {
    final response = await _attachmentRequest(
      'POST',
      '/attachments/${Uri.encodeComponent(id)}',
      accessToken: accessToken,
      query: {'name': name},
      bytes: bytes,
    );
    return AttachmentItem.fromJson(
      Map<String, dynamic>.from(
        jsonDecode(utf8.decode(response.bodyBytes)) as Map,
      ),
    );
  }

  Future<Uint8List> downloadAttachment({
    required String accessToken,
    required String id,
  }) async => (await _attachmentRequest(
    'GET',
    '/attachments/${Uri.encodeComponent(id)}',
    accessToken: accessToken,
  )).bodyBytes;

  void close() {
    if (_ownsClient) _client.close();
  }
}
