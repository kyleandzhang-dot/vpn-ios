import 'dart:math';
import 'package:flutter/material.dart';
import '../config/app_config.dart';

class PowerIconPainter extends CustomPainter {
  final Color color;
  PowerIconPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.0
      ..strokeCap = StrokeCap.round;[cite: 1]

    final cx = size.width / 2;
    final cy = size.height / 2;
    final radius = min(cx, cy) - paint.strokeWidth;
    final rect = Rect.fromCircle(center: Offset(cx, cy), radius: radius);

    // 绘制外部圆弧 (-60度 到 300度)[cite: 1]
    canvas.drawArc(rect, -60 * pi / 180, 300 * pi / 180, false, paint);[cite: 1]
    // 绘制中心竖线[cite: 1]
    canvas.drawLine(Offset(cx, cy - radius * 0.3), Offset(cx, cy - radius), paint);[cite: 1]
  }

  @override
  bool shouldRepaint(covariant PowerIconPainter oldDelegate) => oldDelegate.color != color;
}

class SpinningRingPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0
      ..strokeCap = StrokeCap.round
      ..shader = SweepGradient(
        colors: [Colors.transparent, AppConfig.colorPrimary],[cite: 1]
        stops: const [0.0, 1.0],[cite: 1]
      ).createShader(rect);

    final pad = paint.strokeWidth / 2;
    canvas.drawOval(Rect.fromLTRB(pad, pad, size.width - pad, size.height - pad), paint);[cite: 1]
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}