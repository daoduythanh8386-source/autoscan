import 'dart:math' as math;
import 'dart:typed_data';

import '../../core/geometry.dart';

/// Kết quả nhận diện tài liệu trên một khung ảnh xám.
class DetectionResult {
  final Quad? quad;

  /// 0..1 – độ tin cậy tổng hợp.
  final double confidence;

  /// Mã vấn đề (nếu có): 'no_document', 'corner_out_of_frame', 'low_contrast',
  /// 'occluded', 'too_small'.
  final List<String> issues;

  /// Tỷ lệ diện tích tài liệu / khung hình.
  final double fill;

  /// Điểm biên mặt nạ tờ giấy (dùng để phát hiện mép cong). Có thể rỗng.
  final List<Pt> boundary;

  const DetectionResult(this.quad, this.confidence, this.issues, this.fill,
      [this.boundary = const []]);

  static const none = DetectionResult(null, 0, ['no_document'], 0);

  bool get isReliable => quad != null && confidence >= DocumentDetector.reliableThreshold;
}

/// Bộ nhận diện tài liệu thuần Dart (không phụ thuộc native), chạy được trên cả
/// Android và iOS. Có thể thay bằng engine OpenCV/Vision qua cùng interface.
///
/// Thuật toán:
/// 1. Làm mờ hộp 2 lần để triệt nhiễu và chữ.
/// 2. Ngưỡng Otsu → mặt nạ "giấy sáng" (và thử cực tính ngược lại).
/// 3. Lấy thành phần liên thông lớn nhất, lấp lỗ (chữ bên trong giấy).
/// 4. Bao lồi các điểm biên → tứ giác có diện tích lớn nhất nội tiếp bao lồi.
/// 5. Chấm điểm: độ đặc (solidity), độ tương phản trong/ngoài, góc, vị trí biên.
class DocumentDetector {
  static const reliableThreshold = 0.62;

  DetectionResult detect(Uint8List gray, int w, int h) {
    if (w < 16 || h < 16) return DetectionResult.none;
    final blurred = _boxBlur(_boxBlur(gray, w, h, 2), w, h, 2);
    final t = otsuThreshold(blurred);
    DetectionResult best = DetectionResult.none;
    for (final brightPaper in [true, false]) {
      final r = _detectWithPolarity(blurred, w, h, t, brightPaper);
      if (r.confidence > best.confidence) best = r;
    }
    return best;
  }

  DetectionResult _detectWithPolarity(
      Uint8List g, int w, int h, int t, bool brightPaper) {
    final n = w * h;
    final mask = Uint8List(n);
    for (var i = 0; i < n; i++) {
      mask[i] = (brightPaper ? g[i] > t : g[i] <= t) ? 1 : 0;
    }
    final comp = _largestComponent(mask, w, h);
    if (comp == null) return DetectionResult.none;
    final filled = _fillHoles(comp, w, h);
    var filledArea = 0;
    for (var i = 0; i < n; i++) {
      filledArea += filled[i];
    }
    final fillFrac = filledArea / n;
    if (fillFrac < 0.08) return DetectionResult(null, 0, const ['too_small'], fillFrac);

    final boundary = <Pt>[];
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final i = y * w + x;
        if (filled[i] == 0) continue;
        if (x == 0 || y == 0 || x == w - 1 || y == h - 1 ||
            filled[i - 1] == 0 || filled[i + 1] == 0 ||
            filled[i - w] == 0 || filled[i + w] == 0) {
          boundary.add(Pt(x + 0.5, y + 0.5));
        }
      }
    }
    if (boundary.length < 8) return DetectionResult.none;
    var hull = convexHull(boundary);
    if (hull.length < 4) return DetectionResult.none;
    if (hull.length > 240) {
      final step = hull.length / 240;
      hull = [for (var i = 0.0; i < hull.length; i += step) hull[i.floor()]];
    }
    final quad = maxAreaQuad(hull);
    if (quad == null || !quad.isConvex) return DetectionResult.none;

    final issues = <String>[];
    final qArea = quad.area;
    final solidity = (filledArea / math.max(1, qArea)).clamp(0.0, 1.0);
    final quadFill = qArea / n;
    if (quadFill > 0.985) {
      // Mặt nạ phủ gần như cả khung → không phân biệt được giấy và nền.
      return DetectionResult(null, 0, const ['no_document'], quadFill);
    }

    // Tương phản giữa vùng giấy và nền.
    var sumIn = 0.0, cntIn = 0, sumOut = 0.0, cntOut = 0;
    for (var i = 0; i < n; i += 3) {
      if (filled[i] == 1) {
        sumIn += g[i];
        cntIn++;
      } else {
        sumOut += g[i];
        cntOut++;
      }
    }
    final contrast = (cntIn == 0 || cntOut == 0)
        ? 0.0
        : ((sumIn / cntIn) - (sumOut / cntOut)).abs();
    final contrastScore = (contrast / 45).clamp(0.0, 1.0);
    if (contrastScore < 0.5) issues.add('low_contrast');

    final angle = quad.minAngleDeg;
    final angleScore = ((angle - 35) / 35).clamp(0.0, 1.0);

    var cornersOnEdge = 0;
    for (final p in quad.pts) {
      if (p.x <= 2 || p.y <= 2 || p.x >= w - 3 || p.y >= h - 3) cornersOnEdge++;
    }
    var edgePenalty = 1.0;
    if (cornersOnEdge > 0) {
      issues.add('corner_out_of_frame');
      edgePenalty = cornersOnEdge >= 2 ? 0.45 : 0.7;
    }
    if (solidity < 0.88) issues.add('occluded');
    final sizeScore = ((quadFill - 0.08) / 0.17).clamp(0.0, 1.0);
    if (quadFill < 0.2) issues.add('too_small');

    final conf = math.pow(solidity, 3).toDouble() *
        (0.4 + 0.6 * contrastScore) *
        angleScore *
        edgePenalty *
        (0.5 + 0.5 * sizeScore);
    final step = (boundary.length / 3000).ceil();
    final bnd = step <= 1
        ? boundary
        : [for (var i = 0; i < boundary.length; i += step) boundary[i]];
    return DetectionResult(quad, conf.clamp(0.0, 1.0), issues, quadFill, bnd);
  }

  // ---------------------------------------------------------------- helpers

  static Uint8List _boxBlur(Uint8List src, int w, int h, int r) {
    final tmp = Uint8List(src.length);
    final out = Uint8List(src.length);
    final win = 2 * r + 1;
    for (var y = 0; y < h; y++) {
      var sum = 0;
      final row = y * w;
      for (var k = -r; k <= r; k++) {
        sum += src[row + k.clamp(0, w - 1)];
      }
      for (var x = 0; x < w; x++) {
        tmp[row + x] = sum ~/ win;
        sum += src[row + (x + r + 1).clamp(0, w - 1)] - src[row + (x - r).clamp(0, w - 1)];
      }
    }
    for (var x = 0; x < w; x++) {
      var sum = 0;
      for (var k = -r; k <= r; k++) {
        sum += tmp[k.clamp(0, h - 1) * w + x];
      }
      for (var y = 0; y < h; y++) {
        out[y * w + x] = sum ~/ win;
        sum += tmp[(y + r + 1).clamp(0, h - 1) * w + x] - tmp[(y - r).clamp(0, h - 1) * w + x];
      }
    }
    return out;
  }

  /// Trả về mặt nạ (0/1) của thành phần liên thông 4-lân-cận lớn nhất.
  static Uint8List? _largestComponent(Uint8List mask, int w, int h) {
    final n = w * h;
    final labels = Int32List(n);
    final stack = Int32List(n);
    var label = 0, bestLabel = 0, bestSize = 0;
    for (var s = 0; s < n; s++) {
      if (mask[s] == 0 || labels[s] != 0) continue;
      label++;
      var sp = 0, size = 0;
      stack[sp++] = s;
      labels[s] = label;
      while (sp > 0) {
        final i = stack[--sp];
        size++;
        final x = i % w;
        if (x > 0 && mask[i - 1] == 1 && labels[i - 1] == 0) {
          labels[i - 1] = label;
          stack[sp++] = i - 1;
        }
        if (x < w - 1 && mask[i + 1] == 1 && labels[i + 1] == 0) {
          labels[i + 1] = label;
          stack[sp++] = i + 1;
        }
        if (i >= w && mask[i - w] == 1 && labels[i - w] == 0) {
          labels[i - w] = label;
          stack[sp++] = i - w;
        }
        if (i < n - w && mask[i + w] == 1 && labels[i + w] == 0) {
          labels[i + w] = label;
          stack[sp++] = i + w;
        }
      }
      if (size > bestSize) {
        bestSize = size;
        bestLabel = label;
      }
    }
    if (bestSize == 0) return null;
    final out = Uint8List(n);
    for (var i = 0; i < n; i++) {
      if (labels[i] == bestLabel) out[i] = 1;
    }
    return out;
  }

  /// Lấp các lỗ bên trong (chữ, hình) bằng flood-fill nền từ biên ảnh.
  static Uint8List _fillHoles(Uint8List comp, int w, int h) {
    final n = w * h;
    final outside = Uint8List(n);
    final stack = Int32List(n);
    var sp = 0;
    void push(int i) {
      if (comp[i] == 0 && outside[i] == 0) {
        outside[i] = 1;
        stack[sp++] = i;
      }
    }

    for (var x = 0; x < w; x++) {
      push(x);
      push((h - 1) * w + x);
    }
    for (var y = 0; y < h; y++) {
      push(y * w);
      push(y * w + w - 1);
    }
    while (sp > 0) {
      final i = stack[--sp];
      final x = i % w;
      if (x > 0) push(i - 1);
      if (x < w - 1) push(i + 1);
      if (i >= w) push(i - w);
      if (i < n - w) push(i + w);
    }
    final filled = Uint8List(n);
    for (var i = 0; i < n; i++) {
      filled[i] = outside[i] == 1 ? 0 : 1;
    }
    return filled;
  }
}

/// Ngưỡng Otsu trên ảnh xám 8 bit.
int otsuThreshold(Uint8List g) {
  final hist = List<int>.filled(256, 0);
  for (final v in g) {
    hist[v]++;
  }
  final total = g.length;
  var sumAll = 0.0;
  for (var i = 0; i < 256; i++) {
    sumAll += i * hist[i];
  }
  var sumB = 0.0, wB = 0, best = 0.0, t = 127;
  for (var i = 0; i < 256; i++) {
    wB += hist[i];
    if (wB == 0) continue;
    final wF = total - wB;
    if (wF == 0) break;
    sumB += i * hist[i];
    final mB = sumB / wB, mF = (sumAll - sumB) / wF;
    final between = wB * wF * (mB - mF) * (mB - mF);
    if (between > best) {
      best = between;
      t = i;
    }
  }
  return t;
}

/// Bao lồi (monotone chain).
List<Pt> convexHull(List<Pt> pts) {
  final p = [...pts]..sort((a, b) => a.x != b.x ? a.x.compareTo(b.x) : a.y.compareTo(b.y));
  double cross(Pt o, Pt a, Pt b) => (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x);
  final lower = <Pt>[];
  for (final q in p) {
    while (lower.length >= 2 && cross(lower[lower.length - 2], lower.last, q) <= 0) {
      lower.removeLast();
    }
    lower.add(q);
  }
  final upper = <Pt>[];
  for (final q in p.reversed) {
    while (upper.length >= 2 && cross(upper[upper.length - 2], upper.last, q) <= 0) {
      upper.removeLast();
    }
    upper.add(q);
  }
  lower.removeLast();
  upper.removeLast();
  return [...lower, ...upper];
}

/// Tứ giác diện tích lớn nhất với đỉnh thuộc bao lồi (tối ưu cục bộ lặp).
Quad? maxAreaQuad(List<Pt> hull) {
  if (hull.length < 4) return null;
  int argBest(double Function(Pt) f) {
    var bi = 0;
    var bv = -double.infinity;
    for (var i = 0; i < hull.length; i++) {
      final v = f(hull[i]);
      if (v > bv) {
        bv = v;
        bi = i;
      }
    }
    return bi;
  }

  final idx = <int>[
    argBest((p) => -(p.x + p.y)),
    argBest((p) => p.x - p.y),
    argBest((p) => p.x + p.y),
    argBest((p) => p.y - p.x),
  ];
  double areaOf(List<int> id) {
    var a = 0.0;
    for (var i = 0; i < 4; i++) {
      final p = hull[id[i]], q = hull[id[(i + 1) % 4]];
      a += p.x * q.y - q.x * p.y;
    }
    return a.abs() / 2;
  }

  var bestArea = areaOf(idx);
  for (var iter = 0; iter < 4; iter++) {
    var improved = false;
    for (var k = 0; k < 4; k++) {
      for (var c = 0; c < hull.length; c++) {
        if (idx.contains(c)) continue;
        final trial = [...idx]..[k] = c;
        final a = areaOf(trial);
        if (a > bestArea + 1e-6) {
          final q = Quad.ordered([for (final i in trial) hull[i]]);
          if (!q.isConvex) continue;
          bestArea = a;
          idx[k] = c;
          improved = true;
        }
      }
    }
    if (!improved) break;
  }
  final set = idx.toSet();
  if (set.length < 4) return null;
  return Quad.ordered([for (final i in idx) hull[i]]);
}

/// Phương sai Laplacian – thước đo độ nét (cao = nét).
double laplacianVariance(Uint8List g, int w, int h, {int step = 1}) {
  var sum = 0.0, sumSq = 0.0, cnt = 0;
  for (var y = 1; y < h - 1; y += step) {
    for (var x = 1; x < w - 1; x += step) {
      final i = y * w + x;
      final l = 4 * g[i] - g[i - 1] - g[i + 1] - g[i - w] - g[i + w];
      sum += l;
      sumSq += l * l;
      cnt++;
    }
  }
  if (cnt == 0) return 0;
  final m = sum / cnt;
  return sumSq / cnt - m * m;
}

/// Theo dõi độ ổn định của 4 góc giữa các khung hình để làm mượt và quyết định
/// tự động chụp.
class CornerStabilityTracker {
  final int requiredStableFrames;
  final double maxMoveFraction;
  final double smoothing;

  Quad? _smoothed;
  int _stableCount = 0;
  int _missCount = 0;

  CornerStabilityTracker({
    this.requiredStableFrames = 8,
    this.maxMoveFraction = 0.018,
    this.smoothing = 0.45,
  });

  Quad? get quad => _smoothed;
  int get stableCount => _stableCount;
  double get progress => (_stableCount / requiredStableFrames).clamp(0.0, 1.0);
  bool get isStable => _stableCount >= requiredStableFrames;

  void reset() {
    _smoothed = null;
    _stableCount = 0;
    _missCount = 0;
  }

  /// [diag] là đường chéo khung ảnh (pixel) để chuẩn hoá ngưỡng dịch chuyển.
  void update(DetectionResult r, double diag) {
    if (!r.isReliable) {
      _missCount++;
      _stableCount = 0;
      if (_missCount > 4) _smoothed = null;
      return;
    }
    _missCount = 0;
    final q = r.quad!;
    final prev = _smoothed;
    if (prev == null) {
      _smoothed = q;
      _stableCount = 0;
      return;
    }
    final move = prev.maxDisplacement(q) / diag;
    _smoothed = Quad.ordered([
      for (var i = 0; i < 4; i++)
        Pt(prev.pts[i].x + (q.pts[i].x - prev.pts[i].x) * smoothing,
            prev.pts[i].y + (q.pts[i].y - prev.pts[i].y) * smoothing)
    ]);
    if (move <= maxMoveFraction) {
      _stableCount++;
    } else {
      _stableCount = 0;
    }
  }
}
