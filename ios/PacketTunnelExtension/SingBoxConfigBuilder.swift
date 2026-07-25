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
        NSLog("[Tunnel] 开始执行 startTunnel MARKER-V3")

        setenv("GOMEMLIMIT", "30MiB", 1)
        setenv("GOGC", "20", 1)

        guard let conf = (protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration,
              let nodeJson = conf["node_json"] as? String else {
            completionHandler(NSError(domain: "PacketTunnel", code: 1, userInfo: [NSLocalizedDescriptionKey: "缺少 node_json 配置"]))
            return
        }

        do {
            guard let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) else {
                throw NSError(domain: "PacketTunnel", code: 10, userInfo: [NSLocalizedDescriptionKey: "无法获取 App Group 目录"])
            }
            let basePath = containerURL.appendingPathComponent("libbox").path
            try? FileManager.default.createDirectory(atPath: basePath, withIntermediateDirectories: true)

            // 诊断用：把 stderr 重定向到文件——Go 的 panic / fatal error 默认打印到 stderr，
            // 系统崩溃报告器抓不到这些文字，但这样能把它落盘保存下来。
            // 关键修复：这一步必须在 SingBoxConfigBuilder.build() 之前执行，否则
            // build() 内部所有 NSLog（协议识别、生成的完整配置 JSON 等）都会在
            // 重定向生效之前就打印完了，永远不会出现在 go_stderr.log 里。
            let stderrLogPath = (basePath as NSString).appendingPathComponent("go_stderr.log")
            freopen(stderrLogPath, "a+", stderr)
            NSLog("[Tunnel] stderr 已重定向到: %@ MARKER-V3", stderrLogPath)

            let configJson = try SingBoxConfigBuilder.build(fromNodeJson: nodeJson)

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

            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self = self, let server = self.commandServer else { return }
                do {
                    // ⚠️ 关键修复：sing-box 的 StartOrReloadService 内部直接访问
                    // options.AutoRedirect 等字段，没有做 nil 判断。传 nil 会导致
                    // Go 侧空指针崩溃（panic: invalid memory address or nil pointer dereference）。
                    let overrideOptions = LibboxOverrideOptions()
                    NSLog("[Tunnel] === 即将调用 startOrReloadService，options 非空: %@ MARKER-V3 ===", overrideOptions)
                    try server.startOrReloadService(configJson, options: overrideOptions)
                    NSLog("[Tunnel] Libbox 服务启动成功！MARKER-V3")
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

    // utun 相关常量:PF_SYSTEM socket 族里 SYSPROTO_CONTROL 的 getsockopt 选项。
    // 这是 XNU 内核层面的稳定 ABI,不依赖 NEPacketTunnelFlow 的任何私有属性,
    // 是 WireGuard / sing-box 官方客户端等主流实现都在用的做法。
    private static let SYSPROTO_CONTROL: Int32 = 2
    private static let UTUN_OPT_IFNAME: Int32 = 2
    private static let maxScanFd: Int32 = 1024

    /// 遍历当前进程打开的文件描述符,找到那个是 utun 接口的 fd。
    /// 找不到返回 nil,并打印扫描了多少个 fd 方便排查。
    fileprivate func findTunFileDescriptor() -> Int32? {
        var buffer = [UInt8](repeating: 0, count: 64)
        var scanned = 0
        for fd: Int32 in 0...Self.maxScanFd {
            var len = socklen_t(buffer.count)
            let result = buffer.withUnsafeMutableBytes { ptr -> Int32 in
                getsockopt(fd, Self.SYSPROTO_CONTROL, Self.UTUN_OPT_IFNAME, ptr.baseAddress, &len)
            }
            if result == 0 {
                scanned += 1
                let name = String(cString: buffer)
                if name.hasPrefix("utun") {
                    NSLog("[Tunnel] 找到 utun 接口: %@，fd=%d MARKER-V3", name, fd)
                    return fd
                }
            }
        }
        NSLog("[Tunnel] 未找到 utun fd，共探测到 %d 个 SYSPROTO_CONTROL socket MARKER-V3", scanned)
        return nil
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
                if let fd = self.findTunFileDescriptor() {
                    tunFd = fd
                } else {
                    NSLog("[Tunnel] 未能获取 TUN fd，请检查系统版本兼容性 MARKER-V3")
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