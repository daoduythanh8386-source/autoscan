import 'dart:math' as math;
import 'dart:typed_data';

import 'geometry.dart';
import 'rectify.dart';

/// NẮN GIẤY CONG / CONG MÉP (port từ tools/sim/curve.py + curl3d.py đã kiểm chứng).
///
/// 1. Lấy đường cong thật của 4 mép giấy: khởi tạo từ biên mặt nạ nhận diện, rồi
///    dò gradient ở độ phân giải đầy đủ quanh đường cong dự đoán, khớp đa thức bậc 4.
/// 2. Phân loại:
///    - Phẳng (lệch < 0,6%)                       → homography thường.
///    - Quăn 1 mép / gáy sách (cong ở 1 đầu)      → [CylinderModel]: dựng lại tư thế 3D
///      của mặt giấy + mặt cắt cong thật → trải phẳng theo độ dài cung.
///    - Cong phức tạp (gợn sóng, gấp)            → [CoonsModel]: lưới Coons theo 4 mép cong.
///
/// Chỉ thay đổi VỊ TRÍ lấy mẫu điểm ảnh (hình học); không vẽ thêm, không sửa nét mực.

const int kCurveSamples = 33;
const double kCurlThreshold = 0.006; // 0,6% kích thước trang

enum Side { top, right, bottom, left }

// ------------------------------------------------------------- tiện ích

/// Khớp đa thức bậc [deg] bình phương nhỏ nhất, loại ngoại lai 3 vòng.
List<double> polyfitRobust(List<double> t, List<double> d, {int deg = 4}) {
  var keep = List<bool>.filled(t.length, true);
  var c = _polyfit(t, d, deg);
  for (var it = 0; it < 3; it++) {
    final res = [for (var i = 0; i < t.length; i++) (polyval(c, t[i]) - d[i]).abs()];
    final kept = [for (var i = 0; i < t.length; i++) if (keep[i]) res[i]]..sort();
    if (kept.isEmpty) break;
    final thr = math.max(kept[kept.length ~/ 2] * 3, 1e-3);
    final nk = [for (final r in res) r <= thr];
    final nt = <double>[], nd = <double>[];
    for (var i = 0; i < t.length; i++) {
      if (nk[i]) {
        nt.add(t[i]);
        nd.add(d[i]);
      }
    }
    if (nt.length < deg + 3) break;
    keep = nk;
    c = _polyfit(nt, nd, deg);
  }
  return c;
}

List<double> _polyfit(List<double> t, List<double> d, int deg) {
  final n = deg + 1;
  if (t.length < n) return List<double>.filled(n, 0);
  final a = List.generate(n, (_) => Float64List(n + 1));
  for (var i = 0; i < t.length; i++) {
    final pw = Float64List(2 * n);
    pw[0] = 1;
    for (var k = 1; k < 2 * n; k++) {
      pw[k] = pw[k - 1] * t[i];
    }
    for (var r = 0; r < n; r++) {
      for (var c = 0; c < n; c++) {
        a[r][c] += pw[r + c];
      }
      a[r][n] += pw[r] * d[i];
    }
  }
  // Gauss
  for (var c = 0; c < n; c++) {
    var p = c;
    for (var r = c + 1; r < n; r++) {
      if (a[r][c].abs() > a[p][c].abs()) p = r;
    }
    final tmp = a[c];
    a[c] = a[p];
    a[p] = tmp;
    if (a[c][c].abs() < 1e-14) return List<double>.filled(n, 0);
    for (var r = 0; r < n; r++) {
      if (r == c) continue;
      final f = a[r][c] / a[c][c];
      for (var k = c; k <= n; k++) {
        a[r][k] -= f * a[c][k];
      }
    }
  }
  // hệ số theo bậc tăng dần: c0 + c1 t + ...
  return [for (var i = 0; i < n; i++) a[i][n] / a[i][i]];
}

double polyval(List<double> c, double t) {
  var v = 0.0;
  for (var i = c.length - 1; i >= 0; i--) {
    v = v * t + c[i];
  }
  return v;
}

Homography unitToImage(Quad q) =>
    Homography.fromPoints([Pt(0, 0), Pt(1, 0), Pt(1, 1), Pt(0, 1)], q.pts);
Homography imageToUnit(Quad q) =>
    Homography.fromPoints(q.pts, [Pt(0, 0), Pt(1, 0), Pt(1, 1), Pt(0, 1)]);

/// (tham số t, giá trị lệch) → toạ độ đơn vị của mép [s].
Pt _unitOnSide(Side s, double t, double dev) => switch (s) {
      Side.top => Pt(t, dev),
      Side.bottom => Pt(t, 1 + dev),
      Side.left => Pt(dev, t),
      Side.right => Pt(1 + dev, t),
    };

(double, double) _unitToSide(Side s, Pt uv) => switch (s) {
      Side.top => (uv.x, uv.y),
      Side.bottom => (uv.x, uv.y - 1),
      Side.left => (uv.y, uv.x),
      Side.right => (uv.y, uv.x - 1),
    };

// ------------------------------------------------------- đường cong 4 mép

typedef SideCoefs = Map<Side, List<double>>;

/// Khởi tạo đường cong từ biên mặt nạ (toạ độ ảnh đầy đủ).
SideCoefs curvesFromBoundary(List<Pt> boundary, Quad q) {
  final inv = imageToUnit(q);
  final ts = {for (final s in Side.values) s: <double>[]};
  final ds = {for (final s in Side.values) s: <double>[]};
  for (final p in boundary) {
    final uv = inv.apply(p.x, p.y);
    for (final s in Side.values) {
      final (t, d) = _unitToSide(s, uv);
      if (t > 0.03 && t < 0.97 && d.abs() < 0.15) {
        ts[s]!.add(t);
        ds[s]!.add(d);
      }
    }
  }
  return {
    for (final s in Side.values)
      s: ts[s]!.length > 10 ? polyfitRobust(ts[s]!, ds[s]!) : List<double>.filled(5, 0)
  };
}

class EdgeSample {
  final Side side;
  final double t;
  final Pt p;
  const EdgeSample(this.side, this.t, this.p);
}

/// Dò mép thật ở độ phân giải đầy đủ quanh đường cong dự đoán.
List<EdgeSample> _probeEdges(Uint8List g, int w, int h, Quad q, SideCoefs pred, double r,
    {int k = 120, double t0 = 0.02, double t1 = 0.98}) {
  final hu = unitToImage(q);
  final cen = hu.apply(0.5, 0.5);
  final steps = r.floor();
  final prof = Float64List(2 * steps + 1), grad = Float64List(2 * steps + 1);
  final out = <EdgeSample>[];
  for (final s in Side.values) {
    final c = pred[s]!;
    final found = {1: <EdgeSample>[], -1: <EdgeSample>[]};
    final score = {1: 0.0, -1: 0.0};
    double? flip;
    for (var j = 0; j < k; j++) {
      final t = t0 + (t1 - t0) * j / (k - 1);
      final dev = polyval(c, t);
      final uv = _unitOnSide(s, t, dev);
      final uv2 = _unitOnSide(s, t, dev + 1e-3);
      final p = hu.apply(uv.x, uv.y), p2 = hu.apply(uv2.x, uv2.y);
      var nx = p2.x - p.x, ny = p2.y - p.y;
      final nl = math.sqrt(nx * nx + ny * ny);
      if (nl < 1e-12) continue;
      nx /= nl;
      ny /= nl;
      flip ??= ((cen.x - p.x) * nx + (cen.y - p.y) * ny) < 0 ? -1.0 : 1.0;
      nx *= flip;
      ny *= flip;
      for (var o = -steps; o <= steps; o++) {
        prof[o + steps] = _sampleGray(g, w, h, p.x + nx * o, p.y + ny * o);
      }
      for (var o = 1; o < prof.length - 1; o++) {
        grad[o] = (prof[o + 1] - prof[o - 1]) / 2;
      }
      for (final sg in const [1, -1]) {
        var bi = -1;
        var bv = 4.0;
        for (var o = 2; o < prof.length - 2; o++) {
          final v = grad[o] * sg;
          if (v > bv) {
            bv = v;
            bi = o;
          }
        }
        if (bi < 0) continue;
        final a = grad[bi - 1] * sg, cc = grad[bi + 1] * sg;
        final den = a - 2 * bv + cc;
        final sub = (den.abs() > 1e-9 ? 0.5 * (a - cc) / den : 0.0).clamp(-0.5, 0.5);
        final d = bi - steps + sub;
        found[sg]!.add(EdgeSample(s, t, Pt(p.x + nx * d, p.y + ny * d)));
        score[sg] = score[sg]! + bv;
      }
    }
    final sg = score[1]! >= score[-1]! ? 1 : -1;
    if (found[sg]!.length >= k * 0.4) out.addAll(found[sg]!);
  }
  return out;
}

double _sampleGray(Uint8List g, int w, int h, double x, double y) {
  if (x < 0) x = 0;
  if (y < 0) y = 0;
  if (x > w - 1.001) x = w - 1.001;
  if (y > h - 1.001) y = h - 1.001;
  final x0 = x.floor(), y0 = y.floor();
  final fx = x - x0, fy = y - y0;
  final i = y0 * w + x0;
  final a = g[i] + (g[i + 1] - g[i]) * fx;
  final b = g[i + w] + (g[i + w + 1] - g[i + w]) * fx;
  return a + (b - a) * fy;
}

SideCoefs _refineCurves(Uint8List g, int w, int h, Quad q, SideCoefs pred, double r) {
  final samples = _probeEdges(g, w, h, q, pred, r);
  final inv = imageToUnit(q);
  final res = <Side, List<double>>{};
  for (final s in Side.values) {
    final ts = <double>[], ds = <double>[];
    for (final e in samples.where((e) => e.side == s)) {
      final (t, d) = _unitToSide(s, inv.apply(e.p.x, e.p.y));
      ts.add(t);
      ds.add(d);
    }
    res[s] = ts.length > 12 ? polyfitRobust(ts, ds) : pred[s]!;
  }
  return res;
}

Quad _updateCorners(Quad q, SideCoefs c) {
  final hu = unitToImage(q);
  final pts = [
    Pt(0 + polyval(c[Side.left]!, 0), 0 + polyval(c[Side.top]!, 0)),
    Pt(1 + polyval(c[Side.right]!, 0), 0 + polyval(c[Side.top]!, 1)),
    Pt(1 + polyval(c[Side.right]!, 1), 1 + polyval(c[Side.bottom]!, 1)),
    Pt(0 + polyval(c[Side.left]!, 1), 1 + polyval(c[Side.bottom]!, 0)),
  ];
  return Quad.ordered([for (final p in pts) hu.apply(p.x, p.y)]);
}

/// Bỏ phần tuyến tính: độ lệch = 0 ở 2 đầu mỗi mép (góc nằm đúng trên đường cong).
SideCoefs _detrend(SideCoefs c) => {
      for (final e in c.entries)
        e.key: () {
          final a = polyval(e.value, 0), b = polyval(e.value, 1);
          final n = [...e.value];
          n[0] -= a;
          n[1] -= (b - a);
          return n;
        }()
    };

Map<Side, Float64List> _sampleDevs(SideCoefs c) => {
      for (final e in c.entries)
        e.key: Float64List.fromList([
          for (var i = 0; i < kCurveSamples; i++) polyval(e.value, i / (kCurveSamples - 1))
        ])
    };

// ---------------------------------------------------------------- mô hình

abstract class DewarpModel {
  /// Toạ độ đầu ra chuẩn hoá (u, v ∈ [0,1]) → điểm ảnh nguồn.
  Pt map(double u, double v);

  /// Tỷ lệ rộng/cao đo được của trang (trước khi khớp khổ).
  double get measuredAspect;
  Map<String, dynamic> toJson();

  static DewarpModel? fromJson(Map<String, dynamic>? j) {
    if (j == null) return null;
    switch (j['type']) {
      case 'coons':
        return CoonsModel.fromJson(j);
      case 'cyl':
        return CylinderModel.fromJson(j);
    }
    return null;
  }

  /// Mô hình đã thu nhỏ theo hệ số [s] (dùng cho ảnh xem trước).
  DewarpModel scaled(double s) => _ScaledModel(this, s);
}

class _ScaledModel extends DewarpModel {
  final DewarpModel base;
  final double s;
  _ScaledModel(this.base, this.s);
  @override
  Pt map(double u, double v) => base.map(u, v).scale(s);
  @override
  double get measuredAspect => base.measuredAspect;
  @override
  Map<String, dynamic> toJson() => base.toJson();
}

/// Lưới Coons trên nền homography: P(u,v) = H( u + (1-u)·ℓ(v) + u·r(v),
///                                             v + (1-v)·t(u) + v·b(u) ).
class CoonsModel extends DewarpModel {
  final Quad quad;
  final Map<Side, Float64List> devs;
  final double aspect;
  late final Homography _h = unitToImage(quad);

  CoonsModel(this.quad, this.devs, this.aspect);

  static double _interp(Float64List d, double t) {
    final f = (t.clamp(0.0, 1.0)) * (d.length - 1);
    final i = f.floor().clamp(0, d.length - 2);
    final a = f - i;
    return d[i] + (d[i + 1] - d[i]) * a;
  }

  @override
  Pt map(double u, double v) {
    final x = u + (1 - u) * _interp(devs[Side.left]!, v) + u * _interp(devs[Side.right]!, v);
    final y = v + (1 - v) * _interp(devs[Side.top]!, u) + v * _interp(devs[Side.bottom]!, u);
    return _h.apply(x, y);
  }

  @override
  double get measuredAspect => aspect;

  @override
  Map<String, dynamic> toJson() => {
        'type': 'coons',
        'quad': quad.toJson(),
        'aspect': aspect,
        for (final e in devs.entries) e.key.name: e.value.toList(),
      };

  factory CoonsModel.fromJson(Map<String, dynamic> j) => CoonsModel(
        Quad.fromJson(j['quad'] as List<dynamic>),
        {
          for (final s in Side.values)
            s: Float64List.fromList([for (final v in j[s.name] as List<dynamic>) (v as num).toDouble()])
        },
        (j['aspect'] as num).toDouble(),
      );
}

/// Mặt giấy = phần phẳng + phần uốn trụ quanh trục song song 1 cạnh.
/// Khung chuẩn: chỗ quăn ở "dưới"; [rot] = số lần xoay 90° (chiều kim đồng hồ)
/// để đưa ảnh khung chuẩn về hướng gốc.
class CylinderModel extends DewarpModel {
  final double f, cx, cy;
  final List<double> ptl, dx, dy, n; // vector 3D (hệ camera)
  final double y0, c2, c3, yMax; // mặt cắt: Z = c2 (Y-y0)^2 + c3 (Y-y0)^3 khi Y > y0
  final int rot;
  late final Float64List _ys, _ss;

  CylinderModel({
    required this.f,
    required this.cx,
    required this.cy,
    required this.ptl,
    required this.dx,
    required this.dy,
    required this.n,
    required this.y0,
    required this.c2,
    required this.c3,
    required this.yMax,
    required this.rot,
  }) {
    const m = 400;
    _ys = Float64List(m + 1);
    _ss = Float64List(m + 1);
    for (var i = 0; i <= m; i++) {
      _ys[i] = yMax * i / m;
      if (i > 0) {
        final dz = z(_ys[i]) - z(_ys[i - 1]);
        final dyy = _ys[i] - _ys[i - 1];
        _ss[i] = _ss[i - 1] + math.sqrt(dyy * dyy + dz * dz);
      }
    }
  }

  double z(double y) {
    final d = y - y0;
    return d <= 0 ? 0 : c2 * d * d + c3 * d * d * d;
  }

  /// Độ dài trang (theo đơn vị bề rộng = 1) trong khung chuẩn.
  double get length => _ss.last;

  /// Độ cao phần quăn lớn nhất (đơn vị bề rộng).
  double get lift => z(yMax).abs();

  double _yFromS(double s) {
    if (s <= 0) return 0;
    if (s >= _ss.last) return _ys.last;
    var lo = 0, hi = _ss.length - 1;
    while (hi - lo > 1) {
      final mid = (lo + hi) >> 1;
      if (_ss[mid] < s) {
        lo = mid;
      } else {
        hi = mid;
      }
    }
    final a = (s - _ss[lo]) / (_ss[hi] - _ss[lo]);
    return _ys[lo] + (_ys[hi] - _ys[lo]) * a;
  }

  /// Toạ độ khung chuẩn (X ∈ [0,1], S ∈ [0,length]) → ảnh.
  Pt mapCanonical(double x, double s) {
    final y = _yFromS(s), zz = z(y);
    final px = ptl[0] + x * dx[0] + y * dy[0] + zz * n[0];
    final py = ptl[1] + x * dx[1] + y * dy[1] + zz * n[1];
    final pz = ptl[2] + x * dx[2] + y * dy[2] + zz * n[2];
    return Pt(f * px / pz + cx, f * py / pz + cy);
  }

  @override
  Pt map(double u, double v) {
    // (u,v) theo hướng gốc → (cu, cv) khung chuẩn; khung chuẩn được xoay [rot]
    // lần 90° theo chiều kim đồng hồ để ra hướng gốc.
    double cu, cv;
    switch (rot % 4) {
      case 0:
        cu = u;
        cv = v;
        break;
      case 1: // gốc = chuẩn xoay 90° CW: (u,v) = (1-cv, cu)
        cu = v;
        cv = 1 - u;
        break;
      case 2:
        cu = 1 - u;
        cv = 1 - v;
        break;
      default: // 3: (u,v) = (cv, 1-cu)
        cu = 1 - v;
        cv = u;
    }
    return mapCanonical(cu, cv * length);
  }

  @override
  double get measuredAspect => rot.isOdd ? length : 1 / length;

  @override
  Map<String, dynamic> toJson() => {
        'type': 'cyl',
        'f': f,
        'cx': cx,
        'cy': cy,
        'ptl': ptl,
        'dx': dx,
        'dy': dy,
        'n': n,
        'y0': y0,
        'c2': c2,
        'c3': c3,
        'yMax': yMax,
        'rot': rot,
      };

  factory CylinderModel.fromJson(Map<String, dynamic> j) {
    List<double> v(String k) => [for (final e in j[k] as List<dynamic>) (e as num).toDouble()];
    double d(String k) => (j[k] as num).toDouble();
    return CylinderModel(
      f: d('f'),
      cx: d('cx'),
      cy: d('cy'),
      ptl: v('ptl'),
      dx: v('dx'),
      dy: v('dy'),
      n: v('n'),
      y0: d('y0'),
      c2: d('c2'),
      c3: d('c3'),
      yMax: d('yMax'),
      rot: (j['rot'] as num).toInt(),
    );
  }
}

// -------------------------------------------------- dựng mô hình 3D trụ

List<double> _v3(double a, double b, double c) => [a, b, c];
double _dot3(List<double> a, List<double> b) => a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
List<double> _cross3(List<double> a, List<double> b) =>
    [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]];
List<double> _scale3(List<double> a, double s) => [a[0] * s, a[1] * s, a[2] * s];
List<double> _sub3(List<double> a, List<double> b) => [a[0] - b[0], a[1] - b[1], a[2] - b[2]];
List<double> _add3(List<double> a, List<double> b) => [a[0] + b[0], a[1] + b[1], a[2] + b[2]];
List<double> _norm3(List<double> a) {
  final l = math.sqrt(_dot3(a, a));
  return l < 1e-15 ? a : _scale3(a, 1 / l);
}

/// Đường thẳng đồng nhất khớp tập điểm.
List<double>? _lineH(List<Pt> pts) {
  if (pts.length < 3) return null;
  var cx = 0.0, cy = 0.0;
  for (final p in pts) {
    cx += p.x;
    cy += p.y;
  }
  cx /= pts.length;
  cy /= pts.length;
  var sxx = 0.0, sxy = 0.0, syy = 0.0;
  for (final p in pts) {
    sxx += (p.x - cx) * (p.x - cx);
    sxy += (p.x - cx) * (p.y - cy);
    syy += (p.y - cy) * (p.y - cy);
  }
  final th = 0.5 * math.atan2(2 * sxy, sxx - syy);
  final nx = -math.sin(th), ny = math.cos(th);
  return [nx, ny, -(nx * cx + ny * cy)];
}

/// Nhãn cạnh khung chuẩn (top, right, bottom, left) và cạnh gốc tương ứng,
/// kèm cờ đảo chiều tham số, cho từng hướng quăn.
const _canon = {
  Side.bottom: ([Side.top, Side.right, Side.bottom, Side.left], [false, false, false, false], 0),
  Side.top: ([Side.bottom, Side.left, Side.top, Side.right], [true, true, true, true], 2),
  Side.left: ([Side.right, Side.bottom, Side.left, Side.top], [false, true, false, true], 1),
  Side.right: ([Side.left, Side.top, Side.right, Side.bottom], [true, false, true, false], 3),
};

int _cornerIndex(Side a, Side b) {
  final s = {a, b};
  if (s.containsAll([Side.top, Side.left])) return 0;
  if (s.containsAll([Side.top, Side.right])) return 1;
  if (s.containsAll([Side.right, Side.bottom])) return 2;
  return 3;
}

/// Phát hiện mép quăn từ độ lệch 2 cạnh vuông góc ở cùng 1 đầu.
/// Trả về (mép quăn, phức tạp?).
(Side?, bool) classifyCurl(Map<Side, Float64List> devs) {
  double endMax(Side s, bool atStart) {
    final d = devs[s]!;
    var m = 0.0;
    for (var i = 0; i < 10; i++) {
      final v = d[atStart ? i : d.length - 1 - i].abs();
      if (v > m) m = v;
    }
    return m;
  }

  final sc = {
    Side.bottom: math.max(endMax(Side.left, false), endMax(Side.right, false)),
    Side.top: math.max(endMax(Side.left, true), endMax(Side.right, true)),
    Side.left: math.max(endMax(Side.top, true), endMax(Side.bottom, true)),
    Side.right: math.max(endMax(Side.top, false), endMax(Side.bottom, false)),
  };
  var best = Side.bottom;
  for (final e in sc.entries) {
    if (e.value > sc[best]!) best = e.key;
  }
  if (sc[best]! < kCurlThreshold) return (null, false);
  for (final e in sc.entries) {
    if (e.key != best && e.value > 0.6 * sc[best]!) return (best, true);
  }
  return (best, false);
}

CylinderModel? buildCylinder({
  required List<EdgeSample> samples,
  required Side curl,
  required Quad corners,
  required double focal,
  required int imgW,
  required int imgH,
  double flatUntil = 0.55,
}) {
  final (names, rev, rot) = _canon[curl]!;
  List<(double, Pt)> sideOf(int idx) {
    final s = names[idx];
    return [
      for (final e in samples.where((e) => e.side == s)) (rev[idx] ? 1 - e.t : e.t, e.p)
    ];
  }

  final top = sideOf(0), right = sideOf(1), left = sideOf(3);
  if (top.length < 20 || right.length < 20 || left.length < 20) return null;
  final lt = _lineH([for (final e in top) e.$2]);
  final ll = _lineH([for (final e in left) if (e.$1 < flatUntil) e.$2]);
  final lr = _lineH([for (final e in right) if (e.$1 < flatUntil) e.$2]);
  if (lt == null || ll == null || lr == null) return null;
  final cx = imgW / 2, cy = imgH / 2;
  List<double> kinv(List<double> p) => [(p[0] - cx * p[2]) / focal, (p[1] - cy * p[2]) / focal, p[2]];
  var tl = _cross3(lt, ll), tr = _cross3(lt, lr);
  final vy = _cross3(ll, lr);
  if (tl[2].abs() < 1e-12 || tr[2].abs() < 1e-12) return null;
  tl = _scale3(tl, 1 / tl[2]);
  tr = _scale3(tr, 1 / tr[2]);
  // Điểm tụ trục X nằm trên cạnh trên và trực giao với trục Y qua ω = K^-T K^-1.
  final ktl = kinv(tl), ktr = kinv(tr), kvy = kinv(vy);
  final a = _dot3(ktr, kvy), b = -_dot3(ktl, kvy);
  var dX = _norm3(_add3(_scale3(ktl, a), _scale3(ktr, b)));
  var dY = _norm3(kvy);
  final rtl = ktl, rtr = ktr;
  final dirTlTr = _sub3(_scale3(rtr, 1 / rtr[2]), _scale3(rtl, 1 / rtl[2]));
  if (_dot3(dX, dirTlTr) < 0) dX = _scale3(dX, -1);
  // s·rtl + dX = t·rtr  (bình phương nhỏ nhất 3x2)
  final a11 = _dot3(rtl, rtl), a12 = -_dot3(rtl, rtr), a22 = _dot3(rtr, rtr);
  final b1 = -_dot3(rtl, dX), b2 = _dot3(rtr, dX);
  final det = a11 * a22 - a12 * a12;
  if (det.abs() < 1e-15) return null;
  final sTl = (b1 * a22 - a12 * b2) / det;
  final ptl = _scale3(rtl, sTl);
  if (ptl[2] <= 0) return null;
  // Hướng Y: về phía các điểm cạnh trái.
  final mid = left[left.length ~/ 2].$2;
  final rl = kinv([mid.x, mid.y, 1]);
  final den0 = _dot3(rl, dX);
  if (den0.abs() > 1e-12) {
    final lam = _dot3(ptl, dX) / den0;
    if (_dot3(_sub3(_scale3(rl, lam), ptl), dY) < 0) dY = _scale3(dY, -1);
  }
  dY = _norm3(_sub3(dY, _scale3(dX, _dot3(dY, dX))));
  final nn = _cross3(dX, dY);

  (double, double)? backProject(Pt p, double x0) {
    final r = kinv([p.x, p.y, 1]);
    final den = _dot3(r, dX);
    if (den.abs() < 1e-12) return null;
    final lam = (_dot3(ptl, dX) + x0) / den;
    final q = _sub3(_scale3(r, lam), ptl);
    return (_dot3(q, dY), _dot3(q, nn));
  }

  final ys = <double>[], zs = <double>[];
  for (final e in left) {
    final r = backProject(e.$2, 0);
    if (r != null) {
      ys.add(r.$1);
      zs.add(r.$2);
    }
  }
  for (final e in right) {
    final r = backProject(e.$2, 1);
    if (r != null) {
      ys.add(r.$1);
      zs.add(r.$2);
    }
  }
  // Góc ở đầu quăn xác định chính xác điểm kết thúc trang.
  final bl = corners.pts[_cornerIndex(names[2], names[3])];
  final br = corners.pts[_cornerIndex(names[1], names[2])];
  var yEnd = 0.0;
  for (final (c, x0) in [(bl, 0.0), (br, 1.0)]) {
    final r = backProject(c, x0);
    if (r != null) {
      ys.add(r.$1);
      zs.add(r.$2);
      yEnd = math.max(yEnd, r.$1);
    }
  }
  if (ys.length < 30 || yEnd <= 0) return null;
  final yMax = yEnd;
  final flat = [for (var i = 0; i < ys.length; i++) if (ys[i] < yMax * 0.4) zs[i]]..sort();
  final flatZ = flat.isEmpty ? 0.0 : flat[flat.length ~/ 2];
  for (var i = 0; i < zs.length; i++) {
    zs[i] -= flatZ;
  }
  // Mặt cắt: phẳng tới y0 rồi Z = c2 d² + c3 d³; chọn y0 tốt nhất (sai số bị chặn).
  var best = (double.infinity, 0.0, 0.0, yMax);
  const cap = 0.004 * 0.004;
  for (var k = 0; k < 68; k++) {
    final y0 = yMax * (0.3 + 0.67 * k / 67);
    var s22 = 0.0, s23 = 0.0, s33 = 0.0, sz2 = 0.0, sz3 = 0.0;
    var cnt = 0;
    for (var i = 0; i < ys.length; i++) {
      final d = ys[i] - y0;
      if (d <= 0) continue;
      final d2 = d * d, d3 = d2 * d;
      s22 += d2 * d2;
      s23 += d2 * d3;
      s33 += d3 * d3;
      sz2 += d2 * zs[i];
      sz3 += d3 * zs[i];
      cnt++;
    }
    if (cnt < 8) continue;
    final dd = s22 * s33 - s23 * s23;
    if (dd.abs() < 1e-30) continue;
    final c2 = (sz2 * s33 - s23 * sz3) / dd;
    final c3 = (s22 * sz3 - s23 * sz2) / dd;
    var sse = 0.0;
    for (var i = 0; i < ys.length; i++) {
      final d = ys[i] - y0;
      final pred = d <= 0 ? 0.0 : c2 * d * d + c3 * d * d * d;
      sse += math.min((pred - zs[i]) * (pred - zs[i]), cap);
    }
    if (sse < best.$1) best = (sse, c2, c3, y0);
  }
  if (best.$1 == double.infinity) return null;
  final model = CylinderModel(
    f: focal,
    cx: cx,
    cy: cy,
    ptl: ptl,
    dx: dX,
    dy: dY,
    n: nn,
    y0: best.$4,
    c2: best.$2,
    c3: best.$3,
    yMax: yMax,
    rot: rot,
  );
  // Kiểm tra hợp lý: độ dài trang 0,3–4 lần bề rộng.
  if (!model.length.isFinite || model.length < 0.3 || model.length > 4) return null;
  return model;
}

// ------------------------------------------------------------ điểm vào

class DewarpResult {
  final Quad corners;
  final DewarpModel? model; // null = phẳng
  final double curvature; // độ lệch mép lớn nhất (đơn vị trang)
  final String kind; // 'flat' | 'curl' | 'complex'
  const DewarpResult(this.corners, this.model, this.curvature, this.kind);
}

/// Phân tích độ cong của trang. [boundary] = biên mặt nạ nhận diện (toạ độ ảnh
/// đầy đủ, có thể rỗng); [q] = 4 góc đã tinh chỉnh; [focal] tiêu cự px.
DewarpResult analyzeCurvature(Uint8List gray, int w, int h, Quad q, List<Pt> boundary,
    {required double focal}) {
  final r = math.max(6.0, 0.012 * math.sqrt(w * w + h * h.toDouble()));
  var quad = q;
  var pred = boundary.length > 40
      ? _detrend(curvesFromBoundary(boundary, quad))
      : {for (final s in Side.values) s: List<double>.filled(5, 0)};
  for (var it = 0; it < 3; it++) {
    final c = _refineCurves(gray, w, h, quad, pred, r);
    final nq = _updateCorners(quad, c);
    if (!nq.isConvex || nq.area < 0.5 * quad.area) break;
    quad = nq;
    pred = _detrend(c);
  }
  final finalC = _detrend(_refineCurves(gray, w, h, quad, pred, r));
  final devs = _sampleDevs(finalC);
  var curv = 0.0;
  for (final d in devs.values) {
    for (final v in d) {
      curv = math.max(curv, v.abs());
    }
  }
  if (curv < kCurlThreshold) return DewarpResult(q, null, curv, 'flat');

  final (side, complex) = classifyCurl(devs);
  if (side != null && !complex) {
    final samples = _probeEdges(gray, w, h, quad, {
      for (final e in finalC.entries) e.key: e.value
    }, r, k: 160, t0: 0.01, t1: 0.99);
    final cyl = buildCylinder(
        samples: samples, curl: side, corners: quad, focal: focal, imgW: w, imgH: h);
    if (cyl != null) return DewarpResult(quad, cyl, curv, 'curl');
  }
  final aspect = estimateAspect(quad, w, h, focalPx: focal, paper: PaperSize.free).ratio;
  return DewarpResult(quad, CoonsModel(quad, devs, aspect), curv, 'complex');
}

/// Nắn ảnh RGB theo mô hình: điểm đầu ra (x, y) → mô hình (u, v) → nguồn.
Uint8List warpModelRgb(Uint8List src, int sw, int sh, DewarpModel m, int outW, int outH,
    {bool bicubic = false}) {
  final out = Uint8List(outW * outH * 3);
  final maxX = sw - 1, maxY = sh - 1;
  var o = 0;
  for (var y = 0; y < outH; y++) {
    final v = (y + 0.5) / outH;
    for (var x = 0; x < outW; x++) {
      final p = m.map((x + 0.5) / outW, v);
      var sx = p.x - 0.5, sy = p.y - 0.5;
      if (sx < 0) sx = 0;
      if (sy < 0) sy = 0;
      if (sx > maxX) sx = maxX.toDouble();
      if (sy > maxY) sy = maxY.toDouble();
      o = sampleRgbInto(src, sw, sh, sx, sy, out, o, bicubic: bicubic);
    }
  }
  return out;
}
