import 'package:flutter/material.dart';

import '../models/document.dart';
import '../services/storage/app_storage.dart';
import '../widgets/common.dart';
import 'camera_screen.dart';
import 'editor_screen.dart';
import 'export_screen.dart';
import 'import_flow.dart';

/// Quản lý nhiều trang (mục 11): thêm, xoá, xoay, sắp xếp, xem trước, chọn trang xuất.
class PageManagerScreen extends StatefulWidget {
  final ScanDocument doc;
  const PageManagerScreen({super.key, required this.doc});
  @override
  State<PageManagerScreen> createState() => _PageManagerScreenState();
}

class _PageManagerScreenState extends State<PageManagerScreen> {
  final storage = AppStorage.instance;
  late final Set<String> _selected = {for (final p in widget.doc.pages) p.id};
  List<ScanPage> _broken = [];

  ScanDocument get doc => widget.doc;

  @override
  void initState() {
    super.initState();
    _check();
  }

  Future<void> _check() async {
    final b = await storage.verifyDocument(doc);
    if (mounted) setState(() => _broken = b);
  }

  Future<void> _rename() async {
    final n = await promptText(context, 'Đổi tên tài liệu', initial: doc.name);
    if (n == null) return;
    await storage.renameDocument(doc, n);
    setState(() {});
  }

  Future<void> _rotate(ScanPage p) async {
    p.edit = p.edit.copyWith(rotation: p.edit.rotation + 1);
    await storage.updatePage(p);
    ThumbnailCache.evict(p.id);
    setState(() {});
  }

  Future<void> _delete(ScanPage p) async {
    if (!await confirmDialog(context, 'Xoá trang ${p.index + 1}?',
        'Ảnh gốc của trang này sẽ bị xoá khỏi thiết bị.',
        ok: 'Xoá', destructive: true)) {
      return;
    }
    await storage.deletePage(doc, p);
    _selected.remove(p.id);
    ThumbnailCache.evict(p.id);
    setState(() {});
  }

  Future<void> _addFromCamera() async {
    await Navigator.push(context,
        MaterialPageRoute(builder: (_) => CameraScreen(doc: doc, returnOnDone: true)));
    _selected.addAll(doc.pages.map((e) => e.id));
    setState(() {});
  }

  Future<void> _addFromGallery() async {
    await importFromGallery(context, doc);
    _selected.addAll(doc.pages.map((e) => e.id));
    if (mounted) setState(() {});
  }

  Future<void> _export() async {
    final pages = doc.pages.where((p) => _selected.contains(p.id)).toList();
    if (pages.isEmpty) {
      showSnack(context, 'Hãy chọn ít nhất 1 trang để xuất.');
      return;
    }
    await storage.markSaved(doc);
    if (!mounted) return;
    await Navigator.push(
        context, MaterialPageRoute(builder: (_) => ExportScreen(doc: doc, pages: pages)));
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final pages = doc.pages;
    return Scaffold(
      appBar: AppBar(
        title: GestureDetector(onTap: _rename, child: Text(doc.name, overflow: TextOverflow.ellipsis)),
        actions: [
          IconButton(tooltip: 'Đổi tên', onPressed: _rename, icon: const Icon(Icons.edit_outlined)),
          IconButton(
            tooltip: 'Lưu và về trang chủ',
            icon: const Icon(Icons.save_outlined),
            onPressed: () async {
              await storage.markSaved(doc);
              if (context.mounted) {
                showSnack(context, 'Đã lưu "${doc.name}"');
                Navigator.popUntil(context, (r) => r.isFirst);
              }
            },
          ),
        ],
      ),
      body: Column(children: [
        if (_broken.isNotEmpty)
          MaterialBanner(
            content: Text('${_broken.length} trang bị thiếu/hỏng file ảnh gốc.'),
            actions: [
              TextButton(
                onPressed: () async {
                  for (final b in _broken) {
                    await storage.deletePage(doc, b);
                  }
                  await _check();
                },
                child: const Text('Gỡ trang hỏng'),
              ),
            ],
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 8, 0),
          child: Row(children: [
            Text('${pages.length} trang • đã chọn ${_selected.length}'),
            const Spacer(),
            TextButton(
              onPressed: () => setState(() {
                if (_selected.length == pages.length) {
                  _selected.clear();
                } else {
                  _selected.addAll(pages.map((e) => e.id));
                }
              }),
              child: Text(_selected.length == pages.length ? 'Bỏ chọn' : 'Chọn tất cả'),
            ),
          ]),
        ),
        Expanded(
          child: pages.isEmpty
              ? const Center(child: Text('Chưa có trang nào. Bấm "Chụp thêm" để bắt đầu.'))
              : ReorderableListView.builder(
                  padding: const EdgeInsets.only(bottom: 100),
                  itemCount: pages.length,
                  onReorder: (from, to) async {
                    final list = [...pages];
                    if (to > from) to--;
                    final item = list.removeAt(from);
                    list.insert(to, item);
                    await storage.reorder(doc, list);
                    setState(() {});
                  },
                  itemBuilder: (c, i) {
                    final p = pages[i];
                    return Card(
                      key: ValueKey(p.id),
                      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                      child: InkWell(
                        onTap: () async {
                          await Navigator.push(c,
                              MaterialPageRoute(builder: (_) => EditorScreen(doc: doc, page: p)));
                          setState(() {});
                        },
                        child: Padding(
                          padding: const EdgeInsets.all(8),
                          child: Row(children: [
                            Checkbox(
                              value: _selected.contains(p.id),
                              onChanged: (v) => setState(() =>
                                  v == true ? _selected.add(p.id) : _selected.remove(p.id)),
                            ),
                            PageThumb(p, size: 64),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                Text('Trang ${i + 1}',
                                    style: const TextStyle(fontWeight: FontWeight.w600)),
                                Text(p.edit.mode.label, style: const TextStyle(fontSize: 12)),
                                if (p.edit.corners == null)
                                  const Text('Chưa crop – nên chỉnh 4 góc',
                                      style: TextStyle(fontSize: 12, color: Colors.orange)),
                                if (p.qualityCodes.any((e) => e != 'shadow'))
                                  const Text('Có cảnh báo chất lượng',
                                      style: TextStyle(fontSize: 12, color: Colors.orange)),
                              ]),
                            ),
                            IconButton(
                                tooltip: 'Xoay',
                                onPressed: () => _rotate(p),
                                icon: const Icon(Icons.rotate_right)),
                            IconButton(
                                tooltip: 'Xoá',
                                onPressed: () => _delete(p),
                                icon: const Icon(Icons.delete_outline)),
                            ReorderableDragStartListener(
                                index: i, child: const Icon(Icons.drag_handle)),
                          ]),
                        ),
                      ),
                    );
                  },
                ),
        ),
      ]),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(children: [
            Expanded(
              child: OutlinedButton.icon(
                  onPressed: _addFromCamera,
                  icon: const Icon(Icons.add_a_photo_outlined),
                  label: const Text('Chụp thêm')),
            ),
            const SizedBox(width: 8),
            IconButton.outlined(
                tooltip: 'Thêm từ thư viện',
                onPressed: _addFromGallery,
                icon: const Icon(Icons.photo_library_outlined)),
            const SizedBox(width: 8),
            Expanded(
              child: FilledButton.icon(
                  onPressed: pages.isEmpty ? null : _export,
                  icon: const Icon(Icons.ios_share),
                  label: const Text('Xuất file')),
            ),
          ]),
        ),
      ),
    );
  }
}
