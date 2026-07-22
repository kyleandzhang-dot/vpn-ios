import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:android_id/android_id.dart';
import 'package:uuid/uuid.dart';
import '../config/app_config.dart';

class ApiService {
  static const _androidIdPlugin = AndroidId();

  static Future<String> getDeviceId() async {
    final prefs = await SharedPreferences.getInstance();
    String? deviceId = prefs.getString('device_uuid');
    if (deviceId != null && deviceId.isNotEmpty) {
      return deviceId;
    }

    try {
      if (Platform.isAndroid) {
        // device_info_plus 的 AndroidDeviceInfo 里没有 androidId 字段，
        // 它的 .id 对应的是 Build.ID（固件版本号），不是设备唯一标识。
        // 真正的 Settings.Secure.ANDROID_ID 需要用专门的 android_id 插件获取。
        deviceId = (await _androidIdPlugin.getId())
            ?.replaceAll('-', '')
            .toUpperCase();
      } else if (Platform.isIOS) {
        final deviceInfo = DeviceInfoPlugin();
        final iosInfo = await deviceInfo.iosInfo;
        deviceId = iosInfo.identifierForVendor?.replaceAll('-', '').toUpperCase();
      }
    } catch (_) {
      deviceId = null;
    }

    // 过滤已知的坏值/空值：
    // - "0000000000000000"：模拟器或部分设备上 ANDROID_ID 的默认空值
    // - "9774D56D682E549C"：老版本安卓(2.2及以前)在特定条件下所有设备共享的经典默认值
    const invalidIds = {"0000000000000000", "9774D56D682E549C"};
    if (deviceId == null ||
        deviceId.isEmpty ||
        invalidIds.contains(deviceId.toUpperCase())) {
      // 兜底：生成真正随机的 UUID，并去掉横杠、转大写，跟正常设备号格式保持一致
      deviceId = const Uuid().v4().replaceAll('-', '').toUpperCase();
    }

    await prefs.setString('device_uuid', deviceId);
    return deviceId;
  }

  static Future<Map<String, dynamic>> fetchConfig() async {
    try {
      final response = await http.get(Uri.parse('${AppConfig.apiBaseUrl}/api/v1/config')).timeout(const Duration(seconds: 5));
      if (response.statusCode == 200) {
        return json.decode(response.body);
      }
    } catch (_) {}
    return {};
  }

  static Future<Map<String, dynamic>> fetchVersion() async {
    try {
      final response = await http.get(Uri.parse('${AppConfig.apiBaseUrl}/api/v1/app_version')).timeout(const Duration(seconds: 5));
      if (response.statusCode == 200) {
        return json.decode(response.body);
      }
    } catch (_) {}
    return {};
  }

  static Future<Map<String, dynamic>> fetchInviteInfo() async {
    final deviceId = await getDeviceId();
    final response = await http.get(Uri.parse('${AppConfig.apiBaseUrl}/api/v1/invite_info?device_id=$deviceId')).timeout(const Duration(seconds: 5));
    return json.decode(response.body);
  }

  static Future<Map<String, dynamic>> bindInviteCode(String code) async {
    final deviceId = await getDeviceId();
    final response = await http.post(
      Uri.parse('${AppConfig.apiBaseUrl}/api/v1/bind_invite'),
      headers: {'Content-Type': 'application/json'},
      body: json.encode({'device_id': deviceId, 'invite_code': code}),
    ).timeout(const Duration(seconds: 5));
    return json.decode(response.body);
  }

  static Future<Map<String, dynamic>> recharge(String code) async {
    final deviceId = await getDeviceId();
    final response = await http.post(
      Uri.parse('${AppConfig.apiBaseUrl}/api/v1/recharge'),
      headers: {'Content-Type': 'application/json'},
      body: json.encode({'device_id': deviceId, 'code': code}),
    ).timeout(const Duration(seconds: 5));
    return json.decode(response.body);
  }

  static Future<http.Response> getNode() async {
    final deviceId = await getDeviceId();
    return await http.post(
      Uri.parse('${AppConfig.apiBaseUrl}/api/v1/get_node'),
      headers: {'Content-Type': 'application/json'},
      body: json.encode({'device_id': deviceId}),
    ).timeout(const Duration(seconds: 5));
  }

  // ================= 每日签到 =================

  /// 执行签到。网络异常/服务器错误时返回 {code: -1, msg: ...} 而不是抛异常，
  /// 方便页面统一走 res['code'] != 200 的失败提示分支。
  static Future<Map<String, dynamic>> checkin() async {
    final deviceId = await getDeviceId();
    try {
      final response = await http.post(
        Uri.parse('${AppConfig.apiBaseUrl}/api/v1/checkin'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({'device_id': deviceId}),
      ).timeout(const Duration(seconds: 8));
      return json.decode(response.body);
    } catch (_) {
      return {'code': -1, 'msg': '网络连接异常，请稍后重试'};
    }
  }

  /// 查询今天是否已签到、连续签到天数，供进入页面时渲染按钮初始状态。
  static Future<Map<String, dynamic>> fetchCheckinStatus() async {
    final deviceId = await getDeviceId();
    try {
      final response = await http
          .get(Uri.parse('${AppConfig.apiBaseUrl}/api/v1/checkin_status?device_id=$deviceId'))
          .timeout(const Duration(seconds: 8));
      return json.decode(response.body);
    } catch (_) {
      return {'code': -1, 'msg': '网络连接异常'};
    }
  }

  // ================= 商城 =================

  /// 拉取应用市场列表。网络异常/服务器错误时返回 {code: -1/状态码, msg: ...}，
  /// 而不是抛异常或返回空map，方便页面区分"加载中/出错/空列表"三种状态。
  static Future<Map<String, dynamic>> fetchMarketApps() async {
    try {
      final response = await http
          .get(Uri.parse('${AppConfig.apiBaseUrl}/api/v1/market/apps'))
          .timeout(const Duration(seconds: 8));
      if (response.statusCode == 200) {
        return json.decode(response.body);
      }
      return {'code': response.statusCode, 'msg': '服务器错误 ${response.statusCode}'};
    } catch (_) {
      return {'code': -1, 'msg': '网络连接异常'};
    }
  }

  // ================= 支付 / 充值 =================

  static Future<Map<String, dynamic>> createPaymentOrder({
    required int productId,
    String paymentMethod = 'wechat',
  }) async {
    final deviceId = await getDeviceId();
    try {
      final response = await http.post(
        Uri.parse('${AppConfig.apiBaseUrl}/api/v1/payment/create'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({
          'product_id': productId,
          'payment_method': paymentMethod,
          'source': 'app',
          'device_id': deviceId,
        }),
      ).timeout(const Duration(seconds: 8));
      return json.decode(response.body);
    } catch (_) {
      return {'code': -1, 'msg': '网络连接异常，请稍后重试'};
    }
  }

  static Future<Map<String, dynamic>> fetchPaymentStatus(String orderId) async {
    final response = await http
        .get(Uri.parse('${AppConfig.apiBaseUrl}/api/v1/payment/status/$orderId'))
        .timeout(const Duration(seconds: 6));
    return json.decode(response.body);
  }
}