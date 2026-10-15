import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_pdf_editor/core/document.dart';
import 'package:local_pdf_editor/features/documents/document_controller.dart';
import 'package:local_pdf_editor/features/viewer/export_dialog.dart';

class ExportPicker extends FilePicker {
  ExportPicker(this.path);
  final String? path;
  @override
  Future<String?> saveFile({
    String? dialogTitle,
    String? fileName,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Uint8List? bytes,
    bool lockParentWindow = false,
  }) async => path;
}

class ExportController extends DocumentController {
  final completion = Completer<void>();
  bool fail = false;
  int calls = 0;
  @override
  DocumentState build() => DocumentState(
    document: DocumentInfo({
      'id': 'test',
      'source_path': 'C:/sample.pdf',
      'version': 0,
      'dirty': false,
      'can_undo': false,
      'can_redo': false,
      'pages': [
        {'id': 'page', 'width': 595, 'height': 842, 'text_objects': []},
      ],
    }),
  );
  @override
  Future<bool> applyPendingDrafts() async => true;
  @override
  Future<void> command(String command, {String value = ''}) async {
    calls++;
    await completion.future;
    if (fail) {
      state = DocumentState(document: state.document, error: '磁盘写入失败');
      return;
    }
    File(
      (jsonDecode(value) as Map)['destination'] as String,
    ).writeAsStringSync('exported');
  }
}

void main() {
  for (final outcome in ['success', 'failure', 'cancel']) {
    testWidgets('export $outcome reports success only after writing finishes', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1;
      final directory = Directory.systemTemp.createTempSync(
        'folinq-export-feedback-',
      );
      final output = File('${directory.path}/export.md');
      FilePicker.platform = ExportPicker(
        outcome == 'cancel' ? null : output.path,
      );
      final controller = ExportController()..fail = outcome == 'failure';
      final container = ProviderContainer(
        overrides: [documentProvider.overrideWith(() => controller)],
      );
      try {
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: const MaterialApp(
              home: Scaffold(body: ExportDialog(format: 'md')),
            ),
          ),
        );
        await tester.tap(find.text('选择位置并导出'));
        await tester.pump();
        expect(find.text('导出成功'), findsNothing);
        expect(output.existsSync(), isFalse);
        if (outcome == 'cancel') {
          expect(controller.calls, 0);
        } else {
          expect(controller.calls, 1);
          controller.completion.complete();
          await tester.pumpAndSettle();
          if (outcome == 'success') {
            expect(find.text('导出成功'), findsOneWidget);
            expect(find.textContaining('保存位置：${output.path}'), findsOneWidget);
            expect(output.existsSync(), isTrue);
            expect(find.text('完成'), findsOneWidget);
          } else {
            expect(find.text('导出成功'), findsNothing);
            expect(find.textContaining('磁盘写入失败'), findsOneWidget);
            expect(output.existsSync(), isFalse);
          }
        }
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        container.dispose();
        FilePicker.platform = ExportPicker(null);
        directory.deleteSync(recursive: true);
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      }
    });
  }
}
