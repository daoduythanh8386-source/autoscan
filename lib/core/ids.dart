import 'dart:math';

final _rng = Random.secure();

/// ID ngẫu nhiên 128-bit dạng hex (không cần thư viện uuid).
String newId() {
  final b = List<int>.generate(16, (_) => _rng.nextInt(256));
  return b.map((e) => e.toRadixString(16).padLeft(2, '0')).join();
}

/// Làm sạch tên file: giữ tiếng Việt có dấu, bỏ ký tự cấm trên Android/iOS.
String sanitizeFileName(String input) {
  var s = input.trim().replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1F]'), '_');
  s = s.replaceAll(RegExp(r'\s+'), ' ');
  while (s.startsWith('.')) {
    s = s.substring(1);
  }
  if (s.isEmpty) s = 'TaiLieu';
  if (s.length > 120) s = s.substring(0, 120);
  return s;
}

String formatBytes(int b) {
  if (b < 1024) return '$b B';
  if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(1)} KB';
  if (b < 1024 * 1024 * 1024) return '${(b / 1024 / 1024).toStringAsFixed(1)} MB';
  return '${(b / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
}

String defaultDocName(DateTime t) {
  String two(int v) => v.toString().padLeft(2, '0');
  return 'Scan ${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}h${two(t.minute)}';
}
