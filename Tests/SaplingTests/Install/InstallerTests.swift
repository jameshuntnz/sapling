import Foundation
import Testing

@testable import SaplingCore
@testable import SaplingInstall

extension EnvironmentDependentTests {
    @Suite("Installer")
    struct InstallerTests {
        @Test("runs the §9.5 step list in order")
        func stepOrder() async throws {
            try await TemporaryHome.run { _ in
                let names = Installer().steps().map(\.name)
                #expect(names.first == "Platform")
                #expect(names.last == "LaunchDaemon")
                #expect(names.contains("Homebrew"))
                #expect(names.contains("Tart"))
                #expect(names.contains("Egress filter (pf)"))
                // Homebrew must precede everything installed through it.
                let brew = try #require(names.firstIndex(of: "Homebrew"))
                let tart = try #require(names.firstIndex(of: "Tart"))
                #expect(brew < tart)
            }
        }

        /// doctor is install with the fixes withheld — same list, no writes.
        @Test("doctor reports on every step and changes nothing")
        func doctorIsReadOnly() async throws {
            try await TemporaryHome.run { home in
                let results = await Installer().doctor()
                #expect(results.count == Installer().steps().count)
                #expect(results.contains { $0.step == "Platform" })

                // Nothing was created: no config, no key, no home directory.
                #expect(
                    !FileManager.default.fileExists(atPath: home.appendingPathComponent("config.toml").path))
                #expect(
                    !FileManager.default.fileExists(atPath: home.appendingPathComponent("vm_ed25519").path))
            }
        }

        @Test("strips its own marked block out of pf.conf and leaves the rest")
        func removesMarkedBlock() {
            let original = """
                scrub-anchor "com.apple/*"
                anchor "com.apple/*"

                # BEGIN sapling
                anchor "sapling"
                load anchor "sapling" from "/etc/pf.anchors/sapling"
                # END sapling
                """
            let cleaned = Installer.removeMarkedBlock(from: original)
            #expect(!cleaned.contains("sapling"))
            #expect(cleaned.contains("scrub-anchor \"com.apple/*\""))
            #expect(cleaned.contains("anchor \"com.apple/*\""))
        }

        @Test("leaves a pf.conf it never touched alone")
        func removeMarkedBlockIsSafeWhenAbsent() {
            let original =
                "anchor \"com.apple/*\"\nload anchor \"com.apple\" from \"/etc/pf.anchors/com.apple\""
            #expect(Installer.removeMarkedBlock(from: original) == original)
        }

        /// Under sudo, NSHomeDirectory() is /var/root — which is not where
        /// any of this belongs.
        @Test("resolves the owning user's home, not root's, under sudo")
        func installContextUnderSudo() {
            let previous = ProcessInfo.processInfo.environment["SUDO_USER"]
            setenv("SUDO_USER", "someadmin", 1)
            defer {
                if let previous { setenv("SUDO_USER", previous, 1) } else { unsetenv("SUDO_USER") }
            }
            #expect(InstallContext.owningUser == "someadmin")
            #expect(InstallContext.owningUserHome == "/Users/someadmin")
        }

        @Test("uninstall refuses without root rather than half-removing things")
        func uninstallNeedsRoot() async {
            guard getuid() != 0 else { return }
            await #expect(throws: InstallError.self) {
                _ = try await Installer().uninstall(purge: false)
            }
        }

        @Test("upgrade refuses without root")
        func upgradeNeedsRoot() async {
            guard getuid() != 0 else { return }
            await #expect(throws: InstallError.self) {
                _ = try await Installer().upgrade(from: "/bin/echo")
            }
        }
    }
}
