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
      title: AppConfig.appName,[cite: 1]
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        scaffoldBackgroundColor: AppConfig.colorBg,[cite: 1]
        primaryColor: AppConfig.colorPrimary,[cite: 1]
        colorScheme: ColorScheme.fromSeed(
          seedColor: AppConfig.colorPrimary,[cite: 1]
          primary: AppConfig.colorPrimary,[cite: 1]
          surface: AppConfig.colorBg,[cite: 1]
        ),
        fontFamily: 'Roboto',
      ),
      home: const HomeScreen(),
    );
  }
}