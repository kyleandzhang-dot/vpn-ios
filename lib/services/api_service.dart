import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:android_id/android_id.dart';
import 'package:uuid/uuid.dart';
import '../config/app_config.dart';
// ⚠️ 按你项目实际路径改一下这个 import
import 'vpn_bridge.dart';

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
        // 不再用 identifierForVendor：那个值只在主 App 进程里生成/缓存，
        // 跟 Network Extension（PacketTunnelProvider）里 DeviceIdManager
        // 走 Keychain 生成的 ID 是两份完全不同的值，会导致后台隧道心跳
        // 检测账号状态时用的 device_id 跟登录/付费用的对不上。
        // 改成走 native 方法通道，读同一份存在共享 Keychain 里的 ID。
        final nativeId = await VpnBridge.getDeviceId();
        deviceId = nativeId.isNotEmpty
            ? nativeId.replaceAll('-', '').toUpperCase()
            : null;
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

  // ================= UID 本地缓存 =================
  // 后端 invite_info / get_node 现在都会返回 uid（首页初始化时调 fetchInviteInfo
  // 就会自动建号+拿到uid，不用非要点一次连接）。这里顺手缓存一份到本地，
  // 这样主页展示 uid 或者调用 rechargeByUid 时不用每次都等一次网络请求。
  static const _uidPrefsKey = 'cached_uid';

  static Future<void> _cacheUidIfPresent(Map<String, dynamic>? data) async {
    final uid = data?['uid']?.toString();
    if (uid != null && uid.isNotEmpty) {
      await cacheUid(uid);
    }
  }

  /// 公开方法：外部（比如 get_node 成功回调）拿到uid后也可以直接调这个存本地缓存
  static Future<void> cacheUid(String uid) async {
    if (uid.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_uidPrefsKey, uid);
  }

  /// 读取本地缓存的uid，还没拿到过就返回 null（正常在 fetchInviteInfo 成功一次后就会有值）
  static Future<String?> getCachedUid() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_uidPrefsKey);
  }

  static Future<Map<String, dynamic>> fetchInviteInfo() async {
    try {
      final deviceId = await getDeviceId();
      final response = await http
          .get(Uri.parse('${AppConfig.apiBaseUrl}/api/v1/invite_info?device_id=$deviceId'))
          .timeout(const Duration(seconds: 8));
      final result = json.decode(response.body) as Map<String, dynamic>;
      if (result['code'] == 200) {
        await _cacheUidIfPresent(result['data'] as Map<String, dynamic>?);
      }
      return result;
    } catch (_) {
      // 首次冷启动网络栈还没热起来时容易超时/失败，之前这里没有 try/catch，
      // 请求一失败就直接抛异常，_initData 里 .then() 的成功回调完全不会执行，
      // uid/邀请信息就再也没机会更新，只能等下次重新打开App。
      // 改成返回 {code:-1}，让页面走"这次没拿到，下次再试"的分支，而不是静默丢失。
      return {'code': -1, 'msg': '网络连接异常'};
    }
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

  /// 通过 uid（而不是 device_id）充值。用于客服/人工代充场景：
  /// 用户口头报一个短数字uid，不用抄一长串 device_id。
  static Future<Map<String, dynamic>> rechargeByUid(String uid, String code) async {
    final response = await http.post(
      Uri.parse('${AppConfig.apiBaseUrl}/api/v1/recharge_by_uid'),
      headers: {'Content-Type': 'application/json'},
      body: json.encode({'uid': uid, 'code': code}),
    ).timeout(const Duration(seconds: 5));
    return json.decode(response.body);
  }

  static Future<http.Response> getNode({String? nodeId}) async {
    final deviceId = await getDeviceId();
    final body = <String, dynamic>{'device_id': deviceId};
    if (nodeId != null && nodeId.isNotEmpty) {
      body['node_id'] = nodeId; // 用户手动指定节点；不传 = 服务端自动负载均衡
    }
    return await http.post(
      Uri.parse('${AppConfig.apiBaseUrl}/api/v1/get_node'),
      headers: {'Content-Type': 'application/json'},
      body: json.encode(body),
    ).timeout(const Duration(seconds: 5));
  }

  // ================= 节点列表 =================

  /// 拉取可选节点列表（用于"手动选节点"面板）。网络异常/服务器错误时
  /// 返回 {code: -1/状态码, msg: ...}，不抛异常，方便面板区分加载中/出错/空列表。
  static Future<Map<String, dynamic>> fetchNodes() async {
    try {
      final response = await http
          .get(Uri.parse('${AppConfig.apiBaseUrl}/api/v1/nodes'))
          .timeout(const Duration(seconds: 8));
      if (response.statusCode == 200) {
        return json.decode(response.body);
      }
      return {'code': response.statusCode, 'msg': '服务器错误 ${response.statusCode}'};
    } catch (_) {
      return {'code': -1, 'msg': '网络连接异常'};
    }
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