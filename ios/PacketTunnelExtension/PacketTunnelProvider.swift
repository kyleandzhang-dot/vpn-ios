import NetworkExtension
import Libbox
import Darwin

class PacketTunnelProvider: NEPacketTunnelProvider {

    private var service: LibboxBoxService?
    private var platformInterface: TunnelPlatformInterface?

    override func startTunnel(options: [String : NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        guard let conf = (protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration,
              let nodeJson = conf["node_json"] as? String else {
            completionHandler(NSError(domain: "PacketTunnel", code: 1, userInfo: [NSLocalizedDescriptionKey: "缺少 node_json 配置"]))
            return
        }

        do {
            let configJson = try SingBoxConfigBuilder.build(fromNodeJson: nodeJson)

            let interface = TunnelPlatformInterface(provider: self)
            self.platformInterface = interface

            var err: NSError?
            guard let service = LibboxNewService(configJson, interface, &err) else {
                if let err = err {
                    throw err
                }
                throw NSError(domain: "PacketTunnel", code: 2, userInfo: [NSLocalizedDescriptionKey: "创建 Libbox 内核服务失败"])
            }

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

private class TunnelPlatformInterface: NSObject, LibboxPlatformInterfaceProtocol {
    private weak var provider: PacketTunnelProvider?

    init(provider: PacketTunnelProvider) {
        self.provider = provider
        super.init()
    }

    func usePlatformAutoDetectControl() -> Bool {
        return false
    }

    func autoDetectControl(_ fd: Int32) throws {
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

    // 适配 v1.10.7：新旧接口名同时保留
    func useGetter() -> Bool {
        return false
    }

    func usePlatformInterfaceGetter() -> Bool {
        return false
    }

    func getInterfaces() throws -> LibboxNetworkInterfaceIteratorProtocol {
        throw NSError(domain: "LibboxPlatformInterface", code: 1, userInfo: [NSLocalizedDescriptionKey: "iOS 平台不需要接口迭代器"])
    }

    // 系统代理适配
    func usePlatformSystemProxy() -> Bool {
        return false
    }

    func setSystemProxy(_ enabled: Bool, server: String?, port: Int32) throws {
    }

    func clearSystemProxy() throws {
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