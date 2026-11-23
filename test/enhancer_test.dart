import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:smart_document_scanner/models/edit_params.dart';
import 'package:smart_document_scanner/services/imaging/enhancer.dart';

/// Giấy có bóng đổ (tối dần sang phải), chữ đen, dấu đỏ và nét bút xanh mảnh.
(Uint8List, int, int) page() {
  const w = 300, h = 200;
  final b = Uint8List(w * h * 3);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final shade = 1.0 - 0.5 * x / w; // bóng: 100% → 50%
      var r = 235 * shade, g = 228 * shade, bl = 200 * shade; // giấy hơi vàng
      if (y >= 40 && y < 44 && x > 20 && x < 280) {
        r = g = bl = 25 * shade; // dòng chữ
      }
      if ((x - 220) * (x - 220) + (y - 120) * (y - 120) < 400) {
        r = 200 * shade; g = 30 * shade; bl = 40 * shade; // dấu đỏ
      }
      if (x == 60 && y > 100 && y < 180) {
        r = 30 * shade; g = 50 * shade; bl = 160 * shade; // nét bút xanh 1px
      }
      final i = (y * w + x) * 3;
      b[i] = r.round();
      b[i + 1] = g.round();
      b[i + 2] = bl.round();
    }
  }
  return (b, w, h);
}

int lum(Uint8List b, int w, int x, int y) {
  final i = (y * w + x) * 3;
  return (b[i] * 299 + b[i + 1] * 587 + b[i + 2] * 114) ~/ 1000;
}

void main() {
  final (src, w, h) = page();
  final e = DocumentEnhancer();

  test('không sửa buffer đầu vào (không phá huỷ)', () {
    final copy = Uint8List.fromList(src);
    e.apply(src, w, h, const EditParams(mode: ColorMode.colorDocument));
    expect(src, equals(copy));
  });

  test('Tài liệu màu: nền giấy sáng đều, khử bóng', () {
    final out = e.apply(src, w, h, const EditParams(mode: ColorMode.colorDocument));
    final left = lum(out, w, 10, 150), right = lum(out, w, 290, 150);
    expect((left - right).abs(), lessThan(20), reason: 'trái=$left phải=$right');
    expect(left, greaterThan(225));
  });

  test('giữ màu dấu đỏ và nét bút xanh', () {
    for (final m in [ColorMode.original, ColorMode.colorDocument]) {
      final out = e.apply(src, w, h, EditParams(mode: m));
      final i = (120 * w + 220) * 3;
      expect(out[i], greaterThan(out[i + 1] + 60), reason: 'đỏ phải trội ở chế độ ${m.name}');
      final j = (140 * w + 60) * 3;
      expect(out[j + 2], greaterThan(out[j] + 40), reason: 'xanh phải trội ở chế độ ${m.name}');
    }
  });

  test('chữ vẫn tối sau khi làm sáng (không bị tẩy mất)', () {
    final out = e.apply(src, w, h, const EditParams(mode: ColorMode.colorDocument));
    expect(lum(out, w, 250, 42), lessThan(90));
  });

  test('Trắng đen giữ nét mảnh 1px', () {
    final out = e.apply(src, w, h, const EditParams(mode: ColorMode.blackWhite));
    expect(lum(out, w, 60, 140), 0);
    expect(lum(out, w, 80, 140), 255);
  });

  test('EditParams JSON khứ hồi', () {
    const p = EditParams(rotation: 3, mode: ColorMode.grayscale, brightness: 0.2, warmth: -0.4);
    final q = EditParams.decode(p.encode());
    expect(q.encode(), p.encode());
  });
}
