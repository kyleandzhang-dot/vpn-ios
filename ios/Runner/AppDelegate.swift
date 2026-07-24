import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)

    VpnTunnelPlugin.register(with: self.registrar(forPlugin: "VpnTunnelPlugin")!)

    // 新增：把 Extension 写在 App Group 容器里的诊断日志
    // 复制到主 App 自己的 Documents 目录，这样才能在「文件」App 里看到
    copyExtensionLogToDocuments()

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  // 每次主 App 启动时，把 Extension 写的 go_stderr.log 复制一份到
  // 主 App 自己的 Documents 目录（App Group 容器本身对「文件」App 不可见）。
  private func copyExtensionLogToDocuments() {
    let appGroup = "group.com.miaolian.myvpn" // 跟 Extension 里用的保持一致

    guard let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) else {
      return
    }
    let sourceURL = containerURL.appendingPathComponent("libbox/go_stderr.log")
    guard FileManager.default.fileExists(atPath: sourceURL.path) else {
      return
    }

    guard let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
      return
    }
    let destURL = documentsURL.appendingPathComponent("go_stderr.log")

    do {
      if FileManager.default.fileExists(atPath: destURL.path) {
        try FileManager.default.removeItem(at: destURL)
      }
      try FileManager.default.copyItem(at: sourceURL, to: destURL)
      print("[Debug] 已把日志复制到 Documents: \(destURL.path)")
    } catch {
      print("[Debug] 复制日志失败: \(error)")
    }
  }
}