import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:device_info_plus/device_info_plus.dart';
import '../config/app_config.dart';

class ApiService {
  static Future<String> getDeviceId() async {
    final prefs = await SharedPreferences.getInstance();
    String? deviceId = prefs.getString('device_uuid');
    if (deviceId != null && deviceId.isNotEmpty) {
      return deviceId;
    }

    final deviceInfo = DeviceInfoPlugin();
    if (Platform.isAndroid) {
      final androidInfo = await deviceInfo.androidInfo;
      deviceId = androidInfo.id.replaceAll('-', '').toUpperCase();[cite: 1]
    } else if (Platform.isIOS) {
      final iosInfo = await deviceInfo.iosInfo;
      deviceId = iosInfo.identifierForVendor?.replaceAll('-', '').toUpperCase() ?? '';
    }

    if (deviceId == null || deviceId.isEmpty || deviceId == "0000000000000000") {[cite: 1]
      deviceId = DateTime.now().millisecondsSinceEpoch.toString();
    }

    await prefs.setString('device_uuid', deviceId);
    return deviceId;
  }

  static Future<Map<String, dynamic>> fetchConfig() async {
    try {
      final response = await http.get(Uri.parse('${AppConfig.apiBaseUrl}/api/v1/config')).timeout(const Duration(seconds: 5));[cite: 1]
      if (response.statusCode == 200) {
        return json.decode(response.body);
      }
    } catch (_) {}
    return {};
  }

  static Future<Map<String, dynamic>> fetchVersion() async {
    try {
      final response = await http.get(Uri.parse('${AppConfig.apiBaseUrl}/api/v1/app_version')).timeout(const Duration(seconds: 5));[cite: 1]
      if (response.statusCode == 200) {
        return json.decode(response.body);
      }
    } catch (_) {}
    return {};
  }

  static Future<Map<String, dynamic>> fetchInviteInfo() async {
    final deviceId = await getDeviceId();
    final response = await http.get(Uri.parse('${AppConfig.apiBaseUrl}/api/v1/invite_info?device_id=$deviceId')).timeout(const Duration(seconds: 5));[cite: 1]
    return json.decode(response.body);
  }

  static Future<Map<String, dynamic>> bindInviteCode(String code) async {
    final deviceId = await getDeviceId();
    final response = await http.post(
      Uri.parse('${AppConfig.apiBaseUrl}/api/v1/bind_invite'),[cite: 1]
      headers: {'Content-Type': 'application/json'},
      body: json.encode({'device_id': deviceId, 'invite_code': code}),[cite: 1]
    ).timeout(const Duration(seconds: 5));
    return json.decode(response.body);
  }

  static Future<Map<String, dynamic>> recharge(String code) async {
    final deviceId = await getDeviceId();
    final response = await http.post(
      Uri.parse('${AppConfig.apiBaseUrl}/api/v1/recharge'),[cite: 1]
      headers: {'Content-Type': 'application/json'},
      body: json.encode({'device_id': deviceId, 'code': code}),[cite: 1]
    ).timeout(const Duration(seconds: 5));
    return json.decode(response.body);
  }

  static Future<http.Response> getNode() async {
    final deviceId = await getDeviceId();
    return await http.post(
      Uri.parse('${AppConfig.apiBaseUrl}/api/v1/get_node'),[cite: 1]
      headers: {'Content-Type': 'application/json'},
      body: json.encode({'device_id': deviceId}),[cite: 1]
    ).timeout(const Duration(seconds: 5));
  }
}