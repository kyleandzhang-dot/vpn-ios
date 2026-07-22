import 'dart:async';
import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import '../config/app_config.dart';
import '../models/recharge_tier.dart';
import '../services/api_service.dart';
import '../services/native_utils.dart';

enum _Stage { select, paying, success }

class RechargeScreen extends StatefulWidget {
  const RechargeScreen({super.key});

  @override
  State<RechargeScreen> createState() => _RechargeScreenState();
}

class _RechargeScreenState extends State<RechargeScreen> {
  _Stage _stage = _Stage.select;
  RechargeTier _selectedTier = kRechargeTiers[1];

  bool _creatingOrder = false;
  String? _currentOrderId;
  String? _currentPayUrl;
  Timer? _pollTimer;

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  Future<void> _createOrder() async {
    setState(() => _creatingOrder = true);

    final data = await ApiService.createPaymentOrder(productId: _selectedTier.productId);
    if (!mounted) return;
    setState(() => _creatingOrder = false);

    if (data['code'] == 200 && data['data'] != null) {
      setState(() {
        _currentOrderId = data['data']['order_id']?.toString();
        _currentPayUrl = data['data']['pay_url']?.toString();
        _stage = _Stage.paying;
      });
      _startPolling();
    } else {
      _showToast(data['msg']?.toString() ?? '创建订单失败');
    }
  }

  void _startPolling() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(seconds: 3), (_) => _checkOrderStatus());
  }

  void _stopPolling() {
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  Future<void> _checkOrderStatus() async {
    final orderId = _currentOrderId;
    if (orderId == null) return;
    try {
      final data = await ApiService.fetchPaymentStatus(orderId);
      if (!mounted) return;
      if (data['data']?['status'] == 'paid') {
        _stopPolling();
        setState(() => _stage = _Stage.success);
      }
    } catch (_) {
      // 忽略网络波动，继续轮询
    }
  }

  void _cancelPaying() {
    _stopPolling();
    setState(() {
      _currentOrderId = null;
      _currentPayUrl = null;
      _stage = _Stage.select;
    });
  }

  Future<void> _openWechatPay() async {
    final url = _currentPayUrl;
    if (url == null || url.isEmpty) return;
    final uri = Uri.tryParse(url);
    if (uri == null || !await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      _showToast('无法调起外部应用');
    }
  }

  Future<void> _saveQrToGallery() async {
    final url = _currentPayUrl;
    if (url == null || url.isEmpty) {
      _showToast('二维码尚未生成');
      return;
    }
    try {
      final painter = QrPainter(
        data: url,
        version: QrVersions.auto,
        gapless: true,
        color: const Color(0xFF000000),
        emptyColor: const Color(0xFFFFFFFF),
      );
      final imageData = await painter.toImageData(600);
      if (imageData == null) {
        _showToast('二维码生成失败');
        return;
      }
      final bytes = imageData.buffer.asUint8List();
      final ok = await NativeUtils.saveImageToGallery(bytes, 'WeChat_Pay_${DateTime.now().millisecondsSinceEpoch}.png');
      _showToast(ok ? '✓ 已保存至相册！请打开微信 -> 扫一扫 -> 选相册' : '保存失败，请检查系统相册权限');
    } catch (_) {
      _showToast('保存失败，请检查系统相册权限');
    }
  }

  void _showToast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg), duration: const Duration(seconds: 2)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF6F6F6),
      body: SafeArea(
        child: switch (_stage) {
          _Stage.select => _buildSelectPage(),
          _Stage.paying => _buildPayingPage(),
          _Stage.success => _buildSuccessPage(),
        },
      ),
    );
  }

  Widget _topBar(String title, VoidCallback onBack) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      child: Row(
        children: [
          IconButton(icon: const Icon(Icons.arrow_back_ios_new, size: 18, color: Colors.black), onPressed: onBack),
          Text(title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.black)),
        ],
      ),
    );
  }

  Widget _buildSelectPage() {
    return Column(
      children: [
        _topBar('喵脸会员', () => Navigator.pop(context)),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 10),
                const Text('选择会员方案', style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: Colors.black)),
                const SizedBox(height: 4),
                const Text('高速连接 · 全球节点 · 自动续期', style: TextStyle(fontSize: 13, color: Color(0xFF888888))),
                const SizedBox(height: 14),
                Expanded(
                  child: ListView.separated(
                    itemCount: kRechargeTiers.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 12),
                    itemBuilder: (context, index) => _buildTierCard(kRechargeTiers[index]),
                  ),
                ),
                const SizedBox(height: 10),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: _creatingOrder ? null : _createOrder,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.black,
                      padding: const EdgeInsets.symmetric(vertical: 15),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
                    ),
                    child: Text(
                      _creatingOrder ? '正在创建订单...' : '立即开通',
                      style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold, color: Colors.white),
                    ),
                  ),
                ),
                const SizedBox(height: 24),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildTierCard(RechargeTier tier) {
    final selected = tier.productId == _selectedTier.productId;
    return GestureDetector(
      onTap: () => setState(() => _selectedTier = tier),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: selected ? Colors.black : const Color(0xFFE5E5E5), width: selected ? 2 : 1),
          boxShadow: selected ? [const BoxShadow(color: Color(0x22000000), blurRadius: 6, offset: Offset(0, 3))] : [],
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(tier.name, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold, color: Colors.black)),
                  const SizedBox(height: 4),
                  Text('${tier.days} 天有效期', style: const TextStyle(fontSize: 12, color: Color(0xFF888888))),
                  if (tier.badge.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(color: Colors.black, borderRadius: BorderRadius.circular(999)),
                      child: Text(tier.badge, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.white)),
                    ),
                  ],
                ],
              ),
            ),
            Text('¥${tier.price}', style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: Colors.black)),
          ],
        ),
      ),
    );
  }

  Widget _buildPayingPage() {
    return Column(
      children: [
        _topBar('微信支付', _cancelPaying),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 28),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  '${_selectedTier.name}  ¥${_selectedTier.price}',
                  style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Colors.black),
                ),
                const SizedBox(height: 20),
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: const Color(0xFFE5E5E5)),
                  ),
                  child: _currentPayUrl != null
                      ? QrImageView(data: _currentPayUrl!, size: 190, version: QrVersions.auto)
                      : const SizedBox(width: 190, height: 190),
                ),
                const SizedBox(height: 16),
                const Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                    SizedBox(width: 8),
                    Text('等待支付确认', style: TextStyle(fontSize: 14, color: Color(0xFF888888))),
                  ],
                ),
                const SizedBox(height: 28),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton(
                    onPressed: _saveQrToGallery,
                    style: OutlinedButton.styleFrom(
                      side: const BorderSide(color: Colors.black),
                      padding: const EdgeInsets.symmetric(vertical: 13),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
                    ),
                    child: const Text('保存二维码至相册', style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: Colors.black)),
                  ),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: _openWechatPay,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.black,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
                    ),
                    child: const Text('打开微信完成支付', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white)),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildSuccessPage() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 40),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 72,
            height: 72,
            decoration: const BoxDecoration(color: Colors.black, shape: BoxShape.circle),
            alignment: Alignment.center,
            child: const Text('✓', style: TextStyle(fontSize: 36, fontWeight: FontWeight.bold, color: Colors.white)),
          ),
          const SizedBox(height: 20),
          const Text('充值成功', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Colors.black)),
          const SizedBox(height: 8),
          Text('会员有效期增加 ${_selectedTier.days} 天', style: const TextStyle(fontSize: 14, color: Color(0xFF888888))),
          const SizedBox(height: 32),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: () => Navigator.pop(context, true),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.black,
                padding: const EdgeInsets.symmetric(vertical: 15),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
              ),
              child: const Text('开始使用', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white)),
            ),
          ),
        ],
      ),
    );
  }
}