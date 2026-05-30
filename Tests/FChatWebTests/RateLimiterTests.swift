// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Testing
import Foundation
@testable import FChatWeb

@Suite("RateLimiter")
struct RateLimiterTests {
    @Test func firstSlotIsNow() async {
        let base = Date(timeIntervalSince1970: 1_000_000)
        let limiter = RateLimiter(minimumInterval: 1.0, clock: { base })
        let slot = await limiter.reserveSlot()
        #expect(slot == base)
    }

    @Test func successiveSlotsAreSpacedByInterval() async {
        let base = Date(timeIntervalSince1970: 1_000_000)
        // Frozen clock so we can observe scheduling math without sleeping.
        let limiter = RateLimiter(minimumInterval: 0.5, clock: { base })
        let s1 = await limiter.reserveSlot()
        let s2 = await limiter.reserveSlot()
        let s3 = await limiter.reserveSlot()
        #expect(s1 == base)
        #expect(s2.timeIntervalSince(s1) == 0.5)
        #expect(s3.timeIntervalSince(s2) == 0.5)
    }

    @Test func clockMovingForwardCollapsesPendingDelay() async {
        let clock = MovableClock(base: Date(timeIntervalSince1970: 1_000_000))
        let limiter = RateLimiter(minimumInterval: 1.0, clock: { clock.now })

        _ = await limiter.reserveSlot()
        clock.advance(by: 5.0)
        let later = await limiter.reserveSlot()
        #expect(later == clock.now)
    }
}

private final class MovableClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(base: Date) { self.value = base }
    var now: Date {
        lock.lock(); defer { lock.unlock() }
        return value
    }
    func advance(by seconds: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        value = value.addingTimeInterval(seconds)
    }
}
