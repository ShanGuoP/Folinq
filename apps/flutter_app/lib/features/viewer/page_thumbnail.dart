import 'dart:io';
import 'package:flutter/material.dart';
import '../../core/rust/api.dart' as rust;

class PageThumbnail extends StatefulWidget {
  const PageThumbnail({
    super.key,
    required this.documentId,
    required this.version,
    required this.page,
    this.preview,
  });
  final String documentId;
  final int version, page;
  final String? preview;
  @override
  State<PageThumbnail> createState() => _PageThumbnailState();
}

class _PageThumbnailState extends State<PageThumbnail> {
  late Future<String> image = load();
  Future<String> load() => widget.preview != null
      ? Future.value(widget.preview)
      : rust.renderDetail(
          documentId: widget.documentId,
          expectedVersion: BigInt.from(widget.version),
          pageIndex: widget.page,
          width: 512,
        );
  @override
  void didUpdateWidget(PageThumbnail oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.documentId != widget.documentId ||
        oldWidget.version != widget.version ||
        oldWidget.page != widget.page ||
        oldWidget.preview != widget.preview) {
      image = load();
    }
  }

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 34,
    height: 48,
    child: FutureBuilder<String>(
      future: image,
      builder: (context, snapshot) => snapshot.hasData
          ? DecoratedBox(
              decoration: BoxDecoration(
                color: Colors.white,
                border: Border.all(color: const Color(0xffdedee4)),
              ),
              child: Image.file(
                File(snapshot.data!),
                fit: BoxFit.contain,
                errorBuilder: (_, _, _) =>
                    const Icon(Icons.description_outlined, size: 24),
              ),
            )
          : const Icon(Icons.description_outlined, size: 24),
    ),
  );
}
