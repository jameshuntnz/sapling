import Foundation

/// A configuration problem the operator has to resolve.
public struct ConfigError: Error, LocalizedError, Sendable {
    /// What is wrong, phrased so it can be printed verbatim.
    public let message: String
    /// Creates a configuration error.
    public init(_ message: String) { self.message = message }
    /// The message, for `LocalizedError`.
    public var errorDescription: String? { message }
}
