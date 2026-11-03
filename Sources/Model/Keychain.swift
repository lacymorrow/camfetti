import Foundation
import Security

/// Small wrapper over the Keychain for camera secrets. Items stay on this device.
enum Keychain {
    private static let service = "sh.lacy.camfetti"

    /// On the Mac the data protection keychain is the one that matches iOS: items belong to the
    /// app, not to a login keychain file that prompts. It needs a signed build, so a build
    /// without a team falls back to the file keychain.
    nonisolated(unsafe) private static var useDataProtection = true

    private static func base(_ key: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        #if os(macOS)
        if useDataProtection { query[kSecUseDataProtectionKeychain as String] = true }
        #endif
        return query
    }

    static func set(_ value: String?, for key: String) {
        let base = base(key)
        SecItemDelete(base as CFDictionary)
        guard let value, !value.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        #if os(macOS)
        if status == errSecMissingEntitlement, useDataProtection {
            useDataProtection = false
            set(value, for: key)
        }
        #endif
    }

    static func get(_ key: String) -> String? {
        if let value = read(base(key)) { return value }
        #if os(macOS)
        // A build without the data protection entitlement saved to the file keychain; look there too,
        // or every relaunch would lose the camera passwords.
        if useDataProtection {
            var file = base(key)
            file.removeValue(forKey: kSecUseDataProtectionKeychain as String)
            return read(file)
        }
        #endif
        return nil
    }

    private static func read(_ base: [String: Any]) -> String? {
        var query = base
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// Typed access to one camera's secrets.
struct CameraSecrets: Sendable {
    let id: UUID
    var password: String? {
        get { Keychain.get("\(id).rtsp") }
        nonmutating set { Keychain.set(newValue, for: "\(id).rtsp") }
    }
    /// Thingino API key (sent as X-API-Key).
    var apiKey: String? {
        get { Keychain.get("\(id).api") }
        nonmutating set { Keychain.set(newValue, for: "\(id).api") }
    }
    func removeAll() {
        Keychain.set(nil, for: "\(id).rtsp")
        Keychain.set(nil, for: "\(id).api")
    }
}
