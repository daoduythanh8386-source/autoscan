import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:smart_document_scanner/core/geometry.dart';

void main() {
  test('Quad.ordered sắp xếp TL, TR, BR, BL từ thứ tự lộn xộn', () {
    final q = Quad.ordered([Pt(90, 95), Pt(10, 5), Pt(5, 100), Pt(100, 0)]);
    expect(q.tl.x, 10);
    expect(q.tr.x, 100);
    expect(q.br.x, 90);
    expect(q.bl.x, 5);
    expect(q.isConvex, isTrue);
  });

  test('Homography ánh xạ đúng 4 điểm', () {
    final src = [Pt(0, 0), Pt(100, 0), Pt(100, 50), Pt(0, 50)];
    final dst = [Pt(10, 20), Pt(210, 30), Pt(200, 140), Pt(5, 120)];
    final h = Homography.fromPoints(src, dst);
    for (var i = 0; i < 4; i++) {
      final p = h.apply(src[i].x, src[i].y);
      expect(p.x, closeTo(dst[i].x, 1e-6));
      expect(p.y, closeTo(dst[i].y, 1e-6));
    }
  });

  test('outputSize không thu nhỏ độ phân giải', () {
    final q = Quad.ordered([Pt(0, 0), Pt(400, 10), Pt(390, 600), Pt(5, 590)]);
    final (w, h) = q.outputSize();
    expect(w, greaterThanOrEqualTo(385));
    expect(h, greaterThanOrEqualTo(590));
  });

  test('warp hình chữ nhật đồng nhất giữ nguyên pixel', () {
    const w = 8, h = 6;
    final src = Uint8List(w * h * 3);
    for (var i = 0; i < src.length; i++) {
      src[i] = (i * 37) % 256;
    }
    final q = Quad.fullFrame(w - 1.0, h - 1.0);
    final out = warpPerspectiveRgb(src, w, h, q, w, h);
    expect(out, equals(src));
  });

  test('xoay 4 lần 90° trả về ảnh ban đầu', () {
    const w = 5, h = 3;
    final src = Uint8List.fromList(List.generate(w * h * 3, (i) => i));
    var (b, bw, bh) = rotateRgb90(src, w, h, 1);
    expect((bw, bh), (3, 5));
    for (var k = 0; k < 3; k++) {
      (b, bw, bh) = rotateRgb90(b, bw, bh, 1);
    }
    expect(b, equals(src));
  });
}
