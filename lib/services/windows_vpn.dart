import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../config/app_config.dart';
import 'api_service.dart';
import 'vpn_bridge.dart' show VpnState;

typedef _InetSetOptNative = Int32 Function(
    Pointer<Void>, Uint32, Pointer<Void>, Uint32);
typedef _InetSetOptDart = int Function(Pointer<Void>, int, Pointer<Void>, int);

/// 通知 WinINet 系统代理设置已变化（Chrome/Edge 等才会立刻生效）
void _notifyProxyChanged() {
  try {
    final f = DynamicLibrary.open('wininet.dll')
        .lookupFunction<_InetSetOptNative, _InetSetOptDart>(
            'InternetSetOptionW');
    f(nullptr, 39, nullptr, 0); // INTERNET_OPTION_SETTINGS_CHANGED
    f(nullptr, 37, nullptr, 0); // INTERNET_OPTION_REFRESH
  } catch (_) {}
}

/// Windows 上的 VPN 实现：本地启动 xray 核心（http 入站），并设置系统代理。
/// 对应 Android 的 CustomVpnService + XrayEngine。
class WindowsVpn {
  WindowsVpn._();
  static final WindowsVpn instance = WindowsVpn._();

  static const _coreName = 'miaolian-core.exe';
  static const _regKey =
      r'HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings';
  static const _kActive = 'win_proxy_active';
  static const _kPrevEnable = 'win_prev_proxy_enable';
  static const _kPrevServer = 'win_prev_proxy_server';
  static const _kPrevOverride = 'win_prev_proxy_override';

  final _ctrl = StreamController<VpnState>.broadcast();
  Stream<VpnState> get stream => _ctrl.stream;
  VpnState _state = VpnState.disconnected;
  VpnState get state => _state;

  Process? _proc;
  Timer? _heartbeat;
  bool _stopping = false;
  int _gen = 0; // 用于识别"连接过程中被用户取消"
  final List<String> _logTail = [];
  File? _cfgFile;

  void _emit(VpnState s) {
    _state = s;
    _ctrl.add(s);
  }

  // ================= 对外接口 =================

  Future<void> connect(String nodeJson) async {
    final myGen = ++_gen;
    await _teardown();
    await _killStaleCore();

    final node = json.decode(nodeJson) as Map<String, dynamic>;
    final port = await _freePort();

    final base =
        Platform.environment['LOCALAPPDATA'] ?? Directory.systemTemp.path;
    final dir = Directory('$base\\MiaoLian');
    await dir.create(recursive: true);
    _cfgFile = File('${dir.path}\\core_config.json');
    await _cfgFile!.writeAsString(json.encode(_buildConfig(node, port)));

    _logTail.clear();
    final proc = await Process.start(
      _corePath(),
      ['run', '-c', _cfgFile!.path],
      workingDirectory: dir.path,
    );
    _proc = proc;
    var exited = false;
    proc.stdout.transform(utf8.decoder).listen(_onLog);
    proc.stderr.transform(utf8.decoder).listen(_onLog);
    proc.exitCode.then((code) {
      exited = true;
      if (!_stopping && identical(_proc, proc)) _onCoreCrashed(code);
    });

    final ok = await _waitPort(port, () => exited, const Duration(seconds: 8));
    if (myGen != _gen) {
      await _teardown(); // 用户在连接过程中取消了，静默退出
      return;
    }
    if (!ok) {
      final detail = _logTail.join(' ').trim();
      await _teardown();
      throw Exception(exited ? '核心启动失败: $detail' : '核心启动超时');
    }

    await _applySystemProxy(port);
    _startHeartbeat();
    _emit(VpnState.connected);
  }

  Future<void> disconnect() async {
    _gen++;
    await _teardown();
    _emit(VpnState.disconnected);
  }

  /// App 启动时调用：上次崩溃/被强杀时可能残留系统代理和核心进程
  static Future<void> cleanupStale() async {
    await instance._restoreSystemProxy();
    await instance._killStaleCore();
  }

  // ================= 内部实现 =================

  Future<void> _teardown() async {
    _stopping = true;
    _heartbeat?.cancel();
    _heartbeat = null;
    await _restoreSystemProxy();
    final p = _proc;
    _proc = null;
    if (p != null) {
      p.kill();
      await p.exitCode.timeout(const Duration(seconds: 3), onTimeout: () => -1);
    }
    try {
      await _cfgFile?.delete(); // 配置里有 uuid，用完即删
    } catch (_) {}
    _stopping = false;
  }

  void _onCoreCrashed(int code) async {
    _proc = null;
    _heartbeat?.cancel();
    await _restoreSystemProxy();
    _emit(VpnState.disconnected);
  }

  void _onLog(String s) {
    for (final line in const LineSplitter().convert(s)) {
      if (line.trim().isEmpty) continue;
      _logTail.add(line.trim());
      if (_logTail.length > 8) _logTail.removeAt(0);
    }
  }

  String _corePath() {
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    final p = '$exeDir\\core\\$_coreName';
    if (!File(p).existsSync()) throw Exception('缺少核心文件: $p');
    return p;
  }

  Future<void> _killStaleCore() async {
    try {
      await Process.run('taskkill', ['/F', '/IM', _coreName]);
    } catch (_) {}
  }

  Future<int> _freePort() async {
    final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final p = s.port;
    await s.close();
    return p;
  }

  Future<bool> _waitPort(
      int port, bool Function() exited, Duration timeout) async {
    final end = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(end)) {
      if (exited()) return false;
      try {
        final s = await Socket.connect('127.0.0.1', port,
            timeout: const Duration(milliseconds: 300));
        s.destroy();
        return true;
      } catch (_) {
        await Future.delayed(const Duration(milliseconds: 150));
      }
    }
    return false;
  }

  /// 对应 Android 的 XrayEngine.buildVlessConfig，只是入站从 tun 换成本地 http 代理
  Map<String, dynamic> _buildConfig(Map<String, dynamic> n, int httpPort) {
    final r = Map<String, dynamic>.from(n['reality'] as Map);
    return {
      'log': {'loglevel': 'warning'},
      'inbounds': [
        {
          'tag': 'http-in',
          'listen': '127.0.0.1',
          'port': httpPort,
          'protocol': 'http',
          'settings': {'allowTransparent': false},
        }
      ],
      'outbounds': [
        {
          'tag': 'proxy',
          'protocol': 'vless',
          'settings': {
            'vnext': [
              {
                'address': n['address'],
                'port': n['port'],
                'users': [
                  {
                    'id': n['uuid'],
                    'encryption': n['encryption'] ?? 'none',
                    'flow': n['flow'] ?? 'xtls-rprx-vision',
                  }
                ],
              }
            ],
          },
          'streamSettings': {
            'network': n['network'] ?? 'tcp',
            'security': n['security'] ?? 'reality',
            'realitySettings': {
              'show': false,
              'fingerprint': r['fingerprint'] ?? 'chrome',
              'serverName': r['serverName'],
              'publicKey': r['publicKey'],
              'shortId': r['shortId'],
              'spiderX': r['spiderX'] ?? '/',
            },
          },
        },
        {'tag': 'direct', 'protocol': 'freedom', 'settings': {}},
      ],
      'routing': {
        'domainStrategy': 'AsIs',
        'rules': [
          {
            'type': 'field',
            'ip': [
              '0.0.0.0/8',
              '10.0.0.0/8',
              '100.64.0.0/10',
              '127.0.0.0/8',
              '169.254.0.0/16',
              '172.16.0.0/12',
              '192.168.0.0/16',
              '224.0.0.0/4',
              '240.0.0.0/4'
            ],
            'outboundTag': 'direct',
          },
          {'type': 'field', 'network': 'tcp,udp', 'outboundTag': 'proxy'},
        ],
      },
    };
  }

  // ---------- 系统代理（注册表） ----------

  Future<String?> _regGet(String name) async {
    try {
      final r = await Process.run('reg', ['query', _regKey, '/v', name]);
      if (r.exitCode != 0) return null;
      return RegExp(r'REG_\w+\s+(.*)')
          .firstMatch(r.stdout.toString())
          ?.group(1)
          ?.trim();
    } catch (_) {
      return null;
    }
  }

  Future<void> _regSet(String name, String type, String value) async {
    final result = await Process.run(
      'reg',
      ['add', _regKey, '/v', name, '/t', type, '/d', value, '/f'],
    );
    if (result.exitCode != 0) {
      throw StateError(
        '写入系统代理失败($name): ${result.stderr.toString().trim()}',
      );
    }
  }

  Future<void> _regDel(String name) async {
    final result = await Process.run(
      'reg',
      ['delete', _regKey, '/v', name, '/f'],
    );
    // 注册表值原本就不存在也视为删除成功。
    if (result.exitCode != 0 && await _regGet(name) != null) {
      throw StateError(
        '清除系统代理失败($name): ${result.stderr.toString().trim()}',
      );
    }
  }

  int _parseRegDword(String? value) {
    if (value == null) return 0;
    final text = value.trim().toLowerCase();
    if (text.startsWith('0x')) {
      return int.tryParse(text.substring(2), radix: 16) ?? 0;
    }
    return int.tryParse(text) ?? 0;
  }

  bool _looksLikeMiaoLianProxy(String? server, String? override) {
    if (server == null ||
        !RegExp(r'^127\.0\.0\.1:\d+$').hasMatch(server.trim())) {
      return false;
    }
    final bypass = override ?? '';
    return bypass.contains('localhost') &&
        bypass.contains('127.*') &&
        bypass.contains('192.168.*') &&
        bypass.contains('<local>');
  }

  Future<void> _applySystemProxy(int port) async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(_kActive) != true) {
      // 只在"尚未接管"时备份用户原来的代理设置，避免把我们自己的值当成原值
      await prefs.setString(
          _kPrevEnable, await _regGet('ProxyEnable') ?? '0x0');
      await prefs.setString(_kPrevServer, await _regGet('ProxyServer') ?? '');
      await prefs.setString(
          _kPrevOverride, await _regGet('ProxyOverride') ?? '');
      await prefs.setBool(_kActive, true);
    }
    await _regSet('ProxyEnable', 'REG_DWORD', '1');
    await _regSet('ProxyServer', 'REG_SZ', '127.0.0.1:$port');
    await _regSet(
        'ProxyOverride', 'REG_SZ', 'localhost;127.*;10.*;192.168.*;<local>');
    _notifyProxyChanged();
  }

  Future<void> _restoreSystemProxy() async {
    final prefs = await SharedPreferences.getInstance();
    final wasActive = prefs.getBool(_kActive) == true;
    final currentServer = await _regGet('ProxyServer');
    final currentOverride = await _regGet('ProxyOverride');

    // SharedPreferences 可能因重装/升级丢失。只要注册表仍带有本应用设置的
    // 本地临时端口和特征绕过列表，也要兜底关闭，避免断开后无法联网。
    if (!wasActive) {
      if (!_looksLikeMiaoLianProxy(currentServer, currentOverride)) return;
      await _regSet('ProxyEnable', 'REG_DWORD', '0');
      await _regDel('ProxyServer');
      await _regDel('ProxyOverride');
      _notifyProxyChanged();
      return;
    }

    final enable = _parseRegDword(prefs.getString(_kPrevEnable));
    final server = prefs.getString(_kPrevServer) ?? '';
    final override = prefs.getString(_kPrevOverride) ?? '';

    // 某些 Windows 环境在代理页面打开时会短暂覆盖注册表值，所以恢复后
    // 立即读回校验；不一致时再写一次，只有确认成功才清除 active 标记。
    for (var attempt = 0; attempt < 2; attempt++) {
      await _regSet('ProxyEnable', 'REG_DWORD', '$enable');
      if (server.isEmpty) {
        await _regDel('ProxyServer');
      } else {
        await _regSet('ProxyServer', 'REG_SZ', server);
      }
      if (override.isEmpty) {
        await _regDel('ProxyOverride');
      } else {
        await _regSet('ProxyOverride', 'REG_SZ', override);
      }
      _notifyProxyChanged();

      final restoredEnable = _parseRegDword(await _regGet('ProxyEnable'));
      final restoredServer = await _regGet('ProxyServer') ?? '';
      final restoredOverride = await _regGet('ProxyOverride') ?? '';
      if (restoredEnable == enable &&
          restoredServer == server &&
          restoredOverride == override) {
        await prefs.setBool(_kActive, false);
        return;
      }
      await Future.delayed(const Duration(milliseconds: 150));
    }

    throw StateError('系统代理恢复失败，请在 Windows 设置中手动关闭代理');
  }

  // ---------- 心跳（对应 CustomVpnService.checkUserStatus） ----------
  // Dart 的 HttpClient 不读 Windows 系统代理，所以这个请求天然直连，
  // 不需要像 Android 那样专门绕过隧道。

  void _startHeartbeat() {
    _heartbeat?.cancel();
    _heartbeat =
        Timer.periodic(const Duration(seconds: 60), (_) => _checkStatus());
  }

  Future<void> _checkStatus() async {
    try {
      final id = await ApiService.getDeviceId();
      final res = await http
          .post(
            Uri.parse('${AppConfig.apiBaseUrl}/api/v1/check_status'),
            headers: {'Content-Type': 'application/json'},
            body: json.encode({'device_id': id}),
          )
          .timeout(const Duration(seconds: 8));
      if (res.statusCode == 200 && json.decode(res.body)['code'] == 403) {
        _gen++;
        await _teardown();
        _emit(VpnState.expired);
      }
    } catch (_) {}
  }
}
