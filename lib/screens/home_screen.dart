import 'dart:io';
import 'dart:math';
import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/gestures.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../config/app_config.dart';
import '../services/api_service.dart';
import '../services/vpn_bridge.dart';
import '../services/notification_service.dart';
import '../widgets/power_ring_view.dart';
import 'recharge_screen.dart';
import 'market_screen.dart';
import 'invite_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with SingleTickerProviderStateMixin {
  VpnState _vpnState = VpnState.disconnected;
  StreamSubscription? _vpnSubscription;
  late AnimationController _ringAnimController;

  // 【对接 iOS 原生】AppDelegate 中注册的独立日志分享通道
  static const _logChannel = MethodChannel('com.example.vpn_all/log');

  // 【减法】：删除了 _statusText 和 _statusType，只保留核心到期时间
  String _expireText = "";
  String _inviteBtnText = "免费领时长";
  
  String _cfgBuyQQ = "1772757914";
  String _cfgAnnouncement = "";
  String _cfgAnnouncementTitle = "公告";
  bool _showNoticeDot = false;
  bool _isFetchingAnnouncement = false; // 点铃铛图标手动刷新公告时的防抖标记，避免连续点击并发发多个请求
  String _uid = "";
  bool _uidFetchFailed = false; // 重试一次仍失败后置 true，UI 提示可点击重试

  bool _checkedInToday = false;
  bool _isCheckinLoading = false;
  bool _isCheckinDialogSubmitting = false; 
  int _checkinStreak = 0;
  int _checkinRewardMinutes = 30;
  bool _pendingCheckinPopup = false;

  // ================= 节点选择 =================
  List<Map<String, dynamic>> _nodeList = [];
  String? _selectedNodeId; 
  String _selectedNodeLabel = "自动选线";
  static const _prefsSelectedNodeIdKey = 'selected_node_id';
  static const _prefsSelectedNodeLabelKey = 'selected_node_label';

  bool _isDialogActive = false; 
  String? _pendingNodeJson;

  Timer? _connectTimeoutTimer;
  static const _connectTimeout = Duration(seconds: 15);

  @override
  void initState() {
    super.initState();
    _ringAnimController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 1),
    );

    _vpnSubscription = VpnBridge.statusStream.listen((state) {
      _cancelConnectTimeout();
      setState(() {
        _vpnState = state;
        _updateUIByState(state);
      });
    });

    _initData();
  }

  @override
  void dispose() {
    _ringAnimController.dispose();
    _vpnSubscription?.cancel();
    _connectTimeoutTimer?.cancel();
    super.dispose();
  }

  void _startConnectTimeout() {
    _cancelConnectTimeout();
    _connectTimeoutTimer = Timer(_connectTimeout, () {
      if (!mounted || _vpnState != VpnState.connecting) return;
      debugPrint('[VPN] 连接超时（${_connectTimeout.inSeconds}s），自动复位');
      VpnBridge.disconnect(); 
      setState(() {
        _vpnState = VpnState.disconnected;
        _ringAnimController.stop();
      });
      _showToast("连接超时，请检查网络后重试");
    });
  }

  void _cancelConnectTimeout() {
    _connectTimeoutTimer?.cancel();
    _connectTimeoutTimer = null;
  }

  void _updateUIByState(VpnState state) {
    switch (state) {
      case VpnState.disconnected:
        _ringAnimController.stop();
        break;
      case VpnState.connecting:
        _ringAnimController.repeat();
        break;
      case VpnState.connected:
        _ringAnimController.stop();
        break;
      case VpnState.expired:
        _ringAnimController.stop();
        _showToast("时长不足");
        // 安卓侧 CustomVpnService 的心跳检测到403时，已经用原生 NotificationManager
        // 弹过一次「服务已到期」的系统通知了（见 showExpiredNotification()）。
        // iOS 侧 PacketTunnelProvider 现在也一样，心跳检测到403/404时会直接调
        // UNUserNotificationCenter 弹一条本地通知（见 showExpiredLocalNotification），
        // 不再依赖主 App 存活/在前台。这里如果还调 NotificationService.showExpiredNow()，
        // 只要 App 恰好在前台/未被系统挂起，就会跟原生那条重复弹出两条通知
        // （两边 identifier 不一样，系统不会互相去重）。所以两端都不需要在这里
        // 额外弹通知了，只保留跳转充值页。
        if (!Platform.isIOS) {
          _openRechargePage();
        }
        break;
    }
  }

  Future<void> _initData() async {
    // 先秒读本地缓存的uid（上次成功拿到过的话），不用等这次网络请求，
    // 避免"看起来空白，几秒后才冒出来"的观感；纯新装设备这里还没有缓存，走下面的网络请求。
    ApiService.getCachedUid().then((cachedUid) {
      if (mounted && cachedUid != null && cachedUid.isNotEmpty && _uid.isEmpty) {
        setState(() => _uid = cachedUid);
      }
    });

    _fetchInviteInfoWithRetry();

    _loadNodes();
    _loadSelectedNode();

    final cfgData = await ApiService.fetchConfig();
    bool willShowAnnouncement = false;
    if (cfgData.isNotEmpty && cfgData['data'] != null) {
      final cfg = cfgData['data'];
      setState(() {
        _cfgBuyQQ = cfg['buy_qq'] ?? _cfgBuyQQ;
        _cfgAnnouncement = cfg['announcement'] ?? "";
        _cfgAnnouncementTitle = cfg['announcement_title'] ?? "公告";
      });
      willShowAnnouncement = await _checkAnnouncement();
    }

    final checkinData = await ApiService.fetchCheckinStatus();
    if (checkinData['code'] == 200 && checkinData['data'] != null) {
      setState(() {
        _checkedInToday = checkinData['data']['checked_today'] ?? false;
        _checkinStreak = checkinData['data']['streak_days'] ?? 0;
        _checkinRewardMinutes = checkinData['data']['reward_minutes'] ?? 30;
      });
    }

    if (!_checkedInToday) {
      if (willShowAnnouncement) {
        _pendingCheckinPopup = true;
      } else if (mounted) {
        _showCheckinDialog();
      }
    }
  }

  /// 拉取邀请信息（顺带拿 uid）。之前的写法是失败了就直接放弃——
  /// 首次冷启动网络栈没热，或者 iOS 原生取设备号的通道慢一点，
  /// 就会导致 UID 永远卡在"获取中..."，没有任何重试。
  /// 这里改成：失败/超时自动重试一次（等 2 秒，给网络栈缓一口气），
  /// 两次都失败就标记 _uidFetchFailed，UI 上把"获取中..."换成
  /// "获取失败，点击重试"，用户可以手动再触发一次。
  Future<void> _fetchInviteInfoWithRetry({bool isRetry = false}) async {
    final data = await ApiService.fetchInviteInfo();
    if (data['code'] == 200 && data['data'] != null) {
      final count = data['data']['invited_count'] ?? 0;
      final uid = data['data']['uid']?.toString() ?? '';
      if (mounted) {
        setState(() {
          _inviteBtnText = count > 0 ? "邀请奖励 (已邀$count人)" : "免费领时长";
          if (uid.isNotEmpty) {
            _uid = uid;
            _uidFetchFailed = false;
          }
        });
      }
      return;
    }

    // 第一次失败：等 2 秒自动重试一次，不打扰用户
    if (!isRetry) {
      await Future.delayed(const Duration(seconds: 2));
      if (!mounted) return;
      await _fetchInviteInfoWithRetry(isRetry: true);
      return;
    }

    // 重试过一次还是失败，且这次真的没拿到 uid（不是本地缓存兜底过了），
    // 才标记成失败态，让用户可以点击手动重试
    if (mounted && _uid.isEmpty) {
      setState(() => _uidFetchFailed = true);
    }
  }

  Future<void> _loadNodes() async {
    final data = await ApiService.fetchNodes();
    if (data['code'] == 200 && data['data'] != null && mounted) {
      setState(() {
        _nodeList = List<Map<String, dynamic>>.from(data['data']);
      });
    }
  }

  Future<void> _loadSelectedNode() async {
    final prefs = await SharedPreferences.getInstance();
    final savedId = prefs.getString(_prefsSelectedNodeIdKey);
    final savedLabel = prefs.getString(_prefsSelectedNodeLabelKey);
    if (savedId != null && savedId.isNotEmpty && mounted) {
      setState(() {
        _selectedNodeId = savedId;
        _selectedNodeLabel = savedLabel ?? "已选节点";
      });
    }
  }

  Future<void> _saveSelectedNode(String? nodeId, String label) async {
    final prefs = await SharedPreferences.getInstance();
    if (nodeId == null) {
      await prefs.remove(_prefsSelectedNodeIdKey);
      await prefs.remove(_prefsSelectedNodeLabelKey);
    } else {
      await prefs.setString(_prefsSelectedNodeIdKey, nodeId);
      await prefs.setString(_prefsSelectedNodeLabelKey, label);
    }
  }

  Future<bool> _checkAnnouncement() async {
    if (_cfgAnnouncement.isEmpty) return false;
    final prefs = await SharedPreferences.getInstance();
    final hash = (_cfgAnnouncementTitle + _cfgAnnouncement).hashCode.toString();
    final lastHash = prefs.getString('last_read_announcement_hash');

    if (hash != lastHash) {
      setState(() => _showNoticeDot = true);
      _showNoticeDialog();
      return true;
    }
    return false;
  }

  void _maybeShowPendingCheckinPopup() {
    if (_pendingCheckinPopup && !_checkedInToday) {
      _pendingCheckinPopup = false;
      _showCheckinDialog();
    }
  }

  void _markAnnouncementRead() async {
    final prefs = await SharedPreferences.getInstance();
    final hash = (_cfgAnnouncementTitle + _cfgAnnouncement).hashCode.toString();
    await prefs.setString('last_read_announcement_hash', hash);
    setState(() => _showNoticeDot = false);
  }

  void _openRechargePage() {
    Navigator.push(context, MaterialPageRoute(builder: (_) => const RechargeScreen()));
  }

  /// 统一更新到期文案 + 排定到期前的本地通知提醒
  void _applyExpireTime(String? expireTimeStr) {
    if (expireTimeStr == null || expireTimeStr.isEmpty) return;
    setState(() => _expireText = "有效期至: $expireTimeStr");
    final parsed = DateTime.tryParse(expireTimeStr);
    if (parsed != null) {
      NotificationService.scheduleExpireReminder(
        expireTime: parsed,
        before: const Duration(hours: 1),
      );
    } else {
      debugPrint('[Notify] 无法解析到期时间: $expireTimeStr');
    }
  }

  void _toggleConnect() async {
    if (_vpnState == VpnState.connected) {
      await VpnBridge.disconnect();
      setState(() {
        _vpnState = VpnState.disconnected;
        _updateUIByState(_vpnState);
      });
      return;
    }

    if (_vpnState == VpnState.connecting) {
      _cancelConnectTimeout();
      await VpnBridge.disconnect();
      setState(() {
        _vpnState = VpnState.disconnected;
        _updateUIByState(_vpnState);
      });
      _showToast("已取消连接");
      return;
    }

    setState(() {
      _vpnState = VpnState.connecting;
      _ringAnimController.repeat();
    });
    _startConnectTimeout();

    try {
      final res = await ApiService.getNode(nodeId: _selectedNodeId);
      if (res.statusCode == 200) {
        final jsonBody = json.decode(res.body);
        if (jsonBody['code'] == 200) {
          final data = jsonBody['data'];
          _pendingNodeJson = json.encode(data['node']);
          _applyExpireTime(data['expire_time']?.toString());
          // get_node 现在也带uid，多一条独立于 fetchInviteInfo 的兜底路径：
          // 就算首次冷启动时 fetchInviteInfo 那次网络请求没成功，
          // 用户一点连接触发 get_node，这里也能把 uid 补上。
          final nodeUid = data['uid']?.toString();
          if (nodeUid != null && nodeUid.isNotEmpty) {
            ApiService.cacheUid(nodeUid);
            if (mounted) setState(() => _uid = nodeUid);
          }
        } else if (jsonBody['code'] == 403) {
          _cancelConnectTimeout();
          setState(() {
            _vpnState = VpnState.disconnected;
            _updateUIByState(_vpnState);
          });
          _showToast("时长不足");
          NotificationService.showExpiredNow();
          if (!Platform.isIOS) {
            _openRechargePage();
          }
          return;
        } else {
          _cancelConnectTimeout();
          _showToast(jsonBody['msg'] ?? "连接失败");
          setState(() {
            _vpnState = VpnState.disconnected;
            _ringAnimController.stop();
          });
          return;
        }
      } else {
        _cancelConnectTimeout();
        _showToast("获取节点失败: HTTP ${res.statusCode}");
        setState(() {
          _vpnState = VpnState.disconnected;
          _ringAnimController.stop();
        });
        return;
      }
    } catch (e) {
      debugPrint('[VPN] getNode 失败: $e');
      _cancelConnectTimeout();
      setState(() {
        _vpnState = VpnState.disconnected;
        _ringAnimController.stop();
      });
      return;
    }

    try {
      await VpnBridge.connect(_pendingNodeJson!, apiBaseUrl: AppConfig.apiBaseUrl);
    } catch (e) {
      debugPrint('[VPN] VpnBridge.connect 失败: $e');
      _cancelConnectTimeout();
      setState(() {
        _vpnState = VpnState.disconnected;
        _ringAnimController.stop();
      });
      _showToast("VPN 隧道建立失败: $e");
    }
  }

  void _showToast(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg, style: const TextStyle(fontSize: 13)), 
        duration: const Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        backgroundColor: const Color(0xFF333333),
      )
    );
  }

  // ================= 业务交互调用 =================

  Future<void> _shareNativeLog() async {
    try {
      final Map<dynamic, dynamic>? res = await _logChannel.invokeMethod('shareLog');
      if (res != null) {
        final bool success = res['success'] == true;
        final String message = res['message']?.toString() ?? (success ? "已弹出日志分享面板" : "调起分享失败");
        _showToast(message);
      }
    } on PlatformException catch (e) {
      debugPrint("调起原生日志分享异常: ${e.message}");
      _showToast("分享失败: ${e.message ?? '未知平台错误'}");
    } catch (e) {
      debugPrint("调起原生日志分享出错: $e");
      _showToast("暂不支持该设备的日志分享");
    }
  }

  // ================= 公告链接识别 =================

  // 匹配 http/https 链接：排除空白符、中文字符和常见中文标点，
  // 这样公告里写"详情见 https://xxx.com，谢谢"这种紧跟中文逗号的情况，
  // 逗号不会被当成链接的一部分。
  static final RegExp _urlPattern = RegExp(
    r'https?:\/\/[^\s\u4e00-\u9fff，。！？；：、""''《》【】]+',
    caseSensitive: false,
  );

  /// 把公告文本按 URL 切段，普通文字保持原样，URL 部分做成带下划线的
  /// 可点击 TextSpan。英文链接后面偶尔会紧跟句号/右括号这类英文标点，
  /// 正则会把它们一起吃进去，这里额外裁掉尾部的这几种符号，
  /// 避免用户点进去的链接末尾多一个 "." 或 ")" 导致打不开。
  List<InlineSpan> _buildAnnouncementSpans(String text) {
    final spans = <InlineSpan>[];
    int lastEnd = 0;
    for (final match in _urlPattern.allMatches(text)) {
      if (match.start > lastEnd) {
        spans.add(TextSpan(text: text.substring(lastEnd, match.start)));
      }
      var url = match.group(0)!;
      while (url.isNotEmpty && ').,;:!?'.contains(url[url.length - 1])) {
        url = url.substring(0, url.length - 1);
      }
      spans.add(
        TextSpan(
          text: url,
          style: TextStyle(
            color: AppConfig.colorPrimary,
            decoration: TextDecoration.underline,
            fontWeight: FontWeight.w600,
          ),
          recognizer: TapGestureRecognizer()..onTap = () => _openAnnouncementLink(url),
        ),
      );
      lastEnd = match.start + url.length; // 用裁剪后的长度定位剩余文本起点，被裁掉的标点会回到下一段普通文字里正常显示
    }
    if (lastEnd < text.length) {
      spans.add(TextSpan(text: text.substring(lastEnd)));
    }
    return spans;
  }

  Future<void> _openAnnouncementLink(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) {
      _showToast("链接格式有误");
      return;
    }
    try {
      final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!ok && mounted) _showToast("无法打开链接");
    } catch (e) {
      debugPrint('[Notice] 打开公告链接失败: $e');
      if (mounted) _showToast("打开链接失败");
    }
  }

  /// 点铃铛图标手动查看公告。之前直接复用 App 启动时缓存的 _cfgAnnouncement，
  /// 公告后台更新了但用户没重启 App 的话，点开看到的还是旧内容。
  /// 改成点击时先重新请求一次 /api/v1/config，拿到最新公告内容再弹窗；
  /// 请求失败就还是用手头缓存的内容弹（不阻塞用户查看，只是可能不是最新的）。
  Future<void> _onNoticeIconTap() async {
    if (_isFetchingAnnouncement) return;
    _isFetchingAnnouncement = true;

    final cfgData = await ApiService.fetchConfig();
    if (cfgData.isNotEmpty && cfgData['data'] != null && mounted) {
      final cfg = cfgData['data'];
      setState(() {
        _cfgBuyQQ = cfg['buy_qq'] ?? _cfgBuyQQ;
        _cfgAnnouncement = cfg['announcement'] ?? _cfgAnnouncement;
        _cfgAnnouncementTitle = cfg['announcement_title'] ?? _cfgAnnouncementTitle;
      });
    }

    _isFetchingAnnouncement = false;
    if (mounted) _showNoticeDialog();
  }

  void _showNoticeDialog() {
    _isDialogActive = true;
    showDialog(
      context: context,
      builder: (_) => Dialog(
        backgroundColor: Colors.white, 
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(28, 28, 28, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _cfgAnnouncement.isNotEmpty ? _cfgAnnouncementTitle : "公告",
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700, 
                  color: Colors.black87,
                  letterSpacing: 0.5, 
                ),
              ),
              const SizedBox(height: 16),
              SelectableText.rich(
                TextSpan(
                  style: const TextStyle(
                    fontSize: 14,
                    color: Color(0xFF666666),
                    height: 1.6,
                  ),
                  children: _cfgAnnouncement.isNotEmpty
                      ? _buildAnnouncementSpans(_cfgAnnouncement)
                      : const [TextSpan(text: "暂无公告")],
                ),
              ),
              const SizedBox(height: 32),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppConfig.colorPrimary,
                    foregroundColor: Colors.white,
                    elevation: 0,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                  onPressed: () {
                    Navigator.pop(context);
                    _isDialogActive = false;
                    _markAnnouncementRead();
                    _maybeShowPendingCheckinPopup();
                  },
                  child: const Text(
                    "我知道了",
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                  ),
                ),
              )
            ],
          ),
        ),
      )
    );
  }

  void _showRechargeDialog() {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (_) => Dialog(
        backgroundColor: Colors.white,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(28, 28, 28, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                "卡密激活",
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: Colors.black87),
              ),
              const SizedBox(height: 8),
              const Text(
                "输入激活码，立即恢复服务时间",
                style: TextStyle(fontSize: 13, color: Color(0xFF888888)),
              ),
              const SizedBox(height: 24),
              TextField(
                controller: controller,
                style: const TextStyle(fontSize: 15, color: Colors.black87),
                decoration: InputDecoration(
                  hintText: "请输入激活码",
                  hintStyle: const TextStyle(fontSize: 14, color: Color(0xFFBBBBBB)),
                  filled: true,
                  fillColor: const Color(0xFFF7F8FA),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppConfig.colorPrimary,
                    foregroundColor: Colors.white,
                    elevation: 0,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                  ),
                  onPressed: () async {
                    final code = controller.text.trim();
                    if (code.isEmpty) {
                      _showToast("请输入激活码");
                      return;
                    }
                    Navigator.pop(context);
                    _showToast("正在验证...");
                    final res = await ApiService.recharge(code);
                    if (res['code'] == 200) {
                      _applyExpireTime(res['data']?['new_expire_time']?.toString());
                    }
                    _showToast(res['msg'] ?? "处理完成");
                  },
                  child: const Text("立即激活", style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                ),
              )
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _handleCheckin() async {
    if (_isCheckinLoading || _checkedInToday) return;

    setState(() => _isCheckinLoading = true);
    try {
      final res = await ApiService.checkin();
      if (res['code'] == 200 && res['data'] != null) {
        final rewardMinutes = res['data']['reward_minutes'] ?? _checkinRewardMinutes;
        setState(() {
          _checkedInToday = true;
          _checkinStreak = res['data']['streak_days'] ?? _checkinStreak;
        });
        _applyExpireTime(res['data']['new_expire_time']?.toString());
        _showToast("签到成功，时长 +$rewardMinutes 分钟");
      } else {
        if (res['code'] == 400) {
          setState(() => _checkedInToday = true);
        }
        _showToast(res['msg'] ?? "签到失败，请稍后重试");
      }
    } catch (e) {
      _showToast("网络异常，签到失败");
    } finally {
      if (mounted) setState(() => _isCheckinLoading = false);
    }
  }

  void _showCheckinDialog() {
    if (_isDialogActive || _checkedInToday) return;
    _isDialogActive = true;
    _isCheckinDialogSubmitting = false;

    showDialog(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) {
          Future<void> handleCheckinTap() async {
            if (_isCheckinLoading) return;
            setDialogState(() => _isCheckinDialogSubmitting = true);
            await _handleCheckin();
            if (!dialogContext.mounted) return;
            setDialogState(() => _isCheckinDialogSubmitting = false);
            if (_checkedInToday) {
              Future.delayed(const Duration(milliseconds: 400), () {
                if (dialogContext.mounted) Navigator.pop(dialogContext);
              });
            }
          }

          return Dialog(
            backgroundColor: Colors.white,
            elevation: 0,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(28, 32, 28, 24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 56, height: 56,
                    decoration: BoxDecoration(color: AppConfig.colorPrimary.withOpacity(0.08), shape: BoxShape.circle),
                    child: Icon(Icons.card_giftcard_rounded, size: 26, color: AppConfig.colorPrimary),
                  ),
                  const SizedBox(height: 20),
                  const Text("每日签到", style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: Colors.black87)),
                  const SizedBox(height: 10),
                  Text(
                    _checkinStreak > 0
                        ? "已连续签到 $_checkinStreak 天\n签到即可获得 $_checkinRewardMinutes 分钟免费时长"
                        : "签到即可获得 $_checkinRewardMinutes 分钟免费时长",
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 13, color: Color(0xFF666666), height: 1.6),
                  ),
                  const SizedBox(height: 28),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppConfig.colorPrimary,
                        foregroundColor: Colors.white,
                        elevation: 0,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                      ),
                      onPressed: _isCheckinDialogSubmitting ? null : handleCheckinTap,
                      child: _isCheckinDialogSubmitting
                          ? const SizedBox(
                              width: 18, height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                            )
                          : const Text("立即签到", style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextButton(
                    onPressed: () => Navigator.pop(dialogContext),
                    style: TextButton.styleFrom(foregroundColor: const Color(0xFF999999)),
                    child: const Text("下次再说", style: TextStyle(fontSize: 13)),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    ).then((_) => _isDialogActive = false);
  }

  // ================= 节点选择 =================

  void _showNodePickerSheet() {
    // 之前这里直接用 _initData 时加载的那份 _nodeList，节点可能在后台
    // 被下线/新增，缓存太久容易选到已经不可用的线路。改成每次点开都
    // 重新从后端拉一次最新列表，用 StatefulBuilder 管理弹窗内部的 loading
    // 状态（不能直接用外层 setState，因为 bottom sheet 的 builder 不会
    // 随外层 State 重建），拉完再把结果同步回 _nodeList，下次打开先展示
    // 这次的结果、同时仍然会再拉一次最新的。
    bool isLoadingNodes = true;
    bool hasStartedFetch = false;

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
      elevation: 0,
      isScrollControlled: true, 
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            if (!hasStartedFetch) {
              hasStartedFetch = true;
              // build 过程中不能直接 setState，用 microtask 延后到下一帧执行
              Future.microtask(() async {
                final data = await ApiService.fetchNodes();
                if (data['code'] == 200 && data['data'] != null) {
                  final freshList = List<Map<String, dynamic>>.from(data['data']);
                  if (mounted) setState(() => _nodeList = freshList); // 同步回外层，下次打开先展示这次结果
                }
                // 拉取失败就保留原来的 _nodeList 兜底展示，不清空
                setSheetState(() => isLoadingNodes = false);
              });
            }

            return SafeArea(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(24, 12, 24, 16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Center(
                      child: Container(
                        width: 36, height: 4,
                        margin: const EdgeInsets.only(bottom: 20),
                        decoration: BoxDecoration(color: const Color(0xFFE0E0E0), borderRadius: BorderRadius.circular(2)),
                      ),
                    ),
                    // 【改造】：极简标题，移除了多余的说明语
                    const Text(
                      "选择线路",
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                        color: Colors.black87,
                      ),
                    ),
                    const SizedBox(height: 20),
                    _buildNodeOptionTile(
                      label: "自动选线",
                      subtitle: "",
                      selected: _selectedNodeId == null,
                      onTap: () => _onSelectNode(null, "自动选线", sheetContext),
                    ),
                    if (isLoadingNodes)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 32),
                        child: Center(
                          child: SizedBox(
                            width: 20, height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        ),
                      )
                    else if (_nodeList.isEmpty)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 32),
                        child: Center(child: Text("暂无可选节点", style: TextStyle(fontSize: 13, color: Color(0xFF999999)))),
                      )
                    else
                      ..._nodeList.map((node) {
                        final nodeId = node['node_id'] as String;
                        final remark = (node['remark'] as String?)?.isNotEmpty == true ? node['remark'] as String : nodeId;
                        return _buildNodeOptionTile(
                          label: remark,
                          subtitle: "", // 【改造】：移除了“当前负载”字段
                          selected: _selectedNodeId == nodeId,
                          onTap: () => _onSelectNode(nodeId, remark, sheetContext),
                        );
                      }),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildNodeOptionTile({
    required String label,
    required String subtitle,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
        decoration: BoxDecoration(
          color: selected ? AppConfig.colorPrimary.withOpacity(0.06) : const Color(0xFFF7F8FA),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: selected ? AppConfig.colorPrimary.withOpacity(0.4) : Colors.transparent, 
            width: 1.5
          ),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label, 
                    style: TextStyle(
                      fontSize: 15, 
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w500, 
                      color: selected ? AppConfig.colorPrimary : Colors.black87
                    )
                  ),
                  if (subtitle.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(subtitle, style: const TextStyle(fontSize: 12, color: Color(0xFF888888))),
                  ]
                ],
              ),
            ),
            if (selected) 
              Icon(Icons.check_circle_rounded, size: 20, color: AppConfig.colorPrimary)
            else 
              const Icon(Icons.circle_outlined, size: 20, color: Color(0xFFDDDDDD)),
          ],
        ),
      ),
    );
  }

  void _onSelectNode(String? nodeId, String label, BuildContext sheetContext) {
    if (_vpnState == VpnState.connected || _vpnState == VpnState.connecting) {
      _showToast("请先断开当前连接再切换节点");
      return;
    }
    setState(() {
      _selectedNodeId = nodeId;
      _selectedNodeLabel = label;
    });
    _saveSelectedNode(nodeId, label);
    Navigator.pop(sheetContext);
  }

  // ================= 1. 改为极简字体的「服务到期」 =================
  Widget _buildExpireTag() {
    if (_expireText.isEmpty) return const SizedBox.shrink();

    final cleanExpire = _expireText
        .replaceAll("有效期至: ", "")
        .replaceAll("有效期至:", "")
        .replaceAll("服务到期: ", "")
        .replaceAll("服务到期:", "")
        .trim();

    return Text(
      "服务有效至 $cleanExpire",
      style: const TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w500,
        color: Color(0xFF999999),
        letterSpacing: 0.2,
      ),
    );
  }

  // ================= 页面视图构建 =================

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppConfig.colorBg,
      body: SafeArea(
        child: Column(
          children: [
            _buildTopBar(),
            Expanded(child: _buildCenterBody()),
            _buildBottomArea(),
            _buildUidTag(),
          ],
        ),
      ),
    );
  }

  // ================= 3. 将线路选择移到左上角喵脸下面（已替换回文字） =================
  Widget _buildTopBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                // 喵脸 / Logo 文字（替换了原有的猫咪脚图标）
                const Text(
                  AppConfig.appName, // 默认会显示原有的 "喵脸" 两字
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w800,
                    color: Colors.black87,
                    letterSpacing: -0.5,
                  ),
                ),

                const SizedBox(height: 4),

                // 小型线路选择入口
                GestureDetector(
                  onTap: () {
                    if (_vpnState == VpnState.connected ||
                        _vpnState == VpnState.connecting) {
                      _showToast("请先停止连接再切换线路");
                      return;
                    }
                    _showNodePickerSheet();
                  },
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        _selectedNodeLabel,
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w500,
                          color: (_vpnState == VpnState.connected ||
                                  _vpnState == VpnState.connecting)
                              ? const Color(0xFFBBBBBB)
                              : const Color(0xFF777777),
                        ),
                      ),
                      const SizedBox(width: 2),
                      Icon(
                        Icons.keyboard_arrow_down_rounded,
                        size: 13,
                        color: (_vpnState == VpnState.connected ||
                                _vpnState == VpnState.connecting)
                            ? const Color(0xFFBBBBBB)
                            : const Color(0xFF777777),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          
          // 右侧常规操作区（Bug日志/公告等）
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Row(
              children: [
                GestureDetector(
                  onTap: _shareNativeLog,
                  child: Container(
                    margin: const EdgeInsets.only(right: 12),
                    padding: const EdgeInsets.all(10),
                    decoration: const BoxDecoration(
                      color: Color(0xFFF2F3F5), 
                      shape: BoxShape.circle, 
                    ),
                    child: const Icon(Icons.bug_report_outlined, size: 20, color: Colors.black87),
                  ),
                ),
                GestureDetector(
                  onTap: _onNoticeIconTap,
                  child: Container(
                    margin: const EdgeInsets.only(right: 12),
                    padding: const EdgeInsets.all(10),
                    decoration: const BoxDecoration(
                      color: Color(0xFFF2F3F5), 
                      shape: BoxShape.circle, 
                    ),
                    child: Stack(
                      clipBehavior: Clip.none,
                      children: [
                        const Icon(Icons.notifications_none_rounded, size: 20, color: Colors.black87),
                        if (_showNoticeDot)
                          Positioned(
                            right: -1, top: -1,
                            child: Container(
                              width: 7, height: 7, 
                              decoration: const BoxDecoration(color: Color(0xFFFF4D4F), shape: BoxShape.circle)
                            ),
                          )
                      ],
                    ),
                  ),
                ),
                if (!Platform.isIOS)
                  GestureDetector(
                    onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const MarketScreen())),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF2F3F5), 
                        borderRadius: BorderRadius.circular(999), 
                      ),
                      child: const Text(
                        "海外应用", 
                        style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Colors.black87)
                      ),
                    ),
                  )
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ================= 2. 删除了中间的「选择路线」组件 =================
  Widget _buildCenterBody() {
    final isConnected = _vpnState == VpnState.connected;

    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        // 核心大环形连接按钮
        SizedBox(
          width: 210, 
          height: 210,
          child: Stack(
            alignment: Alignment.center,
            children: [
              if (_vpnState == VpnState.connecting)
                AnimatedBuilder(
                  animation: _ringAnimController,
                  builder: (_, __) => Transform.rotate(
                    angle: _ringAnimController.value * 2 * pi,
                    child: CustomPaint(size: const Size(210, 210), painter: SpinningRingPainter()),
                  ),
                ),
              GestureDetector(
                onTap: _toggleConnect,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 300),
                  curve: Curves.easeOutCubic,
                  width: 176, 
                  height: 176,
                  decoration: BoxDecoration(
                    color: isConnected ? AppConfig.colorBg : AppConfig.colorPrimary,
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: isConnected ? AppConfig.colorPrimary : AppConfig.colorPrimary.withOpacity(0.8), 
                      width: isConnected ? 3 : 1
                    ),
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      CustomPaint(
                        size: const Size(34, 34),
                        painter: PowerIconPainter(color: isConnected ? AppConfig.colorPrimary : Colors.white),
                      ),
                      const SizedBox(height: 14),
                      Text(
                        isConnected ? "已连接" : (_vpnState == VpnState.connecting ? "连接中" : "点击连接"),
                        style: TextStyle(
                          fontSize: 15, 
                          fontWeight: FontWeight.w700, 
                          color: isConnected ? AppConfig.colorPrimary : Colors.white,
                          letterSpacing: 1.0,
                        ),
                      )
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),

        const SizedBox(height: 32),

        // 服务有效期（纯纯的细文本文字）
        _buildExpireTag(),
      ],
    );
  }

  /// 页面最底部的UID标签：改为常驻打开显示，点击复制到剪贴板。
  /// 即使在 iOS 隐藏了底部功能区，UID 也会固定呈现在页面下方。
  Widget _buildUidTag() {
    String displayUid;
    if (_uid.isNotEmpty) {
      displayUid = _uid;
    } else if (_uidFetchFailed) {
      displayUid = "获取失败，点击重试";
    } else {
      displayUid = "获取中...";
    }
    return Padding(
      // 【优化】：顶部留白仅 4px（与上文衔接），底部留白 14px（给屏幕底边留出呼吸感）
      padding: const EdgeInsets.only(top: 4, bottom: 14),
      child: GestureDetector(
        onTap: () => _copyUid(),
        behavior: HitTestBehavior.opaque,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              "UID: $displayUid",
              style: const TextStyle(
                fontSize: 12, // 【优化】：将 13 改为 12，与上方的激活码字号一致，更协调
                color: Color(0xFF999999),
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(width: 4),
            const Icon(Icons.copy_rounded, size: 13, color: Color(0xFF999999)),
          ],
        ),
      ),
    );
  }

  void _copyUid() {
    if (_uid.isEmpty) {
      // 之前失败/还在获取时点击只会弹个"请稍后"，用户除了干等没别的办法。
      // 现在点一下就手动再拉一次（不再等自动重试的 2 秒延迟），
      // 拉取失败态也顺手清掉，避免一直显示"获取失败"。
      _showToast(_uidFetchFailed ? "正在重新获取 UID..." : "UID正在获取中，请稍后");
      if (_uidFetchFailed) {
        setState(() => _uidFetchFailed = false);
        _fetchInviteInfoWithRetry();
      }
      return;
    }
    Clipboard.setData(ClipboardData(text: _uid));
    _showToast("UID已复制");
  }

  Widget _buildBottomArea() {
    // 暂时在 iOS 平台隐藏整个底部区域（包含免费领取时长）
    if (Platform.isIOS) {
      return const SizedBox.shrink();
    }

    return Padding(
      // 【优化】：底部内边距从 16 改为 2
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 2),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                child: GestureDetector(
                  onTap: () {
                    Navigator.push(
                      context, 
                      MaterialPageRoute(builder: (_) => const InviteScreen()),
                    ).then((_) => _initData());
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    decoration: BoxDecoration(
                      color: Platform.isIOS ? const Color(0xFFF2F3F5) : AppConfig.colorPrimary.withOpacity(0.08),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      _inviteBtnText, 
                      style: TextStyle(
                        fontSize: 14, 
                        fontWeight: Platform.isIOS ? FontWeight.w700 : FontWeight.w600, 
                        color: Platform.isIOS ? const Color(0xFF181818) : AppConfig.colorPrimary,
                        letterSpacing: 0.3,
                      ),
                      maxLines: 1, 
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              ),
              if (!Platform.isIOS) ...[
                const SizedBox(width: 12),
                Expanded(
                  child: GestureDetector(
                    onTap: _openRechargePage,
                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      decoration: BoxDecoration(
                        color: AppConfig.colorPrimary,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      alignment: Alignment.center,
                      child: const Text(
                        "立即充值", 
                        style: TextStyle(
                          fontSize: 14, 
                          fontWeight: FontWeight.w600, 
                          color: Colors.white,
                          letterSpacing: 0.3,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),

          const SizedBox(height: 12), // 【优化】：由 16 微调为 12，拉近按钮与激活码提示的距离

          if (!Platform.isIOS)
            GestureDetector(
              onTap: _showRechargeDialog,
              behavior: HitTestBehavior.opaque,
              child: const Padding(
                // 【优化】：上下 Padding 从 8 收紧为 4
                padding: EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.key_outlined, size: 14, color: Color(0xFF999999)),
                    SizedBox(width: 4),
                    Text("持有激活码？点击直接兑换", style: TextStyle(fontSize: 12, color: Color(0xFF999999))),
                    Icon(Icons.keyboard_arrow_right_rounded, size: 14, color: Color(0xFF999999)),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}