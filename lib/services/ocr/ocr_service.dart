import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

import '../export/export_core.dart';

class OcrPageResult {
  final String fullText;
  final List<OcrLine> lines;

  /// Các dòng có chữ số – cần người dùng kiểm tra lại vì OCR có thể sai số liệu.
  final int linesWithDigits;
  const OcrPageResult(this.fullText, this.lines, this.linesWithDigits);
}

/// Module OCR độc lập, tuỳ chọn (mục 19).
///
/// - Chạy hoàn toàn trên thiết bị (Google ML Kit, mô hình Latin – theo tài liệu
///   ML Kit có hỗ trợ tiếng Việt; độ chính xác thực tế: NOT VERIFIED).
/// - Chỉ ĐỌC ảnh đã xử lý; không bao giờ thay pixel ảnh bằng kết quả OCR.
/// - Mọi lỗi được bắt lại để scan/xuất file vẫn hoạt động khi OCR hỏng.
abstract class OcrEngine {
  Future<OcrPageResult> recognizeFile(String imagePath);
  Future<void> dispose();
}

class MlKitOcrEngine implements OcrEngine {
  TextRecognizer? _rec;

  TextRecognizer get _r => _rec ??= TextRecognizer(script: TextRecognitionScript.latin);

  @override
  Future<OcrPageResult> recognizeFile(String imagePath) async {
    final result = await _r.processImage(InputImage.fromFilePath(imagePath));
    final lines = <OcrLine>[];
    var digits = 0;
    final digitRe = RegExp(r'\d');
    for (final block in result.blocks) {
      for (final line in block.lines) {
        final b = line.boundingBox;
        lines.add(OcrLine(line.text, b.left, b.top, b.width, b.height));
        if (digitRe.hasMatch(line.text)) digits++;
      }
    }
    return OcrPageResult(result.text, lines, digits);
  }

  @override
  Future<void> dispose() async {
    await _rec?.close();
    _rec = null;
  }
}
