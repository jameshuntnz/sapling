import Foundation
import SaplingAgent
import SaplingCore

/// Checks that pf evaluates Sapling's egress anchor.
public struct FirewallStep: InstallStep {
    /// Name shown by `install` and `doctor`.
    public let name = "Egress filter (pf)"
    let enabled: Bool
    /// Creates the step.
    public init(enabled: Bool = true) { self.enabled = enabled }

    static let beginMarker = "# BEGIN sapling"
    static let endMarker = "# END sapling"
    static let pfConfPath = "/etc/pf.conf"

    static var anchorBlock: String {
        """
        \(beginMarker)
        anchor "\(NetworkGuard.anchorName)"
        load anchor "\(NetworkGuard.anchorName)" from "\(NetworkGuard.anchorPath)"
        \(endMarker)
        """
    }

    /// Reports whether this step is already satisfied.
    public func check() async -> StepState {
        guard enabled else {
            return .ok("disabled in config (jobs can reach your LAN — see §8)")
        }
        guard let pfConf = try? String(contentsOfFile: Self.pfConfPath, encoding: .utf8) else {
            return .failed("could not read \(Self.pfConfPath)")
        }
        guard pfConf.contains(Self.beginMarker) else {
            return .fixable("\(Self.pfConfPath) does not load the sapling anchor")
        }
        guard FileManager.default.fileExists(atPath: NetworkGuard.anchorPath) else {
            return .fixable("anchor file \(NetworkGuard.anchorPath) is missing")
        }
        switch await NetworkGuard.verify() {
        case .loaded(let rules):
            return .ok("anchor loaded, \(rules.count) rule(s) active")
        case .empty:
            // Expected before the first job: the anchor is wired but empty
            // until a bridge interface exists to write rules about.
            return .ok("anchor wired and empty; rules are written when the first job starts")
        case .unverifiable(let reason):
            return .unverified("\(Self.pfConfPath) loads the anchor, but \(reason)")
        }
    }

    /// Installs or configures the pf anchor that keeps jobs off your LAN.
    public func fix() async throws -> String {
        guard InstallContext.isRoot else {
            throw InstallError("editing \(Self.pfConfPath) needs root — re-run with sudo")
        }

        if !FileManager.default.fileExists(atPath: NetworkGuard.anchorPath) {
            try FileManager.default.createDirectory(
                atPath: (NetworkGuard.anchorPath as NSString).deletingLastPathComponent,
                withIntermediateDirectories: true
            )
            // pfctl refuses to load pf.conf if a referenced anchor file is
            // missing, so seed an empty one.
            try "# Populated by `sapling serve`.\n".write(
                toFile: NetworkGuard.anchorPath,
                atomically: true,
                encoding: .utf8
            )
        }

        var pfConf = (try? String(contentsOfFile: Self.pfConfPath, encoding: .utf8)) ?? ""
        if !pfConf.contains(Self.beginMarker) {
            try? pfConf.write(toFile: Self.pfConfPath + ".sapling-backup", atomically: true, encoding: .utf8)
            // Appended, not inserted: pf requires filter rules last, and
            // anything already in pf.conf is filter rules or earlier.
            if !pfConf.hasSuffix("\n") { pfConf += "\n" }
            pfConf += "\n" + Self.anchorBlock + "\n"
            try pfConf.write(toFile: Self.pfConfPath, atomically: true, encoding: .utf8)
        }

        let reload = try await ProcessRunner.run("pfctl", ["-f", Self.pfConfPath], timeout: .seconds(30))
        guard reload.succeeded || reload.stderr.contains("already enabled") else {
            throw InstallError("`pfctl -f \(Self.pfConfPath)` failed: \(reload.stderr)")
        }
        _ = try? await ProcessRunner.run("pfctl", ["-E"], timeout: .seconds(20))
        return
            "wired the sapling anchor into \(Self.pfConfPath) (backup at \(Self.pfConfPath).sapling-backup)"
    }
}

// MARK: - 9. Base macOS VM image

/// §9.5 step 7: unavoidably manual. The first boot of any macOS VM requires
/// walking through Setup Assistant, and Apple provides no supported way to
/// script past it.
