import 'package:flutter/material.dart';
import '../config/app_config.dart';

class RechargeScreen extends StatelessWidget {
  const RechargeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('会员续费', style: TextStyle(color: AppConfig.colorPrimary, fontWeight: FontWeight.bold)),
        backgroundColor: AppConfig.colorBg,
        elevation: 0,
        iconTheme: const IconThemeData(color: AppConfig.colorPrimary),
      ),
      body: const Center(
        child: Text('充值页面建设中...', style: TextStyle(color: AppConfig.colorTextSub)),
      ),
    );
  }
}