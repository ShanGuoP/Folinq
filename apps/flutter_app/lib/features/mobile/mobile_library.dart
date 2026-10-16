import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/document.dart';
import '../../shared/editor_theme.dart';
import '../documents/document_controller.dart';

class MobileLibrary extends ConsumerStatefulWidget {
  const MobileLibrary({
    super.key,
    required this.onOpen,
    required this.onRestore,
  });
  final VoidCallback? onOpen;
  final Future<void> Function(String) onRestore;
  @override
  ConsumerState<MobileLibrary> createState() => _MobileLibraryState();
}

class _MobileLibraryState extends ConsumerState<MobileLibrary> {
  late Future<List<DocumentInfo>> records = load();
  String query = '';
  Future<List<DocumentInfo>> load() =>
      ref.read(documentProvider.notifier).recoverable();
  @override
  Widget build(BuildContext context) => Column(
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
        child: TextField(
          decoration: const InputDecoration(
            prefixIcon: Icon(Icons.search),
            hintText: '搜索本机文档',
          ),
          onChanged: (value) => setState(() => query = value.toLowerCase()),
        ),
      ),
      Expanded(
        child: FutureBuilder<List<DocumentInfo>>(
          future: records,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const Center(child: CircularProgressIndicator());
            }
            if (snapshot.hasError) {
              return Center(
                child: TextButton.icon(
                  onPressed: () => setState(() => records = load()),
                  icon: const Icon(Icons.refresh),
                  label: const Text('读取记录失败，点击重试'),
                ),
              );
            }
            final documents = snapshot.data!
                .where((d) => d.name.toLowerCase().contains(query))
                .toList();
            if (documents.isEmpty) {
              return Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.description_outlined,
                        size: 48,
                        color: EditorColors.muted,
                      ),
                      const SizedBox(height: 16),
                      Text(query.isEmpty ? '打开一份 PDF，开始阅读与编辑' : '没有找到匹配的文档'),
                      const SizedBox(height: 8),
                      const Text(
                        '文档工作副本与修改记录保存在本机。',
                        style: TextStyle(color: EditorColors.secondary),
                      ),
                      const SizedBox(height: 20),
                      FilledButton.icon(
                        onPressed: widget.onOpen,
                        icon: const Icon(Icons.folder_open),
                        label: const Text('打开 PDF'),
                      ),
                    ],
                  ),
                ),
              );
            }
            return RefreshIndicator(
              onRefresh: () async {
                final next = load();
                setState(() => records = next);
                await next;
              },
              child: ListView.separated(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.only(top: 8, bottom: 96),
                itemCount: documents.length,
                separatorBuilder: (_, _) =>
                    const Divider(indent: 72, height: 1),
                itemBuilder: (context, index) {
                  final document = documents[index];
                  return ListTile(
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 8,
                    ),
                    leading: const Icon(
                      Icons.picture_as_pdf_outlined,
                      size: 32,
                    ),
                    title: Text(
                      document.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      '${document.pages.length} 页${document.dirty ? ' · 有工作修改' : ''}',
                    ),
                    trailing: const Icon(Icons.chevron_right),
                    enabled: widget.onOpen != null,
                    onTap: () => widget.onRestore(document.id),
                  );
                },
              ),
            );
          },
        ),
      ),
    ],
  );
}
