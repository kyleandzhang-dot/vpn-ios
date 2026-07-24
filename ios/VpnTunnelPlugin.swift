// ios/Runner/VpnTunnelPlugin.swift
import Flutter
import UIKit
import NetworkExtension

public class VpnTunnelPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
    
    private var eventSink: FlutterEventSink?
    private var vpnManager: NETunnelProviderManager?

    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: "com.example.vpn_all/vpn", binaryMessenger: registrar.messenger())
        let instance = VpnTunnelPlugin()
        registrar.addMethodCallDelegate(instance, channel: channel)
        
        let eventChannel = FlutterEventChannel(name: "com.example.vpn_all/vpn_status", binaryMessenger: registrar.messenger())
        eventChannel.setStreamHandler(instance)
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "connect":
            guard let args = call.arguments as? [String: Any],
                  let nodeJson = args["node_json"] as? String else {
                result(FlutterError(code: "PARAM_ERROR", message: "缺少 node_json 参数", details: nil))
                return
            }
            startSingBoxVpn(nodeJson: nodeJson, result: result)
            
        case "disconnect":
            stopSingBoxVpn(result: result)
            
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // --- EventChannel 状态监听 ---
    public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        self.eventSink = events
        // 监听 iOS 系统 VPN 状态变化
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onVpnStatusChanged),
            name: .NEVPNStatusDidChange,
            object: nil
        )
        return nil
    }

    public func onCancel(withArguments arguments: Any?) -> FlutterError? {
        NotificationCenter.default.removeObserver(self, name: .NEVPNStatusDidChange, object: nil)
        self.eventSink = nil
        return nil
    }

    @objc private func onVpnStatusChanged() {
        guard let status = vpnManager?.connection.status else { return }
        switch status {
        case .connecting, .reasserting:
            eventSink?("CONNECTING")
        case .connected:
            eventSink?("CONNECTED")
        case .disconnected, .invalid:
            eventSink?("DISCONNECTED")
        default:
            break
        }
    }

    // --- NETunnelProviderManager 核心控制 ---
    private func startSingBoxVpn(nodeJson: String, result: @escaping FlutterResult) {
        // 先向 UI 发送正在连接的状态，避免 Flutter UI 傻等
        self.eventSink?("CONNECTING")
        
        // 1. 从系统加载或创建 VPN 配置
        NETunnelProviderManager.loadAllFromPreferences { [weak self] managers, error in
            guard let self = self else { return }
            
            if let error = error {
                print("[iOS Native] 加载 VPN 配置失败: \(error.localizedDescription)")
                self.eventSink?("DISCONNECTED")
                result(FlutterError(code: "VPN_ERROR", message: error.localizedDescription, details: nil))
                return
            }
            
            // 如果已有配置则复用，没有则新建
            let manager = managers?.first ?? NETunnelProviderManager()
            self.vpnManager = manager
            
            // 2. 配置协议 (⚠️ 注意：这里的 Bundle Identifier 必须指向你的 NetworkExtension Target)
            let protocolConfiguration = NETunnelProviderProtocol()
            // TODO: 请确保这里换成你实际的 PacketTunnelProvider Target 的 Bundle ID（例如 com.miaolian.myvpn.extension）
            protocolConfiguration.providerBundleIdentifier = "com.example.vpn_all.PacketTunnel"
            protocolConfiguration.serverAddress = "SingBox VPN"
            
            // 3. 把节点 JSON 数据塞进配置里，供后台 Extension 扩展读取
            protocolConfiguration.providerConfiguration = ["node_json": nodeJson]
            
            manager.protocolConfiguration = protocolConfiguration
            manager.localizedDescription = "MiaoLian VPN"
            manager.isEnabled = true
            
            // 4. 保存到系统设置并启动
            manager.saveToPreferences { error in
                if let error = error {
                    print("[iOS Native] 保存 VPN 设置失败: \(error.localizedDescription)")
                    self.eventSink?("DISCONNECTED")
                    result(FlutterError(code: "SAVE_ERROR", message: error.localizedDescription, details: nil))
                    return
                }
                
                // 重新加载一次以确保权限和配置生效
                manager.loadFromPreferences { error in
                    do {
                        try manager.connection.startVPNTunnel()
                        print("[iOS Native] 隧道启动指令已发出")
                        result(nil)
                    } catch {
                        print("[iOS Native] 启动隧道异常: \(error.localizedDescription)")
                        self.eventSink?("DISCONNECTED")
                        result(FlutterError(code: "START_ERROR", message: error.localizedDescription, details: nil))
                    }
                }
            }
        }
    }

    private func stopSingBoxVpn(result: @escaping FlutterResult) {
        vpnManager?.connection.stopVPNTunnel()
        self.eventSink?("DISCONNECTED")
        result(nil)
    }
}