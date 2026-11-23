import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:smart_document_scanner/core/geometry.dart';
import 'package:smart_document_scanner/services/imaging/document_detector.dart';

/// Ảnh tổng hợp: tờ giấy sáng (có "chữ" tối) nghiêng trên nền tối.
(Uint8List, int, int, Quad) synthetic({bool cut = false}) {
  const w = 320, h = 420;
  final corners = cut
      ? Quad.ordered([Pt(-30, 40), Pt(280, 30), Pt(300, 390), Pt(20, 400)])
      : Quad.ordered([Pt(60, 50), Pt(270, 70), Pt(250, 380), Pt(40, 360)]);
  final g = Uint8List(w * h);
  bool inside(double x, double y) {
    for (var i = 0; i < 4; i++) {
      final a = corners.pts[i], b = corners.pts[(i + 1) % 4];
      if ((b.x - a.x) * (y - a.y) - (b.y - a.y) * (x - a.x) < 0) return false;
    }
    return true;
  }

  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final i = y * w + x;
      if (inside(x + 0.5, y + 0.5)) {
        final text = (y % 14 < 3) && (x % 9 < 6);
        g[i] = text ? 40 : 225;
      } else {
        g[i] = 50 + ((x * 7 + y * 3) % 20);
      }
    }
  }
  return (g, w, h, corners);
}

void main() {
  test('nhận diện đúng 4 góc tài liệu nghiêng (sai số < 6px)', () {
    final (g, w, h, truth) = synthetic();
    final r = DocumentDetector().detect(g, w, h);
    expect(r.quad, isNotNull);
    expect(r.isReliable, isTrue, reason: 'confidence=${r.confidence} issues=${r.issues}');
    for (var i = 0; i < 4; i++) {
      expect(r.quad!.pts[i].dist(truth.pts[i]), lessThan(6), reason: 'góc $i');
    }
  });

  test('báo mất góc khi tài liệu vượt khỏi khung', () {
    final (g, w, h, _) = synthetic(cut: true);
    final r = DocumentDetector().detect(g, w, h);
    expect(r.issues, contains('corner_out_of_frame'));
  });

  test('ảnh đồng màu → không tự crop', () {
    final g = Uint8List(200 * 200)..fillRange(0, 200 * 200, 128);
    final r = DocumentDetector().detect(g, 200, 200);
    expect(r.isReliable, isFalse);
  });

  test('tracker chỉ ổn định sau đủ số khung', () {
    final (g, w, h, _) = synthetic();
    final r = DocumentDetector().detect(g, w, h);
    final t = CornerStabilityTracker(requiredStableFrames: 5);
    for (var i = 0; i < 5; i++) {
      t.update(r, 500);
      expect(t.isStable, isFalse);
    }
    t.update(r, 500);
    expect(t.isStable, isTrue);
  });
}
