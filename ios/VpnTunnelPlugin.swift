// ios/Runner/VpnTunnelPlugin.swift
import Flutter
import UIKit
import NetworkExtension

public class VpnTunnelPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
    
    private var eventSink: FlutterEventSink?

    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(
            name: "com.example.vpn_all/vpn", 
            binaryMessenger: registrar.messenger()
        )
        let instance = VpnTunnelPlugin()
        registrar.addMethodCallDelegate(instance, channel: channel)
        
        let eventChannel = FlutterEventChannel(
            name: "com.example.vpn_all/vpn_status", 
            binaryMessenger: registrar.messenger()
        )
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

    public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        self.eventSink = events
        return nil
    }

    public func onCancel(withArguments arguments: Any?) -> FlutterError? {
        self.eventSink = nil
        return nil
    }

    private func startSingBoxVpn(nodeJson: String, result: @escaping FlutterResult) {
        print("[iOS Native] 准备连接 VPN, 节点数据: \(nodeJson)")
        result(nil) 
    }

    private func stopSingBoxVpn(result: @escaping FlutterResult) {
        print("[iOS Native] 准备断开 VPN")
        result(nil)
    }
}