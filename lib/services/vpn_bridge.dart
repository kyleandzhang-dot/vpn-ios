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

  /// [apiBaseUrl] 会透传给 iOS 原生的 PacketTunnelProvider(Network Extension)，
  /// 供它在隧道进程里自己定时查账号是否到期。安卓这边如果心跳检测走的是
  /// 应用内 VpnService（跟主 App 同进程），不需要这个参数也能正常工作，
  /// 传了也不影响。
  static Future<void> connect(String nodeJson, {String apiBaseUrl = ''}) async {
    try {
      await _channel.invokeMethod('connect', {
        'node_json': nodeJson,
        'api_base_url': apiBaseUrl,
      });
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

  static Future<String> getDeviceId() async {
    try {
      // 通过已经定义好的 _channel ('com.example.vpn_all/vpn') 调用原生方法[cite: 2]
      final String? deviceId = await _channel.invokeMethod('getDeviceId');
      return deviceId ?? '';
    } catch (e) {
      return '';
    }
  }
}