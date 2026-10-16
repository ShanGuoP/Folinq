part of 'online_ocr.dart';

extension _OfficialOcrJobs on OnlineOcrClient {
  Future<List<Map<String, Object>>> _recognizeJob(
    File pdf,
    int pageCount,
    bool includeImages,
    void Function(String)? onJobCreated,
    void Function(String)? onProgress,
  ) async {
    if (pageCount < 1 ||
        pageCount > 100 ||
        await pdf.length() > OnlineOcrClient.maxPdfBytes) {
      throw const FormatException('在线 OCR 每次最多 100 页、25 MB，请缩小范围。');
    }
    checkCancelled();
    if (jobId == null) {
      onProgress?.call('正在上传所选页面到官方 OCR 服务…');
      final boundary = 'folinq-${DateTime.now().microsecondsSinceEpoch}';
      final start = utf8.encode(
        '--$boundary\r\nContent-Disposition: form-data; name="model"\r\n\r\n${_config.model.trim()}\r\n'
        '--$boundary\r\nContent-Disposition: form-data; name="optionalPayload"\r\n\r\n{}\r\n'
        '--$boundary\r\nContent-Disposition: form-data; name="file"; filename="document.pdf"\r\nContent-Type: application/pdf\r\n\r\n',
      );
      final end = utf8.encode('\r\n--$boundary--\r\n');
      final request = await _http.postUrl(_apiUri);
      request.followRedirects = false;
      request.headers.set(
        HttpHeaders.authorizationHeader,
        'Bearer ${_config.token.trim()}',
      );
      request.headers.set('Client-Platform', 'folinq');
      request.headers.set(
        HttpHeaders.contentTypeHeader,
        'multipart/form-data; boundary=$boundary',
      );
      request.contentLength = start.length + await pdf.length() + end.length;
      request.add(start);
      await request.addStream(pdf.openRead());
      checkCancelled();
      request.add(end);
      final payload = await _jsonResponse(await request.close());
      final data = payload['data'];
      final id = data is Map ? data['jobId'] : null;
      if (id is! String || !_validJobId(id)) {
        throw const FormatException('官方 OCR 未返回有效任务编号。请在服务后台确认后再提交，避免重复计费。');
      }
      jobId = id;
      onJobCreated?.call(id);
    } else if (!_validJobId(jobId!)) {
      throw const FormatException('OCR 任务编号无效。');
    } else {
      onProgress?.call('继续查询已有 OCR 任务，未重复上传页面…');
    }
    while (true) {
      checkCancelled();
      final request = await _http.getUrl(
        _apiUri.replace(path: '${_apiUri.path}/$jobId'),
      );
      request.followRedirects = false;
      request.headers.set(
        HttpHeaders.authorizationHeader,
        'Bearer ${_config.token.trim()}',
      );
      final payload = await _jsonResponse(await request.close());
      final data = payload['data'];
      if (data is! Map || (data['jobId'] != null && data['jobId'] != jobId)) {
        throw const FormatException('OCR 返回的任务状态不匹配。');
      }
      switch (data['state']) {
        case 'done':
          final urls = data['resultUrl'];
          final url = urls is Map ? urls['jsonUrl'] : null;
          if (url is! String) {
            throw const FormatException('OCR 任务已完成，但未返回结果下载地址。');
          }
          onProgress?.call('识别完成，正在获取文字${includeImages ? '和配图' : ''}…');
          final bytes = await _download(url, 96 * 1024 * 1024);
          final results = <dynamic>[];
          for (final raw
              in utf8.decode(bytes).replaceFirst('\uFEFF', '').split('\n')) {
            checkCancelled();
            if (raw.trim().isEmpty) continue;
            final dynamic row;
            try {
              row = jsonDecode(raw);
            } on FormatException {
              throw const FormatException('OCR 返回了无效的逐页 JSONL 结果。');
            }
            final result = row is Map ? row['result'] : null;
            final pages = result is Map ? result['layoutParsingResults'] : null;
            if (pages is! List) {
              throw const FormatException(
                'OCR 结果没有文档解析内容，请选择 PaddleOCR-VL 或 PP-StructureV3。',
              );
            }
            results.addAll(pages);
            if (results.length > pageCount) {
              throw const FormatException('OCR 返回页数超出所选范围，未保存文件。');
            }
          }
          return _parsePages(results, pageCount, includeImages);
        case 'failed':
          terminalJobFailure = true;
          throw OnlineOcrFailure(
            '云端 OCR 任务处理失败，未导出文件。',
            detail: safeOcrDiagnostic(data['errorMsg'], _config.token),
            requestId: safeOcrDiagnostic(payload['traceId'], _config.token),
            jobId: jobId,
          );
        case 'pending':
          onProgress?.call('云端任务正在排队…\n任务编号：$jobId');
        case 'running':
          final progress = data['extractProgress'];
          final count = progress is Map
              ? int.tryParse('${progress['extractedPages']}')
              : null;
          onProgress?.call(
            '云端正在识别${count == null ? '' : ' $count / $pageCount 页'}…\n任务编号：$jobId',
          );
        default:
          throw OnlineOcrFailure('OCR 返回了未知任务状态，未自动重新提交。', jobId: jobId);
      }
      await Future.any([
        Future<void>.delayed(pollInterval),
        _cancelSignal.future,
      ]);
    }
  }

  bool _validJobId(String value) =>
      RegExp(r'^[A-Za-z0-9_-]{1,160}$').hasMatch(value);
}
