import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/rust/api.dart' as rust;
import '../../shared/editor_theme.dart';
import '../documents/document_controller.dart';
import '../viewer/editable_page.dart';

/// One touch viewport for the whole document. Only pages intersecting the
/// viewport and its small prefetch margin are built; there is no nested pan
/// recognizer competing with vertical scrolling or pinching.
class MobileContinuousCanvas extends ConsumerStatefulWidget {
  const MobileContinuousCanvas({
    super.key,
    required this.state,
    this.editing = false,
  });
  final DocumentState state;
  final bool editing;
  @override
  ConsumerState<MobileContinuousCanvas> createState() =>
      _MobileContinuousCanvasState();
}

class _MobileContinuousCanvasState
    extends ConsumerState<MobileContinuousCanvas> {
  final transform = TransformationController();
  final futures = <(int, int), Future<String>>{};
  final paths = <int, String>{};
  final qualities = <int, int>{};
  List<double> tops = [], heights = [];
  Size viewport = Size.zero;
  double pageWidth = 1, contentHeight = 1;
  int visible = 0;
  int navigationGeneration = 0;
  int positioningRevision = 0;
  int? pendingPage;
  bool reporting = false, repositioning = false;
  Timer? persistTimer;

  @override
  void initState() {
    super.initState();
    visible = widget.state.page;
    pendingPage = visible;
    seedPreview();
    transform.addListener(changed);
  }

  void seedPreview() {
    final path = widget.state.preview;
    if (path != null && !paths.containsKey(widget.state.page)) {
      paths[widget.state.page] = path;
      qualities[widget.state.page] = 1200;
    }
  }

  int pageAt(double y) {
    var low = 0, high = tops.length;
    while (low < high) {
      final mid = (low + high) ~/ 2;
      if (tops[mid] <= y) {
        low = mid + 1;
      } else {
        high = mid;
      }
    }
    return (low - 1).clamp(0, tops.length - 1);
  }

  void changed() {
    if (!reporting) {
      reporting = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        reporting = false;
        if (mounted) reportVisible();
      });
    }
    persistTimer?.cancel();
    persistTimer = Timer(const Duration(milliseconds: 400), () {
      if (mounted && !widget.state.busy) {
        reportVisible();
        unawaited(ref.read(documentProvider.notifier).persistView());
      }
    });
  }

  void reportVisible() {
    if (tops.isEmpty ||
        repositioning ||
        pendingPage != null ||
        widget.state.busy) {
      return;
    }
    final point = transform.toScene(
      Offset(viewport.width / 2, viewport.height * .3),
    );
    final index = pageAt(point.dy);
    final path = paths[index];
    if (path != null && (index != visible || widget.state.page != index)) {
      visible = index;
      ref.read(documentProvider.notifier).visiblePage(index, path);
    }
  }

  Future<String> preview(int index, int width) {
    final cached = paths[index];
    if (cached != null && (qualities[index] ?? 0) >= width) {
      return Future.value(cached);
    }
    return futures.putIfAbsent((index, width), () async {
      final document = widget.state.document!;
      final path = width <= 1200
          ? await rust.renderPreview(
              documentId: document.id,
              expectedVersion: BigInt.from(document.version),
              pageIndex: index,
            )
          : await rust.renderDetail(
              documentId: document.id,
              expectedVersion: BigInt.from(document.version),
              pageIndex: index,
              width: width,
            );
      if (mounted &&
          document.id == widget.state.document?.id &&
          document.version == widget.state.document?.version) {
        if (width >= (qualities[index] ?? 0)) {
          paths[index] = path;
          qualities[index] = width;
        }
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) reportVisible();
        });
      }
      return path;
    });
  }

  Matrix4 bounded(double scale, double x, double y) {
    final minX = math.min(0.0, viewport.width - viewport.width * scale);
    final minY = math.min(0.0, viewport.height - contentHeight * scale);
    return Matrix4.identity()
      ..setEntry(0, 0, scale)
      ..setEntry(1, 1, scale)
      ..setEntry(0, 3, x.clamp(minX, 0.0))
      ..setEntry(1, 3, y.clamp(minY, 0.0));
  }

  void jump(int index) {
    if (index < 0 || index >= tops.length) return;
    // Recreate the gesture viewport to stop any previous fling animation before
    // applying explicit navigation. The transformation and page cache stay owned here.
    final scale = transform.value.getMaxScaleOnAxis();
    applyTransform(
      bounded(scale, transform.value.entry(0, 3), -(tops[index] - 16) * scale),
    );
    visible = index;
  }

  void zoom(double scale) {
    final focal = Offset(viewport.width / 2, viewport.height / 2);
    final point = transform.toScene(focal);
    final next = scale.clamp(1.0, 4.0);
    applyTransform(
      bounded(next, focal.dx - point.dx * next, focal.dy - point.dy * next),
    );
  }

  void applyTransform(Matrix4 matrix) {
    setState(() => navigationGeneration++);
    final revision = ++positioningRevision;
    transform.value = matrix;
    // The old viewport's fling can still tick before the next build disposes
    // it. Reassert the destination after replacement, unless a new touch began.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && revision == positioningRevision) transform.value = matrix;
    });
  }

  @override
  void didUpdateWidget(MobileContinuousCanvas oldWidget) {
    super.didUpdateWidget(oldWidget);
    final old = oldWidget.state.document!, current = widget.state.document!;
    if (old.version != current.version) {
      futures.clear();
      paths.clear();
      qualities.clear();
      if (old.pages.length != current.pages.length ||
          List.generate(current.pages.length, (i) => i).any(
            (i) =>
                old.pages[i].width != current.pages[i].width ||
                old.pages[i].height != current.pages[i].height,
          )) {
        pendingPage = widget.state.page;
      }
    }
    seedPreview();
    if (oldWidget.state.page != widget.state.page &&
        widget.state.page != visible) {
      visible = widget.state.page;
      // Tapping an object on an adjacent visible page should select it in place.
      if (widget.state.selected == null) pendingPage = visible;
    }
  }

  @override
  void dispose() {
    persistTimer?.cancel();
    transform.removeListener(changed);
    transform.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final document = widget.state.document!;
      final nextViewport = constraints.biggest;
      // Preserve the page and within-page position when rotating/resizing a phone.
      final oldAnchor = tops.isEmpty
          ? null
          : transform.toScene(Offset(viewport.width / 2, viewport.height * .3));
      final oldPage = oldAnchor == null ? 0 : pageAt(oldAnchor.dy);
      final fraction = oldAnchor == null
          ? 0.0
          : (oldAnchor.dy - tops[oldPage]) / heights[oldPage];
      final resized = viewport != nextViewport;
      viewport = nextViewport;
      pageWidth = math.max(40, viewport.width - 24);
      tops = [];
      heights = [];
      var y = 16.0;
      for (final page in document.pages) {
        tops.add(y);
        final height = pageWidth * page.height / page.width;
        heights.add(height);
        y += height + 36;
      }
      // A short landscape last page must still be able to align at the top;
      // otherwise clamping at the document end reports the previous page.
      contentHeight = math.max(
        viewport.height,
        y + math.max(64.0, viewport.height - heights.last - 52),
      );
      if (pendingPage != null || resized) {
        repositioning = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          if (pendingPage != null) {
            final page = pendingPage!;
            pendingPage = null;
            jump(page);
          } else if (oldAnchor != null) {
            final index = oldPage.clamp(0, tops.length - 1);
            final scale = transform.value.getMaxScaleOnAxis();
            applyTransform(
              bounded(
                scale,
                transform.value.entry(0, 3),
                viewport.height * .3 -
                    (tops[index] + fraction * heights[index]) * scale,
              ),
            );
          }
          repositioning = false;
          reportVisible();
        });
      }
      return Stack(
        key: const ValueKey('mobile-continuous-pages'),
        children: [
          Positioned.fill(
            child: InteractiveViewer.builder(
              key: ValueKey(navigationGeneration),
              transformationController: transform,
              alignment: Alignment.topLeft,
              minScale: 1,
              maxScale: 4,
              onInteractionStart: (_) => positioningRevision++,
              onInteractionEnd: (_) => changed(),
              builder: (context, region) {
                final top = math.min(region.point0.y, region.point2.y);
                final bottom = math.max(region.point0.y, region.point2.y);
                final first = pageAt(top - 240), last = pageAt(bottom + 240);
                final desired =
                    (pageWidth *
                            transform.value.getMaxScaleOnAxis() *
                            MediaQuery.devicePixelRatioOf(context) /
                            512)
                        .ceil() *
                    512;
                final quality = desired.clamp(1200, 2048);
                return SizedBox(
                  width: viewport.width,
                  height: contentHeight,
                  child: Stack(
                    children: [
                      for (var i = first; i <= last; i++)
                        Positioned(
                          key: ValueKey('mobile-page-$i'),
                          top: tops[i],
                          left: 12,
                          width: pageWidth,
                          height: heights[i] + 28,
                          child: Column(
                            children: [
                              SizedBox(
                                width: pageWidth,
                                height: heights[i],
                                child: ColoredBox(
                                  color: Colors.white,
                                  child: FutureBuilder<String>(
                                    key: ValueKey(
                                      '${document.id}:${document.version}:$i',
                                    ),
                                    future: preview(i, quality),
                                    builder: (context, snapshot) {
                                      final path = snapshot.data ?? paths[i];
                                      if (path != null) {
                                        return EditablePage(
                                          page: document.pages[i],
                                          pageIndex: i,
                                          preview: path,
                                          allowSelection: widget.editing,
                                          allowObjectDrag: false,
                                        );
                                      }
                                      if (snapshot.hasError) {
                                        return Center(
                                          child: TextButton(
                                            onPressed: () => setState(
                                              () =>
                                                  futures.remove((i, quality)),
                                            ),
                                            child: Text('重试第 ${i + 1} 页'),
                                          ),
                                        );
                                      }
                                      return Center(
                                        child: Text('正在载入第 ${i + 1} 页…'),
                                      );
                                    },
                                  ),
                                ),
                              ),
                              const SizedBox(height: 6),
                              Text(
                                '第 ${i + 1} 页',
                                style: const TextStyle(
                                  fontSize: 11,
                                  color: EditorColors.muted,
                                ),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                );
              },
            ),
          ),
          Positioned(
            bottom: 12,
            left: 0,
            right: 0,
            child: Center(
              child: Material(
                color: EditorColors.surface,
                borderRadius: BorderRadius.circular(32),
                child: ValueListenableBuilder<Matrix4>(
                  valueListenable: transform,
                  builder: (context, matrix, _) => Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        tooltip: '缩小',
                        onPressed: () => zoom(matrix.getMaxScaleOnAxis() / 1.2),
                        icon: const Icon(Icons.remove),
                      ),
                      SizedBox(
                        width: 48,
                        child: Text(
                          '${(matrix.getMaxScaleOnAxis() * 100).round()}%',
                          textAlign: TextAlign.center,
                          style: const TextStyle(fontSize: 12),
                        ),
                      ),
                      IconButton(
                        tooltip: '放大',
                        onPressed: () => zoom(matrix.getMaxScaleOnAxis() * 1.2),
                        icon: const Icon(Icons.add),
                      ),
                      IconButton(
                        tooltip: '适应窗口',
                        onPressed: () {
                          zoom(1);
                          jump(widget.state.page);
                        },
                        icon: const Icon(Icons.fit_screen),
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
