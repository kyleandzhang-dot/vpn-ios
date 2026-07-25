import UIKit
import Security

class DeviceIdManager {
    // 你的 Keychain 专属标识，建议用 Bundle ID 加后缀
    private static let keychainKey = "com.example.vpn_all.device_unique_id"

    // ⚠️⚠️⚠️ 必须改成你自己的值 ⚠️⚠️⚠️
    // 格式："<你的 Team ID>.<Keychain Sharing 里填的组名>"
    // 例如 Team ID 是 ABCDE12345，Keychain Sharing 组名填的是 com.example.vpnAll.shared，
    // 这里就写 "ABCDE12345.com.example.vpnAll.shared"
    //
    // 前置条件（在 Xcode 里操作，代码改不了这步）：
    // 1. 主 App(Runner) target -> Signing & Capabilities -> + Capability -> Keychain Sharing
    //    -> 组名填 com.example.vpnAll.shared（随便起，但两边必须完全一致）
    // 2. PacketTunnelExtension target 同样加一遍 Keychain Sharing，组名填一模一样的
    // 3. 如果不设置这个，主 App 和 Extension 会各自生成一份不同的 UUID，
    //    Extension 里的心跳检测用的 device_id 会跟主 App 登录/付费用的 device_id 对不上
    private static let keychainAccessGroup = "TEAMID.com.example.vpnAll.shared"

    /// 获取设备的永久唯一 ID（主 App 和 Extension 共用同一份）
    static func getDeviceId() -> String {
        // 1. 尝试从共享 Keychain 读取已有 ID
        if let existingId = readFromKeychain(key: keychainKey) {
            return existingId
        }

        // 2. 如果 Keychain 没有，先拿系统的 IDFV，拿不到就保底生成一个 UUID
        let newId = UIDevice.current.identifierForVendor?.uuidString.uppercased()
                    ?? UUID().uuidString.uppercased()

        // 3. 写入共享 Keychain，保证日后卸载重装、主 App/Extension 两端都能读到同一个值
        saveToKeychain(key: keychainKey, value: newId)

        return newId
    }

    // MARK: - Keychain 底层私有方法

    private static func saveToKeychain(key: String, value: String) {
        guard let data = value.data(using: .utf8) else { return }

        // 配置 Keychain 查询字典
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecAttrAccessGroup as String: keychainAccessGroup,
            kSecValueData as String: data,
            // ⚠️ 关键设置：只在本机保留，不要同步到 iCloud！否则用户的 iPad 和 iPhone 会变成同一个 ID
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        // 写入前先尝试删除旧的，避免主键冲突
        SecItemDelete(query as CFDictionary)
        let status = SecItemAdd(query as CFDictionary, nil)
        if status != errSecSuccess {
            // 常见原因：Keychain Sharing 的组名两个 target 没配一致，
            // 或者 keychainAccessGroup 里的 TEAMID 没换成真实值
            NSLog("[DeviceIdManager] 写入 Keychain 失败，status=\(status)，检查 Keychain Sharing 配置")
        }
    }

    private static func readFromKeychain(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecAttrAccessGroup as String: keychainAccessGroup,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var dataTypeRef: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &dataTypeRef)

        if status == errSecSuccess, let data = dataTypeRef as? Data {
            return String(data: data, encoding: .utf8)
        }
        return nil
    }
}