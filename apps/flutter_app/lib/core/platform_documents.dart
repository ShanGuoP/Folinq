import 'package:flutter/services.dart';

abstract final class PlatformDocuments {
  static const channel = MethodChannel('dev.localpdf/documents');
  static Future<String?> save(String source, String filename, String mime) =>
      channel.invokeMethod<String>('saveDocument', {
        'source': source,
        'filename': filename,
        'mime': mime,
      });
}
