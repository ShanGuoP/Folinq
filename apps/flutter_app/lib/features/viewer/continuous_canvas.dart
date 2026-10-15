import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/rust/api.dart' as rust;
import '../../shared/editor_theme.dart';
import '../documents/document_controller.dart';
import 'editable_page.dart';

class ContinuousCanvas extends ConsumerStatefulWidget {
  const ContinuousCanvas({super.key, required this.state});
  final DocumentState state;
  @override
  ConsumerState<ContinuousCanvas> createState() => _ContinuousCanvasState();
}

class _ContinuousCanvasState extends ConsumerState<ContinuousCanvas> {
  final scroll = ScrollController(), horizontal = ScrollController();
  final futures = <int, Future<String>>{};
  final paths = <int, String>{};
  List<double> offsets = [];
  double zoom = 1;
  int visible = 0;
  bool jumpPending = false;
  @override
  void initState() {
    super.initState();
    visible = widget.state.page;
    if (widget.state.preview != null) paths[visible] = widget.state.preview!;
    scroll.addListener(reportVisible);
    if (visible > 0) {
      jumpPending = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && scroll.hasClients && visible < offsets.length) {
          scroll.jumpTo(
            offsets[visible].clamp(0, scroll.position.maxScrollExtent),
          );
        }
        jumpPending = false;
      });
    }
  }

  Future<String> preview(int page) => futures.putIfAbsent(page, () async {
    final document = widget.state.document!;
    final path =
        paths[page] ??
        await rust.renderPreview(
          documentId: document.id,
          expectedVersion: BigInt.from(document.version),
          pageIndex: page,
        );
    if (mounted &&
        widget.state.document?.id == document.id &&
        widget.state.document?.version == document.version) {
      paths[page] = path;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) reportVisible();
      });
    }
    return path;
  });
  void reportVisible() {
    if (!mounted ||
        !scroll.hasClients ||
        offsets.isEmpty ||
        jumpPending ||
        widget.state.busy) {
      return;
    }
    final position = scroll.offset + scroll.position.viewportDimension * .3;
    var index = 0;
    for (var i = 1; i < offsets.length; i++) {
      if (offsets[i] > position) break;
      index = i;
    }
    final path = paths[index];
    if (path != null && index != visible) {
      visible = index;
      ref.read(documentProvider.notifier).visiblePage(index, path);
    }
  }

  @override
  void didUpdateWidget(ContinuousCanvas oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.state.document?.version != widget.state.document?.version) {
      futures.clear();
      paths.clear();
      if (widget.state.preview != null) {
        paths[widget.state.page] = widget.state.preview!;
      }
    }
    if (widget.state.preview != null &&
        (oldWidget.state.preview != widget.state.preview ||
            oldWidget.state.busy && !widget.state.busy)) {
      paths[widget.state.page] = widget.state.preview!;
      futures[widget.state.page] = Future.value(widget.state.preview!);
    }
    if (oldWidget.state.page != widget.state.page &&
        widget.state.page != visible) {
      visible = widget.state.page;
      jumpPending = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && scroll.hasClients && visible < offsets.length) {
          scroll.jumpTo(
            offsets[visible].clamp(0, scroll.position.maxScrollExtent),
          );
        }
        jumpPending = false;
      });
    }
  }

  @override
  void dispose() {
    scroll.dispose();
    horizontal.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final document = widget.state.document!;
      final widths = [
        for (final page in document.pages)
          math
                  .min(
                    constraints.maxWidth - 56,
                    (constraints.maxHeight - 92) * page.width / page.height,
                  )
                  .clamp(40.0, 4000.0) *
              zoom,
      ];
      offsets = [];
      var sum = 16.0;
      for (var i = 0; i < widths.length; i++) {
        offsets.add(sum);
        sum +=
            widths[i] * document.pages[i].height / document.pages[i].width + 48;
      }
      final contentWidth = math.max(
        constraints.maxWidth,
        widths.reduce(math.max) + 56,
      );
      return Stack(
        children: [
          Positioned.fill(
            child: Scrollbar(
              controller: horizontal,
              child: SingleChildScrollView(
                controller: horizontal,
                scrollDirection: Axis.horizontal,
                child: SizedBox(
                  width: contentWidth,
                  height: constraints.maxHeight,
                  child: Scrollbar(
                    controller: scroll,
                    thumbVisibility: true,
                    child: ListView.builder(
                      key: const ValueKey('continuous-pages'),
                      controller: scroll,
                      padding: const EdgeInsets.only(top: 16, bottom: 72),
                      itemCount: document.pages.length,
                      itemBuilder: (context, index) {
                        final page = document.pages[index];
                        return SizedBox(
                          height: widths[index] * page.height / page.width + 48,
                          child: Column(
                            children: [
                              SizedBox(
                                width: widths[index],
                                height:
                                    widths[index] * page.height / page.width,
                                child: ColoredBox(
                                  color: Colors.white,
                                  child: FutureBuilder<String>(
                                    future: preview(index),
                                    builder: (context, snapshot) =>
                                        snapshot.hasData
                                        ? EditablePage(
                                            key: ValueKey(
                                              '${document.id}:${page.id}',
                                            ),
                                            page: page,
                                            pageIndex: index,
                                            preview: snapshot.data!,
                                          )
                                        : Center(
                                            child: Text(
                                              snapshot.hasError
                                                  ? '页面加载失败，点击页码重试'
                                                  : '正在载入第 ${index + 1} 页…',
                                            ),
                                          ),
                                  ),
                                ),
                              ),
                              Padding(
                                padding: const EdgeInsets.only(top: 8),
                                child: Text(
                                  '第 ${index + 1} 页',
                                  style: const TextStyle(
                                    fontSize: 11,
                                    color: EditorColors.muted,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        );
                      },
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
              child: Material(
                color: Colors.white,
                borderRadius: BorderRadius.circular(32),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      ToolButton(
                        icon: Icons.remove,
                        label: '缩小',
                        onPressed: () =>
                            setState(() => zoom = (zoom / 1.2).clamp(.5, 4)),
                      ),
                      SizedBox(
                        width: 48,
                        child: Text(
                          '${(zoom * 100).round()}%',
                          textAlign: TextAlign.center,
                          style: const TextStyle(fontSize: 11),
                        ),
                      ),
                      ToolButton(
                        icon: Icons.add,
                        label: '放大',
                        onPressed: () =>
                            setState(() => zoom = (zoom * 1.2).clamp(.5, 4)),
                      ),
                      ToolButton(
                        icon: Icons.fit_screen,
                        label: '适应窗口',
                        onPressed: () => setState(() => zoom = 1),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      );
    },
  );
}
