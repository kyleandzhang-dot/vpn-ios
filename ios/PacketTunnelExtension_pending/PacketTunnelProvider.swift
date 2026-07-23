import NetworkExtension
import Libbox

class PacketTunnelProvider: NEPacketTunnelProvider {
  private var boxService: LibboxBoxService?

  override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
    guard let nodeJson = options?["node_json"] as? String else {
      completionHandler(NSError(domain: "PacketTunnelProvider", code: 1, userInfo: [NSLocalizedDescriptionKey: "缺少 node_json"]))
      return
    }

    // TODO: 把 nodeJson（VLESS+Reality 参数）转换成 sing-box 的 config schema
    // 参照 buildSingBoxVlessConfig(...) —— 需要新写一个函数，逻辑对应
    // Android 那边的 buildVlessConfig，但字段名和结构要换成 sing-box 格式
    let configJson = buildSingBoxConfig(fromNodeJson: nodeJson)

    let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
    let ipv4Settings = NEIPv4Settings(addresses: ["10.0.0.2"], subnetMasks: ["255.255.255.0"])
    ipv4Settings.includedRoutes = [NEIPv4Route.default()]
    settings.ipv4Settings = ipv4Settings

    let ipv6Settings = NEIPv6Settings(addresses: ["fd00:1:1:1::2"], networkPrefixLengths: [64])
    ipv6Settings.includedRoutes = [NEIPv6Route.default()]
    settings.ipv6Settings = ipv6Settings

    settings.mtu = 1500

    setTunnelNetworkSettings(settings) { [weak self] error in
      guard let self = self else { return }
      if let error = error {
        completionHandler(error)
        return
      }

      do {
        let baseDir = self.documentsDirectory()
        LibboxSetup(baseDir, baseDir, NSTemporaryDirectory(), false)

        let platformInterface = SingBoxPlatformInterface(packetFlow: self.packetFlow)
        self.boxService = try LibboxNewService(configJson, platformInterface)
        try self.boxService?.start()
        completionHandler(nil)
      } catch {
        completionHandler(error)
      }
    }
  }

  override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
    try? boxService?.close()
    boxService = nil
    completionHandler()
  }

  private func documentsDirectory() -> String {
    let containerURL = FileManager.default.containerURL(
      forSecurityApplicationGroupIdentifier: "group.com.miaolian.myvpn"
    )
    return containerURL?.path ?? NSTemporaryDirectory()
  }

  // TODO: 这个函数需要参照 Android 端 buildVlessConfig，
  // 把字段名换成 sing-box 的 schema（outbounds.type = "vless"，
  // tls.reality.public_key 等），具体字段对照见之前的说明
  private func buildSingBoxConfig(fromNodeJson nodeJson: String) -> String {
    // TODO: 实现 JSON 转换逻辑
    return nodeJson
  }
}

// PlatformInterface 的具体实现——这部分强烈建议直接参照
// sing-box 官方仓库 SFI (sing-box-for-apple) 项目里的真实实现，
// 这里先给一个骨架，真正可用的版本需要对照官方源码补全
class SingBoxPlatformInterface: NSObject {
  let packetFlow: NEPacketTunnelFlow

  init(packetFlow: NEPacketTunnelFlow) {
    self.packetFlow = packetFlow
  }

  // TODO: 实现 LibboxPlatformInterfaceProtocol 要求的所有方法
  // 包括 readPackets / writePackets 桥接到 packetFlow.readPackets(completionHandler:) 等
}