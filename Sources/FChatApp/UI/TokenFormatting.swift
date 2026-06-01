// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Foundation

extension Int {
    /// Compact token-count label: `1234 → "1.2k"`, `120000 → "120k"`, `<1000`
    /// shown verbatim. Used by the composer token meter and the per-message
    /// footer so both read consistently.
    var tokenCountLabel: String {
        if self >= 1000 {
            let value = Double(self) / 1000
            return value >= 100 ? "\(Int(value))k" : String(format: "%.1fk", value)
        }
        return "\(self)"
    }
}
