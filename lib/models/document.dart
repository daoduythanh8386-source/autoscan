import 'edit_params.dart';

enum DocStatus { draft, saved }

class ScanDocument {
  final String id;
  String name;
  String? folderId;
  final DateTime createdAt;
  DateTime updatedAt;
  DocStatus status;
  List<ScanPage> pages;

  ScanDocument({
    required this.id,
    required this.name,
    this.folderId,
    required this.createdAt,
    required this.updatedAt,
    this.status = DocStatus.draft,
    List<ScanPage>? pages,
  }) : pages = pages ?? [];

  Map<String, Object?> toRow() => {
        'id': id,
        'name': name,
        'folder_id': folderId,
        'created_at': createdAt.millisecondsSinceEpoch,
        'updated_at': updatedAt.millisecondsSinceEpoch,
        'status': status.name,
      };

  factory ScanDocument.fromRow(Map<String, Object?> r) => ScanDocument(
        id: r['id'] as String,
        name: r['name'] as String,
        folderId: r['folder_id'] as String?,
        createdAt: DateTime.fromMillisecondsSinceEpoch(r['created_at'] as int),
        updatedAt: DateTime.fromMillisecondsSinceEpoch(r['updated_at'] as int),
        status: DocStatus.values.firstWhere((s) => s.name == r['status'],
            orElse: () => DocStatus.draft),
      );
}

class ScanPage {
  final String id;
  final String documentId;
  int index;

  /// Đường dẫn tương đối (so với thư mục dữ liệu app) tới ẢNH GỐC – bất biến.
  final String originalRelPath;
  EditParams edit;
  final int width;
  final int height;
  String? ocrText;
  final DateTime createdAt;

  /// Danh sách cảnh báo chất lượng lúc chụp (mã).
  List<String> qualityCodes;

  ScanPage({
    required this.id,
    required this.documentId,
    required this.index,
    required this.originalRelPath,
    required this.edit,
    required this.width,
    required this.height,
    required this.createdAt,
    this.ocrText,
    List<String>? qualityCodes,
  }) : qualityCodes = qualityCodes ?? [];

  Map<String, Object?> toRow() => {
        'id': id,
        'document_id': documentId,
        'idx': index,
        'original_path': originalRelPath,
        'edit_json': edit.encode(),
        'width': width,
        'height': height,
        'ocr_text': ocrText,
        'quality': qualityCodes.join(','),
        'created_at': createdAt.millisecondsSinceEpoch,
      };

  factory ScanPage.fromRow(Map<String, Object?> r) => ScanPage(
        id: r['id'] as String,
        documentId: r['document_id'] as String,
        index: r['idx'] as int,
        originalRelPath: r['original_path'] as String,
        edit: EditParams.decode(r['edit_json'] as String),
        width: r['width'] as int,
        height: r['height'] as int,
        ocrText: r['ocr_text'] as String?,
        qualityCodes: ((r['quality'] as String?) ?? '')
            .split(',')
            .where((s) => s.isNotEmpty)
            .toList(),
        createdAt: DateTime.fromMillisecondsSinceEpoch(r['created_at'] as int),
      );
}

class DocFolder {
  final String id;
  String name;
  final DateTime createdAt;
  DocFolder(this.id, this.name, this.createdAt);

  Map<String, Object?> toRow() =>
      {'id': id, 'name': name, 'created_at': createdAt.millisecondsSinceEpoch};
  factory DocFolder.fromRow(Map<String, Object?> r) => DocFolder(r['id'] as String,
      r['name'] as String, DateTime.fromMillisecondsSinceEpoch(r['created_at'] as int));
}

/// File đã xuất (PDF/PNG/JPG/GIF/ảnh gốc).
class ExportedFile {
  final String id;
  final String? documentId;
  String relPath;
  final String format;
  int sizeBytes;
  int pageCount;
  final DateTime createdAt;
  String? folderId;

  ExportedFile({
    required this.id,
    required this.documentId,
    required this.relPath,
    required this.format,
    required this.sizeBytes,
    required this.pageCount,
    required this.createdAt,
    this.folderId,
  });

  String get fileName => relPath.split('/').last;

  Map<String, Object?> toRow() => {
        'id': id,
        'document_id': documentId,
        'rel_path': relPath,
        'format': format,
        'size': sizeBytes,
        'page_count': pageCount,
        'created_at': createdAt.millisecondsSinceEpoch,
        'folder_id': folderId,
      };

  factory ExportedFile.fromRow(Map<String, Object?> r) => ExportedFile(
        id: r['id'] as String,
        documentId: r['document_id'] as String?,
        relPath: r['rel_path'] as String,
        format: r['format'] as String,
        sizeBytes: r['size'] as int,
        pageCount: r['page_count'] as int,
        createdAt: DateTime.fromMillisecondsSinceEpoch(r['created_at'] as int),
        folderId: r['folder_id'] as String?,
      );
}
