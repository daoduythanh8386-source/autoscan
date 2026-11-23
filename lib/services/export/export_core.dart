import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../imaging/pipeline.dart';

/// Kích thước trang PDF (mục 12).
enum PdfPageSize {
  auto('Tự động theo tài liệu'),
  a4('A4'),
  a5('A5'),
  letter('Letter');

  final String label;
  const PdfPageSize(this.label);
}

/// Mức nén ảnh trong PDF. Mọi mức có giảm kích thước đều được ghi rõ.
enum PdfImageQuality {
  lossless('Không nén mất dữ liệu (PNG) – nét nhất, file lớn', null, null),
  high('JPEG 95 – gần như không thấy khác biệt', 95, null),
  medium('JPEG 85 – cân bằng', 85, null),
  small('JPEG 75 + giới hạn 2480px cạnh dài – file nhỏ (CÓ giảm độ phân giải)', 75, 2480);

  final String label;
  final int? jpegQuality;
  final int? maxSide;
  const PdfImageQuality(this.label, this.jpegQuality, this.maxSide);
}

/// Một dòng OCR, toạ độ theo pixel của ảnh trang.
class OcrLine {
  final String text;
  final double left, top, width, height;
  const OcrLine(this.text, this.left, this.top, this.width, this.height);

  Map<String, dynamic> toJson() => {'t': text, 'l': left, 'y': top, 'w': width, 'h': height};
  factory OcrLine.fromJson(Map<String, dynamic> j) => OcrLine(
      j['t'] as String,
      (j['l'] as num).toDouble(),
      (j['y'] as num).toDouble(),
      (j['w'] as num).toDouble(),
      (j['h'] as num).toDouble());

  static String encodeList(List<OcrLine> l) => jsonEncode([for (final e in l) e.toJson()]);
  static List<OcrLine> decodeList(String s) => [
        for (final e in jsonDecode(s) as List<dynamic>) OcrLine.fromJson(e as Map<String, dynamic>)
      ];
}

/// Trang PDF đầu vào. Ảnh được nạp lười ([load]) từng trang một để không giữ
/// toàn bộ ảnh độ phân giải đầy đủ trong RAM cùng lúc.
class PdfPageInput {
  final RgbImage Function() load;
  final List<OcrLine> ocrLines;
  PdfPageInput(this.load, [this.ocrLines = const []]);
  factory PdfPageInput.fromImage(RgbImage im, [List<OcrLine> lines = const []]) =>
      PdfPageInput(() => im, lines);
}

/// Dựng PDF nhiều trang. Ảnh được mã hoá đúng MỘT lần từ dữ liệu RGB đã xử lý
/// (không nén JPEG chồng nhiều lần).
Future<Uint8List> buildPdf(
  List<PdfPageInput> pages, {
  required PdfPageSize size,
  required PdfImageQuality quality,
  Uint8List? fontTtf,
  String title = 'APP scan PDF',
}) async {
  final doc = pw.Document(
      title: title, creator: 'APP scan PDF – Đào Duy Thanh', producer: 'APP scan PDF', compress: true);
  final font = fontTtf == null ? null : pw.Font.ttf(ByteData.sublistView(fontTtf));
  for (final pg in pages) {
    var im = pg.load();
    var ocrScale = 1.0;
    if (quality.maxSide != null && math.max(im.width, im.height) > quality.maxSide!) {
      final before = im.width;
      im = ImagePipeline.downscale(im, quality.maxSide!);
      ocrScale = im.width / before;
    }
    final encoded = quality.jpegQuality == null
        ? img.encodePng(im.toImage(), level: 6)
        : img.encodeJpg(im.toImage(), quality: quality.jpegQuality!);
    final format = _pageFormat(size, im.width, im.height);
    final s = math.min(format.width / im.width, format.height / im.height);
    final dw = im.width * s, dh = im.height * s;
    final ox = (format.width - dw) / 2, oy = (format.height - dh) / 2;
    final image = pw.MemoryImage(encoded);
    final hasText = font != null && pg.ocrLines.isNotEmpty;
    doc.addPage(pw.Page(
      pageFormat: format,
      margin: pw.EdgeInsets.zero,
      build: (ctx) => pw.SizedBox(
        width: format.width,
        height: format.height,
        child: pw.Stack(children: [
          pw.Positioned(
              left: ox, top: oy, child: pw.Image(image, width: dw, height: dh, fit: pw.BoxFit.fill)),
          if (hasText)
            for (final l in pg.ocrLines)
              pw.Positioned(
                left: ox + l.left * ocrScale * s,
                top: oy + l.top * ocrScale * s,
                // Lớp chữ ẩn (độ mờ 0): tìm kiếm & sao chép được, không che ảnh.
                child: pw.Opacity(
                  opacity: 0,
                  child: pw.Text(l.text,
                      softWrap: false,
                      style: pw.TextStyle(
                          font: font,
                          fontSize: math.max(1.0, l.height * ocrScale * s * 0.85))),
                ),
              ),
        ]),
      ),
    ));
  }
  return doc.save();
}

PdfPageFormat _pageFormat(PdfPageSize size, int w, int h) {
  final landscape = w > h;
  PdfPageFormat base;
  switch (size) {
    case PdfPageSize.a4:
      base = PdfPageFormat.a4;
      break;
    case PdfPageSize.a5:
      base = PdfPageFormat.a5;
      break;
    case PdfPageSize.letter:
      base = PdfPageFormat.letter;
      break;
    case PdfPageSize.auto:
      // Giả định 300 DPI: kích thước trang theo đúng tỷ lệ ảnh tài liệu.
      return PdfPageFormat(w / 300 * PdfPageFormat.inch, h / 300 * PdfPageFormat.inch);
  }
  return landscape ? base.landscape : base.portrait;
}

class GifOptions {
  /// Thời gian hiển thị mỗi khung, mili-giây.
  final int frameMs;

  /// 0 = lặp vô hạn; n > 0 = số lần lặp.
  final int loopCount;

  /// Chiều rộng đầu ra (px).
  final int width;
  const GifOptions({this.frameMs = 1500, this.loopCount = 0, this.width = 720});
}

/// GIF nhiều khung. Lưu ý: GIF tối đa 256 màu – chỉ dùng để xem nhanh/chia sẻ,
/// không phải định dạng lưu trữ chất lượng cao.
Uint8List buildGif(List<RgbImage> frames, GifOptions o) {
  final resized = [
    for (final f in frames)
      img.copyResize(f.toImage(),
          width: o.width,
          height: math.max(1, (f.height * o.width / f.width).round()),
          interpolation: img.Interpolation.average)
  ];
  final canvasH = resized.map((e) => e.height).reduce(math.max);
  final enc = img.GifEncoder(repeat: o.loopCount, samplingFactor: 1);
  final cs = math.max(2, (o.frameMs / 10).round());
  for (final r in resized) {
    final canvas = img.Image(width: o.width, height: canvasH, numChannels: 3);
    img.fill(canvas, color: img.ColorRgb8(255, 255, 255));
    img.compositeImage(canvas, r, dstX: 0, dstY: (canvasH - r.height) ~/ 2);
    enc.addFrame(canvas, duration: cs);
  }
  final out = enc.finish();
  if (out == null) throw StateError('Không tạo được GIF');
  return out;
}

// ------------------------------------------------------------- kiểm tra file

enum VerifyStatus { pass, fail, notVerified }

class VerifyResult {
  final VerifyStatus status;
  final String message;
  const VerifyResult(this.status, this.message);
  bool get ok => status != VerifyStatus.fail;
}

VerifyResult verifyPdf(Uint8List bytes, int expectedPages) {
  if (bytes.length < 16) return const VerifyResult(VerifyStatus.fail, 'PDF rỗng');
  final head = latin1.decode(bytes.sublist(0, 5));
  if (head != '%PDF-') return const VerifyResult(VerifyStatus.fail, 'Thiếu header %PDF-');
  final tail = latin1.decode(bytes.sublist(math.max(0, bytes.length - 1024)));
  if (!tail.contains('%%EOF')) return const VerifyResult(VerifyStatus.fail, 'Thiếu %%EOF');
  final text = latin1.decode(bytes, allowInvalid: true);
  final pages = RegExp(r'/Type\s*/Page(?![s\w])').allMatches(text).length;
  if (pages == 0) {
    return const VerifyResult(
        VerifyStatus.notVerified, 'Cấu trúc hợp lệ nhưng không đếm được số trang (object stream).');
  }
  if (pages != expectedPages) {
    return VerifyResult(VerifyStatus.fail, 'Số trang $pages ≠ $expectedPages');
  }
  return VerifyResult(VerifyStatus.pass, 'PDF hợp lệ, $pages trang');
}

/// Kiểm tra PNG lossless: giải mã lại và so khớp từng pixel với dữ liệu nguồn.
VerifyResult verifyPngLossless(Uint8List png, RgbImage source) {
  final d = img.decodePng(png);
  if (d == null) return const VerifyResult(VerifyStatus.fail, 'Không giải mã được PNG');
  if (d.width != source.width || d.height != source.height) {
    return const VerifyResult(VerifyStatus.fail, 'Kích thước PNG sai');
  }
  final rgb = d.convert(format: img.Format.uint8, numChannels: 3).getBytes(order: img.ChannelOrder.rgb);
  for (var i = 0; i < rgb.length; i++) {
    if (rgb[i] != source.bytes[i]) {
      return const VerifyResult(VerifyStatus.fail, 'PNG không khớp pixel (không lossless)');
    }
  }
  return VerifyResult(VerifyStatus.pass, 'PNG lossless ${d.width}x${d.height}');
}

VerifyResult verifyJpg(Uint8List jpg, int w, int h) {
  final d = img.decodeJpg(jpg);
  if (d == null) return const VerifyResult(VerifyStatus.fail, 'Không giải mã được JPG');
  if (d.width != w || d.height != h) {
    return const VerifyResult(VerifyStatus.fail, 'Kích thước JPG sai');
  }
  return VerifyResult(VerifyStatus.pass, 'JPG hợp lệ ${d.width}x${d.height}');
}

VerifyResult verifyGif(Uint8List gif, int expectedFrames) {
  final d = img.decodeGif(gif);
  if (d == null) return const VerifyResult(VerifyStatus.fail, 'Không giải mã được GIF');
  final n = d.numFrames;
  if (n != expectedFrames) {
    return VerifyResult(VerifyStatus.fail, 'GIF có $n khung, mong đợi $expectedFrames');
  }
  return VerifyResult(VerifyStatus.pass, 'GIF hợp lệ, $n khung');
}

VerifyResult verifyIdentical(Uint8List a, Uint8List b) {
  if (a.length != b.length) return const VerifyResult(VerifyStatus.fail, 'Khác kích thước');
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return const VerifyResult(VerifyStatus.fail, 'Nội dung bị thay đổi');
  }
  return const VerifyResult(VerifyStatus.pass, 'Giống hệt ảnh gốc (từng byte)');
}
