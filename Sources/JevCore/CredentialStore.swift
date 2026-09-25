import Foundation
#if canImport(Security)
import Security
#endif

/// Where `jev setup` keeps host credentials: one generic-password item in the login keychain
/// whose data is a JSON object of variable → value (`CLOUDFLARE_API_TOKEN_JEV`, …). Values are
/// never written to a file or passed on a command line. On platforms without a keychain the
/// store is always empty and writes fail.
public struct CredentialStore: Sendable {
    public var service: String
    public var account: String

    public init(service: String, account: String = "hosts") {
        self.service = service
        self.account = account
    }

    public static let keychain = CredentialStore(service: "dev.jev.router")

    public struct Failure: Error, Sendable, CustomStringConvertible {
        public var description: String
    }

    /// The stored values; empty when nothing is stored.
    public func read() throws -> [String: String] {
        #if canImport(Security)
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [:] }
        guard status == errSecSuccess, let data = result as? Data else { throw Self.failure(status, "read") }
        guard let values = try? JSONDecoder().decode([String: String].self, from: data) else {
            throw Failure(description: "the keychain item \(service) is not jev's format")
        }
        return values
        #else
        return [:]
        #endif
    }

    /// Replaces the stored values; an empty dictionary deletes the item.
    public func write(_ values: [String: String]) throws {
        guard !values.isEmpty else { return try delete() }
        #if canImport(Security)
        let data = try JSONEncoder().encode(values)
        let update = SecItemUpdate(baseQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw Self.failure(update, "update") }
        var item = baseQuery
        item[kSecValueData as String] = data
        item[kSecAttrLabel as String] = "jev host credentials"
        item[kSecAttrDescription as String] = "Jev host API keys (jev setup)"
        let add = SecItemAdd(item as CFDictionary, nil)
        guard add == errSecSuccess else { throw Self.failure(add, "save") }
        #else
        throw Failure(description: "no keychain on this platform; use ~/.jev-router.env")
        #endif
    }

    public func delete() throws {
        #if canImport(Security)
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Self.failure(status, "delete") }
        #endif
    }

    #if canImport(Security)
    var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func failure(_ status: OSStatus, _ action: String) -> Failure {
        let message = SecCopyErrorMessageString(status, nil).map { $0 as String } ?? "OSStatus \(status)"
        return Failure(description: "could not \(action) the keychain item: \(message)")
    }
    #endif
}
