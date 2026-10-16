import 'dart:convert';

class OnlineOcrFailure implements Exception {
  const OnlineOcrFailure(
    this.message, {
    this.status,
    this.code,
    this.detail,
    this.requestId,
    this.jobId,
  });
  final String message;
  final int? status;
  final String? code, detail, requestId, jobId;
  @override
  String toString() => [
    '$message${status == null ? '' : '（HTTP $status）'}',
    if (detail != null && detail!.isNotEmpty) '服务信息：$detail',
    if (code != null) '服务错误码：$code',
    if (requestId != null) '请求编号：$requestId',
    if (jobId != null) '任务编号：$jobId',
  ].join('\n');
}

String? safeOcrDiagnostic(Object? value, String token, {int maxLength = 400}) {
  if (value is! String && value is! num) return null;
  var text = '$value';
  if (token.trim().isNotEmpty) text = text.replaceAll(token.trim(), '[已隐藏]');
  text = text
      .replaceAll(
        RegExp(r'(?:Bearer|token)\s+[^\s,;"<>]+', caseSensitive: false),
        '[令牌已隐藏]',
      )
      .replaceAll(
        RegExp(r'https?://[^\s"<>]+', caseSensitive: false),
        '[地址已隐藏]',
      )
      .replaceAll(RegExp(r'[A-Za-z0-9+/=_-]{64,}'), '[长数据已隐藏]')
      .replaceAll(RegExp(r'[\x00-\x1f\x7f]'), ' ')
      .trim();
  if (text.isEmpty) return null;
  return text.length > maxLength ? '${text.substring(0, maxLength)}…' : text;
}

OnlineOcrFailure ocrServiceFailure(
  int status,
  Object? payload,
  String token, {
  String? headerRequestId,
  String? jobId,
}) {
  final body = payload is Map ? payload : const {};
  final data = body['data'] is Map ? body['data'] as Map : const {};
  final code = safeOcrDiagnostic(
    body['code'] ?? body['errorCode'],
    token,
    maxLength: 32,
  );
  final detail = safeOcrDiagnostic(
    data['errorMsg'] ??
        body['errorMsg'] ??
        body['msg'] ??
        body['message'] ??
        body['detail'],
    token,
  );
  final requestId = safeOcrDiagnostic(
    body['traceId'] ?? body['logId'] ?? body['requestId'] ?? headerRequestId,
    token,
    maxLength: 128,
  );
  final reason = switch (code) {
    '12001' => '今日 OCR 解析页数已达上限，请等待额度恢复或调整服务配额。',
    '12002' || '10010' => 'OCR 服务繁忙或请求过于频繁，请稍后再试。未自动重复提交。',
    '10007' => 'OCR 模型名称不受服务支持，请切换文档解析模型。',
    '10003' || '10006' => '文件大小或页数超出服务限制，请缩小导出范围。',
    '11001' || '11002' => '原 OCR 任务不存在或已过期，再次导出将创建新任务。',
    _ => switch (status) {
      401 || 403 => 'OCR 服务拒绝访问，请检查访问令牌、权限或服务配额。',
      404 => '找不到 OCR 接口，请检查完整地址和服务类型。',
      413 => '上传文件超出服务限制，请缩小页面范围。',
      429 => 'OCR 请求过于频繁或配额受限，请稍后再试。',
      >= 500 => 'OCR 服务端处理失败。请先尝试少量页面，或凭请求编号联系服务方。未自动重复提交。',
      >= 300 && < 400 => 'OCR 接口返回了重定向，已停止发送；请填写最终接口地址。',
      _ => 'OCR 请求未完成，请根据服务信息检查文件或参数。',
    },
  };
  return OnlineOcrFailure(
    reason,
    status: status,
    code: code,
    detail: detail,
    requestId: requestId,
    jobId: jobId,
  );
}

Object? tryOcrJson(List<int> bytes) {
  try {
    return jsonDecode(utf8.decode(bytes));
  } on FormatException {
    return null;
  }
}
