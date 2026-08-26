import Foundation
import SaplingCore

/// Checks that the base macOS VM image exists.
public struct BaseImageStep: InstallStep {
    /// Name shown by `install` and `doctor`.
    public let name = "Base macOS image"
    let imageName: String
    /// Creates the step.
    public init(imageName: String) { self.imageName = imageName }

    /// Reports whether this step is already satisfied.
    public func check() async -> StepState {
        guard ProcessRunner.which("tart") != nil else {
            return .failed("Tart is not installed yet")
        }
        guard let result = try? await ProcessRunner.run("tart", ["get", imageName], timeout: .seconds(30)),
            result.succeeded
        else {
            return .manual(
                "base image `\(imageName)` does not exist",
                instructions: Self.instructions(imageName: imageName)
            )
        }
        return .ok("`\(imageName)` present")
    }

    /// The manual steps for building a base image.
    ///
    /// Apple's Setup Assistant has no scriptable path, so this is printed
    /// rather than performed.
    public static func instructions(imageName: String) -> String {
        """
        This is the one step that cannot be automated — macOS Setup Assistant has no
        scriptable path. Do it once:

          1. Pull a prepared image (fastest route):
               tart clone ghcr.io/cirruslabs/macos-sequoia-xcode:latest \(imageName)

             Or start from a bare installer if you'd rather build your own:
               tart create --from-ipsw=latest \(imageName)
               tart run \(imageName)
             and complete Setup Assistant, creating a user named `admin`.

          2. Boot it and finish preparing it:
               tart run \(imageName)

          3. Inside the VM: enable Remote Login
             (System Settings > General > Sharing > Remote Login), then authorise
             Sapling's key by pasting the contents of
               \(SaplingPaths.sshKeyFile.path).pub
             into ~/.ssh/authorized_keys.

          4. Strongly recommended — bake the runner in so every job doesn't
             re-download ~200MB:
               mkdir -p ~/actions-runner && cd ~/actions-runner
               # download the latest actions/runner osx-arm64 tarball and extract it

          5. Shut the VM down cleanly, then re-run `sapling install`.

        See docs/BASE-IMAGE.md for the full walkthrough.
        """
    }
}

// MARK: - 10. Installed binary
