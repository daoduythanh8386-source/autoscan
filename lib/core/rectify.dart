import 'dart:math' as math;
import 'dart:typed_data';

import 'geometry.dart';

/// Các bước làm tài liệu "vuông vắn như máy scan" (mục 7 đặc tả):
///
/// 1. [refineQuad]   – tinh chỉnh 4 cạnh ở ĐỘ PHÂN GIẢI ĐẦY ĐỦ: dò mép giấy theo
///    gradient vuông góc với cạnh, khớp đường thẳng bền vững, giao các cạnh →
///    góc chính xác dưới 1 pixel (mô phỏng: 9–16 px → < 1 px).
/// 2. [estimateAspect] – tỷ lệ rộng/cao THẬT của tờ giấy từ hình chiếu phối cảnh
///    (Zhang & He, "Whiteboard scanning and image enhancement", 2007) + tiêu cự
///    từ EXIF, rồi khớp khổ chuẩn A4/A5/Letter/Legal. Cách cũ (lấy cạnh dài nhất)
///    làm tài liệu chụp nghiêng bị bóp/kéo 13–53% theo chiều dọc.
/// 3. [estimateSkew] / [rotateFineRgb] – làm thẳng dòng chữ khi không có mép giấy.
///
/// Đã kiểm chứng bằng mô phỏng camera 3D (proto/sim.py, xem docs/GEOMETRY_VALIDATION.md).

// ---------------------------------------------------------------- 1. cạnh

class RefineResult {
  final Quad quad;
  final int sidesRefined;
  const RefineResult(this.quad, this.sidesRefined);
}

double _sample(Uint8List g, int w, int h, double x, double y) {
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

/// Đường thẳng (điểm c, hướng đơn vị d) khớp tổng bình phương khoảng cách vuông góc.
(Pt, Pt)? _fitLine(List<Pt> pts) {
  if (pts.length < 2) return null;
  var cx = 0.0, cy = 0.0;
  for (final p in pts) {
    cx += p.x;
    cy += p.y;
  }
  cx /= pts.length;
  cy /= pts.length;
  var sxx = 0.0, sxy = 0.0, syy = 0.0;
  for (final p in pts) {
    final dx = p.x - cx, dy = p.y - cy;
    sxx += dx * dx;
    sxy += dx * dy;
    syy += dy * dy;
  }
  // Vector riêng ứng với trị riêng lớn nhất của ma trận hiệp phương sai 2x2.
  final theta = 0.5 * math.atan2(2 * sxy, sxx - syy);
  return (Pt(cx, cy), Pt(math.cos(theta), math.sin(theta)));
}

Pt? _intersect((Pt, Pt) l1, (Pt, Pt) l2) {
  final (c1, d1) = l1;
  final (c2, d2) = l2;
  final det = d1.x * (-d2.y) - (-d2.x) * d1.y;
  if (det.abs() < 1e-9) return null;
  final rx = c2.x - c1.x, ry = c2.y - c1.y;
  final s = (rx * (-d2.y) - (-d2.x) * ry) / det;
  return Pt(c1.x + d1.x * s, c1.y + d1.y * s);
}

/// Chọn biên mép giấy trong 1 mặt cắt: biên NGOÀI CÙNG (chỉ số nhỏ = phía ngoài)
/// đúng chiều sáng/tối và ≥ 50% biên mạnh nhất – tránh bám vào dòng chữ sát mép.
/// Trả về vị trí (có phần lẻ) hoặc null.
double? pickEdge(Float64List grad, int sign) {
  final n = grad.length;
  var gmax = 4.0;
  for (var o = 2; o < n - 2; o++) {
    final v = grad[o] * sign;
    if (v > gmax) gmax = v;
  }
  if (gmax <= 4) return null;
  for (var o = 2; o < n - 2; o++) {
    final v = grad[o] * sign;
    if (v >= 0.5 * gmax && v >= grad[o - 1] * sign && v >= grad[o + 1] * sign) {
      final a = grad[o - 1] * sign, c = grad[o + 1] * sign;
      final den = a - 2 * v + c;
      final sub = (den.abs() > 1e-9 ? 0.5 * (a - c) / den : 0.0).clamp(-0.5, 0.5);
      return o + sub;
    }
  }
  return null;
}

/// +1 nếu phía trong (giấy) sáng hơn phía ngoài, ngược lại -1.
int insideSign(List<Float64List> profiles, int steps) {
  var d = 0.0;
  for (final p in profiles) {
    for (var o = 1; o <= steps; o++) {
      d += p[steps + o] - p[steps - o];
    }
  }
  return d >= 0 ? 1 : -1;
}

/// [gray] ảnh xám độ phân giải đầy đủ (w x h); [q] góc thô (cùng hệ toạ độ).
RefineResult refineQuad(Uint8List gray, int w, int h, Quad q) {
  final diag = math.sqrt(w * w + h * h.toDouble());
  final r = math.max(6.0, 0.012 * diag);
  final steps = r.floor();
  final cx = q.pts.fold<double>(0, (s, p) => s + p.x) / 4;
  final cy = q.pts.fold<double>(0, (s, p) => s + p.y) / 4;
  final lines = List<(Pt, Pt)?>.filled(4, null);
  var refined = 0;

  for (var i = 0; i < 4; i++) {
    final p0 = q.pts[i], p1 = q.pts[(i + 1) % 4];
    final len = p0.dist(p1);
    if (len < 10) continue;
    final tx = (p1.x - p0.x) / len, ty = (p1.y - p0.y) / len;
    var nx = -ty, ny = tx;
    final mx = (p0.x + p1.x) / 2, my = (p0.y + p1.y) / 2;
    if ((cx - mx) * nx + (cy - my) * ny < 0) {
      nx = -nx; // pháp tuyến hướng vào trong tờ giấy
      ny = -ny;
    }
    final k = (len / 8).clamp(20, 200).toInt();
    final profs = <Float64List>[];
    final bases = <Pt>[];
    for (var j = 0; j < k; j++) {
      final s = 0.08 + 0.84 * j / (k - 1);
      final bx = p0.x + (p1.x - p0.x) * s, by = p0.y + (p1.y - p0.y) * s;
      final pr = Float64List(2 * steps + 1);
      for (var o = -steps; o <= steps; o++) {
        final px = bx + nx * o, py = by + ny * o;
        // Trung bình 3 mẫu dọc theo cạnh để giảm nhiễu.
        pr[o + steps] = (_sample(gray, w, h, px - tx * 1.5, py - ty * 1.5) +
                _sample(gray, w, h, px, py) +
                _sample(gray, w, h, px + tx * 1.5, py + ty * 1.5)) /
            3;
      }
      profs.add(pr);
      bases.add(Pt(bx, by));
    }
    final sign = insideSign(profs, steps);
    final grad = Float64List(2 * steps + 1);
    var pts = <Pt>[];
    for (var j = 0; j < k; j++) {
      final pr = profs[j];
      for (var o = 1; o < pr.length - 1; o++) {
        grad[o] = (pr[o + 1] - pr[o - 1]) / 2;
      }
      final e = pickEdge(grad, sign);
      if (e == null) continue;
      final d = e - steps;
      pts.add(Pt(bases[j].x + nx * d, bases[j].y + ny * d));
    }
    if (pts.length < k * 0.4) continue;
    var line = _fitLine(pts);
    for (var it = 0; it < 3 && line != null; it++) {
      final (c, d) = line;
      final res = [for (final p in pts) ((p.x - c.x) * -d.y + (p.y - c.y) * d.x).abs()];
      final sorted = [...res]..sort();
      final thr = math.max(1.0, 2.5 * sorted[sorted.length ~/ 2]);
      final keep = [for (var m = 0; m < pts.length; m++) if (res[m] <= thr) pts[m]];
      if (keep.length < k * 0.35) break;
      pts = keep;
      line = _fitLine(pts);
    }
    lines[i] = line;
    if (line != null) refined++;
  }

  final out = [...q.pts];
  for (var i = 0; i < 4; i++) {
    final la = lines[(i + 3) % 4], lb = lines[i];
    if (la == null || lb == null) continue;
    final p = _intersect(la, lb);
    if (p == null || p.dist(q.pts[i]) > 2 * r) continue;
    out[i] = Pt(p.x.clamp(0.0, w.toDouble()), p.y.clamp(0.0, h.toDouble()));
  }
  final nq = Quad.ordered(out);
  if (!nq.isConvex || nq.area < 0.5 * q.area) return RefineResult(q, 0);
  return RefineResult(nq, refined);
}

// ------------------------------------------------------------ 2. tỷ lệ thật

enum PaperSize {
  auto('Tự động'),
  a4('A4 / A5'),
  letter('Letter'),
  legal('Legal'),
  free('Không ép khổ');

  final String label;
  const PaperSize(this.label);

  double? get ratio => switch (this) {
        PaperSize.a4 => math.sqrt2,
        PaperSize.letter => 11 / 8.5,
        PaperSize.legal => 14 / 8.5,
        _ => null,
      };
}

class AspectEstimate {
  /// Tỷ lệ rộng / cao của tờ giấy thật.
  final double ratio;

  /// Tỷ lệ đo được trước khi khớp khổ chuẩn.
  final double measured;

  /// Khổ giấy đã khớp (null nếu không khớp/không ép).
  final PaperSize? snapped;

  /// 'quad' (tính từ 2 điểm tụ), 'exif' hoặc 'default'.
  final String focalSource;
  const AspectEstimate(this.ratio, this.measured, this.snapped, this.focalSource);
}

/// Tiêu cự (pixel) từ tiêu cự quy đổi 35mm trong EXIF. Quy đổi theo đường chéo
/// (36x24mm → 43,27mm) để đúng với cảm biến 4:3 của điện thoại.
double focalFrom35mm(double f35, int w, int h) =>
    f35 * math.sqrt(w * w + h * h.toDouble()) / 43.267;

/// Tiêu cự mặc định khi không có EXIF: camera chính điện thoại ~26mm quy đổi.
double defaultFocal(int w, int h) => focalFrom35mm(26, w, h);

AspectEstimate estimateAspect(Quad q, int imgW, int imgH,
    {double? focalPx, PaperSize paper = PaperSize.auto}) {
  final u0 = imgW / 2, v0 = imgH / 2;
  List<double> m(Pt p) => [p.x - u0, p.y - v0, 1];
  List<double> cross(List<double> a, List<double> b) =>
      [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]];
  double dot(List<double> a, List<double> b) => a[0] * b[0] + a[1] * b[1] + a[2] * b[2];

  final m1 = m(q.tl), m2 = m(q.tr), m3 = m(q.bl), m4 = m(q.br);
  final c14 = cross(m1, m4);
  final d2 = dot(cross(m2, m4), m3), d3 = dot(cross(m3, m4), m2);
  double measured;
  var source = 'default';
  if (d2.abs() < 1e-9 || d3.abs() < 1e-9) {
    measured = _naiveRatio(q);
  } else {
    final k2 = dot(c14, m3) / d2;
    final k3 = dot(c14, m2) / d3;
    final n2 = [k2 * m2[0] - m1[0], k2 * m2[1] - m1[1], k2 * m2[2] - m1[2]];
    final n3 = [k3 * m3[0] - m1[0], k3 * m3[1] - m1[1], k3 * m3[2] - m1[2]];
    final longSide = math.max(imgW, imgH).toDouble();
    double f2;
    if (focalPx != null) {
      f2 = focalPx * focalPx;
      source = 'exif';
    } else {
      final f0 = defaultFocal(imgW, imgH);
      f2 = f0 * f0;
      // Chỉ tự tính tiêu cự khi CẢ HAI cặp cạnh đều hội tụ rõ; nếu một cặp gần
      // song song (nghiêng 1 trục – trường hợp phổ biến) thì bài toán suy biến.
      final c2 = n2[2].abs() * longSide / math.max(1e-9, math.sqrt(n2[0] * n2[0] + n2[1] * n2[1]));
      final c3 = n3[2].abs() * longSide / math.max(1e-9, math.sqrt(n3[0] * n3[0] + n3[1] * n3[1]));
      if (c2 > 0.08 && c3 > 0.08) {
        final fc2 = -(n2[0] * n3[0] + n2[1] * n3[1]) / (n2[2] * n3[2]);
        if (fc2 > 0) {
          final fc = math.sqrt(fc2);
          if (fc >= 0.5 * longSide && fc <= 1.6 * longSide) {
            f2 = fc2;
            source = 'quad';
          }
        }
      }
    }
    final num = (n2[0] * n2[0] + n2[1] * n2[1]) / f2 + n2[2] * n2[2];
    final den = (n3[0] * n3[0] + n3[1] * n3[1]) / f2 + n3[2] * n3[2];
    measured = (num > 0 && den > 0) ? math.sqrt(num / den) : _naiveRatio(q);
    if (!measured.isFinite || measured < 0.05 || measured > 20) measured = _naiveRatio(q);
  }

  return snapAspect(measured, paper, source);
}

/// Khớp tỷ lệ đo được vào khổ giấy chuẩn.
/// Tự động: chọn khổ GẦN NHẤT trong dung sai (A4/A5 ±6%, Letter/Legal ±3%) –
/// tài liệu khổ lạ (hoá đơn, thẻ…) giữ nguyên tỷ lệ thật, không bị kéo giãn.
AspectEstimate snapAspect(double measured, PaperSize paper, [String source = 'default']) {
  if (paper == PaperSize.free) return AspectEstimate(measured, measured, null, source);
  final long = measured >= 1 ? measured : 1 / measured;
  if (paper != PaperSize.auto) {
    final pr = paper.ratio!;
    return AspectEstimate(measured >= 1 ? pr : 1 / pr, measured, paper, source);
  }
  PaperSize? best;
  var bestErr = double.infinity;
  for (final c in const [PaperSize.a4, PaperSize.letter, PaperSize.legal]) {
    final err = (long / c.ratio! - 1).abs();
    final tol = c == PaperSize.a4 ? 0.06 : 0.03;
    if (err <= tol && err < bestErr) {
      best = c;
      bestErr = err;
    }
  }
  if (best == null) return AspectEstimate(measured, measured, null, source);
  final pr = best.ratio!;
  return AspectEstimate(measured >= 1 ? pr : 1 / pr, measured, best, source);
}

double _naiveRatio(Quad q) {
  final w = math.max(q.tl.dist(q.tr), q.bl.dist(q.br));
  final h = math.max(q.tl.dist(q.bl), q.tr.dist(q.br));
  return w / h;
}

/// Kích thước đầu ra theo tỷ lệ thật, giữ cạnh đo được dài nhất (không giảm chi tiết).
(int, int) outputSizeForAspect(Quad q, double ratio) {
  final wm = math.max(q.tl.dist(q.tr), q.bl.dist(q.br));
  final hm = math.max(q.tl.dist(q.bl), q.tr.dist(q.br));
  final w = math.max(wm, hm * ratio);
  return (math.max(1, w.round()), math.max(1, (w / ratio).round()));
}

// ------------------------------------------------------------ 3. làm thẳng

class SkewEstimate {
  /// Độ dốc của dòng chữ (độ, hệ y hướng xuống; dương = dòng chữ đi xuống bên phải).
  final double angle;

  /// Mức tăng "độ sắc" của hình chiếu so với góc 0 (≥ 1.15: đáng tin).
  final double gain;
  const SkewEstimate(this.angle, this.gain);

  /// Góc cần xoay theo chiều kim đồng hồ để dòng chữ nằm ngang.
  double get correction => -angle;
  bool get reliable => gain >= 1.15 && angle.abs() >= 0.15 && angle.abs() < 14.9;
}

/// Ước lượng độ nghiêng dòng chữ bằng phương sai hình chiếu (Projection profile).
SkewEstimate estimateSkew(Uint8List gray, int w, int h) {
  // Thu nhỏ về ~1000px.
  final s = math.min(1.0, 1000 / math.max(w, h));
  final sw = math.max(1, (w * s).round()), sh = math.max(1, (h * s).round());
  final g = Float64List(sw * sh);
  for (var y = 0; y < sh; y++) {
    final yy = math.min(h - 1, (y / s).floor());
    for (var x = 0; x < sw; x++) {
      g[y * sw + x] = gray[yy * w + math.min(w - 1, (x / s).floor())].toDouble();
    }
  }
  // Điểm mực: tối hơn 75% nền cục bộ (trung bình cửa sổ 31px qua ảnh tích phân).
  final integ = Float64List((sw + 1) * (sh + 1));
  for (var y = 0; y < sh; y++) {
    var row = 0.0;
    for (var x = 0; x < sw; x++) {
      row += g[y * sw + x];
      integ[(y + 1) * (sw + 1) + x + 1] = integ[y * (sw + 1) + x + 1] + row;
    }
  }
  final xs = <double>[], ys = <double>[];
  const r = 15;
  for (var y = 0; y < sh; y++) {
    final y0 = math.max(0, y - r), y1 = math.min(sh, y + r + 1);
    for (var x = 0; x < sw; x++) {
      final x0 = math.max(0, x - r), x1 = math.min(sw, x + r + 1);
      final sum = integ[y1 * (sw + 1) + x1] - integ[y0 * (sw + 1) + x1] -
          integ[y1 * (sw + 1) + x0] + integ[y0 * (sw + 1) + x0];
      final mean = sum / ((x1 - x0) * (y1 - y0));
      if (g[y * sw + x] < mean * 0.75) {
        xs.add(x - sw / 2);
        ys.add(y - sh / 2);
      }
    }
  }
  if (xs.length < 200) return const SkewEstimate(0, 1);
  final stride = (xs.length / 40000).ceil();
  double score(double deg) {
    final t = deg * math.pi / 180, c = math.cos(t), sn = math.sin(t);
    final bins = <int, int>{};
    for (var i = 0; i < xs.length; i += stride) {
      final rr = (ys[i] * c - xs[i] * sn).floor();
      bins[rr] = (bins[rr] ?? 0) + 1;
    }
    var acc = 0.0;
    for (final v in bins.values) {
      acc += v.toDouble() * v;
    }
    return acc;
  }

  var best = 0.0, bestS = -1.0;
  for (var a = -15.0; a <= 15.0001; a += 0.5) {
    final sc = score(a);
    if (sc > bestS) {
      bestS = sc;
      best = a;
    }
  }
  final coarse = best;
  for (var a = coarse - 0.5; a <= coarse + 0.5001; a += 0.05) {
    final sc = score(a);
    if (sc > bestS) {
      bestS = sc;
      best = a;
    }
  }
  final base = score(0);
  return SkewEstimate(best, base <= 0 ? 1 : bestS / base);
}

/// Xoay ảnh RGB một góc nhỏ (độ, chiều kim đồng hồ), giữ nguyên kích thước,
/// nội suy song tuyến, vùng trống tô màu [fill].
Uint8List rotateFineRgb(Uint8List src, int w, int h, double degClockwise, {int fill = 255}) {
  final t = degClockwise * math.pi / 180;
  final c = math.cos(t), s = math.sin(t);
  final cx = (w - 1) / 2, cy = (h - 1) / 2;
  final out = Uint8List(src.length);
  var o = 0;
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      // Ánh xạ ngược: điểm nguồn = R(-t) * (điểm đích - tâm) + tâm.
      final dx = x - cx, dy = y - cy;
      final sx = c * dx + s * dy + cx;
      final sy = -s * dx + c * dy + cy;
      if (sx < 0 || sy < 0 || sx > w - 1 || sy > h - 1) {
        out[o++] = fill;
        out[o++] = fill;
        out[o++] = fill;
        continue;
      }
      final x0 = sx.floor(), y0 = sy.floor();
      final x1 = x0 < w - 1 ? x0 + 1 : x0, y1 = y0 < h - 1 ? y0 + 1 : y0;
      final fx = sx - x0, fy = sy - y0;
      final i00 = (y0 * w + x0) * 3, i10 = (y0 * w + x1) * 3;
      final i01 = (y1 * w + x0) * 3, i11 = (y1 * w + x1) * 3;
      for (var ch = 0; ch < 3; ch++) {
        final top = src[i00 + ch] + (src[i10 + ch] - src[i00 + ch]) * fx;
        final bot = src[i01 + ch] + (src[i11 + ch] - src[i01 + ch]) * fx;
        out[o++] = (top + (bot - top) * fy + 0.5).toInt().clamp(0, 255);
      }
    }
  }
  return out;
}
