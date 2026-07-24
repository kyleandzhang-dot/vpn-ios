// ios/Runner/VpnTunnelPlugin.swift
import Flutter
import UIKit
import NetworkExtension // 使用 sing-box 建立 VPN 隧道必须引入

public class VpnTunnelPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
    
    private var eventSink: FlutterEventSink?

    public static func register(with registrar: FlutterPluginRegistrar) {
        // 1. 修正为与 Dart 端一字不差的 MethodChannel 名称[cite: 2]
        let channel = FlutterMethodChannel(
            name: "com.example.vpn_all/vpn", 
            binaryMessenger: registrar.messenger()
        )
        let instance = VpnTunnelPlugin()
        registrar.addMethodCallDelegate(instance, channel: channel)
        
        // 2. 顺便注册 EventChannel，用于向 Dart 发送 VPN 状态 (CONNECTED/CONNECTING等)[cite: 2]
        let eventChannel = FlutterEventChannel(
            name: "com.example.vpn_all/vpn_status", 
            binaryMessenger: registrar.messenger()
        )
        eventChannel.setStreamHandler(instance)
    }

    // 处理 Dart 调用的 MethodChannel 指令[cite: 4]
    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "connect": // 对应 Dart 的 VpnBridge.connect[cite: 2]
            guard let args = call.arguments as? [String: Any],
                  let nodeJson = args["node_json"] as? String else {[cite: 2]
                result(FlutterError(code: "PARAM_ERROR", message: "缺少 node_json 参数", details: nil))
                return
            }
            startSingBoxVpn(nodeJson: nodeJson, result: result)
            
        case "disconnect": // 对应 Dart 的 VpnBridge.disconnect[cite: 2]
            stopSingBoxVpn(result: result)
            
        default:
            result(FlutterMethodNotImplemented)[cite: 4]
        }
    }

    // --- 实现 EventChannel 回调监听 ---
    public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        self.eventSink = events
        // TODO: 在这里向系统注册 NEVPNStatusDidChange 监听，当原生 VPN 状态改变时，
        // 调用 self.eventSink?("CONNECTED") 或 self.eventSink?("CONNECTING")[cite: 2]
        return nil
    }

    public func onCancel(withArguments arguments: Any?) -> FlutterError? {
        self.eventSink = nil
        return nil
    }

    // --- VPN 具体控制逻辑 ---
    private func startSingBoxVpn(nodeJson: String, result: @escaping FlutterResult) {
        // ⚠️ 注意 sing-box 架构：这里不要直接调用 Libbox 启动业务
        // 应该通过 NETunnelProviderManager 把 nodeJson 写入系统 VPN 的 providerConfiguration[cite: 2]，
        // 然后调用 connection.startVPNTunnel() 唤醒你的 PacketTunnelProvider 进程
        
        print("[iOS Native] 准备连接 VPN, 节点数据: \(nodeJson)")
        // 告诉 Dart 端方法调用成功（不代表 VPN 马上建立成功，隧道状态由 EventChannel 另行通知）
        result(nil) 
    }

    private func stopSingBoxVpn(result: @escaping FlutterResult) {
        print("[iOS Native] 准备断开 VPN")
        // TODO: NETunnelProviderManager.shared().connection.stopVPNTunnel()
        result(nil)
    }
}