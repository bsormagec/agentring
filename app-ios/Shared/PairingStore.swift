import Foundation
import Security

/// Everything the phone needs to talk to its relay. Stored in the Keychain, in the
/// access group shared with the Notification Service Extension.
struct Pairing: Codable, Equatable, Sendable {
    var relayUrl: String
    var relayId: String
    var deviceId: String
    var deviceJwt: String
    var pushSecret: String
    var agentName: String
    /// `push_config` from the pair response; nil = the relay has no push for iOS.
    var push: PushSettings?

    enum CodingKeys: String, CodingKey {
        case relayUrl = "relay_url"
        case relayId = "relay_id"
        case deviceId = "device_id"
        case deviceJwt = "device_jwt"
        case pushSecret = "push_secret"
        case agentName = "agent_name"
        case push
    }
}

/// The app's own copy of `PushConfig` (kept separate so the stored format doesn't
/// depend on the core's Codable).
struct PushSettings: Codable, Equatable, Sendable {
    var provider: String
    /// Bundle id the relay's APNs key can reach.
    var topic: String?
    var viaGateway: Bool
    var gatewayUrl: String?

    enum CodingKeys: String, CodingKey {
        case provider
        case topic
        case viaGateway = "via_gateway"
        case gatewayUrl = "gateway_url"
    }
}

/// Keychain storage of the pairing. Items are readable after the first unlock
/// (`kSecAttrAccessibleAfterFirstUnlock`) so a VoIP push can be verified on a locked
/// phone, but not before the first unlock after a reboot.
enum PairingStore {
    enum LoadResult: Equatable {
        case found(Pairing)
        case none
        /// The Keychain can't be read yet (before the first unlock after a reboot).
        case unavailable
    }

    private static let account = "pairing"

    static func load() -> LoadResult {
        switch Keychain.read(account: account) {
        case .found(let data):
            guard let p = try? JSONDecoder().decode(Pairing.self, from: data) else { return .none }
            return .found(p)
        case .notFound:
            return .none
        case .locked:
            return .unavailable
        }
    }

    /// The pairing, or nil when there is none or the Keychain is locked.
    static func current() -> Pairing? {
        if case .found(let p) = load() { return p }
        return nil
    }

    @discardableResult
    static func save(_ pairing: Pairing?) -> Bool {
        guard let pairing else { return Keychain.delete(account: account) }
        guard let data = try? JSONEncoder().encode(pairing) else { return false }
        return Keychain.write(account: account, data: data)
    }
}

/// Generic-password items of `SharedConfig.keychainService`, in the shared access
/// group when the build has one (falls back to the app's default group otherwise).
enum Keychain {
    enum ReadResult {
        case found(Data)
        case notFound
        case locked
    }

    static func read(account: String) -> ReadResult {
        var result = readOnce(account: account, group: SharedConfig.keychainGroup)
        if case .missingEntitlement = result {
            result = readOnce(account: account, group: nil)
        }
        switch result {
        case .found(let data): return .found(data)
        case .locked: return .locked
        default: return .notFound
        }
    }

    @discardableResult
    static func write(account: String, data: Data) -> Bool {
        let group = SharedConfig.keychainGroup
        var status = writeOnce(account: account, data: data, group: group)
        if status == errSecMissingEntitlement, group != nil {
            status = writeOnce(account: account, data: data, group: nil)
        }
        return status == errSecSuccess
    }

    @discardableResult
    static func delete(account: String) -> Bool {
        var ok = true
        for group in [SharedConfig.keychainGroup, nil] {
            var query = baseQuery(account: account, group: group)
            query.removeValue(forKey: kSecReturnData as String)
            let status = SecItemDelete(query as CFDictionary)
            if status != errSecSuccess && status != errSecItemNotFound && status != errSecMissingEntitlement {
                ok = false
            }
            if group == nil { break }
        }
        return ok
    }

    private enum OnceResult {
        case found(Data)
        case notFound
        case locked
        case missingEntitlement
    }

    private static func baseQuery(account: String, group: String?) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: SharedConfig.keychainService,
            kSecAttrAccount as String: account,
        ]
        if let group { query[kSecAttrAccessGroup as String] = group }
        return query
    }

    private static func readOnce(account: String, group: String?) -> OnceResult {
        var query = baseQuery(account: account, group: group)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        switch status {
        case errSecSuccess:
            if let data = out as? Data { return .found(data) }
            return .notFound
        case errSecInteractionNotAllowed:
            return .locked
        case errSecMissingEntitlement:
            return .missingEntitlement
        default:
            return .notFound
        }
    }

    private static func writeOnce(account: String, data: Data, group: String?) -> OSStatus {
        let query = baseQuery(account: account, group: group)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            for (k, v) in attributes { add[k] = v }
            status = SecItemAdd(add as CFDictionary, nil)
        }
        return status
    }
}
