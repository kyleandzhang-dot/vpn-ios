import Flutter
import NetworkExtension

// 放进 Runner 主 App target。
// Channel 名字跟你 Dart 侧 vpn_bridge.dart 里的完全一致,
// 所以 Dart 代码一行都不用改。

public class VpnTunnelPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {

    private var eventSink: FlutterEventSink?
    private var manager: NETunnelProviderManager?
    // 【排除测试】：换回旧代码里的值做对照测试。注意：开发者后台的
    // Identifiers 列表里查不到 com.example.vpnAll.PacketTunnel 这个注册项，
    // 且上次用 com.miaolian.myvpn.PacketTunnelExtension（后台唯一合法值）
    // 测试时报的是同一句 "The VPN app used by the VPN configuration is
    // not installed"——两个不同 ID 报同一个错，大概率说明问题不在这串
    // 字符串本身，而是 Extension 没有被 Embed & Sign 进包里，或者
    // Provisioning Profile / Network Extension entitlement 没配好。
    // 这里改回旧值只是用来排除"是不是字符串问题"，如果还报同样的错，
    // 就该去查 Xcode 里 Embed & Sign 和 Signing & Capabilities 了。
    private let appGroup = "group.com.example.vpnAll"
    private let providerBundleId = "com.example.vpnAll.PacketTunnel"

    public static func register(with registrar: FlutterPluginRegistrar) {
        let instance = VpnTunnelPlugin()

        let methodChannel = FlutterMethodChannel(
            name: "com.example.vpn_all/vpn",
            binaryMessenger: registrar.messenger()
        )
        registrar.addMethodCallDelegate(instance, channel: methodChannel)

        let eventChannel = FlutterEventChannel(
            name: "com.example.vpn_all/vpn_status",
            binaryMessenger: registrar.messenger()
        )
        eventChannel.setStreamHandler(instance)

        instance.observeExtensionStatus()
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "connect":
            guard let args = call.arguments as? [String: Any],
                  let nodeJson = args["node_json"] as? String else {
                result(FlutterError(code: "BAD_ARGS", message: "缺少 node_json", details: nil))
                return
            }
            // api_base_url 透传给 Extension，供它自己起心跳查到期状态用
            let apiBaseUrl = args["api_base_url"] as? String ?? ""
            connect(nodeJson: nodeJson, apiBaseUrl: apiBaseUrl, result: result)
        case "getDeviceId":
            // 关键修复：这个 case 之前压根不存在，导致 Dart 侧 VpnBridge.getDeviceId()
            // 每次都命中 FlutterMethodNotImplemented、拿到空字符串，进而回退成
            // ApiService 里存在本地 SharedPreferences 的随机 UUID —— 跟 Extension
            // 心跳检测读的 Keychain 共享 ID 完全对不上，这才是"用户不存在"的真正原因。
            // 补上之后，主 App 登录/充值/拉节点用的 device_id 才会跟 Extension
            // 心跳检测用的 device_id 是同一个。
            result(DeviceIdManager.getDeviceId())
        case "disconnect":
            disconnect(result: result)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - connect / disconnect

    private func connect(nodeJson: String, apiBaseUrl: String, result: @escaping FlutterResult) {
        loadOrCreateManager { [weak self] manager, error in
            guard let self = self, let manager = manager else {
                result(FlutterError(code: "MANAGER_ERR", message: error?.localizedDescription, details: nil))
                return
            }

            let proto = NETunnelProviderProtocol()
            proto.providerBundleIdentifier = self.providerBundleId
            proto.serverAddress = "miaolian-vpn" // 随便填一个非空标识即可,系统不关心内容
            proto.providerConfiguration = ["node_json": nodeJson, "api_base_url": apiBaseUrl]

            manager.protocolConfiguration = proto
            manager.localizedDescription = "喵脸"
            manager.isEnabled = true

            manager.saveToPreferences { saveError in
                if let saveError = saveError {
                    result(FlutterError(code: "SAVE_ERR", message: saveError.localizedDescription, details: nil))
                    return
                }
                // 保存后要 reload 一次才能拿到有效的 connection 对象
                manager.loadFromPreferences { loadError in
                    if let loadError = loadError {
                        result(FlutterError(code: "LOAD_ERR", message: loadError.localizedDescription, details: nil))
                        return
                    }
                    do {
                        try manager.connection.startVPNTunnel()
                        self.manager = manager
                        result(nil)
                    } catch {
                        result(FlutterError(code: "START_ERR", message: error.localizedDescription, details: nil))
                    }
                }
            }
        }
    }

    private func disconnect(result: @escaping FlutterResult) {
        manager?.connection.stopVPNTunnel()
        result(nil)
    }

    private func loadOrCreateManager(_ completion: @escaping (NETunnelProviderManager?, Error?) -> Void) {
        NETunnelProviderManager.loadAllFromPreferences { managers, error in
            if let error = error {
                completion(nil, error)
                return
            }
            if let existing = managers?.first {
                completion(existing, nil)
            } else {
                completion(NETunnelProviderManager(), nil)
            }
        }
    }

    // MARK: - 状态上报

    public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        self.eventSink = events
        return nil
    }

    public func onCancel(withArguments arguments: Any?) -> FlutterError? {
        self.eventSink = nil
        return nil
    }

    // 系统级状态变化(连接中/已断开等)
    private func observeExtensionStatus() {
        NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let connection = notification.object as? NEVPNConnection else { return }
            self?.emit(forSystemStatus: connection.status)
        }

        // 自定义状态(比如 EXPIRED)通过 App Group + Darwin 通知从 Extension 传回来
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            { _, observer, _, _, _ in
                guard let observer = observer else { return }
                let mySelf = Unmanaged<VpnTunnelPlugin>.fromOpaque(observer).takeUnretainedValue()
                mySelf.emitCustomStatusFromAppGroup()
            },
            "com.example.vpnAll.statusChanged" as CFString,
            nil,
            .deliverImmediately
        )
    }

    private func emit(forSystemStatus status: NEVPNStatus) {
        switch status {
        case .connected:
            eventSink?("CONNECTED")
        case .connecting, .reasserting:
            eventSink?("CONNECTING")
        case .disconnected, .invalid, .disconnecting:
            eventSink?("DISCONNECTED")
        @unknown default:
            eventSink?("DISCONNECTED")
        }
    }

    private func emitCustomStatusFromAppGroup() {
        let defaults = UserDefaults(suiteName: appGroup)
        if let status = defaults?.string(forKey: "vpn_status") {
            eventSink?(status) // 主要用来传 "EXPIRED"
        }
    }
}