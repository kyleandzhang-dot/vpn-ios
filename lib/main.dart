import 'package:flutter/material.dart';
import 'config/app_config.dart';
import 'screens/home_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
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