import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/rust/api.dart' as rust;
import '../documents/document_controller.dart';

class AnnotationsDialog extends ConsumerStatefulWidget {
  const AnnotationsDialog({super.key});
  @override
  ConsumerState<AnnotationsDialog> createState() => _AnnotationsDialogState();
}

class _AnnotationsDialogState extends ConsumerState<AnnotationsDialog> {
  List<dynamic> annotations = [];
  bool busy = true;
  String? error;
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    final state = ref.read(documentProvider);
    try {
      final result =
          jsonDecode(
                await rust.pageAnnotations(
                  documentId: state.document!.id,
                  expectedVersion: BigInt.from(state.document!.version),
                  pageIndex: state.page,
                ),
              )
              as List;
      if (mounted) {
        setState(() {
          annotations = result;
          busy = false;
          error = null;
        });
      }
    } catch (failure) {
      if (mounted) {
        setState(() {
          busy = false;
          error = '$failure';
        });
      }
    }
  }

  Future<void> remove(int index) async {
    setState(() => busy = true);
    final controller = ref.read(documentProvider.notifier);
    await controller.command(
      'object_operation',
      value: jsonEncode({
        'kind': 'delete_annotation',
        'page': ref.read(documentProvider).page,
        'index': index,
      }),
    );
    if (!mounted) return;
    final failure = ref.read(documentProvider).error;
    if (failure != null) {
      setState(() {
        error = failure;
        busy = false;
      });
      return;
    }
    await load();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text('第 ${ref.read(documentProvider).page + 1} 页批注'),
    content: SizedBox(
      width: 480,
      height: 340,
      child: busy
          ? const Center(child: CircularProgressIndicator())
          : error != null
          ? SelectableText(error!)
          : annotations.isEmpty
          ? const Center(child: Text('当前页没有批注。'))
          : ListView(
              children: [
                for (final item in annotations)
                  ListTile(
                    leading: const Icon(Icons.comment_outlined),
                    title: Text(
                      const {
                            'Highlight': '高亮',
                            'Underline': '下划线',
                            'Text': '注释',
                            'Ink': '手绘批注',
                            'Stamp': '印章',
                          }[item['kind']] ??
                          item['kind'] as String,
                    ),
                    subtitle: (item['text'] as String).isEmpty
                        ? null
                        : SelectableText(item['text'] as String),
                    trailing: item['removable'] == true
                        ? IconButton(
                            tooltip: '删除批注（可撤销）',
                            onPressed: () => remove(item['index'] as int),
                            icon: const Icon(Icons.delete_outline),
                          )
                        : const Icon(Icons.lock_outline, size: 16),
                  ),
              ],
            ),
    ),
    actions: [
      TextButton(
        onPressed: busy ? null : () => Navigator.pop(context),
        child: const Text('关闭'),
      ),
    ],
  );
}
