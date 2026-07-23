import Foundation

// ⚠️ 这个文件是最需要你确认的部分。
//
// Android 那边 node_json 是喂给 libv2ray 的,大概率是标准 v2ray outbound 结构
// (比如 vmess 节点常见字段:v, ps, add, port, id, aid, net, type, host, path, tls, sni)。
// 下面按这个假设写了一版 vmess 转换,trojan/vless/ss 先留了空壳。
//
// 请把 Android 侧实际拿到的 node_json 样例发给我(敏感字段可以打码,
// 比如 id/uuid 换成 "xxxx-xxxx", add 换成 "example.com"),
// 我按真实结构把这个 builder 精确改完整,并且补上 trojan / vless / shadowsocks。

enum SingBoxConfigBuilder {

    struct BuildError: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func build(fromNodeJson nodeJson: String) throws -> String {
        guard let data = nodeJson.data(using: .utf8),
              let node = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BuildError(message: "node_json 不是合法 JSON")
        }

        let protocolType = (node["protocol"] as? String) ?? guessProtocol(node)

        let outbound: [String: Any]
        switch protocolType {
        case "vmess":
            outbound = try buildVmessOutbound(node)
        // case "vless":
        //     outbound = try buildVlessOutbound(node)
        // case "trojan":
        //     outbound = try buildTrojanOutbound(node)
        // case "shadowsocks", "ss":
        //     outbound = try buildShadowsocksOutbound(node)
        default:
            throw BuildError(message: "暂不支持的协议类型: \(protocolType),把 node_json 样例发我补上")
        }

        let config: [String: Any] = [
            "log": ["level": "warn"],
            "dns": [
                "servers": [
                    ["tag": "dns-remote", "address": "1.1.1.1", "detour": "proxy"]
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

        let jsonData = try JSONSerialization.data(withJSONObject: config, options: [])
        guard let jsonString = String(data: jsonData, encoding: .utf8) else {
            throw BuildError(message: "序列化 sing-box 配置失败")
        }
        return jsonString
    }

    // 假设字段沿用 vmess 分享链接的常见命名(v2rayN/v2rayNG 风格)
    private static func buildVmessOutbound(_ node: [String: Any]) throws -> [String: Any] {
        guard let address = node["add"] as? String,
              let uuid = node["id"] as? String else {
            throw BuildError(message: "vmess 节点缺少 add/id 字段,字段名可能对不上,请提供真实样例")
        }
        let port = intValue(node["port"]) ?? 443
        let alterId = intValue(node["aid"]) ?? 0
        let network = (node["net"] as? String) ?? "tcp"
        let tlsEnabled = (node["tls"] as? String) == "tls"

        var outbound: [String: Any] = [
            "type": "vmess",
            "tag": "proxy",
            "server": address,
            "server_port": port,
            "uuid": uuid,
            "alter_id": alterId,
            "security": "auto"
        ]

        if network == "ws" {
            outbound["transport"] = [
                "type": "ws",
                "path": (node["path"] as? String) ?? "/",
                "headers": ["Host": (node["host"] as? String) ?? address]
            ]
        }

        if tlsEnabled {
            outbound["tls"] = [
                "enabled": true,
                "server_name": (node["sni"] as? String) ?? (node["host"] as? String) ?? address,
                "insecure": false
            ]
        }

        return outbound
    }

    private static func guessProtocol(_ node: [String: Any]) -> String {
        // 有的分享格式没有显式 protocol 字段,靠特征字段猜
        if node["id"] != nil && node["aid"] != nil { return "vmess" }
        if node["password"] != nil && node["method"] != nil { return "shadowsocks" }
        return "unknown"
    }

    private static func intValue(_ any: Any?) -> Int? {
        if let i = any as? Int { return i }
        if let s = any as? String { return Int(s) }
        return nil
    }
}