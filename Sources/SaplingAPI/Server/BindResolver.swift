import Foundation
import SaplingCore

/// Works out which address the control plane should listen on.
///
/// §8 makes Tailscale interface binding the access control: there is no
/// separate auth layer, so binding the wrong interface is the whole security
/// model failing open. When `bind = "tailscale"` and no Tailscale address can
/// be found, this refuses rather than falling back to something broader.
enum BindResolver {
    struct Resolution: Sendable {
        let hostname: String
        let description: String
    }

    static func resolve(_ mode: BindMode) async throws -> Resolution {
        switch mode {
        case .loopback:
            return Resolution(hostname: "127.0.0.1", description: "loopback only")
        case .all:
            return Resolution(
                hostname: "0.0.0.0", description: "ALL interfaces — exposed beyond Tailscale (§8)")
        case .explicit(let address):
            return Resolution(hostname: address, description: "explicit address \(address)")
        case .tailscale:
            guard let address = await tailscaleAddress() else {
                throw ConfigError(
                    """
                    server.bind is "tailscale" but no Tailscale IPv4 address was found. \
                    Run `tailscale up` and try again, or set server.bind explicitly in \
                    \(SaplingPaths.configFile.path). Sapling will not fall back to a wider \
                    interface, because Tailscale membership is the only access control (§8).
                    """)
            }
            return Resolution(hostname: address, description: "Tailscale address \(address)")
        }
    }

    /// Ask the Tailscale CLI first, then fall back to scanning interfaces for
    /// a CGNAT address — the CLI isn't always on the daemon's PATH.
    static func tailscaleAddress() async -> String? {
        if let result = try? await ProcessRunner.run("tailscale", ["ip", "-4"], timeout: .seconds(10)),
            result.succeeded
        {
            let address = result.trimmedOutput.split(separator: "\n").first.map(String.init)
            if let address, !address.isEmpty { return address }
        }
        // Tailscale hands out addresses from 100.64.0.0/10 on a utun device.
        if let result = try? await ProcessRunner.run("ifconfig", [], timeout: .seconds(10)),
            result.succeeded
        {
            for line in result.stdout.split(separator: "\n") {
                // Continuation lines are tab-indented; splitting on spaces
                // alone leaves "\tinet" and matches nothing.
                let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
                guard let index = fields.firstIndex(of: "inet"), index + 1 < fields.count else { continue }
                let address = fields[index + 1]
                if isCGNAT(address) { return address }
            }
        }
        return nil
    }

    static func isCGNAT(_ address: String) -> Bool {
        let octets = address.split(separator: ".").compactMap { Int($0) }
        guard octets.count == 4, octets[0] == 100 else { return false }
        return (64...127).contains(octets[1])
    }
}
