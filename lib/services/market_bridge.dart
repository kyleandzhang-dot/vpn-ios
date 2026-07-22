import 'package:flutter/services.dart';

enum DownloadStatus { pending, running, paused, successful, failed, unknown }

class DownloadProgress {
  final DownloadStatus status;
  final int downloaded;
  final int total;

  const DownloadProgress({required this.status, required this.downloaded, required this.total});

  int get percent => total > 0 ? ((downloaded * 100) / total).toInt() : 0;

  factory DownloadProgress.fromMap(Map<dynamic, dynamic> map) {
    final statusStr = map['status']?.toString() ?? 'UNKNOWN';
    final status = DownloadStatus.values.firstWhere(
      (e) => e.name.toUpperCase() == statusStr,
      orElse: () => DownloadStatus.unknown,
    );
    return DownloadProgress(
      status: status,
      downloaded: (map['downloaded'] as num?)?.toInt() ?? 0,
      total: (map['total'] as num?)?.toInt() ?? 0,
    );
  }
}

class MarketBridge {
  static const MethodChannel _channel = MethodChannel('com.example.vpn_all/market');

  static Future<bool> isPackageInstalled(String packageName) async {
    if (packageName.isEmpty) return false;
    try {
      return await _channel.invokeMethod<bool>('isPackageInstalled', {'package_name': packageName}) ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> canInstallUnknownApps() async {
    try {
      return await _channel.invokeMethod<bool>('canInstallUnknownApps') ?? true;
    } catch (_) {
      return true;
    }
  }

  /// 跳转系统设置让用户开启"安装未知应用"权限，返回用户设置完之后的最新状态
  static Future<bool> requestInstallPermission() async {
    try {
      return await _channel.invokeMethod<bool>('requestInstallPermission') ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<String> startDownload({
    required String appId,
    required String apkUrl,
    required String appName,
    required String version,
  }) async {
    final id = await _channel.invokeMethod<String>('startDownload', {
      'app_id': appId,
      'apk_url': apkUrl,
      'app_name': appName,
      'version': version,
    });
    return id ?? '';
  }

  /// 返回 null 表示下载记录已不存在（比如用户在系统下载管理里清掉了）
  static Future<DownloadProgress?> queryDownloadStatus(String downloadId) async {
    final res = await _channel.invokeMethod<Map<dynamic, dynamic>>('queryDownloadStatus', {'download_id': downloadId});
    if (res == null) return null;
    return DownloadProgress.fromMap(res);
  }

  /// 返回 null 表示没有保存过下载记录
  static Future<String?> getSavedDownloadId(String appId) async {
    final id = await _channel.invokeMethod<String>('getSavedDownloadId', {'app_id': appId});
    if (id == null || id == '-1') return null;
    return id;
  }

  static Future<void> removeSavedDownloadId(String appId) async {
    await _channel.invokeMethod('removeSavedDownloadId', {'app_id': appId});
  }

  static Future<void> installDownloadedApk(String downloadId) async {
    await _channel.invokeMethod('installDownloadedApk', {'download_id': downloadId});
  }

  static Future<void> launchApp(String packageName) async {
    await _channel.invokeMethod('launchApp', {'package_name': packageName});
  }
}