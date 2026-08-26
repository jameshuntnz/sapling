import Foundation
import Security
import Testing

@testable import SaplingAgent

@Suite("PKCS#8 keys")
struct PKCS8Tests {
    static func derLength(_ count: Int) -> [UInt8] {
        if count < 0x80 { return [UInt8(count)] }
        var bytes: [UInt8] = []
        var value = count
        while value > 0 {
            bytes.insert(UInt8(value & 0xFF), at: 0)
            value >>= 8
        }
        return [UInt8(0x80 | bytes.count)] + bytes
    }

    static func derWrap(tag: UInt8, _ content: [UInt8]) -> [UInt8] {
        [tag] + derLength(content.count) + content
    }

    /// GitHub hands out PKCS#1, but anyone who round-trips the key through
    /// openssl ends up with PKCS#8 — and that key is perfectly valid.
    @Test("signs a JWT with a PKCS#8-wrapped key")
    func signsWithPKCS8() throws {
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 2048,
        ]
        var error: Unmanaged<CFError>?
        let key = try #require(SecKeyCreateRandomKey(attributes as CFDictionary, &error))
        let pkcs1 = try #require(SecKeyCopyExternalRepresentation(key, &error) as Data?)

        // PrivateKeyInfo ::= SEQUENCE { version, AlgorithmIdentifier, OCTET STRING }
        let rsaEncryptionAlgorithmID: [UInt8] = [
            0x30, 0x0d, 0x06, 0x09, 0x2a, 0x86, 0x48, 0x86,
            0xf7, 0x0d, 0x01, 0x01, 0x01, 0x05, 0x00,
        ]
        let body =
            [0x02, 0x01, 0x00] as [UInt8]
            + rsaEncryptionAlgorithmID
            + Self.derWrap(tag: 0x04, [UInt8](pkcs1))
        let pkcs8 = Data(Self.derWrap(tag: 0x30, body))

        let base64 = pkcs8.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        let pem = "-----BEGIN PRIVATE KEY-----\n\(base64)\n-----END PRIVATE KEY-----"

        let jwt = try RSASigner.appJWT(appID: "999", privateKeyPEM: pem)
        #expect(jwt.split(separator: ".").count == 3)
    }

    @Test("rejects a PKCS#8 header wrapped around nonsense")
    func rejectsTruncatedPKCS8() {
        let pem = "-----BEGIN PRIVATE KEY-----\nMAAA\n-----END PRIVATE KEY-----"
        #expect(throws: (any Error).self) {
            try RSASigner.loadPrivateKey(pem: pem)
        }
    }

    @Test("base64url encoding drops padding and swaps the URL-unsafe characters")
    func base64URL() {
        #expect(RSASigner.base64URL(Data([0xFB, 0xFF, 0xFE])) == "-__-")
        #expect(!RSASigner.base64URL(Data([0x01])).contains("="))
    }
}
