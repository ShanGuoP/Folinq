import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class OnlineOcrConfig {
  const OnlineOcrConfig({
    this.endpoint = '',
    this.token = '',
    this.scheme = 'token',
    this.allowHttp = false,
  });
  final String endpoint, token, scheme;
  final bool allowHttp;
  OnlineOcrConfig copyWith({
    String? endpoint,
    String? token,
    String? scheme,
    bool? allowHttp,
  }) => OnlineOcrConfig(
    endpoint: endpoint ?? this.endpoint,
    token: token ?? this.token,
    scheme: scheme ?? this.scheme,
    allowHttp: allowHttp ?? this.allowHttp,
  );
  Uri validate() {
    final uri = Uri.tryParse(endpoint.trim());
    if (uri == null ||
        !uri.hasAuthority ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasFragment ||
        !['https', 'http'].contains(uri.scheme)) {
      throw const FormatException(
        '请填写完整的 PaddleOCR 文档解析接口地址，例如 https://服务地址/layout-parsing',
      );
    }
    if (uri.scheme == 'http' && !allowHttp) {
      throw const FormatException('请使用 HTTPS，或明确允许可信内网的 HTTP 连接。');
    }
    if (!['token', 'Bearer'].contains(scheme) ||
        token.codeUnits.any((c) => c < 32 || c > 126)) {
      throw const FormatException('Token 或鉴权方式无效。');
    }
    return uri;
  }
}

final onlineOcrConfigProvider =
    NotifierProvider<OnlineOcrSettings, OnlineOcrConfig>(OnlineOcrSettings.new);

class OnlineOcrSettings extends Notifier<OnlineOcrConfig> {
  @override
  OnlineOcrConfig build() => const OnlineOcrConfig();
  void update(OnlineOcrConfig value) => state = value;
}

class OnlineOcrCancelled implements Exception {
  @override
  String toString() => '已取消在线识别，未发布导出文件。';
}

/// PaddleOCR synchronous layout-parsing protocol. No submission retries and no
/// redirect forwarding of credentials. The client lives for one export only.
class OnlineOcrClient {
  final HttpClient _http = HttpClient()
    ..connectionTimeout = const Duration(seconds: 20);
  bool _cancelled = false;
  int _resourceBytes = 0;
  static const maxPdfBytes = 25 * 1024 * 1024;
  void cancel() {
    _cancelled = true;
    _http.close(force: true);
  }

  void checkCancelled() {
    if (_cancelled) throw OnlineOcrCancelled();
  }

  Future<Uint8List> _read(HttpClientResponse response, int limit) async {
    if (response.contentLength > limit) {
      throw const FormatException('OCR 返回内容过大，请缩小页面范围。');
    }
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in response) {
      checkCancelled();
      if (bytes.length + chunk.length > limit) {
        throw const FormatException('OCR 返回内容过大，请缩小页面范围。');
      }
      bytes.add(chunk);
    }
    return bytes.takeBytes();
  }

  Future<String> _image(String value) async {
    Uint8List bytes;
    final uri = Uri.tryParse(value);
    if (uri != null && ['https', 'http'].contains(uri.scheme)) {
      // Resources carry no Authorization header, including same-host downloads.
      if (uri.scheme != 'https' ||
          uri.userInfo.isNotEmpty ||
          !uri.hasAuthority) {
        throw const FormatException('OCR 配图下载地址必须使用 HTTPS。');
      }
      final request = await _http.getUrl(uri);
      request.followRedirects = false;
      final response = await request.close();
      if (response.statusCode != 200) {
        throw FormatException('OCR 配图下载失败（HTTP ${response.statusCode}）。');
      }
      bytes = await _read(response, 16 * 1024 * 1024);
    } else {
      final raw = value.startsWith('data:')
          ? value.substring(value.indexOf(',') + 1)
          : value;
      try {
        bytes = base64Decode(raw);
      } catch (_) {
        throw const FormatException('OCR 配图编码无效。');
      }
    }
    _resourceBytes += bytes.length;
    if (bytes.length > 16 * 1024 * 1024 || _resourceBytes > 64 * 1024 * 1024) {
      throw const FormatException('OCR 配图过大，请缩小页面范围。');
    }
    return base64Encode(bytes);
  }

  Future<List<Map<String, Object>>> recognize(
    File pdf,
    int pageCount,
    OnlineOcrConfig config, {
    bool includeImages = true,
  }) async {
    final uri = config.validate();
    try {
      return await _recognize(
        pdf,
        pageCount,
        config,
        uri,
        includeImages,
      ).timeout(const Duration(minutes: 5));
    } on TimeoutException {
      throw const FormatException('在线 OCR 超时，未自动重试；可在服务后台确认请求状态后重试。');
    } on SocketException {
      checkCancelled();
      throw const FormatException('无法连接 OCR 服务，请检查地址和网络。');
    } on HttpException {
      checkCancelled();
      throw const FormatException('OCR 连接中断，未自动重试。');
    } on HandshakeException {
      throw const FormatException('OCR 服务的 HTTPS 证书验证失败。');
    } finally {
      _http.close(force: true);
    }
  }

  Future<List<Map<String, Object>>> _recognize(
    File pdf,
    int pageCount,
    OnlineOcrConfig config,
    Uri uri,
    bool includeImages,
  ) async {
    if (pageCount < 1 || pageCount > 100 || await pdf.length() > maxPdfBytes) {
      throw const FormatException('在线 OCR 每次最多 100 页、25 MB，请缩小范围。');
    }
    final bytes = await pdf.readAsBytes();
    checkCancelled();
    final request = await _http.postUrl(uri);
    request.followRedirects = false;
    request.headers.contentType = ContentType.json;
    if (config.token.trim().isNotEmpty) {
      request.headers.set(
        HttpHeaders.authorizationHeader,
        '${config.scheme} ${config.token.trim()}',
      );
    }
    request.add(
      utf8.encode(jsonEncode({'file': base64Encode(bytes), 'fileType': 0})),
    );
    final response = await request.close();
    if (response.statusCode != 200) {
      throw FormatException(
        'OCR 请求失败（HTTP ${response.statusCode}），请检查地址、Token 和额度。',
      );
    }
    final dynamic decoded;
    try {
      decoded = jsonDecode(
        utf8.decode(await _read(response, 96 * 1024 * 1024)),
      );
    } on FormatException {
      throw const FormatException('OCR 服务返回了无效 JSON 或超出限制的结果。');
    }
    if (decoded is! Map ||
        (decoded['errorCode'] != null && decoded['errorCode'] != 0)) {
      throw const FormatException('OCR 服务识别失败，请在服务后台查看原因。');
    }
    final result = decoded['result'];
    final results = result is Map ? result['layoutParsingResults'] : null;
    if (results is! List || results.length != pageCount) {
      throw const FormatException(
        'OCR 返回页数与所选范围不一致。请使用同步 layout-parsing 接口，避免导出缺页。',
      );
    }
    final pages = <Map<String, Object>>[];
    for (final item in results) {
      checkCancelled();
      final markdown = item is Map ? item['markdown'] : null;
      if (markdown is! Map || markdown['text'] is! String) {
        throw const FormatException('OCR 服务未返回 Markdown，请启用文档解析而非仅文字检测。');
      }
      final images = <String, String>{};
      final source = markdown['images'];
      if (source != null && source is! Map) {
        throw const FormatException('OCR 配图格式无效。');
      }
      if (includeImages && source is Map) {
        if (source.length > 500) throw const FormatException('OCR 配图数量超出限制。');
        for (final entry in source.entries) {
          final name = '${entry.key}';
          if (name.length > 240 ||
              !name
                  .split('/')
                  .every(
                    (p) =>
                        p.isNotEmpty &&
                        p != '.' &&
                        p != '..' &&
                        RegExp(r'^[a-zA-Z0-9_.-]+$').hasMatch(p),
                  ) ||
              entry.value is! String) {
            throw const FormatException('OCR 返回了无效的配图路径。');
          }
          images[name] = await _image(entry.value as String);
        }
      }
      pages.add({'markdown': markdown['text'] as String, 'images': images});
    }
    if (pages.every((p) => (p['markdown'] as String).trim().isEmpty)) {
      throw const FormatException('OCR 未识别出内容，未导出文件。');
    }
    return pages;
  }
}
