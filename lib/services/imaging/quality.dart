import 'dart:math' as math;
import 'dart:typed_data';

import 'document_detector.dart';
import 'enhancer.dart';
import 'pipeline.dart';

enum IssueSeverity { info, warning, critical }

class QualityIssue {
  final String code;
  final String message;
  final IssueSeverity severity;
  const QualityIssue(this.code, this.message, this.severity);
}

/// Kiểm tra chất lượng ảnh ngay sau khi chụp (mục 6).
///
/// LƯU Ý: các ngưỡng dưới đây là giá trị khởi điểm, CHƯA hiệu chuẩn trên bộ 60
/// ảnh mẫu (mục 25). Cần điều chỉnh sau kiểm thử thực tế.
class QualityAssessor {
  static const blurVarThreshold = 35.0;
  static const darkMeanThreshold = 70.0;
  static const overexposedFraction = 0.22;
  static const minLongSide = 1600;

  List<QualityIssue> assess({
    required int fullWidth,
    required int fullHeight,
    required RgbImage small,
    required Uint8List smallGray,
    required DetectionResult detection,
  }) {
    final issues = <QualityIssue>[];
    final w = small.width, h = small.height;

    // Độ nét / rung tay: phương sai Laplacian trên bản 720px.
    final lv = laplacianVariance(smallGray, w, h, step: 1);
    if (lv < blurVarThreshold) {
      issues.add(QualityIssue(
          'blur',
          'Ảnh có thể bị mờ hoặc rung tay (độ nét ${lv.toStringAsFixed(0)}). Nên chụp lại.',
          lv < blurVarThreshold / 2 ? IssueSeverity.critical : IssueSeverity.warning));
    }

    var sum = 0, clipped = 0;
    for (final v in smallGray) {
      sum += v;
      if (v >= 254) clipped++;
    }
    final mean = sum / smallGray.length;
    if (mean < darkMeanThreshold) {
      issues.add(QualityIssue('dark', 'Ảnh thiếu sáng. Hãy bật đèn hoặc flash rồi chụp lại.',
          mean < darkMeanThreshold / 2 ? IssueSeverity.critical : IssueSeverity.warning));
    }
    final clipFrac = clipped / smallGray.length;
    if (clipFrac > overexposedFraction) {
      issues.add(QualityIssue(
          'overexposed',
          'Có vùng cháy sáng (${(clipFrac * 100).toStringAsFixed(0)}% điểm ảnh bão hoà). '
              'Chi tiết trong vùng này không thể khôi phục – nên đổi góc chụp, tránh phản chiếu.',
          IssueSeverity.warning));
    }

    final bg = BackgroundModel.estimate(small.bytes, w, h);
    if (bg.unevenness < 0.55) {
      issues.add(const QualityIssue('shadow',
          'Phát hiện bóng đổ / ánh sáng không đều. Ứng dụng đã tự cân bằng, hãy kiểm tra lại chữ ở vùng tối.',
          IssueSeverity.info));
    }

    if (math.max(fullWidth, fullHeight) < minLongSide) {
      issues.add(QualityIssue('low_res',
          'Độ phân giải thấp (${fullWidth}x$fullHeight). Chữ nhỏ có thể không đọc được.',
          IssueSeverity.warning));
    }

    if (detection.quad == null) {
      issues.add(const QualityIssue('no_document',
          'Không nhận diện chắc chắn được tài liệu. Vui lòng chỉnh 4 góc bằng tay.',
          IssueSeverity.warning));
    } else {
      if (detection.issues.contains('corner_out_of_frame')) {
        issues.add(const QualityIssue('corner_cut',
            'Một hoặc nhiều góc tài liệu có thể nằm ngoài khung hình (mất góc).',
            IssueSeverity.warning));
      }
      if (detection.issues.contains('occluded')) {
        issues.add(const QualityIssue('occluded',
            'Tài liệu có thể bị che khuất một phần (tay, vật cản).', IssueSeverity.warning));
      }
      if (detection.fill < 0.25) {
        issues.add(const QualityIssue('small_doc',
            'Tài liệu chiếm diện tích nhỏ trong khung – chữ có thể quá nhỏ. Nên đưa máy lại gần.',
            IssueSeverity.warning));
      }
    }
    return issues;
  }
}
