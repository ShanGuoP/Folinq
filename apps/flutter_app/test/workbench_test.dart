import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_pdf_editor/main.dart';

void main() {
  testWidgets('empty workbench explains local opening', (tester) async {
    await tester.pumpWidget(const ProviderScope(child: PdfEditorApp()));
    expect(find.text('项目与 PDF'), findsOneWidget);
    final save = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, '另存为'),
    );
    expect(save.onPressed, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('startup failure remains visible', (tester) async {
    await tester.pumpWidget(
      const PdfEditorApp(startupError: 'PDFIUM_UNAVAILABLE'),
    );
    expect(find.text('文档引擎未能启动'), findsOneWidget);
    expect(find.text('PDFIUM_UNAVAILABLE'), findsOneWidget);
  });
}
