// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Foundation
import Network

/// SSRF guard for URLs that originate from untrusted input — primarily the
/// `web_fetch` tool (URLs chosen by the LLM) and OAuth/MCP endpoint discovery
/// (URLs chosen by a remote server). The model or a malicious server must not be
/// able to make FyxLocal reach `file://`, `localhost`, the cloud-metadata address,
/// or any internal/private host.
///
/// Two gates:
/// - `validatePublicHTTP` — synchronous, fast: scheme allow-list + literal
///   host/IP checks. Used everywhere as the cheap first pass and on redirects.
/// - `hostResolvesToPublicOnly` — async: resolves the hostname and rejects if
///   *any* resolved address is non-global (blocks names that point at internal
///   IPs / DNS-rebinding). Used right before a real network load.
public enum URLSafety {
    public enum Rejection: Error, Equatable, CustomStringConvertible {
        case scheme            // not http/https
        case noHost            // missing host (e.g. file:///path)
        case privateOrLoopback // localhost / loopback / link-local / private / metadata

        public var description: String {
            switch self {
            case .scheme: return "only http and https URLs are allowed"
            case .noHost: return "the URL has no host"
            case .privateOrLoopback: return "the URL points at a local or private address"
            }
        }
    }

    /// Synchronous gate: http/https only, to a host that is not a literal
    /// loopback/link-local/private/metadata address (and not localhost / *.local).
    public static func validatePublicHTTP(_ url: URL) -> Result<Void, Rejection> {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return .failure(.scheme)
        }
        guard let host = url.host?.lowercased(), !host.isEmpty else {
            return .failure(.noHost)
        }
        if isBlockedHostname(host) { return .failure(.privateOrLoopback) }
        // Bracketed IPv6 hosts arrive without brackets from `url.host`.
        if let ip = IPv4Address(host) ?? IPv4Address(stripBrackets(host)) {
            if isBlocked(ipv4: ip) { return .failure(.privateOrLoopback) }
        }
        if let ip6 = IPv6Address(host) ?? IPv6Address(stripBrackets(host)) {
            if isBlocked(ipv6: ip6) { return .failure(.privateOrLoopback) }
        }
        return .success(())
    }

    /// Async strong gate: must pass `validatePublicHTTP` AND every IP the host
    /// resolves to must be global. Returns false on any resolution failure
    /// (fail-closed).
    public static func hostResolvesToPublicOnly(_ url: URL) async -> Bool {
        guard case .success = validatePublicHTTP(url), let host = url.host else { return false }
        // A literal IP already passed the sync check; no DNS needed.
        if IPv4Address(host) != nil || IPv6Address(stripBrackets(host)) != nil { return true }
        let addresses = await resolve(host: host)
        guard !addresses.isEmpty else { return false }
        for addr in addresses {
            if let v4 = IPv4Address(addr), isBlocked(ipv4: v4) { return false }
            if let v6 = IPv6Address(addr), isBlocked(ipv6: v6) { return false }
        }
        return true
    }

    // MARK: - Hostname rules

    private static func isBlockedHostname(_ host: String) -> Bool {
        if host == "localhost" || host.hasSuffix(".localhost") { return true }
        if host == "local" || host.hasSuffix(".local") { return true }   // mDNS / Bonjour
        return false
    }

    private static func stripBrackets(_ host: String) -> String {
        var h = host
        if h.hasPrefix("[") { h.removeFirst() }
        if h.hasSuffix("]") { h.removeLast() }
        return h
    }

    // MARK: - IP range rules

    private static func isBlocked(ipv4 ip: IPv4Address) -> Bool {
        let b = [UInt8](ip.rawValue)
        guard b.count == 4 else { return true }
        switch (b[0], b[1]) {
        case (0, _): return true                         // 0.0.0.0/8 ("this host")
        case (10, _): return true                        // 10.0.0.0/8 private
        case (127, _): return true                       // 127.0.0.0/8 loopback
        case (169, 254): return true                     // 169.254.0.0/16 link-local + metadata
        case (172, let s) where s >= 16 && s <= 31: return true // 172.16.0.0/12 private
        case (192, 168): return true                     // 192.168.0.0/16 private
        case (192, 0) where b[2] == 2: return true       // 192.0.2.0/24 TEST-NET
        case (100, let s) where s >= 64 && s <= 127: return true // 100.64.0.0/10 CGNAT
        default:
            if b[0] >= 224 { return true }               // 224.0.0.0/4 multicast + 240/4 reserved
            return false
        }
    }

    private static func isBlocked(ipv6 ip: IPv6Address) -> Bool {
        let b = [UInt8](ip.rawValue)
        guard b.count == 16 else { return true }
        // ::1 loopback
        if b[0..<15].allSatisfy({ $0 == 0 }) && b[15] == 1 { return true }
        // :: unspecified
        if b.allSatisfy({ $0 == 0 }) { return true }
        // fe80::/10 link-local
        if b[0] == 0xfe && (b[1] & 0xc0) == 0x80 { return true }
        // fc00::/7 unique-local
        if (b[0] & 0xfe) == 0xfc { return true }
        // IPv4-mapped ::ffff:a.b.c.d — re-check the embedded v4.
        if b[0..<10].allSatisfy({ $0 == 0 }) && b[10] == 0xff && b[11] == 0xff {
            if let v4 = IPv4Address(Data(b[12..<16])) { return isBlocked(ipv4: v4) }
        }
        return false
    }

    // MARK: - DNS

    /// Resolve a hostname to its IP-string addresses via getaddrinfo, off the
    /// calling thread. Empty on failure.
    private static func resolve(host: String) async -> [String] {
        await withCheckedContinuation { (cont: CheckedContinuation<[String], Never>) in
            DispatchQueue.global(qos: .utility).async {
                var hints = addrinfo(
                    ai_flags: 0, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM,
                    ai_protocol: 0, ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil
                )
                var result: UnsafeMutablePointer<addrinfo>?
                let status = getaddrinfo(host, nil, &hints, &result)
                guard status == 0, let first = result else { cont.resume(returning: []); return }
                defer { freeaddrinfo(first) }
                var out: [String] = []
                var node: UnsafeMutablePointer<addrinfo>? = first
                while let n = node {
                    var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if getnameinfo(n.pointee.ai_addr, n.pointee.ai_addrlen,
                                   &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 {
                        // Strip any scope suffix (fe80::1%en0) for parsing.
                        let s = String(cString: buffer)
                        out.append(s.components(separatedBy: "%").first ?? s)
                    }
                    node = n.pointee.ai_next
                }
                cont.resume(returning: out)
            }
        }
    }
}
