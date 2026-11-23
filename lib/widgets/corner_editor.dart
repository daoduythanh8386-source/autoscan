import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../core/geometry.dart';

/// Kéo từng góc để chỉnh vùng tài liệu trên ẢNH GỐC. Có kính lúp khi kéo.
class CornerEditor extends StatefulWidget {
  final ui.Image image; // ảnh xem trước của ảnh gốc
  final int fullWidth; // kích thước ảnh gốc đầy đủ (toạ độ góc tính theo đây)
  final int fullHeight;
  final Quad quad;
  final ValueChanged<Quad> onChanged;
  final ValueChanged<Quad> onChangeEnd;

  const CornerEditor({
    super.key,
    required this.image,
    required this.fullWidth,
    required this.fullHeight,
    required this.quad,
    required this.onChanged,
    required this.onChangeEnd,
  });

  @override
  State<CornerEditor> createState() => _CornerEditorState();
}

class _CornerEditorState extends State<CornerEditor> {
  int? _drag;
  late Quad _q = widget.quad;

  @override
  void didUpdateWidget(covariant CornerEditor old) {
    super.didUpdateWidget(old);
    if (_drag == null) _q = widget.quad;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, box) {
      const pad = 24.0;
      final aw = box.maxWidth - 2 * pad, ah = box.maxHeight - 2 * pad;
      final s = (aw / widget.fullWidth) < (ah / widget.fullHeight)
          ? aw / widget.fullWidth
          : ah / widget.fullHeight;
      final dw = widget.fullWidth * s, dh = widget.fullHeight * s;
      final origin = Offset((box.maxWidth - dw) / 2, (box.maxHeight - dh) / 2);
      Offset toScreen(Pt p) => origin + Offset(p.x * s, p.y * s);
      Pt toImage(Offset o) => Pt(
          ((o.dx - origin.dx) / s).clamp(0.0, widget.fullWidth.toDouble()),
          ((o.dy - origin.dy) / s).clamp(0.0, widget.fullHeight.toDouble()));

      return Stack(children: [
        Positioned(
          left: origin.dx,
          top: origin.dy,
          width: dw,
          height: dh,
          child: RawImage(image: widget.image, fit: BoxFit.fill),
        ),
        Positioned.fill(
          child: CustomPaint(painter: _CornerPainter([for (final p in _q.pts) toScreen(p)])),
        ),
        for (var i = 0; i < 4; i++)
          Positioned(
            left: toScreen(_q.pts[i]).dx - 28,
            top: toScreen(_q.pts[i]).dy - 28,
            width: 56,
            height: 56,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onPanStart: (_) => setState(() => _drag = i),
              onPanUpdate: (d) {
                final cur = toScreen(_q.pts[i]) + d.delta;
                final nq = _q.withPoint(i, toImage(cur));
                setState(() => _q = nq);
                widget.onChanged(nq);
              },
              onPanEnd: (_) {
                setState(() => _drag = null);
                final ordered = Quad.ordered(_q.pts);
                _q = ordered;
                widget.onChangeEnd(ordered);
              },
              child: Center(
                child: Container(
                  width: 26,
                  height: 26,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.white.withValues(alpha: 0.85),
                    border: Border.all(color: Theme.of(context).colorScheme.primary, width: 3),
                  ),
                ),
              ),
            ),
          ),
        if (_drag != null)
          Positioned(
            // Kính lúp ở góc đối diện để ngón tay không che.
            left: toScreen(_q.pts[_drag!]).dx < box.maxWidth / 2 ? box.maxWidth - 140 : 12,
            top: 12,
            width: 128,
            height: 128,
            child: CustomPaint(
              painter: _LoupePainter(
                widget.image,
                Offset(_q.pts[_drag!].x * widget.image.width / widget.fullWidth,
                    _q.pts[_drag!].y * widget.image.height / widget.fullHeight),
              ),
            ),
          ),
      ]);
    });
  }
}

class _CornerPainter extends CustomPainter {
  final List<Offset> pts;
  _CornerPainter(this.pts);

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()..addPolygon(pts, true);
    final outside = Path.combine(
        PathOperation.difference, Path()..addRect(Offset.zero & size), path);
    canvas.drawPath(outside, Paint()..color = Colors.black.withValues(alpha: 0.45));
    canvas.drawPath(
        path,
        Paint()
          ..color = Colors.lightBlueAccent
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.5);
  }

  @override
  bool shouldRepaint(covariant _CornerPainter old) => true;
}

class _LoupePainter extends CustomPainter {
  final ui.Image image;
  final Offset center; // theo pixel của ảnh xem trước
  _LoupePainter(this.image, this.center);

  @override
  void paint(Canvas canvas, Size size) {
    const zoomSrc = 36.0;
    final src = Rect.fromCenter(center: center, width: zoomSrc, height: zoomSrc);
    final dst = Offset.zero & size;
    canvas.save();
    canvas.clipPath(Path()..addOval(dst));
    canvas.drawColor(Colors.black, BlendMode.src);
    canvas.drawImageRect(image, src, dst, Paint()..filterQuality = FilterQuality.medium);
    canvas.restore();
    final c = dst.center;
    final p = Paint()
      ..color = Colors.redAccent
      ..strokeWidth = 1.5;
    canvas.drawLine(c - const Offset(14, 0), c + const Offset(14, 0), p);
    canvas.drawLine(c - const Offset(0, 14), c + const Offset(0, 14), p);
    canvas.drawOval(
        dst,
        Paint()
          ..color = Colors.white
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3);
  }

  @override
  bool shouldRepaint(covariant _LoupePainter old) => old.center != center || old.image != image;
}
