import CryptoKit
import Foundation

/// The Ed25519 signature that ties a release's checksums to its tag.
///
/// `SHA256SUMS` sits beside the archive it describes, so on its own it proves
/// nothing about who published either. The signature does: it is made with a
/// key only the release workflow holds, and checked against public keys built
/// into the binary. The tag is signed too, so a genuine old release cannot be
/// republished under a newer tag to roll nodes back or freeze them.
public enum ReleaseSignature {
    /// Name of the signature asset published beside `SHA256SUMS`.
    public static let assetName = "SHA256SUMS.sig"

    /// Base64 Ed25519 public keys whose signatures a node accepts.
    ///
    /// More than one so a key can be rotated: add the new key, release with
    /// it, then drop the old one.
    public static let trustedKeys = [
        "hXZPD+I663ejTjSmiSEKGT5iGeBRVVWihubmGK1qMuM="
    ]

    /// Why a signature was not accepted.
    public struct Failure: Error, LocalizedError, Sendable {
        /// What went wrong, phrased for a person.
        public let message: String
        /// Describes the failure.
        public var errorDescription: String? { message }
    }

    /// The bytes that are signed: a domain label, the tag, then the checksums.
    static func message(tag: String, checksums: Data) -> Data {
        Data("sapling-release-v1\n\(tag)\n".utf8) + checksums
    }

    /// Signs a release's checksums.
    ///
    /// - Parameters:
    ///   - checksums: The `SHA256SUMS` file's contents.
    ///   - tag: The release tag.
    ///   - privateKey: Base64 of the 32-byte Ed25519 private key.
    /// - Returns: The signature, base64.
    /// - Throws: `Failure` if the key is malformed.
    public static func sign(checksums: Data, tag: String, privateKey: String) throws -> String {
        guard let raw = Data(base64Encoded: privateKey.trimmingCharacters(in: .whitespacesAndNewlines)),
            let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw)
        else {
            throw Failure(message: "the signing key is not a base64 Ed25519 private key")
        }
        return try key.signature(for: message(tag: tag, checksums: checksums)).base64EncodedString()
    }

    /// Checks a release's signature against the trusted keys.
    ///
    /// - Parameters:
    ///   - signature: The `SHA256SUMS.sig` file's contents, base64.
    ///   - checksums: The `SHA256SUMS` file's contents.
    ///   - tag: The tag the release was downloaded as.
    ///   - keys: Base64 public keys to accept; the built-in ones by default.
    /// - Throws: `Failure` unless one of the keys made the signature.
    public static func verify(
        signature: String, checksums: Data, tag: String, keys: [String] = trustedKeys
    ) throws {
        guard let raw = Data(base64Encoded: signature.trimmingCharacters(in: .whitespacesAndNewlines))
        else {
            throw Failure(message: "the release signature is not base64")
        }
        let signed = message(tag: tag, checksums: checksums)
        for key in keys {
            guard let data = Data(base64Encoded: key),
                let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: data)
            else { continue }
            if publicKey.isValidSignature(raw, for: signed) { return }
        }
        throw Failure(message: "the release is not signed by a trusted Sapling release key")
    }

    /// A new key pair, base64.
    ///
    /// - Returns: The private key, for the release workflow's secret, and the
    ///   public key, for `trustedKeys`.
    public static func generateKeyPair() -> (privateKey: String, publicKey: String) {
        let key = Curve25519.Signing.PrivateKey()
        return (
            key.rawRepresentation.base64EncodedString(), key.publicKey.rawRepresentation.base64EncodedString()
        )
    }
}
