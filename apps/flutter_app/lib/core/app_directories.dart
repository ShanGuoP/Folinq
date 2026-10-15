import 'dart:io';
import 'package:path_provider/path_provider.dart' as platform;

/// Keep the existing Windows profile stable across display-name changes.
Directory windowsSupportDirectory(String roamingRoot) =>
    Directory('$roamingRoot/dev.localpdf/Local PDF Editor');

Future<Directory> applicationSupportDirectory() async {
  if (Platform.isWindows) {
    final roaming = Platform.environment['APPDATA'];
    if (roaming != null && roaming.isNotEmpty) {
      return windowsSupportDirectory(roaming);
    }
    final current = await platform.getApplicationSupportDirectory();
    return Directory('${current.parent.path}/Local PDF Editor');
  }
  return platform.getApplicationSupportDirectory();
}
