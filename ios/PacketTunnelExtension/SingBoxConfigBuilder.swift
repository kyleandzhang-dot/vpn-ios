// PacketTunnelExtension/SingBoxConfigBuilder.swift
import Foundation

enum SingBoxConfigBuilder {

    struct BuildError: Error, LocalizedError, CustomNSError {
        let message: String
        var errorDescription: String? { message }
        var errorCode: Int { 1 }
        var errorUserInfo: [String : Any] { [NSLocalizedDescriptionKey: message] }
    }

    static func build(fromNodeJson nodeJson: String, logFilePath: String? = nil) throws -> String {
        NSLog("[SingBoxBuilder] 开始解析节点配置，字符长度: %d", nodeJson.count)

        guard let data = nodeJson.data(using: .utf8),
              let node = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let msg = "node_json 不是合法的 JSON 对象。收到内容前50字符: \(String(nodeJson.prefix(50)))"
            NSLog("[SingBoxBuilder 致命错误] %@", msg)
            throw BuildError(message: msg)
        }

        // 1. 【终极兼容】如果传过来的已经是完整 sing-box 配置文件，直接放行！
        if node["outbounds"] != nil && node["inbounds"] != nil {
            NSLog("[SingBoxBuilder] 检测到已经是完整 sing-box 配置文件，跳过转换直接使用！")
            return nodeJson
        }

        // 2. 识别协议
        let rawProtocol = (node["protocol"] as? String) ?? guessProtocol(node)
        let protocolType = rawProtocol.lowercased()
        NSLog("[SingBoxBuilder] 识别到协议类型: %@", protocolType)

        let outbound: [String: Any]
        do {
            switch protocolType {
            case "vmess":
                outbound = try buildVmessOutbound(node)
            case "vless":
                outbound = try buildVlessOutbound(node)
            case "trojan":
                outbound = try buildTrojanOutbound(node)
            case "shadowsocks", "ss":
                outbound = try buildShadowsocksOutbound(node)
            default:
                let msg = "暂不支持的协议类型: '\(protocolType)'。请检查节点 JSON 是否包含 id/uuid/v/password 等特征。"
                NSLog("[SingBoxBuilder 致命错误] %@", msg)
                throw BuildError(message: msg)
            }
        } catch let error as BuildError {
            NSLog("[SingBoxBuilder 致命错误] %@", error.message)
            throw error
        } catch {
            NSLog("[SingBoxBuilder 致命错误] %@", error.localizedDescription)
            throw error
        }

        // 3. 组装标准 config.json
        // 关键修复：之前只设置了 "level":"info"，sing-box 默认把这部分结构化运行日志
        // 写去 stdout（不是 stderr），而我们只重定向了 stderr，导致这些日志一直
        // 进了"黑洞"。现在显式指定 "output" 路径，让 sing-box 直接写文件，
        // 不再依赖猜测它到底写去 stdout 还是 stderr。
        var logConfig: [String: Any] = ["level": "info", "timestamp": true]
        if let logFilePath = logFilePath {
            logConfig["output"] = logFilePath
        }

        let config: [String: Any] = [
            "log": logConfig,
            "dns": [
                "servers": [
                    ["tag": "dns-remote", "type": "udp", "server": "1.1.1.1", "detour": "proxy"],
                    ["tag": "dns-local", "type": "udp", "server": "223.5.5.5"]
                ],
                // 关键修复：如果代理服务器地址填的是域名，出站(outbound)自己去连接
                // 服务器之前得先解析这个域名。如果这个解析也走 dns-remote(经代理)，
                // 就会死循环：连代理需要先解析域名 -> 解析域名需要经过代理 -> 代理还没连上。
                // "outbound": "any" 专门匹配这种"由出站发起的解析请求"(不是客户端 App
                // 自己发起的 DNS 查询)，让它强制走 dns-local 直连解析，从而打破死循环。
                "rules": [
                    ["outbound": "any", "server": "dns-local"]
                ],
                "final": "dns-remote"
            ],
            "inbounds": [
                [
                    "type": "tun",
                    "tag": "tun-in",
                    "address": ["172.19.0.1/30"],
                    "auto_route": true,
                    "strict_route": true
                ]
            ],
            "outbounds": [
                outbound,
                ["type": "direct", "tag": "direct"]
            ],
            "route": [
                "auto_detect_interface": true,
                "final": "proxy",
                "rules": [
                    ["action": "sniff"],
                    ["protocol": "dns", "action": "hijack-dns"]
                ]
            ]
        ]

        let jsonData = try JSONSerialization.data(withJSONObject: config, options: .prettyPrinted)
        guard let jsonString = String(data: jsonData, encoding: .utf8) else {
            throw BuildError(message: "序列化 sing-box JSON 配置失败")
        }
        NSLog("[SingBoxBuilder] 成功生成 sing-box 配置 JSON！完整内容如下，方便核对 tls/reality 字段是否正确:\n%@", jsonString)
        return jsonString
    }

    // --- VMess 协议转换 (全面兼容 3x-ui / v2rayN / Xray 字段名) ---
    private static func buildVmessOutbound(_ node: [String: Any]) throws -> [String: Any] {
        guard let address = extractString(node, keys: ["add", "address", "server", "ip", "host", "srv"]),
              let uuid = extractString(node, keys: ["id", "uuid", "userId", "user_id"]) else {
            throw BuildError(message: "VMess 节点缺少目标地址(add/address/server)或 UUID(id/uuid)")
        }
        let port = extractInt(node, keys: ["port", "server_port", "serverPort"]) ?? 443
        let alterId = extractInt(node, keys: ["aid", "alter_id", "alterId"]) ?? 0
        let network = (node["net"] as? String) ?? (node["network"] as? String) ?? "tcp"

        var outbound: [String: Any] = [
            "type": "vmess",
            "tag": "proxy",
            "server": address,
            "server_port": port,
            "uuid": uuid,
            "alter_id": alterId,
            "security": (node["scy"] as? String) ?? (node["security"] as? String) ?? "auto"
        ]

        appendTransport(to: &outbound, node: node, network: network, defaultHost: address)
        appendTLS(to: &outbound, node: node, defaultHost: address)
        return outbound
    }

    // --- VLESS 协议转换 ---
    private static func buildVlessOutbound(_ node: [String: Any]) throws -> [String: Any] {
        guard let address = extractString(node, keys: ["add", "address", "server", "ip", "host", "srv"]),
              let uuid = extractString(node, keys: ["id", "uuid", "userId", "user_id"]) else {
            throw BuildError(message: "VLESS 节点缺少目标地址或 UUID")
        }
        let port = extractInt(node, keys: ["port", "server_port", "serverPort"]) ?? 443
        let network = (node["net"] as? String) ?? (node["network"] as? String) ?? "tcp"
        let flow = extractString(node, keys: ["flow"]) ?? ""

        var outbound: [String: Any] = [
            "type": "vless",
            "tag": "proxy",
            "server": address,
            "server_port": port,
            "uuid": uuid
        ]

        if !flow.isEmpty { outbound["flow"] = flow }
        appendTransport(to: &outbound, node: node, network: network, defaultHost: address)
        appendTLS(to: &outbound, node: node, defaultHost: address)
        return outbound
    }

    // --- Trojan 协议转换 ---
    private static func buildTrojanOutbound(_ node: [String: Any]) throws -> [String: Any] {
        guard let address = extractString(node, keys: ["add", "address", "server", "ip", "host", "srv"]),
              let password = extractString(node, keys: ["password", "passwd", "id", "uuid"]) else {
            throw BuildError(message: "Trojan 节点缺少目标地址或连接密码")
        }
        let port = extractInt(node, keys: ["port", "server_port", "serverPort"]) ?? 443
        let network = (node["net"] as? String) ?? (node["network"] as? String) ?? "tcp"

        var outbound: [String: Any] = [
            "type": "trojan",
            "tag": "proxy",
            "server": address,
            "server_port": port,
            "password": password
        ]

        appendTransport(to: &outbound, node: node, network: network, defaultHost: address)
        appendTLS(to: &outbound, node: node, defaultHost: address, forceTLS: true)
        return outbound
    }

    // --- Shadowsocks 协议转换 ---
    private static func buildShadowsocksOutbound(_ node: [String: Any]) throws -> [String: Any] {
        guard let address = extractString(node, keys: ["add", "address", "server", "ip", "host", "srv"]),
              let password = extractString(node, keys: ["password", "passwd"]),
              let method = extractString(node, keys: ["method", "cipher"]) else {
            throw BuildError(message: "Shadowsocks 节点缺少 server、password 或 method 字段")
        }
        let port = extractInt(node, keys: ["port", "server_port", "serverPort"]) ?? 8388

        return [
            "type": "shadowsocks",
            "tag": "proxy",
            "server": address,
            "server_port": port,
            "method": method,
            "password": password
        ]
    }

    // --- 传输层处理 (WS / gRPC / HTTP) ---
    private static func appendTransport(to outbound: inout [String: Any], node: [String: Any], network: String, defaultHost: String) {
        if network == "ws" {
            let path = extractString(node, keys: ["path"]) ?? "/"
            let host = extractString(node, keys: ["host", "sni"]) ?? defaultHost
            outbound["transport"] = [
                "type": "ws",
                "path": path,
                "headers": ["Host": host]
            ]
        } else if network == "grpc" {
            let serviceName = extractString(node, keys: ["path", "serviceName", "service_name"]) ?? ""
            outbound["transport"] = [
                "type": "grpc",
                "service_name": serviceName
            ]
        }
    }

    // --- TLS / Reality 处理 ---
    // 关键修复：这个后端的节点 JSON 把 Reality 相关字段放在嵌套的
    // "reality": {publicKey, shortId, serverName, fingerprint} 对象里，
    // 而不是老式扁平字段(pbk/sid/sni)。之前只找顶层字段，导致：
    // 1) SNI 拿不到 serverName，退化成用服务器 IP 当 SNI —— Reality 服务端一看
    //    SNI 不对就直接判定异常连接。
    // 2) publicKey/shortId 拿不到，最终配置里根本没有 "reality" 字段 ——
    //    客户端等于在用普通 TLS 去敲一个 Reality 端口，握手必然失败。
    // 这里统一用 extractRealityInfo 同时兼容嵌套对象和老式扁平字段。
    private static func extractRealityInfo(_ node: [String: Any]) -> (serverName: String?, publicKey: String?, shortId: String?, fingerprint: String?) {
        if let realityObj = node["reality"] as? [String: Any] {
            return (
                extractString(realityObj, keys: ["serverName", "server_name", "sni"]),
                extractString(realityObj, keys: ["publicKey", "public_key", "pbk"]),
                extractString(realityObj, keys: ["shortId", "short_id", "sid"]),
                extractString(realityObj, keys: ["fingerprint", "fp"])
            )
        }
        // 兼容老式扁平字段（其他来源的节点可能是这种格式）
        return (
            extractString(node, keys: ["sni", "host", "peer"]),
            extractString(node, keys: ["pbk", "public_key"]),
            extractString(node, keys: ["sid", "short_id"]),
            extractString(node, keys: ["fp", "fingerprint"])
        )
    }

    private static func appendTLS(to outbound: inout [String: Any], node: [String: Any], defaultHost: String, forceTLS: Bool = false) {
        let tlsStr = extractString(node, keys: ["tls", "security"]) ?? ""
        let realityInfo = extractRealityInfo(node)
        let isReality = tlsStr == "reality" || realityInfo.publicKey != nil
        let isTls = forceTLS || tlsStr == "tls" || isReality || node["sni"] != nil

        guard isTls else { return }

        let sni = realityInfo.serverName ?? defaultHost
        var tlsConfig: [String: Any] = [
            "enabled": true,
            "server_name": sni,
            "insecure": (node["allowInsecure"] as? Bool) ?? false
        ]

        if isReality, let pbk = realityInfo.publicKey, let sid = realityInfo.shortId {
            tlsConfig["reality"] = [
                "enabled": true,
                "public_key": pbk,
                "short_id": sid
            ]
            // Reality 强依赖客户端 TLS 指纹跟正常浏览器一致（否则容易被识别），
            // 用节点给的 fingerprint(如 "chrome")；没给就默认用 chrome。
            tlsConfig["utls"] = [
                "enabled": true,
                "fingerprint": realityInfo.fingerprint ?? "chrome"
            ]
        } else if tlsStr == "reality" {
            let msg = "协议标记为 reality，但节点里缺少 publicKey/shortId，Reality 握手必然失败"
            NSLog("[SingBoxBuilder 致命错误] %@", msg)
        }

        outbound["tls"] = tlsConfig
    }

    // --- 智能推测协议 ---
    private static func guessProtocol(_ node: [String: Any]) -> String {
        if node["v"] != nil || node["aid"] != nil { return "vmess" }
        if node["flow"] != nil || (node["id"] != nil && node["pbk"] != nil) { return "vless" }
        if node["password"] != nil && node["method"] != nil { return "shadowsocks" }
        if node["password"] != nil { return "trojan" }
        if node["id"] != nil { return "vmess" }
        return "unknown"
    }

    // --- 多 Key 备选提取工具 ---
    private static func extractString(_ dict: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let val = dict[key] as? String, !val.isEmpty { return val }
        }
        return nil
    }

    private static func extractInt(_ dict: [String: Any], keys: [String]) -> Int? {
        for key in keys {
            if let val = dict[key] as? Int { return val }
            if let str = dict[key] as? String, let val = Int(str) { return val }
        }
        return nil
    }
}