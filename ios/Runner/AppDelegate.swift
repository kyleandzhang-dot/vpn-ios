// 在 Runner/AppDelegate.swift 的 application(_:didFinishLaunchingWithOptions:) 里加一行：

import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)

    // 新增这一行
    VpnTunnelPlugin.register(with: self.registrar(forPlugin: "VpnTunnelPlugin")!)

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}