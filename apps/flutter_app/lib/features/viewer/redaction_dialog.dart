import 'dart:convert';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../documents/document_controller.dart';
import '../../core/export_locations.dart';

class RedactionDialog extends ConsumerStatefulWidget {
  const RedactionDialog({super.key, required this.snapshot});
  final DocumentState snapshot;
  @override
  ConsumerState<RedactionDialog> createState() => _RedactionDialogState();
}

class _RedactionDialogState extends ConsumerState<RedactionDialog> {
  final areas = <Rect>[];
  Offset? start;
  Rect? drawing;
  bool busy = false;
  String? message;
  Future<void> export() async {
    if (busy) return;
    final captured = widget.snapshot.document!;
    final state = ref.read(documentProvider);
    if (state.document?.id != captured.id ||
        state.document?.version != captured.version ||
        state.busy) {
      setState(() => message = '文档已变化，请关闭并重新框选。');
      return;
    }
    setState(() {
      busy = true;
      message = null;
    });
    try {
      final locations = ref.read(exportLocationsProvider);
      final initialDirectory = await locations.initialDirectory(
        captured.source,
      );
      if (!mounted) return;
      final name = captured.name.replaceAll(
        RegExp(r'\.pdf$', caseSensitive: false),
        '',
      );
      final suggested = '$name-redacted.pdf';
      final destination = await FilePicker.platform.saveFile(
        dialogTitle: '导出图片脱敏副本',
        initialDirectory: initialDirectory,
        fileName: initialDirectory == null
            ? suggested
            : File(
                availableExportPath('$initialDirectory/$suggested'),
              ).uri.pathSegments.last,
        type: FileType.custom,
        allowedExtensions: ['pdf'],
      );
      if (!mounted || destination == null) return;
      final output = availableExportPath(
        withExportExtension(destination, 'pdf'),
      );
      final remembered = await locations.remember(File(output).parent.path);
      if (!mounted) return;
      final current = ref.read(documentProvider).document;
      if (current?.id != captured.id || current?.version != captured.version) {
        setState(() => message = '文档已变化，请关闭并重新框选。');
        return;
      }
      await ref
          .read(documentProvider.notifier)
          .command(
            'redact_export',
            value: jsonEncode({
              'page': widget.snapshot.page,
              'areas': [
                for (final area in areas)
                  [area.left, area.top, area.right, area.bottom],
              ],
              'destination': output,
            }),
          );
      if (!mounted) return;
      setState(() {
        message =
            ref.read(documentProvider).error ??
            '导出成功：脱敏副本已保存。\n保存位置：$output\n整份输出均为图片页面，不包含原文字层或附件。${remembered ? '' : '\n未能保存目录偏好'}';
      });
    } catch (failure) {
      if (mounted) setState(() => message = '导出失败：$failure');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final page = widget.snapshot.document!.pages[widget.snapshot.page];
    return PopScope(
      canPop: !busy,
      child: AlertDialog(
        title: const Text('框选并导出脱敏副本'),
        content: SizedBox(
          width: 520,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '拖动框选当前页的敏感区域，可框选多处。整份文档将重建为图片 PDF，清除框内像素和原文字层、附件、表单及签名。原件保留；输出不再能选择文字。最多 50 页。',
                  style: TextStyle(fontSize: 12),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: 520,
                  height: 350,
                  child: FittedBox(
                    fit: BoxFit.contain,
                    child: SizedBox(
                      width: page.width,
                      height: page.height,
                      child: LayoutBuilder(
                        builder: (context, constraints) {
                          Offset normalize(Offset p) => Offset(
                            (p.dx / constraints.maxWidth).clamp(0, 1),
                            (p.dy / constraints.maxHeight).clamp(0, 1),
                          );
                          return GestureDetector(
                            key: const ValueKey('redaction-page'),
                            onPanStart: busy
                                ? null
                                : (event) => setState(() {
                                    start = normalize(event.localPosition);
                                    drawing = null;
                                  }),
                            onPanUpdate: busy
                                ? null
                                : (event) {
                                    if (start != null) {
                                      setState(
                                        () => drawing = Rect.fromPoints(
                                          start!,
                                          normalize(event.localPosition),
                                        ),
                                      );
                                    }
                                  },
                            onPanEnd: busy
                                ? null
                                : (_) => setState(() {
                                    if (drawing != null &&
                                        drawing!.width > .002 &&
                                        drawing!.height > .002 &&
                                        areas.length < 100) {
                                      areas.add(drawing!);
                                    }
                                    drawing = null;
                                    start = null;
                                  }),
                            child: Stack(
                              fit: StackFit.expand,
                              children: [
                                Image.file(
                                  File(widget.snapshot.preview!),
                                  fit: BoxFit.fill,
                                ),
                                for (final rect in [...areas, ?drawing])
                                  Positioned(
                                    left: rect.left * constraints.maxWidth,
                                    top: rect.top * constraints.maxHeight,
                                    width: rect.width * constraints.maxWidth,
                                    height: rect.height * constraints.maxHeight,
                                    child: const ColoredBox(
                                      color: Colors.black,
                                    ),
                                  ),
                              ],
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Text('已选 ${areas.length} 个区域'),
                if (busy) const LinearProgressIndicator(),
                if (message != null) SelectableText(message!),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: busy ? null : () => setState(areas.clear),
            child: const Text('清空框选'),
          ),
          TextButton(
            onPressed: busy ? null : () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
          FilledButton(
            onPressed: busy || areas.isEmpty ? null : export,
            child: const Text('导出脱敏副本'),
          ),
        ],
      ),
    );
  }
}
