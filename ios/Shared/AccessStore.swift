import Foundation
import Security

protocol AccessStorage: Sendable {
    func readAccess() throws -> DeviceAccess?
    func saveAccess(_ access: DeviceAccess) throws
    func readCatalog() throws -> Data?
    func saveCatalog(_ catalog: Data) throws
    func removeCatalog() throws
    func removeAccess() throws
}

struct AccessStore: AccessStorage {
    private func query(_ account: String) -> [String: Any] {
        var request: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.chromvoid.vpn.access", kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: AppIdentity.keychainAccessGroup,
            kSecAttrSynchronizable as String: false]
        #if os(macOS)
        request[kSecUseDataProtectionKeychain as String] = true
        #endif
        return request
    }

    func readAccess() throws -> DeviceAccess? {
        try read("device").map { try JSONDecoder().decode(DeviceAccess.self, from: $0) }
    }

    func saveAccess(_ access: DeviceAccess) throws { try save(JSONEncoder().encode(access), account: "device") }

    func readCatalog() throws -> Data? {
        guard let access = try readAccess(), !access.device.isEmpty,
              let data = try read("catalog"), let catalog = try? NodeCatalog.parse(data),
              catalog.device == access.device else { return nil }
        return data
    }

    func saveCatalog(_ catalog: Data) throws { try save(catalog, account: "catalog") }
    func removeCatalog() throws { try remove("catalog") }
    func removeAccess() throws { try removeCatalog(); try remove("node_pauses"); try remove("device") }

    /// The pauses of failed nodes, shared by the app and the tunnel extension, see `NodePauses`.
    func readNodePauses() throws -> Data? { try read("node_pauses") }
    func saveNodePauses(_ pauses: Data) throws { try save(pauses, account: "node_pauses") }

    private func read(_ account: String) throws -> Data? {
        var request = query(account)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw storageError() }
        return data
    }

    private func save(_ data: Data, account: String) throws {
        let values: [String: Any] = [kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(query(account) as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound {
            guard SecItemAdd(query(account).merging(values) { _, new in new } as CFDictionary, nil) == errSecSuccess else {
                throw storageError()
            }
        } else if status != errSecSuccess { throw storageError() }
    }

    private func remove(_ account: String) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw storageError() }
    }

    private func storageError() -> NSError {
        NSError(domain: "Wayveil", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not access the secure device access."])
    }
}

extension NodePauses {
    /// The pauses kept in the keychain shared by the app and the tunnel extension, so that they outlive the process.
    static func stored(in store: AccessStore = AccessStore()) -> NodePauses {
        NodePauses(read: { try? store.readNodePauses() }, write: { try? store.saveNodePauses($0) })
    }
}
