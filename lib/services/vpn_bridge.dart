import 'dart:async';
import 'package:flutter/services.dart';

enum VpnState { disconnected, connecting, connected, expired }

class VpnBridge {
  static const MethodChannel _channel = MethodChannel('com.example.vpn_all/vpn');
  static const EventChannel _eventChannel = EventChannel('com.example.vpn_all/vpn_status');

  // 单独的 channel，专门给"手动分享日志"测试按钮用，跟 connect/disconnect 的
  // channel 分开，避免互相影响。
  static const MethodChannel _logChannel = MethodChannel('com.example.vpn_all/log');

  /// 手动触发一次日志分享面板。
  /// 返回 {'success': bool, 'message': String}，方便 UI 直接弹 toast 提示结果
  /// （比如日志文件还不存在、是空的，或者分享面板已经弹出）。
  static Future<Map<String, dynamic>> shareLog() async {
    try {
      final result = await _logChannel.invokeMethod('shareLog');
      return Map<String, dynamic>.from(result as Map);
    } catch (e) {
      return {'success': false, 'message': '调用分享日志失败: $e'};
    }
  }

  static Stream<VpnState>? _statusStream;

  static Stream<VpnState> get statusStream {
    _statusStream ??= _eventChannel.receiveBroadcastStream().map((event) {
      final String stateStr = event.toString();
      switch (stateStr) {
        case "CONNECTED":
          return VpnState.connected;
        case "CONNECTING":
          return VpnState.connecting;
        case "EXPIRED":
          return VpnState.expired;
        default:
          return VpnState.disconnected;
      }
    });
    return _statusStream!;
  }

  static Future<void> connect(String nodeJson) async {
    try {
      await _channel.invokeMethod('connect', {'node_json': nodeJson});
    } catch (e) {
      rethrow;
    }
  }

  static Future<void> disconnect() async {
    try {
      await _channel.invokeMethod('disconnect');
    } catch (e) {
      rethrow;
    }
  }
}