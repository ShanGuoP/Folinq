import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/document.dart';
import '../../shared/editor_theme.dart';
import '../documents/document_controller.dart';
import 'document_tools.dart';

String _sourceKey(DocumentInfo document) => document.source
    .replaceAll('\\', '/')
    .replaceFirst(RegExp(r'^//\?/'), '')
    .toLowerCase();

class _HomeData {
  _HomeData(List<DocumentInfo> all, Map<String, dynamic> catalog) {
    projects = List<Map<String, dynamic>>.from(
      (catalog['projects'] as List).map(
        (p) => Map<String, dynamic>.from(p as Map),
      ),
    );
    final membershipsById = Map<String, dynamic>.from(
      catalog['memberships'] as Map,
    );
    final bySource = <String, DocumentInfo>{};
    final groups = <String, dynamic>{};
    for (final document in all) {
      final key = _sourceKey(document);
      bySource.putIfAbsent(key, () => document);
      if (membershipsById[document.id] != null) {
        groups.putIfAbsent(key, () => membershipsById[document.id]);
      }
    }
    documents = bySource.values.toList();
    memberships = {for (final d in documents) d.id: groups[_sourceKey(d)]};
  }
  late final List<DocumentInfo> documents;
  late final List<Map<String, dynamic>> projects;
  late final Map<String, dynamic> memberships;
}

class ProjectHome extends ConsumerStatefulWidget {
  const ProjectHome({super.key, required this.onOpen, required this.onEnter});
  final VoidCallback? onOpen;
  final VoidCallback onEnter;
  @override
  ConsumerState<ProjectHome> createState() => _ProjectHomeState();
}

class _ProjectHomeState extends ConsumerState<ProjectHome> {
  late Future<_HomeData> history = load();
  String query = '';
  String? activeProject, error;
  bool busy = false;
  Future<_HomeData> load() async {
    final controller = ref.read(documentProvider.notifier);
    final documents = await controller.recoverable();
    final current = ref.read(documentProvider).document;
    return _HomeData([
      if (current != null && documents.any((d) => d.id == current.id)) current,
      ...documents,
    ], await controller.projects());
  }

  Future<void> change(String command, Map<String, dynamic> value) async {
    setState(() => busy = true);
    try {
      await ref
          .read(documentProvider.notifier)
          .projects(command: command, value: value);
      if (mounted) {
        setState(() {
          history = load();
          error = null;
        });
      }
    } catch (failure) {
      if (mounted) setState(() => error = '$failure');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> nameProject([Map<String, dynamic>? project]) async {
    var input = project?['name'] as String? ?? '';
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(project == null ? '新建项目' : '重命名项目'),
        content: TextFormField(
          key: const ValueKey('project-name'),
          initialValue: input,
          onChanged: (value) => input = value,
          autofocus: true,
          maxLength: 80,
          decoration: const InputDecoration(labelText: '项目名称'),
          onFieldSubmitted: (value) {
            if (value.trim().isNotEmpty) Navigator.pop(context, value.trim());
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              if (input.trim().isNotEmpty) Navigator.pop(context, input.trim());
            },
            child: const Text('确定'),
          ),
        ],
      ),
    );
    if (name != null && mounted) {
      await change(project == null ? 'create' : 'rename', {
        'name': name,
        if (project != null) 'id': project['id'],
      });
    }
  }

  Future<void> deleteProject(Map<String, dynamic> project) async {
    final remove = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('删除项目“${project['name']}”？'),
        content: const Text('只删除分组。项目中的 PDF 会回到独立 PDF，文件和编辑历史保留。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除分组'),
          ),
        ],
      ),
    );
    if (remove == true && mounted) {
      await change('delete', {'id': project['id']});
      if (mounted && activeProject == project['id']) {
        setState(() => activeProject = null);
      }
    }
  }

  Future<void> addPdf() async {
    final project = activeProject;
    if (project == null) return;
    final controller = ref.read(documentProvider.notifier);
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['pdf'],
    );
    final path = result?.files.single.path;
    if (path != null) await controller.openIntoProject(path, project);
  }

  @override
  Widget build(BuildContext context) {
    final disabled = busy || ref.watch(documentProvider).busy;
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  '最近的文档',
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600),
                ),
              ),
              IconButton(
                tooltip: '刷新',
                onPressed: disabled
                    ? null
                    : () => setState(() => history = load()),
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 10,
            runSpacing: 8,
            children: [
              FilledButton.icon(
                onPressed: disabled ? null : () => nameProject(),
                icon: const Icon(Icons.create_new_folder_outlined),
                label: const Text('新建项目'),
              ),
              OutlinedButton.icon(
                onPressed: disabled ? null : widget.onOpen,
                icon: const Icon(Icons.folder_open_outlined),
                label: const Text('打开独立 PDF'),
              ),
              const NewDocumentButton(),
              const ImportDocumentButton(),
            ],
          ),
          const SizedBox(height: 18),
          TextField(
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search),
              hintText: '搜索项目或 PDF 名称',
            ),
            onChanged: (value) => setState(() => query = value.toLowerCase()),
          ),
          if (error != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: SelectableText(error!),
            ),
          const SizedBox(height: 20),
          Expanded(
            child: FutureBuilder<_HomeData>(
              future: history,
              builder: (context, snapshot) {
                if (snapshot.connectionState != ConnectionState.done) {
                  return const Center(child: Text('正在读取本机项目…'));
                }
                if (snapshot.hasError) {
                  return const Center(child: Text('暂时无法读取项目。可以打开 PDF 或刷新重试。'));
                }
                final data = snapshot.data!;
                final project = data.projects
                    .where((p) => p['id'] == activeProject)
                    .firstOrNull;
                final projects = project == null
                    ? data.projects
                          .where(
                            (p) =>
                                (p['name'] as String).toLowerCase().contains(
                                  query,
                                ) ||
                                data.documents.any(
                                  (d) =>
                                      data.memberships[d.id] == p['id'] &&
                                      d.name.toLowerCase().contains(query),
                                ),
                          )
                          .toList()
                    : <Map<String, dynamic>>[];
                final documents = data.documents
                    .where(
                      (d) =>
                          (project == null
                              ? data.memberships[d.id] == null
                              : data.memberships[d.id] == project['id']) &&
                          d.name.toLowerCase().contains(query),
                    )
                    .toList();
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (project != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: Row(
                          children: [
                            TextButton.icon(
                              onPressed: () =>
                                  setState(() => activeProject = null),
                              icon: const Icon(Icons.arrow_back, size: 16),
                              label: const Text('全部项目'),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                project['name'] as String,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                            TextButton.icon(
                              onPressed: disabled ? null : addPdf,
                              icon: const Icon(Icons.add, size: 16),
                              label: const Text('添加 PDF 到项目'),
                            ),
                          ],
                        ),
                      ),
                    Expanded(
                      child: projects.isEmpty && documents.isEmpty
                          ? Center(
                              child: Text(
                                project == null
                                    ? '打开 PDF 或新建项目，开始整理文档。'
                                    : '项目中还没有 PDF。可以添加文件，或把独立 PDF 移入项目。',
                                style: const TextStyle(
                                  color: EditorColors.muted,
                                ),
                              ),
                            )
                          : LayoutBuilder(
                              builder: (context, constraints) {
                                final columns = (constraints.maxWidth / 190)
                                    .floor()
                                    .clamp(1, 12);
                                return GridView.builder(
                                  gridDelegate:
                                      SliverGridDelegateWithFixedCrossAxisCount(
                                        crossAxisCount: columns,
                                        mainAxisExtent: 252,
                                        crossAxisSpacing: 18,
                                        mainAxisSpacing: 20,
                                      ),
                                  itemCount: projects.length + documents.length,
                                  itemBuilder: (context, index) {
                                    if (index < projects.length) {
                                      final p = projects[index];
                                      final members = data.documents
                                          .where(
                                            (d) =>
                                                data.memberships[d.id] ==
                                                p['id'],
                                          )
                                          .toList();
                                      return _LibraryCard(
                                        title: p['name'] as String,
                                        subtitle: '${members.length} 份 PDF',
                                        onTap: disabled
                                            ? null
                                            : () => setState(
                                                () => activeProject =
                                                    p['id'] as String,
                                              ),
                                        cover: Padding(
                                          padding: const EdgeInsets.all(12),
                                          child: Column(
                                            children: [
                                              for (
                                                var row = 0;
                                                row < 2;
                                                row++
                                              ) ...[
                                                if (row > 0)
                                                  const SizedBox(height: 8),
                                                Expanded(
                                                  child: Row(
                                                    crossAxisAlignment:
                                                        CrossAxisAlignment
                                                            .stretch,
                                                    children: [
                                                      for (
                                                        var col = 0;
                                                        col < 2;
                                                        col++
                                                      ) ...[
                                                        if (col > 0)
                                                          const SizedBox(
                                                            width: 8,
                                                          ),
                                                        Expanded(
                                                          child:
                                                              row * 2 + col <
                                                                  members.length
                                                              ? _DocumentCover(
                                                                  key: ValueKey(
                                                                    'cover-${members[row * 2 + col].id}-${members[row * 2 + col].version}',
                                                                  ),
                                                                  document:
                                                                      members[row *
                                                                              2 +
                                                                          col],
                                                                )
                                                              : Container(
                                                                  decoration: BoxDecoration(
                                                                    color: const Color(
                                                                      0xffe9e9ee,
                                                                    ),
                                                                    borderRadius:
                                                                        BorderRadius.circular(
                                                                          4,
                                                                        ),
                                                                  ),
                                                                  child: const Icon(
                                                                    Icons
                                                                        .description_outlined,
                                                                    color: Color(
                                                                      0xffcdced5,
                                                                    ),
                                                                    size: 24,
                                                                  ),
                                                                ),
                                                        ),
                                                      ],
                                                    ],
                                                  ),
                                                ),
                                              ],
                                            ],
                                          ),
                                        ),
                                        menu: PopupMenuButton<String>(
                                          tooltip: '项目操作',
                                          enabled: !disabled,
                                          onSelected: (action) =>
                                              action == 'rename'
                                              ? nameProject(p)
                                              : deleteProject(p),
                                          itemBuilder: (_) => const [
                                            PopupMenuItem(
                                              value: 'rename',
                                              child: Text('重命名'),
                                            ),
                                            PopupMenuItem(
                                              value: 'delete',
                                              child: Text('删除分组'),
                                            ),
                                          ],
                                        ),
                                      );
                                    }
                                    final document =
                                        documents[index - projects.length];
                                    return _LibraryCard(
                                      key: ValueKey(
                                        'home-document-${document.id}',
                                      ),
                                      title: document.name,
                                      subtitle:
                                          '${document.pages.length} 页${document.dirty ? ' · 有未保存修改' : ''}',
                                      cover: Padding(
                                        padding: const EdgeInsets.all(14),
                                        child: _DocumentCover(
                                          key: ValueKey(
                                            'cover-${document.id}-${document.version}',
                                          ),
                                          document: document,
                                        ),
                                      ),
                                      onTap: disabled
                                          ? null
                                          : () async {
                                              await ref
                                                  .read(
                                                    documentProvider.notifier,
                                                  )
                                                  .restore(document.id);
                                              if (mounted &&
                                                  ref
                                                          .read(
                                                            documentProvider,
                                                          )
                                                          .error ==
                                                      null) {
                                                widget.onEnter();
                                              }
                                            },
                                      menu: PopupMenuButton<String>(
                                        tooltip: '归组 PDF',
                                        enabled: !disabled,
                                        onSelected: (project) =>
                                            change('assign', {
                                              'document_id': document.id,
                                              'project_id':
                                                  project == 'standalone'
                                                  ? null
                                                  : project,
                                            }),
                                        itemBuilder: (_) => [
                                          const PopupMenuItem(
                                            value: 'standalone',
                                            child: Text('移为独立 PDF'),
                                          ),
                                          for (final p in data.projects)
                                            PopupMenuItem(
                                              value: p['id'] as String,
                                              child: Text('移入 ${p['name']}'),
                                            ),
                                        ],
                                      ),
                                    );
                                  },
                                );
                              },
                            ),
                    ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _LibraryCard extends StatelessWidget {
  const _LibraryCard({
    super.key,
    required this.title,
    required this.subtitle,
    required this.cover,
    required this.menu,
    this.onTap,
  });
  final String title, subtitle;
  final Widget cover, menu;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) => Material(
    color: Colors.transparent,
    borderRadius: BorderRadius.circular(10),
    child: InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Container(
              width: double.infinity,
              decoration: BoxDecoration(
                color: const Color(0xfff8f8fa),
                border: Border.all(color: const Color(0xffe2e3e9)),
                borderRadius: BorderRadius.circular(8),
              ),
              child: cover,
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(left: 4),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Tooltip(
                        message: title,
                        child: Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w500),
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 11,
                          color: EditorColors.muted,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              SizedBox(width: 32, height: 44, child: menu),
            ],
          ),
        ],
      ),
    ),
  );
}

class _DocumentCover extends ConsumerStatefulWidget {
  const _DocumentCover({super.key, required this.document});
  final DocumentInfo document;
  @override
  ConsumerState<_DocumentCover> createState() => _DocumentCoverState();
}

class _DocumentCoverState extends ConsumerState<_DocumentCover> {
  late final Future<String> path = ref
      .read(documentProvider.notifier)
      .documentCover(widget.document.id, widget.document.version);
  @override
  Widget build(BuildContext context) => FutureBuilder<String>(
    future: path,
    builder: (context, snapshot) => snapshot.hasData
        ? Image.file(
            File(snapshot.data!),
            fit: BoxFit.contain,
            errorBuilder: (_, error, stack) => const Icon(
              Icons.picture_as_pdf_outlined,
              color: EditorColors.muted,
            ),
          )
        : const Center(
            child: Icon(
              Icons.description_outlined,
              color: EditorColors.muted,
              size: 32,
            ),
          ),
  );
}
