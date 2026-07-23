import NetworkExtension
import Libbox
import os.log

// 放进 PacketTunnel Extension target
//
// ⚠️ 注意:Libbox 的具体 protocol/方法签名会随 sing-box 版本变化。
// 如果编译报“找不到某方法/协议”,在 Xcode 里 Cmd+click `Libbox` 模块,
// 打开生成的接口(Generated Interface)对照实际签名微调,思路不用变。
// 这里的实现对应的是 sing-box 官方 sing-box-for-apple 项目里
// Extension/PacketTunnelProvider.swift 的通用写法。

class PacketTunnelProvider: NEPacketTunnelProvider {

    private var boxService: LibboxBoxServiceProtocol?
    private let appGroup = "group.com.miaolian.myvpn.shared" // TODO: 换成你自己注册的 App Group id

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        guard let proto = protocolConfiguration as? NETunnelProviderProtocol,
              let nodeJson = proto.providerConfiguration?["node_json"] as? String else {
            completionHandler(NSError(domain: "PacketTunnel", code: 1,
                                       userInfo: [NSLocalizedDescriptionKey: "缺少 node_json"]))
            return
        }

        do {
            // 1. 把业务侧 node_json 转成 sing-box 认识的配置 JSON
            let singBoxConfig = try SingBoxConfigBuilder.build(fromNodeJson: nodeJson)

            // 2. 起 Libbox 服务,把自己(PlatformInterface)传进去
            let platformInterface = TunnelPlatformInterface(tunnel: self)
            let service = try LibboxNewService(singBoxConfig, platformInterface)
            self.boxService = service

            try service.start()

            // 3. 通知 App 侧已连接(通过共享 UserDefaults + Darwin 通知,见下方 notifyStatus)
            notifyStatus("CONNECTED")
            completionHandler(nil)
        } catch {
            os_log("启动隧道失败: %{public}@", String(describing: error))
            notifyStatus("DISCONNECTED")
            completionHandler(error)
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        do {
            try boxService?.close()
        } catch {
            os_log("关闭隧道出错: %{public}@", String(describing: error))
        }
        boxService = nil
        notifyStatus("DISCONNECTED")
        completionHandler()
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        // 主 App 可以通过 session.sendProviderMessage 发指令过来,预留
        completionHandler?(nil)
    }

    // 把状态写进 App Group 共享的 UserDefaults,并发一个 Darwin 通知唤醒主 App 侧监听。
    // 主 App 用 NEVPNStatusDidChange 只能拿到 connect/disconnect/connecting/reasserting 这几种系统状态,
    // 拿不到我们自定义的 "EXPIRED"(欠费/到期),所以额外走这条通道。
    private func notifyStatus(_ status: String) {
        let defaults = UserDefaults(suiteName: appGroup)
        defaults?.set(status, forKey: "vpn_status")
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName("com.example.vpnAll.statusChanged" as CFString),
            nil, nil, true
        )
    }
}

// MARK: - Libbox PlatformInterface 实现

// Libbox 需要一个实现了它平台接口协议的对象,用来做 TUN fd 设置、日志、网络信息查询等。
// 协议名称/方法数量随版本可能有出入,以 Xcode 里 Libbox 模块的实际定义为准,
// 缺哪个方法编译器会直接报错,照着补空实现或按需实现即可。
final class TunnelPlatformInterface: NSObject, LibboxPlatformInterfaceProtocol {

    private weak var tunnel: NEPacketTunnelProvider?

    init(tunnel: NEPacketTunnelProvider) {
        self.tunnel = tunnel
    }

    // 把 sing-box 算好的 TUN 参数(地址/路由/DNS/MTU)转成 NEPacketTunnelNetworkSettings 下发给系统
    func openTun(_ options: LibboxTunOptionsProtocol?, ret0_: UnsafeMutablePointer<Int32>?) throws {
        guard let options = options, let tunnel = tunnel else { return }

        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")

        var ipv4Addresses: [String] = []
        var ipv4SubnetMasks: [String] = []
        // Libbox 提供的 options 具体取值方法名以生成接口为准,大意如下:
        if let inet4Address = try? options.getInet4Address() {
            ipv4Addresses.append(inet4Address)
            ipv4SubnetMasks.append("255.255.255.0")
        }
        let ipv4Settings = NEIPv4Settings(addresses: ipv4Addresses, subnetMasks: ipv4SubnetMasks)
        ipv4Settings.includedRoutes = [NEIPv4Route.default()]
        settings.ipv4Settings = ipv4Settings

        let dnsSettings = NEDNSSettings(servers: ["1.1.1.1", "8.8.8.8"])
        settings.dnsSettings = dnsSettings

        settings.mtu = NSNumber(value: try options.getMTU())

        let semaphore = DispatchSemaphore(value: 0)
        var setError: Error?
        tunnel.setTunnelNetworkSettings(settings) { error in
            setError = error
            semaphore.signal()
        }
        semaphore.wait()
        if let setError = setError { throw setError }

        ret0_?.pointee = tunnel.packetFlow.value(forKeyPath: "socket.fileDescriptor") as? Int32 ?? -1
    }

    func writeLog(_ message: String?) {
        os_log("[sing-box] %{public}@", message ?? "")
    }

    func useProcFS() -> Bool { false }

    func findConnectionOwner(_ ipProtocol: Int32, sourceAddress: String?, sourcePort: Int32, destinationAddress: String?, destinationPort: Int32, ret0_: UnsafeMutablePointer<Int32>?) throws {
        ret0_?.pointee = -1
    }

    func packageName(byUid uid: Int32, ret0_: AutoreleasingUnsafeMutablePointer<NSString?>?) throws {}

    func uidByPackageName(_ packageName: String?, ret0_: UnsafeMutablePointer<Int32>?) throws {
        ret0_?.pointee = -1
    }

    func usePlatformDefaultInterfaceMonitor() -> Bool { true }

    func startDefaultInterfaceMonitor(_ listener: LibboxInterfaceUpdateListenerProtocol?) throws {}
    func closeDefaultInterfaceMonitor(_ listener: LibboxInterfaceUpdateListenerProtocol?) throws {}
    func getInterfaces() throws -> LibboxNetworkInterfaceIteratorProtocol { fatalError("按需实现") }

    func underNetworkExtension() -> Bool { true }
    func includeAllNetworks() -> Bool { true }
    func clearDNSCache() {}
    func readWIFIState() -> LibboxWIFIState? { nil }
    func systemCertificates() -> LibboxStringIteratorProtocol? { nil }
}