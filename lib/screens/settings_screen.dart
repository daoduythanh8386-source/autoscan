import 'package:flutter/material.dart';

import '../core/ids.dart';
import '../models/edit_params.dart';
import '../services/settings_service.dart';
import '../services/storage/app_storage.dart';
import '../widgets/brand.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final svc = SettingsService.instance;
  int? _free;

  @override
  void initState() {
    super.initState();
    AppStorage.instance.freeBytes().then((v) {
      if (mounted) setState(() => _free = v);
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = svc.value;
    return Scaffold(
      appBar: AppBar(title: const Text('Cài đặt')),
      body: ListView(children: [
        const _Header('Scan'),
        SwitchListTile(
          title: const Text('Tự động chụp (AUTO)'),
          subtitle: const Text('Chụp khi 4 góc ổn định và ảnh đủ nét. Luôn có nút chụp tay.'),
          value: s.autoCapture,
          onChanged: (v) => svc.update((x) => x.autoCapture = v).then((_) => setState(() {})),
        ),
        ListTile(
          title: const Text('Chế độ màu mặc định'),
          trailing: DropdownButton<ColorMode>(
            value: s.defaultMode,
            items: [for (final m in ColorMode.values) DropdownMenuItem(value: m, child: Text(m.label))],
            onChanged: (v) => svc.update((x) => x.defaultMode = v!).then((_) => setState(() {})),
          ),
        ),
        const _Header('Chất lượng (MAXIMUM)'),
        ListTile(
          title: Text('Chất lượng JPG mặc định: ${s.jpgQuality}'),
          subtitle: Slider(
            value: s.jpgQuality.toDouble(),
            min: 60,
            max: 100,
            divisions: 40,
            onChanged: (v) => svc.update((x) => x.jpgQuality = v.round()).then((_) => setState(() {})),
          ),
        ),
        const ListTile(
          leading: Icon(Icons.info_outline),
          subtitle: Text('Ảnh gốc luôn được giữ nguyên độ phân giải đầy đủ. File xuất được dựng từ ảnh '
              'gốc, không dùng ảnh xem trước. Ứng dụng không phục hồi được chi tiết vốn không có '
              'trong ảnh (mờ, cháy sáng) – khi đó sẽ cảnh báo để chụp lại.'),
        ),
        const _Header('OCR (OPTIONAL)'),
        SwitchListTile(
          title: const Text('Bật OCR khi xuất PDF'),
          subtitle: const Text('Mặc định TẮT. Nhận dạng chạy trên thiết bị, có thể sai – '
              'đặc biệt với số liệu. Tắt OCR không ảnh hưởng chức năng scan và xuất.'),
          value: s.ocrEnabled,
          onChanged: (v) => svc.update((x) => x.ocrEnabled = v).then((_) => setState(() {})),
        ),
        const _Header('Lưu trữ (DEVICE)'),
        ListTile(
          leading: const Icon(Icons.sd_storage_outlined),
          title: const Text('Dung lượng trống'),
          subtitle: Text(_free == null ? 'Không xác định được trên thiết bị này' : formatBytes(_free!)),
        ),
        const ListTile(
          leading: Icon(Icons.lock_outline),
          title: Text('Quyền riêng tư'),
          subtitle: Text('Không đăng nhập, không máy chủ, không tải lên cloud, không gửi dữ liệu cho bên '
              'thứ ba, không ghi nội dung tài liệu vào log. Hoạt động ở chế độ máy bay. '
              'Chỉ xin quyền Camera (và thư viện ảnh khi bạn chọn nhập ảnh).'),
        ),
        const SizedBox(height: 16),
        const Center(child: Text('Phiên bản 0.2.0', style: TextStyle(fontSize: 12))),
        const BrandFooter(),
        const SizedBox(height: 16),
      ]),
    );
  }
}

class _Header extends StatelessWidget {
  final String text;
  const _Header(this.text);
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
        child: Text(text,
            style: TextStyle(
                color: Theme.of(context).colorScheme.primary, fontWeight: FontWeight.w700)),
      );
}
