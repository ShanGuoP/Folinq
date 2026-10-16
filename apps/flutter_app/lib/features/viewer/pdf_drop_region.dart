import 'dart:io';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../documents/document_controller.dart';

/// Accept files over both the library and editor, preserving normal open rules.
class PdfDropRegion extends ConsumerStatefulWidget {
  const PdfDropRegion({
    super.key,
    required this.child,
    required this.onOpened,
    this.startupPaths = const [],
  });
  final Widget child;
  final VoidCallback onOpened;
  final List<String> startupPaths;
  @override
  ConsumerState<PdfDropRegion> createState() => _PdfDropRegionState();
}

class _PdfDropRegionState extends ConsumerState<PdfDropRegion> {
  bool hovering = false, opening = false;

  @override
  void initState() {
    super.initState();
    if (widget.startupPaths.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        accept(
          DropDoneDetails(
            files: [for (final path in widget.startupPaths) DropItemFile(path)],
            localPosition: Offset.zero,
            globalPosition: Offset.zero,
          ),
        );
      });
    }
  }

  Future<void> accept(DropDoneDetails details) async {
    setState(() => hovering = false);
    if (opening ||
        ref.read(documentProvider).busy ||
        ModalRoute.of(context)?.isCurrent == false) {
      return;
    }
    final paths = <String>[];
    final seen = <String>{};
    var ignored = 0;
    for (final item in details.files) {
      final path = item.path;
      final key = Platform.isWindows ? path.toLowerCase() : path;
      if (!path.toLowerCase().endsWith('.pdf') ||
          FileSystemEntity.typeSync(path) != FileSystemEntityType.file) {
        ignored++;
      } else if (seen.add(key)) {
        paths.add(path);
      }
    }
    if (paths.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('请拖入 PDF 文件，文件夹和其他格式暂不支持。')));
      return;
    }
    setState(() => opening = true);
    try {
      for (final path in paths) {
        if (!mounted) return;
        await ref.read(documentProvider.notifier).open(path);
        if (!mounted) return;
        if (ref.read(documentProvider).error != null) break;
        widget.onOpened();
      }
      if (mounted && ignored > 0) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('已忽略 $ignored 个非 PDF 文件或文件夹。')));
      }
    } catch (failure) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('无法打开拖入的 PDF：$failure')));
      }
    } finally {
      if (mounted) setState(() => opening = false);
    }
  }

  @override
  Widget build(BuildContext context) => DropTarget(
    enable:
        !opening &&
        !ref.watch(documentProvider).busy &&
        ModalRoute.of(context)?.isCurrent != false,
    onDragEntered: (_) => setState(() => hovering = true),
    onDragExited: (_) => setState(() => hovering = false),
    onDragDone: accept,
    child: Stack(
      fit: StackFit.expand,
      children: [
        widget.child,
        if (hovering)
          const IgnorePointer(
            child: ColoredBox(
              color: Color(0xeef4f4f6),
              child: Center(
                child: Text('松开以打开 PDF', style: TextStyle(fontSize: 24)),
              ),
            ),
          ),
      ],
    ),
  );
}
