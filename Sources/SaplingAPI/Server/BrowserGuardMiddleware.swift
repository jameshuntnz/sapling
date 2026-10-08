import Foundation
import Vapor

/// Refuses requests a web browser made on someone else's behalf.
///
/// The API has no auth, so a page open on any tailnet machine could otherwise
/// drive it: a cross-site POST needs no preflight when it has no body, and a
/// page whose domain is rebound to the node's address reads responses as its
/// own. No client of this API is a browser, so any `Origin` is refused, and the
/// `Host` must be a name a tailnet client would use — an attacker's domain,
/// rebound or not, is neither.
struct BrowserGuardMiddleware: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        if request.headers.first(name: .origin) != nil {
            return errorResponse(.forbidden, "forbidden", "browser requests are not accepted")
        }
        if let host = request.headers.first(name: .host), !Self.isTrustedHost(host) {
            return errorResponse(
                .forbidden, "forbidden",
                "\(host) is not a tailnet address; use the node's IP, MagicDNS name or localhost")
        }
        return try await next.respond(to: request)
    }

    /// Whether a `Host` header names something public DNS cannot answer for.
    ///
    /// An IP literal, `localhost`, a single-label name, or a MagicDNS or
    /// `.local` name.
    static func isTrustedHost(_ header: String) -> Bool {
        var host = header.lowercased()
        if host.hasPrefix("["), let close = host.firstIndex(of: "]") {
            let literal = host[host.index(after: host.startIndex)..<close]
            return !literal.isEmpty && literal.allSatisfy { $0.isHexDigit || $0 == ":" || $0 == "." }
        }
        if let colon = host.lastIndex(of: ":") { host = String(host[..<colon]) }
        if host.hasSuffix(".") { host.removeLast() }
        guard !host.isEmpty else { return false }
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        let isIPv4 = octets.count == 4 && octets.allSatisfy { UInt8($0) != nil }
        if isIPv4 || host == "localhost" || !host.contains(".") { return true }
        return host.hasSuffix(".ts.net") || host.hasSuffix(".local")
    }
}
