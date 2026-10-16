import 'dart:io';
import 'features/viewer/workbench.dart';
export 'features/viewer/workbench.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'core/rust/frb_generated.dart';
import 'shared/editor_theme.dart';
import 'shared/app_brand.dart';
import 'features/mobile/mobile_workbench.dart';

Future<void> main(List<String> arguments) async {
  WidgetsFlutterBinding.ensureInitialized();
  String? startupError;
  try {
    final name = Platform.isWindows ? 'app_api.dll' : 'libapp_api.so';
    final path =
        Platform.environment['PDF_EDITOR_LIBRARY'] ??
        (Platform.isWindows
            ? '${File(Platform.resolvedExecutable).parent.path}/$name'
            : name);
    await RustLib.init(externalLibrary: ExternalLibrary.open(path));
  } catch (error) {
    startupError = '$error';
  }
  runApp(
    ProviderScope(
      child: PdfEditorApp(startupError: startupError, startupPaths: arguments),
    ),
  );
}

class PdfEditorApp extends StatelessWidget {
  const PdfEditorApp({
    super.key,
    this.startupError,
    this.startupPaths = const [],
  });
  final String? startupError;
  final List<String> startupPaths;
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: AppBrand.name,
    debugShowCheckedModeBanner: false,
    theme: editorTheme(),
    home: startupError == null
        ? Platform.isAndroid
              ? const MobileWorkbench()
              : Workbench(startupPaths: startupPaths)
        : Scaffold(
            body: Center(
              child: SizedBox(
                width: 560,
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('文档引擎未能启动', style: TextStyle(fontSize: 24)),
                      const SizedBox(height: 16),
                      Text(
                        Platform.isAndroid
                            ? '文档引擎加载失败。请安装包含 ARM64 本地引擎的完整 APK。'
                            : '请使用项目的 Windows 启动脚本构建应用，确保本地引擎已部署。',
                      ),
                      const SizedBox(height: 16),
                      SelectableText(startupError!),
                    ],
                  ),
                ),
              ),
            ),
          ),
  );
}
