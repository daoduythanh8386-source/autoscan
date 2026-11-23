import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:smart_document_scanner/core/dewarp.dart';
import 'package:smart_document_scanner/core/geometry.dart';

List<double> _norm(List<double> a) {
  final l = math.sqrt(a[0] * a[0] + a[1] * a[1] + a[2] * a[2]);
  return [a[0] / l, a[1] / l, a[2] / l];
}

List<double> _cross(List<double> a, List<double> b) =>
    [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]];

/// Trang thật: mặt phẳng nghiêng + mép quăn (mô hình trụ) nhìn qua camera f=1500.
CylinderModel truthModel(int rot) {
  final dx = _norm([1, 0.06, 0.12]);
  var dy = _norm([0.02, 1, -0.35]);
  // trực chuẩn hoá
  final d = dy[0] * dx[0] + dy[1] * dx[1] + dy[2] * dx[2];
  dy = _norm([dy[0] - d * dx[0], dy[1] - d * dx[1], dy[2] - d * dx[2]]);
  final n = _cross(dx, dy);
  return CylinderModel(
    f: 1500,
    cx: 750,
    cy: 1000,
    ptl: [-0.45, -0.62, 2.2],
    dx: dx,
    dy: dy,
    n: n,
    y0: 1.05,
    c2: -0.35,
    c3: -0.2,
    yMax: 1.38,
    rot: rot,
  );
}

List<EdgeSample> samplesFrom(DewarpModel m) {
  final out = <EdgeSample>[];
  for (var i = 0; i <= 160; i++) {
    final t = 0.01 + 0.98 * i / 160;
    out.add(EdgeSample(Side.top, t, m.map(t, 0)));
    out.add(EdgeSample(Side.bottom, t, m.map(t, 1)));
    out.add(EdgeSample(Side.left, t, m.map(0, t)));
    out.add(EdgeSample(Side.right, t, m.map(1, t)));
  }
  return out;
}

void main() {
  group('Mô hình 3D mép quăn: dựng lại từ đường mép', () {
    for (final (curl, rot) in [
      (Side.bottom, 0),
      (Side.top, 2),
      (Side.left, 1),
      (Side.right, 3),
    ]) {
      test('quăn ở ${curl.name}: sai số ánh xạ < 1,5 px, tỷ lệ < 1%', () {
        final truth = truthModel(rot);
        final corners =
            Quad.ordered([truth.map(0, 0), truth.map(1, 0), truth.map(1, 1), truth.map(0, 1)]);
        final m = buildCylinder(
            samples: samplesFrom(truth),
            curl: curl,
            corners: corners,
            focal: 1500,
            imgW: 1500,
            imgH: 2000);
        expect(m, isNotNull);
        var worst = 0.0;
        for (var i = 1; i < 10; i++) {
          for (var j = 1; j < 10; j++) {
            final a = truth.map(i / 10, j / 10), b = m!.map(i / 10, j / 10);
            worst = math.max(worst, a.dist(b));
          }
        }
        expect(worst, lessThan(1.5));
        expect((m!.measuredAspect / truth.measuredAspect - 1).abs(), lessThan(0.01));
      });
    }

    test('phân loại hướng quăn từ độ lệch mép', () {
      Float64List z() => Float64List(kCurveSamples);
      final devs = {for (final s in Side.values) s: z()};
      for (var i = 0; i < kCurveSamples; i++) {
        final t = i / (kCurveSamples - 1);
        final bump = t > 0.75 ? 0.04 * (t - 0.75) / 0.25 : 0.0;
        devs[Side.left]![i] = -bump;
        devs[Side.right]![i] = bump;
      }
      expect(classifyCurl(devs), (Side.bottom, false));
      final flat = {for (final s in Side.values) s: z()};
      expect(classifyCurl(flat).$1, isNull);
    });
  });

  test('Coons với độ lệch 0 trùng homography', () {
    final q = Quad.ordered([Pt(100, 120), Pt(900, 90), Pt(950, 1300), Pt(80, 1250)]);
    final devs = {for (final s in Side.values) s: Float64List(kCurveSamples)};
    final m = CoonsModel(q, devs, 0.7);
    final h = unitToImage(q);
    for (final (u, v) in [(0.0, 0.0), (0.3, 0.7), (1.0, 1.0), (0.5, 0.5)]) {
      expect(m.map(u, v).dist(h.apply(u, v)), lessThan(1e-6));
    }
  });

  test('đa thức bền vững bỏ qua điểm ngoại lai', () {
    final t = [for (var i = 0; i < 50; i++) i / 49];
    final d = [for (final x in t) 0.02 * x * x - 0.01 * x];
    d[10] = 0.5; // ngoại lai
    final c = polyfitRobust(t, d);
    expect(polyval(c, 0.5), closeTo(0.02 * 0.25 - 0.005, 1e-4));
  });
}
