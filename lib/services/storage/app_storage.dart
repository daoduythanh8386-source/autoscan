import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import '../../core/ids.dart';
import '../../models/document.dart';
import '../../models/edit_params.dart';

class StorageFullException implements Exception {
  final String message;
  StorageFullException([this.message = 'Bộ nhớ thiết bị đã đầy. Hãy giải phóng dung lượng rồi thử lại.']);
  @override
  String toString() => message;
}

class FileNameConflict implements Exception {
  final String existingPath;
  FileNameConflict(this.existingPath);
  @override
  String toString() => 'Đã có file trùng tên: ${p.basename(existingPath)}';
}

/// Lưu trữ DEVICE (mục 2.4, 22): SQLite cho metadata, file ảnh/PDF trong thư mục app.
/// Không có bất kỳ kết nối mạng nào trong lớp này.
class AppStorage {
  AppStorage._();
  static final AppStorage instance = AppStorage._();

  static const _channel = MethodChannel('sds/storage');
  static const lowSpaceBytes = 300 * 1024 * 1024;

  late Database _db;
  late Directory internalRoot; // ảnh gốc, cache, DB (ẩn với người dùng)
  late Directory exportRoot; // file xuất (iOS: hiện trong app Tệp)

  Future<void> init() async {
    final support = await getApplicationSupportDirectory();
    final docs = await getApplicationDocumentsDirectory();
    internalRoot = Directory(p.join(support.path, 'sds'));
    exportRoot = Directory(p.join(docs.path, 'APP scan PDF'));
    await internalRoot.create(recursive: true);
    await exportRoot.create(recursive: true);
    await Directory(p.join(internalRoot.path, 'originals')).create(recursive: true);
    await Directory(p.join(internalRoot.path, 'tmp')).create(recursive: true);
    _db = await openDatabase(
      p.join(internalRoot.path, 'sds.db'),
      version: 1,
      onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
      onCreate: (db, _) async {
        await db.execute('''CREATE TABLE folders(
          id TEXT PRIMARY KEY, name TEXT NOT NULL, created_at INTEGER NOT NULL)''');
        await db.execute('''CREATE TABLE documents(
          id TEXT PRIMARY KEY, name TEXT NOT NULL, folder_id TEXT,
          created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL, status TEXT NOT NULL)''');
        await db.execute('''CREATE TABLE pages(
          id TEXT PRIMARY KEY,
          document_id TEXT NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
          idx INTEGER NOT NULL, original_path TEXT NOT NULL, edit_json TEXT NOT NULL,
          width INTEGER NOT NULL, height INTEGER NOT NULL, ocr_text TEXT,
          quality TEXT, created_at INTEGER NOT NULL)''');
        await db.execute('''CREATE TABLE exports(
          id TEXT PRIMARY KEY, document_id TEXT, rel_path TEXT NOT NULL,
          format TEXT NOT NULL, size INTEGER NOT NULL, page_count INTEGER NOT NULL,
          created_at INTEGER NOT NULL, folder_id TEXT)''');
        await db.execute('CREATE INDEX pages_doc ON pages(document_id, idx)');
      },
    );
    await _cleanTmp();
  }

  Future<void> _cleanTmp() async {
    final tmp = Directory(p.join(internalRoot.path, 'tmp'));
    if (await tmp.exists()) {
      await for (final e in tmp.list()) {
        try {
          await e.delete(recursive: true);
        } catch (_) {}
      }
    }
  }

  String internalAbs(String rel) => p.join(internalRoot.path, rel);
  String exportAbs(String rel) => p.join(exportRoot.path, rel);
  Directory get tmpDir => Directory(p.join(internalRoot.path, 'tmp'));

  // ------------------------------------------------------------- dung lượng

  /// Số byte trống (qua kênh native). null nếu nền tảng không hỗ trợ.
  Future<int?> freeBytes() async {
    try {
      final v = await _channel.invokeMethod<int>('freeBytes', {'path': internalRoot.path});
      return v;
    } catch (_) {
      return null;
    }
  }

  Future<bool> isLowOnSpace() async {
    final f = await freeBytes();
    return f != null && f < lowSpaceBytes;
  }

  /// Ghi file an toàn: ghi ra file tạm → kiểm tra kích thước → đổi tên (atomic).
  Future<File> writeBytesAtomic(String absPath, List<int> bytes) async {
    final dir = Directory(p.dirname(absPath));
    await dir.create(recursive: true);
    final tmp = File('$absPath.part');
    try {
      await tmp.writeAsBytes(bytes, flush: true);
      final len = await tmp.length();
      if (len != bytes.length) {
        throw FileSystemException('Ghi file không đầy đủ', absPath);
      }
      return await tmp.rename(absPath);
    } on FileSystemException catch (e) {
      if (await tmp.exists()) await tmp.delete();
      final code = e.osError?.errorCode;
      if (code == 28 /* ENOSPC */) throw StorageFullException();
      rethrow;
    }
  }

  // ------------------------------------------------------------- tài liệu

  Future<ScanDocument> createDraft(String name) async {
    final now = DateTime.now();
    final doc = ScanDocument(id: newId(), name: name, createdAt: now, updatedAt: now);
    await _db.insert('documents', doc.toRow());
    return doc;
  }

  /// Sao chép NGUYÊN VẸN file ảnh nguồn thành ảnh gốc của trang (giữ metadata).
  /// Trang được ghi xuống DB ngay để không mất khi app bị đóng đột ngột.
  Future<ScanPage> addPage(
    ScanDocument doc, {
    required String sourcePath,
    required EditParams edit,
    required int width,
    required int height,
    List<String> qualityCodes = const [],
  }) async {
    final pageId = newId();
    var ext = p.extension(sourcePath).toLowerCase();
    if (ext.isEmpty) ext = '.jpg';
    final rel = p.join('originals', doc.id, '$pageId$ext');
    final bytes = await File(sourcePath).readAsBytes();
    await writeBytesAtomic(internalAbs(rel), bytes);
    final page = ScanPage(
      id: pageId,
      documentId: doc.id,
      index: doc.pages.length,
      originalRelPath: rel,
      edit: edit,
      width: width,
      height: height,
      createdAt: DateTime.now(),
      qualityCodes: qualityCodes,
    );
    await _db.insert('pages', page.toRow());
    doc.pages.add(page);
    await touch(doc);
    return page;
  }

  Future<void> touch(ScanDocument doc) async {
    doc.updatedAt = DateTime.now();
    await _db.update('documents', doc.toRow(), where: 'id = ?', whereArgs: [doc.id]);
  }

  Future<void> updatePage(ScanPage page) async {
    await _db.update('pages', page.toRow(), where: 'id = ?', whereArgs: [page.id]);
  }

  Future<void> deletePage(ScanDocument doc, ScanPage page) async {
    await _db.delete('pages', where: 'id = ?', whereArgs: [page.id]);
    final f = File(internalAbs(page.originalRelPath));
    if (await f.exists()) await f.delete();
    doc.pages.removeWhere((e) => e.id == page.id);
    await reorder(doc, doc.pages);
  }

  Future<void> reorder(ScanDocument doc, List<ScanPage> ordered) async {
    await _db.transaction((txn) async {
      for (var i = 0; i < ordered.length; i++) {
        ordered[i].index = i;
        await txn.update('pages', {'idx': i}, where: 'id = ?', whereArgs: [ordered[i].id]);
      }
    });
    doc.pages = [...ordered];
    await touch(doc);
  }

  Future<void> renameDocument(ScanDocument doc, String name) async {
    doc.name = name.trim().isEmpty ? doc.name : name.trim();
    await touch(doc);
  }

  Future<void> markSaved(ScanDocument doc) async {
    doc.status = DocStatus.saved;
    await touch(doc);
  }

  Future<void> moveDocument(ScanDocument doc, String? folderId) async {
    doc.folderId = folderId;
    await touch(doc);
  }

  Future<List<ScanDocument>> listDocuments({DocStatus? status, String? query}) async {
    final where = <String>[];
    final args = <Object?>[];
    if (status != null) {
      where.add('status = ?');
      args.add(status.name);
    }
    if (query != null && query.trim().isNotEmpty) {
      where.add('(name LIKE ? OR id IN (SELECT document_id FROM pages WHERE ocr_text LIKE ?))');
      args.addAll(['%${query.trim()}%', '%${query.trim()}%']);
    }
    final rows = await _db.query('documents',
        where: where.isEmpty ? null : where.join(' AND '),
        whereArgs: args.isEmpty ? null : args,
        orderBy: 'updated_at DESC');
    final docs = rows.map(ScanDocument.fromRow).toList();
    for (final d in docs) {
      d.pages = await _pagesOf(d.id);
    }
    return docs;
  }

  Future<ScanDocument?> loadDocument(String id) async {
    final rows = await _db.query('documents', where: 'id = ?', whereArgs: [id]);
    if (rows.isEmpty) return null;
    final d = ScanDocument.fromRow(rows.first);
    d.pages = await _pagesOf(id);
    return d;
  }

  Future<List<ScanPage>> _pagesOf(String docId) async {
    final rows = await _db.query('pages',
        where: 'document_id = ?', whereArgs: [docId], orderBy: 'idx ASC');
    return rows.map(ScanPage.fromRow).toList();
  }

  Future<void> deleteDocument(ScanDocument doc) async {
    await _db.delete('pages', where: 'document_id = ?', whereArgs: [doc.id]);
    await _db.delete('documents', where: 'id = ?', whereArgs: [doc.id]);
    final dir = Directory(internalAbs(p.join('originals', doc.id)));
    if (await dir.exists()) await dir.delete(recursive: true);
  }

  /// Kiểm tra tính toàn vẹn: trả về các trang thiếu/hỏng file gốc.
  Future<List<ScanPage>> verifyDocument(ScanDocument doc) async {
    final broken = <ScanPage>[];
    for (final pg in doc.pages) {
      final f = File(internalAbs(pg.originalRelPath));
      if (!await f.exists() || await f.length() == 0) broken.add(pg);
    }
    return broken;
  }

  // ------------------------------------------------------------- thư mục

  Future<List<DocFolder>> listFolders() async {
    final rows = await _db.query('folders', orderBy: 'name COLLATE NOCASE');
    return rows.map(DocFolder.fromRow).toList();
  }

  Future<DocFolder> createFolder(String name) async {
    final f = DocFolder(newId(), sanitizeFileName(name), DateTime.now());
    await Directory(exportAbs(f.name)).create(recursive: true);
    await _db.insert('folders', f.toRow());
    return f;
  }

  Future<String?> folderName(String? id) async {
    if (id == null) return null;
    final rows = await _db.query('folders', where: 'id = ?', whereArgs: [id]);
    return rows.isEmpty ? null : rows.first['name'] as String;
  }

  // ------------------------------------------------------------- file xuất

  /// Trả về đường dẫn tương đối dự kiến; ném [FileNameConflict] nếu trùng
  /// và [replace] = false. Không bao giờ tự ghi đè.
  Future<String> reserveExportPath(String fileName, {String? folderName, bool replace = false}) async {
    final rel = folderName == null ? fileName : p.join(folderName, fileName);
    final abs = exportAbs(rel);
    if (!replace && await File(abs).exists()) throw FileNameConflict(abs);
    return rel;
  }

  Future<ExportedFile> recordExport({
    required String? documentId,
    required String relPath,
    required String format,
    required int pageCount,
    String? folderId,
  }) async {
    final size = await File(exportAbs(relPath)).length();
    await _db.delete('exports', where: 'rel_path = ?', whereArgs: [relPath]);
    final e = ExportedFile(
      id: newId(),
      documentId: documentId,
      relPath: relPath,
      format: format,
      sizeBytes: size,
      pageCount: pageCount,
      createdAt: DateTime.now(),
      folderId: folderId,
    );
    await _db.insert('exports', e.toRow());
    return e;
  }

  Future<List<ExportedFile>> listExports({String? query, String? folderId}) async {
    final where = <String>[];
    final args = <Object?>[];
    if (query != null && query.trim().isNotEmpty) {
      where.add('rel_path LIKE ?');
      args.add('%${query.trim()}%');
    }
    if (folderId != null) {
      where.add('folder_id = ?');
      args.add(folderId);
    }
    final rows = await _db.query('exports',
        where: where.isEmpty ? null : where.join(' AND '),
        whereArgs: args.isEmpty ? null : args,
        orderBy: 'created_at DESC');
    final list = rows.map(ExportedFile.fromRow).toList();
    // Bỏ các bản ghi mà file đã bị xoá bên ngoài app.
    final alive = <ExportedFile>[];
    for (final e in list) {
      if (await File(exportAbs(e.relPath)).exists()) {
        alive.add(e);
      } else {
        await _db.delete('exports', where: 'id = ?', whereArgs: [e.id]);
      }
    }
    return alive;
  }

  Future<void> renameExport(ExportedFile e, String newBaseName, {bool replace = false}) async {
    final ext = p.extension(e.relPath);
    final newName = '${sanitizeFileName(newBaseName)}$ext';
    final newRel = p.join(p.dirname(e.relPath), newName).replaceFirst(RegExp(r'^\./'), '');
    if (newRel == e.relPath) return;
    final target = File(exportAbs(newRel));
    if (await target.exists()) {
      if (!replace) throw FileNameConflict(target.path);
      await target.delete();
      await _db.delete('exports', where: 'rel_path = ?', whereArgs: [newRel]);
    }
    await File(exportAbs(e.relPath)).rename(target.path);
    e.relPath = newRel;
    await _db.update('exports', e.toRow(), where: 'id = ?', whereArgs: [e.id]);
  }

  Future<void> deleteExport(ExportedFile e) async {
    final f = File(exportAbs(e.relPath));
    if (await f.exists()) await f.delete();
    await _db.delete('exports', where: 'id = ?', whereArgs: [e.id]);
  }
}
