import 'dart:convert';
import 'dart:io';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_pdf_editor/core/rust/api.dart' as rust;
import 'package:local_pdf_editor/core/rust/frb_generated.dart';

void main() {
  test('real Dart to Rust edit, preview, save and reopen', () async {
    final root = Directory.current.parent.parent;
    await RustLib.init(
      externalLibrary: ExternalLibrary.open(
        Platform.environment['PDF_EDITOR_NATIVE_LIBRARY'] ??
            '${root.path}/rust/target/debug/app_api.dll',
      ),
    );
    final workspace = Directory.systemTemp.createTempSync('pdf-editor-bridge-');
    final source = '${root.path}/tests/pdf-fixtures/native-text.pdf';
    try {
      var info =
          jsonDecode(
                await rust.openDocument(
                  source: source,
                  workspace: workspace.path,
                ),
              )
              as Map;
      final id = info['id'] as String;
      final object = info['pages'][0]['text_objects'][0]['id'] as String;
      info =
          jsonDecode(
                await rust.documentCommand(
                  documentId: id,
                  expectedVersion: BigInt.zero,
                  command: 'replace_text',
                  objectId: object,
                  value: 'Hello PDF',
                ),
              )
              as Map;
      expect(info['version'], 1);
      expect(info['pages'][0]['text_objects'][0]['text'], 'Hello PDF');
      final preview = await rust.renderPreview(
        documentId: id,
        expectedVersion: BigInt.one,
        pageIndex: 0,
      );
      expect(File(preview).lengthSync(), greaterThan(1000));
      await expectLater(
        rust.documentCommand(
          documentId: id,
          expectedVersion: BigInt.zero,
          command: 'undo',
          objectId: '',
          value: '',
        ),
        throwsA(anything),
      );
      final destination = '${workspace.path}/export.pdf';
      info =
          jsonDecode(
                await rust.documentCommand(
                  documentId: id,
                  expectedVersion: BigInt.one,
                  command: 'save_as',
                  objectId: '',
                  value: destination,
                ),
              )
              as Map;
      expect(info['dirty'], false);
      await rust.closeDocument(documentId: id);
      final reopened =
          jsonDecode(
                await rust.openDocument(
                  source: destination,
                  workspace: workspace.path,
                ),
              )
              as Map;
      expect(reopened['pages'][0]['text_objects'][0]['text'], 'Hello PDF');
      await rust.closeDocument(documentId: reopened['id'] as String);
    } finally {
      workspace.deleteSync(recursive: true);
      RustLib.dispose();
    }
  });
}
