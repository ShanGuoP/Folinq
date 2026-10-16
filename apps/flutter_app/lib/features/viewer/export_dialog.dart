import 'dart:convert';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/export_locations.dart';
import '../documents/document_controller.dart';

List<int> parsePageRange(String input, int pageCount) {
  if (input.trim().isEmpty) return List.generate(pageCount, (i) => i);
  final result = <int>{};
  for (final part in input.replaceAll('，', ',').split(',')) {
    final match = RegExp(r'^\s*(\d+)\s*(?:-\s*(\d+))?\s*$').firstMatch(part);
    if (match == null) throw const FormatException('页码格式例如：1-3,5,8');
    final start = int.parse(match[1]!);
    final end = match[2] == null ? start : int.parse(match[2]!);
    if (start < 1 || end < start || end > pageCount) {
      throw FormatException('页码应在 1–$pageCount 以内，范围从小到大。');
    }
    for (var page = start; page <= end; page++) {
      result.add(page - 1);
    }
  }
  return result.toList();
}

class ExportDialog extends ConsumerStatefulWidget {
  const ExportDialog({super.key, required this.format});
  final String format;
  @override
  ConsumerState<ExportDialog> createState() => _ExportDialogState();
}

class _ExportDialogState extends ConsumerState<ExportDialog> {
  final range = TextEditingController();
  bool split = false, running = false, cancelled = false;
  int completed = 0, total = 0;
  String? message;
  bool succeeded = false;
  String mode = 'layout';
  @override
  void dispose() {
    range.dispose();
    super.dispose();
  }

  Future<void> export() async {
    final controller = ref.read(documentProvider.notifier);
    final snapshot = ref.read(documentProvider);
    if (running || snapshot.document == null || snapshot.busy) return;
    setState(() {
      running = true;
      cancelled = false;
      completed = 0;
      total = 0;
      message = null;
      succeeded = false;
    });
    try {
      final pages = parsePageRange(range.text, snapshot.document!.pages.length);
      final perPage = split || ['png', 'jpg'].contains(widget.format);
      final name = snapshot.document!.name.replaceAll(
        RegExp(r'\.pdf$', caseSensitive: false),
        '',
      );
      final locations = ref.read(exportLocationsProvider);
      final initialDirectory = await locations.initialDirectory(
        snapshot.document!.source,
      );
      if (!mounted || cancelled) return;
      String? destination;
      if (perPage) {
        destination = await FilePicker.platform.getDirectoryPath(
          dialogTitle: '选择输出文件夹',
          initialDirectory: initialDirectory,
        );
      } else {
        destination = await FilePicker.platform.saveFile(
          dialogTitle: '导出所选页面',
          fileName: initialDirectory == null
              ? '$name.${widget.format}'
              : File(
                  availableExportPath(
                    '$initialDirectory/$name.${widget.format}',
                  ),
                ).uri.pathSegments.last,
          initialDirectory: initialDirectory,
          type: FileType.custom,
          allowedExtensions: [widget.format],
        );
      }
      if (destination == null || !mounted || cancelled) return;
      if (!perPage) {
        destination = withExportExtension(destination, widget.format);
      }
      final remembered = await locations.remember(
        perPage ? destination : File(destination).parent.path,
      );
      if (!mounted || cancelled) return;
      final jobs = perPage
          ? [
              for (final page in pages) [page],
            ]
          : [pages];
      final paths = [
        for (final job in jobs)
          availableExportPath(
            perPage
                ? '$destination${Platform.pathSeparator}$name-page-${(job.first + 1).toString().padLeft(4, '0')}.${widget.format}'
                : destination,
          ),
      ];
      final actualDestination = perPage ? destination : paths.single;
      setState(() {
        running = true;
        completed = 0;
        total = jobs.length;
        cancelled = false;
        message = null;
        succeeded = false;
      });
      if (!await controller.applyPendingDrafts()) {
        throw FormatException(ref.read(documentProvider).error ?? '草稿提交失败');
      }
      final document = ref.read(documentProvider).document!;
      if (document.id != snapshot.document!.id) {
        throw const FormatException('当前文档已切换，请重新导出。');
      }
      for (var i = 0; i < jobs.length && !cancelled; i++) {
        final current = ref.read(documentProvider).document;
        if (current?.id != document.id ||
            current?.version != document.version) {
          throw const FormatException('文档已发生变化，已停止导出。');
        }
        await controller.command(
          'export',
          value: jsonEncode({
            'format': widget.format,
            'mode': mode,
            'pages': jobs[i],
            'destination': paths[i],
          }),
        );
        final error = ref.read(documentProvider).error;
        if (error != null) throw FormatException(error);
        if (!mounted) return;
        setState(() => completed++);
        await Future<void>.delayed(Duration.zero);
      }
      if (mounted) {
        setState(() {
          succeeded = completed == total;
          message =
              '${succeeded ? '导出成功' : '已停止导出'}，已保存 $completed 个文件。\n保存位置：$actualDestination'
              '${!remembered ? '\n未能保存目录偏好，下次启动将使用 PDF 所在文件夹。' : ''}';
        });
      }
    } catch (failure) {
      if (mounted) {
        setState(
          () => message =
              '$failure${completed > 0 ? '\n已完成的 $completed 个文件保留。' : ''}',
        );
      }
    } finally {
      if (mounted) setState(() => running = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !running,
    child: AlertDialog(
      title: Row(
        children: [
          if (succeeded) ...[
            const Icon(Icons.check_circle, color: Color(0xff348263)),
            const SizedBox(width: 10),
          ],
          Text(succeeded ? '导出成功' : '导出 ${widget.format.toUpperCase()}'),
        ],
      ),
      content: SizedBox(
        width: 430,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (!succeeded) ...[
                TextField(
                  controller: range,
                  enabled: !running && !succeeded,
                  decoration: const InputDecoration(
                    labelText: '页面范围',
                    hintText: '留空为全部，例如 1-3,5',
                  ),
                ),
                const SizedBox(height: 12),
                const Text(
                  '同名文件会自动添加编号保存，保留已有文件。',
                  style: TextStyle(fontSize: 12),
                ),
                if (!['png', 'jpg'].contains(widget.format))
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('按页拆分为独立文件'),
                    value: split,
                    onChanged: running || succeeded
                        ? null
                        : (value) => setState(() => split = value!),
                  )
                else
                  const Text('每页输出一张图片，保存到所选文件夹。'),
                const SizedBox(height: 12),
                if (['docx', 'md'].contains(widget.format)) ...[
                  DropdownButtonFormField<String>(
                    initialValue: mode,
                    decoration: const InputDecoration(labelText: '导出方式'),
                    items: [
                      DropdownMenuItem(
                        value: 'layout',
                        child: Text(
                          widget.format == 'docx' ? '可编辑文字与版式' : '页面图片与版式',
                        ),
                      ),
                      const DropdownMenuItem(
                        value: 'text',
                        child: Text('仅提取文字'),
                      ),
                    ],
                    onChanged: running || succeeded
                        ? null
                        : (value) => setState(() => mode = value!),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    mode == 'layout'
                        ? (widget.format == 'md'
                              ? '每页保存为高清图片，保留表格、图片和文字外观。请将 Markdown 与配套资源文件夹一起移动。'
                              : '文字、字号、字体、颜色及位置转换为可编辑的 Word 内容，同时保留原有图片和可识别的表格。扫描页需先完成 OCR。')
                        : '仅提取文字内容，不保留图片、表格结构和原始排版。',
                    style: const TextStyle(fontSize: 12),
                  ),
                ],
              ],
              if (running) ...[
                const SizedBox(height: 16),
                LinearProgressIndicator(
                  value: total == 0 ? null : completed / total,
                ),
                Text('$completed / $total'),
              ],
              if (message != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: SelectableText(message!),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: running
              ? () => setState(() => cancelled = true)
              : () => Navigator.pop(context),
          child: Text(running ? '完成当前文件后停止' : '关闭'),
        ),
        FilledButton(
          onPressed: running
              ? null
              : (succeeded ? () => Navigator.pop(context) : export),
          child: Text(succeeded ? '完成' : '选择位置并导出'),
        ),
      ],
    ),
  );
}
