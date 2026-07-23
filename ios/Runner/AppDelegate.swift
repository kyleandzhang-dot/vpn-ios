import Flutter
import UIKit
import NetworkExtension

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  var vpnChannel: FlutterMethodChannel?
  var vpnEventSink: FlutterEventSink?
  var tunnelManager: NETunnelProviderManager?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(vpnStatusDidChange),
      name: .NEVPNStatusDidChange,
      object: nil
    )
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    let messenger = engineBridge.pluginRegistry as! FlutterBinaryMessenger

    vpnChannel = FlutterMethodChannel(name: "com.example.vpn_all/vpn", binaryMessenger: messenger)
    vpnChannel?.setMethodCallHandler { [weak self] (call, result) in
      guard let self = self else { return }
      switch call.method {
      case "connect":
        guard let args = call.arguments as? [String: Any],
              let nodeJson = args["node_json"] as? String else {
          result(FlutterError(code: "BAD_ARGS", message: "缺少 node_json 参数", details: nil))
          return
        }
        self.connectVpn(nodeJson: nodeJson, result: result)
      case "disconnect":
        self.disconnectVpn(result: result)
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    let eventChannel = FlutterEventChannel(name: "com.example.vpn_all/vpn_status", binaryMessenger: messenger)
    eventChannel.setStreamHandler(VpnStatusStreamHandler(appDelegate: self))
  }

  // MARK: - VPN 控制逻辑

  func loadOrCreateTunnelManager(completion: @escaping (NETunnelProviderManager?, Error?) -> Void) {
    NETunnelProviderManager.loadAllFromPreferences { managers, error in
      if let error = error {
        completion(nil, error)
        return
      }

      let manager = managers?.first ?? NETunnelProviderManager()
      let proto = NETunnelProviderProtocol()
      // ⚠️ bundleIdentifier 需要跟你之后新建的 Extension Target 的 Bundle ID 完全一致
      proto.providerBundleIdentifier = "com.miaolian.myvpn.PacketTunnelExtension"
      proto.serverAddress = "sing-box" // 随便填一个非空字符串，系统要求非空
      manager.protocolConfiguration = proto
      manager.localizedDescription = "喵脸VPN"
      manager.isEnabled = true

      manager.saveToPreferences { error in
        if let error = error {
          completion(nil, error)
          return
        }
        manager.loadFromPreferences { error in
          completion(manager, error)
        }
      }
    }
  }

  func connectVpn(nodeJson: String, result: @escaping FlutterResult) {
    loadOrCreateTunnelManager { [weak self] manager, error in
      guard let self = self else { return }
      if let error = error {
        result(FlutterError(code: "LOAD_FAILED", message: error.localizedDescription, details: nil))
        return
      }
      guard let manager = manager else {
        result(FlutterError(code: "NO_MANAGER", message: "无法创建 VPN 配置", details: nil))
        return
      }
      self.tunnelManager = manager

      do {
        // node_json 通过 options 传给 Extension 的 startTunnel(options:)
        let options: [String: NSObject] = [
          "node_json": nodeJson as NSObject
        ]
        try manager.connection.startVPNTunnel(options: options)
        result("connecting")
      } catch {
        result(FlutterError(code: "START_FAILED", message: error.localizedDescription, details: nil))
      }
    }
  }

  func disconnectVpn(result: @escaping FlutterResult) {
    tunnelManager?.connection.stopVPNTunnel()
    result("disconnected")
  }

  @objc func vpnStatusDidChange(notification: Notification) {
    guard let connection = notification.object as? NEVPNConnection else { return }
    let statusStr: String
    switch connection.status {
    case .connected:
      statusStr = "CONNECTED"
    case .connecting, .reasserting:
      statusStr = "CONNECTING"
    case .disconnected, .invalid:
      statusStr = "DISCONNECTED"
    case .disconnecting:
      statusStr = "DISCONNECTED"
    @unknown default:
      statusStr = "DISCONNECTED"
    }
    vpnEventSink?(statusStr)
  }
}

class VpnStatusStreamHandler: NSObject, FlutterStreamHandler {
  weak var appDelegate: AppDelegate?

  init(appDelegate: AppDelegate) {
    self.appDelegate = appDelegate
  }

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    appDelegate?.vpnEventSink = events
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    appDelegate?.vpnEventSink = nil
    return nil
  }
}