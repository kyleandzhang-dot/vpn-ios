import 'dart:io';
import 'dart:ui' show AppExitResponse;
import 'package:flutter/material.dart';
import 'config/app_config.dart';
import 'screens/home_screen.dart';
import 'services/notification_service.dart';
import 'services/windows_vpn.dart';

AppLifecycleListener? _exitListener; // 持有引用，防止被回收

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (Platform.isWindows) {
    // 清理上次崩溃/强杀残留的系统代理和核心进程
    await WindowsVpn.cleanupStale();
    // 正常关窗口时断开并还原系统代理（尽力而为，兜底是下次启动的 cleanupStale）
    _exitListener = AppLifecycleListener(onExitRequested: () async {
      await WindowsVpn.instance.disconnect();
      return AppExitResponse.exit;
    });
  }
  await NotificationService.init();
  await NotificationService.requestPermission();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: AppConfig.appName,
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        scaffoldBackgroundColor: AppConfig.colorBg,
        primaryColor: AppConfig.colorPrimary,
        colorScheme: ColorScheme.fromSeed(
          seedColor: AppConfig.colorPrimary,
          primary: AppConfig.colorPrimary,
          surface: AppConfig.colorBg,
        ),
        fontFamily: 'Roboto',
      ),
      home: const HomeScreen(),
    );
  }
}