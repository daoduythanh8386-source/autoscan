import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:share_plus/share_plus.dart';

import '../../core/ids.dart';
import '../../models/document.dart';
import '../imaging/pipeline.dart';
import '../ocr/ocr_service.dart';
import '../storage/app_storage.dart';
import 'export_core.dart';

enum ExportFormat {
  pdf('PDF', 'pdf', 'application/pdf'),
  png('PNG', 'png', 'image/png'),
  jpg('JPG/JPEG', 'jpg', 'image/jpeg'),
  gif('GIF', 'gif', 'image/gif'),
  original('Ảnh gốc', '', 'image/*');

  final String label;
  final String ext;
  final String mime;
  const ExportFormat(this.label, this.ext, this.mime);
}

class ExportRequest {
  final ScanDocument doc;
  final List<ScanPage> pages; // đã chọn, theo đúng thứ tự xuất
  final ExportFormat format;
  final String baseName;
  final DocFolder? folder;
  final bool replaceExisting;
  final PdfPageSize pdfSize;
  final PdfImageQuality pdfQuality;
  final int jpgQuality;
  final GifOptions gif;
  final bool ocr;

  const ExportRequest({
    required this.doc,
    required this.pages,
    required this.format,
    required this.baseName,
    this.folder,
    this.replaceExisting = false,
    this.pdfSize = PdfPageSize.auto,
    this.pdfQuality = PdfImageQuality.lossless,
    this.jpgQuality = 95,
    this.gif = const GifOptions(),
    this.ocr = false,
  });
}

class ExportOutcome {
  final List<ExportedFile> files;
  final List<VerifyResult> checks;
  final List<String> warnings;
  const ExportOutcome(this.files, this.checks, this.warnings);
  List<String> absPaths(AppStorage s) => [for (final f in files) s.exportAbs(f.relPath)];
}

typedef ProgressCb = void Function(String step, double fraction);

class ExportService {
  ExportService(this.storage, {OcrEngine? ocr}) : _ocr = ocr ?? MlKitOcrEngine();
  final AppStorage storage;
  final OcrEngine _ocr;

  /// Ảnh đã xử lý ở độ phân giải đầy đủ, mã hoá PNG lossless, có cache theo
  /// tham số chỉnh sửa. Không bao giờ dùng ảnh preview làm nguồn xuất.
  Future<String> processedPng(ScanPage page) async {
    final rel = p.join('processed', '${page.id}_${page.edit.cacheKey}.png');
    final abs = storage.internalAbs(rel);
    final f = File(abs);
    if (await f.exists() && await f.length() > 0) return abs;
    final dir = Directory(p.dirname(abs));
    if (await dir.exists()) {
      await for (final e in dir.list()) {
        if (p.basename(e.path).startsWith('${page.id}_')) {
          try {
            await e.delete();
          } catch (_) {}
        }
      }
    }
    final png = await ImagePipeline.renderFullPng(storage.internalAbs(page.originalRelPath), page.edit);
    await storage.writeBytesAtomic(abs, png);
    return abs;
  }

  List<String> _targetNames(ExportRequest r) {
    final base = sanitizeFileName(r.baseName);
    switch (r.format) {
      case ExportFormat.pdf:
      case ExportFormat.gif:
        return ['$base.${r.format.ext}'];
      case ExportFormat.png:
      case ExportFormat.jpg:
      case ExportFormat.original:
        return [
          for (var i = 0; i < r.pages.length; i++)
            () {
              final ext = r.format == ExportFormat.original
                  ? p.extension(r.pages[i].originalRelPath)
                  : '.${r.format.ext}';
              final suffix = r.pages.length == 1 ? '' : '_${(i + 1).toString().padLeft(2, '0')}';
              return '$base$suffix$ext';
            }()
        ];
    }
  }

  Future<ExportOutcome> export(ExportRequest r, {ProgressCb? onProgress}) async {
    if (r.pages.isEmpty) throw ArgumentError('Chưa chọn trang nào để xuất');
    final warnings = <String>[];
    final checks = <VerifyResult>[];
    if (await storage.isLowOnSpace()) {
      warnings.add('Bộ nhớ thiết bị sắp đầy. Hãy giải phóng dung lượng nếu xuất bị lỗi.');
    }
    // 1) Giữ chỗ tên file – không tự ghi đè (mục 17).
    final rels = <String>[];
    for (final n in _targetNames(r)) {
      rels.add(await storage.reserveExportPath(n,
          folderName: r.folder?.name, replace: r.replaceExisting));
    }

    // 2) Ảnh gốc: sao chép nguyên vẹn từng byte.
    if (r.format == ExportFormat.original) {
      final files = <ExportedFile>[];
      for (var i = 0; i < r.pages.length; i++) {
        onProgress?.call('Sao chép ảnh gốc ${i + 1}/${r.pages.length}', i / r.pages.length);
        final src = await File(storage.internalAbs(r.pages[i].originalRelPath)).readAsBytes();
        await storage.writeBytesAtomic(storage.exportAbs(rels[i]), src);
        final written = await File(storage.exportAbs(rels[i])).readAsBytes();
        checks.add(verifyIdentical(src, written));
        files.add(await storage.recordExport(
            documentId: r.doc.id, relPath: rels[i], format: 'original', pageCount: 1,
            folderId: r.folder?.id));
      }
      return ExportOutcome(files, checks, warnings);
    }

    // 3) Ảnh đã xử lý, độ phân giải đầy đủ.
    final pngPaths = <String>[];
    for (var i = 0; i < r.pages.length; i++) {
      onProgress?.call('Xử lý trang ${i + 1}/${r.pages.length}', i / r.pages.length * 0.6);
      pngPaths.add(await processedPng(r.pages[i]));
    }

    // 4) OCR (tuỳ chọn) – lỗi OCR không làm hỏng việc xuất.
    final ocrLines = List<List<OcrLine>>.filled(r.pages.length, const []);
    if (r.ocr && r.format == ExportFormat.pdf) {
      var digitLines = 0;
      for (var i = 0; i < r.pages.length; i++) {
        onProgress?.call('Nhận dạng chữ (OCR) ${i + 1}/${r.pages.length}',
            0.6 + i / r.pages.length * 0.2);
        try {
          final res = await _ocr.recognizeFile(pngPaths[i]);
          ocrLines[i] = res.lines;
          digitLines += res.linesWithDigits;
          r.pages[i].ocrText = res.fullText;
          await storage.updatePage(r.pages[i]);
        } catch (e) {
          warnings.add('OCR trang ${i + 1} lỗi – PDF vẫn được tạo, không có lớp chữ trang này.');
        }
      }
      warnings.add('OCR có thể nhận dạng sai. Không mặc định số liệu OCR là chính xác'
          '${digitLines > 0 ? ' ($digitLines dòng có chữ số cần kiểm tra lại)' : ''}.');
    }

    onProgress?.call('Mã hoá ${r.format.label}', 0.85);
    final files = <ExportedFile>[];
    switch (r.format) {
      case ExportFormat.pdf:
        {
        final font = (await rootBundle.load('assets/fonts/DejaVuSans.ttf')).buffer.asUint8List();
        final linesJson = [for (final l in ocrLines) OcrLine.encodeList(l)];
        final size = r.pdfSize, q = r.pdfQuality, title = r.baseName;
        final n = r.pages.length;
        final paths = [...pngPaths];
        final (bytes, check) = await _pdfJob(paths, linesJson, size, q, font, title, n);
        if (q.maxSide != null) {
          warnings.add('Mức nén "Nhỏ" đã giảm độ phân giải ảnh trong PDF xuống tối đa ${q.maxSide}px.');
        }
        await storage.writeBytesAtomic(storage.exportAbs(rels[0]), bytes);
        checks.add(check);
        files.add(await storage.recordExport(
            documentId: r.doc.id, relPath: rels[0], format: 'pdf', pageCount: n,
            folderId: r.folder?.id));
        }
      case ExportFormat.png:
        {
        for (var i = 0; i < pngPaths.length; i++) {
          final bytes = await File(pngPaths[i]).readAsBytes();
          await storage.writeBytesAtomic(storage.exportAbs(rels[i]), bytes);
          final written = await File(storage.exportAbs(rels[i])).readAsBytes();
          final path = pngPaths[i];
          checks.add(await _pngVerifyJob(path, written));
          files.add(await storage.recordExport(
              documentId: r.doc.id, relPath: rels[i], format: 'png', pageCount: 1,
              folderId: r.folder?.id));
        }
        }
      case ExportFormat.jpg:
        {
        final q = r.jpgQuality;
        for (var i = 0; i < pngPaths.length; i++) {
          final path = pngPaths[i];
          final (bytes, check) = await _jpgJob(path, q);
          await storage.writeBytesAtomic(storage.exportAbs(rels[i]), bytes);
          checks.add(check);
          files.add(await storage.recordExport(
              documentId: r.doc.id, relPath: rels[i], format: 'jpg', pageCount: 1,
              folderId: r.folder?.id));
        }
        }
      case ExportFormat.gif:
        {
        final paths = [...pngPaths];
        final o = r.gif;
        final (bytes, check) = await _gifJob(paths, o);
        warnings.add('GIF chỉ hỗ trợ tối đa 256 màu – không dùng để lưu trữ tài liệu chất lượng cao.');
        await storage.writeBytesAtomic(storage.exportAbs(rels[0]), bytes);
        checks.add(check);
        files.add(await storage.recordExport(
            documentId: r.doc.id, relPath: rels[0], format: 'gif', pageCount: paths.length,
            folderId: r.folder?.id));
        }
      case ExportFormat.original:
        break;
    }
    onProgress?.call('Hoàn tất', 1);
    return ExportOutcome(files, checks, warnings);
  }

  /// Xem trước PDF (không lưu): dựng ở mức nén đã chọn.
  Future<Uint8List> previewPdf(ExportRequest r) async {
    final pngPaths = [for (final pg in r.pages) await processedPng(pg)];
    final size = r.pdfSize, q = r.pdfQuality;
    return _pdfPreviewJob(pngPaths, size, q);
  }
}

// ---- Tác vụ isolate ở mức top-level: closure chỉ giữ tham số (không giữ `this`).

Future<(Uint8List, VerifyResult)> _pdfJob(List<String> paths, List<String> linesJson,
    PdfPageSize size, PdfImageQuality q, Uint8List font, String title, int n) {
  return Isolate.run(() async {
    final inputs = <PdfPageInput>[];
    for (var i = 0; i < paths.length; i++) {
      final pth = paths[i];
      inputs.add(PdfPageInput(
          () => _decodePng(File(pth).readAsBytesSync()), OcrLine.decodeList(linesJson[i])));
    }
    final b = await buildPdf(inputs, size: size, quality: q, fontTtf: font, title: title);
    return (b, verifyPdf(b, n));
  });
}

Future<Uint8List> _pdfPreviewJob(List<String> paths, PdfPageSize size, PdfImageQuality q) {
  return Isolate.run(() {
    final inputs = [
      for (final pth in paths) PdfPageInput(() => _decodePng(File(pth).readAsBytesSync()))
    ];
    return buildPdf(inputs, size: size, quality: q);
  });
}

Future<VerifyResult> _pngVerifyJob(String path, Uint8List written) {
  return Isolate.run(() => verifyPngLossless(written, _decodePng(File(path).readAsBytesSync())));
}

Future<(Uint8List, VerifyResult)> _jpgJob(String path, int q) {
  return Isolate.run(() {
    final src = _decodePng(File(path).readAsBytesSync());
    // Mã hoá JPEG đúng 1 lần từ dữ liệu lossless.
    final jpg = img.encodeJpg(src.toImage(), quality: q);
    return (jpg, verifyJpg(jpg, src.width, src.height));
  });
}

Future<(Uint8List, VerifyResult)> _gifJob(List<String> paths, GifOptions o) {
  return Isolate.run(() {
    final frames = [for (final pth in paths) _decodePng(File(pth).readAsBytesSync())];
    final g = buildGif(frames, o);
    return (g, verifyGif(g, frames.length));
  });
}

RgbImage _decodePng(Uint8List bytes) {
  final d = img.decodePng(bytes);
  if (d == null) throw const FormatException('PNG hỏng');
  final c = d.convert(format: img.Format.uint8, numChannels: 3);
  return RgbImage(Uint8List.fromList(c.getBytes(order: img.ChannelOrder.rgb)), c.width, c.height);
}

/// Chia sẻ file THẬT qua cơ chế chia sẻ của hệ điều hành (mục 18).
class ShareManager {
  static Future<void> shareFiles(List<String> absPaths, String mime, {String? subject}) async {
    final files = [for (final pth in absPaths) XFile(pth, mimeType: mime == 'image/*' ? null : mime)];
    await Share.shareXFiles(files, subject: subject);
  }

  static String mimeForPath(String path) {
    switch (p.extension(path).toLowerCase()) {
      case '.pdf':
        return 'application/pdf';
      case '.png':
        return 'image/png';
      case '.jpg':
      case '.jpeg':
        return 'image/jpeg';
      case '.gif':
        return 'image/gif';
      case '.heic':
        return 'image/heic';
      default:
        return 'application/octet-stream';
    }
  }
}
