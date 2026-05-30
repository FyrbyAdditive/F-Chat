// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Foundation

/// Simple actor-based rate limiter: at most one event per `minimumInterval`,
/// queueing later requests until their slot opens.
public actor RateLimiter {
    private let minimumInterval: TimeInterval
    private var earliestNextSlot: Date = .distantPast
    private let clock: @Sendable () -> Date

    public init(minimumInterval: TimeInterval, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.minimumInterval = minimumInterval
        self.clock = clock
    }

    /// Returns the `Date` at which the next call may proceed. Callers should
    /// `try await Task.sleep(until: result)` (or compare to `clock()` and wait).
    public func reserveSlot() -> Date {
        let now = clock()
        let slot = max(now, earliestNextSlot)
        earliestNextSlot = slot.addingTimeInterval(minimumInterval)
        return slot
    }

    public func waitForSlot() async throws {
        let slot = reserveSlot()
        let now = clock()
        let delay = slot.timeIntervalSince(now)
        if delay > 0 {
            try await Task.sleep(for: .seconds(delay))
        }
    }
}
