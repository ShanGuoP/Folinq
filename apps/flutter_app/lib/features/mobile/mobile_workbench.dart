import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/platform_documents.dart';
import '../../shared/app_brand.dart';
import '../../shared/editor_theme.dart';
import '../documents/document_controller.dart';
import '../viewer/about_dialog.dart';
import '../viewer/workbench.dart' show PropertiesPanel;
import 'mobile_continuous_canvas.dart';
import 'mobile_library.dart';
import 'mobile_export_sheet.dart';

class MobileWorkbench extends ConsumerStatefulWidget {
  const MobileWorkbench({super.key});
  @override
  ConsumerState<MobileWorkbench> createState() => _MobileWorkbenchState();
}

class _MobileWorkbenchState extends ConsumerState<MobileWorkbench> {
  bool home = true, picking = false, editing = false;
  int libraryGeneration = 0;
  late final AppLifecycleListener lifecycle;
  @override
  void initState() {
    super.initState();
    lifecycle = AppLifecycleListener(onPause: persist, onInactive: persist);
  }

  void persist() => unawaited(ref.read(documentProvider.notifier).persistAll());
  @override
  void dispose() {
    lifecycle.dispose();
    super.dispose();
  }

  void notify(String message) {
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    }
  }

  Future<void> open() async {
    if (picking || ref.read(documentProvider).busy) return;
    if (!await ref.read(documentProvider.notifier).persistAll()) return;
    setState(() => picking = true);
    try {
      final path = await PlatformDocuments.openPdf();
      if (path == null || !mounted) return;
      await ref.read(documentProvider.notifier).open(path);
      if (mounted && ref.read(documentProvider).error == null) {
        setState(() {
          home = false;
          editing = false;
        });
      }
    } catch (error) {
      notify('打开失败：${readableError('$error')}');
    } finally {
      if (mounted) setState(() => picking = false);
    }
  }

  Future<void> restore(String id) async {
    await ref.read(documentProvider.notifier).restore(id);
    if (mounted && ref.read(documentProvider).error == null) {
      setState(() {
        home = false;
        editing = false;
      });
    }
  }

  Future<void> back() async {
    if (picking || !await ref.read(documentProvider.notifier).persistAll()) {
      return;
    }
    if (!mounted) return;
    if (!home) {
      setState(() {
        home = true;
        libraryGeneration++;
      });
    } else {
      await SystemNavigator.pop();
    }
  }

  Future<void> save() async {
    final controller = ref.read(documentProvider.notifier);
    if (!await controller.applyPendingDrafts()) return;
    if (await controller.exportAndroid('pdf', [], markSaved: true)) {
      notify('PDF 已写入所选位置，工作记录已保存。');
    }
  }

  Future<void> properties() async {
    if (!editing) setState(() => editing = true);
    if (ref.read(documentProvider).selected == null) {
      notify('请点击页面中的文字或图片，再选择“修改选中内容”。');
      return;
    }
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (context) => Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: SizedBox(
          height: MediaQuery.sizeOf(context).height * .72,
          child: Consumer(
            builder: (context, ref, _) {
              final state = ref.watch(documentProvider);
              return Column(
                children: [
                  if (state.error != null)
                    Padding(
                      padding: const EdgeInsets.all(12),
                      child: Text(state.error!),
                    ),
                  Expanded(child: PropertiesPanel(state: state)),
                ],
              );
            },
          ),
        ),
      ),
    );
    if (mounted) await ref.read(documentProvider.notifier).persistView();
  }

  Future<void> pages() => showModalBottomSheet<void>(
    context: context,
    useSafeArea: true,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (context) => SizedBox(
      height: MediaQuery.sizeOf(context).height * .65,
      child: Consumer(
        builder: (context, ref, _) {
          final state = ref.watch(documentProvider);
          final controller = ref.read(documentProvider.notifier);
          final document = state.document!;
          Future<void> operate(Map<String, dynamic> operation) async {
            Navigator.pop(context);
            if (!await controller.applyPendingDrafts()) return;
            await controller.command(
              'page_operation',
              value: jsonEncode(operation),
            );
          }

          return Column(
            children: [
              const Text(
                '页面管理',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                children: [
                  TextButton.icon(
                    onPressed: state.busy
                        ? null
                        : () => operate({
                            'kind': 'rotate',
                            'page': state.page,
                            'clockwise': true,
                          }),
                    icon: const Icon(Icons.rotate_right),
                    label: const Text('旋转当前页'),
                  ),
                  TextButton.icon(
                    onPressed: state.busy
                        ? null
                        : () =>
                              operate({'kind': 'insert', 'at': state.page + 1}),
                    icon: const Icon(Icons.note_add_outlined),
                    label: const Text('插入空白页'),
                  ),
                ],
              ),
              Expanded(
                child: ListView.builder(
                  itemCount: document.pages.length,
                  itemBuilder: (context, index) => ListTile(
                    title: Text('第 ${index + 1} 页'),
                    selected: index == state.page,
                    leading: const Icon(Icons.description_outlined),
                    trailing: index == state.page
                        ? const Icon(Icons.check)
                        : null,
                    onTap: state.busy
                        ? null
                        : () async {
                            Navigator.pop(context);
                            await controller.goToPage(index);
                          },
                  ),
                ),
              ),
            ],
          );
        },
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(documentProvider);
    final controller = ref.read(documentProvider.notifier);
    final document = home ? null : state.document;
    final busy = state.busy || picking;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(back());
      },
      child: Scaffold(
        appBar: AppBar(
          backgroundColor: EditorColors.shell,
          surfaceTintColor: Colors.transparent,
          leading: document == null
              ? null
              : IconButton(
                  tooltip: '返回文档',
                  onPressed: busy ? null : back,
                  icon: const Icon(Icons.arrow_back),
                ),
          title: document == null
              ? TextButton(
                  onPressed: () => showFolinqAbout(context),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      AppIcon(size: 36),
                      SizedBox(width: 8),
                      Text(AppBrand.name),
                    ],
                  ),
                )
              : Text(
                  document.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 16),
                ),
          actions: [
            if (document != null)
              IconButton(
                tooltip: '另存 PDF',
                onPressed: busy ? null : save,
                icon: const Icon(Icons.save_outlined),
              ),
            PopupMenuButton<String>(
              tooltip: '更多',
              onSelected: (value) {
                if (value == 'about') showFolinqAbout(context);
                if (value == 'open') open();
                if (value == 'redo') controller.command('redo');
              },
              itemBuilder: (_) => [
                PopupMenuItem(
                  value: 'open',
                  enabled: !busy,
                  child: const Text('打开 PDF'),
                ),
                if (document != null)
                  PopupMenuItem(
                    value: 'redo',
                    enabled: !busy && document.canRedo,
                    child: const Text('重做'),
                  ),
                const PopupMenuItem(
                  value: 'about',
                  child: Text('关于 ${AppBrand.name}'),
                ),
              ],
            ),
          ],
        ),
        body: SafeArea(
          top: false,
          child: Column(
            children: [
              if (busy) const LinearProgressIndicator(minHeight: 2),
              if (state.error != null)
                Container(
                  color: EditorColors.surface,
                  padding: const EdgeInsets.all(12),
                  width: double.infinity,
                  child: Text(
                    state.error!,
                    maxLines: 4,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              Expanded(
                child: document == null
                    ? MobileLibrary(
                        key: ValueKey(libraryGeneration),
                        onOpen: busy ? null : open,
                        onRestore: restore,
                      )
                    : Column(
                        children: [
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            child: Row(
                              children: [
                                IconButton(
                                  tooltip: '上一页',
                                  onPressed: busy || state.page == 0
                                      ? null
                                      : () =>
                                            controller.goToPage(state.page - 1),
                                  icon: const Icon(Icons.chevron_left),
                                ),
                                Expanded(
                                  child: TextButton(
                                    onPressed: busy ? null : pages,
                                    child: Text(
                                      '${state.page + 1} / ${document.pages.length} 页',
                                    ),
                                  ),
                                ),
                                IconButton(
                                  tooltip: '下一页',
                                  onPressed:
                                      busy ||
                                          state.page ==
                                              document.pages.length - 1
                                      ? null
                                      : () =>
                                            controller.goToPage(state.page + 1),
                                  icon: const Icon(Icons.chevron_right),
                                ),
                                IconButton(
                                  tooltip: '撤销',
                                  onPressed: busy || !document.canUndo
                                      ? null
                                      : () => controller.command('undo'),
                                  icon: const Icon(Icons.undo),
                                ),
                              ],
                            ),
                          ),
                          if (editing)
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                              ),
                              child: Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      state.selected == null
                                          ? '点击文字或图片进行选择'
                                          : '已选择${state.selected!.kind == 'image' ? '图片' : '文字'}',
                                      style: const TextStyle(fontSize: 12),
                                    ),
                                  ),
                                  TextButton(
                                    onPressed: busy ? null : properties,
                                    child: const Text('修改选中内容'),
                                  ),
                                ],
                              ),
                            ),
                          Expanded(
                            child: MobileContinuousCanvas(
                              key: ValueKey(document.id),
                              state: state,
                              editing: editing,
                            ),
                          ),
                        ],
                      ),
              ),
            ],
          ),
        ),
        floatingActionButton: document == null
            ? FloatingActionButton.extended(
                onPressed: busy ? null : open,
                icon: const Icon(Icons.add),
                label: const Text('打开 PDF'),
              )
            : null,
        bottomNavigationBar: document == null
            ? null
            : NavigationBar(
                selectedIndex: editing ? 1 : 0,
                onDestinationSelected: busy
                    ? null
                    : (index) {
                        if (index < 2) setState(() => editing = index == 1);
                        if (index == 2) pages();
                        if (index == 3) {
                          showModalBottomSheet<void>(
                            context: context,
                            useSafeArea: true,
                            isScrollControlled: true,
                            showDragHandle: true,
                            isDismissible: false,
                            enableDrag: false,
                            builder: (_) => const MobileExportSheet(),
                          );
                        }
                      },
                destinations: const [
                  NavigationDestination(
                    icon: Icon(Icons.menu_book_outlined),
                    label: '阅读',
                  ),
                  NavigationDestination(
                    icon: Icon(Icons.edit_outlined),
                    label: '编辑',
                  ),
                  NavigationDestination(
                    icon: Icon(Icons.layers_outlined),
                    label: '页面',
                  ),
                  NavigationDestination(
                    icon: Icon(Icons.ios_share),
                    label: '导出',
                  ),
                ],
              ),
      ),
    );
  }
}
