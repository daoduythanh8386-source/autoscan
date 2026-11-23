import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:smart_document_scanner/core/ids.dart';
import 'package:smart_document_scanner/services/export/export_core.dart';
import 'package:smart_document_scanner/services/imaging/pipeline.dart';

RgbImage sample(int w, int h, int seed) {
  final b = Uint8List(w * h * 3);
  for (var i = 0; i < b.length; i++) {
    b[i] = (i * seed + i ~/ 7) % 256;
  }
  return RgbImage(b, w, h);
}

void main() {
  test('PNG lossless khớp từng pixel', () {
    final s = sample(64, 48, 13);
    final png = img.encodePng(s.toImage());
    expect(verifyPngLossless(png, s).status, VerifyStatus.pass);
  });

  test('JPG giữ đúng kích thước', () {
    final s = sample(64, 48, 5);
    final jpg = img.encodeJpg(s.toImage(), quality: 95);
    expect(verifyJpg(jpg, 64, 48).status, VerifyStatus.pass);
  });

  test('GIF đúng số khung', () {
    final g = buildGif([sample(60, 80, 3), sample(60, 90, 7), sample(60, 70, 11)],
        const GifOptions(frameMs: 500, width: 60));
    expect(verifyGif(g, 3).status, VerifyStatus.pass);
  });

  test('PDF nhiều trang hợp lệ, đúng số trang', () async {
    final pages = [
      PdfPageInput.fromImage(sample(120, 160, 3)),
      PdfPageInput.fromImage(sample(160, 120, 9)),
    ];
    for (final q in PdfImageQuality.values) {
      final pdf = await buildPdf(pages, size: PdfPageSize.a4, quality: q);
      final v = verifyPdf(pdf, 2);
      expect(v.ok, isTrue, reason: '${q.name}: ${v.message}');
    }
  });

  test('ảnh gốc: so khớp từng byte', () {
    final a = Uint8List.fromList([1, 2, 3]);
    expect(verifyIdentical(a, Uint8List.fromList([1, 2, 3])).status, VerifyStatus.pass);
    expect(verifyIdentical(a, Uint8List.fromList([1, 2, 4])).status, VerifyStatus.fail);
  });

  test('tên file giữ tiếng Việt, bỏ ký tự cấm', () {
    expect(sanitizeFileName('Hóa đơn: tháng 5/2026?'), 'Hóa đơn_ tháng 5_2026_');
    expect(sanitizeFileName('   '), 'TaiLieu');
  });
}
