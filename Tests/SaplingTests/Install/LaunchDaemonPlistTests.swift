import Foundation
import Testing

@testable import SaplingCore
@testable import SaplingInstall

extension EnvironmentDependentTests {
    @Suite("LaunchDaemon plist")
    struct LaunchDaemonPlistTests {
        func parse(runAsUser: String?) throws -> [String: Any] {
            let text = LaunchDaemonStep.plistContents(runAsUser: runAsUser)
            let object = try PropertyListSerialization.propertyList(
                from: Data(text.utf8),
                options: [],
                format: nil
            )
            return try #require(object as? [String: Any])
        }

        /// A malformed plist means the daemon silently never starts, which is
        /// the least debuggable failure in the whole system.
        @Test("is valid plist XML with the keys launchd needs")
        func isValidPlist() throws {
            let plist = try parse(runAsUser: nil)
            #expect(plist["Label"] as? String == SaplingPaths.launchDaemonLabel)
            #expect(plist["RunAtLoad"] as? Bool == true)
            #expect(plist["ProcessType"] as? String == "Background")

            let arguments = plist["ProgramArguments"] as? [String]
            #expect(arguments == [SaplingPaths.installedBinary, "serve"])
        }

        /// Under launchd the daemon has no login session, so both of these
        /// have to be explicit: SAPLING_HOME because $HOME is /var/root, and
        /// TART_HOME so the root daemon clones the base image the human built.
        @Test("pins SAPLING_HOME, TART_HOME, and a Homebrew-inclusive PATH")
        func environmentVariables() throws {
            let plist = try parse(runAsUser: nil)
            let env = try #require(plist["EnvironmentVariables"] as? [String: String])

            #expect(env["SAPLING_HOME"] == InstallContext.saplingHome)
            #expect(env["TART_HOME"] == InstallContext.tartHome)
            #expect(env["PATH"]?.contains("/opt/homebrew/bin") == true)
        }

        @Test("omits UserName by default and includes it when asked")
        func runAsUser() throws {
            #expect(try parse(runAsUser: nil)["UserName"] == nil)
            #expect(try parse(runAsUser: "admin")["UserName"] as? String == "admin")
        }

        /// KeepAlive must not restart a daemon that exited cleanly, or
        /// `launchctl bootout` fights the restart loop.
        @Test("only restarts on unclean exit")
        func keepAlive() throws {
            let keepAlive = try #require(try parse(runAsUser: nil)["KeepAlive"] as? [String: Any])
            #expect(keepAlive["SuccessfulExit"] as? Bool == false)
        }
    }

    // MARK: - Steps
}
