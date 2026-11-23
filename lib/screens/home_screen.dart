import 'package:flutter/material.dart';

import '../core/ids.dart';
import '../models/document.dart';
import '../services/storage/app_storage.dart';
import '../widgets/brand.dart';
import '../widgets/common.dart';
import 'camera_screen.dart';
import 'import_flow.dart';
import 'library_screen.dart';
import 'page_manager_screen.dart';
import 'settings_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final storage = AppStorage.instance;
  List<ScanDocument> drafts = [];
  bool lowSpace = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final d = await storage.listDocuments(status: DocStatus.draft);
    // Bản nháp rỗng (chưa chụp trang nào) thì dọn đi.
    for (final doc in d.where((e) => e.pages.isEmpty)) {
      await storage.deleteDocument(doc);
    }
    final low = await storage.isLowOnSpace();
    if (!mounted) return;
    setState(() {
      drafts = d.where((e) => e.pages.isNotEmpty).toList();
      lowSpace = low;
    });
  }

  Future<void> _newScan() async {
    final doc = await storage.createDraft(defaultDocName(DateTime.now()));
    if (!mounted) return;
    await Navigator.push(context, MaterialPageRoute(builder: (_) => CameraScreen(doc: doc)));
    await _refresh();
  }

  Future<void> _import() async {
    final doc = await storage.createDraft(defaultDocName(DateTime.now()));
    if (!mounted) return;
    final added = await importFromGallery(context, doc);
    if (!mounted) return;
    if (added > 0) {
      await Navigator.push(context, MaterialPageRoute(builder: (_) => PageManagerScreen(doc: doc)));
    }
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: ListView(
          padding: EdgeInsets.zero,
          children: [
            BrandHeader(
              trailing: IconButton(
                tooltip: 'Cài đặt',
                icon: const Icon(Icons.settings_rounded, color: Colors.white, size: 28),
                onPressed: () => Navigator.push(
                    context, MaterialPageRoute(builder: (_) => const SettingsScreen())),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 18, 16, 0),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                if (lowSpace)
                  Card(
                    color: cs.errorContainer,
                    child: const ListTile(
                      leading: Icon(Icons.sd_storage_outlined),
                      title: Text('Bộ nhớ gần đầy'),
                      subtitle: Text('Hãy giải phóng dung lượng để tránh lỗi khi chụp hoặc xuất file.'),
                    ),
                  ),
                GradientButton(
                  label: 'Scan tài liệu',
                  subtitle: 'Tự nhận 4 góc • nắn phẳng • làm sáng',
                  icon: Icons.document_scanner_rounded,
                  onTap: _newScan,
                  height: 104,
                ),
                const SizedBox(height: 14),
                Row(children: [
                  Expanded(
                    child: ActionTile(
                      label: 'Chọn ảnh',
                      icon: Icons.photo_library_rounded,
                      gradient: Brand.tealGradient,
                      onTap: _import,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: ActionTile(
                      label: 'Tài liệu\nđã lưu',
                      icon: Icons.folder_rounded,
                      gradient: Brand.amberGradient,
                      onTap: () async {
                        await Navigator.push(
                            context, MaterialPageRoute(builder: (_) => const LibraryScreen()));
                        await _refresh();
                      },
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: ActionTile(
                      label: 'Cài đặt',
                      icon: Icons.tune_rounded,
                      gradient: Brand.coralGradient,
                      onTap: () => Navigator.push(
                          context, MaterialPageRoute(builder: (_) => const SettingsScreen())),
                    ),
                  ),
                ]),
                const SizedBox(height: 22),
                if (drafts.isNotEmpty) ...[
                  const Text('Phiên scan chưa hoàn tất',
                      style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: Brand.ink)),
                  const SizedBox(height: 2),
                  Text('Trang đã chụp được lưu tự động, kể cả khi app bị đóng đột ngột.',
                      style: Theme.of(context).textTheme.bodySmall),
                  const SizedBox(height: 8),
                  for (final d in drafts)
                    Card(
                      child: ListTile(
                        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                        leading: PageThumb(d.pages.first, size: 40),
                        title: Text(d.name, style: const TextStyle(fontWeight: FontWeight.w700)),
                        subtitle: Text('${d.pages.length} trang • nháp'),
                        trailing: IconButton(
                          icon: const Icon(Icons.delete_outline_rounded),
                          tooltip: 'Xoá bản nháp',
                          onPressed: () async {
                            if (await confirmDialog(context, 'Xoá bản nháp?',
                                'Xoá "${d.name}" và ${d.pages.length} ảnh đã chụp. Không thể hoàn tác.',
                                ok: 'Xoá', destructive: true)) {
                              await storage.deleteDocument(d);
                              await _refresh();
                            }
                          },
                        ),
                        onTap: () async {
                          await Navigator.push(context,
                              MaterialPageRoute(builder: (_) => PageManagerScreen(doc: d)));
                          await _refresh();
                        },
                      ),
                    ),
                  const SizedBox(height: 14),
                ],
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: Brand.teal.withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: const Row(children: [
                    Icon(Icons.lock_rounded, color: Brand.teal),
                    SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        'Dữ liệu chỉ lưu trên điện thoại này. Không cần đăng nhập, không cần Internet, '
                        'chỉ chia sẻ khi bạn bấm Chia sẻ.',
                        style: TextStyle(fontSize: 13),
                      ),
                    ),
                  ]),
                ),
              ]),
            ),
            const SizedBox(height: 8),
            const BrandFooter(),
          ],
        ),
      ),
    );
  }
}
