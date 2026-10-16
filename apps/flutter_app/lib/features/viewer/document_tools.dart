import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/app_directories.dart';
import '../../core/rust/api.dart' as rust;
import '../../core/font_assets.dart';
import '../../core/document.dart';
import '../../shared/editor_theme.dart';
import '../documents/document_controller.dart';
import 'drawing_dialog.dart';
import 'export_dialog.dart';
import 'annotations_dialog.dart';
import 'redaction_dialog.dart';

class NewDocumentButton extends ConsumerWidget {
  const NewDocumentButton({super.key, this.library = false});
  final bool library;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final VoidCallback? onPressed = ref.watch(documentProvider).busy
        ? null
        : () => ref.read(documentProvider.notifier).importDocument([]);
    return library
        ? LibraryAction(
            icon: Icons.note_add_outlined,
            label: '新建 PDF',
            accent: const Color(0xff8860ff),
            onPressed: onPressed,
          )
        : TextButton.icon(
            onPressed: onPressed,
            icon: const Icon(Icons.note_add_outlined, size: 18),
            label: const Text('新建 PDF'),
          );
  }
}

class DocumentTabs extends ConsumerWidget {
  const DocumentTabs({super.key, required this.disabled});
  final bool disabled;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final documents = ref.watch(openDocumentsProvider);
    final active = ref.watch(documentProvider).document?.id;
    if (documents.length < 2) return const SizedBox.shrink();
    return SizedBox(
      height: 38,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        children: [
          for (final document in documents)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: Material(
                color: active == document.id
                    ? EditorColors.surface
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(8),
                child: Row(
                  children: [
                    TextButton(
                      onPressed: disabled
                          ? null
                          : () => ref
                                .read(documentProvider.notifier)
                                .switchDocument(document.id),
                      child: Text(
                        '${document.name}${document.dirty ? ' ·' : ''}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    IconButton(
                      tooltip: '关闭 ${document.name}',
                      icon: const Icon(Icons.close, size: 14),
                      onPressed: disabled
                          ? null
                          : () async {
                              if (document.dirty ||
                                  ref
                                      .read(documentProvider.notifier)
                                      .hasDrafts(document.id)) {
                                final close = await showDialog<bool>(
                                  context: context,
                                  builder: (context) => AlertDialog(
                                    title: const Text('关闭未保存文档？'),
                                    content: const Text(
                                      '工作版本会保留在本机，可从“恢复工作”重新打开。',
                                    ),
                                    actions: [
                                      TextButton(
                                        onPressed: () =>
                                            Navigator.pop(context, false),
                                        child: const Text('取消'),
                                      ),
                                      FilledButton(
                                        onPressed: () =>
                                            Navigator.pop(context, true),
                                        child: const Text('关闭'),
                                      ),
                                    ],
                                  ),
                                );
                                if (close != true) return;
                              }
                              await ref
                                  .read(documentProvider.notifier)
                                  .closeDocument(document.id);
                            },
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class RecoveryButton extends ConsumerWidget {
  const RecoveryButton({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) => TextButton.icon(
    onPressed: ref.watch(documentProvider).busy
        ? null
        : () async {
            try {
              final documents = await ref
                  .read(documentProvider.notifier)
                  .recoverable();
              if (!context.mounted) return;
              final id = await showDialog<String>(
                context: context,
                builder: (context) => AlertDialog(
                  title: const Text('恢复本机工作'),
                  content: SizedBox(
                    width: 480,
                    height: 320,
                    child: documents.isEmpty
                        ? const Center(child: Text('没有可恢复的工作版本'))
                        : ListView(
                            children: [
                              for (final document in documents)
                                ListTile(
                                  title: Text(document.name),
                                  subtitle: Text(
                                    '版本 ${document.version} · ${document.dirty ? '未保存修改' : '已保存'}',
                                  ),
                                  onTap: () =>
                                      Navigator.pop(context, document.id),
                                ),
                            ],
                          ),
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('取消'),
                    ),
                  ],
                ),
              );
              if (id != null) {
                await ref.read(documentProvider.notifier).restore(id);
              }
            } catch (error) {
              if (context.mounted) showError(context, error);
            }
          },
    icon: const Icon(Icons.history, size: 16),
    label: const Text('恢复工作'),
  );
}

class ImportDocumentButton extends ConsumerWidget {
  const ImportDocumentButton({super.key, this.library = false});
  final bool library;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final VoidCallback? onPressed = ref.watch(documentProvider).busy
        ? null
        : () async {
            final source = await FilePicker.platform.pickFiles(
              type: FileType.custom,
              allowedExtensions: [
                'md',
                'markdown',
                'txt',
                'docx',
                'png',
                'jpg',
                'jpeg',
              ],
              allowMultiple: true,
            );
            if (source == null) return;
            final paths = source.files
                .map((file) => file.path)
                .whereType<String>()
                .toList();
            if (paths.isNotEmpty) {
              await ref.read(documentProvider.notifier).importDocument(paths);
            }
          };
    return library
        ? LibraryAction(
            icon: Icons.sync_alt,
            label: '转换为 PDF',
            accent: const Color(0xff168667),
            onPressed: onPressed,
          )
        : TextButton.icon(
            onPressed: onPressed,
            icon: const Icon(Icons.sync_alt, size: 18),
            label: const Text('转换为 PDF'),
          );
  }
}

class CacheButton extends ConsumerWidget {
  const CacheButton({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) => TextButton.icon(
    onPressed: ref.watch(documentProvider).busy
        ? null
        : () async {
            try {
              final root = await applicationSupportDirectory();
              final workspace = '${root.path}/documents';
              final stats =
                  jsonDecode(
                        await rust.applicationData(
                          workspace: workspace,
                          clearCache: false,
                        ),
                      )
                      as Map;
              if (!context.mounted) return;
              final clear = await showDialog<bool>(
                context: context,
                builder: (context) => AlertDialog(
                  title: const Text('本机缓存'),
                  content: Text(
                    '${stats['cache_files']} 个预览与 OCR 缓存文件，约 ${((stats['cache_bytes'] as num) / 1048576).toStringAsFixed(1)} MB。\n\n清理不会删除原件、工作版本、历史和恢复记录。',
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: const Text('关闭'),
                    ),
                    FilledButton(
                      onPressed: () => Navigator.pop(context, true),
                      child: const Text('清理缓存'),
                    ),
                  ],
                ),
              );
              if (clear == true) {
                final result =
                    jsonDecode(
                          await rust.applicationData(
                            workspace: workspace,
                            clearCache: true,
                          ),
                        )
                        as Map;
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(
                        '已清理 ${result['removed']} 个缓存文件；${result['locked']} 个文件正在使用，予以保留。',
                      ),
                    ),
                  );
                }
              }
            } catch (error) {
              if (context.mounted) showError(context, error);
            }
          },
    icon: const Icon(Icons.storage_outlined, size: 16),
    label: const Text('缓存'),
  );
}

void showError(BuildContext context, Object error) =>
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(readableError('$error')),
        behavior: SnackBarBehavior.floating,
      ),
    );

class DocumentToolStrip extends ConsumerStatefulWidget {
  const DocumentToolStrip({super.key});
  @override
  ConsumerState<DocumentToolStrip> createState() => _DocumentToolStripState();
}

class _DocumentToolStripState extends ConsumerState<DocumentToolStrip> {
  Future<void> action(
    BuildContext context,
    WidgetRef ref,
    String action,
  ) async {
    final state = ref.read(documentProvider);
    final document = state.document;
    if (document == null || state.busy) return;
    final controller = ref.read(documentProvider.notifier);
    try {
      switch (action) {
        case 'annotations':
          await showDialog<void>(
            context: context,
            builder: (_) => const AnnotationsDialog(),
          );
        case 'redact':
          if (!await controller.applyPendingDrafts() || !context.mounted) {
            return;
          }
          final snapshot = ref.read(documentProvider);
          if (snapshot.preview != null) {
            await showDialog<void>(
              context: context,
              barrierDismissible: false,
              builder: (_) => RedactionDialog(snapshot: snapshot),
            );
          }
        case 'draw':
          final strokes = await showDialog<List<dynamic>>(
            context: context,
            builder: (_) => const DrawingDialog(),
          );
          if (strokes != null) {
            await controller.command(
              'object_operation',
              value: jsonEncode({
                'kind': 'ink',
                'page': state.page,
                'strokes': strokes,
              }),
            );
          }
        case 'ocr':
          final language = await showDialog<String>(
            context: context,
            builder: (context) => SimpleDialog(
              title: const Text('离线识别当前页'),
              children: [
                for (final option in [
                  ('', '使用系统语言'),
                  ('zh-Hans', '简体中文'),
                  ('en-US', 'English'),
                ])
                  SimpleDialogOption(
                    onPressed: () => Navigator.pop(context, option.$1),
                    child: Text(option.$2),
                  ),
              ],
            ),
          );
          if (language == null) return;
          final result = await controller.recognize(language);
          if (result == null || !context.mounted) return;
          await showDialog<void>(
            context: context,
            builder: (context) => AlertDialog(
              title: Text(
                result['provider'] == 'native_text'
                    ? '已有原生文字 · 未运行 OCR'
                    : '离线 OCR 结果',
              ),
              content: SizedBox(
                width: 560,
                height: 360,
                child: SingleChildScrollView(
                  child: SelectableText(result['text'] as String),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Clipboard.setData(
                    ClipboardData(text: result['text'] as String),
                  ),
                  child: const Text('复制'),
                ),
                if (result['provider'] != 'native_text' &&
                    (result['words'] as List).isNotEmpty)
                  FilledButton(
                    onPressed: () async {
                      String? font;
                      if (!(result['text'] as String).codeUnits.every(
                        (c) => c < 128,
                      )) {
                        font = await FontAssets.chineseFont();
                      }
                      await controller.command(
                        'ocr_layer',
                        value: jsonEncode({
                          'page': state.page,
                          'language': language,
                          'font_path': font,
                        }),
                      );
                      if (context.mounted) Navigator.pop(context);
                    },
                    child: const Text('加入可搜索文字层'),
                  ),
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('关闭'),
                ),
              ],
            ),
          );
        case 'search':
          await showDialog<void>(
            context: context,
            builder: (_) => const _SearchDialog(),
          );
        case 'copy':
          await Clipboard.setData(
            ClipboardData(
              text:
                  state.selected?.text ??
                  document.pages[state.page].textContent,
            ),
          );
          if (context.mounted) {
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(const SnackBar(content: Text('文字已复制')));
          }
        case 'insert_text':
        case 'comment':
          final request = await showDialog<Map<String, dynamic>>(
            context: context,
            builder: (_) => _InsertDialog(
              page: document.pages[state.page],
              comment: action == 'comment',
            ),
          );
          if (request != null) {
            await controller.command(
              'object_operation',
              value: jsonEncode({'page': state.page, ...request}),
            );
          }
        case 'insert_image':
          final result = await FilePicker.platform.pickFiles(
            type: FileType.custom,
            allowedExtensions: ['png', 'jpg', 'jpeg'],
          );
          final path = result?.files.single.path;
          if (path != null) {
            final buffer = await ui.ImmutableBuffer.fromFilePath(path);
            late final double imageWidth, imageHeight;
            try {
              final descriptor = await ui.ImageDescriptor.encoded(buffer);
              imageWidth = descriptor.width.toDouble();
              imageHeight = descriptor.height.toDouble();
              descriptor.dispose();
            } finally {
              buffer.dispose();
            }
            final ratio = imageHeight / imageWidth;
            final maxHeight = document.pages[state.page].height * .4;
            final width = (maxHeight / ratio).clamp(1.0, 240.0);
            await controller.command(
              'object_operation',
              value: jsonEncode({
                'kind': 'insert_image',
                'page': state.page,
                'path': path,
                'x': 60,
                'y': document.pages[state.page].height * .5,
                'width': width,
                'height': width * ratio,
              }),
            );
          }
        case 'merge':
          final result = await FilePicker.platform.pickFiles(
            type: FileType.custom,
            allowedExtensions: ['pdf'],
          );
          if (result?.files.single.path case final String path) {
            await controller.command(
              'page_operation',
              value: jsonEncode({
                'kind': 'merge',
                'path': path,
                'at': state.page + 1,
              }),
            );
          }
        case 'rotate':
          await controller.command(
            'page_operation',
            value: jsonEncode({
              'kind': 'rotate',
              'page': state.page,
              'clockwise': true,
            }),
          );
        case 'insert_page':
          await controller.command(
            'page_operation',
            value: jsonEncode({'kind': 'insert', 'at': state.page + 1}),
          );
        case 'delete_page':
          final remove = await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
              title: Text('删除第 ${state.page + 1} 页？'),
              content: const Text('删除后可撤销。'),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('取消'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: const Text('删除'),
                ),
              ],
            ),
          );
          if (remove == true) {
            await controller.command(
              'page_operation',
              value: jsonEncode({'kind': 'delete', 'page': state.page}),
            );
          }
        case 'move_up':
        case 'move_down':
          final target = state.page + (action == 'move_up' ? -1 : 1);
          if (target >= 0 && target < document.pages.length) {
            await controller.command(
              'page_operation',
              value: jsonEncode({
                'kind': 'move',
                'page': state.page,
                'target': target,
              }),
            );
            if (ref.read(documentProvider).error == null) {
              await controller.goToPage(target);
            }
          }
        default:
          if (!action.startsWith('export_')) return;
          final format = action.substring(7);
          final singlePage = ['png', 'jpg', 'pdf'].contains(format);
          if (Platform.isAndroid) {
            final saved = await controller.exportAndroid(
              format,
              singlePage ? [state.page] : [],
            );
            if (context.mounted && saved) {
              ScaffoldMessenger.of(
                context,
              ).showSnackBar(const SnackBar(content: Text('导出完成')));
            }
            return;
          }
          if (!context.mounted) return;
          await showDialog<void>(
            context: context,
            barrierDismissible: false,
            builder: (_) => ExportDialog(format: format),
          );
      }
    } catch (error) {
      if (context.mounted) showError(context, error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(documentProvider);
    final busy = state.busy;
    return Padding(
      key: const ValueKey('document-tools'),
      padding: const EdgeInsets.fromLTRB(18, 0, 18, 0),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: const BoxDecoration(
          color: EditorColors.surface,
          borderRadius: BorderRadius.vertical(bottom: Radius.circular(16)),
          border: Border(top: BorderSide(color: EditorColors.border)),
        ),
        child: Wrap(
          alignment: WrapAlignment.center,
          spacing: 12,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            TextButton.icon(
              onPressed: busy
                  ? null
                  : () =>
                        ref.read(documentProvider.notifier).importDocument([]),
              icon: const Icon(Icons.note_add_outlined, size: 16),
              label: const Text('新建'),
            ),
            TextButton.icon(
              onPressed: busy ? null : () => action(context, ref, 'search'),
              icon: const Icon(Icons.search, size: 16),
              label: const Text('搜索'),
            ),
            PopupMenuButton<String>(
              tooltip: '编辑',
              position: PopupMenuPosition.under,
              enabled: !busy,
              onSelected: (value) => action(context, ref, value),
              itemBuilder: (_) => [
                for (final item in [
                  ('copy', Icons.copy_outlined, '复制'),
                  ('insert_text', Icons.text_fields, '添加文字'),
                  ('insert_image', Icons.image_outlined, '添加图片'),
                  ('comment', Icons.comment_outlined, '注释'),
                  ('draw', Icons.draw_outlined, '绘画 / 手签'),
                  ('annotations', Icons.speaker_notes_outlined, '管理批注'),
                  ('redact', Icons.hide_image_outlined, '脱敏副本'),
                ])
                  PopupMenuItem(
                    value: item.$1,
                    child: Row(
                      children: [
                        Icon(item.$2, size: 18),
                        const SizedBox(width: 12),
                        Text(item.$3),
                      ],
                    ),
                  ),
              ],
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: EditorColors.selection,
                  borderRadius: BorderRadius.circular(11),
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.edit_outlined,
                      size: 19,
                      color: EditorColors.focus,
                    ),
                    SizedBox(width: 6),
                    Text(
                      '编辑',
                      style: TextStyle(
                        color: EditorColors.focus,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    SizedBox(width: 4),
                    Icon(Icons.keyboard_arrow_down, size: 16),
                  ],
                ),
              ),
            ),
            PopupMenuButton<String>(
              tooltip: '页面管理',
              enabled: !busy,
              onSelected: (value) => action(context, ref, value),
              itemBuilder: (_) => [
                for (final item in [
                  ('rotate', '顺时针旋转'),
                  ('insert_page', '插入空白页'),
                  ('delete_page', '删除当前页'),
                  ('move_up', '当前页上移'),
                  ('move_down', '当前页下移'),
                  ('merge', '从 PDF 插入页面'),
                ])
                  PopupMenuItem(value: item.$1, child: Text(item.$2)),
              ],
              child: const Padding(
                padding: EdgeInsets.all(10),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.view_carousel_outlined, size: 16),
                    SizedBox(width: 6),
                    Text('页面管理'),
                  ],
                ),
              ),
            ),
            PopupMenuButton<String>(
              tooltip: '导出',
              enabled: !busy,
              onSelected: (value) => action(context, ref, 'export_$value'),
              itemBuilder: (_) => [
                for (final item in [
                  ('pdf', 'PDF / 拆分'),
                  ('md', 'Markdown'),
                  ('txt', '纯文本 TXT'),
                  ('docx', 'Word DOCX'),
                  ('png', 'PNG 图片 / 批量'),
                  ('jpg', 'JPG 图片 / 批量'),
                ])
                  PopupMenuItem(value: item.$1, child: Text(item.$2)),
              ],
              child: const Padding(
                padding: EdgeInsets.all(10),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.ios_share_outlined, size: 16),
                    SizedBox(width: 6),
                    Text('导出'),
                  ],
                ),
              ),
            ),
            TextButton.icon(
              onPressed: state.ocrRunning
                  ? () => ref.read(documentProvider.notifier).cancelOcr()
                  : busy || !Platform.isWindows
                  ? null
                  : () => action(context, ref, 'ocr'),
              icon: Icon(
                state.ocrRunning
                    ? Icons.cancel_outlined
                    : Icons.document_scanner_outlined,
                size: 16,
              ),
              label: Text(
                state.ocrRunning
                    ? '取消识别'
                    : Platform.isWindows
                    ? '离线 OCR'
                    : 'OCR（Windows）',
              ),
            ),
            const ImportDocumentButton(),
            const RecoveryButton(),
            const CacheButton(),
          ],
        ),
      ),
    );
  }
}

class _InsertDialog extends StatefulWidget {
  const _InsertDialog({required this.page, required this.comment});
  final PageInfo page;
  final bool comment;
  @override
  State<_InsertDialog> createState() => _InsertDialogState();
}

class _InsertDialogState extends State<_InsertDialog> {
  final text = TextEditingController();
  final x = TextEditingController(text: '60'),
      y = TextEditingController(),
      size = TextEditingController(text: '16');
  String? font;
  String? error;
  @override
  void initState() {
    super.initState();
    y.text = (widget.page.height - 100).round().toString();
  }

  @override
  void dispose() {
    text.dispose();
    x.dispose();
    y.dispose();
    size.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.comment ? '添加注释' : '添加文字'),
    content: SizedBox(
      width: 460,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: text,
              autofocus: true,
              minLines: 3,
              maxLines: 6,
              decoration: const InputDecoration(labelText: '内容'),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                for (final item in [(x, '横向位置'), (y, '纵向位置'), (size, '字号')])
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: TextField(
                        controller: item.$1,
                        keyboardType: TextInputType.number,
                        decoration: InputDecoration(labelText: item.$2),
                      ),
                    ),
                  ),
              ],
            ),
            if (!widget.comment)
              TextButton.icon(
                onPressed: () async {
                  final result = await FilePicker.platform.pickFiles(
                    type: FileType.custom,
                    allowedExtensions: ['ttf', 'otf', 'ttc'],
                  );
                  if (mounted && result?.files.single.path != null) {
                    setState(() => font = result!.files.single.path);
                  }
                },
                icon: const Icon(Icons.font_download_outlined, size: 16),
                label: Text(
                  font == null
                      ? '内置中文字体 · 点击更换'
                      : File(font!).uri.pathSegments.last,
                ),
              ),
            if (error != null) Text(error!),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: () async {
          final px = double.tryParse(x.text),
              py = double.tryParse(y.text),
              fontSize = double.tryParse(size.text);
          if (text.text.trim().isEmpty ||
              px == null ||
              py == null ||
              fontSize == null ||
              !px.isFinite ||
              !py.isFinite ||
              !fontSize.isFinite ||
              fontSize < 4 ||
              fontSize > 288) {
            setState(() => error = '请输入内容和有效的位置、字号（4–288）。');
            return;
          }
          try {
            final fontPath = widget.comment
                ? null
                : font ??
                      (text.text.codeUnits.every((c) => c < 128)
                          ? null
                          : await FontAssets.chineseFont());
            if (!context.mounted) return;
            Navigator.pop(context, {
              'kind': widget.comment ? 'comment' : 'insert_text',
              'text': text.text,
              'x': px,
              'y': py,
              if (!widget.comment) ...{
                'font_size': fontSize,
                'font_path': fontPath,
              },
            });
          } catch (failure) {
            if (mounted) setState(() => error = readableError('$failure'));
          }
        },
        child: const Text('添加'),
      ),
    ],
  );
}

class _SearchDialog extends ConsumerStatefulWidget {
  const _SearchDialog();
  @override
  ConsumerState<_SearchDialog> createState() => _SearchDialogState();
}

class _SearchDialogState extends ConsumerState<_SearchDialog> {
  final query = TextEditingController();
  @override
  void dispose() {
    query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final document = ref.watch(documentProvider).document;
    final keyword = query.text.toLowerCase();
    final hits =
        document?.pages
            .where(
              (page) =>
                  keyword.isNotEmpty &&
                  page.textContent.toLowerCase().contains(keyword),
            )
            .toList() ??
        [];
    return AlertDialog(
      title: const Text('搜索文档'),
      content: SizedBox(
        width: 520,
        height: 400,
        child: Column(
          children: [
            TextField(
              controller: query,
              autofocus: true,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                hintText: '搜索文字，支持中文',
              ),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: ListView(
                children: [
                  for (final page in hits)
                    ListTile(
                      title: Text('第 ${document!.pages.indexOf(page) + 1} 页'),
                      subtitle: Text(
                        page.textContent,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      onTap: () async {
                        final controller = ref.read(documentProvider.notifier);
                        await controller.goToPage(document.pages.indexOf(page));
                        final object = page.objects
                            .where(
                              (object) =>
                                  object.text.toLowerCase().contains(keyword),
                            )
                            .firstOrNull;
                        if (object != null) controller.select(object);
                        if (context.mounted) Navigator.pop(context);
                      },
                    ),
                ],
              ),
            ),
            if (keyword.isNotEmpty && hits.isEmpty) const Text('没有找到匹配文字'),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
      ],
    );
  }
}
