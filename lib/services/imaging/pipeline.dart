import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import '../../core/geometry.dart';
import '../../core/dewarp.dart';
import '../../core/rectify.dart';
import '../../models/edit_params.dart';
import 'document_detector.dart';
import 'enhancer.dart';
import 'quality.dart';

/// Ảnh RGB 8 bit thô (3 kênh).
class RgbImage {
  final Uint8List bytes;
  final int width;
  final int height;
  const RgbImage(this.bytes, this.width, this.height);

  img.Image toImage() => img.Image.fromBytes(
      width: width, height: height, bytes: bytes.buffer, numChannels: 3);
}

/// Kết quả phân tích ngay sau khi chụp/nhập ảnh.
class CaptureAnalysis {
  /// 4 góc đã tinh chỉnh ở độ phân giải đầy đủ (null = không đủ tin cậy để tự crop).
  final Quad? corners;

  /// Số cạnh tinh chỉnh được theo mép giấy thật (0–4).
  final int sidesRefined;

  /// Góc làm thẳng đề xuất (khi không tìm được mép giấy).
  final double suggestedFineRotation;

  /// Mô hình nắn giấy cong (null = giấy phẳng) và loại: flat / curl / complex.
  final Map<String, dynamic>? dewarp;
  final String curveKind;
  final double curvature;
  final double confidence;
  final List<String> detectionIssues;
  final List<QualityIssue> qualityIssues;
  final int width;
  final int height;

  const CaptureAnalysis({
    required this.corners,
    this.sidesRefined = 0,
    this.suggestedFineRotation = 0,
    this.dewarp,
    this.curveKind = 'flat',
    this.curvature = 0,
    required this.confidence,
    required this.detectionIssues,
    required this.qualityIssues,
    required this.width,
    required this.height,
  });

  bool get autoCropReliable => corners != null && confidence >= DocumentDetector.reliableThreshold;
}

/// Toàn bộ xử lý nặng chạy trong isolate riêng để UI không bị treo (mục 20).
class ImagePipeline {
  /// Giải mã ảnh gốc, xoay theo EXIF, trả về RGB độ phân giải đầy đủ.
  static RgbImage decodeOriented(Uint8List fileBytes) => decodeWithExif(fileBytes).$1;

  /// Giải mã + xoay theo EXIF; trả kèm tiêu cự quy đổi 35mm (nếu có trong EXIF).
  static (RgbImage, double?) decodeWithExif(Uint8List fileBytes) {
    final decoded = img.decodeImage(fileBytes);
    if (decoded == null) {
      throw const FormatException('Không đọc được ảnh (định dạng không hỗ trợ hoặc file hỏng).');
    }
    double? f35;
    try {
      final v = decoded.exif.exifIfd[0xA405]?.toInt(); // FocalLengthIn35mmFilm
      if (v != null && v >= 10 && v <= 200) f35 = v.toDouble();
    } catch (_) {}
    var im = img.bakeOrientation(decoded);
    if (im.numChannels != 3 || im.format != img.Format.uint8 || im.hasPalette) {
      im = im.convert(format: img.Format.uint8, numChannels: 3);
    }
    return (
      RgbImage(Uint8List.fromList(im.getBytes(order: img.ChannelOrder.rgb)), im.width, im.height),
      f35
    );
  }

  static Uint8List toGray(RgbImage im) {
    final n = im.width * im.height;
    final g = Uint8List(n);
    final b = im.bytes;
    for (var i = 0, j = 0; i < n; i++, j += 3) {
      g[i] = (b[j] * 299 + b[j + 1] * 587 + b[j + 2] * 114) ~/ 1000;
    }
    return g;
  }

  static RgbImage downscale(RgbImage im, int maxSide) {
    final long = math.max(im.width, im.height);
    if (long <= maxSide) return im;
    final s = maxSide / long;
    final r = img.copyResize(im.toImage(),
        width: math.max(1, (im.width * s).round()),
        height: math.max(1, (im.height * s).round()),
        interpolation: img.Interpolation.average);
    return RgbImage(Uint8List.fromList(r.getBytes(order: img.ChannelOrder.rgb)), r.width, r.height);
  }

  /// Phân tích: nhận diện 4 góc trên bản thu nhỏ rồi quy đổi về toạ độ gốc,
  /// đồng thời đánh giá chất lượng ảnh.
  static double focalFor(double? f35, int w, int h) =>
      f35 == null ? defaultFocal(w, h) : focalFrom35mm(f35, w, h);

  static CaptureAnalysis analyze(Uint8List fileBytes) {
    final (full, f35) = decodeWithExif(fileBytes);
    final small = downscale(full, 720);
    final gray = toGray(small);
    final det = DocumentDetector().detect(gray, small.width, small.height);
    final scale = full.width / small.width;
    final fullGray = toGray(full);
    Quad? corners;
    var sides = 0;
    var fine = 0.0;
    DewarpResult? curve;
    if (det.quad != null) {
      final coarse =
          det.quad!.scaled(scale).clampTo(full.width.toDouble(), full.height.toDouble());
      // Tinh chỉnh mép giấy ở độ phân giải đầy đủ → cạnh thẳng, góc chính xác.
      final ref = refineQuad(fullGray, full.width, full.height, coarse);
      corners = ref.quad;
      sides = ref.sidesRefined;
    }
    final reliable = det.isReliable && corners != null;
    if (reliable) {
      // Phát hiện giấy cong / mép quăn và dựng mô hình nắn.
      try {
        curve = analyzeCurvature(fullGray, full.width, full.height, corners!,
            [for (final p in det.boundary) p.scale(scale)],
            focal: focalFor(f35, full.width, full.height));
        corners = curve.corners;
      } catch (_) {
        curve = null; // lỗi nắn cong không được làm hỏng việc scan
      }
    } else {
      // Không thấy mép giấy: đề xuất làm thẳng theo dòng chữ.
      final sk = estimateSkew(fullGray, full.width, full.height);
      if (sk.reliable) fine = sk.correction;
    }
    final quality = QualityAssessor().assess(
      fullWidth: full.width,
      fullHeight: full.height,
      small: small,
      smallGray: gray,
      detection: det,
    );
    return CaptureAnalysis(
      corners: reliable ? corners : null,
      sidesRefined: sides,
      suggestedFineRotation: fine,
      dewarp: curve?.model?.toJson(),
      curveKind: curve?.kind ?? 'flat',
      curvature: curve?.curvature ?? 0,
      confidence: det.confidence,
      detectionIssues: det.issues,
      qualityIssues: quality,
      width: full.width,
      height: full.height,
    );
  }

  /// Dựng lại mô hình nắn cong với 4 góc cho trước (sau khi người dùng chỉnh góc).
  static (Quad, Map<String, dynamic>?, String) dewarpWithCorners(Uint8List fileBytes, Quad q) {
    final (full, f35) = decodeWithExif(fileBytes);
    final small = downscale(full, 720);
    final det = DocumentDetector().detect(toGray(small), small.width, small.height);
    final scale = full.width / small.width;
    final r = analyzeCurvature(toGray(full), full.width, full.height, q,
        [for (final p in det.boundary) p.scale(scale)],
        focal: focalFor(f35, full.width, full.height));
    return (r.model == null ? q : r.corners, r.model?.toJson(), r.kind);
  }

  /// "Bắt dính" góc người dùng kéo vào đúng mép giấy gần nhất.
  static Quad snapToEdges(Uint8List fileBytes, Quad q) {
    final full = decodeOriented(fileBytes);
    return refineQuad(toGray(full), full.width, full.height, q).quad;
  }

  /// Ước lượng góc làm thẳng theo dòng chữ trên ảnh đã nắn phẳng (không tính góc tinh).
  static double autoStraighten(Uint8List fileBytes, EditParams p) {
    final r = render(fileBytes, p.copyWith(fineRotation: 0, mode: ColorMode.original,
        shadowReduction: 0.0, brightness: 0, contrast: 0, sharpness: 0, warmth: 0), maxSide: 1400);
    final sk = estimateSkew(toGray(r), r.width, r.height);
    return sk.reliable ? sk.correction : 0;
  }

  /// Dựng ảnh đã xử lý từ ảnh gốc + tham số. [maxSide] chỉ dùng cho xem trước;
  /// khi xuất file luôn để null để giữ độ phân giải đầy đủ (MAXIMUM).
  static RgbImage render(Uint8List fileBytes, EditParams p, {int? maxSide}) {
    var (src, f35) = decodeWithExif(fileBytes);
    var corners = p.corners;
    var s = 1.0;
    if (maxSide != null) {
      final small = downscale(src, maxSide);
      s = small.width / src.width;
      if (corners != null) corners = corners.scaled(s);
      src = small;
    }
    RgbImage warped;
    final model = corners == null ? null : DewarpModel.fromJson(p.dewarp);
    if (corners == null) {
      warped = src;
    } else if (model != null) {
      // Giấy cong: nắn theo mô hình mép cong / trụ 3D (toạ độ mô hình theo ảnh gốc).
      final aspect = snapAspect(model.measuredAspect, p.paper);
      final (ow, oh) = outputSizeForAspect(corners, aspect.ratio);
      final m = s == 1.0 ? model : model.scaled(s);
      warped = RgbImage(
          warpModelRgb(src.bytes, src.width, src.height, m, ow, oh, bicubic: maxSide == null),
          ow,
          oh);
    } else {
      // Tỷ lệ rộng/cao THẬT của tờ giấy (không phải độ dài cạnh trên ảnh nghiêng).
      final aspect = estimateAspect(corners, src.width, src.height,
          focalPx: f35 == null ? null : focalFrom35mm(f35, src.width, src.height),
          paper: p.paper);
      final (ow, oh) = outputSizeForAspect(corners, aspect.ratio);
      warped = RgbImage(
          warpPerspectiveRgb(src.bytes, src.width, src.height, corners, ow, oh,
              bicubic: maxSide == null),
          ow,
          oh);
    }
    var (rb, rw, rh) = rotateRgb90(warped.bytes, warped.width, warped.height, p.rotation);
    if (p.fineRotation.abs() > 0.01) {
      rb = rotateFineRgb(rb, rw, rh, p.fineRotation);
    }
    final enhanced = DocumentEnhancer().apply(rb, rw, rh, p);
    return RgbImage(enhanced, rw, rh);
  }

  /// Thông tin tỷ lệ để hiển thị cho người dùng.
  static AspectEstimate? aspectInfo(Uint8List fileBytes, EditParams p) {
    final c = p.corners;
    if (c == null) return null;
    final model = DewarpModel.fromJson(p.dewarp);
    if (model != null) return snapAspect(model.measuredAspect, p.paper, 'cong');
    final (src, f35) = decodeWithExif(fileBytes);
    return estimateAspect(c, src.width, src.height,
        focalPx: f35 == null ? null : focalFrom35mm(f35, src.width, src.height), paper: p.paper);
  }

  // ------------------------------------------------------- isolate wrappers

  static Future<CaptureAnalysis> analyzeFile(String path) async {
    return Isolate.run(() => analyze(File(path).readAsBytesSync()));
  }

  static Future<AspectEstimate?> aspectInfoFile(String path, EditParams p) {
    final json = p.encode();
    return Isolate.run(() => aspectInfo(File(path).readAsBytesSync(), EditParams.decode(json)));
  }

  static Future<(Quad, Map<String, dynamic>?, String)> dewarpFile(String path, Quad q) {
    final json = q.toJson();
    return Isolate.run(() => dewarpWithCorners(File(path).readAsBytesSync(), Quad.fromJson(json)));
  }

  static Future<Quad> snapToEdgesFile(String path, Quad q) {
    final json = q.toJson();
    return Isolate.run(() => snapToEdges(File(path).readAsBytesSync(), Quad.fromJson(json)));
  }

  static Future<double> autoStraightenFile(String path, EditParams p) {
    final json = p.encode();
    return Isolate.run(() => autoStraighten(File(path).readAsBytesSync(), EditParams.decode(json)));
  }

  /// Ảnh xem trước (JPEG chất lượng cao, chỉ để hiển thị – không dùng làm nguồn xuất).
  static Future<Uint8List> renderPreviewJpg(String path, EditParams p, {int maxSide = 1600}) {
    final json = p.encode();
    return Isolate.run(() {
      final r = render(File(path).readAsBytesSync(), EditParams.decode(json), maxSide: maxSide);
      return img.encodeJpg(r.toImage(), quality: 92);
    });
  }

  /// Xem trước ảnh gốc (không xử lý) – dùng cho màn chỉnh góc và so sánh trước/sau.
  static Future<(Uint8List, int, int)> originalPreview(String path, {int maxSide = 1600}) {
    return Isolate.run(() {
      final full = decodeOriented(File(path).readAsBytesSync());
      final s = downscale(full, maxSide);
      return (img.encodeJpg(s.toImage(), quality: 90), full.width, full.height);
    });
  }

  /// Render đầy đủ độ phân giải và mã hoá PNG lossless.
  static Future<Uint8List> renderFullPng(String path, EditParams p) {
    final json = p.encode();
    return Isolate.run(() {
      final r = render(File(path).readAsBytesSync(), EditParams.decode(json));
      return img.encodePng(r.toImage(), level: 6);
    });
  }
}
