// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Foundation
import Security

public enum KeychainError: Error, Equatable, Sendable {
    case unexpectedStatus(OSStatus)
    case itemNotFound
    case invalidData
}

public protocol SecretStore: Sendable {
    func setSecret(_ value: String, for account: String) async throws
    func secret(for account: String) async throws -> String?
    func deleteSecret(for account: String) async throws
    func allAccounts() async throws -> [String]
}

public struct KeychainStore: SecretStore {
    public let service: String

    public init(service: String = FChat.appIdentifier) {
        self.service = service
    }

    public func setSecret(_ value: String, for account: String) throws {
        guard let data = value.data(using: .utf8) else { throw KeychainError.invalidData }

        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]

        let attributesToUpdate: [String: Any] = [
            kSecValueData as String: data,
        ]

        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, attributesToUpdate as CFDictionary)
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var addQuery = baseQuery
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError.unexpectedStatus(addStatus) }
        default:
            throw KeychainError.unexpectedStatus(updateStatus)
        }
    }

    public func secret(for account: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: kCFBooleanTrue as Any,
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data, let str = String(data: data, encoding: .utf8) else {
                throw KeychainError.invalidData
            }
            return str
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }

    public func deleteSecret(for account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    public func allAccounts() throws -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: kCFBooleanTrue as Any,
        ]
        var items: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &items)
        switch status {
        case errSecSuccess:
            let array = (items as? [[String: Any]]) ?? []
            return array.compactMap { $0[kSecAttrAccount as String] as? String }
        case errSecItemNotFound:
            return []
        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }
}

public enum KeychainAccount {
    public static func providerAPIKey(_ id: ProviderID) -> String {
        "provider:\(id.rawValue):apiKey"
    }
    public static func mcpAccessToken(_ id: MCPServerID) -> String {
        "mcp:\(id.rawValue):oauthAccessToken"
    }
    public static func mcpRefreshToken(_ id: MCPServerID) -> String {
        "mcp:\(id.rawValue):oauthRefreshToken"
    }
    /// JSON-encoded `TokenMetadata` blob holding everything we need to
    /// drive a token-endpoint call without a fresh discovery round:
    /// expiry, scope, registered client id + secret, token-endpoint URL.
    public static func mcpTokenMetadata(_ id: MCPServerID) -> String {
        "mcp:\(id.rawValue):oauthMetadata"
    }
    /// Non-OAuth static auth credential for an HTTP MCP server: the
    /// raw bearer token, or (for Basic auth) the API token half of the
    /// email:token pair. The email itself is not a secret and lives in
    /// the server's HTTPConfig.
    public static func mcpStaticAuthToken(_ id: MCPServerID) -> String {
        "mcp:\(id.rawValue):staticAuthToken"
    }
}

public actor InMemorySecretStore: SecretStore {
    private var storage: [String: String] = [:]
    public init() {}
    public func setSecret(_ value: String, for account: String) { storage[account] = value }
    public func secret(for account: String) -> String? { storage[account] }
    public func deleteSecret(for account: String) { storage.removeValue(forKey: account) }
    public func allAccounts() -> [String] { Array(storage.keys) }
}
