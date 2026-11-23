import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:smart_document_scanner/core/geometry.dart';
import 'package:smart_document_scanner/core/rectify.dart';

/// Chiếu tờ A4 (0,210 x 0,297 m) qua camera thật: tiêu cự [f] px, ảnh [w]x[h].
List<Pt> projectA4(double tiltX, double tiltY, double roll, double dist,
    {double f = 3100, int w = 3000, int h = 4000}) {
  const pw = 0.210, ph = 0.297;
  final obj = [
    [-pw / 2, -ph / 2, 0.0],
    [pw / 2, -ph / 2, 0.0],
    [pw / 2, ph / 2, 0.0],
    [-pw / 2, ph / 2, 0.0],
  ];
  double rad(double d) => d * math.pi / 180;
  final ax = rad(tiltX), ay = rad(tiltY), az = rad(roll);
  List<double> rot(List<double> p) {
    var x = p[0], y = p[1], z = p[2];
    // Rx
    var y1 = y * math.cos(ax) - z * math.sin(ax), z1 = y * math.sin(ax) + z * math.cos(ax);
    y = y1;
    z = z1;
    // Ry
    final x2 = x * math.cos(ay) + z * math.sin(ay), z2 = -x * math.sin(ay) + z * math.cos(ay);
    x = x2;
    z = z2;
    // Rz
    final x3 = x * math.cos(az) - y * math.sin(az), y3 = x * math.sin(az) + y * math.cos(az);
    return [x3, y3, z];
  }

  return [
    for (final p in obj)
      () {
        final r = rot(p);
        final z = r[2] + dist;
        return Pt(f * r[0] / z + w / 2, f * r[1] / z + h / 2);
      }()
  ];
}

const cases = [
  [0.0, 0.0, 3.0, 0.42],
  [20.0, 0.0, 0.0, 0.42],
  [30.0, 8.0, -6.0, 0.45],
  [35.0, -12.0, 10.0, 0.47],
  [-25.0, 15.0, 4.0, 0.44],
  [10.0, 25.0, -15.0, 0.46],
  [40.0, 0.0, 2.0, 0.5],
];

void main() {
  group('Tỷ lệ thật sau nắn phẳng (chống bóp/kéo dọc)', () {
    final truth = 0.210 / 0.297;

    test('có tiêu cự EXIF: sai số < 0,3% ở mọi góc nghiêng', () {
      for (final c in cases) {
        final q = Quad.ordered(projectA4(c[0], c[1], c[2], c[3]));
        final a = estimateAspect(q, 3000, 4000, focalPx: 3100, paper: PaperSize.free);
        expect((a.ratio / truth - 1).abs(), lessThan(0.003), reason: 'ca $c: ${a.ratio}');
      }
    });

    test('không có EXIF: tự khớp đúng khổ A4', () {
      for (final c in cases) {
        final q = Quad.ordered(projectA4(c[0], c[1], c[2], c[3]));
        final a = estimateAspect(q, 3000, 4000);
        expect(a.snapped, PaperSize.a4, reason: 'ca $c: đo ${a.measured}');
        expect(a.ratio, closeTo(1 / math.sqrt2, 1e-9));
      }
    });

    test('cách cũ (cạnh dài nhất) sai nhiều – xác nhận lỗi đã sửa', () {
      final q = Quad.ordered(projectA4(40, 0, 2, 0.5));
      final (w, h) = q.outputSize();
      expect((w / h / truth - 1).abs(), greaterThan(0.3));
      final a = estimateAspect(q, 3000, 4000);
      final (w2, h2) = outputSizeForAspect(q, a.ratio);
      expect((w2 / h2 / truth - 1).abs(), lessThan(0.002));
    });
  });

  test('tinh chỉnh mép giấy: góc lệch ~8px → < 1,5px', () {
    const w = 900, h = 1200;
    final truth = Quad.ordered(projectA4(30, 8, -6, 0.45, f: 930, w: w, h: h));
    // Dựng ảnh: giấy sáng có dòng chữ, nền tối có vân.
    final hm = Homography.fromPoints(truth.pts, [Pt(0, 0), Pt(1, 0), Pt(1, 1), Pt(0, 1)]);
    final img = Uint8List(w * h);
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final u = hm.apply(x + 0.5, y + 0.5);
        if (u.x >= 0 && u.x <= 1 && u.y >= 0 && u.y <= 1) {
          final text = u.y > 0.08 && u.y < 0.92 && u.x > 0.08 && u.x < 0.92 &&
              (u.y * 60).floor().isEven && ((u.x * 40).floor() % 5 != 0);
          img[y * w + x] = text ? 40 : 220;
        } else {
          img[y * w + x] = 60 + ((x ~/ 13 + y ~/ 29) % 3) * 8;
        }
      }
    }
    final coarse = Quad.ordered([
      for (var i = 0; i < 4; i++)
        Pt(truth.pts[i].x + (i.isEven ? 6 : -5), truth.pts[i].y + (i < 2 ? 5 : -6))
    ]);
    final r = refineQuad(img, w, h, coarse);
    expect(r.sidesRefined, 4);
    for (var i = 0; i < 4; i++) {
      expect(r.quad.pts[i].dist(truth.pts[i]), lessThan(1.5), reason: 'góc $i');
    }
  });

  group('Làm thẳng dòng chữ', () {
    Uint8List lines(int w, int h, double slopeDeg) {
      final g = Uint8List(w * h)..fillRange(0, w * h, 235);
      final t = math.tan(slopeDeg * math.pi / 180);
      for (var y = 0; y < h; y++) {
        for (var x = 0; x < w; x++) {
          final yy = y - (x - w / 2) * t;
          if (yy % 28 < 5 && x % 37 < 30 && x > 60 && x < w - 60) g[y * w + x] = 30;
        }
      }
      return g;
    }

    test('đo đúng độ dốc dòng chữ (±0,15°)', () {
      for (final a in [0.0, 1.2, -3.7, 6.5, -11.0]) {
        final s = estimateSkew(lines(800, 1000, a), 800, 1000);
        expect(s.angle, closeTo(a, 0.15), reason: 'góc $a');
      }
    });

    test('xoay theo góc hiệu chỉnh → dòng chữ nằm ngang', () {
      const w = 800, h = 1000;
      final g = lines(w, h, 5);
      final s = estimateSkew(g, w, h);
      expect(s.reliable, isTrue);
      final rgb = Uint8List(w * h * 3);
      for (var i = 0; i < w * h; i++) {
        rgb[i * 3] = rgb[i * 3 + 1] = rgb[i * 3 + 2] = g[i];
      }
      final out = rotateFineRgb(rgb, w, h, s.correction);
      final g2 = Uint8List(w * h);
      for (var i = 0; i < w * h; i++) {
        g2[i] = out[i * 3];
      }
      expect(estimateSkew(g2, w, h).angle.abs(), lessThan(0.2));
    });
  });

  test('warp bicubic đồng nhất giữ nguyên pixel', () {
    const w = 9, h = 7;
    final src = Uint8List.fromList(List.generate(w * h * 3, (i) => (i * 53) % 256));
    final out = warpPerspectiveRgb(src, w, h, Quad.fullFrame(w - 1.0, h - 1.0), w, h,
        bicubic: true);
    expect(out, equals(src));
  });
}
