// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Foundation

/// One contact, flattened to plain Sendable strings. The platform-specific
/// `CNContact` is mapped to this in the app layer so `FChatTools` never imports
/// the Contacts framework and results cross actor boundaries safely.
public struct ContactRecord: Sendable, Hashable, Codable {
    public var name: String            // display name (given + family, or org as fallback)
    public var givenName: String?
    public var familyName: String?
    public var organization: String?
    public var emails: [String]
    public var phones: [String]

    public init(
        name: String,
        givenName: String? = nil,
        familyName: String? = nil,
        organization: String? = nil,
        emails: [String] = [],
        phones: [String] = []
    ) {
        self.name = name
        self.givenName = givenName
        self.familyName = familyName
        self.organization = organization
        self.emails = emails
        self.phones = phones
    }
}

/// Read-access state for the user's Contacts (a subset of `CNAuthorizationStatus`
/// the tool cares about; `.limited` maps to `.authorized` for reads).
public enum ContactsAccess: Sendable, Equatable {
    case authorized
    case denied
    case restricted
    case notDetermined
}

/// Abstraction over the macOS Contacts store so the tool stays platform-free
/// and unit-testable. The concrete `CNContactStore`-backed implementation is
/// injected from the app layer (mirrors `WebSearchProvider` / `PageExtractor`).
/// READ-ONLY by construction: there are no write/update/delete methods.
public protocol ContactsProvider: Sendable {
    /// Current authorization status without prompting.
    func authorization() async -> ContactsAccess
    /// Trigger the system permission prompt when `notDetermined`; returns the
    /// resulting access. A no-op (returns current status) when already decided.
    func requestAccess() async -> ContactsAccess
    /// Fetch contacts. `query == nil` lists all (bounded by `limit`); a non-nil
    /// query matches against name, email, or phone. `limit` caps the result count.
    func fetch(query: String?, limit: Int) async throws -> [ContactRecord]
}
