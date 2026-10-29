import Foundation
import Security

enum AppIdentity {
    static let keychainAccessGroup = Bundle.main.object(forInfoDictionaryKey: "WayveilKeychainAccessGroup") as! String
    static let tunnelIdentifier = "com.chromvoid.vpn.Tunnel"
    static let coreVersion = "1.14.4"
}

enum ProfileStore {
    static let preferences = UserDefaults.standard
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.chromvoid.vpn.profile",
         kSecAttrAccount as String: "connection", kSecAttrAccessGroup as String: AppIdentity.keychainAccessGroup,
         kSecAttrSynchronizable as String: false]
    }
    static func read() throws -> ConnectionProfile? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              data.count <= ConnectionProfile.maximumLength * 4, let text = String(data: data, encoding: .utf8) else { throw storageError() }
        return try ConnectionProfile.parse(text)
    }
    static func save(_ profile: ConnectionProfile) throws {
        let data = try JSONEncoder().encode(profile)
        let values: [String: Any] = [kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound {
            guard SecItemAdd(query.merging(values) { _, new in new } as CFDictionary, nil) == errSecSuccess else { throw storageError() }
        } else if status != errSecSuccess { throw storageError() }
    }
    static func remove() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw storageError() }
    }
    static var routing: RoutingMode {
        get { RoutingMode(rawValue: preferences.string(forKey: "routing") ?? "ALL") ?? .all }
        set { preferences.set(newValue.rawValue, forKey: "routing") }
    }
    private static func storageError() -> NSError {
        NSError(domain: "Wayveil", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not access the secure connection profile."])
    }
}

enum RoutingOverrideStoreError: Error {
    case damaged
}

enum RoutingOverrideStore {
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.chromvoid.vpn.routing-overrides",
         kSecAttrAccount as String: "overrides", kSecAttrAccessGroup as String: AppIdentity.keychainAccessGroup,
         kSecAttrSynchronizable as String: false]
    }

    static func read() throws -> RoutingOverrides {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return .empty }
        guard status == errSecSuccess, let data = result as? Data else { throw RoutingOverrideStoreError.damaged }
        do { return try RoutingOverrides.parse(data) }
        catch { throw RoutingOverrideStoreError.damaged }
    }

    @discardableResult
    static func add(_ input: String, to list: RoutingOverrides.List) throws -> RoutingOverrides {
        let overrides = try read().adding(input, to: list)
        try save(overrides)
        return overrides
    }

    @discardableResult
    static func remove(_ domain: String, from list: RoutingOverrides.List) throws -> RoutingOverrides {
        let overrides = try read().removing(domain, from: list)
        try save(overrides)
        return overrides
    }

    static func remove() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw storageError() }
    }

    static func errorKey(_ error: Error) -> String {
        if error is RoutingOverrideStoreError { return "overrides_damaged" }
        guard let ruleError = error as? RoutingRuleError else { return "overrides_save_failed" }
        switch ruleError {
        case .nameInOtherList: return "overrides_other_list"
        case .duplicateEntry: return "overrides_duplicate"
        case .tooManyEntries: return "overrides_limit"
        default: return "overrides_invalid_address"
        }
    }

    private static func save(_ overrides: RoutingOverrides) throws {
        let data = try JSONEncoder().encode(overrides)
        let values: [String: Any] = [kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound {
            guard SecItemAdd(query.merging(values) { _, new in new } as CFDictionary, nil) == errSecSuccess else { throw storageError() }
        } else if status != errSecSuccess { throw storageError() }
    }

    private static func storageError() -> NSError {
        NSError(domain: "Wayveil", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not access the secure routing exceptions."])
    }
}

enum TunnelPhase: String, Codable {
    case disconnected, connecting, connected, reconnecting, stopping, error
    var running: Bool { [.connecting, .connected, .reconnecting, .stopping].contains(self) }
}
