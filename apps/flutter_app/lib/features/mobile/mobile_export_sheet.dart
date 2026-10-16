import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/platform_documents.dart';
import '../../core/online_ocr.dart';
import '../documents/document_controller.dart';
import '../viewer/export_dialog.dart' show parsePageRange;
import '../viewer/online_ocr_options.dart';

class MobileExportSheet extends ConsumerStatefulWidget {
  const MobileExportSheet({super.key});
  @override
  ConsumerState<MobileExportSheet> createState() => _MobileExportSheetState();
}

class _MobileExportSheetState extends ConsumerState<MobileExportSheet> {
  final range = TextEditingController();
  String format = 'pdf';
  bool running = false;
  bool online = false;
  String? message, savedUri;
  @override
  void dispose() {
    range.dispose();
    super.dispose();
  }

  Future<void> export() async {
    final controller = ref.read(documentProvider.notifier);
    final document = ref.read(documentProvider).document;
    if (running || document == null) return;
    setState(() {
      running = true;
      message = null;
      savedUri = null;
    });
    try {
      final pages = parsePageRange(range.text, document.pages.length);
      if (['png', 'jpg'].contains(format) && pages.length != 1) {
        throw const FormatException('图片导出请填写一个页码。多页可先导出 PDF。');
      }
      if (!await controller.applyPendingDrafts()) {
        throw StateError(ref.read(documentProvider).error ?? '修改提交失败');
      }
      if (ref.read(documentProvider).document?.id != document.id) {
        throw StateError('文档已切换，请重新导出。');
      }
      final saved = online && ['docx', 'md', 'txt'].contains(format)
          ? await controller.exportOnline(
                  format,
                  pages,
                  ref.read(onlineOcrConfigProvider),
                  onProgress: (value) {
                    if (mounted) setState(() => message = value);
                  },
                ) !=
                null
          : await controller.exportAndroid(format, pages);
      if (!mounted) return;
      setState(() {
        savedUri = saved ? controller.lastExternalExportUri : null;
        message = saved
            ? '导出成功，文件已写入所选位置。'
            : ref.read(documentProvider).error ?? '已取消，未导出文件。';
      });
    } catch (error) {
      if (mounted) setState(() => message = readableError('$error'));
    } finally {
      if (mounted) setState(() => running = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !running,
    child: Padding(
      padding: EdgeInsets.fromLTRB(
        20,
        0,
        20,
        24 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text(
                    '导出副本',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
                  ),
                ),
                IconButton(
                  tooltip: '关闭导出',
                  onPressed: running ? null : () => Navigator.pop(context),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
            const SizedBox(height: 20),
            DropdownButtonFormField<String>(
              initialValue: format,
              decoration: const InputDecoration(labelText: '文件格式'),
              items: const [
                DropdownMenuItem(value: 'pdf', child: Text('PDF')),
                DropdownMenuItem(value: 'docx', child: Text('Word · 自动排版')),
                DropdownMenuItem(
                  value: 'md',
                  child: Text('Markdown · 含配图的 ZIP'),
                ),
                DropdownMenuItem(value: 'txt', child: Text('纯文字 TXT')),
                DropdownMenuItem(value: 'png', child: Text('单页 PNG')),
                DropdownMenuItem(value: 'jpg', child: Text('单页 JPG')),
              ],
              onChanged: running
                  ? null
                  : (value) => setState(() {
                      format = value!;
                      savedUri = null;
                      message = null;
                    }),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: range,
              enabled: !running,
              keyboardType: TextInputType.text,
              decoration: const InputDecoration(
                labelText: '页码范围',
                hintText: '留空导出全部，例如 1-3,5',
              ),
            ),
            const SizedBox(height: 12),
            const Text('使用系统文件选择器另存。Markdown 与配图一起打包；扫描页可启用在线 OCR 导出文字。'),
            if (['docx', 'md', 'txt'].contains(format))
              OnlineOcrOptions(
                enabled: online,
                running: running,
                onChanged: (v) => setState(() => online = v),
              ),
            if (running && online)
              TextButton(
                onPressed: controllerCancel,
                child: const Text('取消在线识别'),
              ),
            if (message != null)
              Padding(
                padding: const EdgeInsets.only(top: 16),
                child: Text(message!),
              ),
            if (savedUri != null) ...[
              const SizedBox(height: 8),
              SelectableText(savedUri!, style: const TextStyle(fontSize: 11)),
              TextButton.icon(
                onPressed: () async {
                  try {
                    await PlatformDocuments.share(savedUri!, mimeFor(format));
                  } catch (error) {
                    if (mounted) setState(() => message = '无法打开分享菜单：$error');
                  }
                },
                icon: const Icon(Icons.share_outlined),
                label: const Text('分享已导出文件'),
              ),
            ],
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: running ? null : export,
                icon: const Icon(Icons.save_alt),
                label: Text(running ? '正在导出…' : '选择保存位置'),
              ),
            ),
          ],
        ),
      ),
    ),
  );

  void controllerCancel() =>
      ref.read(documentProvider.notifier).cancelOnlineExport();
}

String mimeFor(String format) =>
    const {
      'pdf': 'application/pdf',
      'md': 'application/zip',
      'txt': 'text/plain',
      'docx':
          'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
      'png': 'image/png',
      'jpg': 'image/jpeg',
    }[format] ??
    'application/octet-stream';
