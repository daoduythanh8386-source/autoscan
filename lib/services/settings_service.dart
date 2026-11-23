import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../models/edit_params.dart';
import 'export/export_core.dart';
import 'storage/app_storage.dart';

/// Cấu hình đã chốt: AUTO / MAXIMUM / OPTIONAL / DEVICE.
class AppSettings {
  bool autoCapture; // AUTO
  bool ocrEnabled; // OPTIONAL – mặc định TẮT
  int jpgQuality; // MAXIMUM – mặc định cao
  ColorMode defaultMode;
  PdfPageSize pdfSize;
  PdfImageQuality pdfQuality;
  bool showGrid; // lưới căn chỉnh trên camera

  AppSettings({
    this.autoCapture = true,
    this.ocrEnabled = false,
    this.jpgQuality = 95,
    this.defaultMode = ColorMode.colorDocument,
    this.pdfSize = PdfPageSize.a4,
    this.showGrid = true,
    this.pdfQuality = PdfImageQuality.lossless,
  });

  Map<String, dynamic> toJson() => {
        'autoCapture': autoCapture,
        'ocrEnabled': ocrEnabled,
        'jpgQuality': jpgQuality,
        'defaultMode': defaultMode.name,
        'pdfSize': pdfSize.name,
        'pdfQuality': pdfQuality.name,
        'showGrid': showGrid,
      };

  factory AppSettings.fromJson(Map<String, dynamic> j) => AppSettings(
        autoCapture: j['autoCapture'] as bool? ?? true,
        ocrEnabled: j['ocrEnabled'] as bool? ?? false,
        jpgQuality: (j['jpgQuality'] as num?)?.toInt() ?? 95,
        defaultMode: ColorMode.values
            .firstWhere((e) => e.name == j['defaultMode'], orElse: () => ColorMode.colorDocument),
        pdfSize: PdfPageSize.values
            .firstWhere((e) => e.name == j['pdfSize'], orElse: () => PdfPageSize.a4),
        pdfQuality: PdfImageQuality.values
            .firstWhere((e) => e.name == j['pdfQuality'], orElse: () => PdfImageQuality.lossless),
        showGrid: j['showGrid'] as bool? ?? true,
      );
}

class SettingsService extends ChangeNotifier {
  SettingsService._();
  static final SettingsService instance = SettingsService._();

  AppSettings value = AppSettings();

  File get _file => File(p.join(AppStorage.instance.internalRoot.path, 'settings.json'));

  Future<void> load() async {
    try {
      if (await _file.exists()) {
        value = AppSettings.fromJson(jsonDecode(await _file.readAsString()) as Map<String, dynamic>);
      }
    } catch (_) {
      value = AppSettings();
    }
  }

  Future<void> update(void Function(AppSettings s) change) async {
    change(value);
    notifyListeners();
    await AppStorage.instance.writeBytesAtomic(_file.path, utf8.encode(jsonEncode(value.toJson())));
  }
}
