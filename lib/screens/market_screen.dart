import 'package:flutter/material.dart';
import '../config/app_config.dart';

class MarketScreen extends StatelessWidget {
  const MarketScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('海外应用推荐', style: TextStyle(color: AppConfig.colorPrimary, fontWeight: FontWeight.bold)),[cite: 1]
        backgroundColor: AppConfig.colorBg,
        elevation: 0,
        iconTheme: const IconThemeData(color: AppConfig.colorPrimary),
      ),
      body: const Center(
        child: Text('应用市场页面建设中...', style: TextStyle(color: AppConfig.colorTextSub)),
      ),
    );
  }
}