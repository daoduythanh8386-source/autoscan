import 'dart:convert';

import '../core/geometry.dart';
import '../core/rectify.dart';

/// Chế độ xử lý màu (mục 9 đặc tả).
enum ColorMode {
  original('Màu gốc'),
  colorDocument('Scan rõ chữ'),
  blackWhite('Trắng đen'),
  grayscale('Scan xám');

  final String label;
  const ColorMode(this.label);
}

/// Tham số chỉnh sửa KHÔNG phá huỷ: ảnh gốc không bao giờ bị ghi đè, ảnh đầu ra
/// luôn được dựng lại từ ảnh gốc + các tham số này.
class EditParams {
  /// 4 góc trên ảnh gốc (đã xoay theo EXIF). null = toàn khung (không crop).
  final Quad? corners;

  /// Số lần xoay 90° theo chiều kim đồng hồ, áp dụng sau khi nắn phẳng.
  final int rotation;
  final ColorMode mode;

  /// -1..1
  final double brightness;

  /// -1..1
  final double contrast;

  /// 0..1 (giới hạn để tránh viền giả).
  final double sharpness;

  /// -1 (lạnh) .. 1 (ấm) – cân bằng trắng.
  final double warmth;

  /// 0..1 – mức giảm bóng / làm đều sáng.
  final double shadowReduction;

  /// Góc làm thẳng tinh (độ, chiều kim đồng hồ), áp dụng sau khi nắn phẳng.
  final double fineRotation;

  /// Khổ giấy dùng để xác định tỷ lệ rộng/cao sau khi nắn phẳng.
  final PaperSize paper;

  /// Mô hình nắn giấy cong (JSON của DewarpModel). null = giấy phẳng.
  final Map<String, dynamic>? dewarp;

  const EditParams({
    this.corners,
    this.rotation = 0,
    this.mode = ColorMode.original,
    this.brightness = 0,
    this.contrast = 0,
    this.sharpness = 0,
    this.warmth = 0,
    this.shadowReduction = 0.7,
    this.fineRotation = 0,
    this.paper = PaperSize.auto,
    this.dewarp,
  });

  EditParams copyWith({
    Quad? corners,
    bool clearCorners = false,
    int? rotation,
    ColorMode? mode,
    double? brightness,
    double? contrast,
    double? sharpness,
    double? warmth,
    double? shadowReduction,
    double? fineRotation,
    PaperSize? paper,
    Map<String, dynamic>? dewarp,
    bool clearDewarp = false,
  }) =>
      EditParams(
        corners: clearCorners ? null : (corners ?? this.corners),
        rotation: (rotation ?? this.rotation) % 4,
        mode: mode ?? this.mode,
        brightness: brightness ?? this.brightness,
        contrast: contrast ?? this.contrast,
        sharpness: sharpness ?? this.sharpness,
        warmth: warmth ?? this.warmth,
        shadowReduction: shadowReduction ?? this.shadowReduction,
        fineRotation: fineRotation ?? this.fineRotation,
        paper: paper ?? this.paper,
        dewarp: clearDewarp ? null : (dewarp ?? this.dewarp),
      );

  Map<String, dynamic> toJson() => {
        'corners': corners?.toJson(),
        'rotation': rotation,
        'mode': mode.name,
        'brightness': brightness,
        'contrast': contrast,
        'sharpness': sharpness,
        'warmth': warmth,
        'shadow': shadowReduction,
        'fineRot': fineRotation,
        'paper': paper.name,
        if (dewarp != null) 'dewarp': dewarp,
      };

  factory EditParams.fromJson(Map<String, dynamic> j) => EditParams(
        corners: j['corners'] == null ? null : Quad.fromJson(j['corners'] as List<dynamic>),
        rotation: (j['rotation'] as num?)?.toInt() ?? 0,
        mode: ColorMode.values.firstWhere((m) => m.name == j['mode'],
            orElse: () => ColorMode.original),
        brightness: (j['brightness'] as num?)?.toDouble() ?? 0,
        contrast: (j['contrast'] as num?)?.toDouble() ?? 0,
        sharpness: (j['sharpness'] as num?)?.toDouble() ?? 0,
        warmth: (j['warmth'] as num?)?.toDouble() ?? 0,
        shadowReduction: (j['shadow'] as num?)?.toDouble() ?? 0.7,
        fineRotation: (j['fineRot'] as num?)?.toDouble() ?? 0,
        paper: PaperSize.values.firstWhere((p) => p.name == j['paper'],
            orElse: () => PaperSize.auto),
        dewarp: j['dewarp'] as Map<String, dynamic>?,
      );

  String encode() => jsonEncode(toJson());
  static EditParams decode(String s) => EditParams.fromJson(jsonDecode(s) as Map<String, dynamic>);

  /// Khoá để cache ảnh đã xử lý.
  String get cacheKey => encode().hashCode.toUnsigned(32).toRadixString(16);
}
