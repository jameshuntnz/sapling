import Foundation
import Testing

@testable import SaplingCore
@testable import SaplingInstall

extension EnvironmentDependentTests {
    @Suite("Install steps")
    struct StepTests {
        @Test("platform check passes on this Mac")
        func platformCheck() async {
            // The suite only runs on macOS 26+ arm64 in the first place.
            #expect(await PlatformStep().check().isOK)
        }

        @Test("reports missing tooling as fixable, not as a hard failure")
        func missingToolingIsFixable() async {
            // This machine is a monitor/dev box: tart, container, and
            // tailscale are all absent, which is exactly the state
            // `sapling install` has to be able to converge from.
            for step: any InstallStep in [TartStep(), ContainerStep(), TailscaleStep()] {
                let state = await step.check()
                if ProcessRunner.which(toolName(for: step)) == nil {
                    if case .fixable = state {
                    } else {
                        Issue.record(
                            "\(step.name) should be fixable when its binary is missing, got \(state)")
                    }
                }
            }
        }

        func toolName(for step: any InstallStep) -> String {
            switch step.name {
            case "Tart": "tart"
            case "Apple container": "container"
            default: "tailscale"
            }
        }

        /// §9.5's central promise: every step checks before it acts, so
        /// running twice converges instead of erroring or duplicating.
        @Test("SSH key step generates a usable key and is idempotent")
        func sshKeyStepIsIdempotent() async throws {
            try await TemporaryHome.run { home in
                let step = SSHKeyStep()

                if case .fixable = await step.check() {
                } else {
                    Issue.record("expected a missing key to be fixable")
                }

                _ = try await step.fix()
                #expect(await step.check().isOK)

                let privateKey = home.appendingPathComponent("vm_ed25519")
                let publicKey = home.appendingPathComponent("vm_ed25519.pub")
                #expect(FileManager.default.fileExists(atPath: privateKey.path))

                let attributes = try FileManager.default.attributesOfItem(atPath: privateKey.path)
                #expect(attributes[.posixPermissions] as? Int == 0o600)

                let publicKeyText = try String(contentsOf: publicKey, encoding: .utf8)
                #expect(publicKeyText.hasPrefix("ssh-ed25519 "))
                #expect(publicKeyText.contains("sapling-vm"))

                // Re-running must not disturb the key that already works.
                let before = try Data(contentsOf: privateKey)
                #expect(await step.check().isOK)
                #expect(try Data(contentsOf: privateKey) == before)
            }
        }

        @Test("config step goes from fixable to ok once a valid config exists")
        func configStep() async throws {
            try await TemporaryHome.run { _ in
                let step = ConfigStep(options: InstallOptions())
                if case .fixable = await step.check() {
                } else {
                    Issue.record("expected a missing config to be fixable")
                }

                var config = SaplingConfig()
                config.github.repos = ["acme/widgets"]
                config.github.auth = .pat
                config.github.token = "ghp_example"
                try config.save()

                #expect(await step.check().isOK)
            }
        }

        @Test("config step accepts credentials from flags without prompting")
        func configStepNonInteractive() async throws {
            try await TemporaryHome.run { _ in
                let options = InstallOptions(
                    githubToken: "ghp_from_flag",
                    repos: ["acme/widgets"],
                    nodeName: "mac-mini-01",
                    nonInteractive: true
                )
                _ = try await ConfigStep(options: options).fix()

                let written = try SaplingConfig.load()
                #expect(written.github.auth == .pat)
                #expect(written.github.token == "ghp_from_flag")
                #expect(written.github.repos == ["acme/widgets"])
                #expect(written.node.name == "mac-mini-01")
            }
        }

        @Test("firewall step reports ok when filtering is switched off")
        func firewallDisabled() async {
            let state = await FirewallStep(enabled: false).check()
            #expect(state.isOK)
            #expect(state.summary.contains("LAN"))
        }

        @Test("base image step explains the manual route it can't automate")
        func baseImageInstructions() {
            let instructions = BaseImageStep.instructions(imageName: "sapling-macos-base")
            #expect(instructions.contains("tart clone"))
            #expect(instructions.contains("authorized_keys"))
            #expect(instructions.contains("Setup Assistant"))
        }
    }

    // MARK: - Installer
}
