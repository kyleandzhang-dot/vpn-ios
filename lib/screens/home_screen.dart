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

  String _statusText = "未连接";
  String _statusType = "neutral";
  String _expireText = "";
  String _inviteBtnText = "获取免费时长";
  
  String _cfgBuyQQ = "1772757914";
  String _cfgAnnouncement = "";
  String _cfgAnnouncementTitle = "公告";
  bool _showNoticeDot = false;

  bool _checkedInToday = false;
  bool _isCheckinLoading = false;
  int _checkinStreak = 0;
  int _checkinRewardMinutes = 20;

  bool _isDialogActive = false;
  String? _pendingNodeJson;

  // “连接中”状态的兜底超时：如果一直等不到 native 侧的 CONNECTED/DISCONNECTED
  // 广播，15 秒后自动复位，避免转圈圈卡死、点了没反应。
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
      // 只要 native 侧真的给了一个状态回应（不管是连上了还是断了），
      // 说明这次连接流程有了结果，超时兜底就不需要了。
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
      VpnBridge.disconnect(); // 顺手清一下 native 侧可能残留的状态
      setState(() {
        _vpnState = VpnState.disconnected;
        _statusText = "连接超时";
        _statusType = "error";
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
        _statusText = "未连接";
        _statusType = "neutral";
        _ringAnimController.stop();
        break;
      case VpnState.connecting:
        _statusText = "正在连接...";
        _statusType = "neutral";
        _ringAnimController.repeat();
        break;
      case VpnState.connected:
        _statusText = "安全连接已建立";
        _statusType = "success";
        _ringAnimController.stop();
        break;
      case VpnState.expired:
        _statusText = "服务已过期";
        _statusType = "error";
        _ringAnimController.stop();
        _showToast("时长不足，请充值");
        _openRechargePage();
        break;
    }
  }

  Future<void> _initData() async {
    ApiService.fetchConfig().then((data) {
      if (data.isNotEmpty && data['data'] != null) {
        final cfg = data['data'];
        setState(() {
          _cfgBuyQQ = cfg['buy_qq'] ?? _cfgBuyQQ;
          _cfgAnnouncement = cfg['announcement'] ?? "";
          _cfgAnnouncementTitle = cfg['announcement_title'] ?? "公告";
        });
        _checkAnnouncement();
      }
    });

    ApiService.fetchInviteInfo().then((data) {
      if (data['code'] == 200 && data['data'] != null) {
        final count = data['data']['invited_count'] ?? 0;
        setState(() {
          _inviteBtnText = count > 0 ? "获取免费时长 (已邀 $count 人)" : "获取免费时长";
        });
      }
    });

    ApiService.fetchCheckinStatus().then((data) {
      if (data['code'] == 200 && data['data'] != null) {
        setState(() {
          _checkedInToday = data['data']['checked_today'] ?? false;
          _checkinStreak = data['data']['streak_days'] ?? 0;
          _checkinRewardMinutes = data['data']['reward_minutes'] ?? 20;
        });
      }
    });
  }

  Future<void> _checkAnnouncement() async {
    if (_cfgAnnouncement.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    final hash = (_cfgAnnouncementTitle + _cfgAnnouncement).hashCode.toString();
    final lastHash = prefs.getString('last_read_announcement_hash');

    if (hash != lastHash) {
      setState(() => _showNoticeDot = true);
      _showNoticeDialog();
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
      _statusText = "正在获取节点...";
      _statusType = "neutral";
      _ringAnimController.repeat();
    });
    _startConnectTimeout();

    try {
      final res = await ApiService.getNode();
      if (res.statusCode == 200) {
        final jsonBody = json.decode(res.body);
        if (jsonBody['code'] == 200) {
          final data = jsonBody['data'];
          _pendingNodeJson = json.encode(data['node']);
          setState(() {
            _expireText = "有效期至: ${data['expire_time']}";
          });
          await VpnBridge.connect(_pendingNodeJson!);
        } else if (jsonBody['code'] == 403) {
          _cancelConnectTimeout();
          setState(() {
            _vpnState = VpnState.disconnected;
            _updateUIByState(_vpnState);
          });
          _showToast("时长不足，请充值");
          _openRechargePage();
        } else {
          _cancelConnectTimeout();
          _showToast(jsonBody['msg'] ?? "连接失败");
          setState(() {
            _vpnState = VpnState.disconnected;
            _statusText = "连接失败";
            _statusType = "error";
            _ringAnimController.stop();
          });
        }
      }
    } catch (e) {
      _cancelConnectTimeout();
      setState(() {
        _vpnState = VpnState.disconnected;
        _statusText = "网络异常";
        _statusType = "error";
        _ringAnimController.stop();
      });
    }
  }

  void _showToast(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 2))
    );
  }

  // ================= 业务交互弹窗 =================

  void _showNoticeDialog() {
    showDialog(
      context: context,
      builder: (_) => Dialog(
        backgroundColor: Colors.white, 
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8), 
          side: const BorderSide(color: Color(0xFFEEEEEE), width: 1), 
        ),
        child: Padding(
          padding: const EdgeInsets.all(28.0), 
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _cfgAnnouncementTitle,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w600, 
                  color: Colors.black87,
                  letterSpacing: 1.2, 
                ),
              ),
              const SizedBox(height: 20),
              Text(
                _cfgAnnouncement,
                style: const TextStyle(
                  fontSize: 14,
                  color: Colors.black54,
                  height: 1.8, 
                ),
              ),
              const SizedBox(height: 36),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.black87, 
                    side: const BorderSide(color: Colors.black87, width: 1), 
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(4), 
                    ),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                  onPressed: () {
                    Navigator.pop(context);
                    _markAnnouncementRead();
                  },
                  child: const Text(
                    "我知道了",
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1.5,
                    ),
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
        backgroundColor: AppConfig.colorBg,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(22),
        ),
        child: Padding(
          padding: const EdgeInsets.all(22),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                "卡密激活",
                style: TextStyle(fontSize:20,fontWeight:FontWeight.bold),
              ),
              const SizedBox(height:8),
              const Text(
                "输入激活码，立即恢复服务时间",
                style:TextStyle(
                  fontSize:12,
                  color:AppConfig.colorTextSub,
                ),
              ),
              const SizedBox(height:20),
              TextField(
                controller: controller,
                decoration: InputDecoration(
                  hintText:"请输入激活码",
                  filled:true,
                  fillColor:AppConfig.colorBtnBg,
                  border:OutlineInputBorder(
                    borderRadius:BorderRadius.circular(14),
                    borderSide:BorderSide.none,
                  ),
                ),
              ),
              const SizedBox(height:16),
              SizedBox(
                width:double.infinity,
                child:ElevatedButton(
                  style:ElevatedButton.styleFrom(
                    backgroundColor:AppConfig.colorPrimary,
                    foregroundColor:Colors.white,
                    shape:RoundedRectangleBorder(
                      borderRadius:BorderRadius.circular(14),
                    ),
                  ),
                  onPressed:() async {
                    final code=controller.text.trim();
                    if(code.isEmpty){
                      _showToast("请输入激活码");
                      return;
                    }
                    Navigator.pop(context);
                    _showToast("正在验证...");
                    final res=await ApiService.recharge(code);
                    if(res['code']==200){
                      setState(()=>_expireText="有效期至: ${res['data']['new_expire_time']}");
                    }
                    _showToast(res['msg']??"处理完成");
                  },
                  child:const Text("立即激活"),
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

  // ================= 页面视图构建 =================

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Stack(
          children: [
            Column(
              children: [
                _buildTopBar(),
                Expanded(child: _buildCenterBody()),
                _buildBottomArea(),
              ],
            ),
            if (!Platform.isIOS)
              _buildFloatingCheckinButton(),
          ],
        ),
      ),
    );
  }

  Widget _buildTopBar() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
      child: Row(
        children: [
          const Expanded(
            child: Text(AppConfig.appName, style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: AppConfig.colorPrimary)),
          ),
          if (_cfgAnnouncement.isNotEmpty)
            GestureDetector(
              onTap: _showNoticeDialog,
              child: Container(
                margin: const EdgeInsets.only(right: 8),
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(color: AppConfig.colorBtnBg, shape: BoxShape.circle, border: Border.all(color: AppConfig.colorBorder)),
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    const Icon(Icons.notifications_none, size: 20, color: AppConfig.colorPrimary),
                    if (_showNoticeDot)
                      Positioned(
                        right: -2, top: -2,
                        child: Container(width: 8, height: 8, decoration: const BoxDecoration(color: AppConfig.colorAlert, shape: BoxShape.circle)),
                      )
                  ],
                ),
              ),
            ),
          if (!Platform.isIOS)
            GestureDetector(
              onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const MarketScreen())),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                decoration: BoxDecoration(color: AppConfig.colorBtnBg, borderRadius: BorderRadius.circular(999), border: Border.all(color: AppConfig.colorBorder)),
                child: const Text("海外应用", style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: AppConfig.colorPrimary)),
              ),
            )
        ],
      ),
    );
  }

  Widget _buildCenterBody() {
    final isConnected = _vpnState == VpnState.connected;
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        SizedBox(
          width: 184, height: 184,
          child: Stack(
            alignment: Alignment.center,
            children: [
              if (_vpnState == VpnState.connecting)
                AnimatedBuilder(
                  animation: _ringAnimController,
                  builder: (_, __) => Transform.rotate(
                    angle: _ringAnimController.value * 2 * pi,
                    child: CustomPaint(size: const Size(184, 184), painter: SpinningRingPainter()),
                  ),
                ),
              GestureDetector(
                onTap: _toggleConnect,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  width: 164, height: 164,
                  decoration: BoxDecoration(
                    color: isConnected ? AppConfig.colorBg : AppConfig.colorPrimary,
                    shape: BoxShape.circle,
                    border: isConnected ? Border.all(color: AppConfig.colorPrimary, width: 2) : null,
                    boxShadow: isConnected ? [] : [BoxShadow(color: Colors.black.withOpacity(0.15), blurRadius: 12, offset: const Offset(0, 6))],
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      CustomPaint(
                        size: const Size(34, 34),
                        painter: PowerIconPainter(color: isConnected ? AppConfig.colorPrimary : AppConfig.colorBg),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        isConnected ? "已连接" : (_vpnState == VpnState.connecting ? "连接中" : "点击连接"),
                        style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: isConnected ? AppConfig.colorPrimary : AppConfig.colorBg),
                      )
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 28),
        if (_statusType == "error") ...[
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            decoration: BoxDecoration(
              color: AppConfig.colorBtnBg,
              borderRadius: BorderRadius.circular(999),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 6, height: 6,
                  decoration: const BoxDecoration(color: AppConfig.colorTextSub, shape: BoxShape.circle),
                ),
                const SizedBox(width: 8),
                Text(_statusText, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
              ],
            ),
          ),
          const SizedBox(height: 18),
        ],
        GestureDetector(
          onTap: _openRechargePage,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
            decoration: BoxDecoration(color: AppConfig.colorPrimary, borderRadius: BorderRadius.circular(999)),
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.bolt, size: 16, color: Colors.white),
                SizedBox(width: 6),
                Text("立即充值", style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Colors.white)),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        if (_expireText.isNotEmpty)
          Text(_expireText, style: const TextStyle(fontSize: 12, color: AppConfig.colorTextSub)),
      ],
    );
  }

  // ================= 极简胶囊签到按钮 =================
  Widget _buildFloatingCheckinButton() {
    final Color primaryColor = AppConfig.colorPrimary;
    final Color textColorOnDisable = primaryColor.withOpacity(0.6);

    return Positioned(
      right: 16,
      top: 100,
      child: GestureDetector(
        onTap: _handleCheckin,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeInOut,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(999),
            gradient: _checkedInToday
                ? null
                : LinearGradient(
                    colors: [primaryColor.withOpacity(0.85), primaryColor],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
            color: _checkedInToday ? AppConfig.colorBtnBg : null,
            border: _checkedInToday ? Border.all(color: AppConfig.colorBorder) : null,
            boxShadow: _checkedInToday
                ? []
                : [
                    BoxShadow(
                      color: primaryColor.withOpacity(0.3),
                      blurRadius: 8,
                      offset: const Offset(0, 4),
                    ),
                  ],
          ),
          child: _isCheckinLoading
              ? SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor: AlwaysStoppedAnimation<Color>(
                        _checkedInToday ? primaryColor : Colors.white),
                  ),
                )
              : Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      _checkedInToday
                          ? Icons.check_circle_outline
                          : Icons.card_giftcard,
                      size: 16,
                      color: _checkedInToday ? textColorOnDisable : Colors.white,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      _checkedInToday ? "已签到" : "签到",
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: _checkedInToday ? textColorOnDisable : Colors.white,
                      ),
                    ),
                  ],
                ),
        ),
      ),
    );
  }

  Widget _buildBottomArea() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
      child: Column(
        children: [
          GestureDetector(
            onTap: _showRechargeDialog,
            child: const Padding(
              padding: EdgeInsets.symmetric(vertical: 10),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text("持有激活码？点击立即兑换", style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: AppConfig.colorTextSub)),
                  Icon(Icons.keyboard_arrow_right, size: 16, color: AppConfig.colorTextMute)
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          GestureDetector(
            onTap: () {
              Navigator.push(
                context, 
                MaterialPageRoute(builder: (_) => const InviteScreen()),
              ).then((_) {
                _initData(); 
              });
            },
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 16),
              decoration: BoxDecoration(
                color: AppConfig.colorPrimary,
                borderRadius: BorderRadius.circular(999),
                boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.15), blurRadius: 8, offset: const Offset(0, 4))]
              ),
              alignment: Alignment.center,
              child: Text(_inviteBtnText, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: Colors.white)),
            ),
          ),
          const SizedBox(height: 16),
          const Text("设备安全守护中 • V1.0.0", style: TextStyle(fontSize: 11, color: AppConfig.colorTextMute))
        ],
      ),
    );
  }
}