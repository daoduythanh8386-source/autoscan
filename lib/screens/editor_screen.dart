import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../core/geometry.dart';
import '../core/rectify.dart';
import '../models/document.dart';
import '../models/edit_params.dart';
import '../services/imaging/pipeline.dart';
import '../services/settings_service.dart';
import '../services/storage/app_storage.dart';
import '../widgets/common.dart';
import '../widgets/corner_editor.dart';

/// Màn hình xem & chỉnh sửa (mục 10). Mọi chỉnh sửa là tham số – ảnh gốc
/// không bao giờ bị ghi đè; có hoàn tác/làm lại/khôi phục ảnh gốc.
class EditorScreen extends StatefulWidget {
  final ScanDocument doc;
  final ScanPage page;
  final bool startWithCorners;
  const EditorScreen(
      {super.key, required this.doc, required this.page, this.startWithCorners = false});

  @override
  State<EditorScreen> createState() => _EditorScreenState();
}

class _EditorScreenState extends State<EditorScreen> {
  final storage = AppStorage.instance;
  late List<EditParams> _history = [widget.page.edit];
  int _h = 0;
  EditParams get _p => _history[_h];

  int _tab = 0;
  Uint8List? _preview;
  Uint8List? _originalJpg;
  ui.Image? _originalUi;
  int _fullW = 0, _fullH = 0;
  bool _rendering = false;
  bool _showBefore = false;
  bool _grid = false;
  Timer? _debounce;
  int _renderSeq = 0;
  Quad? _liveQuad;
  String? _aspectText;

  String get _path => storage.internalAbs(widget.page.originalRelPath);

  @override
  void initState() {
    super.initState();
    _tab = widget.startWithCorners ? 0 : 1;
    _loadOriginal();
    _render();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _originalUi?.dispose();
    super.dispose();
  }

  Future<void> _loadOriginal() async {
    final (jpg, w, h) = await ImagePipeline.originalPreview(_path);
    final codec = await ui.instantiateImageCodec(jpg);
    final frame = await codec.getNextFrame();
    if (!mounted) return;
    setState(() {
      _originalJpg = jpg;
      _originalUi = frame.image;
      _fullW = w;
      _fullH = h;
    });
  }

  void _render({bool debounce = false}) {
    _debounce?.cancel();
    if (debounce) {
      _debounce = Timer(const Duration(milliseconds: 220), () => _render());
      return;
    }
    final seq = ++_renderSeq;
    setState(() => _rendering = true);
    final p = _p;
    ImagePipeline.renderPreviewJpg(_path, p).then((b) {
      if (!mounted || seq != _renderSeq) return;
      setState(() {
        _preview = b;
        _rendering = false;
      });
      _updateAspectText(p);
    }).catchError((Object e) {
      if (mounted) {
        setState(() => _rendering = false);
        showSnack(context, 'Lỗi xử lý ảnh: $e');
      }
    });
  }

  String? _aspectKey;

  Future<void> _updateAspectText(EditParams p) async {
    final key = '${p.corners?.toJson()}|${p.paper.name}';
    if (key == _aspectKey) return; // chỉ tính lại khi góc/khổ giấy đổi
    _aspectKey = key;
    final a = await ImagePipeline.aspectInfoFile(_path, p);
    if (!mounted) return;
    setState(() {
      if (a == null) {
        _aspectText = null;
      } else {
        final long = a.ratio >= 1 ? a.ratio : 1 / a.ratio;
        final src = switch (a.focalSource) {
          'exif' => 'tiêu cự EXIF',
          'quad' => 'tiêu cự tính từ phối cảnh',
          _ => 'tiêu cự mặc định',
        };
        _aspectText = 'Tỷ lệ 1 : ${long.toStringAsFixed(3)}'
            '${a.snapped != null ? ' • khổ ${a.snapped!.label}' : ''} • $src';
      }
    });
  }

  Future<void> _snapEdges() async {
    final c = _p.corners;
    if (c == null) {
      showSnack(context, 'Hãy kéo 4 góc về gần mép giấy trước.');
      return;
    }
    final q = await runWithProgress(
        context, 'Đang bắt dính vào mép giấy…', () => ImagePipeline.snapToEdgesFile(_path, c));
    if (!mounted) return;
    if (q.maxDisplacement(c) < 0.5) {
      showSnack(context, 'Các góc đã nằm đúng mép giấy.');
      return;
    }
    await _commit(_p.copyWith(corners: q, clearDewarp: true));
  }

  Future<void> _dewarp() async {
    final c = _p.corners;
    if (c == null) {
      showSnack(context, 'Hãy đặt 4 góc tài liệu trước.');
      return;
    }
    final (q, model, kind) = await runWithProgress(
        context, 'Đang phân tích độ cong của giấy…', () => ImagePipeline.dewarpFile(_path, c));
    if (!mounted) return;
    if (model == null) {
      showSnack(context, 'Giấy phẳng – không cần nắn cong.');
      return;
    }
    await _commit(_p.copyWith(corners: q, dewarp: model));
    if (mounted) {
      showSnack(context, kind == 'curl' ? 'Đã nắn mép quăn bằng mô hình 3D.' : 'Đã nắn theo mép giấy cong.');
    }
  }

  Future<void> _autoStraighten() async {
    final a = await runWithProgress(context, 'Đang đo độ nghiêng dòng chữ…',
        () => ImagePipeline.autoStraightenFile(_path, _p));
    if (!mounted) return;
    if (a == 0) {
      showSnack(context, 'Dòng chữ đã thẳng (hoặc không đủ chữ để đo).');
    }
    await _commit(_p.copyWith(fineRotation: a));
  }

  /// Ghi nhận một bước chỉnh sửa (cho hoàn tác) và lưu ngay xuống DB.
  Future<void> _commit(EditParams next, {bool debounce = false}) async {
    if (next.encode() == _p.encode()) return;
    setState(() {
      _history = [..._history.sublist(0, _h + 1), next];
      if (_history.length > 60) _history.removeAt(0);
      _h = _history.length - 1;
    });
    _render(debounce: debounce);
    await _persist();
  }

  Future<void> _persist() async {
    widget.page.edit = _p;
    await storage.updatePage(widget.page);
    ThumbnailCache.evict(widget.page.id);
  }

  void _undo() {
    if (_h == 0) return;
    setState(() => _h--);
    _render();
    _persist();
  }

  void _redo() {
    if (_h >= _history.length - 1) return;
    setState(() => _h++);
    _render();
    _persist();
  }

  Future<void> _autoDetect() async {
    final a = await runWithProgress(context, 'Đang nhận diện 4 góc…',
        () => ImagePipeline.analyzeFile(_path));
    if (!mounted) return;
    if (a.corners == null) {
      showSnack(context, 'Không nhận diện chắc chắn được – hãy kéo 4 góc bằng tay.');
      return;
    }
    await _commit(_p.copyWith(corners: a.corners, dewarp: a.dewarp, clearDewarp: a.dewarp == null));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Trang ${widget.page.index + 1}'),
        actions: [
          IconButton(
              tooltip: 'Hoàn tác', onPressed: _h > 0 ? _undo : null, icon: const Icon(Icons.undo)),
          IconButton(
              tooltip: 'Làm lại',
              onPressed: _h < _history.length - 1 ? _redo : null,
              icon: const Icon(Icons.redo)),
          PopupMenuButton<String>(
            onSelected: (v) async {
              if (v == 'original') {
                await _commit(const EditParams(mode: ColorMode.original, shadowReduction: 0));
                if (mounted) showSnack(context, 'Đã khôi phục ảnh gốc (không crop, không xử lý).');
              } else if (v == 'auto') {
                await _commit(EditParams(
                    corners: _p.corners,
                    dewarp: _p.dewarp,
                    paper: _p.paper,
                    mode: SettingsService.instance.value.defaultMode));
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'auto', child: Text('Đặt lại xử lý mặc định')),
              PopupMenuItem(value: 'original', child: Text('Khôi phục ảnh gốc')),
            ],
          ),
        ],
      ),
      body: Column(children: [
        Expanded(child: _tab == 0 ? _cornerView() : _previewView()),
        _controls(),
      ]),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) {
          setState(() => _tab = i);
          if (i != 0) _render();
        },
        destinations: const [
          NavigationDestination(icon: Icon(Icons.crop_free), label: 'Góc / Crop'),
          NavigationDestination(icon: Icon(Icons.tune), label: 'Ánh sáng'),
          NavigationDestination(icon: Icon(Icons.palette_outlined), label: 'Chế độ màu'),
        ],
      ),
    );
  }

  Widget _cornerView() {
    final img = _originalUi;
    if (img == null) return const Center(child: CircularProgressIndicator());
    final q = _liveQuad ?? _p.corners ?? Quad.fullFrame(_fullW.toDouble(), _fullH.toDouble());
    return Container(
      color: Colors.black,
      child: CornerEditor(
        image: img,
        fullWidth: _fullW,
        fullHeight: _fullH,
        quad: q,
        onChanged: (nq) => _liveQuad = nq,
        onChangeEnd: (nq) {
          _liveQuad = null;
          if (!nq.isConvex || nq.area < 100) {
            showSnack(context, 'Vùng chọn không hợp lệ (tứ giác bị xoắn hoặc quá nhỏ).');
            setState(() {});
            return;
          }
          _commit(_p.copyWith(corners: nq, clearDewarp: true));
        },
      ),
    );
  }

  Widget _previewView() {
    final bytes = _showBefore ? _originalJpg : _preview;
    return Container(
      color: Colors.grey.shade900,
      child: Stack(children: [
        if (bytes != null)
          Positioned.fill(
            child: InteractiveViewer(
              maxScale: 10,
              child: Center(
                child: Stack(children: [
                  Image.memory(bytes, gaplessPlayback: true),
                  if (_grid) Positioned.fill(child: CustomPaint(painter: _CheckGridPainter())),
                ]),
              ),
            ),
          )
        else
          const Center(child: CircularProgressIndicator()),
        if (_rendering)
          const Positioned(
              top: 8, right: 8, child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5))),
        if (_showBefore)
          const Positioned(
            top: 8,
            left: 8,
            child: Chip(label: Text('TRƯỚC (ảnh gốc)')),
          ),
        Positioned(
          top: 4,
          left: _showBefore ? 170 : 4,
          child: IconButton.filledTonal(
            tooltip: 'Lưới kiểm tra độ thẳng',
            icon: Icon(_grid ? Icons.grid_on : Icons.grid_off),
            onPressed: () => setState(() => _grid = !_grid),
          ),
        ),
        Positioned(
          bottom: 8,
          left: 8,
          child: Text('Chụm 2 ngón để phóng to kiểm tra chữ & số',
              style: TextStyle(color: Colors.white.withValues(alpha: 0.7), fontSize: 12)),
        ),
      ]),
    );
  }

  Widget _controls() {
    final row = Row(children: [
      IconButton(
        tooltip: 'Xoay trái',
        icon: const Icon(Icons.rotate_left),
        onPressed: () => _commit(_p.copyWith(rotation: _p.rotation + 3)),
      ),
      IconButton(
        tooltip: 'Xoay phải',
        icon: const Icon(Icons.rotate_right),
        onPressed: () => _commit(_p.copyWith(rotation: _p.rotation + 1)),
      ),
      if (_tab != 0)
        GestureDetector(
          onTapDown: (_) => setState(() => _showBefore = true),
          onTapUp: (_) => setState(() => _showBefore = false),
          onTapCancel: () => setState(() => _showBefore = false),
          child: const Chip(avatar: Icon(Icons.compare, size: 18), label: Text('Giữ để so sánh')),
        ),
      const Spacer(),
      FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Xong')),
    ]);

    Widget body;
    switch (_tab) {
      case 0:
        body = Wrap(spacing: 8, children: [
          OutlinedButton.icon(
              onPressed: _autoDetect,
              icon: const Icon(Icons.auto_fix_high),
              label: const Text('Tự nhận diện')),
          OutlinedButton.icon(
              onPressed: _snapEdges,
              icon: const Icon(Icons.border_outer),
              label: const Text('Bắt dính mép giấy')),
          OutlinedButton.icon(
              onPressed: _dewarp,
              icon: const Icon(Icons.auto_awesome_mosaic_outlined),
              label: const Text('Nắn giấy cong')),
          if (_p.dewarp != null)
            InputChip(
              avatar: const Icon(Icons.check_circle, size: 18, color: Colors.green),
              label: Text(_p.dewarp!['type'] == 'cyl'
                  ? 'Đang nắn mép quăn (3D)'
                  : 'Đang nắn theo mép cong'),
              onDeleted: () => _commit(_p.copyWith(clearDewarp: true)),
              deleteButtonTooltipMessage: 'Tắt nắn cong',
            ),
          OutlinedButton.icon(
              onPressed: () => _commit(_p.copyWith(clearCorners: true, clearDewarp: true)),
              icon: const Icon(Icons.fullscreen),
              label: const Text('Toàn ảnh')),
          const SizedBox(width: double.infinity, height: 4),
          const Text('Khổ giấy (tỷ lệ sau khi nắn phẳng):', style: TextStyle(fontSize: 13)),
          for (final ps in PaperSize.values)
            ChoiceChip(
              label: Text(ps.label),
              selected: _p.paper == ps,
              onSelected: (_) => _commit(_p.copyWith(paper: ps)),
            ),
          if (_aspectText != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(_aspectText!, style: const TextStyle(fontSize: 12)),
            ),
        ]);
        break;
      case 1:
        body = Column(children: [
          Row(children: [
            Expanded(
              child: _slider('Làm thẳng (°)', _p.fineRotation, -15, 15,
                  (v) => _p.copyWith(fineRotation: v), divisions: 300),
            ),
            TextButton(onPressed: _autoStraighten, child: const Text('Tự động')),
          ]),
          _slider('Giảm bóng / làm đều sáng', _p.shadowReduction, 0, 1,
              (v) => _p.copyWith(shadowReduction: v)),
          _slider('Độ sáng', _p.brightness, -1, 1, (v) => _p.copyWith(brightness: v)),
          _slider('Tương phản', _p.contrast, -1, 1, (v) => _p.copyWith(contrast: v)),
          _slider('Độ sắc nét (giới hạn)', _p.sharpness, 0, 1, (v) => _p.copyWith(sharpness: v)),
          _slider('Cân bằng trắng (lạnh ↔ ấm)', _p.warmth, -1, 1, (v) => _p.copyWith(warmth: v)),
        ]);
        break;
      default:
        body = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Wrap(spacing: 8, children: [
            for (final m in ColorMode.values)
              ChoiceChip(
                label: Text(m.label),
                selected: _p.mode == m,
                onSelected: (_) => _commit(_p.copyWith(mode: m)),
              ),
          ]),
          if (_p.mode == ColorMode.blackWhite || _p.mode == ColorMode.grayscale)
            const Padding(
              padding: EdgeInsets.only(top: 6),
              child: Text('Lưu ý: chế độ này làm mất màu dấu đỏ và chữ ký xanh. '
                  'Dùng "Màu gốc" để bảo toàn màu.', style: TextStyle(fontSize: 12)),
            ),
        ]);
    }
    return Material(
      elevation: 4,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 240),
              child: SingleChildScrollView(child: body)),
          row,
        ]),
      ),
    );
  }

  Widget _slider(String label, double value, double min, double max,
      EditParams Function(double) make, {int divisions = 40}) {
    return Row(children: [
      SizedBox(width: 130, child: Text(label, style: const TextStyle(fontSize: 13))),
      Expanded(
        child: Slider(
          value: value.clamp(min, max),
          min: min,
          max: max,
          divisions: divisions,
          onChanged: (v) {
            // Cập nhật trực tiếp bước hiện tại (không tạo bước hoàn tác cho từng pixel kéo).
            setState(() => _history[_h] = make(v));
            _render(debounce: true);
          },
          onChangeStart: (_) {
            setState(() {
              _history = [..._history.sublist(0, _h + 1), _p];
              _h = _history.length - 1;
            });
          },
          onChangeEnd: (_) => _persist(),
        ),
      ),
    ]);
  }
}

/// Lưới kiểm tra: dòng chữ và cạnh bảng phải song song với các đường lưới.
class _CheckGridPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = Colors.cyanAccent.withValues(alpha: 0.55)
      ..strokeWidth = 1;
    const nx = 8, ny = 11;
    for (var i = 1; i < nx; i++) {
      canvas.drawLine(Offset(size.width * i / nx, 0), Offset(size.width * i / nx, size.height), p);
    }
    for (var i = 1; i < ny; i++) {
      canvas.drawLine(Offset(0, size.height * i / ny), Offset(size.width, size.height * i / ny), p);
    }
  }

  @override
  bool shouldRepaint(covariant _CheckGridPainter old) => false;
}
