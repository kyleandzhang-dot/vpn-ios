import 'dart:async';
import 'package:flutter/material.dart';
import '../config/app_config.dart';
import '../models/market_app.dart';
import '../services/api_service.dart';
import '../services/market_bridge.dart';

enum _RowState { idle, downloading, downloaded }

class MarketScreen extends StatefulWidget {
  const MarketScreen({super.key});

  @override
  State<MarketScreen> createState() => _MarketScreenState();
}

class _MarketScreenState extends State<MarketScreen> with WidgetsBindingObserver {
  bool _loading = true;
  String? _errorText;
  List<MarketApp> _apps = [];

  // 每个 app.id 对应的行状态
  final Map<String, _RowState> _rowState = {};
  final Map<String, DownloadProgress> _rowProgress = {};
  final Map<String, String> _rowDownloadId = {}; // app.id -> download_id
  final Map<String, Timer> _rowTimers = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadAppList();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    for (final t in _rowTimers.values) {
      t.cancel();
    }
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // 用户可能刚从系统安装器装完App返回，刷新一下已下载行的安装状态
      _refreshInstalledStates();
    }
  }

  Future<void> _refreshInstalledStates() async {
    for (final app in _apps) {
      if (_rowState[app.id] == _RowState.downloaded) {
        // 只是触发一次 rebuild 让"打开/安装"文案根据实际安装情况更新
        if (mounted) setState(() {});
      }
    }
  }

  Future<void> _loadAppList() async {
    setState(() {
      _loading = true;
      _errorText = null;
    });

    final data = await ApiService.fetchMarketApps();
    if (data['code'] != 200 || data['data'] == null) {
      setState(() {
        _loading = false;
        _errorText = data['msg']?.toString() ?? '获取失败';
      });
      return;
    }

    final list = (data['data'] as List)
        .map((e) => MarketApp.fromJson(Map<String, dynamic>.from(e)))
        .toList();

    setState(() {
      _loading = false;
      _apps = list;
      _errorText = list.isEmpty ? '暂无应用' : null;
    });

    for (final app in list) {
      await _restoreDownloadStateIfNeeded(app);
    }
  }

  Future<void> _restoreDownloadStateIfNeeded(MarketApp app) async {
    final installed = await MarketBridge.isPackageInstalled(app.packageName);
    if (installed) {
      if (mounted) setState(() => _rowState[app.id] = _RowState.downloaded);
      return;
    }

    final savedId = await MarketBridge.getSavedDownloadId(app.id);
    if (savedId == null) {
      if (mounted) setState(() => _rowState[app.id] = _RowState.idle);
      return;
    }

    final progress = await MarketBridge.queryDownloadStatus(savedId);
    if (progress == null) {
      await MarketBridge.removeSavedDownloadId(app.id);
      if (mounted) setState(() => _rowState[app.id] = _RowState.idle);
      return;
    }

    _rowDownloadId[app.id] = savedId;

    switch (progress.status) {
      case DownloadStatus.successful:
        if (mounted) setState(() => _rowState[app.id] = _RowState.downloaded);
        break;
      case DownloadStatus.failed:
        await MarketBridge.removeSavedDownloadId(app.id);
        if (mounted) setState(() => _rowState[app.id] = _RowState.idle);
        break;
      default:
        if (mounted) {
          setState(() {
            _rowState[app.id] = _RowState.downloading;
            _rowProgress[app.id] = progress;
          });
        }
        _startPolling(app, savedId);
    }
  }

  Future<void> _onDownloadTap(MarketApp app) async {
    if (app.apkUrl.isEmpty) {
      _showToast('下载地址无效');
      return;
    }

    final canInstall = await MarketBridge.canInstallUnknownApps();
    if (!canInstall) {
      if (!mounted) return;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('需要安装权限'),
          content: const Text('请开启「允许安装未知应用」权限后再试'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
            TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('去设置')),
          ],
        ),
      );
      if (confirmed != true) return;
      final granted = await MarketBridge.requestInstallPermission();
      if (!granted) {
        _showToast('未获得安装权限，无法下载安装');
        return;
      }
    }

    await _startDownload(app);
  }

  Future<void> _startDownload(MarketApp app) async {
    setState(() {
      _rowState[app.id] = _RowState.downloading;
      _rowProgress[app.id] = const DownloadProgress(status: DownloadStatus.pending, downloaded: 0, total: 0);
    });

    final downloadId = await MarketBridge.startDownload(
      appId: app.id,
      apkUrl: app.apkUrl,
      appName: app.name,
      version: app.version,
    );
    _rowDownloadId[app.id] = downloadId;
    _startPolling(app, downloadId);
  }

  void _startPolling(MarketApp app, String downloadId) {
    _rowTimers[app.id]?.cancel();
    _rowTimers[app.id] = Timer.periodic(const Duration(milliseconds: 500), (timer) async {
      final progress = await MarketBridge.queryDownloadStatus(downloadId);
      if (!mounted) {
        timer.cancel();
        return;
      }

      if (progress == null) {
        timer.cancel();
        await MarketBridge.removeSavedDownloadId(app.id);
        setState(() => _rowState[app.id] = _RowState.idle);
        return;
      }

      setState(() => _rowProgress[app.id] = progress);

      switch (progress.status) {
        case DownloadStatus.successful:
          timer.cancel();
          setState(() => _rowState[app.id] = _RowState.downloaded);
          await MarketBridge.installDownloadedApk(downloadId);
          break;
        case DownloadStatus.failed:
          timer.cancel();
          await MarketBridge.removeSavedDownloadId(app.id);
          setState(() => _rowState[app.id] = _RowState.idle);
          _showToast('下载失败');
          break;
        default:
          break; // 继续轮询
      }
    });
  }

  Future<void> _onInstallOrOpenTap(MarketApp app) async {
    final installed = await MarketBridge.isPackageInstalled(app.packageName);
    if (installed) {
      await MarketBridge.launchApp(app.packageName);
      return;
    }

    final downloadId = _rowDownloadId[app.id];
    if (downloadId == null) {
      setState(() => _rowState[app.id] = _RowState.idle);
      _showToast('安装包已失效，请重新下载');
      return;
    }
    await MarketBridge.installDownloadedApk(downloadId);
  }

  void _showToast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg), duration: const Duration(seconds: 2)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('海外应用推荐', style: TextStyle(color: AppConfig.colorPrimary, fontWeight: FontWeight.bold)),
        backgroundColor: AppConfig.colorBg,
        elevation: 0,
        iconTheme: const IconThemeData(color: AppConfig.colorPrimary),
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator(color: AppConfig.colorPrimary));
    }
    if (_errorText != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_errorText!, style: const TextStyle(color: AppConfig.colorTextMute, fontSize: 13)),
            const SizedBox(height: 12),
            TextButton(onPressed: _loadAppList, child: const Text('重新加载')),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _loadAppList,
      child: ListView.builder(
        padding: const EdgeInsets.all(16),
        itemCount: _apps.length,
        itemBuilder: (context, index) => _buildAppRow(_apps[index]),
      ),
    );
  }

  Widget _buildAppRow(MarketApp app) {
    final state = _rowState[app.id] ?? _RowState.idle;
    final progress = _rowProgress[app.id];

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppConfig.colorBg,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppConfig.colorBorder),
      ),
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: Container(
              width: 48,
              height: 48,
              color: AppConfig.colorBtnBg,
              child: app.iconUrl.isNotEmpty
                  ? Image.network(
                      app.iconUrl,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => const Icon(Icons.apps, color: AppConfig.colorTextMute),
                    )
                  : const Icon(Icons.apps, color: AppConfig.colorTextMute),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(app.name, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: AppConfig.colorTextMain)),
                const SizedBox(height: 4),
                Text(
                  app.version.isNotEmpty ? 'v${app.version} · ${app.price}' : app.price,
                  style: const TextStyle(fontSize: 11, color: AppConfig.colorTextSub),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          _buildActionArea(app, state, progress),
        ],
      ),
    );
  }

  Widget _buildActionArea(MarketApp app, _RowState state, DownloadProgress? progress) {
    switch (state) {
      case _RowState.idle:
        return _pillButton(text: '下载', bg: AppConfig.colorPrimary, onTap: () => _onDownloadTap(app));
      case _RowState.downloading:
        final percent = progress?.percent ?? 0;
        return SizedBox(
          width: 70,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('$percent%', style: const TextStyle(fontSize: 11, color: AppConfig.colorTextSub)),
              const SizedBox(height: 4),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: (progress?.total ?? 0) > 0 ? percent / 100 : null,
                  minHeight: 4,
                  backgroundColor: AppConfig.colorBorder,
                  color: AppConfig.colorPrimary,
                ),
              ),
            ],
          ),
        );
      case _RowState.downloaded:
        return FutureBuilder<bool>(
          future: MarketBridge.isPackageInstalled(app.packageName),
          builder: (context, snapshot) {
            final installed = snapshot.data ?? false;
            return _pillButton(
              text: installed ? '打开' : '安装',
              bg: const Color(0xFF2E7D32),
              onTap: () => _onInstallOrOpenTap(app),
            );
          },
        );
    }
  }

  Widget _pillButton({required String text, required Color bg, required VoidCallback onTap}) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(999)),
        child: Text(text, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.white)),
      ),
    );
  }
}