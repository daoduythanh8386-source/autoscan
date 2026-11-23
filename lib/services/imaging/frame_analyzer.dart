import 'dart:math' as math;
import 'dart:typed_data';

import '../../core/geometry.dart';
import 'document_detector.dart';

/// Dữ liệu 1 khung hình camera (mặt phẳng độ sáng) gửi sang isolate.
class FrameData {
  final Uint8List bytes;
  final int width;
  final int height;
  final int bytesPerRow;

  /// true: BGRA 8888 (iOS); false: plane Y của YUV420 (Android).
  final bool bgra;

  /// Số độ cần xoay theo chiều kim đồng hồ để khớp khung xem dọc (0/90/180/270).
  final int rotation;
  final bool mirror;

  const FrameData({
    required this.bytes,
    required this.width,
    required this.height,
    required this.bytesPerRow,
    required this.bgra,
    required this.rotation,
    required this.mirror,
  });
}

class FrameResult {
  /// Tứ giác chuẩn hoá về [0..1] theo khung xem dọc.
  final Quad? normQuad;
  final DetectionResult detection;
  final double sharpness;
  final int width;
  final int height;
  const FrameResult(this.normQuad, this.detection, this.sharpness, this.width, this.height);
}

/// Chạy trong isolate: thu nhỏ → xoay → nhận diện → đo độ nét.
FrameResult analyzeFrame(FrameData f) {
  const target = 320;
  final step = math.max(1, (math.max(f.width, f.height) / target).ceil());
  var gw = f.width ~/ step, gh = f.height ~/ step;
  var g = Uint8List(gw * gh);
  for (var y = 0; y < gh; y++) {
    final row = y * step * f.bytesPerRow;
    for (var x = 0; x < gw; x++) {
      if (f.bgra) {
        final i = row + x * step * 4;
        g[y * gw + x] = (f.bytes[i + 2] * 299 + f.bytes[i + 1] * 587 + f.bytes[i] * 114) ~/ 1000;
      } else {
        g[y * gw + x] = f.bytes[row + x * step];
      }
    }
  }
  final q = ((f.rotation % 360) ~/ 90) % 4;
  if (q != 0) {
    final nw = q.isOdd ? gh : gw, nh = q.isOdd ? gw : gh;
    final r = Uint8List(g.length);
    for (var y = 0; y < gh; y++) {
      for (var x = 0; x < gw; x++) {
        int dx, dy;
        switch (q) {
          case 1:
            dx = gh - 1 - y;
            dy = x;
            break;
          case 2:
            dx = gw - 1 - x;
            dy = gh - 1 - y;
            break;
          default:
            dx = y;
            dy = gw - 1 - x;
        }
        r[dy * nw + dx] = g[y * gw + x];
      }
    }
    g = r;
    gw = nw;
    gh = nh;
  }
  if (f.mirror) {
    for (var y = 0; y < gh; y++) {
      final row = y * gw;
      for (var x = 0; x < gw ~/ 2; x++) {
        final t = g[row + x];
        g[row + x] = g[row + gw - 1 - x];
        g[row + gw - 1 - x] = t;
      }
    }
  }
  final det = DocumentDetector().detect(g, gw, gh);
  final sharp = laplacianVariance(g, gw, gh);
  final nq = det.quad == null
      ? null
      : Quad.ordered([for (final p in det.quad!.pts) Pt(p.x / gw, p.y / gh)]);
  return FrameResult(nq, det, sharp, gw, gh);
}
