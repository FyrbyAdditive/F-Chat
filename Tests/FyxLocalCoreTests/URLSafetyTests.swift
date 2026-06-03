// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Testing
import Foundation
@testable import FyxLocalCore

@Suite("URLSafety (SSRF guard)")
struct URLSafetyTests {
    private func rejected(_ s: String) -> Bool {
        guard let url = URL(string: s) else { return true }
        if case .failure = URLSafety.validatePublicHTTP(url) { return true }
        return false
    }
    private func allowed(_ s: String) -> Bool { !rejected(s) }

    @Test func allowsPublicHTTPAndHTTPS() {
        #expect(allowed("https://example.com/path?q=1"))
        #expect(allowed("http://example.com"))
        #expect(allowed("https://8.8.8.8/"))                 // public literal IP
        #expect(allowed("https://sub.domain.example.co.uk"))
    }

    @Test func rejectsNonHTTPSchemes() {
        #expect(rejected("file:///Users/tim/.ssh/id_rsa"))
        #expect(rejected("ftp://example.com/x"))
        #expect(rejected("data:text/plain;base64,AAAA"))
        #expect(rejected("about:blank"))
        #expect(rejected("javascript:alert(1)"))
    }

    @Test func rejectsLoopbackAndLocalhost() {
        #expect(rejected("http://localhost/"))
        #expect(rejected("http://LocalHost:8080/x"))
        #expect(rejected("http://foo.localhost/"))
        #expect(rejected("http://127.0.0.1/"))
        #expect(rejected("http://127.9.9.9/"))
        #expect(rejected("http://[::1]/"))
    }

    @Test func rejectsLinkLocalAndCloudMetadata() {
        #expect(rejected("http://169.254.169.254/latest/meta-data/"))  // AWS/GCP/Azure metadata
        #expect(rejected("http://169.254.0.1/"))
        #expect(rejected("http://[fe80::1]/"))
    }

    @Test func rejectsPrivateRanges() {
        #expect(rejected("http://10.0.0.1/"))
        #expect(rejected("http://10.255.255.255/"))
        #expect(rejected("http://172.16.0.1/"))
        #expect(rejected("http://172.31.255.255/"))
        #expect(rejected("http://192.168.1.1/"))
        #expect(rejected("http://0.0.0.0/"))
        #expect(rejected("http://[fc00::1]/"))   // ULA
        #expect(rejected("http://[fd12:3456::1]/"))
    }

    @Test func rejectsIPv4MappedIPv6Loopback() {
        // ::ffff:127.0.0.1 must be caught via the embedded v4 check.
        #expect(rejected("http://[::ffff:127.0.0.1]/"))
        #expect(rejected("http://[::ffff:10.0.0.1]/"))
    }

    @Test func allowsBorderPublicV4() {
        #expect(allowed("http://172.15.0.1/"))    // just below 172.16/12
        #expect(allowed("http://172.32.0.1/"))    // just above
        #expect(allowed("http://11.0.0.1/"))      // just above 10/8
        #expect(allowed("http://126.0.0.1/"))     // just below 127/8
    }

    @Test func resolvesLiteralPublicIPWithoutDNS() async {
        let ok = await URLSafety.hostResolvesToPublicOnly(URL(string: "https://8.8.8.8/")!)
        #expect(ok)
    }

    @Test func resolverRejectsLiteralLoopback() async {
        let ok = await URLSafety.hostResolvesToPublicOnly(URL(string: "http://127.0.0.1/")!)
        #expect(!ok)
    }
}
