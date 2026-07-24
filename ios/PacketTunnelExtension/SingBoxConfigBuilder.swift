// ios/PacketTunnelExtension/SingBoxConfigBuilder.swift
import Foundation

enum SingBoxConfigBuilder {

    struct BuildError: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func build(fromNodeJson nodeJson: String) throws -> String {
        guard let data = nodeJson.data(using: .utf8),
              let node = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BuildError(message: "node_json 不是合法 JSON 格式")
        }

        // 兼容处理：提取协议类型，转换为小写
        let rawProtocol = (node["protocol"] as? String) ?? guessProtocol(node)
        let protocolType = rawProtocol.lowercased()

        let outbound: [String: Any]
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
            throw BuildError(message: "解析失败: 暂不支持协议 '\(protocolType)'，请检查节点 JSON 字段")
        }

        // 构建标准的 sing-box config.json 结构
        let config: [String: Any] = [
            "log": ["level": "warn"],
            "dns": [
                "servers": [
                    ["tag": "dns-remote", "address": "1.1.1.1", "detour": "proxy"],
                    ["tag": "dns-local", "address": "223.5.5.5", "detour": "direct"]
                ],
                "rules": [
                    ["outbound": "any", "server": "dns-local"]
                ]
            ],
            "inbounds": [
                [
                    "type": "tun",
                    "tag": "tun-in",
                    "inet4_address": "172.19.0.1/30",
                    "auto_route": true,
                    "strict_route": true,
                    "sniff": true
                ]
            ],
            "outbounds": [
                outbound,
                ["type": "direct", "tag": "direct"],
                ["type": "dns", "tag": "dns-out"]
            ],
            "route": [
                "auto_detect_interface": true,
                "final": "proxy"
            ]
        ]

        let jsonData = try JSONSerialization.data(withJSONObject: config, options: .prettyPrinted)
        guard let jsonString = String(data: jsonData, encoding: .utf8) else {
            throw BuildError(message: "序列化 sing-box JSON 配置失败")
        }
        return jsonString
    }

    // --- VMess 协议转换 ---
    private static func buildVmessOutbound(_ node: [String: Any]) throws -> [String: Any] {
        guard let address = extractString(node, keys: ["add", "server", "ip", "host"]),
              let uuid = extractString(node, keys: ["id", "uuid"]) else {
            throw BuildError(message: "VMess 节点缺少目标地址(add/server)或 UUID(id)")
        }
        let port = extractInt(node, keys: ["port", "server_port"]) ?? 443
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
        guard let address = extractString(node, keys: ["add", "server", "ip", "host"]),
              let uuid = extractString(node, keys: ["id", "uuid"]) else {
            throw BuildError(message: "VLESS 节点缺少目标地址(add/server)或 UUID(id)")
        }
        let port = extractInt(node, keys: ["port", "server_port"]) ?? 443
        let network = (node["net"] as? String) ?? (node["network"] as? String) ?? "tcp"
        let flow = extractString(node, keys: ["flow"]) ?? ""

        var outbound: [String: Any] = [
            "type": "vless",
            "tag": "proxy",
            "server": address,
            "server_port": port,
            "uuid": uuid
        ]

        if !flow.isEmpty {
            outbound["flow"] = flow
        }

        appendTransport(to: &outbound, node: node, network: network, defaultHost: address)
        appendTLS(to: &outbound, node: node, defaultHost: address)
        return outbound
    }

    // --- Trojan 协议转换 ---
    private static func buildTrojanOutbound(_ node: [String: Any]) throws -> [String: Any] {
        guard let address = extractString(node, keys: ["add", "server", "ip", "host"]),
              let password = extractString(node, keys: ["password", "passwd", "id", "uuid"]) else {
            throw BuildError(message: "Trojan 节点缺少目标地址或连接密码")
        }
        let port = extractInt(node, keys: ["port", "server_port"]) ?? 443
        let network = (node["net"] as? String) ?? (node["network"] as? String) ?? "tcp"

        var outbound: [String: Any] = [
            "type": "trojan",
            "tag": "proxy",
            "server": address,
            "server_port": port,
            "password": password
        ]

        appendTransport(to: &outbound, node: node, network: network, defaultHost: address)
        // Trojan 强制或默认开启 TLS
        appendTLS(to: &outbound, node: node, defaultHost: address, forceTLS: true)
        return outbound
    }

    // --- Shadowsocks 协议转换 ---
    private static func buildShadowsocksOutbound(_ node: [String: Any]) throws -> [String: Any] {
        guard let address = extractString(node, keys: ["add", "server", "ip", "host"]),
              let password = extractString(node, keys: ["password", "passwd"]),
              let method = extractString(node, keys: ["method", "cipher"]) else {
            throw BuildError(message: "Shadowsocks 节点缺少 server、password 或 method 字段")
        }
        let port = extractInt(node, keys: ["port", "server_port"]) ?? 8388

        return [
            "type": "shadowsocks",
            "tag": "proxy",
            "server": address,
            "server_port": port,
            "method": method,
            "password": password
        ]
    }

    // --- 传输层配置配置 (WS / GRPC / HTTP) ---
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

    // --- TLS / Reality 配置 ---
    private static func appendTLS(to outbound: inout [String: Any], node: [String: Any], defaultHost: String, forceTLS: Bool = false) {
        let tlsStr = extractString(node, keys: ["tls", "security"]) ?? ""
        let isTls = forceTLS || tlsStr == "tls" || tlsStr == "reality" || node["sni"] != nil

        if isTls {
            let sni = extractString(node, keys: ["sni", "host", "peer"]) ?? defaultHost
            var tlsConfig: [String: Any] = [
                "enabled": true,
                "server_name": sni,
                "insecure": (node["allowInsecure"] as? Bool) ?? false
            ]

            // 兼容 Reality 协议
            if tlsStr == "reality" || node["pbk"] != nil {
                if let pbk = extractString(node, keys: ["pbk", "public_key"]),
                   let sid = extractString(node, keys: ["sid", "short_id"]) {
                    tlsConfig["reality"] = [
                        "enabled": true,
                        "public_key": pbk,
                        "short_id": sid
                    ]
                }
            }
            outbound["tls"] = tlsConfig
        }
    }

    // --- 智能推测协议 ---
    private static func guessProtocol(_ node: [String: Any]) -> String {
        if node["v"] != nil || node["aid"] != nil { return "vmess" }
        if node["flow"] != nil || (node["id"] != nil && node["pbk"] != nil) { return "vless" }
        if node["password"] != nil && node["method"] != nil { return "shadowsocks" }
        if node["password"] != nil { return "trojan" }
        if node["id"] != nil { return "vmess" } // 默认兜底
        return "unknown"
    }

    // --- 辅助提取工具（支持多 Key 备选） ---
    private static func extractString(_ dict: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let val = dict[key] as? String, !val.isEmpty {
                return val
            }
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