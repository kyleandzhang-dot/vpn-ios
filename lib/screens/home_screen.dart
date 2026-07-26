import 'dart:io';
import 'dart:math';
import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
  String _uid = "";

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
        _showToast("时长不足，请充值");
        // 安卓侧 CustomVpnService 的心跳检测到403时，已经用原生 NotificationManager
        // 弹过一次「服务已到期」的系统通知了（见 showExpiredNotification()），
        // 这里如果再弹一次 flutter_local_notifications 会导致安卓上重复弹两条。
        // iOS 目前没有等价的原生到期检测逻辑，所以只在 iOS 上补这一条。
        if (Platform.isIOS) {
          NotificationService.showExpiredNow();
        } else {
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

    ApiService.fetchInviteInfo().then((data) {
      if (data['code'] == 200 && data['data'] != null) {
        final count = data['data']['invited_count'] ?? 0;
        final uid = data['data']['uid']?.toString() ?? '';
        if (mounted) {
          setState(() {
            _inviteBtnText = count > 0 ? "邀请奖励 (已邀$count人)" : "免费领时长";
            if (uid.isNotEmpty) _uid = uid;
          });
        }
      }
    });

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
          _showToast("时长不足，请充值");
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
              Text(
                _cfgAnnouncement.isNotEmpty ? _cfgAnnouncement : "暂无公告",
                style: const TextStyle(
                  fontSize: 14,
                  color: Color(0xFF666666),
                  height: 1.6, 
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
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
      elevation: 0,
      isScrollControlled: true, 
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (sheetContext) {
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
                if (_nodeList.isEmpty)
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
                  onTap: _vpnState == VpnState.connected ||
                          _vpnState == VpnState.connecting
                      ? null
                      : _showNodePickerSheet,
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
                // 暂时在 iOS 下隐藏导出日志按钮
                if (!Platform.isIOS)
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
                  onTap: _showNoticeDialog,
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

  /// 页面最底部的UID标签：点击复制到剪贴板，方便找客服/人工充值时报号。
  /// _uid 在 fetchInviteInfo 成功后才会有值，没有值之前不占位置（不显示）。
  Widget _buildUidTag() {
    if (_uid.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: GestureDetector(
        onTap: () => _copyUid(),
        behavior: HitTestBehavior.opaque,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              "UID: $_uid",
              style: const TextStyle(fontSize: 12, color: Color(0xFF999999)),
            ),
            const SizedBox(width: 4),
            const Icon(Icons.copy_rounded, size: 12, color: Color(0xFF999999)),
          ],
        ),
      ),
    );
  }

  void _copyUid() {
    Clipboard.setData(ClipboardData(text: _uid));
    _showToast("UID已复制");
  }

  Widget _buildBottomArea() {
    // 暂时在 iOS 平台隐藏整个底部区域（包含免费领取时长）
    if (Platform.isIOS) {
      return const SizedBox.shrink();
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
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

          const SizedBox(height: 16),

          if (!Platform.isIOS)
            GestureDetector(
              onTap: _showRechargeDialog,
              behavior: HitTestBehavior.opaque,
              child: const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.key_outlined, size: 14, color: Color(0xFF999999)),
                    SizedBox(width: 6),
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