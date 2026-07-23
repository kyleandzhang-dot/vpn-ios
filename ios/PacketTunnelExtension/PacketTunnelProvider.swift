import NetworkExtension
import Libbox
import Darwin

class PacketTunnelProvider: NEPacketTunnelProvider {

    // 修复 Error #1: 在最新版 libbox 中，服务类型已从 LibboxBoxServiceProtocol 改为 LibboxBoxService 类
    private var service: LibboxBoxService?
    private var platformInterface: TunnelPlatformInterface?

    override func startTunnel(options: [String : NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        // 从主 App 传入的 providerConfiguration 提取 node_json
        guard let conf = (protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration,
              let nodeJson = conf["node_json"] as? String else {
            completionHandler(NSError(domain: "PacketTunnel", code: 1, userInfo: [NSLocalizedDescriptionKey: "缺少 node_json 配置"]))
            return
        }

        do {
            // 使用你的 SingBoxConfigBuilder 转换为 sing-box 标准 JSON 配置
            let configJson = try SingBoxConfigBuilder.build(fromNodeJson: nodeJson)

            let interface = TunnelPlatformInterface(provider: self)
            self.platformInterface = interface

            // 修复 Error #4: 使用干净的标准初始化，不需要传递额外废弃参数
            let service = try LibboxNewService(configJson, interface)
            try service.start()
            self.service = service

            completionHandler(nil)
        } catch {
            NSLog("[Tunnel] 启动失败: %@", error.localizedDescription)
            completionHandler(error)
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        do {
            try service?.close()
        } catch {
            NSLog("[Tunnel] 关闭异常: %@", error.localizedDescription)
        }
        service = nil
        platformInterface = nil
        completionHandler()
    }

    // 修复 Error #5: 不再尝试去强转容易报错的 LibboxRoutePrefixIteratorProtocol 迭代器，
    // 直接针对我们在 SingBoxConfigBuilder 里配置好的 172.19.0.1/30 建立干净的全局网卡
    fileprivate func openTun(options: LibboxTunOptions) -> Int32 {
        var tunFd: Int32 = -1
        let semaphore = DispatchSemaphore(value: 0)

        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "240.0.0.1")
        settings.mtu = 9000

        let ipv4 = NEIPv4Settings(addresses: ["172.19.0.1"], subnetMasks: ["255.255.255.252"])
        ipv4.includedRoutes = [NEIPv4Route.default()]
        settings.ipv4Settings = ipv4

        let dns = NEDNSSettings(servers: ["1.1.1.1", "8.8.8.8"])
        dns.matchDomains = [""]
        settings.dnsSettings = dns

        setTunnelNetworkSettings(settings) { [weak self] error in
            if let error = error {
                NSLog("[Tunnel] 设置网络参数失败: %@", error.localizedDescription)
            } else if let self = self {
                // 利用 KVC 取出 iOS 底层实际生成的虚拟网卡 Socket 文件描述符交给 Go 内核
                if let fd = self.packetFlow.value(forKeyPath: "socket.fileDescriptor") as? Int32 {
                    tunFd = fd
                }
            }
            semaphore.signal()
        }

        semaphore.wait()
        return tunFd
    }
}

// 修复 Error #3: 严格按照 v1.11.0 的新 API 要求实现 LibboxPlatformInterfaceProtocol
private class TunnelPlatformInterface: NSObject, LibboxPlatformInterfaceProtocol {
    private weak var provider: PacketTunnelProvider?

    init(provider: PacketTunnelProvider) {
        self.provider = provider
        super.init()
    }

    func usePlatformAutoDetectInterfaceControl() -> Bool {
        return false
    }

    func autoDetectInterfaceControl(_ fd: Int32) throws {
    }

    func openTun(_ options: LibboxTunOptions?) throws -> Int32 {
        guard let provider = provider, let options = options else {
            return -1
        }
        return provider.openTun(options: options)
    }

    func useProcFS() -> Bool {
        return false
    }

    func findConnectionOwner(_ ipProtocol: Int32, sourceAddress: String?, sourcePort: Int32, destinationAddress: String?, destinationPort: Int32) throws -> Int32 {
        return 0
    }

    func packageName(byUid uid: Int32) throws -> String {
        return ""
    }

    // 修复 Error #2: 方法名从 uidByPackageName 对齐修改为最新的 uid(byPackageName:ret0_:)
    func uid(byPackageName packageName: String?, ret0_: UnsafeMutablePointer<Int32>?) throws -> Bool {
        return false
    }

    func usePlatformDefaultInterfaceMonitor() -> Bool {
        return false
    }

    func startDefaultInterfaceMonitor(_ listener: LibboxInterfaceUpdateListenerProtocol?) throws {
    }

    func closeDefaultInterfaceMonitor(_ listener: LibboxInterfaceUpdateListenerProtocol?) throws {
    }

    func usePlatformInterfaceGetter() -> Bool {
        return false
    }

    func getInterfaces() throws -> LibboxInterfaceIteratorProtocol? {
        return nil
    }

    func underNetworkExtension() -> Bool {
        return true
    }

    func includeAllNetworks() -> Bool {
        return false
    }

    func clearDNSCache() {
    }

    func readWIFIState() -> LibboxWIFIState? {
        return nil
    }

    func writeLog(_ message: String?) {
        if let msg = message {
            NSLog("[Libbox] %@", msg)
        }
    }
}