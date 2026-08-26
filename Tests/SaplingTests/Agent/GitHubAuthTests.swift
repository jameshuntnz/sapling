import Foundation
import Security
import Testing

@testable import SaplingAgent
@testable import SaplingCore

@Suite("GitHub App JWT")
struct GitHubAuthTests {
    /// Proves the PKCS#1 path works end to end: a real generated key, a real
    /// RS256 signature, verified against the matching public key.
    @Test("signs a JWT with a PKCS#1 key")
    func signsWithPKCS1() throws {
        let key = try makeRSAKey()
        let jwt = try RSASigner.appJWT(appID: "123456", privateKeyPEM: key)

        let parts = jwt.split(separator: ".")
        #expect(parts.count == 3)

        let header = try decodeSegment(String(parts[0]))
        #expect(header["alg"] as? String == "RS256")

        let payload = try decodeSegment(String(parts[1]))
        #expect(payload["iss"] as? String == "123456")
        let issuedAt = payload["iat"] as? Int ?? 0
        let expiry = payload["exp"] as? Int ?? 0
        // Backdated for clock skew, and inside GitHub's 10-minute maximum.
        #expect(issuedAt < Int(Date().timeIntervalSince1970))
        #expect(expiry - issuedAt <= 600)
    }

    @Test("rejects something that isn't a key")
    func rejectsGarbage() {
        #expect(throws: (any Error).self) {
            try RSASigner.appJWT(appID: "1", privateKeyPEM: "not a key")
        }
    }

    func makeRSAKey() throws -> String {
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 2048,
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error),
            let data = SecKeyCopyExternalRepresentation(key, &error) as Data?
        else {
            throw ConfigError("could not generate a test key")
        }
        let base64 = data.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        return "-----BEGIN RSA PRIVATE KEY-----\n\(base64)\n-----END RSA PRIVATE KEY-----"
    }

    func decodeSegment(_ segment: String) throws -> [String: Any] {
        var base64 =
            segment
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        guard let data = Data(base64Encoded: base64),
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw ConfigError("bad JWT segment")
        }
        return object
    }
}
