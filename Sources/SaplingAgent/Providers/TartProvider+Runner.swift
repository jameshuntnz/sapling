import Foundation
import SaplingCore

extension TartProvider {
    /// Make sure the VM has a runner GitHub will accept, downloading one if not.
    func ensureRunnerUsable(ip: String, events: any EventSink) async throws {
        let check = try await ProcessRunner.run(
            "ssh",
            sshArguments(ip: ip) + [
                "test -x ~/actions-runner/run.sh && ~/actions-runner/bin/Runner.Listener --version || echo missing"
            ],
            timeout: .seconds(30)
        )
        let version = check.trimmedOutput
        if version == "missing" {
            await events.log(
                "actions-runner not found in base image — downloading it into the VM (bake it in to avoid this: docs/BASE-IMAGE.md)"
            )
        } else if await DeprecatedRunners.shared.isRefused(version) {
            await events.log(
                "the base image's runner \(version) is deprecated — downloading the current one into the VM "
                    + "(refresh the image to avoid this: docs/BASE-IMAGE.md)"
            )
        } else {
            return
        }

        let script = """
            set -euo pipefail
            mkdir -p ~/actions-runner && cd ~/actions-runner
            VERSION=$(curl -fsSL https://api.github.com/repos/actions/runner/releases/latest | sed -n 's/.*"tag_name": *"v\\([^"]*\\)".*/\\1/p' | head -1)
            curl -fsSL -o runner.tar.gz "https://github.com/actions/runner/releases/download/v${VERSION}/actions-runner-osx-arm64-${VERSION}.tar.gz"
            tar xzf runner.tar.gz && rm runner.tar.gz
            """
        let install = try await ProcessRunner.run(
            "ssh",
            sshArguments(ip: ip) + ["bash -s"],
            standardInput: script,
            timeout: .seconds(900)
        )
        guard install.succeeded else {
            throw ProviderError("could not install the actions runner in the VM: \(install.stderr)")
        }
    }

    /// Remember a runner GitHub refused, so the node's next VM replaces it.
    static func noteDeprecation(in text: String, events: any EventSink) async {
        guard let version = DeprecatedRunners.refusedVersion(in: text) else { return }
        await DeprecatedRunners.shared.record(version)
        await events.log(
            "GitHub refused runner \(version) as deprecated; this node's next VMs will download the current runner "
                + "until the base image is refreshed (docs/BASE-IMAGE.md)"
        )
    }
}
