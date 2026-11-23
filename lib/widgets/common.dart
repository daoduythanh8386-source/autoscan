import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../models/document.dart';
import '../services/imaging/pipeline.dart';
import '../services/storage/app_storage.dart';

Future<bool> confirmDialog(BuildContext context, String title, String message,
    {String ok = 'Xác nhận', bool destructive = false}) async {
  final r = await showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Huỷ')),
        FilledButton(
          style: destructive
              ? FilledButton.styleFrom(backgroundColor: Theme.of(c).colorScheme.error)
              : null,
          onPressed: () => Navigator.pop(c, true),
          child: Text(ok),
        ),
      ],
    ),
  );
  return r ?? false;
}

Future<String?> promptText(BuildContext context, String title,
    {String initial = '', String hint = '', String ok = 'Lưu'}) async {
  final ctl = TextEditingController(text: initial);
  final r = await showDialog<String>(
    context: context,
    builder: (c) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: ctl,
        autofocus: true,
        decoration: InputDecoration(hintText: hint),
        onSubmitted: (v) => Navigator.pop(c, v),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c), child: const Text('Huỷ')),
        FilledButton(onPressed: () => Navigator.pop(c, ctl.text), child: Text(ok)),
      ],
    ),
  );
  return r?.trim().isEmpty ?? true ? null : r!.trim();
}

void showSnack(BuildContext context, String msg) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(msg)));
}

/// Hộp thoại tiến trình không chặn UI thread (việc nặng chạy trong isolate).
Future<T> runWithProgress<T>(BuildContext context, String label, Future<T> Function() task) async {
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => PopScope(
      canPop: false,
      child: AlertDialog(
        content: Row(children: [
          const CircularProgressIndicator(),
          const SizedBox(width: 20),
          Expanded(child: Text(label)),
        ]),
      ),
    ),
  );
  try {
    return await task();
  } finally {
    if (context.mounted) Navigator.of(context, rootNavigator: true).pop();
  }
}

/// Bộ nhớ đệm ảnh thu nhỏ (chỉ để hiển thị).
class ThumbnailCache {
  static final _cache = <String, Future<Uint8List>>{};

  static Future<Uint8List> of(ScanPage page) {
    final key = '${page.id}_${page.edit.cacheKey}';
    return _cache.putIfAbsent(
        key,
        () => ImagePipeline.renderPreviewJpg(
            AppStorage.instance.internalAbs(page.originalRelPath), page.edit,
            maxSide: 480));
  }

  static void evict(String pageId) => _cache.removeWhere((k, _) => k.startsWith('${pageId}_'));
}

class PageThumb extends StatelessWidget {
  final ScanPage page;
  final double size;
  const PageThumb(this.page, {super.key, this.size = 72});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size * 1.35,
      child: FutureBuilder<Uint8List>(
        future: ThumbnailCache.of(page),
        builder: (c, s) {
          if (s.hasError) return const Icon(Icons.broken_image_outlined);
          if (!s.hasData) return const Center(child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)));
          return ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: Image.memory(s.data!, fit: BoxFit.contain, gaplessPlayback: true),
          );
        },
      ),
    );
  }
}
