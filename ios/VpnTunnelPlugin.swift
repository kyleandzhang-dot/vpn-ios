// ios/Runner/VpnTunnelPlugin.swift
import Flutter
import UIKit

public class VpnTunnelPlugin: NSObject, FlutterPlugin {
    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(
            name: "com.example.vpn_all/utils", // 👈 改成这个，跟 Dart 那边完全一致
            binaryMessenger: registrar.messenger()
        )
        let instance = VpnTunnelPlugin()
        registrar.addMethodCallDelegate(instance, channel: channel)
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        // TODO: 这里要对应 Dart 那边 invokeMethod 调用的方法名
        default:
            result(FlutterMethodNotImplemented)
        }
    }
}

