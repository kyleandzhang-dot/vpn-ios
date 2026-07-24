import NetworkExtension
import Libbox
import Darwin

class PacketTunnelProvider: NEPacketTunnelProvider {

    private var commandServer: LibboxCommandServer?
    private var platformInterface: TunnelPlatformInterface?
    private var serverHandler: TunnelCommandServerHandler?
    private static var didSetup = false

    // 换成你自己的 App Group ID
    private let appGroup = "group.com.miaolian.myvpn"

    override func startTunnel(options: [String : NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        guard let conf = (protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration,
              let nodeJson = conf["node_json"] as? String else {
            completionHandler(NSError(domain: "PacketTunnel", code: 1, userInfo: [NSLocalizedDescriptionKey: "缺少 node_json 配置"]))
            return
        }

        do {
            let configJson = try SingBoxConfigBuilder.build(fromNodeJson: nodeJson)

            guard let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) else {
                throw NSError(domain: "PacketTunnel", code: 10, userInfo: [NSLocalizedDescriptionKey: "无法获取 App Group 目录"])
            }
            let basePath = containerURL.appendingPathComponent("libbox").path
            try? FileManager.default.createDirectory(atPath: basePath, withIntermediateDirectories: true)

            // 全局 setup 只需要做一次(整个 extension 进程生命周期内)
            if !PacketTunnelProvider.didSetup {
                let setupOptions = LibboxSetupOptions()
                setupOptions.basePath = basePath
                setupOptions.workingPath = basePath
                setupOptions.tempPath = NSTemporaryDirectory()
                var setupErr: NSError?
                if !LibboxSetup(setupOptions, &setupErr) {
                    throw setupErr ?? NSError(domain: "PacketTunnel", code: 11, userInfo: [NSLocalizedDescriptionKey: "LibboxSetup 失败"])
                }
                PacketTunnelProvider.didSetup = true
            }

            let interface = TunnelPlatformInterface(provider: self)
            self.platformInterface = interface

            let handler = TunnelCommandServerHandler()
            self.serverHandler = handler

            var err: NSError?
            guard let server = LibboxNewCommandServer(handler, interface, &err) else {
                throw err ?? NSError(domain: "PacketTunnel", code: 2, userInfo: [NSLocalizedDescriptionKey: "创建 CommandServer 失败"])
            }
            self.commandServer = server

            try server.start()
            
            // 关键修复：使用新版本标准的 LibboxStartOptions，解决了 nil 无法推断类型的问题
            try server.startOrReloadService(configJson, options: nil as LibboxOverrideOptions?)
        } catch {
            // ⚠️ 打印出完整的原始 JSON 和明确的错误中文原因
            NSLog("[Tunnel致命错误] 启动失败！原始数据: %@ | 错误描述: %@", nodeJson, error.localizedDescription)
            completionHandler(error)
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        do {
            try commandServer?.closeService()
        } catch {
            NSLog("[Tunnel] 停止服务异常: %@", error.localizedDescription)
        }
        commandServer?.close()
        commandServer = nil
        platformInterface = nil
        serverHandler = nil
        completionHandler()
    }

    fileprivate func openTun(options: LibboxTunOptionsProtocol) -> Int32 {
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

// MARK: - CommandServerHandler

private class TunnelCommandServerHandler: NSObject, LibboxCommandServerHandlerProtocol {
    func connectSSHAgent(_ ret0_: UnsafeMutablePointer<Int32>?) throws {
        ret0_?.pointee = -1
    }

    func getSystemProxyStatus() throws -> LibboxSystemProxyStatus {
        throw NSError(domain: "Libbox", code: 1, userInfo: [NSLocalizedDescriptionKey: "iOS 平台不支持获取系统代理状态"])
    }

    func serviceReload() throws {
    }

    func serviceStop() throws {
    }

    func setSystemProxyEnabled(_ enabled: Bool) throws {
    }

    func triggerNativeCrash() throws {
    }

    func writeDebugMessage(_ message: String?) {
        if let msg = message {
            NSLog("[Libbox] %@", msg)
        }
    }
}

// MARK: - PlatformInterface

private class TunnelPlatformInterface: NSObject, LibboxPlatformInterfaceProtocol {
    private weak var provider: PacketTunnelProvider?

    init(provider: PacketTunnelProvider) {
        self.provider = provider
        super.init()
    }

    func lookupSFTPServer(_ error: NSErrorPointer) -> String {
        return ""
    }

    func readSystemSSHHostKey(_ error: NSErrorPointer) -> String {
        return ""
    }

    func autoDetectControl(_ fd: Int32) throws {
    }

    func checkPlatformShell() throws {
    }

    func clearDNSCache() {
    }

    func closeDefaultInterfaceMonitor(_ listener: LibboxInterfaceUpdateListenerProtocol?) throws {
    }

    func closeNeighborMonitor(_ listener: LibboxNeighborUpdateListenerProtocol?) throws {
    }

    func createBridge(_ options: LibboxBridgeOptions?) throws -> LibboxBridgeSessionProtocol {
        throw NSError(domain: "LibboxPlatformInterface", code: 1, userInfo: [NSLocalizedDescriptionKey: "iOS 不支持创建 Bridge"])
    }

    func findConnectionOwner(_ ipProtocol: Int32, sourceAddress: String?, sourcePort: Int32, destinationAddress: String?, destinationPort: Int32) throws -> LibboxConnectionOwner {
        throw NSError(domain: "LibboxPlatformInterface", code: 1, userInfo: [NSLocalizedDescriptionKey: "iOS 不支持 ConnectionOwner 查询"])
    }

    func getInterfaces() throws -> LibboxNetworkInterfaceIteratorProtocol {
        throw NSError(domain: "LibboxPlatformInterface", code: 1, userInfo: [NSLocalizedDescriptionKey: "iOS 平台不需要接口迭代器"])
    }

    func includeAllNetworks() -> Bool {
        return false
    }

    func localDNSTransport() -> LibboxLocalDNSTransportProtocol? {
        return nil
    }

    func lookupSFTPServer() throws -> String {
        return ""
    }

    func lookupUser(_ username: String?) throws -> LibboxPlatformUser {
        throw NSError(domain: "LibboxPlatformInterface", code: 1, userInfo: [NSLocalizedDescriptionKey: "iOS 不支持 User 查询"])
    }

    func openShellSession(_ user: LibboxPlatformUser?, command: String?, environ: LibboxStringIteratorProtocol?, term: String?, rows: Int32, cols: Int32) throws -> LibboxShellSessionProtocol {
        throw NSError(domain: "LibboxPlatformInterface", code: 1, userInfo: [NSLocalizedDescriptionKey: "iOS 不支持 Shell Session"])
    }

    func openTun(_ options: LibboxTunOptionsProtocol?, ret0_: UnsafeMutablePointer<Int32>?) throws {
        guard let provider = provider, let options = options else {
            throw NSError(domain: "LibboxPlatformInterface", code: 1, userInfo: [NSLocalizedDescriptionKey: "openTun 参数无效"])
        }
        let fd = provider.openTun(options: options)
        guard fd >= 0 else {
            throw NSError(domain: "LibboxPlatformInterface", code: 2, userInfo: [NSLocalizedDescriptionKey: "打开 TUN 失败"])
        }
        ret0_?.pointee = fd
    }

    func readSystemSSHHostKey() throws -> String {
        return ""
    }

    func readWIFIState() -> LibboxWIFIState? {
        return nil
    }

    func registerMyInterface(_ name: String?) {
    }

    func send(_ notification: LibboxNotification?) throws {
    }

    func startDefaultInterfaceMonitor(_ listener: LibboxInterfaceUpdateListenerProtocol?) throws {
    }

    func startNeighborMonitor(_ listener: LibboxNeighborUpdateListenerProtocol?) throws {
    }

    func tailscaleHostname() -> String {
        return ""
    }

    func underNetworkExtension() -> Bool {
        return true
    }

    func usePlatformAutoDetectControl() -> Bool {
        return false
    }

    func usePlatformBridge() -> Bool {
        return false
    }

    func usePlatformShell() -> Bool {
        return false
    }

    func useProcFS() -> Bool {
        return false
    }
}
