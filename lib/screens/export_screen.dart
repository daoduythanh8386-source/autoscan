import 'package:flutter/material.dart';
import 'package:printing/printing.dart';

import '../models/document.dart';
import '../services/export/export_core.dart';
import '../services/export/export_service.dart';
import '../services/settings_service.dart';
import '../services/storage/app_storage.dart';
import '../widgets/common.dart';

/// Xuất file (mục 12–16) + lưu + chia sẻ (mục 18).
class ExportScreen extends StatefulWidget {
  final ScanDocument doc;
  final List<ScanPage> pages;
  const ExportScreen({super.key, required this.doc, required this.pages});
  @override
  State<ExportScreen> createState() => _ExportScreenState();
}

class _ExportScreenState extends State<ExportScreen> {
  final storage = AppStorage.instance;
  late final service = ExportService(storage);
  final settings = SettingsService.instance.value;

  ExportFormat _format = ExportFormat.pdf;
  late final _name = TextEditingController(text: widget.doc.name);
  late PdfPageSize _size = settings.pdfSize;
  late PdfImageQuality _pdfQ = settings.pdfQuality;
  late double _jpgQ = settings.jpgQuality.toDouble();
  late bool _ocr = settings.ocrEnabled;
  double _gifSeconds = 1.5;
  bool _gifLoop = true;
  int _gifWidth = 720;
  List<DocFolder> _folders = [];
  DocFolder? _folder;

  @override
  void initState() {
    super.initState();
    storage.listFolders().then((f) => setState(() => _folders = f));
  }

  ExportRequest _request({bool replace = false}) => ExportRequest(
        doc: widget.doc,
        pages: widget.pages,
        format: _format,
        baseName: _name.text.trim().isEmpty ? widget.doc.name : _name.text.trim(),
        folder: _folder,
        replaceExisting: replace,
        pdfSize: _size,
        pdfQuality: _pdfQ,
        jpgQuality: _jpgQ.round(),
        gif: GifOptions(
            frameMs: (_gifSeconds * 1000).round(),
            loopCount: _gifLoop ? 0 : 1,
            width: _gifWidth),
        ocr: _ocr && _format == ExportFormat.pdf,
      );

  Future<void> _preview() async {
    final bytes = await runWithProgress(
        context, 'Đang dựng bản xem trước…', () => service.previewPdf(_request()));
    if (!mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => Scaffold(
          appBar: AppBar(title: const Text('Xem trước PDF')),
          body: PdfPreview(
            build: (_) async => bytes,
            allowPrinting: false,
            allowSharing: false,
            canChangePageFormat: false,
            canChangeOrientation: false,
            canDebug: false,
          ),
        ),
      ),
    );
  }

  Future<void> _run({required bool share}) async {
    var req = _request();
    ExportOutcome? out;
    while (out == null) {
      try {
        out = await runWithProgress(context, 'Đang xuất ${_format.label}…', () => service.export(req));
      } on FileNameConflict catch (e) {
        if (!mounted) return;
        final choice = await showDialog<String>(
          context: context,
          builder: (c) => AlertDialog(
            title: const Text('Trùng tên file'),
            content: Text('$e\nBạn muốn đổi tên hay thay thế file cũ?'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(c), child: const Text('Huỷ')),
              TextButton(onPressed: () => Navigator.pop(c, 'rename'), child: const Text('Đổi tên')),
              FilledButton(onPressed: () => Navigator.pop(c, 'replace'), child: const Text('Thay thế')),
            ],
          ),
        );
        if (!mounted || choice == null) return;
        if (choice == 'replace') {
          req = _request(replace: true);
        } else {
          final n = await promptText(context, 'Tên file mới', initial: '${_name.text} (2)');
          if (n == null) return;
          _name.text = n;
          req = _request();
        }
      } on StorageFullException catch (e) {
        if (mounted) showSnack(context, e.message);
        return;
      } catch (e) {
        if (mounted) showSnack(context, 'Xuất file lỗi: $e');
        return;
      }
    }
    if (!mounted) return;
    final result = out!;
    final paths = result.absPaths(storage);
    await showDialog<void>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Đã lưu trên thiết bị'),
        content: SingleChildScrollView(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            for (final f in result.files) Text('• ${f.fileName}'),
            const SizedBox(height: 10),
            const Text('Kiểm tra file:', style: TextStyle(fontWeight: FontWeight.w600)),
            for (final ch in result.checks)
              Text('${switch (ch.status) {
                VerifyStatus.pass => '✅ PASS',
                VerifyStatus.fail => '❌ NEEDS FIX',
                VerifyStatus.notVerified => '⚠️ NOT VERIFIED',
              }} – ${ch.message}'),
            if (result.warnings.isNotEmpty) ...[
              const SizedBox(height: 10),
              for (final w in result.warnings) Text('⚠️ $w'),
            ],
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('Đóng')),
          if (!share)
            FilledButton.icon(
              onPressed: () {
                Navigator.pop(c);
                ShareManager.shareFiles(paths, _format.mime);
              },
              icon: const Icon(Icons.share),
              label: const Text('Chia sẻ'),
            ),
        ],
      ),
    );
    if (share) {
      await ShareManager.shareFiles(
          paths, _format == ExportFormat.original ? ShareManager.mimeForPath(paths.first) : _format.mime);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Xuất ${widget.pages.length} trang')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        Text('Định dạng', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 6),
        Wrap(spacing: 8, runSpacing: 4, children: [
          for (final f in ExportFormat.values)
            ChoiceChip(
                label: Text(f.label),
                selected: _format == f,
                onSelected: (_) => setState(() => _format = f)),
        ]),
        const SizedBox(height: 16),
        TextField(
          controller: _name,
          decoration: const InputDecoration(
              labelText: 'Tên file (có thể dùng tiếng Việt có dấu)', border: OutlineInputBorder()),
        ),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(
            child: DropdownButtonFormField<DocFolder?>(
              value: _folder,
              decoration: const InputDecoration(labelText: 'Thư mục lưu', border: OutlineInputBorder()),
              items: [
                const DropdownMenuItem(value: null, child: Text('APP scan PDF (gốc)')),
                for (final f in _folders) DropdownMenuItem(value: f, child: Text(f.name)),
              ],
              onChanged: (v) => setState(() => _folder = v),
            ),
          ),
          IconButton(
            tooltip: 'Tạo thư mục',
            icon: const Icon(Icons.create_new_folder_outlined),
            onPressed: () async {
              final n = await promptText(context, 'Tên thư mục mới');
              if (n == null) return;
              final f = await storage.createFolder(n);
              final all = await storage.listFolders();
              setState(() {
                _folders = all;
                _folder = all.firstWhere((e) => e.id == f.id);
              });
            },
          ),
        ]),
        const Divider(height: 32),
        ..._options(),
      ]),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(children: [
            if (_format == ExportFormat.pdf)
              IconButton.outlined(
                  tooltip: 'Xem trước PDF',
                  onPressed: _preview,
                  icon: const Icon(Icons.preview_outlined)),
            const SizedBox(width: 8),
            Expanded(
                child: OutlinedButton(
                    onPressed: () => _run(share: false), child: const Text('Lưu'))),
            const SizedBox(width: 8),
            Expanded(
              child: FilledButton.icon(
                  onPressed: () => _run(share: true),
                  icon: const Icon(Icons.share),
                  label: const Text('Lưu & chia sẻ')),
            ),
          ]),
        ),
      ),
    );
  }

  List<Widget> _options() {
    switch (_format) {
      case ExportFormat.pdf:
        return [
          DropdownButtonFormField<PdfPageSize>(
            value: _size,
            decoration: const InputDecoration(labelText: 'Khổ giấy', border: OutlineInputBorder()),
            items: [for (final s in PdfPageSize.values) DropdownMenuItem(value: s, child: Text(s.label))],
            onChanged: (v) => setState(() => _size = v!),
          ),
          const SizedBox(height: 12),
          Text('Chất lượng ảnh trong PDF', style: Theme.of(context).textTheme.titleSmall),
          for (final q in PdfImageQuality.values)
            RadioListTile<PdfImageQuality>(
              dense: true,
              value: q,
              groupValue: _pdfQ,
              title: Text(q.label),
              onChanged: (v) => setState(() => _pdfQ = v!),
            ),
          SwitchListTile(
            value: _ocr,
            onChanged: (v) => setState(() => _ocr = v),
            title: const Text('OCR – thêm lớp chữ ẩn (tìm kiếm, sao chép)'),
            subtitle: const Text(
                'Chạy trên thiết bị. OCR có thể nhận dạng sai, đặc biệt số liệu – không thay đổi ảnh.'),
          ),
        ];
      case ExportFormat.png:
        return const [
          ListTile(
            leading: Icon(Icons.verified_outlined),
            title: Text('PNG lossless, giữ nguyên độ phân giải'),
            subtitle: Text('Mỗi trang một file. Ưu tiên khi cần giữ chất lượng tối đa.'),
          ),
        ];
      case ExportFormat.jpg:
        return [
          Text('Chất lượng JPG: ${_jpgQ.round()}', style: Theme.of(context).textTheme.titleSmall),
          Slider(value: _jpgQ, min: 60, max: 100, divisions: 40, label: '${_jpgQ.round()}',
              onChanged: (v) => setState(() => _jpgQ = v)),
          const Text('Mã hoá 1 lần từ ảnh lossless (không nén chồng). '
              'Dưới 85 có thể làm nhoè nét chữ nhỏ và viền dấu đỏ.', style: TextStyle(fontSize: 12)),
        ];
      case ExportFormat.gif:
        return [
          Card(
            color: Theme.of(context).colorScheme.tertiaryContainer,
            child: const Padding(
              padding: EdgeInsets.all(12),
              child: Text('GIF chỉ hỗ trợ tối đa 256 màu. Chỉ dùng để xem nhanh/chia sẻ, '
                  'KHÔNG dùng làm định dạng lưu trữ tài liệu chất lượng cao.'),
            ),
          ),
          Text('Thời gian mỗi khung: ${_gifSeconds.toStringAsFixed(1)} giây'),
          Slider(value: _gifSeconds, min: 0.2, max: 5, divisions: 48,
              onChanged: (v) => setState(() => _gifSeconds = v)),
          SwitchListTile(
              value: _gifLoop, onChanged: (v) => setState(() => _gifLoop = v), title: const Text('Lặp vô hạn')),
          DropdownButtonFormField<int>(
            value: _gifWidth,
            decoration: const InputDecoration(labelText: 'Chiều rộng đầu ra', border: OutlineInputBorder()),
            items: const [
              DropdownMenuItem(value: 480, child: Text('480 px')),
              DropdownMenuItem(value: 720, child: Text('720 px')),
              DropdownMenuItem(value: 1080, child: Text('1080 px')),
              DropdownMenuItem(value: 1600, child: Text('1600 px')),
            ],
            onChanged: (v) => setState(() => _gifWidth = v!),
          ),
        ];
      case ExportFormat.original:
        return const [
          ListTile(
            leading: Icon(Icons.image_outlined),
            title: Text('Xuất ảnh gốc'),
            subtitle: Text('Sao chép nguyên vẹn từng byte: không crop, không căn chỉnh, '
                'không chỉnh sáng, không làm nét, không giảm kích thước, giữ metadata.'),
          ),
        ];
    }
  }
}
