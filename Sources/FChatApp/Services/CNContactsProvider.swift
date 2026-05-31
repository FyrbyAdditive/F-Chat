// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Foundation
import FChatTools
#if canImport(Contacts)
import Contacts
#endif

/// `CNContactStore`-backed implementation of the read-only `ContactsProvider`.
/// Lives in the app layer so `FChatTools` never imports the Contacts framework.
/// All store access runs on the main actor (CNContactStore isn't thread-safe);
/// results are mapped to the Sendable `ContactRecord` before crossing back out.
///
/// The app is non-sandboxed, so reading Contacts needs only the
/// `NSContactsUsageDescription` Info.plist string + the runtime TCC prompt — no
/// sandbox entitlement.
final class CNContactsProvider: ContactsProvider {
#if canImport(Contacts)
    // Computed (not a static stored property) because `[CNKeyDescriptor]` isn't
    // Sendable, which a global/static would require under strict concurrency.
    private static var keys: [CNKeyDescriptor] {
        [
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactOrganizationNameKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor,
        ]
    }

    func authorization() async -> ContactsAccess {
        Self.map(CNContactStore.authorizationStatus(for: .contacts))
    }

    func requestAccess() async -> ContactsAccess {
        let current = CNContactStore.authorizationStatus(for: .contacts)
        guard current == .notDetermined else { return Self.map(current) }
        let store = CNContactStore()
        _ = try? await store.requestAccess(for: .contacts)
        return Self.map(CNContactStore.authorizationStatus(for: .contacts))
    }

    @MainActor
    func fetch(query: String?, limit: Int) async throws -> [ContactRecord] {
        let store = CNContactStore()
        var out: [ContactRecord] = []

        if let query, !query.isEmpty {
            // Union of name / email / phone matches, de-duplicated by identifier.
            var seen = Set<String>()
            let predicates = [
                CNContact.predicateForContacts(matchingName: query),
                CNContact.predicateForContacts(matchingEmailAddress: query),
            ]
            for predicate in predicates {
                let matches = (try? store.unifiedContacts(matching: predicate, keysToFetch: Self.keys)) ?? []
                for c in matches where seen.insert(c.identifier).inserted {
                    out.append(Self.record(from: c))
                    if out.count >= limit { return out }
                }
            }
        } else {
            // List all, bounded by `limit`. enumerateContacts streams; stop early.
            let request = CNContactFetchRequest(keysToFetch: Self.keys)
            try store.enumerateContacts(with: request) { contact, stop in
                out.append(Self.record(from: contact))
                if out.count >= limit { stop.pointee = true }
            }
        }
        return out
    }

    private static func map(_ status: CNAuthorizationStatus) -> ContactsAccess {
        switch status {
        case .authorized: return .authorized
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notDetermined
        @unknown default:
            // `.limited` (and any future tier that grants reads) → treat as authorized.
            return .authorized
        }
    }

    private static func record(from c: CNContact) -> ContactRecord {
        let given = c.givenName.isEmpty ? nil : c.givenName
        let family = c.familyName.isEmpty ? nil : c.familyName
        let org = c.organizationName.isEmpty ? nil : c.organizationName
        let display = [c.givenName, c.familyName].filter { !$0.isEmpty }.joined(separator: " ")
        let name = display.isEmpty ? (org ?? "Unknown") : display
        return ContactRecord(
            name: name,
            givenName: given,
            familyName: family,
            organization: org,
            emails: c.emailAddresses.map { $0.value as String },
            phones: c.phoneNumbers.map { $0.value.stringValue }
        )
    }
#else
    func authorization() async -> ContactsAccess { .restricted }
    func requestAccess() async -> ContactsAccess { .restricted }
    func fetch(query: String?, limit: Int) async throws -> [ContactRecord] { [] }
#endif
}
