import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'screens/home_screen.dart';
import 'services/settings_service.dart';
import 'services/storage/app_storage.dart';
import 'widgets/brand.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  await AppStorage.instance.init();
  await SettingsService.instance.load();
  runApp(const SmartScannerApp());
}

class SmartScannerApp extends StatelessWidget {
  const SmartScannerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: Brand.appName,
      debugShowCheckedModeBanner: false,
      theme: Brand.theme(),
      home: const HomeScreen(),
    );
  }
}
