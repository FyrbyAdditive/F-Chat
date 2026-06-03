// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Foundation

public extension KeyedDecodingContainer {
    /// Decode an optional key, falling back to `default` when it's absent.
    ///
    /// Swift's synthesized `Decodable` throws `keyNotFound` for a missing key
    /// rather than using a property's default value, so every back-compatible
    /// model hand-rolls `decodeIfPresent(...) ?? default` per field. This trims
    /// that repeated `?? default` tail to one call.
    func decode<T: Decodable>(_ type: T.Type, forKey key: Key, default defaultValue: T) throws -> T {
        try decodeIfPresent(T.self, forKey: key) ?? defaultValue
    }
}
