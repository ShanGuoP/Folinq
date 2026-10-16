import 'dart:convert';
import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'app_directories.dart';

final exportLocationsProvider = Provider((ref) => ExportLocations());

/// Shared by file exports and Save As; kept outside document/session data.
class ExportLocations {
  ExportLocations({Future<Directory> Function()? supportDirectory})
    : _supportDirectory = supportDirectory ?? applicationSupportDirectory;

  final Future<Directory> Function() _supportDirectory;
  String? _lastDirectory;

  Future<String?> initialDirectory(String source) async {
    try {
      final settings = File(
        '${(await _supportDirectory()).path}/export-location.json',
      );
      if (_lastDirectory == null && settings.existsSync()) {
        final data = jsonDecode(settings.readAsStringSync());
        if (data is Map && data['directory'] is String) {
          _lastDirectory = data['directory'] as String;
        }
      }
    } catch (_) {
      // A missing or damaged preference must not prevent exporting.
    }
    if (_lastDirectory case final String directory) {
      if (Directory(directory).existsSync()) return directory;
    }
    final parent = File(pickerPath(source)).parent;
    return parent.existsSync() ? parent.path : null;
  }

  /// Remember a confirmed picker selection, including when conversion later fails.
  Future<bool> remember(String directory) async {
    _lastDirectory = directory;
    File? temporary;
    try {
      final root = await _supportDirectory();
      root.createSync(recursive: true);
      temporary = File(
        '${root.path}/export-location-$pid-${DateTime.now().microsecondsSinceEpoch}.tmp',
      );
      temporary.writeAsStringSync(
        jsonEncode({'directory': directory}),
        flush: true,
      );
      temporary.renameSync('${root.path}/export-location.json');
      return true;
    } catch (_) {
      return false;
    } finally {
      try {
        if (temporary != null && temporary.existsSync()) temporary.deleteSync();
      } on FileSystemException {
        // Preference cleanup must not turn a completed export into a failure.
      }
    }
  }
}

/// Windows shell dialogs do not consistently accept extended-length prefixes.
String pickerPath(String path) {
  if (path.startsWith(r'\\?\UNC\')) return r'\\' + path.substring(8);
  if (path.startsWith(r'\\?\')) return path.substring(4);
  return path;
}

String withExportExtension(String path, String extension) =>
    path.toLowerCase().endsWith('.${extension.toLowerCase()}')
    ? path
    : '$path.$extension';

/// Never replace an existing file, directory or link. Native publishing also
/// refuses replacement if another process creates this name after selection.
String availableExportPath(String path) {
  bool occupied(String value) =>
      FileSystemEntity.typeSync(value, followLinks: false) !=
      FileSystemEntityType.notFound;
  if (!occupied(path)) return path;
  final separator = path.lastIndexOf(RegExp(r'[/\\]'));
  final dot = path.lastIndexOf('.');
  final hasExtension = dot > separator + 1;
  final stem = hasExtension ? path.substring(0, dot) : path;
  final extension = hasExtension ? path.substring(dot) : '';
  for (var index = 1; index <= 10000; index++) {
    final candidate = '$stem ($index)$extension';
    if (!occupied(candidate)) return candidate;
  }
  throw const FormatException('同名文件过多，请选择其他文件名或文件夹。');
}
