import CryptoKit
import Foundation
import Testing

@testable import SaplingCore

@Suite("Release signatures")
struct ReleaseSignatureTests {
    let pair = ReleaseSignature.generateKeyPair()
    let sums = Data("abc123  sapling-0.4.0-macos-arm64.tar.gz\n".utf8)

    @Test("a release signed by a trusted key verifies")
    func roundTrip() throws {
        let signature = try ReleaseSignature.sign(checksums: sums, tag: "v0.4.0", privateKey: pair.privateKey)
        try ReleaseSignature.verify(
            signature: signature, checksums: sums, tag: "v0.4.0", keys: [pair.publicKey])
    }

    /// An old genuine release republished under a newer tag would roll a
    /// node back, or freeze it on a version nothing outranks.
    @Test("a signature does not carry over to another tag, other checksums or another key")
    func refusals() throws {
        let signature = try ReleaseSignature.sign(checksums: sums, tag: "v0.4.0", privateKey: pair.privateKey)
        #expect(throws: ReleaseSignature.Failure.self) {
            try ReleaseSignature.verify(
                signature: signature, checksums: sums, tag: "v9.9.9", keys: [pair.publicKey])
        }
        #expect(throws: ReleaseSignature.Failure.self) {
            try ReleaseSignature.verify(
                signature: signature, checksums: sums + Data("x".utf8), tag: "v0.4.0", keys: [pair.publicKey])
        }
        let other = ReleaseSignature.generateKeyPair()
        #expect(throws: ReleaseSignature.Failure.self) {
            try ReleaseSignature.verify(
                signature: signature, checksums: sums, tag: "v0.4.0", keys: [other.publicKey])
        }
        #expect(throws: ReleaseSignature.Failure.self) {
            try ReleaseSignature.verify(signature: "not base64!", checksums: sums, tag: "v0.4.0")
        }
    }

    @Test("every built-in key is a valid Ed25519 public key")
    func builtInKeys() throws {
        #expect(!ReleaseSignature.trustedKeys.isEmpty)
        for key in ReleaseSignature.trustedKeys {
            let data = try #require(Data(base64Encoded: key))
            _ = try Curve25519.Signing.PublicKey(rawRepresentation: data)
        }
    }
}
