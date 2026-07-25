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

    let result = super.application(application, didFinishLaunchingWithOptions: launchOptions)

    // 延迟 1.5 秒，等窗口和根视图控制器准备好之后，
    // 自动把日志文件通过系统分享面板弹出来——不依赖「文件」App。
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
      self.shareLogIfExists()
    }

    return result
  }

  private func shareLogIfExists() {
    let appGroup = "group.com.miaolian.myvpn" // 跟 Extension 里用的保持一致

    guard let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) else {
      print("[Debug] 拿不到 App Group 容器路径")
      return
    }
    let sourceURL = containerURL.appendingPathComponent("libbox/go_stderr.log")

    guard FileManager.default.fileExists(atPath: sourceURL.path) else {
      print("[Debug] 日志文件不存在: \(sourceURL.path)")
      return
    }

    // 判断文件是不是空的，空文件就不弹了
    if let attrs = try? FileManager.default.attributesOfItem(atPath: sourceURL.path),
       let size = attrs[.size] as? Int, size == 0 {
      print("[Debug] 日志文件是空的，跳过分享")
      return
    }

    guard let rootVC = UIApplication.shared.connectedScenes
      .compactMap({ ($0 as? UIWindowScene)?.keyWindow })
      .first?.rootViewController else {
      print("[Debug] 找不到 rootViewController，无法弹分享面板")
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
  }
}