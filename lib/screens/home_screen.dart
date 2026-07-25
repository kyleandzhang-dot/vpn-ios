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

  // 【减法】：删除了 _statusText 和 _statusType，只保留核心到期时间
  String _expireText = "";
  String _inviteBtnText = "免费领时长";
  
  String _cfgBuyQQ = "1772757914";
  String _cfgAnnouncement = "";
  String _cfgAnnouncementTitle = "公告";
  bool _showNoticeDot = false;

  bool _checkedInToday = false;
  bool _isCheckinLoading = false;
  bool _isCheckinDialogSubmitting = false; 
  int _checkinStreak = 0;
  int _checkinRewardMinutes = 20;
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
        _openRechargePage();
        break;
    }
  }

  Future<void> _initData() async {
    ApiService.fetchInviteInfo().then((data) {
      if (data['code'] == 200 && data['data'] != null) {
        final count = data['data']['invited_count'] ?? 0;
        if (mounted) {
          setState(() {
            _inviteBtnText = count > 0 ? "邀请奖励 (已邀$count人)" : "免费领时长";
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
        _checkinRewardMinutes = checkinData['data']['reward_minutes'] ?? 20;
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
          setState(() {
            _expireText = "有效期至: ${data['expire_time']}";
          });
        } else if (jsonBody['code'] == 403) {
          _cancelConnectTimeout();
          setState(() {
            _vpnState = VpnState.disconnected;
            _updateUIByState(_vpnState);
          });
          _showToast("时长不足，请充值");
          _openRechargePage();
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
      await VpnBridge.connect(_pendingNodeJson!);
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

  // ================= 业务交互弹窗 =================

  // 【新增】Bug 反馈与诊断日志分享弹窗
  void _showBugShareDialog() {
    final logText = "【App诊断日志 / Bug反馈】\n"
        "应用名称: ${AppConfig.appName}\n"
        "当前状态: $_vpnState\n"
        "当前节点: $_selectedNodeLabel ($_selectedNodeId)\n"
        "服务时间: ${_expireText.isNotEmpty ? _expireText : '未获取'}\n"
        "连续签到: $_checkinStreak 天\n"
        "联系客服QQ: $_cfgBuyQQ\n"
        "系统平台: ${Platform.operatingSystem} (${Platform.operatingSystemVersion})";

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
              const Row(
                children: [
                  Icon(Icons.bug_report_rounded, size: 22, color: Color(0xFFFF4D4F)),
                  SizedBox(width: 8),
                  Text(
                    "Bug 反馈与日志分享",
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: Colors.black87),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              const Text(
                "遇到连接问题或应用异常？您可以一键复制当前运行的诊断日志并分享给开发者或客服，帮您快速定位排查：",
                style: TextStyle(fontSize: 13, color: Color(0xFF666666), height: 1.5),
              ),
              const SizedBox(height: 16),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: const Color(0xFFF7F8FA),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Text(
                  logText,
                  style: const TextStyle(fontSize: 12, color: Color(0xFF444444), height: 1.5, fontFamily: 'monospace'),
                ),
              ),
              const SizedBox(height: 24),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: const Color(0xFF666666),
                        side: const BorderSide(color: Color(0xFFDDDDDD)),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                        padding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                      onPressed: () => Navigator.pop(context),
                      child: const Text("关闭", style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppConfig.colorPrimary,
                        foregroundColor: Colors.white,
                        elevation: 0,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                        padding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                      onPressed: () {
                        Clipboard.setData(ClipboardData(text: logText));
                        Navigator.pop(context);
                        _showToast("诊断日志已复制，请粘贴分享给客服/测试群");
                      },
                      child: const Text("复制并分享", style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
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
                      setState(() => _expireText = "有效期至: ${res['data']['new_expire_time']}");
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
          _expireText = "有效期至: ${res['data']['new_expire_time']}";
        });
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
                const Text("选择线路节点", style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: Colors.black87)),
                const SizedBox(height: 6),
                const Text("未连接状态下切换线路即可生效", style: TextStyle(fontSize: 12, color: Color(0xFF888888))),
                const SizedBox(height: 20),
                _buildNodeOptionTile(
                  label: "自动选线",
                  subtitle: "智能推荐当前延迟最低的节点",
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
                      subtitle: "当前负载 ${node['load'] ?? 0}%",
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
                  const SizedBox(height: 4),
                  Text(subtitle, style: const TextStyle(fontSize: 12, color: Color(0xFF888888))),
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
          ],
        ),
      ),
    );
  }

  Widget _buildTopBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 8),
      child: Row(
        children: [
          const Expanded(
            child: Text(
              AppConfig.appName, 
              style: TextStyle(
                fontSize: 22, 
                fontWeight: FontWeight.w800, 
                color: Colors.black87, 
                letterSpacing: -0.5
              )
            ),
          ),
          // 【新增】Bug 反馈与日志分享按钮
          GestureDetector(
            onTap: _showBugShareDialog,
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
    );
  }

  Widget _buildCenterBody() {
    final isConnected = _vpnState == VpnState.connected;
    final canPickNode = _vpnState != VpnState.connected && _vpnState != VpnState.connecting;

    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        // 1. 顶部节点切换
        GestureDetector(
          onTap: _showNodePickerSheet,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 9),
            decoration: BoxDecoration(
              color: const Color(0xFFF2F3F5),
              borderRadius: BorderRadius.circular(999),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _selectedNodeLabel,
                  style: TextStyle(
                    fontSize: 13, 
                    fontWeight: FontWeight.w600, 
                    color: canPickNode ? Colors.black87 : const Color(0xFF999999)
                  ),
                ),
                const SizedBox(width: 4),
                Icon(
                  Icons.keyboard_arrow_down_rounded, 
                  size: 16, 
                  color: canPickNode ? Colors.black87 : const Color(0xFF999999)
                ),
              ],
            ),
          ),
        ),

        const SizedBox(height: 48),

        // 2. 核心大环形连接按钮
        SizedBox(
          width: 210, height: 210,
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
                  width: 176, height: 176,
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

        const SizedBox(height: 48),

        // 3. 【减法优化】：纯到期时间标签，删除了连接状态和圆点
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
          decoration: BoxDecoration(
            color: const Color(0xFFF7F8FA),
            borderRadius: BorderRadius.circular(999),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.access_time_rounded, size: 15, color: Color(0xFF888888)),
              const SizedBox(width: 6),
              Text(
                _expireText.isNotEmpty 
                    ? _expireText.replaceFirst("有效期至: ", "服务到期: ") 
                    : "点击连接获取服务时长",
                style: const TextStyle(
                  fontSize: 13, 
                  fontWeight: FontWeight.w500, 
                  color: Color(0xFF666666)
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildBottomArea() {
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
                      color: AppConfig.colorPrimary.withOpacity(0.08),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      _inviteBtnText, 
                      style: TextStyle(
                        fontSize: 14, 
                        fontWeight: FontWeight.w600, 
                        color: AppConfig.colorPrimary,
                        letterSpacing: 0.3,
                      ),
                      maxLines: 1, 
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              ),
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
                        letterSpacing: 0.5, 
                      )
                    ),
                  ),
                ),
              ),
            ],
          ),

          const SizedBox(height: 16),

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
    );//
  }
}