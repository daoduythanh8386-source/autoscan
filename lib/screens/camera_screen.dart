import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:sensors_plus/sensors_plus.dart';

import '../core/geometry.dart';
import '../models/document.dart';
import '../services/imaging/document_detector.dart';
import '../services/imaging/frame_analyzer.dart';
import '../services/imaging/quality.dart';
import '../services/settings_service.dart';
import '../services/storage/app_storage.dart';
import '../widgets/brand.dart';
import '../widgets/common.dart';
import 'editor_screen.dart';
import 'import_flow.dart';
import 'page_manager_screen.dart';

class CameraScreen extends StatefulWidget {
  final ScanDocument doc;

  /// true khi mở từ màn quản lý trang để thêm trang (quay lại thay vì mở mới).
  final bool returnOnDone;
  const CameraScreen({super.key, required this.doc, this.returnOnDone = false});

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen> with WidgetsBindingObserver {
  List<CameraDescription> _cameras = [];
  CameraController? _ctl;
  int _camIndex = 0;
  String? _error;

  FlashMode _flash = FlashMode.off;
  double _minExp = 0, _maxExp = 0, _exp = 0;

  final _tracker = CornerStabilityTracker();
  bool _busyFrame = false;
  DateTime _lastFrame = DateTime.fromMillisecondsSinceEpoch(0);
  Quad? _overlay;
  DetectionResult? _lastDet;
  double _lastSharp = 0;
  bool _capturing = false;
  DateTime _cooldownUntil = DateTime.fromMillisecondsSinceEpoch(0);

  // Thước thăng bằng: độ nghiêng máy so với mặt giấy nằm ngang (độ).
  StreamSubscription<AccelerometerEvent>? _accelSub;
  double? _tiltX, _tiltY;

  /// Ngưỡng độ nét trên khung 320px – giá trị khởi điểm, CẦN hiệu chuẩn thực tế.
  static const _minFrameSharpness = 18.0;

  bool get _auto => SettingsService.instance.value.autoCapture;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initCameras();
    try {
      _accelSub = accelerometerEventStream(samplingPeriod: SensorInterval.uiInterval).listen((e) {
        final g = math.sqrt(e.x * e.x + e.y * e.y + e.z * e.z);
        if (g < 1) return;
        // Chỉ hiển thị khi máy gần nằm ngang (chụp giấy trên bàn).
        if (e.z.abs() / g < 0.75) {
          if (_tiltX != null && mounted) setState(() => _tiltX = _tiltY = null);
          return;
        }
        final tx = math.atan2(e.x, e.z.abs()) * 180 / math.pi;
        final ty = math.atan2(e.y, e.z.abs()) * 180 / math.pi;
        if (mounted) {
          setState(() {
            _tiltX = tx;
            _tiltY = ty;
          });
        }
      }, onError: (_) {});
    } catch (_) {}
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _accelSub?.cancel();
    _ctl?.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final c = _ctl;
    if (c == null || !c.value.isInitialized) return;
    if (state == AppLifecycleState.inactive || state == AppLifecycleState.paused) {
      _ctl = null;
      c.dispose();
      if (mounted) setState(() {});
    } else if (state == AppLifecycleState.resumed) {
      _start(_camIndex);
    }
  }

  Future<void> _initCameras() async {
    try {
      _cameras = await availableCameras();
      if (_cameras.isEmpty) {
        setState(() => _error = 'Không tìm thấy camera trên thiết bị.');
        return;
      }
      final back = _cameras.indexWhere((c) => c.lensDirection == CameraLensDirection.back);
      await _start(back < 0 ? 0 : back);
    } on CameraException catch (e) {
      setState(() => _error = _cameraError(e));
    }
  }

  String _cameraError(CameraException e) {
    if (e.code.contains('AccessDenied') || e.code.contains('Permission')) {
      return 'Ứng dụng chưa được cấp quyền camera. Hãy bật quyền Camera trong Cài đặt của máy. '
          'Bạn vẫn có thể "Chọn ảnh" từ thư viện.';
    }
    return 'Lỗi camera: ${e.description ?? e.code}';
  }

  Future<void> _start(int index) async {
    final old = _ctl;
    _ctl = null;
    await old?.dispose();
    _tracker.reset();
    final cam = _cameras[index];
    final ctl = CameraController(
      cam,
      ResolutionPreset.max, // MAXIMUM: độ phân giải cao nhất thiết bị hỗ trợ
      enableAudio: false,
      imageFormatGroup: Platform.isIOS ? ImageFormatGroup.bgra8888 : ImageFormatGroup.yuv420,
    );
    try {
      await ctl.initialize();
      // KHÔNG khoá hướng chụp: plugin ghi hướng cầm máy thật vào EXIF, nhờ vậy
      // chụp ngang tài liệu khổ ngang vẫn ra ảnh đúng chiều từ trên xuống.
      await ctl.unlockCaptureOrientation();
      await ctl.setFocusMode(FocusMode.auto);
      _minExp = await ctl.getMinExposureOffset();
      _maxExp = await ctl.getMaxExposureOffset();
      _exp = 0;
      await ctl.setFlashMode(_flash);
      if (!mounted) {
        await ctl.dispose();
        return;
      }
      _ctl = ctl;
      _camIndex = index;
      setState(() => _error = null);
      await _startStream();
    } on CameraException catch (e) {
      await ctl.dispose();
      if (mounted) setState(() => _error = _cameraError(e));
    }
  }

  Future<void> _startStream() async {
    final c = _ctl;
    if (c == null || c.value.isStreamingImages) return;
    try {
      await c.startImageStream(_onFrame);
    } catch (_) {
      // Một số thiết bị không hỗ trợ stream ở độ phân giải tối đa – vẫn chụp tay được.
    }
  }

  Future<void> _stopStream() async {
    final c = _ctl;
    if (c != null && c.value.isStreamingImages) {
      try {
        await c.stopImageStream();
      } catch (_) {}
    }
  }

  void _onFrame(CameraImage image) {
    final now = DateTime.now();
    if (_busyFrame || _capturing || now.difference(_lastFrame).inMilliseconds < 160) return;
    _busyFrame = true;
    _lastFrame = now;
    final cam = _cameras[_camIndex];
    final plane = image.planes.first;
    final portraitNeedsRotate = image.width > image.height;
    final data = FrameData(
      bytes: plane.bytes,
      width: image.width,
      height: image.height,
      bytesPerRow: plane.bytesPerRow,
      bgra: image.format.group == ImageFormatGroup.bgra8888,
      rotation: portraitNeedsRotate ? cam.sensorOrientation : 0,
      mirror: cam.lensDirection == CameraLensDirection.front,
    );
    _analyzeInIsolate(data).then((r) {
      if (!mounted) return;
      _tracker.update(
          DetectionResult(r.normQuad, r.detection.confidence, r.detection.issues, r.detection.fill),
          math.sqrt2);
      setState(() {
        _overlay = _tracker.quad;
        _lastDet = r.detection;
        _lastSharp = r.sharpness;
      });
      if (_auto &&
          _tracker.isStable &&
          r.sharpness >= _minFrameSharpness &&
          !r.detection.issues.contains('corner_out_of_frame') &&
          !r.detection.issues.contains('occluded') &&
          DateTime.now().isAfter(_cooldownUntil)) {
        _capture(auto: true);
      }
    }).whenComplete(() => _busyFrame = false);
  }

  String get _hint {
    final d = _lastDet;
    if (_ctl == null) return '';
    if (d == null || d.quad == null) return 'Đưa toàn bộ tờ giấy vào khung, đặt trên nền tối hơn giấy';
    if (d.issues.contains('corner_out_of_frame')) return 'Lùi máy ra – có góc giấy nằm ngoài khung';
    if (d.issues.contains('too_small')) return 'Đưa máy lại gần tài liệu hơn';
    if (d.issues.contains('occluded')) return 'Tài liệu đang bị che – bỏ tay/vật cản ra';
    if (d.issues.contains('low_contrast')) return 'Nền và giấy khó phân biệt – đổi sang nền tối hơn';
    if (_lastSharp < _minFrameSharpness) return 'Giữ máy chắc tay để lấy nét…';
    if (!d.isReliable) return 'Đang tìm 4 góc…';
    return _auto ? 'Giữ yên – sẽ tự động chụp' : 'Đã thấy tài liệu – bấm nút để chụp';
  }

  Future<void> _capture({bool auto = false}) async {
    final c = _ctl;
    if (c == null || _capturing || !c.value.isInitialized) return;
    if (await AppStorage.instance.isLowOnSpace() && mounted) {
      showSnack(context, 'Cảnh báo: bộ nhớ thiết bị gần đầy.');
    }
    setState(() => _capturing = true);
    try {
      await _stopStream();
      final shot = await c.takePicture(); // ảnh độ phân giải đầy đủ, không lấy từ preview
      HapticFeedback.mediumImpact();
      final (page, analysis) = await addAnalyzedPage(widget.doc, shot.path);
      try {
        await File(shot.path).delete();
      } catch (_) {}
      if (!mounted) return;
      final serious = analysis.qualityIssues
          .where((i) => i.severity != IssueSeverity.info)
          .toList();
      var keep = true;
      if (serious.isNotEmpty) {
        keep = await _qualityDialog(serious);
        if (!keep) {
          await AppStorage.instance.deletePage(widget.doc, page);
        }
      }
      if (keep && analysis.dewarp != null && mounted) {
        showSnack(
            context,
            analysis.curveKind == 'curl'
                ? 'Phát hiện mép giấy bị quăn/cong – đã tự nắn phẳng.'
                : 'Phát hiện giấy bị cong/gợn – đã tự nắn theo mép giấy.');
      }
      if (keep && !analysis.autoCropReliable && mounted) {
        // Không chắc chắn → KHÔNG tự crop sai, chuyển sang chỉnh tay.
        showSnack(context, 'Không chắc chắn vị trí 4 góc – vui lòng chỉnh tay.');
        await Navigator.push(
            context,
            MaterialPageRoute(
                builder: (_) =>
                    EditorScreen(doc: widget.doc, page: page, startWithCorners: true)));
      } else if (keep && mounted) {
        showSnack(context, 'Đã chụp trang ${widget.doc.pages.length}');
      }
    } on StorageFullException catch (e) {
      if (mounted) showSnack(context, e.message);
    } on CameraException catch (e) {
      if (mounted) showSnack(context, _cameraError(e));
    } catch (e) {
      if (mounted) showSnack(context, 'Lỗi khi chụp: $e');
    } finally {
      _tracker.reset();
      _cooldownUntil = DateTime.now().add(const Duration(milliseconds: 2500));
      if (mounted) {
        setState(() {
          _capturing = false;
          _overlay = null;
        });
        await _startStream();
      }
    }
  }

  Future<bool> _qualityDialog(List<QualityIssue> issues) async {
    final r = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (c) => AlertDialog(
        icon: const Icon(Icons.warning_amber_rounded),
        title: const Text('Ảnh chưa đạt chất lượng'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [for (final i in issues) Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text('• ${i.message}'),
          )],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('Vẫn giữ ảnh')),
          FilledButton(onPressed: () => Navigator.pop(c, false), child: const Text('Chụp lại')),
        ],
      ),
    );
    return r ?? true;
  }

  Future<void> _cycleFlash() async {
    const order = [FlashMode.off, FlashMode.auto, FlashMode.always, FlashMode.torch];
    final next = order[(order.indexOf(_flash) + 1) % order.length];
    try {
      await _ctl?.setFlashMode(next);
      setState(() => _flash = next);
    } on CameraException {
      if (mounted) showSnack(context, 'Thiết bị không hỗ trợ chế độ đèn này.');
    }
  }

  IconData get _flashIcon => switch (_flash) {
        FlashMode.off => Icons.flash_off,
        FlashMode.auto => Icons.flash_auto,
        FlashMode.always => Icons.flash_on,
        FlashMode.torch => Icons.highlight,
      };

  Future<void> _done() async {
    await _stopStream();
    if (!mounted) return;
    if (widget.returnOnDone) {
      Navigator.pop(context);
    } else {
      Navigator.pushReplacement(
          context, MaterialPageRoute(builder: (_) => PageManagerScreen(doc: widget.doc)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = _ctl;
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(children: [
          _topBar(),
          Expanded(
            child: _error != null
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(_error!,
                          style: const TextStyle(color: Colors.white), textAlign: TextAlign.center),
                    ),
                  )
                : (c == null || !c.value.isInitialized)
                    ? const Center(child: CircularProgressIndicator())
                    : Center(
                        child: AspectRatio(
                          aspectRatio: 1 / c.value.aspectRatio,
                          child: LayoutBuilder(builder: (ctx, box) {
                            return GestureDetector(
                              onTapUp: (d) {
                                final pt = Offset(d.localPosition.dx / box.maxWidth,
                                    d.localPosition.dy / box.maxHeight);
                                c.setFocusPoint(pt).catchError((_) {});
                                c.setExposurePoint(pt).catchError((_) {});
                              },
                              child: Stack(fit: StackFit.expand, children: [
                                CameraPreview(c),
                                if (SettingsService.instance.value.showGrid)
                                  CustomPaint(painter: _GridPainter()),
                                CustomPaint(
                                  painter: _QuadPainter(
                                      _overlay, _tracker.progress, _lastDet?.isReliable ?? false),
                                ),
                                if (_tiltX != null && SettingsService.instance.value.showGrid)
                                  Positioned(
                                    left: 0,
                                    right: 0,
                                    bottom: 12,
                                    child: Center(child: _LevelIndicator(_tiltX!, _tiltY!)),
                                  ),
                                if (_capturing)
                                  Container(
                                    color: Colors.black45,
                                    child: const Center(child: CircularProgressIndicator()),
                                  ),
                              ]),
                            );
                          }),
                        ),
                      ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 16),
            child: Text(_hint,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white, fontSize: 15)),
          ),
          if (c != null && _maxExp > _minExp)
            Row(children: [
              const SizedBox(width: 12),
              const Icon(Icons.exposure, color: Colors.white70, size: 20),
              Expanded(
                child: Slider(
                  value: _exp,
                  min: _minExp,
                  max: _maxExp,
                  onChanged: (v) {
                    setState(() => _exp = v);
                    c.setExposureOffset(v).catchError((_) => 0.0);
                  },
                ),
              ),
            ]),
          _bottomBar(),
        ]),
      ),
    );
  }

  Widget _topBar() {
    return Row(children: [
      IconButton(
        icon: const Icon(Icons.close, color: Colors.white),
        tooltip: 'Đóng',
        onPressed: () => Navigator.pop(context),
      ),
      const Spacer(),
      IconButton(
          icon: Icon(_flashIcon, color: Colors.white), tooltip: 'Đèn flash', onPressed: _cycleFlash),
      IconButton(
        icon: Icon(SettingsService.instance.value.showGrid ? Icons.grid_on : Icons.grid_off,
            color: Colors.white),
        tooltip: 'Lưới căn chỉnh',
        onPressed: () => SettingsService.instance
            .update((s) => s.showGrid = !s.showGrid)
            .then((_) => setState(() {})),
      ),
      if (_cameras.length > 1)
        IconButton(
          icon: const Icon(Icons.cameraswitch_outlined, color: Colors.white),
          tooltip: 'Đổi camera trước/sau',
          onPressed: () => _start((_camIndex + 1) % _cameras.length),
        ),
      TextButton.icon(
        onPressed: () => SettingsService.instance
            .update((s) => s.autoCapture = !s.autoCapture)
            .then((_) => setState(() {})),
        icon: Icon(_auto ? Icons.motion_photos_auto : Icons.touch_app_outlined, color: Colors.white),
        label: Text(_auto ? 'Tự động' : 'Thủ công', style: const TextStyle(color: Colors.white)),
      ),
    ]);
  }

  Widget _bottomBar() {
    final pages = widget.doc.pages;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
      child: Row(children: [
        IconButton.filledTonal(
          iconSize: 28,
          tooltip: 'Nhập ảnh từ thư viện',
          icon: const Icon(Icons.photo_library_outlined),
          onPressed: () async {
            await _stopStream();
            if (!mounted) return;
            await importFromGallery(context, widget.doc);
            if (mounted) setState(() {});
            await _startStream();
          },
        ),
        const Spacer(),
        GestureDetector(
          onTap: () => _capture(),
          child: Container(
            width: 82,
            height: 82,
            padding: const EdgeInsets.all(5),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: Brand.mainGradient,
              boxShadow: [BoxShadow(color: Brand.violet.withValues(alpha: 0.5), blurRadius: 16)],
            ),
            child: Container(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: _capturing ? Colors.grey : Colors.white,
              ),
              child: Icon(Icons.camera_alt_rounded,
                  color: _capturing ? Colors.white : Brand.violet, size: 34),
            ),
          ),
        ),
        const Spacer(),
        GestureDetector(
          onTap: pages.isEmpty ? null : _done,
          child: Stack(clipBehavior: Clip.none, children: [
            pages.isEmpty
                ? const SizedBox(width: 52, height: 64)
                : PageThumb(pages.last, size: 48),
            if (pages.isNotEmpty)
              Positioned(
                right: -8,
                top: -8,
                child: CircleAvatar(
                  radius: 12,
                  backgroundColor: Theme.of(context).colorScheme.primary,
                  child: Text('${pages.length}',
                      style: const TextStyle(color: Colors.white, fontSize: 12)),
                ),
              ),
          ]),
        ),
        const SizedBox(width: 8),
        FilledButton(
          onPressed: pages.isEmpty ? null : _done,
          style: FilledButton.styleFrom(minimumSize: const Size(64, 48)),
          child: const Text('Xong'),
        ),
      ]),
    );
  }
}

/// Lưới căn chỉnh: chia 3x3, dấu tâm và khung A4 (tỷ lệ 1 : 1,414) để đặt giấy.
class _GridPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final thin = Paint()
      ..color = Colors.white.withValues(alpha: 0.35)
      ..strokeWidth = 1;
    for (var i = 1; i < 3; i++) {
      canvas.drawLine(Offset(size.width * i / 3, 0), Offset(size.width * i / 3, size.height), thin);
      canvas.drawLine(Offset(0, size.height * i / 3), Offset(size.width, size.height * i / 3), thin);
    }
    final c = size.center(Offset.zero);
    final cross = Paint()
      ..color = Colors.white.withValues(alpha: 0.7)
      ..strokeWidth = 1.5;
    canvas.drawLine(c - const Offset(12, 0), c + const Offset(12, 0), cross);
    canvas.drawLine(c - const Offset(0, 12), c + const Offset(0, 12), cross);
    // Khung A4 dọc: chỉ vẽ 4 góc chữ L để không che tài liệu.
    var fw = size.width * 0.82, fh = fw * 1.4142;
    if (fh > size.height * 0.9) {
      fh = size.height * 0.9;
      fw = fh / 1.4142;
    }
    final r = Rect.fromCenter(center: c, width: fw, height: fh);
    final guide = Paint()
      ..color = Colors.white.withValues(alpha: 0.8)
      ..strokeWidth = 3
      ..style = PaintingStyle.stroke;
    final l = fw * 0.12;
    for (final (p, dx, dy) in [
      (r.topLeft, 1.0, 1.0),
      (r.topRight, -1.0, 1.0),
      (r.bottomRight, -1.0, -1.0),
      (r.bottomLeft, 1.0, -1.0),
    ]) {
      canvas.drawLine(p, p + Offset(l * dx, 0), guide);
      canvas.drawLine(p, p + Offset(0, l * dy), guide);
    }
  }

  @override
  bool shouldRepaint(covariant _GridPainter old) => false;
}

/// Thước thăng bằng dạng bọt nước: xanh khi máy song song mặt giấy (≤ 3°).
class _LevelIndicator extends StatelessWidget {
  final double tx, ty;
  const _LevelIndicator(this.tx, this.ty);

  @override
  Widget build(BuildContext context) {
    final ok = tx.abs() <= 3 && ty.abs() <= 3;
    final color = ok ? Colors.greenAccent : Colors.amber;
    const r = 34.0;
    final bx = (tx / 15).clamp(-1.0, 1.0) * (r - 8);
    final by = (-ty / 15).clamp(-1.0, 1.0) * (r - 8);
    return Row(mainAxisSize: MainAxisSize.min, children: [
      SizedBox(
        width: r * 2,
        height: r * 2,
        child: Stack(alignment: Alignment.center, children: [
          Container(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.black38,
              border: Border.all(color: color, width: 2),
            ),
          ),
          Container(width: 14, height: 14, decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: Colors.white54))),
          Transform.translate(
            offset: Offset(bx, by),
            child: Container(
                width: 12, height: 12, decoration: BoxDecoration(shape: BoxShape.circle, color: color)),
          ),
        ]),
      ),
      const SizedBox(width: 8),
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(color: Colors.black45, borderRadius: BorderRadius.circular(8)),
        child: Text(ok ? 'Máy song song giấy' : 'Nghiêng ${math.max(tx.abs(), ty.abs()).toStringAsFixed(0)}°',
            style: TextStyle(color: color, fontSize: 13)),
      ),
    ]);
  }
}

/// Top-level để closure gửi sang isolate không giữ tham chiếu tới State.
Future<FrameResult> _analyzeInIsolate(FrameData d) => Isolate.run(() => analyzeFrame(d));

class _QuadPainter extends CustomPainter {
  final Quad? q;
  final double progress;
  final bool reliable;
  _QuadPainter(this.q, this.progress, this.reliable);

  @override
  void paint(Canvas canvas, Size size) {
    final quad = q;
    if (quad == null) return;
    final path = Path()
      ..moveTo(quad.tl.x * size.width, quad.tl.y * size.height)
      ..lineTo(quad.tr.x * size.width, quad.tr.y * size.height)
      ..lineTo(quad.br.x * size.width, quad.br.y * size.height)
      ..lineTo(quad.bl.x * size.width, quad.bl.y * size.height)
      ..close();
    final color = Color.lerp(Colors.amber, Colors.greenAccent, progress)!;
    canvas.drawPath(
        path, Paint()..color = color.withValues(alpha: reliable ? 0.22 : 0.1));
    canvas.drawPath(
        path,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3);
    for (final p in quad.pts) {
      canvas.drawCircle(Offset(p.x * size.width, p.y * size.height), 7, Paint()..color = color);
    }
  }

  @override
  bool shouldRepaint(covariant _QuadPainter old) =>
      old.q != q || old.progress != progress || old.reliable != reliable;
}
