import Foundation
import SaplingCore
import Security

/// Minimal RS256 signing for GitHub App JWTs.
///
/// GitHub Apps need a short-lived JWT signed with the app's RSA private key,
/// exchanged for an installation token. That's the only cryptography Sapling
/// does, so it uses Security.framework directly instead of taking on a JWT
/// dependency for one algorithm.
enum RSASigner {
    struct SigningError: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Load a PEM private key.
    ///
    /// GitHub hands out PKCS#1 ("BEGIN RSA PRIVATE KEY"); people who round-trip
    /// the key through openssl often end up with PKCS#8 ("BEGIN PRIVATE KEY"), so
    /// accept both rather than failing on a key that is genuinely fine.
    static func loadPrivateKey(pem: String) throws -> SecKey {
        let isPKCS8 = pem.contains("BEGIN PRIVATE KEY")
        let body =
            pem
            .components(separatedBy: .newlines)
            .filter { !$0.hasPrefix("-----") && !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .joined()

        guard var der = Data(base64Encoded: body) else {
            throw SigningError(message: "GitHub App private key is not valid PEM")
        }
        if isPKCS8 {
            der = try stripPKCS8Wrapper(der)
        }

        var error: Unmanaged<CFError>?
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
        ]
        guard let key = SecKeyCreateWithData(der as CFData, attributes as CFDictionary, &error) else {
            let detail = error?.takeRetainedValue().localizedDescription ?? "unknown error"
            throw SigningError(message: "could not load GitHub App private key: \(detail)")
        }
        return key
    }

    /// Unwrap a PKCS#8 `PrivateKeyInfo` down to the PKCS#1 `RSAPrivateKey` that
    /// SecKeyCreateWithData expects.
    ///
    /// Just enough DER walking to skip the version integer and the algorithm identifier.
    private static func stripPKCS8Wrapper(_ der: Data) throws -> Data {
        var index = 0
        let bytes = [UInt8](der)

        func readLength() throws -> Int {
            guard index < bytes.count else { throw SigningError(message: "truncated PKCS#8 key") }
            let first = bytes[index]
            index += 1
            if first & 0x80 == 0 { return Int(first) }
            let count = Int(first & 0x7F)
            guard count > 0, index + count <= bytes.count else {
                throw SigningError(message: "malformed PKCS#8 length")
            }
            var value = 0
            for _ in 0..<count {
                value = (value << 8) | Int(bytes[index])
                index += 1
            }
            return value
        }

        func expect(tag: UInt8) throws -> Int {
            guard index < bytes.count, bytes[index] == tag else {
                throw SigningError(message: "unexpected DER tag in PKCS#8 key")
            }
            index += 1
            return try readLength()
        }

        _ = try expect(tag: 0x30)  // SEQUENCE PrivateKeyInfo
        let versionLength = try expect(tag: 0x02)  // INTEGER version
        index += versionLength
        let algorithmLength = try expect(tag: 0x30)  // SEQUENCE AlgorithmIdentifier
        index += algorithmLength
        let keyLength = try expect(tag: 0x04)  // OCTET STRING privateKey

        guard index + keyLength <= bytes.count else {
            throw SigningError(message: "truncated PKCS#8 private key body")
        }
        return Data(bytes[index..<(index + keyLength)])
    }

    static func sign(_ message: Data, with key: SecKey) throws -> Data {
        var error: Unmanaged<CFError>?
        guard
            let signature = SecKeyCreateSignature(
                key,
                .rsaSignatureMessagePKCS1v15SHA256,
                message as CFData,
                &error
            )
        else {
            let detail = error?.takeRetainedValue().localizedDescription ?? "unknown error"
            throw SigningError(message: "JWT signing failed: \(detail)")
        }
        return signature as Data
    }

    /// A GitHub App JWT: `iat` backdated 60s to tolerate clock skew, `exp` at
    /// the 10 minute maximum GitHub accepts.
    static func appJWT(appID: String, privateKeyPEM: String) throws -> String {
        let key = try loadPrivateKey(pem: privateKeyPEM)
        let now = Int(Date().timeIntervalSince1970)
        let header = ["alg": "RS256", "typ": "JWT"]
        let payload: [String: Any] = [
            "iat": now - 60,
            "exp": now + 540,
            "iss": appID,
        ]

        let headerData = try JSONSerialization.data(withJSONObject: header, options: [.sortedKeys])
        let payloadData = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let signingInput = "\(base64URL(headerData)).\(base64URL(payloadData))"
        let signature = try sign(Data(signingInput.utf8), with: key)
        return "\(signingInput).\(base64URL(signature))"
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// Supplies a bearer token for the GitHub API, refreshing installation tokens
/// before they expire. An actor because the poll loop and the job-launch path
/// both ask for a token and must not race to mint two.
actor GitHubTokenProvider {
    private let config: GitHubConfig
    private var cachedToken: String?
    private var cachedExpiry: Date?

    init(config: GitHubConfig) {
        self.config = config
    }

    func token() async throws -> String {
        switch config.auth {
        case .pat:
            guard let token = config.token, !token.isEmpty else {
                throw ConfigError("github.auth is \"pat\" but no token is configured")
            }
            return token
        case .app:
            if let cachedToken, let cachedExpiry, cachedExpiry > Date().addingTimeInterval(120) {
                return cachedToken
            }
            let fresh = try await mintInstallationToken()
            cachedToken = fresh.token
            cachedExpiry = fresh.expiresAt
            return fresh.token
        }
    }

    /// Force the next `token()` call to mint a new one.
    ///
    /// Called when the API returns 401 so a clock skew or a revoked token self-heals.
    func invalidate() {
        cachedToken = nil
        cachedExpiry = nil
    }

    private struct InstallationToken: Decodable {
        let token: String
        let expiresAt: Date
    }

    private func mintInstallationToken() async throws -> InstallationToken {
        guard let appID = config.appID,
            let installationID = config.installationID,
            let keyPath = config.resolvedPrivateKeyPath
        else {
            throw ConfigError(
                "GitHub App config is incomplete (need app_id, installation_id, private_key_path)")
        }
        let pem = try String(contentsOfFile: keyPath, encoding: .utf8)
        let jwt = try RSASigner.appJWT(appID: appID, privateKeyPEM: pem)

        guard let url = URL(string: "\(config.apiBaseURL)/app/installations/\(installationID)/access_tokens")
        else {
            throw ConfigError("github.api_base_url is not a valid URL: \(config.apiBaseURL)")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("sapling/\(SaplingVersion.current)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            let body = String(decoding: data, as: UTF8.self)
            throw GitHubError(statusCode: status, message: "could not mint installation token: \(body)")
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(InstallationToken.self, from: data)
    }
}

struct GitHubError: Error, LocalizedError, Sendable {
    let statusCode: Int
    let message: String

    var errorDescription: String? { "GitHub API error \(statusCode): \(message)" }

    var isAuthFailure: Bool { statusCode == 401 }
    var isRateLimited: Bool { statusCode == 403 || statusCode == 429 }
}
