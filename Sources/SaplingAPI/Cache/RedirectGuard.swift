import Foundation

/// Keeps the proxy's redirects on the public internet.
///
/// The proxy runs on the host, outside the egress filter, so a redirect to a
/// private address would let a job read the LAN through it. Requiring `https`
/// to a named host means a private destination would also need a certificate
/// valid for its name.
final class RedirectGuard: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        guard let url = request.url, url.scheme == "https", let host = url.host, !host.isEmpty else {
            return nil
        }
        let isLiteral = host.contains(":") || host.split(separator: ".").allSatisfy { Int($0) != nil }
        return isLiteral ? nil : request
    }
}
