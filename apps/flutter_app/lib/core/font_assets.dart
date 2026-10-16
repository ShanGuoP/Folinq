import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'app_directories.dart';

abstract final class FontAssets {
  static const hash =
      '9cec903964d0ea39a8e79eea35e731b9959138f91126d9ea5a162eae0ee90742';
  static Future<String>? _pending;
  static Future<String> chineseFont() =>
      _pending ??= _materialize().catchError((Object error) {
        _pending = null;
        throw error;
      });
  static Future<String> _materialize() async {
    final support = await applicationSupportDirectory();
    final directory = Directory('${support.path}/fonts');
    await directory.create(recursive: true);
    final target = File('${directory.path}/NotoSansSC-9cec9039.ttf');
    if (await target.exists() &&
        sha256.convert(await target.readAsBytes()).toString() == hash) {
      return target.path;
    }
    final data = await rootBundle.load('assets/fonts/NotoSansSC.ttf');
    final bytes = data.buffer.asUint8List(
      data.offsetInBytes,
      data.lengthInBytes,
    );
    if (sha256.convert(bytes).toString() != hash) throw StateError('内置字体校验失败');
    await target.writeAsBytes(bytes, flush: true);
    return target.path;
  }
}
