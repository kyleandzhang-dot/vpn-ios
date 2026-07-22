import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../config/app_config.dart';
import '../services/api_service.dart';

class InviteScreen extends StatefulWidget {
  const InviteScreen({super.key});

  @override
  State<InviteScreen> createState() => _InviteScreenState();
}

class _InviteScreenState extends State<InviteScreen> {
  int _invitedCount = 0;
  String _inviteCode = "加载中...";
  bool _isLoading = true;
  bool _isBinding = false; // 绑定请求进行中，用于禁用按钮防止重复点击
  
  final TextEditingController _bindController = TextEditingController();
  final List<int> _nodes = [1, 3, 5, 10];
  final List<String> _rewards = ['+2天', '+3天', '+7天', '+18天'];

  @override
  void initState() {
    super.initState();
    _fetchInviteData();
  }

  Future<void> _fetchInviteData() async {
    try {
      final data = await ApiService.fetchInviteInfo();
      if (mounted) {
        setState(() {
          if (data['code'] == 200 && data['data'] != null) {
            _invitedCount = data['data']['invited_count'] ?? 0;
            _inviteCode = data['data']['invite_code'] ?? "";
          } else {
            _inviteCode = "获取失败";
          }
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _inviteCode = "网络错误";
          _isLoading = false;
        });
      }
    }
  }

  int _getNextTarget() {
    for (int n in _nodes) {
      if (_invitedCount < n) return n;
    }
    return -1;
  }

  void _showToast(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
    );
  }

  @override
  void dispose() {
    _bindController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppConfig.colorBg,
      appBar: AppBar(
        backgroundColor: AppConfig.colorBg,
        elevation: 0,
        scrolledUnderElevation: 0,
        iconTheme: const IconThemeData(color: AppConfig.colorPrimary),
        title: const Text(
          "邀请计划",
          style: TextStyle(
            color: AppConfig.colorPrimary,
            fontSize: 16,
            fontWeight: FontWeight.bold,
          ),
        ),
        centerTitle: true,
      ),
      body: _isLoading 
          ? const Center(
              child: CircularProgressIndicator(
                color: AppConfig.colorPrimary,
                strokeWidth: 2,
              ),
            )
          : SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildHeader(),
                  const SizedBox(height: 32),
                  _buildProgressSection(),
                  const SizedBox(height: 48),
                  _buildInviteCodeSection(),
                  const SizedBox(height: 32),
                  _buildBindSection(),
                ],
              ),
            ),
    );
  }

  Widget _buildHeader() {
    return const Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          "邀请好友，获得额外免费时长",
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.bold,
            color: AppConfig.colorPrimary,
          ),
        ),
      ],
    );
  }

  Widget _buildProgressSection() {
    int nextTarget = _getNextTarget();
    String nextStatus = nextTarget != -1 
        ? "还差 ${nextTarget - _invitedCount} 位好友" 
        : "已解锁全部奖励";

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppConfig.colorBg,
        border: Border.all(color: AppConfig.colorBorder),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text("当前进度", style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
              Text(
                "$_invitedCount / 10 人",
                style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: AppConfig.colorPrimary),
              ),
            ],
          ),
          const SizedBox(height: 24),
          _buildStepIndicator(),
          const SizedBox(height: 32),
          const Text("距离下一奖励", style: TextStyle(fontSize: 12, color: AppConfig.colorTextSub)),
          const SizedBox(height: 4),
          Text(
            nextStatus,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: AppConfig.colorPrimary),
          ),
        ],
      ),
    );
  }

  Widget _buildStepIndicator() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: List.generate(_nodes.length, (index) {
        final nodeCount = _nodes[index];
        final isReached = _invitedCount >= nodeCount;
        final isLast = index == _nodes.length - 1;
        final isNextReached = !isLast && _invitedCount >= _nodes[index + 1];

        return Expanded(
          flex: isLast ? 0 : 1,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 节点圆圈与文字
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 14,
                    height: 14,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: isReached ? AppConfig.colorPrimary : AppConfig.colorBg,
                      border: Border.all(
                        color: isReached ? AppConfig.colorPrimary : AppConfig.colorBorder,
                        width: 1.5,
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '${nodeCount}人',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: isReached ? FontWeight.bold : FontWeight.normal,
                      color: isReached ? AppConfig.colorPrimary : AppConfig.colorTextSub,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    _rewards[index],
                    style: TextStyle(
                      fontSize: 11,
                      color: isReached ? AppConfig.colorPrimary.withOpacity(0.8) : AppConfig.colorTextMute,
                    ),
                  ),
                ],
              ),
              // 连接线 (除了最后一个节点)
              if (!isLast)
                Expanded(
                  child: Container(
                    margin: const EdgeInsets.only(top: 6, left: 4, right: 4),
                    height: 1.5, // 细线条，避免突兀
                    color: isNextReached ? AppConfig.colorPrimary : AppConfig.colorBorder,
                  ),
                ),
            ],
          ),
        );
      }),
    );
  }

  Widget _buildInviteCodeSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text("邀请码", style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
        const SizedBox(height: 12),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 20),
          decoration: BoxDecoration(
            color: AppConfig.colorBtnBg,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppConfig.colorBorder),
          ),
          child: Column(
            children: [
              Text(
                _inviteCode,
                style: const TextStyle(
                  fontSize: 32,
                  letterSpacing: 2,
                  fontWeight: FontWeight.bold,
                  color: AppConfig.colorPrimary,
                ),
              ),
              const SizedBox(height: 16),
              OutlinedButton(
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppConfig.colorPrimary,
                  side: const BorderSide(color: AppConfig.colorPrimary),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 12),
                ),
                onPressed: () {
                  if (_inviteCode.isNotEmpty && _inviteCode != "加载中..." && _inviteCode != "获取失败") {
                    Clipboard.setData(ClipboardData(text: _inviteCode));
                    _showToast("已复制到剪贴板");
                  }
                },
                child: const Text("复制代码"),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildBindSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text("输入好友邀请码", style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _bindController,
                decoration: InputDecoration(
                  hintText: "请输入对方的邀请码",
                  hintStyle: const TextStyle(color: AppConfig.colorTextMute, fontSize: 13),
                  filled: true,
                  fillColor: AppConfig.colorBtnBg,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide(color: AppConfig.colorBorder),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide(color: AppConfig.colorBorder),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: const BorderSide(color: AppConfig.colorPrimary),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 12),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: AppConfig.colorPrimary,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                elevation: 0,
              ),
              onPressed: _isBinding
                  ? null // 请求进行中，禁用按钮防止重复点击
                  : () async {
                      final code = _bindController.text.trim();
                      if (code.isEmpty) {
                        _showToast("邀请码不能为空");
                        return;
                      }

                      // 暂时失焦收起键盘
                      FocusScope.of(context).unfocus();

                      setState(() => _isBinding = true);
                      try {
                        final res = await ApiService.bindInviteCode(code);
                        _showToast(res['msg'] ?? "绑定完成");
                        if (res['code'] == 200) {
                          _bindController.clear();
                          setState(() => _isLoading = true);
                          await _fetchInviteData(); // 刷新进度
                        }
                      } catch (e) {
                        _showToast("网络错误，请重试");
                      } finally {
                        if (mounted) setState(() => _isBinding = false);
                      }
                    },
              child: _isBinding
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Text("确认绑定"),
            ),
          ],
        ),
      ],
    );
  }
}