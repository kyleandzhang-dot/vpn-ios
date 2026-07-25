import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {

  // 单独开一个 channel 给"手动分享日志"用，跟 VpnTunnelPlugin 用的
  // 'com.example.vpn_all/vpn' channel 完全独立，不会互相覆盖 handler。
  private let logChannelName = "com.example.vpn_all/log"

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)

    VpnTunnelPlugin.register(with: self.registrar(forPlugin: "VpnTunnelPlugin")!)

    // 注册"手动分享日志" MethodChannel，供 Flutter 侧的测试按钮调用。
    if let logRegistrar = self.registrar(forPlugin: "LogSharePlugin") {
      let logChannel = FlutterMethodChannel(
        name: logChannelName,
        binaryMessenger: logRegistrar.messenger()
      )
      logChannel.setMethodCallHandler { [weak self] call, result in
        guard call.method == "shareLog" else {
          result(FlutterMethodNotImplemented)
          return
        }
        self?.shareLogIfExists(auto: false) { success, message in
          result(["success": success, "message": message])
        }
      }
    }

    // 已经移除了开机自动调用 shareLogIfExists 的代码，现在冷启动不会再自动弹窗了

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  /// 检查 go_stderr.log 是否存在且非空，存在就弹系统分享面板。
  /// - Parameters:
  ///   - auto: true 表示是启动时自动触发的（找不到/为空时只打印日志，不打扰用户）；
  ///           false 表示是用户手动点了测试按钮触发的（找不到/为空时也要通过 completion 告诉调用方，方便在 UI 上提示用户）。
  ///   - completion: (success, message)，用于反馈给 Flutter 侧弹 toast。
  private func shareLogIfExists(auto: Bool, completion: @escaping (Bool, String) -> Void) {
    let appGroup = "group.com.miaolian.myvpn" // 跟 Extension 里用的保持一致

    guard let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) else {
      let msg = "拿不到 App Group 容器路径"
      print("[Debug] \(msg)")
      completion(false, msg)
      return
    }
    let sourceURL = containerURL.appendingPathComponent("libbox/go_stderr.log")

    guard FileManager.default.fileExists(atPath: sourceURL.path) else {
      let msg = "日志文件不存在，还没有产生过连接日志"
      print("[Debug] \(msg): \(sourceURL.path)")
      completion(false, msg)
      return
    }

    // 判断文件是不是空的，空文件就不弹了
    if let attrs = try? FileManager.default.attributesOfItem(atPath: sourceURL.path),
       let size = attrs[.size] as? Int, size == 0 {
      let msg = "日志文件是空的"
      print("[Debug] \(msg)，跳过分享")
      completion(false, msg)
      return
    }

    guard let rootVC = UIApplication.shared.connectedScenes
      .compactMap({ $0 as? UIWindowScene })
      .flatMap({ $0.windows })
      .first(where: { $0.isKeyWindow })?.rootViewController else {
      let msg = "找不到 rootViewController，无法弹分享面板"
      print("[Debug] \(msg)")
      completion(false, msg)
      return
    }

    // 分享的是 App Group 容器里的原始文件（源头，不是 Documents 里的旧副本）
    let activityVC = UIActivityViewController(activityItems: [sourceURL], applicationActivities: nil)

    // iPad 需要指定弹出位置，否则会崩溃
    if let popover = activityVC.popoverPresentationController {
      popover.sourceView = rootVC.view
      popover.sourceRect = CGRect(x: rootVC.view.bounds.midX, y: rootVC.view.bounds.midY, width: 0, height: 0)
      popover.permittedArrowDirections = []
    }

    var topVC = rootVC
    while let presented = topVC.presentedViewController {
      topVC = presented
    }
    topVC.present(activityVC, animated: true)
    completion(true, "已弹出日志分享面板")
  }
}