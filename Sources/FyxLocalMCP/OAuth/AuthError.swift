// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Foundation

/// Typed failure modes the OAuth coordinator surfaces. The MCP registry
/// catches these and converts to its `Status.failed(message:)` shape;
/// the UI can offer "Sign in again" affordances based on which case
/// triggered.
public enum AuthError: Error, Sendable, Equatable, LocalizedError {
    case discoveryFailed(reason: String)
    case missingMetadata(field: String)
    case registrationFailed(reason: String)
    case userCancelled
    case authorizationDenied(reason: String)
    case stateMismatch
    case exchangeFailed(reason: String)
    case refreshFailed(reason: String)
    /// The refresh token is no longer valid (server returned
    /// invalid_grant). Cached tokens have been wiped; next access call
    /// will trigger interactive sign-in.
    case needsReAuthentication
    case configurationError(reason: String)

    public var errorDescription: String? {
        switch self {
        case .discoveryFailed(let reason): return "OAuth discovery failed: \(reason)"
        case .missingMetadata(let field): return "OAuth metadata missing required field: \(field)"
        case .registrationFailed(let reason): return "Dynamic client registration failed: \(reason)"
        case .userCancelled: return "Sign-in cancelled."
        case .authorizationDenied(let reason): return "Authorization denied: \(reason)"
        case .stateMismatch: return "OAuth state mismatch — possible CSRF, sign-in aborted."
        case .exchangeFailed(let reason): return "Token exchange failed: \(reason)"
        case .refreshFailed(let reason): return "Token refresh failed: \(reason)"
        case .needsReAuthentication: return "Sign-in needed."
        case .configurationError(let reason): return "OAuth configuration error: \(reason)"
        }
    }
}
