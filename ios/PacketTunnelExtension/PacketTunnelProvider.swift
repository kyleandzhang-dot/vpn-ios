// PacketTunnelExtension/PacketTunnelProvider.swift
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
        NSLog("[Tunnel] 开始执行 startTunnel")
        
        // ⚠️ 核心防崩修复 1：苹果对 VPN 后台内存限制极严(~15M-30M)，
        // 必须在 Libbox 初始化前强制限制 Golang 内存分配，否则秒被 iOS 系统的 Jetsam (OOM) 强杀！
        setenv("GOMEMLIMIT", "30MiB", 1)
        setenv("GOGC", "20", 1)

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
            
            // ⚠️ 核心防崩修复 2：将服务启动放入后台线程！
            // 避免 startOrReloadService 同步调回 openTun 时与 Main Thread 产生信号量死锁
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self = self, let server = self.commandServer else { return }
                do {
                    try server.startOrReloadService(configJson, options: nil as LibboxOverrideOptions?)
                    NSLog("[Tunnel] Libbox 服务启动成功！")
                    DispatchQueue.main.async {
                        completionHandler(nil)
                    }
                } catch {
                    NSLog("[Tunnel] startOrReloadService 失败: %@", error.localizedDescription)
                    DispatchQueue.main.async {
                        completionHandler(error)
                    }
                }
            }
        } catch {
            NSLog("[Tunnel] 启动失败: %@", error.localizedDescription)
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
                // ⚠️ 核心防崩修复 3：安全反射获取 socket fd[cite: 6]，
                // 避免直接 KVC 在现代 iOS 上触发 NSUnknownKeyException 导致进程瞬间秒崩！
                if self.packetFlow.responds(to: NSSelectorFromString("socket")) {
                    if let socket = self.packetFlow.value(forKey: "socket") as? NSObject {
                        if socket.responds(to: NSSelectorFromString("fileDescriptor")) {
                            if let fd = socket.value(forKey: "fileDescriptor") as? Int32 {
                                tunFd = fd
                            }
                        }
                    }
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