import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/document.dart';
import '../../shared/editor_theme.dart';
import '../documents/document_controller.dart';
import 'document_tools.dart';

class _HomeData {
  _HomeData(this.documents, Map<String, dynamic> catalog)
    : projects = List<Map<String, dynamic>>.from(
        (catalog['projects'] as List).map(
          (p) => Map<String, dynamic>.from(p as Map),
        ),
      ),
      memberships = Map<String, dynamic>.from(catalog['memberships'] as Map);
  final List<DocumentInfo> documents;
  final List<Map<String, dynamic>> projects;
  final Map<String, dynamic> memberships;
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
    return _HomeData(documents, await controller.projects());
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
      padding: const EdgeInsets.all(28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '项目与 PDF',
            style: TextStyle(fontSize: 24, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          const Text(
            '用项目归组多份文档，也可以直接管理独立 PDF。',
            style: TextStyle(color: EditorColors.secondary),
          ),
          const SizedBox(height: 20),
          Wrap(
            spacing: 12,
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
              TextButton.icon(
                onPressed: disabled
                    ? null
                    : () => setState(() => history = load()),
                icon: const Icon(Icons.refresh),
                label: const Text('刷新'),
              ),
            ],
          ),
          const SizedBox(height: 20),
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
          const SizedBox(height: 16),
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
                final projects = data.projects
                    .where(
                      (p) =>
                          (p['name'] as String).toLowerCase().contains(query) ||
                          data.documents.any(
                            (d) =>
                                data.memberships[d.id] == p['id'] &&
                                d.name.toLowerCase().contains(query),
                          ),
                    )
                    .toList();
                final documents = data.documents
                    .where(
                      (d) =>
                          (project == null
                              ? data.memberships[d.id] == null
                              : data.memberships[d.id] == project['id']) &&
                          d.name.toLowerCase().contains(query),
                    )
                    .toList();
                return CustomScrollView(
                  slivers: [
                    if (project == null) ...[
                      const SliverToBoxAdapter(
                        child: Padding(
                          padding: EdgeInsets.only(bottom: 12),
                          child: Text(
                            '项目',
                            style: TextStyle(
                              fontWeight: FontWeight.w600,
                              fontSize: 15,
                            ),
                          ),
                        ),
                      ),
                      if (projects.isEmpty)
                        const SliverToBoxAdapter(
                          child: Padding(
                            padding: EdgeInsets.symmetric(vertical: 20),
                            child: Text(
                              '还没有项目，点击“新建项目”创建。',
                              style: TextStyle(color: EditorColors.muted),
                            ),
                          ),
                        )
                      else
                        SliverGrid(
                          gridDelegate:
                              const SliverGridDelegateWithMaxCrossAxisExtent(
                                maxCrossAxisExtent: 340,
                                mainAxisExtent: 132,
                                crossAxisSpacing: 12,
                                mainAxisSpacing: 12,
                              ),
                          delegate: SliverChildBuilderDelegate((
                            context,
                            index,
                          ) {
                            final p = projects[index];
                            final count = data.documents
                                .where((d) => data.memberships[d.id] == p['id'])
                                .length;
                            return Material(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(12),
                              child: InkWell(
                                borderRadius: BorderRadius.circular(12),
                                onTap: disabled
                                    ? null
                                    : () => setState(
                                        () => activeProject = p['id'] as String,
                                      ),
                                child: Padding(
                                  padding: const EdgeInsets.all(16),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        children: [
                                          const Icon(
                                            Icons.folder_outlined,
                                            size: 22,
                                          ),
                                          const Spacer(),
                                          PopupMenuButton<String>(
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
                                        ],
                                      ),
                                      Text(
                                        p['name'] as String,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          fontWeight: FontWeight.w500,
                                        ),
                                      ),
                                      Text(
                                        '$count 份 PDF',
                                        style: const TextStyle(
                                          color: EditorColors.muted,
                                          fontSize: 11,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            );
                          }, childCount: projects.length),
                        ),
                      const SliverToBoxAdapter(
                        child: Padding(
                          padding: EdgeInsets.only(top: 24, bottom: 12),
                          child: Text(
                            '独立 PDF',
                            style: TextStyle(
                              fontWeight: FontWeight.w600,
                              fontSize: 15,
                            ),
                          ),
                        ),
                      ),
                    ] else
                      SliverToBoxAdapter(
                        child: Padding(
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
                      ),
                    if (documents.isEmpty)
                      SliverToBoxAdapter(
                        child: Padding(
                          padding: const EdgeInsets.all(20),
                          child: Text(
                            project == null
                                ? '独立打开的 PDF 会显示在这里。'
                                : '项目中还没有 PDF。可以添加文件，或把独立 PDF 移入项目。',
                            style: const TextStyle(color: EditorColors.muted),
                          ),
                        ),
                      )
                    else
                      SliverList(
                        delegate: SliverChildBuilderDelegate((context, index) {
                          final document = documents[index];
                          return Padding(
                            padding: const EdgeInsets.only(bottom: 10),
                            child: Material(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(12),
                              child: ListTile(
                                key: ValueKey('home-document-${document.id}'),
                                contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 20,
                                  vertical: 8,
                                ),
                                leading: const Icon(
                                  Icons.picture_as_pdf_outlined,
                                ),
                                title: Text(
                                  document.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                subtitle: Text(
                                  '${document.pages.length} 页 · 版本 ${document.version} · ${document.dirty ? '有未保存修改' : '已保存'}',
                                  style: const TextStyle(fontSize: 12),
                                ),
                                trailing: PopupMenuButton<String>(
                                  tooltip: '归组 PDF',
                                  enabled: !disabled,
                                  onSelected: (project) => change('assign', {
                                    'document_id': document.id,
                                    'project_id': project == 'standalone'
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
                                onTap: disabled
                                    ? null
                                    : () async {
                                        await ref
                                            .read(documentProvider.notifier)
                                            .restore(document.id);
                                        if (mounted &&
                                            ref.read(documentProvider).error ==
                                                null) {
                                          widget.onEnter();
                                        }
                                      },
                              ),
                            ),
                          );
                        }, childCount: documents.length),
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
