import 'dart:convert';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
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
  @override
  void dispose() {
    range.dispose();
    super.dispose();
  }

  Future<void> export() async {
    final controller = ref.read(documentProvider.notifier);
    final snapshot = ref.read(documentProvider);
    if (snapshot.document == null || snapshot.busy) return;
    try {
      final pages = parsePageRange(range.text, snapshot.document!.pages.length);
      final perPage = split || ['png', 'jpg'].contains(widget.format);
      final name = snapshot.document!.name.replaceAll(
        RegExp(r'\.pdf$', caseSensitive: false),
        '',
      );
      String? destination;
      if (perPage) {
        destination = await FilePicker.platform.getDirectoryPath(
          dialogTitle: '选择输出文件夹',
        );
      } else {
        destination = await FilePicker.platform.saveFile(
          dialogTitle: '导出所选页面',
          fileName: '$name.${widget.format}',
          type: FileType.custom,
          allowedExtensions: [widget.format],
        );
      }
      if (destination == null || !mounted) return;
      final jobs = perPage
          ? [
              for (final page in pages) [page],
            ]
          : [pages];
      final paths = [
        for (final job in jobs)
          perPage
              ? '$destination${Platform.pathSeparator}$name-page-${(job.first + 1).toString().padLeft(4, '0')}.${widget.format}'
              : destination,
      ];
      if (paths.any((path) => File(path).existsSync())) {
        throw const FormatException('输出中有同名文件，请选择新的文件名或空文件夹。');
      }
      setState(() {
        running = true;
        completed = 0;
        total = jobs.length;
        cancelled = false;
        message = null;
      });
      if (!await controller.applyPendingDrafts()) {
        throw FormatException(ref.read(documentProvider).error ?? '草稿提交失败');
      }
      final document = ref.read(documentProvider).document!;
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
        setState(
          () => message = '${cancelled ? '已停止' : '导出完成'}，已保存 $completed 个文件。',
        );
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
      title: Text('导出 ${widget.format.toUpperCase()}'),
      content: SizedBox(
        width: 430,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: range,
              enabled: !running,
              decoration: const InputDecoration(
                labelText: '页面范围',
                hintText: '留空为全部，例如 1-3,5',
              ),
            ),
            const SizedBox(height: 12),
            if (!['png', 'jpg'].contains(widget.format))
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('按页拆分为独立文件'),
                value: split,
                onChanged: running
                    ? null
                    : (value) => setState(() => split = value!),
              )
            else
              const Text('每页输出一张图片，保存到所选文件夹。'),
            const SizedBox(height: 12),
            const Text(
              '文字格式保留可编辑内容；复杂表格、多栏和公式的布局可能变化。',
              style: TextStyle(fontSize: 12),
            ),
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
      actions: [
        TextButton(
          onPressed: running
              ? () => setState(() => cancelled = true)
              : () => Navigator.pop(context),
          child: Text(running ? '完成当前文件后停止' : '关闭'),
        ),
        FilledButton(
          onPressed: running ? null : export,
          child: const Text('选择位置并导出'),
        ),
      ],
    ),
  );
}
