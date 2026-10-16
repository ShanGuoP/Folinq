import 'workbench_header.dart';
import 'pdf_drop_region.dart';
import 'history_dialog.dart';
import 'dart:io';
import 'dart:convert';
import 'dart:ui' show AppExitResponse;
import 'dart:math' as math;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/font_assets.dart';
import '../../core/export_locations.dart';
import '../../core/rust/api.dart' as rust;
import '../../shared/editor_theme.dart';
import '../documents/document_controller.dart';
import 'document_tools.dart';
import 'page_thumbnail.dart';
import 'editable_page.dart';
import 'continuous_canvas.dart';
import 'project_home.dart';

class Workbench extends ConsumerStatefulWidget {
  const Workbench({super.key, this.startupPaths = const []});
  final List<String> startupPaths;
  @override
  ConsumerState<Workbench> createState() => _WorkbenchState();
}

class _WorkbenchState extends ConsumerState<Workbench> {
  bool showPages = true, showProperties = true;
  bool showHome = false;
  bool selectingSave = false;
  late final AppLifecycleListener lifecycle;
  @override
  void initState() {
    super.initState();
    lifecycle = AppLifecycleListener(
      onInactive: () => ref.read(documentProvider.notifier).persistView(),
      onPause: () => ref.read(documentProvider.notifier).persistView(),
      onExitRequested: () async {
        if (!mounted) return AppExitResponse.exit;
        final documents = ref.read(openDocumentsProvider);
        final active = ref.read(documentProvider);
        if (!await ref.read(documentProvider.notifier).persistAll()) {
          return AppExitResponse.cancel;
        }
        if (!mounted) return AppExitResponse.exit;
        if (!active.busy &&
            !documents.any((d) => d.dirty) &&
            !documents.any(
              (d) => ref.read(documentProvider.notifier).hasDrafts(d.id),
            ) &&
            active.document?.dirty != true) {
          return AppExitResponse.exit;
        }
        final exit = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('退出 PDF 工作台？'),
            content: const Text('仍有未保存的修改或正在处理的操作。建议取消并另存；已提交的工作版本会保留在本机。'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('继续编辑'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('退出'),
              ),
            ],
          ),
        );
        return exit == true ? AppExitResponse.exit : AppExitResponse.cancel;
      },
    );
  }

  @override
  void dispose() {
    lifecycle.dispose();
    super.dispose();
  }

  Future<void> open() async {
    final state = ref.read(documentProvider);
    if (state.busy) return;
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['pdf'],
    );
    if (!mounted) return;
    if (result?.files.single.path case final String path) {
      await ref.read(documentProvider.notifier).open(path);
      if (mounted && ref.read(documentProvider).error == null) {
        setState(() => showHome = false);
      }
    }
  }

  Future<void> save() async {
    if (selectingSave) return;
    selectingSave = true;
    try {
      await saveAs();
    } catch (failure) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('另存失败：$failure')));
      }
    } finally {
      selectingSave = false;
    }
  }

  Future<void> saveAs() async {
    if (ref.read(documentProvider).busy ||
        ref.read(documentProvider).document == null) {
      return;
    }
    if (!await ref.read(documentProvider.notifier).applyPendingDrafts()) return;
    if (Platform.isAndroid) {
      final saved = await ref
          .read(documentProvider.notifier)
          .exportAndroid('pdf', [], markSaved: true);
      if (mounted && saved) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('PDF 已保存到所选位置')));
      }
      return;
    }
    final document = ref.read(documentProvider).document!;
    final locations = ref.read(exportLocationsProvider);
    final initialDirectory = await locations.initialDirectory(document.source);
    if (!mounted) return;
    final name = document.name.replaceAll(
      RegExp(r'\.pdf$', caseSensitive: false),
      '',
    );
    final suggested = '$name-edited.pdf';
    final destination = await FilePicker.platform.saveFile(
      dialogTitle: '另存为新的 PDF 文件',
      initialDirectory: initialDirectory,
      fileName: initialDirectory == null
          ? suggested
          : File(
              availableExportPath('$initialDirectory/$suggested'),
            ).uri.pathSegments.last,
      type: FileType.custom,
      allowedExtensions: ['pdf'],
    );
    if (!mounted || destination == null) return;
    final output = availableExportPath(withExportExtension(destination, 'pdf'));
    final remembered = await locations.remember(File(output).parent.path);
    if (!mounted || ref.read(documentProvider).document?.id != document.id) {
      return;
    }
    await ref.read(documentProvider.notifier).command('save_as', value: output);
    if (!mounted) return;
    if (ref.read(documentProvider).error == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('已另存为：$output${remembered ? '' : '\n未能保存目录偏好'}'),
          behavior: SnackBarBehavior.floating,
          duration: Duration(seconds: 3),
        ),
      );
    }
  }

  Future<void> saveSource() async {
    final controller = ref.read(documentProvider.notifier);
    if (!await controller.applyPendingDrafts()) return;
    await controller.command('save_source');
    if (mounted && ref.read(documentProvider).error == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('已保存到源 PDF')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(documentProvider);
    ref.listen(documentProvider, (previous, next) {
      if (next.document != null &&
          previous?.document?.id != next.document?.id &&
          showHome) {
        setState(() => showHome = false);
      }
    });
    final document = showHome ? null : state.document;
    final controller = ref.read(documentProvider.notifier);
    final wide = MediaQuery.sizeOf(context).width >= 1000;
    final compact = MediaQuery.sizeOf(context).width < 600;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyO, control: true): open,
        const SingleActivator(LogicalKeyboardKey.keyS, control: true):
            saveSource,
        const SingleActivator(
          LogicalKeyboardKey.keyS,
          control: true,
          shift: true,
        ): save,
        const SingleActivator(LogicalKeyboardKey.escape):
            controller.clearSelection,
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          body: PdfDropRegion(
            startupPaths: widget.startupPaths,
            onOpened: () => setState(() => showHome = false),
            child: SafeArea(
              child: Column(
                children: [
                  WorkbenchHeader(
                    state: state,
                    showingHome: showHome,
                    onNavigate: () => setState(() => showHome = !showHome),
                    onOpen: open,
                    onSave: saveSource,
                    onSaveAs: save,
                    onHistory: () => showDialog<void>(
                      context: context,
                      builder: (_) => const HistoryDialog(),
                    ),
                  ),
                  DocumentTabs(disabled: state.busy),
                  if (document != null) const DocumentToolStrip(),
                  if (state.error != null)
                    MaterialBanner(
                      content: Text(state.error!),
                      actions: [
                        TextButton(
                          onPressed: document == null || state.busy
                              ? null
                              : () => controller.goToPage(state.page),
                          child: const Text('刷新预览'),
                        ),
                      ],
                    ),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(12, 0, 12, 0),
                      child: Row(
                        children: [
                          if (wide && document != null)
                            AnimatedContainer(
                              duration: motionDuration(context, 200),
                              curve: Curves.easeOutCubic,
                              width: showPages ? 184 : 0,
                              clipBehavior: Clip.hardEdge,
                              decoration: const BoxDecoration(),
                              child: OverflowBox(
                                alignment: Alignment.centerLeft,
                                minWidth: 184,
                                maxWidth: 184,
                                child: Padding(
                                  padding: const EdgeInsets.only(right: 12),
                                  child: ExcludeFocus(
                                    excluding: !showPages,
                                    child: ExcludeSemantics(
                                      excluding: !showPages,
                                      child: IgnorePointer(
                                        ignoring: !showPages,
                                        child: _PagePanel(state: state),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          Expanded(
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(14),
                              child: ColoredBox(
                                color: EditorColors.canvas,
                                child: Column(
                                  children: [
                                    if (document != null)
                                      Container(
                                        height: 48,
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 12,
                                        ),
                                        decoration: const BoxDecoration(
                                          border: Border(
                                            bottom: BorderSide(
                                              color: EditorColors.border,
                                            ),
                                          ),
                                        ),
                                        child: Row(
                                          children: [
                                            if (wide)
                                              ToolButton(
                                                icon:
                                                    Icons.view_sidebar_outlined,
                                                label: '切换页面列表',
                                                selected: showPages,
                                                onPressed: () => setState(
                                                  () => showPages = !showPages,
                                                ),
                                              ),
                                            const SizedBox(width: 4),
                                            const Icon(
                                              Icons.text_fields_outlined,
                                              size: 17,
                                            ),
                                            const SizedBox(width: 8),
                                            const Expanded(
                                              child: Text(
                                                '文字编辑',
                                                style: TextStyle(
                                                  fontSize: 12,
                                                  fontWeight: FontWeight.w500,
                                                ),
                                              ),
                                            ),
                                            if (!compact) ...[
                                              const Icon(
                                                Icons.lock_outline,
                                                size: 13,
                                                color: EditorColors.muted,
                                              ),
                                              const SizedBox(width: 5),
                                              const Text(
                                                '保持原版式',
                                                style: TextStyle(
                                                  fontSize: 11,
                                                  color: EditorColors.muted,
                                                ),
                                              ),
                                              const SizedBox(width: 16),
                                            ],
                                            ToolButton(
                                              icon: Icons.undo_rounded,
                                              label: '撤销',
                                              onPressed:
                                                  !state.busy &&
                                                      document.canUndo == true
                                                  ? () => controller.command(
                                                      'undo',
                                                    )
                                                  : null,
                                            ),
                                            ToolButton(
                                              icon: Icons.redo_rounded,
                                              label: '重做',
                                              onPressed:
                                                  !state.busy &&
                                                      document.canRedo == true
                                                  ? () => controller.command(
                                                      'redo',
                                                    )
                                                  : null,
                                            ),
                                            ToolButton(
                                              icon: Icons.tune_rounded,
                                              label: wide ? '切换文字属性' : '文字属性',
                                              selected: wide && showProperties,
                                              onPressed: wide
                                                  ? () => setState(
                                                      () => showProperties =
                                                          !showProperties,
                                                    )
                                                  : () =>
                                                        showModalBottomSheet<
                                                          void
                                                        >(
                                                          context: context,
                                                          isScrollControlled:
                                                              true,
                                                          showDragHandle: true,
                                                          builder: (_) =>
                                                              const _MobileProperties(),
                                                        ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    SizedBox(
                                      height: 2,
                                      child: state.busy
                                          ? const LinearProgressIndicator(
                                              minHeight: 2,
                                              color: EditorColors.secondary,
                                              backgroundColor:
                                                  EditorColors.border,
                                            )
                                          : null,
                                    ),
                                    Expanded(
                                      child: document == null
                                          ? ProjectHome(
                                              onOpen: state.busy ? null : open,
                                              onEnter: () => setState(
                                                () => showHome = false,
                                              ),
                                            )
                                          : document.pages.length > 1
                                          ? ContinuousCanvas(
                                              key: ValueKey(document.id),
                                              state: state,
                                            )
                                          : PageCanvas(
                                              key: ValueKey(document.id),
                                              state: state,
                                            ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                          if (wide && document != null)
                            AnimatedContainer(
                              duration: motionDuration(context, 200),
                              curve: Curves.easeOutCubic,
                              width: showProperties ? 292 : 0,
                              clipBehavior: Clip.hardEdge,
                              decoration: const BoxDecoration(),
                              child: OverflowBox(
                                alignment: Alignment.centerRight,
                                minWidth: 292,
                                maxWidth: 292,
                                child: Padding(
                                  padding: const EdgeInsets.only(left: 12),
                                  child: ExcludeFocus(
                                    excluding: !showProperties,
                                    child: ExcludeSemantics(
                                      excluding: !showProperties,
                                      child: IgnorePointer(
                                        ignoring: !showProperties,
                                        child: PropertiesPanel(state: state),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                  SizedBox(
                    height: 40,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 22),
                      child: Row(
                        children: [
                          Icon(
                            state.busy
                                ? Icons.sync
                                : Icons.check_circle_outline,
                            size: 13,
                            color: state.busy
                                ? EditorColors.warning
                                : EditorColors.success,
                          ),
                          const SizedBox(width: 6),
                          AnimatedSwitcher(
                            duration: motionDuration(context),
                            child: Text(
                              state.busy
                                  ? '正在处理'
                                  : document?.dirty == true
                                  ? '修改待保存'
                                  : '本地处理 · 工作历史保留',
                              key: ValueKey('${state.busy}-${document?.dirty}'),
                              style: const TextStyle(
                                fontSize: 11,
                                color: EditorColors.muted,
                              ),
                            ),
                          ),
                          const Spacer(),
                          if (document != null) ...[
                            ToolButton(
                              icon: Icons.chevron_left,
                              label: '上一页',
                              onPressed: state.busy || state.page == 0
                                  ? null
                                  : () => controller.goToPage(state.page - 1),
                            ),
                            Text(
                              '${state.page + 1} / ${document.pages.length}',
                              style: const TextStyle(fontSize: 11),
                            ),
                            ToolButton(
                              icon: Icons.chevron_right,
                              label: '下一页',
                              onPressed:
                                  state.busy ||
                                      state.page + 1 == document.pages.length
                                  ? null
                                  : () => controller.goToPage(state.page + 1),
                            ),
                            if (!compact) ...[
                              const SizedBox(width: 12),
                              Text(
                                '版本 ${document.version}',
                                style: const TextStyle(
                                  fontSize: 11,
                                  color: EditorColors.muted,
                                ),
                              ),
                            ],
                          ],
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _PagePanel extends ConsumerWidget {
  const _PagePanel({required this.state});
  final DocumentState state;
  @override
  Widget build(BuildContext context, WidgetRef ref) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Padding(
        padding: EdgeInsets.fromLTRB(12, 16, 12, 16),
        child: Text(
          '文档页面',
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: EditorColors.secondary,
          ),
        ),
      ),
      Expanded(
        child: ListView.separated(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          itemCount: state.document!.pages.length,
          separatorBuilder: (_, _) => const SizedBox(height: 8),
          itemBuilder: (context, index) => MotionFeedback(
            enabled: !state.busy,
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                borderRadius: BorderRadius.circular(10),
                onTap: state.busy
                    ? null
                    : () => ref.read(documentProvider.notifier).goToPage(index),
                child: AnimatedContainer(
                  duration: motionDuration(context),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: index == state.page
                        ? EditorColors.surface
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: index == state.page
                          ? EditorColors.border
                          : Colors.transparent,
                    ),
                  ),
                  child: Row(
                    children: [
                      PageThumbnail(
                        documentId: state.document!.id,
                        version: state.document!.version,
                        page: index,
                        preview: index == state.page ? state.preview : null,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '第 ${index + 1} 页',
                              style: const TextStyle(fontSize: 12),
                            ),
                            Text(
                              '${state.document!.pages[index].objects.length} 个对象',
                              style: const TextStyle(
                                fontSize: 10,
                                color: EditorColors.muted,
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (index == state.page)
                        const Icon(
                          Icons.circle,
                          size: 5,
                          color: EditorColors.text,
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ],
  );
}

class _MobileProperties extends ConsumerWidget {
  const _MobileProperties();
  @override
  Widget build(BuildContext context, WidgetRef ref) => Padding(
    padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
    child: SizedBox(
      height: MediaQuery.sizeOf(context).height * .55,
      child: PropertiesPanel(state: ref.watch(documentProvider)),
    ),
  );
}

class PageCanvas extends ConsumerStatefulWidget {
  const PageCanvas({
    super.key,
    required this.state,
    this.allowSelection = true,
    this.allowObjectDrag = true,
    this.maxDetailWidth = 4096,
  });
  final DocumentState state;
  final bool allowSelection, allowObjectDrag;
  final int maxDetailWidth;
  @override
  ConsumerState<PageCanvas> createState() => _PageCanvasState();
}

class _PageCanvasState extends ConsumerState<PageCanvas>
    with SingleTickerProviderStateMixin {
  DocumentState? lastPreview;
  String? detailPreview, detailIdentity;
  int detailGeneration = 0, detailWidth = 1200;
  double fittedWidth = 0;

  Future<void> requestDetail() async {
    final state = widget.state;
    final document = state.document;
    if (document == null || state.busy || state.preview == null) return;
    final desired =
        (fittedWidth *
                transform.value.getMaxScaleOnAxis() *
                MediaQuery.devicePixelRatioOf(context) /
                512)
            .ceil() *
        512;
    final width = desired.clamp(1200, widget.maxDetailWidth);
    if (width <= detailWidth) return;
    final generation = ++detailGeneration;
    final identity = detailIdentity;
    try {
      final path = await rust.renderDetail(
        documentId: document.id,
        expectedVersion: BigInt.from(document.version),
        pageIndex: state.page,
        width: width,
      );
      if (mounted &&
          generation == detailGeneration &&
          identity == detailIdentity) {
        setState(() {
          detailPreview = path;
          detailWidth = width;
        });
      }
    } catch (_) {
      /* The current page preview remains valid if detail rendering fails. */
    }
  }

  final transform = TransformationController();
  late final AnimationController animation = AnimationController(vsync: this);
  Animation<Matrix4>? tween;
  @override
  void initState() {
    super.initState();
    animation.addListener(() {
      if (tween != null) transform.value = tween!.value;
    });
    animation.addStatusListener((status) {
      if (status == AnimationStatus.completed) requestDetail();
    });
  }

  @override
  void didUpdateWidget(PageCanvas oldWidget) {
    super.didUpdateWidget(oldWidget);
    final identity =
        '${widget.state.document?.id}:${widget.state.document?.version}:${widget.state.page}';
    if (detailIdentity != identity) {
      detailGeneration++;
      detailIdentity = identity;
      detailPreview = null;
      detailWidth = 1200;
    }
    if (oldWidget.state.page != widget.state.page) {
      animation.stop();
      transform.value = Matrix4.identity();
    }
  }

  void zoom(double factor, Size viewport) {
    animation.stop();
    final start = transform.value.clone();
    final oldScale = start.getMaxScaleOnAxis();
    final scale = (oldScale * factor).clamp(.5, 5.0);
    final ratio = scale / oldScale;
    final end = start.clone();
    end.setEntry(0, 0, scale);
    end.setEntry(1, 1, scale);
    end.setEntry(
      0,
      3,
      viewport.width / 2 - (viewport.width / 2 - start.entry(0, 3)) * ratio,
    );
    end.setEntry(
      1,
      3,
      viewport.height / 2 - (viewport.height / 2 - start.entry(1, 3)) * ratio,
    );
    animateTo(end);
  }

  void animateTo(Matrix4 end) {
    animation.stop();
    if (MediaQuery.disableAnimationsOf(context)) {
      transform.value = end;
      return;
    }
    animation.duration = const Duration(milliseconds: 180);
    tween = Matrix4Tween(
      begin: transform.value.clone(),
      end: end,
    ).chain(CurveTween(curve: Curves.easeOutCubic)).animate(animation);
    animation.forward(from: 0);
  }

  @override
  void dispose() {
    animation.dispose();
    transform.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.state.preview != null) lastPreview = widget.state;
    final state = widget.state.preview == null && widget.state.busy
        ? lastPreview ?? widget.state
        : widget.state;
    if (state.preview == null) {
      return Center(
        child: Text(
          state.busy ? '正在准备页面…' : '暂无页面预览',
          style: const TextStyle(color: EditorColors.muted),
        ),
      );
    }
    final page = state.document!.pages[state.page];
    return LayoutBuilder(
      builder: (context, constraints) {
        final viewport = Size(constraints.maxWidth, constraints.maxHeight);
        final width = math.max(
          40.0,
          math.min(
            constraints.maxWidth - 56,
            (constraints.maxHeight - 92) * page.width / page.height,
          ),
        );
        final height = width * page.height / page.width;
        fittedWidth = width;
        return Stack(
          children: [
            Positioned.fill(
              child: InteractiveViewer(
                transformationController: transform,
                onInteractionStart: (_) => animation.stop(),
                onInteractionEnd: (_) => requestDetail(),
                minScale: .5,
                maxScale: 5,
                trackpadScrollCausesScale: true,
                boundaryMargin: const EdgeInsets.all(300),
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 52),
                    child: AnimatedSwitcher(
                      layoutBuilder: motionLayout,
                      duration: motionDuration(context, 160),
                      child: Container(
                        key: ValueKey(state.preview),
                        width: width,
                        height: height,
                        decoration: const BoxDecoration(
                          color: EditorColors.surface,
                          boxShadow: [
                            BoxShadow(
                              color: EditorColors.shadow,
                              blurRadius: 18,
                              offset: Offset(0, 4),
                            ),
                          ],
                        ),
                        child: EditablePage(
                          allowSelection: widget.allowSelection,
                          allowObjectDrag: widget.allowObjectDrag,
                          page: page,
                          pageIndex: state.page,
                          preview: detailPreview ?? state.preview!,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            Positioned(
              bottom: 18,
              left: 0,
              right: 0,
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: EditorColors.surface,
                    borderRadius: BorderRadius.circular(40),
                    border: Border.all(color: EditorColors.border),
                    boxShadow: const [
                      BoxShadow(
                        color: EditorColors.shadow,
                        blurRadius: 12,
                        offset: Offset(0, 4),
                      ),
                    ],
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      ToolButton(
                        icon: Icons.remove,
                        label: '缩小',
                        onPressed: () => zoom(1 / 1.2, viewport),
                      ),
                      ValueListenableBuilder<Matrix4>(
                        valueListenable: transform,
                        builder: (_, value, _) => SizedBox(
                          width: 48,
                          child: Text(
                            '${(value.getMaxScaleOnAxis() * 100).round()}%',
                            textAlign: TextAlign.center,
                            style: const TextStyle(fontSize: 11),
                          ),
                        ),
                      ),
                      ToolButton(
                        icon: Icons.add,
                        label: '放大',
                        onPressed: () => zoom(1.2, viewport),
                      ),
                      const SizedBox(
                        height: 16,
                        child: VerticalDivider(width: 16),
                      ),
                      ToolButton(
                        icon: Icons.fit_screen_outlined,
                        label: '适应窗口',
                        onPressed: () => animateTo(Matrix4.identity()),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class PropertiesPanel extends ConsumerStatefulWidget {
  const PropertiesPanel({super.key, required this.state});
  final DocumentState state;
  @override
  ConsumerState<PropertiesPanel> createState() => _PropertiesPanelState();
}

class _PropertiesPanelState extends ConsumerState<PropertiesPanel> {
  final text = TextEditingController();
  bool shrinkToFit = false;
  String? fontPath;
  Future<void> replaceImage() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['png', 'jpg', 'jpeg'],
    );
    if (!mounted) return;
    if (result?.files.single.path case final String path) {
      await objectAction('replace_image', {'path': path});
    }
  }

  Future<void> chooseFont() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['ttf', 'otf', 'ttc'],
    );
    if (!mounted) return;
    if (result?.files.single.path case final String path) {
      setState(() => fontPath = path);
      rememberOptions();
    }
  }

  Future<void> useChineseFont() async {
    try {
      final path = await FontAssets.chineseFont();
      if (!mounted) return;
      setState(() => fontPath = path);
      rememberOptions();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('$error')));
      }
    }
  }

  void rememberOptions() {
    final object = widget.state.selected;
    if (object != null) {
      ref.read(documentProvider.notifier).setEditOptions(object.id, {
        'font_path': fontPath,
        'shrink_to_fit': shrinkToFit,
      });
    }
  }

  Future<void> objectAction(
    String kind, [
    Map<String, dynamic> extra = const {},
  ]) async {
    final object = widget.state.selected;
    if (object == null) return;
    await ref
        .read(documentProvider.notifier)
        .command(
          'object_operation',
          value: jsonEncode({
            'kind': kind,
            'page': widget.state.page,
            'index': object.objectIndex,
            ...extra,
          }),
        );
  }

  @override
  void initState() {
    super.initState();
    final object = widget.state.selected;
    final options = object == null
        ? null
        : ref.read(documentProvider.notifier).editOptionsFor(object.id);
    shrinkToFit = options?['shrink_to_fit'] as bool? ?? false;
    fontPath = options?['font_path'] as String?;
    text.text = object == null
        ? ''
        : ref.read(documentProvider.notifier).draftFor(object.id) ??
              object.text;
  }

  @override
  void didUpdateWidget(PropertiesPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.state.selected?.id != widget.state.selected?.id ||
        oldWidget.state.selected?.text != widget.state.selected?.text) {
      final object = widget.state.selected;
      if (oldWidget.state.selected?.id != object?.id) {
        final options = object == null
            ? null
            : ref.read(documentProvider.notifier).editOptionsFor(object.id);
        shrinkToFit = options?['shrink_to_fit'] as bool? ?? false;
        fontPath = options?['font_path'] as String?;
      }
      text.text = object == null
          ? ''
          : ref.read(documentProvider.notifier).draftFor(object.id) ??
                object.text;
    }
  }

  @override
  void dispose() {
    text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Material(
    color: EditorColors.surface,
    borderRadius: BorderRadius.circular(14),
    child: ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Row(
          children: [
            const Icon(Icons.tune_rounded, size: 16),
            const SizedBox(width: 8),
            Text(
              widget.state.selected?.kind == 'image' ? '图片属性' : '文字属性',
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
            ),
          ],
        ),
        const SizedBox(height: 24),
        AnimatedSwitcher(
          layoutBuilder: motionLayout,
          duration: motionDuration(context, 160),
          child: widget.state.selected == null
              ? const Column(
                  key: ValueKey('empty-properties'),
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.touch_app_outlined,
                      size: 28,
                      color: EditorColors.muted,
                    ),
                    SizedBox(height: 12),
                    Text(
                      '选择一段文字',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    SizedBox(height: 8),
                    Text(
                      '将鼠标移到文字上，点击后即可修改。',
                      style: TextStyle(fontSize: 12, color: EditorColors.muted),
                    ),
                  ],
                )
              : Column(
                  key: ValueKey('properties-${widget.state.selected!.id}'),
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.state.selected!.kind == 'image' ? '图片对象' : '文字内容',
                      style: const TextStyle(
                        fontSize: 12,
                        color: EditorColors.secondary,
                      ),
                    ),
                    const SizedBox(height: 8),
                    if (widget.state.selected!.kind == 'text') ...[
                      TextField(
                        controller: text,
                        onChanged: (value) {
                          ref
                              .read(documentProvider.notifier)
                              .setDraft(widget.state.selected!.id, value);
                          rememberOptions();
                        },
                        enabled:
                            !widget.state.busy &&
                            widget.state.selected!.editable,
                        minLines: 3,
                        maxLines: 6,
                        decoration: const InputDecoration(hintText: '输入替换内容'),
                      ),
                      SwitchListTile.adaptive(
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                        title: const Text(
                          '缩小字号以适应',
                          style: TextStyle(fontSize: 12),
                        ),
                        value: shrinkToFit,
                        onChanged: widget.state.busy
                            ? null
                            : (value) {
                                setState(() => shrinkToFit = value);
                                rememberOptions();
                              },
                      ),
                      SizedBox(
                        width: double.infinity,
                        child: OutlinedButton.icon(
                          onPressed: widget.state.busy ? null : chooseFont,
                          icon: const Icon(
                            Icons.font_download_outlined,
                            size: 16,
                          ),
                          label: Text(
                            fontPath == null
                                ? '使用原字体 · 点击更换'
                                : File(fontPath!).uri.pathSegments.last,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                      if (fontPath != null)
                        TextButton(
                          onPressed: () {
                            setState(() => fontPath = null);
                            rememberOptions();
                          },
                          child: const Text('恢复原字体'),
                        ),
                      if (widget.state.selected!.kind == 'text')
                        TextButton.icon(
                          onPressed: widget.state.busy ? null : useChineseFont,
                          icon: const Icon(Icons.translate, size: 16),
                          label: const Text('使用内置中文字体'),
                        ),
                      const SizedBox(height: 16),
                      Row(
                        children: [
                          const Icon(
                            Icons.lock_outline,
                            size: 13,
                            color: EditorColors.muted,
                          ),
                          const SizedBox(width: 6),
                          const Expanded(
                            child: Text(
                              '原区域布局校验 · 保存后重开验证',
                              style: TextStyle(
                                fontSize: 11,
                                color: EditorColors.muted,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 20),
                      SizedBox(
                        width: double.infinity,
                        child: MotionFeedback(
                          enabled: !widget.state.busy,
                          child: FilledButton(
                            onPressed:
                                widget.state.busy ||
                                    !widget.state.selected!.editable
                                ? null
                                : () => ref
                                      .read(documentProvider.notifier)
                                      .command(
                                        'replace_text_options',
                                        value: jsonEncode({
                                          'text': text.text,
                                          'options': {
                                            'shrink_to_fit': shrinkToFit,
                                            'font_path': fontPath,
                                          },
                                        }),
                                      ),
                            child: const Text('应用修改'),
                          ),
                        ),
                      ),
                    ],
                    if (widget.state.selected!.kind == 'image')
                      OutlinedButton.icon(
                        onPressed: widget.state.busy ? null : replaceImage,
                        icon: const Icon(Icons.image_outlined, size: 16),
                        label: const Text('替换图片'),
                      ),
                    if (!widget.state.selected!.editable &&
                        widget.state.selected!.kind == 'text')
                      const Padding(
                        padding: EdgeInsets.only(top: 8),
                        child: Text(
                          '这是 OCR 搜索文字层。修改它不会改变扫描图像中的可见文字。',
                          style: TextStyle(
                            fontSize: 11,
                            color: EditorColors.muted,
                          ),
                        ),
                      ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 4,
                      runSpacing: 4,
                      children: [
                        if (widget.state.selected!.kind == 'text') ...[
                          ToolButton(
                            icon: Icons.copy_outlined,
                            label: '复制选中文字',
                            onPressed: () => Clipboard.setData(
                              ClipboardData(text: widget.state.selected!.text),
                            ),
                          ),
                          ToolButton(
                            icon: Icons.highlight_outlined,
                            label: '高亮',
                            onPressed: widget.state.busy
                                ? null
                                : () => objectAction('highlight'),
                          ),
                          ToolButton(
                            icon: Icons.format_underlined,
                            label: '下划线',
                            onPressed: widget.state.busy
                                ? null
                                : () => objectAction('underline'),
                          ),
                        ],
                        ToolButton(
                          icon: Icons.delete_outline,
                          label: '删除对象',
                          onPressed: widget.state.busy
                              ? null
                              : () => objectAction('delete'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        const Text('移动', style: TextStyle(fontSize: 11)),
                        const Spacer(),
                        for (final direction in [
                          (Icons.chevron_left, -5.0, 0.0, '向左移动'),
                          (Icons.chevron_right, 5.0, 0.0, '向右移动'),
                          (Icons.expand_less, 0.0, 5.0, '向上移动'),
                          (Icons.expand_more, 0.0, -5.0, '向下移动'),
                        ])
                          ToolButton(
                            icon: direction.$1,
                            label: direction.$4,
                            onPressed: widget.state.busy
                                ? null
                                : () => objectAction('move', {
                                    'dx': direction.$2,
                                    'dy': direction.$3,
                                  }),
                          ),
                      ],
                    ),
                  ],
                ),
        ),
        const SizedBox(height: 24),
        const Divider(height: 1),
        const SizedBox(height: 16),
        const Text(
          '编辑提示',
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w500,
            color: EditorColors.secondary,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          widget.state.selected?.kind == 'image'
              ? '拖动图片可移动位置，拖动四角手柄可调整大小。修改后按 Ctrl+S 保存到源 PDF。'
              : '可拖动文字或四角手柄调整位置和大小。支持字体包含的新字符，缺字时可选择内置中文字体。',
          style: const TextStyle(fontSize: 11, color: EditorColors.muted),
        ),
        const SizedBox(height: 12),
        const Text(
          '扫描文字和已签名文档暂不支持修改。',
          style: TextStyle(fontSize: 11, color: EditorColors.muted),
        ),
      ],
    ),
  );
}
