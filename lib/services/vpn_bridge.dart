import 'dart:async';
import 'package:flutter/services.dart';

enum VpnState { disconnected, connecting, connected, expired }

class VpnBridge {
  static const MethodChannel _channel = MethodChannel('com.example.vpn_all/vpn');
  static const EventChannel _eventChannel = EventChannel('com.example.vpn_all/vpn_status');

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