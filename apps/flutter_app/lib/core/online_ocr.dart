import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'online_ocr_errors.dart';
export 'online_ocr_errors.dart' show OnlineOcrFailure;
part 'online_ocr_jobs.dart';

enum OnlineOcrProtocol { auto, jobs, layout }

class OnlineOcrConfig {
  const OnlineOcrConfig({
    this.endpoint = '',
    this.token = '',
    this.scheme = 'token',
    this.allowHttp = false,
    this.protocol = OnlineOcrProtocol.auto,
    this.model = 'PaddleOCR-VL-1.6',
  });
  static const officialEndpoint =
      'https://paddleocr.aistudio-app.com/api/v2/ocr/jobs';
  final String endpoint, token, scheme;
  final String model;
  final OnlineOcrProtocol protocol;
  final bool allowHttp;
  bool get usesJobs {
    if (protocol != OnlineOcrProtocol.auto) {
      return protocol == OnlineOcrProtocol.jobs;
    }
    final uri = Uri.tryParse(endpoint.trim());
    return uri != null &&
        (uri.host == 'paddleocr.aistudio-app.com' ||
            uri.path
                .replaceFirst(RegExp(r'/+$'), '')
                .endsWith('/api/v2/ocr/jobs'));
  }

  OnlineOcrConfig copyWith({
    String? endpoint,
    String? token,
    String? scheme,
    bool? allowHttp,
    OnlineOcrProtocol? protocol,
    String? model,
  }) => OnlineOcrConfig(
    endpoint: endpoint ?? this.endpoint,
    token: token ?? this.token,
    scheme: scheme ?? this.scheme,
    allowHttp: allowHttp ?? this.allowHttp,
    protocol: protocol ?? this.protocol,
    model: model ?? this.model,
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
    if (uri.host == 'paddleocr.aistudio-app.com' && uri.scheme != 'https') {
      throw const FormatException('官方云端服务必须使用 HTTPS。');
    }
    if (usesJobs) {
      if (token.trim().isEmpty) {
        throw const FormatException('官方任务接口需要填写 AI Studio 访问令牌。');
      }
      if (model.trim().isEmpty || model.contains(RegExp(r'[\r\n\x00]'))) {
        throw const FormatException('请填写有效的文档解析模型名称。');
      }
      final path = uri.path.replaceFirst(RegExp(r'/+$'), '');
      return uri.replace(
        path: path.isEmpty || path == '/api' ? '/api/v2/ocr/jobs' : path,
      );
    }
    if (uri.path.contains('/api/v2/ocr/jobs')) {
      throw const FormatException('此地址是异步任务接口，请将服务类型改为“按地址自动判断”或“官方云端任务”。');
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
  const OnlineOcrCancelled({this.jobId});
  final String? jobId;
  @override
  String toString() => jobId == null
      ? '已取消在线识别，未发布导出文件。'
      : '已停止等待，云端任务可能继续处理。同一文档和页面再次导出时会继续查询原任务。\n任务编号：$jobId';
}

/// PaddleOCR jobs and synchronous layout-parsing. No submission retries and no
/// redirect forwarding of credentials. The client lives for one export only.
class OnlineOcrClient {
  OnlineOcrClient({
    this.pollInterval = const Duration(seconds: 3),
    this.timeout,
  });
  final Duration pollInterval;
  final Duration? timeout;
  final HttpClient _http = HttpClient()
    ..connectionTimeout = const Duration(seconds: 20);
  bool _cancelled = false;
  int _resourceBytes = 0;
  final _cancelSignal = Completer<void>();
  String? jobId;
  bool terminalJobFailure = false;
  late OnlineOcrConfig _config;
  late Uri _apiUri;
  static const maxPdfBytes = 25 * 1024 * 1024;
  void cancel() {
    _cancelled = true;
    _http.close(force: true);
    if (!_cancelSignal.isCompleted) _cancelSignal.complete();
  }

  void checkCancelled() {
    if (_cancelled) throw OnlineOcrCancelled(jobId: jobId);
  }

  Future<Map> _jsonResponse(HttpClientResponse response) async {
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in response) {
        checkCancelled();
        bytes.add(chunk.take(16384 - bytes.length).toList());
        if (bytes.length >= 16384) break;
      }
      final payload = tryOcrJson(bytes.takeBytes());
      if (payload is Map &&
          ['11001', '11002', '11003'].contains('${payload['code']}')) {
        terminalJobFailure = true;
      }
      throw ocrServiceFailure(
        response.statusCode,
        payload,
        _config.token,
        headerRequestId: response.headers.value('x-request-id'),
        jobId: jobId,
      );
    }
    final decoded = tryOcrJson(await _read(response, 96 * 1024 * 1024));
    if (decoded is! Map) throw const FormatException('OCR 服务返回了无效的 JSON 结果。');
    final code = decoded['code'] ?? decoded['errorCode'];
    if (code != null && '$code' != '0') {
      if (['11001', '11002', '11003'].contains('$code')) {
        terminalJobFailure = true;
      }
      throw ocrServiceFailure(
        response.statusCode,
        decoded,
        _config.token,
        jobId: jobId,
      );
    }
    return decoded;
  }

  Uri _resourceUri(String value) {
    final uri = Uri.tryParse(value);
    if (uri == null ||
        !uri.hasAuthority ||
        uri.userInfo.isNotEmpty ||
        uri.hasFragment ||
        (uri.scheme != 'https' &&
            !(uri.scheme == 'http' &&
                _config.allowHttp &&
                _apiUri.scheme == 'http' &&
                uri.origin == _apiUri.origin))) {
      throw const FormatException('OCR 资源地址必须使用 HTTPS；可信 HTTP 服务仅允许同站资源。');
    }
    return uri;
  }

  Future<Uint8List> _download(String value, int limit) async {
    var uri = _resourceUri(value);
    for (var hop = 0; hop <= 3; hop++) {
      checkCancelled();
      final request = await _http.getUrl(uri);
      request.followRedirects = false;
      final response = await request.close();
      // Result links may be BOS short links. Follow only validated resource
      // redirects; these requests never carry the API Authorization header.
      if ([301, 302, 303, 307, 308].contains(response.statusCode) && hop < 3) {
        final location = response.headers.value(HttpHeaders.locationHeader);
        if (location == null) throw const FormatException('OCR 资源重定向缺少目标地址。');
        uri = _resourceUri(uri.resolve(location).toString());
        await response.listen(null).cancel();
        continue;
      }
      if (response.statusCode != 200) {
        throw OnlineOcrFailure(
          'OCR 结果或配图下载失败，未发布文件。',
          status: response.statusCode,
          jobId: jobId,
        );
      }
      return _read(response, limit);
    }
    throw const FormatException('OCR 资源重定向次数过多。');
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
      bytes = await _download(value, 16 * 1024 * 1024);
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
    String? resumeJobId,
    void Function(String)? onJobCreated,
    void Function(String)? onProgress,
  }) async {
    final uri = config.validate();
    _config = config;
    _apiUri = uri;
    jobId = resumeJobId;
    try {
      final operation = config.usesJobs
          ? _recognizeJob(
              pdf,
              pageCount,
              includeImages,
              onJobCreated,
              onProgress,
            )
          : _recognize(pdf, pageCount, config, uri, includeImages);
      return await operation.timeout(
        timeout ?? Duration(minutes: config.usesJobs ? 10 : 5),
      );
    } on TimeoutException {
      throw OnlineOcrFailure(
        jobId == null
            ? '在线 OCR 超时，未自动重试。请求可能已提交，请先在服务后台确认。'
            : '等待在线 OCR 超时，再次导出相同页面会继续查询原任务。',
        jobId: jobId,
      );
    } on SocketException {
      checkCancelled();
      throw const FormatException('无法连接 OCR 服务，请检查地址和网络。');
    } on HttpException {
      checkCancelled();
      throw const FormatException('OCR 连接中断，未自动重试。');
    } on HandshakeException {
      throw const FormatException('OCR 服务的 HTTPS 证书验证失败。');
    } finally {
      cancel();
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
    final decoded = await _jsonResponse(response);
    final result = decoded['result'];
    final results = result is Map ? result['layoutParsingResults'] : null;
    return _parsePages(results, pageCount, includeImages);
  }

  Future<List<Map<String, Object>>> _parsePages(
    Object? results,
    int pageCount,
    bool includeImages,
  ) async {
    if (results is! List || results.length != pageCount) {
      throw const FormatException('OCR 返回页数与所选范围不一致。请检查服务的页数限制，避免导出缺页。');
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
