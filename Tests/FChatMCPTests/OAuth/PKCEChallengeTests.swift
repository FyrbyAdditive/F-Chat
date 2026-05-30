// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Testing
import Foundation
@testable import FChatMCP

@Suite("PKCEChallenge")
struct PKCEChallengeTests {
    /// Golden vector from RFC 7636 §4.1 — verifier
    /// `dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk` produces challenge
    /// `E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM`.
    @Test func s256ChallengeMatchesRFC7636GoldenVector() {
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        let expected = "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
        #expect(PKCEChallenge.s256Challenge(for: verifier) == expected)
    }

    @Test func generatedChallengePairsAreValid() {
        let pair = PKCEChallenge.generate()
        // Verifier should be base64url-style — no padding, no `+/`.
        #expect(!pair.verifier.contains("+"))
        #expect(!pair.verifier.contains("/"))
        #expect(!pair.verifier.contains("="))
        // 32 random bytes → 43 base64url chars (no padding).
        #expect(pair.verifier.count == 43)
        // Challenge is the S256 of the verifier.
        #expect(pair.challenge == PKCEChallenge.s256Challenge(for: pair.verifier))
    }

    @Test func multipleGenerationsProduceUniqueVerifiers() {
        var seen: Set<String> = []
        for _ in 0..<20 {
            seen.insert(PKCEChallenge.generate().verifier)
        }
        #expect(seen.count == 20, "PRNG should never collide in 20 draws")
    }

    @Test func base64URLEncodingDropsPaddingAndReplacesSpecialChars() {
        // `Data([0xff, 0xff, 0xff])` → base64 `////` → base64url `____`.
        let data = Data([0xff, 0xff, 0xff])
        #expect(data.base64URLEncodedString() == "____")
        // 1 byte → `/w==` in standard base64; `_w` in base64url.
        #expect(Data([0xff]).base64URLEncodedString() == "_w")
    }
}
