// PacketTunnelExtension/PacketTunnelProvider.swift
import NetworkExtension
import Libbox
import Darwin
import Network

class PacketTunnelProvider: NEPacketTunnelProvider {

    private var commandServer: LibboxCommandServer?
    private var platformInterface: TunnelPlatformInterface?
    private var serverHandler: TunnelCommandServerHandler?
    private static var didSetup = false

    // 换成你自己的 App Group ID
    private let appGroup = "group.com.miaolian.myvpn"

    // 到期检测用：跟主 App(VpnTunnelPlugin) 约定好的 Darwin 通知名，
    // 必须跟 VpnTunnelPlugin.swift 里监听的字符串完全一致，改一处两边都要改。
    private let statusChangedDarwinNotification = "com.example.vpnAll.statusChanged"

    // 获取由 Keychain 永久持久化的设备唯一标识
    private var deviceId: String {
        return DeviceIdManager.getDeviceId()
    }

    // 心跳定时器：隧道建立成功后启动，定期查一次账号是否到期
    private var statusCheckTimer: DispatchSourceTimer?
    // 从 Flutter 侧 connect() 传进来的 api_base_url，供心跳请求使用
    private var apiBaseUrl: String = ""

    override func startTunnel(options: [String : NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        // 打印出当前设备编号，证明底层 Extension 已经能成功从 Keychain 读取 ID
        NSLog("[Tunnel] 开始执行 startTunnel MARKER-V3，设备编号(Keychain): %@", deviceId)

        setenv("GOMEMLIMIT", "30MiB", 1)
        setenv("GOGC", "20", 1)

        guard let conf = (protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration,
              let nodeJson = conf["node_json"] as? String else {
            completionHandler(NSError(domain: "PacketTunnel", code: 1, userInfo: [NSLocalizedDescriptionKey: "缺少 node_json 配置"]))
            return
        }
        self.apiBaseUrl = conf["api_base_url"] as? String ?? ""
        if self.apiBaseUrl.isEmpty {
            NSLog("[Tunnel] 警告：未收到 api_base_url，到期心跳检测将不会启动 MARKER-V3")
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

            let configJson = try SingBoxConfigBuilder.build(fromNodeJson: nodeJson, logFilePath: stderrLogPath)

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
                    self.startStatusCheckTimer()
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
        statusCheckTimer?.cancel()
        statusCheckTimer = nil
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
    
    // MARK: - 原生心跳与鉴权

    /// 隧道建立成功后启动，每隔一段时间查一次账号是否到期。
    /// 之前这个函数写好了但没人调用，导致 iOS 端到期后永远不会自动断开——这里补上定时触发。
    private func startStatusCheckTimer() {
        guard !apiBaseUrl.isEmpty else { return }
        statusCheckTimer?.cancel()

        let interval: TimeInterval = 60 // 每60秒查一次，按需调整
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .background))
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            NSLog("[Tunnel] 心跳定时器触发 MARKER-V3")
            self.checkUserStatus(apiBaseUrl: self.apiBaseUrl)
        }
        timer.resume()
        statusCheckTimer = timer
        NSLog("[Tunnel] 到期心跳检测已启动，间隔 %.0f 秒 MARKER-V3", interval)
    }

    /// 直接使用当前 Keychain 中的 deviceId，不依赖 Flutter 前台
    private func checkUserStatus(apiBaseUrl: String) {
        guard let url = URL(string: "\(apiBaseUrl)/api/v1/check_status") else {
            NSLog("[Tunnel] 心跳 URL 拼接失败，apiBaseUrl=%@ MARKER-V3", apiBaseUrl)
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 5.0
        
        // 使用本进程从 Keychain 取到的相同 ID
        let deviceIdSnapshot = self.deviceId
        let json: [String: Any] = ["device_id": deviceIdSnapshot]
        request.httpBody = try? JSONSerialization.data(withJSONObject: json)

        NSLog("[Tunnel] 心跳请求发出: %@ device_id=%@ MARKER-V3", url.absoluteString, deviceIdSnapshot)
        
        let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }

            // 关键修复：之前只在 403 分支才打日志，请求失败/超时/其他状态码
            // 全部静默，完全没法排查。现在无论什么结果都打一行，方便对着
            // go_stderr.log 确认心跳到底有没有真的打到服务器、返回的是什么。
            if let error = error {
                NSLog("[Tunnel] 心跳请求失败: %@ MARKER-V3", error.localizedDescription)
                return
            }
            guard let httpRes = response as? HTTPURLResponse else {
                NSLog("[Tunnel] 心跳请求无 HTTP 响应 MARKER-V3")
                return
            }
            let bodyPreview = data.flatMap { String(data: $0, encoding: .utf8) } ?? "<无body或非UTF8>"
            NSLog("[Tunnel] 心跳响应: status=%d body=%@ MARKER-V3", httpRes.statusCode, bodyPreview)

            // 关键修复：之前判断的是 HTTP 状态码本身(httpRes.statusCode == 403)，
            // 但这个后端的约定是 HTTP 永远返回 200，真正的业务状态码放在 JSON body
            // 的 "code" 字段里——跟安卓 CustomVpnService.kt、以及 api_service.dart
            // 里其他所有接口(recharge/checkin/getNode 等)的解析方式完全一致。
            // 之前的写法导致这个分支永远不会命中，无论到没到期都不会触发。
            guard httpRes.statusCode == 200, let data = data else {
                NSLog("[Tunnel] 心跳请求非 200 或无 body，跳过本次判断 MARKER-V3")
                return
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let bizCode = json["code"] as? Int else {
                NSLog("[Tunnel] 心跳响应 body 解析失败或缺少 code 字段 MARKER-V3")
                return
            }

            if bizCode == 403 {
                NSLog("[Tunnel] 心跳返回 403，账号服务已到期，正在自动断开连接...")
                // 关键修复：之前这里只断了隧道，从没告诉过主 App"是因为到期断的"，
                // 所以 Flutter 侧只会收到普通的 disconnected，不会弹到期提示。
                // 断开之前，先把 "EXPIRED" 写进 App Group 共享区，再发 Darwin 通知，
                // 让主 App 的 VpnTunnelPlugin 读到之后往 EventChannel 发 "EXPIRED"。
                self.notifyHostAppExpired()
                self.statusCheckTimer?.cancel()
                self.statusCheckTimer = nil
                self.cancelTunnelWithError(NSError(domain: "PacketTunnel", code: 403, userInfo: [NSLocalizedDescriptionKey: "服务已到期"]))
            } else if bizCode == 404 {
                // 正常情况下配合 DeviceIdManager 里去横杠的修复后，这个分支不应该再被触发。
                // 保留这个处理只是为了兜底：万一后端确实查不到这个 device_id
                // (比如账号被后台删除)，也应该断开，而不是放着不管、一直空转心跳。
                NSLog("[Tunnel] 心跳返回 404，用户不存在，正在自动断开连接...")
                self.notifyHostAppExpired()
                self.statusCheckTimer?.cancel()
                self.statusCheckTimer = nil
                self.cancelTunnelWithError(NSError(domain: "PacketTunnel", code: 404, userInfo: [NSLocalizedDescriptionKey: "用户不存在"]))
            }
        }
        task.resume()
    }

    /// 把到期状态写进 App Group 共享 UserDefaults，并发 Darwin 通知唤醒主 App 读取。
    /// Extension 进程和主 App 进程是隔离的，MethodChannel/EventChannel 在这里用不了，
    /// 只能靠 App Group + Darwin 通知这条路传消息。
    private func notifyHostAppExpired() {
        guard let defaults = UserDefaults(suiteName: appGroup) else {
            NSLog("[Tunnel] 无法打开 App Group 共享 UserDefaults：%@", appGroup)
            return
        }
        defaults.set("EXPIRED", forKey: "vpn_status")

        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(statusChangedDarwinNotification as CFString),
            nil, nil, true
        )
        NSLog("[Tunnel] 已写入 EXPIRED 状态并发出 Darwin 通知 MARKER-V3")
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
    // 关键修复：用 NWPathMonitor 给 sing-box 提供"当前默认物理接口"信息，
    // 否则 route.auto_detect_interface 拿不到任何接口，所有出站连接都会报
    // "no available network interface"。实现方式对齐官方 sing-box-for-apple
    // 客户端 Library/Network/ExtensionPlatformInterface.swift 的做法。
    private var nwMonitor: NWPathMonitor?

    init(provider: PacketTunnelProvider) {
        self.provider = provider
        super.init()
    }

    deinit {
        nwMonitor?.cancel()
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
        nwMonitor?.cancel()
        nwMonitor = nil
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
        guard let nwMonitor = nwMonitor else {
            throw NSError(domain: "LibboxPlatformInterface", code: 1, userInfo: [NSLocalizedDescriptionKey: "NWPathMonitor 尚未启动"])
        }
        let path = nwMonitor.currentPath
        if path.status == .unsatisfied {
            return TunnelNetworkInterfaceIterator([])
        }
        var interfaces: [LibboxNetworkInterface] = []
        for it in path.availableInterfaces {
            let interface = LibboxNetworkInterface()
            interface.name = it.name
            interface.index = Int32(it.index)
            switch it.type {
            case .wifi:
                interface.type = LibboxInterfaceTypeWIFI
            case .cellular:
                interface.type = LibboxInterfaceTypeCellular
            case .wiredEthernet:
                interface.type = LibboxInterfaceTypeEthernet
            default:
                interface.type = LibboxInterfaceTypeOther
            }
            interfaces.append(interface)
        }
        return TunnelNetworkInterfaceIterator(interfaces)
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
        guard let listener = listener else {
            return
        }
        let monitor = NWPathMonitor()
        nwMonitor = monitor
        // 用信号量保证：这个方法返回之前，至少已经把第一次的接口状态回调给了
        // sing-box（跟官方客户端做法一致），避免出现"服务已启动，但还没收到
        // 任何默认接口信息"的时间窗口。
        let semaphore = DispatchSemaphore(value: 0)
        monitor.pathUpdateHandler = { [weak self] path in
            self?.onUpdateDefaultInterface(listener, path)
            semaphore.signal()
            monitor.pathUpdateHandler = { path in
                self?.onUpdateDefaultInterface(listener, path)
            }
        }
        monitor.start(queue: DispatchQueue.global(qos: .utility))
        semaphore.wait()
    }

    private func onUpdateDefaultInterface(_ listener: LibboxInterfaceUpdateListenerProtocol, _ path: Network.NWPath) {
        guard path.status != .unsatisfied,
              let defaultInterface = path.availableInterfaces.first
        else {
            listener.updateDefaultInterface("", interfaceIndex: -1, isExpensive: false, isConstrained: false)
            return
        }
        listener.updateDefaultInterface(
            defaultInterface.name,
            interfaceIndex: Int32(defaultInterface.index),
            isExpensive: path.isExpensive,
            isConstrained: path.isConstrained
        )
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

// MARK: - NetworkInterfaceIterator

/// getInterfaces() 需要返回的迭代器实现，写法对齐官方 sing-box-for-apple 客户端。
private class TunnelNetworkInterfaceIterator: NSObject, LibboxNetworkInterfaceIteratorProtocol {
    private var iterator: IndexingIterator<[LibboxNetworkInterface]>
    private var nextValue: LibboxNetworkInterface?

    init(_ array: [LibboxNetworkInterface]) {
        iterator = array.makeIterator()
    }

    func hasNext() -> Bool {
        nextValue = iterator.next()
        return nextValue != nil
    }

    func next() -> LibboxNetworkInterface? {
        nextValue
    }
}