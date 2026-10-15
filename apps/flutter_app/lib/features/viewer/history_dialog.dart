import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../documents/document_controller.dart';

class HistoryDialog extends ConsumerStatefulWidget {
  const HistoryDialog({super.key});
  @override
  ConsumerState<HistoryDialog> createState() => _HistoryDialogState();
}

class _HistoryDialogState extends ConsumerState<HistoryDialog> {
  late final Future<List<Map<String, dynamic>>> history = ref
      .read(documentProvider.notifier)
      .historyVersions();
  bool restoring = false;
  String? error;
  Future<void> restore(Map<String, dynamic> version) async {
    setState(() {
      restoring = true;
      error = null;
    });
    final controller = ref.read(documentProvider.notifier);
    final documentId = ref.read(documentProvider).document?.id;
    try {
      if (!await controller.applyPendingDrafts()) {
        throw StateError('当前修改提交失败，请先处理后再恢复。');
      }
      if (ref.read(documentProvider).document?.id != documentId) {
        throw StateError('当前文档已切换，请重新打开历史版本。');
      }
      await controller.command(
        'restore_version',
        value: jsonEncode({
          'session_id': version['session_id'],
          'version': version['version'],
        }),
      );
      final failure = ref.read(documentProvider).error;
      if (failure != null) throw StateError(failure);
      if (!mounted) return;
      final messenger = ScaffoldMessenger.of(context);
      Navigator.pop(context);
      messenger.showSnackBar(
        const SnackBar(content: Text('已恢复历史版本，按 Ctrl+S 保存到源文件')),
      );
    } catch (failure) {
      if (mounted) setState(() => error = '$failure');
    } finally {
      if (mounted) setState(() => restoring = false);
    }
  }

  String timeLabel(int milliseconds) {
    final time = DateTime.fromMillisecondsSinceEpoch(milliseconds).toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${time.year}-${two(time.month)}-${two(time.day)} ${two(time.hour)}:${two(time.minute)}:${two(time.second)}';
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !restoring,
    child: AlertDialog(
      title: const Text('历史版本'),
      content: SizedBox(
        width: 560,
        height: 440,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '恢复后生成新的工作版本，可撤销。按 Ctrl+S 才会保存到源 PDF。',
              style: TextStyle(fontSize: 12),
            ),
            const SizedBox(height: 12),
            if (restoring) const LinearProgressIndicator(),
            if (error != null) SelectableText(error!),
            Expanded(
              child: FutureBuilder<List<Map<String, dynamic>>>(
                future: history,
                builder: (context, snapshot) {
                  if (snapshot.hasError) {
                    return const Center(child: Text('无法读取历史版本，请关闭后重试。'));
                  }
                  if (!snapshot.hasData) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  final versions = snapshot.data!;
                  if (versions.isEmpty) {
                    return const Center(child: Text('暂无历史版本'));
                  }
                  return ListView.builder(
                    itemCount: versions.length,
                    itemBuilder: (context, index) {
                      final version = versions[index];
                      final current = version['current'] == true;
                      return ListTile(
                        leading: Icon(
                          current ? Icons.radio_button_checked : Icons.history,
                        ),
                        title: Text(
                          '${timeLabel(version['time'] as int)}${current ? ' · 当前版本' : ''}',
                        ),
                        subtitle: Text(
                          '版本 ${version['version']} · ${version['session_id'].toString().substring(0, 8)}',
                        ),
                        trailing: TextButton(
                          onPressed: restoring || current
                              ? null
                              : () => restore(version),
                          child: Text(current ? '当前' : '恢复'),
                        ),
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: restoring ? null : () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
      ],
    ),
  );
}
