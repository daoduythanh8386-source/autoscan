import 'dart:math' as math;
import 'dart:typed_data';

/// Điểm 2D (toạ độ pixel, gốc trên-trái, trục y hướng xuống).
class Pt {
  final double x;
  final double y;
  const Pt(this.x, this.y);

  Pt operator +(Pt o) => Pt(x + o.x, y + o.y);
  Pt operator -(Pt o) => Pt(x - o.x, y - o.y);
  Pt scale(double s) => Pt(x * s, y * s);
  double dist(Pt o) => math.sqrt((x - o.x) * (x - o.x) + (y - o.y) * (y - o.y));

  List<double> toJson() => [x, y];
  static Pt fromJson(List<dynamic> j) => Pt((j[0] as num).toDouble(), (j[1] as num).toDouble());

  @override
  String toString() => 'Pt(${x.toStringAsFixed(1)}, ${y.toStringAsFixed(1)})';
}

/// Tứ giác tài liệu, luôn theo thứ tự: trên-trái, trên-phải, dưới-phải, dưới-trái.
class Quad {
  final List<Pt> pts;
  Quad._(this.pts);

  Pt get tl => pts[0];
  Pt get tr => pts[1];
  Pt get br => pts[2];
  Pt get bl => pts[3];

  /// Sắp xếp 4 điểm bất kỳ về thứ tự TL, TR, BR, BL.
  factory Quad.ordered(List<Pt> p) {
    assert(p.length == 4);
    final cx = p.fold<double>(0, (s, e) => s + e.x) / 4;
    final cy = p.fold<double>(0, (s, e) => s + e.y) / 4;
    final sorted = [...p]
      ..sort((a, b) => math.atan2(a.y - cy, a.x - cx).compareTo(math.atan2(b.y - cy, b.x - cx)));
    // Sắp theo góc tăng dần (theo chiều kim đồng hồ khi y hướng xuống).
    var start = 0;
    var best = double.infinity;
    for (var i = 0; i < 4; i++) {
      final s = sorted[i].x + sorted[i].y;
      if (s < best) {
        best = s;
        start = i;
      }
    }
    return Quad._([for (var i = 0; i < 4; i++) sorted[(start + i) % 4]]);
  }

  factory Quad.fullFrame(double w, double h) =>
      Quad._([Pt(0, 0), Pt(w, 0), Pt(w, h), Pt(0, h)]);

  Quad scaled(double s) => Quad._([for (final p in pts) p.scale(s)]);

  Quad withPoint(int i, Pt p) {
    final n = [...pts];
    n[i] = p;
    return Quad._(n);
  }

  Quad clampTo(double w, double h) => Quad._([
        for (final p in pts) Pt(p.x.clamp(0, w).toDouble(), p.y.clamp(0, h).toDouble())
      ]);

  double get area {
    var a = 0.0;
    for (var i = 0; i < 4; i++) {
      final p = pts[i], q = pts[(i + 1) % 4];
      a += p.x * q.y - q.x * p.y;
    }
    return a.abs() / 2;
  }

  /// Tứ giác lồi, không tự cắt.
  bool get isConvex {
    double? sign;
    for (var i = 0; i < 4; i++) {
      final a = pts[i], b = pts[(i + 1) % 4], c = pts[(i + 2) % 4];
      final cross = (b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x);
      if (cross.abs() < 1e-9) return false;
      final s = cross.sign;
      sign ??= s;
      if (s != sign) return false;
    }
    return true;
  }

  /// Góc trong nhỏ nhất (độ). Dùng để loại tứ giác quá méo.
  double get minAngleDeg {
    var m = 180.0;
    for (var i = 0; i < 4; i++) {
      final prev = pts[(i + 3) % 4], cur = pts[i], next = pts[(i + 1) % 4];
      final v1 = prev - cur, v2 = next - cur;
      final d = math.sqrt((v1.x * v1.x + v1.y * v1.y) * (v2.x * v2.x + v2.y * v2.y));
      if (d == 0) return 0;
      final cosA = ((v1.x * v2.x + v1.y * v2.y) / d).clamp(-1.0, 1.0);
      m = math.min(m, math.acos(cosA) * 180 / math.pi);
    }
    return m;
  }

  /// Kích thước đầu ra sau khi nắn phẳng: lấy cạnh dài hơn của mỗi cặp cạnh đối
  /// để KHÔNG thu nhỏ độ phân giải.
  (int, int) outputSize() {
    final w = math.max(tl.dist(tr), bl.dist(br));
    final h = math.max(tl.dist(bl), tr.dist(br));
    return (math.max(1, w.round()), math.max(1, h.round()));
  }

  double maxDisplacement(Quad o) {
    var m = 0.0;
    for (var i = 0; i < 4; i++) {
      m = math.max(m, pts[i].dist(o.pts[i]));
    }
    return m;
  }

  List<List<double>> toJson() => [for (final p in pts) p.toJson()];
  static Quad fromJson(List<dynamic> j) =>
      Quad._([for (final e in j) Pt.fromJson(e as List<dynamic>)]);

  @override
  String toString() => 'Quad($pts)';
}

/// Ma trận đồng nhất (homography) 3x3, lưu dạng hàng, h[8] = 1.
class Homography {
  final Float64List h;
  Homography(this.h);

  /// Tìm H sao cho H * src[i] = dst[i] (4 cặp điểm).
  static Homography fromPoints(List<Pt> src, List<Pt> dst) {
    final a = List.generate(8, (_) => Float64List(9));
    for (var i = 0; i < 4; i++) {
      final x = src[i].x, y = src[i].y, u = dst[i].x, v = dst[i].y;
      a[2 * i].setAll(0, [x, y, 1, 0, 0, 0, -u * x, -u * y, u]);
      a[2 * i + 1].setAll(0, [0, 0, 0, x, y, 1, -v * x, -v * y, v]);
    }
    // Khử Gauss với chọn trụ từng phần.
    for (var c = 0; c < 8; c++) {
      var piv = c;
      for (var r = c + 1; r < 8; r++) {
        if (a[r][c].abs() > a[piv][c].abs()) piv = r;
      }
      if (a[piv][c].abs() < 1e-12) {
        throw StateError('Homography suy biến (4 điểm thẳng hàng?)');
      }
      final t = a[c];
      a[c] = a[piv];
      a[piv] = t;
      for (var r = 0; r < 8; r++) {
        if (r == c) continue;
        final f = a[r][c] / a[c][c];
        if (f == 0) continue;
        for (var k = c; k < 9; k++) {
          a[r][k] -= f * a[c][k];
        }
      }
    }
    final h = Float64List(9);
    for (var i = 0; i < 8; i++) {
      h[i] = a[i][8] / a[i][i];
    }
    h[8] = 1;
    return Homography(h);
  }

  Pt apply(double x, double y) {
    final w = h[6] * x + h[7] * y + h[8];
    return Pt((h[0] * x + h[1] * y + h[2]) / w, (h[3] * x + h[4] * y + h[5]) / w);
  }
}

/// Nắn phối cảnh ảnh RGB (3 kênh, 8 bit) về hình chữ nhật [outW x outH].
/// Dùng ánh xạ ngược + nội suy song tuyến (bilinear) để không tạo răng cưa.
///
/// [bicubic] = true: nội suy Catmull-Rom (nét hơn cho chữ nhỏ) có kẹp giá trị
/// trong khoảng 4 điểm lân cận để KHÔNG tạo viền giả (overshoot/halo).
Uint8List warpPerspectiveRgb(
    Uint8List src, int sw, int sh, Quad quad, int outW, int outH, {bool bicubic = false}) {
  final dstRect = [
    Pt(0, 0),
    Pt(outW - 1.0, 0),
    Pt(outW - 1.0, outH - 1.0),
    Pt(0, outH - 1.0),
  ];
  final hm = Homography.fromPoints(dstRect, quad.pts).h;
  final out = Uint8List(outW * outH * 3);
  final maxX = sw - 1, maxY = sh - 1;
  var o = 0;
  for (var y = 0; y < outH; y++) {
    // Tính tăng dần theo x để tiết kiệm phép nhân.
    var nx = hm[1] * y + hm[2];
    var ny = hm[4] * y + hm[5];
    var nw = hm[7] * y + hm[8];
    for (var x = 0; x < outW; x++) {
      final w = nw;
      var sx = nx / w;
      var sy = ny / w;
      nx += hm[0];
      ny += hm[3];
      nw += hm[6];
      if (sx < 0) sx = 0;
      if (sy < 0) sy = 0;
      if (sx > maxX) sx = maxX.toDouble();
      if (sy > maxY) sy = maxY.toDouble();
      final x0 = sx.floor(), y0 = sy.floor();
      final x1 = x0 < maxX ? x0 + 1 : x0;
      final y1 = y0 < maxY ? y0 + 1 : y0;
      final fx = sx - x0, fy = sy - y0;
      final i00 = (y0 * sw + x0) * 3, i10 = (y0 * sw + x1) * 3;
      final i01 = (y1 * sw + x0) * 3, i11 = (y1 * sw + x1) * 3;
      if (bicubic) {
        _cubicWeights(fx, _wx);
        _cubicWeights(fy, _wy);
        for (var c = 0; c < 3; c++) {
          var acc = 0.0;
          for (var m = -1; m <= 2; m++) {
            final yy = (y0 + m).clamp(0, maxY);
            var row = 0.0;
            for (var n = -1; n <= 2; n++) {
              final xx = (x0 + n).clamp(0, maxX);
              row += src[(yy * sw + xx) * 3 + c] * _wx[n + 1];
            }
            acc += row * _wy[m + 1];
          }
          final a = src[i00 + c], b = src[i10 + c], d = src[i01 + c], e = src[i11 + c];
          final lo = math.min(math.min(a, b), math.min(d, e));
          final hi = math.max(math.max(a, b), math.max(d, e));
          out[o++] = acc.round().clamp(lo, hi);
        }
        continue;
      }
      for (var c = 0; c < 3; c++) {
        final top = src[i00 + c] + (src[i10 + c] - src[i00 + c]) * fx;
        final bot = src[i01 + c] + (src[i11 + c] - src[i01 + c]) * fx;
        out[o++] = (top + (bot - top) * fy + 0.5).toInt().clamp(0, 255);
      }
    }
  }
  return out;
}

final _wx = Float64List(4), _wy = Float64List(4);

/// Lấy mẫu 1 điểm RGB tại (sx, sy) (đã kẹp trong ảnh), ghi vào [out] từ vị trí [o].
/// Trả về vị trí ghi tiếp theo.
int sampleRgbInto(Uint8List src, int sw, int sh, double sx, double sy, Uint8List out, int o,
    {bool bicubic = false}) {
  final maxX = sw - 1, maxY = sh - 1;
  final x0 = sx.floor(), y0 = sy.floor();
  final x1 = x0 < maxX ? x0 + 1 : x0;
  final y1 = y0 < maxY ? y0 + 1 : y0;
  final fx = sx - x0, fy = sy - y0;
  final i00 = (y0 * sw + x0) * 3, i10 = (y0 * sw + x1) * 3;
  final i01 = (y1 * sw + x0) * 3, i11 = (y1 * sw + x1) * 3;
  if (bicubic) {
    _cubicWeights(fx, _wx);
    _cubicWeights(fy, _wy);
    for (var c = 0; c < 3; c++) {
      var acc = 0.0;
      for (var m = -1; m <= 2; m++) {
        final yy = (y0 + m).clamp(0, maxY);
        var row = 0.0;
        for (var n = -1; n <= 2; n++) {
          final xx = (x0 + n).clamp(0, maxX);
          row += src[(yy * sw + xx) * 3 + c] * _wx[n + 1];
        }
        acc += row * _wy[m + 1];
      }
      final a = src[i00 + c], b = src[i10 + c], d = src[i01 + c], e = src[i11 + c];
      final lo = math.min(math.min(a, b), math.min(d, e));
      final hi = math.max(math.max(a, b), math.max(d, e));
      out[o++] = acc.round().clamp(lo, hi);
    }
    return o;
  }
  for (var c = 0; c < 3; c++) {
    final top = src[i00 + c] + (src[i10 + c] - src[i00 + c]) * fx;
    final bot = src[i01 + c] + (src[i11 + c] - src[i01 + c]) * fx;
    out[o++] = (top + (bot - top) * fy + 0.5).toInt().clamp(0, 255);
  }
  return o;
}

/// Trọng số Catmull-Rom (a = -0.5) cho 4 điểm tại -1, 0, 1, 2.
void _cubicWeights(double t, Float64List w) {
  final t2 = t * t, t3 = t2 * t;
  w[0] = -0.5 * t3 + t2 - 0.5 * t;
  w[1] = 1.5 * t3 - 2.5 * t2 + 1;
  w[2] = -1.5 * t3 + 2 * t2 + 0.5 * t;
  w[3] = 0.5 * t3 - 0.5 * t2;
}

/// Xoay ảnh RGB theo bội số 90° chiều kim đồng hồ. Không mất dữ liệu.
(Uint8List, int, int) rotateRgb90(Uint8List src, int w, int h, int quarterTurns) {
  final q = quarterTurns % 4;
  if (q == 0) return (src, w, h);
  final nw = q.isOdd ? h : w, nh = q.isOdd ? w : h;
  final out = Uint8List(src.length);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      int dx, dy;
      switch (q) {
        case 1:
          dx = h - 1 - y;
          dy = x;
          break;
        case 2:
          dx = w - 1 - x;
          dy = h - 1 - y;
          break;
        default:
          dx = y;
          dy = w - 1 - x;
      }
      final si = (y * w + x) * 3, di = (dy * nw + dx) * 3;
      out[di] = src[si];
      out[di + 1] = src[si + 1];
      out[di + 2] = src[si + 2];
    }
  }
  return (out, nw, nh);
}
