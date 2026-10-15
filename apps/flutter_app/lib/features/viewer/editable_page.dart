import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/document.dart';
import '../../shared/editor_theme.dart';
import '../documents/document_controller.dart';

class EditablePage extends ConsumerStatefulWidget {
  const EditablePage({
    super.key,
    required this.page,
    required this.pageIndex,
    required this.preview,
  });
  final PageInfo page;
  final int pageIndex;
  final String preview;
  @override
  ConsumerState<EditablePage> createState() => _EditablePageState();
}

class _EditablePageState extends ConsumerState<EditablePage> {
  String? dragging;
  Rect? live;
  void select(TextObject object) {
    Focus.of(context).requestFocus();
    ref
        .read(documentProvider.notifier)
        .selectOnPage(widget.pageIndex, object, widget.preview);
  }

  Future<void> commit(TextObject object) async {
    final rect = live;
    if (rect == null) return;
    await ref
        .read(documentProvider.notifier)
        .command(
          'object_operation',
          value: jsonEncode({
            'kind': 'transform',
            'page': widget.pageIndex,
            'index': object.objectIndex,
            'display': [rect.left, rect.top, rect.right, rect.bottom],
          }),
        );
    if (mounted) {
      setState(() {
        dragging = null;
        live = null;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(documentProvider);
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.biggest;
        return Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned.fill(
              child: Image.file(
                File(widget.preview),
                fit: BoxFit.fill,
                errorBuilder: (_, _, _) =>
                    const Center(child: Text('页面预览加载失败')),
              ),
            ),
            for (final object in widget.page.objects) ...[
              Builder(
                builder: (context) {
                  final original = Rect.fromLTRB(
                    object.left / widget.page.width,
                    1 - object.top / widget.page.height,
                    object.right / widget.page.width,
                    1 - object.bottom / widget.page.height,
                  );
                  final rect = dragging == object.id && live != null
                      ? live!
                      : original;
                  final selected =
                      state.page == widget.pageIndex &&
                      state.selected?.id == object.id;
                  final enabled =
                      !state.busy &&
                      (object.kind == 'image' || object.editable);
                  void begin() {
                    select(object);
                    setState(() {
                      dragging = object.id;
                      live = rect;
                    });
                  }

                  void cancel() => setState(() {
                    dragging = null;
                    live = null;
                  });
                  return Positioned(
                    left: rect.left * size.width - 5,
                    top: rect.top * size.height - 5,
                    width: rect.width * size.width + 10,
                    height: rect.height * size.height + 10,
                    child: MouseRegion(
                      cursor: enabled
                          ? SystemMouseCursors.move
                          : SystemMouseCursors.click,
                      child: GestureDetector(
                        key: ValueKey(object.id),
                        dragStartBehavior: DragStartBehavior.down,
                        behavior: HitTestBehavior.opaque,
                        onTap: state.busy ? null : () => select(object),
                        onPanStart: enabled ? (_) => begin() : null,
                        onPanUpdate: enabled
                            ? (event) {
                                final current = live;
                                if (current == null) return;
                                final dx = (event.delta.dx / size.width).clamp(
                                  -current.left,
                                  1 - current.right,
                                );
                                final dy = (event.delta.dy / size.height).clamp(
                                  -current.top,
                                  1 - current.bottom,
                                );
                                setState(
                                  () => live = current.shift(Offset(dx, dy)),
                                );
                              }
                            : null,
                        onPanEnd: enabled ? (_) => commit(object) : null,
                        onPanCancel: cancel,
                        child: Stack(
                          children: [
                            Positioned.fill(
                              child: Padding(
                                padding: const EdgeInsets.all(5),
                                child: DecoratedBox(
                                  decoration: BoxDecoration(
                                    color: selected
                                        ? EditorColors.selection
                                        : Colors.transparent,
                                    border: Border.all(
                                      color: selected
                                          ? EditorColors.focus
                                          : Colors.transparent,
                                      width: 1.5,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            if (selected && enabled)
                              for (final corner in [
                                const Offset(0, 0),
                                const Offset(1, 0),
                                const Offset(0, 1),
                                const Offset(1, 1),
                              ])
                                Align(
                                  alignment: Alignment(
                                    corner.dx * 2 - 1,
                                    corner.dy * 2 - 1,
                                  ),
                                  child: MouseRegion(
                                    cursor: corner.dx == corner.dy
                                        ? SystemMouseCursors
                                              .resizeUpLeftDownRight
                                        : SystemMouseCursors
                                              .resizeUpRightDownLeft,
                                    child: GestureDetector(
                                      dragStartBehavior: DragStartBehavior.down,
                                      key: ValueKey(
                                        'resize-${object.id}-${corner.dx.toInt()}${corner.dy.toInt()}',
                                      ),
                                      onPanStart: (_) => begin(),
                                      onPanUpdate: (event) {
                                        final r = live;
                                        if (r == null) return;
                                        final dx = event.delta.dx / size.width,
                                            dy = event.delta.dy / size.height;
                                        final minW = (12 / size.width).clamp(
                                              .002,
                                              .1,
                                            ),
                                            minH = (12 / size.height).clamp(
                                              .002,
                                              .1,
                                            );
                                        setState(
                                          () => live = Rect.fromLTRB(
                                            corner.dx == 0
                                                ? (r.left + dx).clamp(
                                                    0,
                                                    r.right - minW,
                                                  )
                                                : r.left,
                                            corner.dy == 0
                                                ? (r.top + dy).clamp(
                                                    0,
                                                    r.bottom - minH,
                                                  )
                                                : r.top,
                                            corner.dx == 1
                                                ? (r.right + dx).clamp(
                                                    r.left + minW,
                                                    1,
                                                  )
                                                : r.right,
                                            corner.dy == 1
                                                ? (r.bottom + dy).clamp(
                                                    r.top + minH,
                                                    1,
                                                  )
                                                : r.bottom,
                                          ),
                                        );
                                      },
                                      onPanEnd: (_) => commit(object),
                                      onPanCancel: cancel,
                                      child: Container(
                                        width: 10,
                                        height: 10,
                                        decoration: BoxDecoration(
                                          color: Colors.white,
                                          border: Border.all(
                                            color: EditorColors.focus,
                                          ),
                                          borderRadius: BorderRadius.circular(
                                            2,
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
                  );
                },
              ),
            ],
          ],
        );
      },
    );
  }
}
