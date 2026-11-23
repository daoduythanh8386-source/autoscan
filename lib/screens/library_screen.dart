import 'dart:io';

import 'package:flutter/material.dart';
import 'package:printing/printing.dart';

import '../core/ids.dart';
import '../models/document.dart';
import '../services/export/export_service.dart';
import '../services/storage/app_storage.dart';
import '../widgets/common.dart';
import 'page_manager_screen.dart';

/// Thư viện tài liệu (mục 17, màn hình 6): danh sách, tìm kiếm, mở, đổi tên,
/// chia sẻ, xoá, thư mục.
class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key});
  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  final storage = AppStorage.instance;
  final _search = TextEditingController();
  List<ScanDocument> _docs = [];
  List<ExportedFile> _files = [];
  List<DocFolder> _folders = [];
  String? _folderId;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final q = _search.text;
    final docs = await storage.listDocuments(query: q);
    final files = await storage.listExports(query: q, folderId: _folderId);
    final folders = await storage.listFolders();
    if (!mounted) return;
    setState(() {
      _docs = _folderId == null ? docs : docs.where((d) => d.folderId == _folderId).toList();
      _files = files;
      _folders = folders;
    });
  }

  String _date(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year} '
      '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Tài liệu đã lưu'),
          bottom: const TabBar(tabs: [Tab(text: 'Phiên scan'), Tab(text: 'File đã xuất')]),
          actions: [
            IconButton(
              tooltip: 'Tạo thư mục',
              icon: const Icon(Icons.create_new_folder_outlined),
              onPressed: () async {
                final n = await promptText(context, 'Tên thư mục mới');
                if (n == null) return;
                await storage.createFolder(n);
                await _load();
              },
            ),
          ],
        ),
        body: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            child: TextField(
              controller: _search,
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                hintText: 'Tìm theo tên hoặc nội dung OCR',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              onChanged: (_) => _load(),
            ),
          ),
          SizedBox(
            height: 48,
            child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 8), children: [
              Padding(
                padding: const EdgeInsets.all(4),
                child: ChoiceChip(
                    label: const Text('Tất cả'),
                    selected: _folderId == null,
                    onSelected: (_) {
                      _folderId = null;
                      _load();
                    }),
              ),
              for (final f in _folders)
                Padding(
                  padding: const EdgeInsets.all(4),
                  child: ChoiceChip(
                      avatar: const Icon(Icons.folder_outlined, size: 16),
                      label: Text(f.name),
                      selected: _folderId == f.id,
                      onSelected: (_) {
                        _folderId = f.id;
                        _load();
                      }),
                ),
            ]),
          ),
          Expanded(
            child: TabBarView(children: [_docList(), _fileList()]),
          ),
        ]),
      ),
    );
  }

  Widget _docList() {
    if (_docs.isEmpty) return const Center(child: Text('Chưa có tài liệu.'));
    return ListView.builder(
      itemCount: _docs.length,
      itemBuilder: (c, i) {
        final d = _docs[i];
        return ListTile(
          leading: d.pages.isEmpty ? const Icon(Icons.description_outlined) : PageThumb(d.pages.first, size: 40),
          title: Text(d.name),
          subtitle: Text('${d.pages.length} trang • ${_date(d.createdAt)}'
              '${d.status == DocStatus.draft ? ' • nháp' : ''}'),
          onTap: () async {
            await Navigator.push(c, MaterialPageRoute(builder: (_) => PageManagerScreen(doc: d)));
            await _load();
          },
          trailing: PopupMenuButton<String>(
            onSelected: (v) async {
              switch (v) {
                case 'rename':
                  final n = await promptText(context, 'Đổi tên', initial: d.name);
                  if (n != null) await storage.renameDocument(d, n);
                  break;
                case 'move':
                  final f = await _pickFolder();
                  if (f != null) await storage.moveDocument(d, f.isEmpty ? null : f);
                  break;
                case 'delete':
                  if (await confirmDialog(context, 'Xoá tài liệu?',
                      'Xoá "${d.name}" cùng ${d.pages.length} ảnh gốc. Các file đã xuất vẫn được giữ.',
                      ok: 'Xoá', destructive: true)) {
                    await storage.deleteDocument(d);
                  }
              }
              await _load();
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'rename', child: Text('Đổi tên')),
              PopupMenuItem(value: 'move', child: Text('Chuyển thư mục')),
              PopupMenuItem(value: 'delete', child: Text('Xoá')),
            ],
          ),
        );
      },
    );
  }

  /// Trả về id thư mục, '' cho thư mục gốc, null nếu huỷ.
  Future<String?> _pickFolder() => showDialog<String>(
        context: context,
        builder: (c) => SimpleDialog(title: const Text('Chọn thư mục'), children: [
          SimpleDialogOption(onPressed: () => Navigator.pop(c, ''), child: const Text('(Không thư mục)')),
          for (final f in _folders)
            SimpleDialogOption(onPressed: () => Navigator.pop(c, f.id), child: Text(f.name)),
        ]),
      );

  Widget _fileList() {
    if (_files.isEmpty) return const Center(child: Text('Chưa có file nào được xuất.'));
    return ListView.builder(
      itemCount: _files.length,
      itemBuilder: (c, i) {
        final f = _files[i];
        final abs = storage.exportAbs(f.relPath);
        return ListTile(
          leading: Icon(switch (f.format) {
            'pdf' => Icons.picture_as_pdf_outlined,
            'gif' => Icons.gif_box_outlined,
            _ => Icons.image_outlined,
          }),
          title: Text(f.fileName),
          subtitle: Text('${f.format.toUpperCase()} • ${f.pageCount} trang • '
              '${formatBytes(f.sizeBytes)} • ${_date(f.createdAt)}'),
          onTap: () => _open(f, abs),
          trailing: PopupMenuButton<String>(
            onSelected: (v) async {
              switch (v) {
                case 'share':
                  await ShareManager.shareFiles([abs], ShareManager.mimeForPath(abs));
                  break;
                case 'rename':
                  await _renameFile(f);
                  break;
                case 'delete':
                  if (await confirmDialog(context, 'Xoá file?', 'Xoá "${f.fileName}" khỏi thiết bị.',
                      ok: 'Xoá', destructive: true)) {
                    await storage.deleteExport(f);
                  }
              }
              await _load();
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'share', child: Text('Chia sẻ')),
              PopupMenuItem(value: 'rename', child: Text('Đổi tên')),
              PopupMenuItem(value: 'delete', child: Text('Xoá')),
            ],
          ),
        );
      },
    );
  }

  Future<void> _renameFile(ExportedFile f) async {
    final base = f.fileName.contains('.') ? f.fileName.substring(0, f.fileName.lastIndexOf('.')) : f.fileName;
    final n = await promptText(context, 'Đổi tên file', initial: base);
    if (n == null) return;
    try {
      await storage.renameExport(f, n);
    } on FileNameConflict catch (e) {
      if (!mounted) return;
      if (await confirmDialog(context, 'Trùng tên', '$e. Thay thế file đó?', ok: 'Thay thế', destructive: true)) {
        await storage.renameExport(f, n, replace: true);
      }
    }
  }

  Future<void> _open(ExportedFile f, String abs) async {
    if (!await File(abs).exists()) {
      if (mounted) showSnack(context, 'File không còn tồn tại.');
      await _load();
      return;
    }
    if (!mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => Scaffold(
          appBar: AppBar(title: Text(f.fileName), actions: [
            IconButton(
              icon: const Icon(Icons.share),
              onPressed: () => ShareManager.shareFiles([abs], ShareManager.mimeForPath(abs)),
            ),
          ]),
          body: f.format == 'pdf'
              ? PdfPreview(
                  build: (_) => File(abs).readAsBytes(),
                  allowPrinting: false,
                  allowSharing: false,
                  canChangePageFormat: false,
                  canChangeOrientation: false,
                  canDebug: false,
                )
              : InteractiveViewer(
                  maxScale: 10,
                  child: Center(child: Image.file(File(abs))),
                ),
        ),
      ),
    );
  }
}
