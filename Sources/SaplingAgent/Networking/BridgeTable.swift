import Foundation
import SaplingCore

/// A `bridge*` interface macOS creates for VM and container networking.
///
/// vmnet brings one of these up per network, on demand: the first Apple
/// `container` to start creates one, the first Tart VM creates another, and
/// each is torn down when its last guest exits. They are numbered from
/// `bridge100` in the order they appear, so a name says nothing about which
/// tool owns it — only the subnet does.
public struct HostBridge: Sendable, Equatable {
    /// Interface name, for example `bridge100`.
    public let name: String
    /// The host's address on this bridge.
    ///
    /// Every guest on this network uses it as its default gateway, and the
    /// egress filter permits it as the one private address a job may reach.
    public let address: String
    /// The network in CIDR form, which is what pf tables want.
    public let subnet: String
    /// Prefix length of that network.
    public let prefix: Int

    /// Creates a bridge record.
    public init(name: String, address: String, subnet: String, prefix: Int) {
        self.name = name
        self.address = address
        self.subnet = subnet
        self.prefix = prefix
    }
}

/// The host's view of job networking, which is the only view worth trusting.
///
/// Everything a tool reports about its own network is hearsay. Measured on
/// `mac-mini-01` while a job was failing: `container list` printed
/// `192.168.64.4/24` for a container whose gateway had ceased to exist,
/// `container system status` said `running`, and `container network list`
/// still declared the subnet — while `ifconfig` showed no `bridge100` at all.
/// Containers started in that state came up, were assigned addresses, and
/// could not resolve DNS.
///
/// So every network decision here is made against the host's interface list:
/// an interface either owns the gateway for a guest's subnet or it does not,
/// and nothing else counts as evidence.
public enum BridgeTable {
    /// The bridge interfaces that exist right now.
    ///
    /// Re-read on every use rather than cached at startup: bridges appear when
    /// the first guest starts and vanish when the last one exits, so a cached
    /// answer is wrong within minutes on an idle node.
    /// - Returns: Every `bridge*` interface carrying an IPv4 address.
    /// - Throws: If `ifconfig` cannot be run.
    public static func current() async throws -> [HostBridge] {
        let result = try await ProcessRunner.run("ifconfig", [], timeout: .seconds(20))
        guard result.succeeded else {
            throw NetworkGuardError.loadFailed("could not run ifconfig: \(result.stderr)")
        }
        return parse(ifconfig: result.stdout)
    }

    /// The bridge a guest address sits behind, or `nil` if nothing does.
    ///
    /// `nil` is the orphaned-environment signal: the guest holds a valid
    /// address on a network the host has no interface for, so every packet it
    /// sends fails at ARP with `EHOSTUNREACH` — instantly, which is what
    /// distinguishes this from a packet the egress filter dropped silently.
    /// - Parameters:
    ///   - address: A guest address, with or without a `/prefix` suffix.
    ///   - bridges: The host's bridges, from `current()`.
    /// - Returns: The bridge whose network contains the address.
    public static func owner(of address: String, in bridges: [HostBridge]) -> HostBridge? {
        let bare = String(address.split(separator: "/").first ?? "")
        return bridges.first { bridge in
            networkCIDR(address: bare, prefix: bridge.prefix) == bridge.subnet
        }
    }

    /// Split out from the `ifconfig` call so the parsing can be exercised
    /// against real output containing bridges — a dev Mac has none, and the
    /// pf rules are only as correct as this.
    static func parse(ifconfig output: String) -> [HostBridge] {
        var bridges: [HostBridge] = []
        var currentName: String?

        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if !line.hasPrefix("\t") && !line.hasPrefix(" ") {
                currentName = line.split(separator: ":").first.map(String.init)
                continue
            }
            guard let name = currentName, name.hasPrefix("bridge") else { continue }

            // ifconfig indents continuation lines with a tab, so splitting
            // on spaces alone leaves "\tinet" and never matches.
            let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard let inetIndex = fields.firstIndex(of: "inet"),
                inetIndex + 1 < fields.count,
                let maskIndex = fields.firstIndex(of: "netmask"),
                maskIndex + 1 < fields.count
            else { continue }

            let address = fields[inetIndex + 1]
            guard let prefix = prefixLength(fromHexNetmask: fields[maskIndex + 1]),
                let subnet = networkCIDR(address: address, prefix: prefix)
            else { continue }

            bridges.append(HostBridge(name: name, address: address, subnet: subnet, prefix: prefix))
        }
        return bridges
    }

    // MARK: - Address maths

    /// The gateway vmnet assigns for a subnet: its first usable host.
    ///
    /// `192.168.64.0/24` becomes `192.168.64.1/32`. The gateway has to stay
    /// reachable or the environment loses DHCP, DNS, and the cache proxy.
    static func gatewayCIDR(forSubnet subnet: String) -> String? {
        let parts = subnet.split(separator: "/")
        guard parts.count == 2, let prefix = Int(parts[1]), prefix <= 32,
            let packed = packed(String(parts[0]))
        else { return nil }
        let gateway = (packed & mask(prefix)) | 1
        return dotted(gateway) + "/32"
    }

    /// ifconfig prints netmasks as `0xffffff00`; pf wants a prefix length.
    static func prefixLength(fromHexNetmask hex: String) -> Int? {
        let cleaned = hex.hasPrefix("0x") ? String(hex.dropFirst(2)) : hex
        guard let value = UInt32(cleaned, radix: 16) else { return nil }
        return value.nonzeroBitCount
    }

    /// The network an address belongs to, in CIDR form.
    static func networkCIDR(address: String, prefix: Int) -> String? {
        guard prefix >= 0, prefix <= 32, let packed = packed(address) else { return nil }
        return dotted(packed & mask(prefix)) + "/\(prefix)"
    }

    private static func packed(_ address: String) -> UInt32? {
        let octets = address.split(separator: ".").compactMap { UInt32($0) }
        guard octets.count == 4, octets.allSatisfy({ $0 <= 255 }) else { return nil }
        return (octets[0] << 24) | (octets[1] << 16) | (octets[2] << 8) | octets[3]
    }

    private static func mask(_ prefix: Int) -> UInt32 {
        prefix == 0 ? 0 : ~UInt32(0) << (32 - prefix)
    }

    private static func dotted(_ packed: UInt32) -> String {
        "\((packed >> 24) & 0xFF).\((packed >> 16) & 0xFF).\((packed >> 8) & 0xFF).\(packed & 0xFF)"
    }
}
