import 'dart:math';
import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../config/app_config.dart';
import '../models/agent_tier.dart';
import '../services/api_service.dart';
import '../services/vpn_bridge.dart';
import '../widgets/power_ring_view.dart';
import 'recharge_screen.dart';
import 'market_screen.dart';

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
  String _cfgAgentQQ = "1772757914";
  String _cfgAnnouncement = "";
  String _cfgAnnouncementTitle = "公告";
  bool _showNoticeDot = false;

  bool _isDialogActive = false;
  String? _pendingNodeJson;

  @override
  void initState() {
    super.initState();
    _ringAnimController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 1),
    );

    _vpnSubscription = VpnBridge.statusStream.listen((state) {
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
    super.dispose();
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
          _cfgAgentQQ = cfg['agent_qq'] ?? _cfgAgentQQ;
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
    } else {
      setState(() {
        _vpnState = VpnState.connecting;
        _statusText = "正在获取节点...";
        _statusType = "neutral";
        _ringAnimController.repeat();
      });

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
            setState(() {
              _vpnState = VpnState.disconnected;
              _updateUIByState(_vpnState);
            });
            _openRechargePage();
          } else {
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
        setState(() {
          _vpnState = VpnState.disconnected;
          _statusText = "网络异常";
          _statusType = "error";
          _ringAnimController.stop();
        });
      }
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
      builder: (_) => AlertDialog(
        title: Text(_cfgAnnouncementTitle, style: const TextStyle(fontWeight: FontWeight.bold)),
        content: Text(_cfgAnnouncement),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              _markAnnouncementRead();
            },
            child: const Text("知道了", style: TextStyle(color: AppConfig.colorPrimary)),
          )
        ],
      )
    );
  }

  void _showRechargeDialog() {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text("卡密激活中心", style: TextStyle(fontWeight: FontWeight.bold)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: controller,
              decoration: InputDecoration(
                hintText: "请输入或粘贴您的激活码",
                filled: true,
                fillColor: AppConfig.colorBtnBg,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide.none),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text("取消", style: TextStyle(color: AppConfig.colorTextSub))),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: AppConfig.colorPrimary, foregroundColor: Colors.white),
            onPressed: () async {
              final code = controller.text.trim();
              if (code.isEmpty) {
                _showToast("激活码不能为空");
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
            child: const Text("立即激活"),
          )
        ],
      )
    );
  }

  void _showAgentDialog() {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text("赚钱计划", style: TextStyle(fontWeight: FontWeight.bold)),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text("成为推广合伙人\n分享喵脸，获得长期收益", style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              const SizedBox(height: 16),
              const Text("代理价格表", style: TextStyle(fontWeight: FontWeight.bold, color: AppConfig.colorPrimary)),
              const SizedBox(height: 8),
              ...kAgentTiers.map((tier) => Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text("${tier.name} · 售价 ¥${tier.price} · 拿货价 ¥${tier.wholesale} · 利润 ¥${tier.commission}", style: const TextStyle(color: AppConfig.colorTextSub, fontSize: 13)),
              )),
              const SizedBox(height: 16),
              const Text("单次拿货满 5 张即可申请结算佣金。", style: TextStyle(color: AppConfig.colorTextMute, fontSize: 11)),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text("关闭", style: TextStyle(color: AppConfig.colorTextSub))),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: AppConfig.colorPrimary, foregroundColor: Colors.white),
            onPressed: () {
              Navigator.pop(context);
              _showAgentContactDialog();
            },
            child: const Text("申请"),
          )
        ],
      )
    );
  }

  void _showAgentContactDialog() {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text("联系客服", style: TextStyle(fontWeight: FontWeight.bold)),
        content: Text("请添加 QQ：$_cfgAgentQQ 验证申请并开通权限。"),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text("关闭", style: TextStyle(color: AppConfig.colorTextSub))),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: AppConfig.colorPrimary, foregroundColor: Colors.white),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: _cfgAgentQQ));
              _showToast("QQ 已复制");
              Navigator.pop(context);
            },
            child: const Text("复制 QQ"),
          )
        ],
      )
    );
  }

  void _showInviteDialog() async {
    if (_isDialogActive) return;
    _isDialogActive = true;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (dialogCtx) => FutureBuilder<Map<String, dynamic>>(
        future: ApiService.fetchInviteInfo(),
        builder: (ctx, snapshot) {
          if (!snapshot.hasData) {
            return const AlertDialog(
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(color: AppConfig.colorPrimary),
                  SizedBox(height: 16),
                  Text("正在生成您的专属邀请卡...", style: TextStyle(color: AppConfig.colorTextSub)),
                ],
              ),
            );
          }

          final data = snapshot.data!;
          if (data['code'] != 200 || data['data'] == null) {
            Navigator.pop(dialogCtx);
            _showToast(data['msg'] ?? "获取失败");
            return const SizedBox();
          }

          final inviteData = data['data'];
          final myCode = inviteData['invite_code'] ?? "";
          final count = inviteData['invited_count'] ?? 0;
          final bindController = TextEditingController();

          return AlertDialog(
            title: Text("已成功邀请 $count 人", style: const TextStyle(fontWeight: FontWeight.bold)),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text("分享邀请码给好友，获取无限免费时长。", style: TextStyle(color: AppConfig.colorTextSub, fontSize: 12)),
                  const SizedBox(height: 16),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    decoration: BoxDecoration(color: AppConfig.colorBtnBg, borderRadius: BorderRadius.circular(12), border: Border.all(color: AppConfig.colorBorder)),
                    child: Column(
                      children: [
                        const Text("专属邀请码", style: TextStyle(color: AppConfig.colorTextMute, fontSize: 11)),
                        const SizedBox(height: 4),
                        Text(myCode, style: const TextStyle(fontSize: 28, fontWeight: FontWeight.bold, color: AppConfig.colorPrimary)),
                        const SizedBox(height: 12),
                        ElevatedButton(
                          style: ElevatedButton.styleFrom(backgroundColor: AppConfig.colorPrimary, foregroundColor: Colors.white, shape: const StadiumBorder()),
                          onPressed: () {
                            Clipboard.setData(ClipboardData(text: myCode));
                            _showToast("邀请码已复制");
                          },
                          child: const Text("复制邀请码"),
                        )
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  const Text("绑定好友邀请码", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: bindController,
                          decoration: InputDecoration(
                            hintText: "输入邀请码",
                            filled: true,
                            fillColor: AppConfig.colorBg,
                            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: AppConfig.colorBorder)),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      ElevatedButton(
                        style: ElevatedButton.styleFrom(backgroundColor: AppConfig.colorBtnBg, foregroundColor: AppConfig.colorTextMain, elevation: 0),
                        onPressed: () async {
                          final code = bindController.text.trim();
                          if (code.isNotEmpty) {
                            final res = await ApiService.bindInviteCode(code);
                            _showToast(res['msg'] ?? "操作完成");
                            Navigator.pop(dialogCtx);
                            _initData();
                          } else {
                            _showToast("请输入邀请码");
                          }
                        },
                        child: const Text("确认"),
                      )
                    ],
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(dialogCtx), child: const Text("关闭", style: TextStyle(color: AppConfig.colorTextSub)))
            ],
          );
        },
      )
    ).then((_) => _isDialogActive = false);
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
            _buildFloatingAgentButton(),
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
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          decoration: BoxDecoration(
            color: _statusType == "success" ? AppConfig.colorBg : AppConfig.colorBtnBg,
            borderRadius: BorderRadius.circular(999),
            border: _statusType == "success" ? Border.all(color: AppConfig.colorBorder) : null,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 6, height: 6,
                decoration: BoxDecoration(
                  color: _statusType == "success" ? AppConfig.colorPrimary : (_statusType == "error" ? AppConfig.colorTextSub : AppConfig.colorTextMute),
                  shape: BoxShape.circle
                ),
              ),
              const SizedBox(width: 8),
              Text(_statusText, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
            ],
          ),
        ),
        const SizedBox(height: 18),
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

  Widget _buildFloatingAgentButton() {
    return Positioned(
      right: 12, top: 120,
      child: GestureDetector(
        onTap: _showAgentDialog,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 14),
          decoration: BoxDecoration(
            color: AppConfig.colorPrimary,
            borderRadius: BorderRadius.circular(16),
            boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.2), blurRadius: 8, offset: const Offset(0, 4))]
          ),
          child: const Column(
            children: [
              Text("代理", style: TextStyle(fontSize: 10, color: Color(0xFFCCCCCC))),
              SizedBox(height: 2),
              Text("赚\n钱", textAlign: TextAlign.center, style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Colors.white, height: 1.1)),
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
            onTap: _showInviteDialog,
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