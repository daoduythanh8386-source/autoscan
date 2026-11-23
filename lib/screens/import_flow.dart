import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../models/document.dart';
import '../models/edit_params.dart';
import '../services/imaging/pipeline.dart';
import '../services/imaging/quality.dart';
import '../services/settings_service.dart';
import '../services/storage/app_storage.dart';
import '../widgets/common.dart';

/// Phân tích ảnh vừa chụp/nhập và thêm vào tài liệu. Trả về trang + phân tích.
Future<(ScanPage, CaptureAnalysis)> addAnalyzedPage(ScanDocument doc, String sourcePath) async {
  final storage = AppStorage.instance;
  final settings = SettingsService.instance.value;
  // Thứ tự an toàn: lưu ảnh gốc vào bộ nhớ app TRƯỚC (không mất trang nếu app bị
  // đóng giữa chừng), rồi mới phân tích và cập nhật tham số.
  final page = await storage.addPage(
    doc,
    sourcePath: sourcePath,
    edit: EditParams(mode: settings.defaultMode),
    width: 0,
    height: 0,
  );
  CaptureAnalysis analysis;
  try {
    analysis = await ImagePipeline.analyzeFile(storage.internalAbs(page.originalRelPath));
  } catch (_) {
    await storage.deletePage(doc, page);
    rethrow;
  }
  final updated = ScanPage(
    id: page.id,
    documentId: page.documentId,
    index: page.index,
    originalRelPath: page.originalRelPath,
    edit: page.edit.copyWith(
        corners: analysis.corners,
        fineRotation: analysis.suggestedFineRotation,
        dewarp: analysis.dewarp),
    width: analysis.width,
    height: analysis.height,
    createdAt: page.createdAt,
    qualityCodes: analysis.qualityIssues.map((e) => e.code).toList(),
  );
  await storage.updatePage(updated);
  doc.pages[doc.pages.indexWhere((p) => p.id == page.id)] = updated;
  return (updated, analysis);
}

/// Nhập nhiều ảnh từ thư viện. Ảnh được sao chép nguyên vẹn làm ảnh gốc.
Future<int> importFromGallery(BuildContext context, ScanDocument doc) async {
  final picker = ImagePicker();
  List<XFile> files;
  try {
    // Không truyền imageQuality/maxWidth để không bị nén/giảm kích thước.
    files = await picker.pickMultiImage(requestFullMetadata: true);
  } catch (e) {
    if (context.mounted) showSnack(context, 'Không mở được thư viện ảnh: $e');
    return 0;
  }
  if (files.isEmpty || !context.mounted) return 0;
  var added = 0;
  final problems = <String>[];
  await runWithProgress(context, 'Đang nhập ${files.length} ảnh…', () async {
    for (final f in files) {
      try {
        final (_, a) = await addAnalyzedPage(doc, f.path);
        added++;
        final crit = a.qualityIssues.where((i) => i.severity != IssueSeverity.info);
        if (crit.isNotEmpty) problems.add('${f.name}: ${crit.first.message}');
        if (!a.autoCropReliable) problems.add('${f.name}: cần chỉnh 4 góc bằng tay.');
      } on FormatException {
        problems.add('${f.name}: định dạng không hỗ trợ (ví dụ HEIC). '
            'Trên iPhone: Cài đặt › Camera › Định dạng › "Tương thích nhất".');
      } on StorageFullException catch (e) {
        problems.add(e.message);
        break;
      }
    }
  });
  if (problems.isNotEmpty && context.mounted) {
    await showDialog<void>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Lưu ý về ảnh đã nhập'),
        content: SingleChildScrollView(child: Text(problems.join('\n\n'))),
        actions: [FilledButton(onPressed: () => Navigator.pop(c), child: const Text('Đã hiểu'))],
      ),
    );
  }
  return added;
}
