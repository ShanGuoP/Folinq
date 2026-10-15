import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_pdf_editor/core/document.dart';
import 'package:local_pdf_editor/core/rust/api.dart' as rust;
import 'package:local_pdf_editor/core/rust/frb_generated.dart';
import 'package:local_pdf_editor/features/documents/document_controller.dart';
import 'package:local_pdf_editor/main.dart';
import 'package:local_pdf_editor/features/viewer/redaction_dialog.dart';
import 'package:local_pdf_editor/features/viewer/continuous_canvas.dart';
import 'package:local_pdf_editor/features/viewer/project_home.dart';

class OpenedController extends DocumentController {
  OpenedController(this.initial, this.workspace);
  final DocumentState initial;
  final String workspace;
  @override
  DocumentState build() => initial;
  @override
  Future<List<DocumentInfo>> recoverable() async =>
      (jsonDecode(await rust.recoverableDocuments(workspace: workspace))
              as List)
          .map((item) => DocumentInfo(item as Map<String, dynamic>))
          .toList()
        ..sort((a, b) => a.name.compareTo(b.name));
  @override
  Future<Map<String, dynamic>> projects({
    String command = 'list',
    Map<String, dynamic> value = const {},
  }) async =>
      jsonDecode(
            await rust.projectCatalog(
              workspace: workspace,
              command: command,
              value: jsonEncode(value),
            ),
          )
          as Map<String, dynamic>;
}

class SavePicker extends FilePicker {
  SavePicker(this.path);
  final String path;
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

Future<void> seedPreview(String path) async {
  final codec = await ui.instantiateImageCodec(File(path).readAsBytesSync());
  final frame = await codec.getNextFrame();
  PaintingBinding.instance.imageCache.putIfAbsent(
    FileImage(File(path)),
    () => OneFrameImageStreamCompleter(
      Future.value(ImageInfo(image: frame.image)),
    ),
  );
  codec.dispose();
}

void main() {
  testWidgets('select original text and apply through native engine', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    final root = Directory.current.parent.parent;
    final flutterRoot =
        Platform.environment['FLUTTER_ROOT'] ?? '${root.path}/.tools/flutter';
    await tester.runAsync(() async {
      final font = FontLoader('Microsoft YaHei')
        ..addFont(
          File(
            'C:/Windows/Fonts/msyh.ttc',
          ).readAsBytes().then((bytes) => ByteData.sublistView(bytes)),
        );
      final icons = FontLoader('MaterialIcons')
        ..addFont(
          File(
            '$flutterRoot/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
          ).readAsBytes().then((bytes) => ByteData.sublistView(bytes)),
        );
      await Future.wait([font.load(), icons.load()]);
    });
    await tester.runAsync(
      () => RustLib.init(
        externalLibrary: ExternalLibrary.open(
          Platform.environment['PDF_EDITOR_NATIVE_LIBRARY'] ??
              '${root.path}/rust/target/debug/app_api.dll',
        ),
      ),
    );
    final workspace = Directory(
      '${root.path}/.work/widget-tests/${DateTime.now().microsecondsSinceEpoch}',
    )..createSync(recursive: true);
    final sourceFile = File('${workspace.path}/input.pdf');
    File(
      '${root.path}/tests/pdf-fixtures/native-text.pdf',
    ).copySync(sourceFile.path);
    final document = DocumentInfo(
      jsonDecode(
            (await tester.runAsync(
              () => rust.openDocument(
                source: sourceFile.path,
                workspace: workspace.path,
              ),
            ))!,
          )
          as Map<String, dynamic>,
    );
    final preview = await tester.runAsync(
      () => rust.renderPreview(
        documentId: document.id,
        expectedVersion: BigInt.zero,
        pageIndex: 0,
      ),
    );
    final container = ProviderContainer(
      overrides: [
        documentProvider.overrideWith(
          () => OpenedController(
            DocumentState(document: document, preview: preview),
            workspace.path,
          ),
        ),
      ],
    );
    await tester.runAsync(() => seedPreview(preview!));
    try {
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const PdfEditorApp(),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey(document.pages[0].objects[0].id)));
      await tester.pumpAndSettle();
      expect(
        find.widgetWithText(TextField, 'Hello PDF Editor'),
        findsOneWidget,
      );
      await tester.enterText(find.byType(TextField), 'New text 123');
      // Native FFI runs outside the fake test clock.
      await tester.runAsync(() async {
        await tester.tap(find.text('应用修改'));
        for (
          var attempt = 0;
          attempt < 100 && container.read(documentProvider).busy;
          attempt++
        ) {
          await Future<void>.delayed(const Duration(milliseconds: 25));
        }
      });
      await tester.runAsync(
        () => seedPreview(container.read(documentProvider).preview!),
      );
      await tester.pumpAndSettle();
      final state = container.read(documentProvider);
      expect(state.error, isNull);
      expect(state.document!.version, 1);
      expect(state.document!.pages[0].objects[0].text, 'New text 123');
      expect(state.selected?.text, 'New text 123');
      const overflow = 'Hello PDF Hello PDF Hello PDF';
      await tester.enterText(find.byType(TextField), overflow);
      await tester.runAsync(() async {
        await tester.tap(find.text('应用修改'));
        for (
          var attempt = 0;
          attempt < 100 && container.read(documentProvider).busy;
          attempt++
        ) {
          await Future<void>.delayed(const Duration(milliseconds: 25));
        }
      });
      await tester.pumpAndSettle();
      expect(container.read(documentProvider).document!.version, 1);
      expect(
        container.read(documentProvider).error,
        contains('LAYOUT_OVERFLOW'),
      );
      expect(find.widgetWithText(TextField, overflow), findsOneWidget);
      container.read(documentProvider.notifier).select(state.selected!);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'New text 123');
      expect(find.text('版本 1'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 250));
      });
      await tester.pumpAndSettle();
      final mouse = await tester.createGesture(
        kind: ui.PointerDeviceKind.mouse,
      );
      await mouse.addPointer(location: Offset.zero);
      await mouse.moveTo(tester.getCenter(find.byTooltip('放大')));
      await tester.pumpAndSettle();
      final feedback = find.ancestor(
        of: find.byTooltip('放大'),
        matching: find.byType(AnimatedScale),
      );
      expect(tester.widget<AnimatedScale>(feedback).scale, 1.025);
      await mouse.down(tester.getCenter(find.byTooltip('放大')));
      await tester.pump(const Duration(milliseconds: 120));
      expect(tester.widget<AnimatedScale>(feedback).scale, .96);
      await mouse.up();
      await mouse.removePointer();
      await tester.pumpAndSettle();
      expect(find.text('120%'), findsOneWidget);
      final viewer = tester.widget<InteractiveViewer>(
        find.byType(InteractiveViewer),
      );
      final beforePan = viewer.transformationController!.value.clone();
      await tester.drag(find.byType(InteractiveViewer), const Offset(60, 40));
      await tester.pumpAndSettle();
      expect(viewer.transformationController!.value, isNot(beforePan));
      await tester.tap(find.byTooltip('适应窗口'));
      await tester.pumpAndSettle();
      expect(find.text('100%'), findsOneWidget);
      final beforeCollapse = tester.getSize(find.byType(PageCanvas)).width;
      await tester.tap(find.byTooltip('切换页面列表'));
      await tester.pumpAndSettle();
      expect(
        tester.getSize(find.byType(PageCanvas)).width,
        greaterThan(beforeCollapse),
      );
      await tester.tap(find.byTooltip('切换页面列表'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey(document.pages[0].objects[0].id)));
      await tester.pumpAndSettle();
      await expectLater(
        find.byType(Workbench),
        matchesGoldenFile('goldens/workbench.png'),
      );
      // Narrow layout keeps the canvas and real property editor reachable.
      tester.view.physicalSize = const Size(640, 760);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await expectLater(
        find.byType(Workbench),
        matchesGoldenFile('goldens/workbench-narrow.png'),
      );
      await tester.tap(find.byTooltip('文字属性'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(TextField, 'New text 123'), findsOneWidget);
      expect(tester.takeException(), isNull);
      Navigator.of(tester.element(find.byType(TextField))).pop();
      await tester.pumpAndSettle();
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(disableAnimations: true);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('放大'));
      await tester.pump();
      expect(find.text('120%'), findsOneWidget);
      tester.platformDispatcher.clearAccessibilityFeaturesTestValue();
      tester.view.physicalSize = const Size(1400, 900);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey(document.pages[0].objects[0].id)));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Save 456');
      final savedPath = '${workspace.path}/saved-ui.pdf';
      FilePicker.platform = SavePicker(savedPath);
      try {
        await tester.runAsync(() async {
          await tester.tap(find.text('另存为'));
          for (
            var attempt = 0;
            attempt < 200 && !File(savedPath).existsSync();
            attempt++
          ) {
            await Future<void>.delayed(const Duration(milliseconds: 25));
          }
        });
        expect(container.read(documentProvider).error, isNull);
        expect(File(savedPath).existsSync(), isTrue);
        expect(container.read(documentProvider).error, isNull);
        final reopened =
            jsonDecode(
                  (await tester.runAsync(
                    () => rust.openDocument(
                      source: savedPath,
                      workspace: workspace.path,
                    ),
                  ))!,
                )
                as Map<String, dynamic>;
        expect(DocumentInfo(reopened).pages[0].objects[0].text, 'Save 456');
        await tester.runAsync(
          () => rust.closeDocument(documentId: DocumentInfo(reopened).id),
        );
        await tester.runAsync(
          () => seedPreview(container.read(documentProvider).preview!),
        );
        await tester.pumpAndSettle();
        showDialog<void>(
          context: tester.element(find.byType(Workbench)),
          builder: (_) =>
              RedactionDialog(snapshot: container.read(documentProvider)),
        );
        await tester.pumpAndSettle();
        await tester.dragFrom(
          tester.getCenter(find.byKey(const ValueKey('redaction-page'))),
          const Offset(80, 35),
        );
        await tester.pumpAndSettle();
        expect(find.text('已选 1 个区域'), findsOneWidget);
        final redactedPath = '${workspace.path}/redacted-ui.pdf';
        FilePicker.platform = SavePicker(redactedPath);
        await tester.runAsync(() async {
          await tester.tap(find.widgetWithText(FilledButton, '导出脱敏副本'));
          for (
            var attempt = 0;
            attempt < 200 && !File(redactedPath).existsSync();
            attempt++
          ) {
            await Future<void>.delayed(const Duration(milliseconds: 25));
          }
        });
        expect(container.read(documentProvider).error, isNull);
        expect(File(redactedPath).existsSync(), isTrue);
        final redacted = DocumentInfo(
          jsonDecode(
                (await tester.runAsync(
                  () => rust.openDocument(
                    source: redactedPath,
                    workspace: workspace.path,
                  ),
                ))!,
              )
              as Map<String, dynamic>,
        );
        expect(redacted.pages[0].textContent.trim(), isEmpty);
        expect(
          container.read(documentProvider).document!.pages[0].objects[0].text,
          'Save 456',
        );
        await tester.runAsync(
          () => rust.closeDocument(documentId: redacted.id),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(TextButton, '关闭'));
        await tester.pumpAndSettle();
      } finally {
        FilePicker.platform = SavePicker(savedPath);
      }
      Future<void> settleNative(Future<void> Function() action) async {
        await tester.runAsync(() async {
          await action();
          for (
            var attempt = 0;
            attempt < 200 && container.read(documentProvider).busy;
            attempt++
          ) {
            await Future<void>.delayed(const Duration(milliseconds: 25));
          }
        });
        final path = container.read(documentProvider).preview;
        if (path != null) await tester.runAsync(() => seedPreview(path));
        await tester.pumpAndSettle();
        expect(container.read(documentProvider).error, isNull);
      }

      await tester.tap(find.byKey(ValueKey(document.pages[0].objects[0].id)));
      await tester.pumpAndSettle();
      final beforeDrag = container.read(documentProvider).selected!.left;
      await settleNative(
        () => tester.drag(
          find.byKey(ValueKey(document.pages[0].objects[0].id)),
          const Offset(35, 20),
        ),
      );
      expect(
        container.read(documentProvider).selected!.left,
        greaterThan(beforeDrag),
      );
      final beforeResize = container.read(documentProvider).selected!;
      await settleNative(
        () => tester.drag(
          find.byKey(ValueKey('resize-${beforeResize.id}-11')),
          const Offset(40, 12),
        ),
      );
      final resized = container.read(documentProvider).selected!;
      expect(
        resized.right - resized.left,
        greaterThan(beforeResize.right - beforeResize.left),
      );
      await settleNative(() async {
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      });
      expect(container.read(documentProvider).document!.dirty, isFalse);
      final directlySaved = DocumentInfo(
        jsonDecode(
              (await tester.runAsync(
                () => rust.openDocument(
                  source: sourceFile.path,
                  workspace: workspace.path,
                ),
              ))!,
            )
            as Map<String, dynamic>,
      );
      expect(directlySaved.pages[0].objects[0].text, 'Save 456');
      expect(
        directlySaved.pages[0].objects[0].right -
            directlySaved.pages[0].objects[0].left,
        closeTo(resized.right - resized.left, .5),
      );
      await tester.runAsync(
        () => rust.closeDocument(documentId: directlySaved.id),
      );
      final imagePath = container.read(documentProvider).preview!;
      await settleNative(
        () => container
            .read(documentProvider.notifier)
            .command(
              'object_operation',
              value: jsonEncode({
                'kind': 'insert_image',
                'page': 0,
                'path': imagePath,
                'x': 300,
                'y': 400,
                'width': 120,
                'height': 90,
              }),
            ),
      );
      final imageObject = container
          .read(documentProvider)
          .document!
          .pages[0]
          .objects
          .firstWhere((o) => o.kind == 'image');
      await tester.tap(find.byKey(ValueKey(imageObject.id)));
      await tester.pumpAndSettle();
      await settleNative(
        () => tester.drag(
          find.byKey(ValueKey(imageObject.id)),
          const Offset(-30, 25),
        ),
      );
      final movedImage = container.read(documentProvider).selected!;
      expect(movedImage.left, lessThan(imageObject.left));
      await settleNative(
        () => tester.drag(
          find.byKey(ValueKey('resize-${imageObject.id}-11')),
          const Offset(35, 20),
        ),
      );
      final resizedImage = container.read(documentProvider).selected!;
      expect(
        resizedImage.right - resizedImage.left,
        greaterThan(movedImage.right - movedImage.left),
      );
      await settleNative(() async {
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      });
      final savedWithImage = DocumentInfo(
        jsonDecode(
              (await tester.runAsync(
                () => rust.openDocument(
                  source: sourceFile.path,
                  workspace: workspace.path,
                ),
              ))!,
            )
            as Map<String, dynamic>,
      );
      expect(
        savedWithImage.pages[0].objects.where((o) => o.kind == 'image'),
        hasLength(1),
      );
      await tester.runAsync(
        () => rust.closeDocument(documentId: savedWithImage.id),
      );
      await settleNative(
        () => container
            .read(documentProvider.notifier)
            .command(
              'page_operation',
              value: jsonEncode({'kind': 'insert', 'at': 1}),
            ),
      );
      expect(find.byType(ContinuousCanvas), findsOneWidget);
      ScaffoldMessenger.of(
        tester.element(find.byType(Workbench)),
      ).clearSnackBars();
      await tester.pump(const Duration(seconds: 5));
      await tester.runAsync(() async {
        final current = container.read(documentProvider).document!;
        final second = await rust.renderPreview(
          documentId: current.id,
          expectedVersion: BigInt.from(current.version),
          pageIndex: 1,
        );
        await seedPreview(second);
        await Future<void>.delayed(const Duration(milliseconds: 150));
      });
      await tester.pumpAndSettle();
      await expectLater(
        find.byType(Workbench),
        matchesGoldenFile('goldens/workbench-continuous.png'),
      );
      await tester.drag(
        find.byKey(const ValueKey('continuous-pages')),
        const Offset(0, -650),
      );
      await tester.pumpAndSettle();
      expect(container.read(documentProvider).page, 1);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byTooltip('项目 / 历史'));
      Future<void> settleHome() async {
        for (var i = 0; i < 40; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 25)),
          );
          await tester.pump();
          if (find.text('正在读取本机项目…').evaluate().isEmpty) break;
        }
        await tester.pumpAndSettle();
      }

      await settleHome();
      expect(find.byType(ProjectHome), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, '新建项目'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('project-name')),
        '客户资料',
      );
      await tester.runAsync(() async {
        await tester.tap(find.text('确定'));
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await settleHome();
      expect(find.text('客户资料'), findsOneWidget);
      final homeDocument = find.byKey(ValueKey('home-document-${document.id}'));
      await tester.tap(
        find.descendant(of: homeDocument, matching: find.byTooltip('归组 PDF')),
      );
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await tester.tap(find.text('移入 客户资料'));
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await settleHome();
      expect(find.text('1 份 PDF'), findsOneWidget);
      await tester.tap(find.text('客户资料'));
      await tester.pumpAndSettle();
      expect(homeDocument, findsOneWidget);
      await tester.tap(find.text('全部项目'));
      await tester.pumpAndSettle();
      await expectLater(
        find.byType(Workbench),
        matchesGoldenFile('goldens/project-home.png'),
      );
      expect(find.text('input.pdf'), findsWidgets);
      await tester.tap(find.text('客户资料'));
      await tester.pumpAndSettle();
      await tester.tap(homeDocument);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pumpAndSettle();
      expect(find.byType(ContinuousCanvas), findsOneWidget);
      expect(container.read(documentProvider).page, 1);
      await tester.runAsync(() => rust.closeDocument(documentId: document.id));
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      container.dispose();
      // Retain test documents for review. Flutter's asynchronous image decoder
      // may still hold a preview file until this test process exits on Windows.
      RustLib.dispose();
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      tester.platformDispatcher.clearAccessibilityFeaturesTestValue();
    }
  });
}
