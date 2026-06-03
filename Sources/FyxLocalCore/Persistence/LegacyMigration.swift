// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Foundation

/// One-time migrations from the pre-rename app ("F-Chat", bundle id
/// `com.fyrbyadditive.fchat`) to the current app ("FyxLocal", bundle id
/// `com.fyrbyadditive.fyxlocal`).
///
/// The Application Support data directory is migrated by `AppDataDirectories`
/// (it keys off a directory name, not the bundle id). This type handles the
/// Keychain, whose items are keyed on the bundle id: changing the id means the
/// new app would otherwise see none of the old API keys / OAuth tokens. Both
/// migrations are best-effort and idempotent — they never throw into startup.
public enum LegacyMigration {
    /// The pre-rename Keychain service name (the old bundle id).
    public static let legacyKeychainService = "com.fyrbyadditive.fchat"

    /// Run all first-launch migrations synchronously. Safe to call
    /// unconditionally at app startup, BEFORE any data or secret is read.
    /// `KeychainStore`'s operations are synchronous under the hood, so this
    /// blocks only on a couple of fast Keychain calls.
    public static func runIfNeeded() {
        AppDataDirectories.migrateLegacyIfNeeded()
        migrateKeychainSync(
            from: KeychainStore(service: legacyKeychainService),
            to: KeychainStore(service: FyxLocal.appIdentifier)
        )
    }

    /// Synchronous keychain migration over the concrete `KeychainStore` (its
    /// methods are non-async). Same idempotent, non-clobbering, best-effort
    /// semantics as `migrateKeychainIfNeeded`.
    static func migrateKeychainSync(from legacy: KeychainStore, to current: KeychainStore) {
        do {
            guard try current.allAccounts().isEmpty else { return }
            let legacyAccounts = try legacy.allAccounts()
            guard !legacyAccounts.isEmpty else { return }
            for account in legacyAccounts {
                if let value = try legacy.secret(for: account) {
                    try current.setSecret(value, for: account)
                }
            }
        } catch {
            // Best-effort: a Keychain hiccup must never block launch.
        }
    }

    /// Copy every generic-password item from the legacy service into the current
    /// service. Runs only when the current service has no items yet and the
    /// legacy service has some, so it can't clobber values written by the new
    /// app, and is a no-op on every subsequent launch.
    ///
    /// Reliable here because the app's Keychain items carry no access group
    /// (`KeychainStore` sets none), so a login-keychain generic password is
    /// readable across the bundle-id change. The legacy items are left in place
    /// as a rollback safety net.
    static func migrateKeychainIfNeeded(
        from legacy: SecretStore = KeychainStore(service: legacyKeychainService),
        to current: SecretStore = KeychainStore(service: FyxLocal.appIdentifier)
    ) async {
        do {
            let currentAccounts = try await current.allAccounts()
            guard currentAccounts.isEmpty else { return }      // new app already has secrets
            let legacyAccounts = try await legacy.allAccounts()
            guard !legacyAccounts.isEmpty else { return }      // nothing to migrate
            for account in legacyAccounts {
                if let value = try await legacy.secret(for: account) {
                    try await current.setSecret(value, for: account)
                }
            }
        } catch {
            // Best-effort: a Keychain hiccup must never block launch. The user
            // can re-enter API keys / re-authorize if migration didn't complete.
        }
    }
}
