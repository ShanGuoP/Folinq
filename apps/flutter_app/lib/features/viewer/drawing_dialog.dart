import 'package:flutter/material.dart';
import '../../shared/editor_theme.dart';

class DrawingDialog extends StatefulWidget {
  const DrawingDialog({super.key});
  @override
  State<DrawingDialog> createState() => _DrawingDialogState();
}

class _DrawingDialogState extends State<DrawingDialog> {
  final List<List<Offset>> strokes = [];
  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('自由绘画 / 手写签名'),
    content: SizedBox(
      width: 520,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            '笔迹将作为页面矢量内容加入当前页底部，可撤销。这不是数字证书签名。',
            style: TextStyle(fontSize: 12, color: EditorColors.muted),
          ),
          const SizedBox(height: 12),
          AspectRatio(
            aspectRatio: 2.5,
            child: LayoutBuilder(
              builder: (context, constraints) {
                Offset normalized(Offset p) => Offset(
                  (p.dx / constraints.maxWidth).clamp(0, 1),
                  (p.dy / constraints.maxHeight).clamp(0, 1),
                );
                return GestureDetector(
                  onPanStart: (details) => setState(
                    () => strokes.add([normalized(details.localPosition)]),
                  ),
                  onPanUpdate: (details) {
                    if (strokes.fold<int>(0, (n, s) => n + s.length) < 20000) {
                      setState(
                        () =>
                            strokes.last.add(normalized(details.localPosition)),
                      );
                    }
                  },
                  child: CustomPaint(
                    painter: _InkPainter(strokes),
                    child: Container(
                      decoration: BoxDecoration(
                        border: Border.all(color: EditorColors.border),
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => setState(strokes.clear),
        child: const Text('清空'),
      ),
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: strokes.any((s) => s.length > 1)
            ? () => Navigator.pop(context, [
                for (final stroke in strokes.where((s) => s.length > 1))
                  [
                    for (final p in stroke) [p.dx, p.dy],
                  ],
              ])
            : null,
        child: const Text('加入当前页'),
      ),
    ],
  );
}

class _InkPainter extends CustomPainter {
  _InkPainter(this.strokes);
  final List<List<Offset>> strokes;
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = EditorColors.text
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    for (final stroke in strokes) {
      if (stroke.isEmpty) continue;
      final path = Path()
        ..moveTo(stroke.first.dx * size.width, stroke.first.dy * size.height);
      for (final p in stroke.skip(1)) {
        path.lineTo(p.dx * size.width, p.dy * size.height);
      }
      canvas.drawPath(path, paint);
    }
  }

  @override
  bool shouldRepaint(_InkPainter oldDelegate) => true;
}
