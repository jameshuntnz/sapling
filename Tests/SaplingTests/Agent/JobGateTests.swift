import Foundation
import Testing

@testable import SaplingAgent
@testable import SaplingCore

/// The Node.js standing in for the runner's bundled one.
///
/// The gate's tests run the hook it installs against real-shaped payloads.
private let hostNode = ["/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node"]
    .first { FileManager.default.isExecutableFile(atPath: $0) }

@Suite("Job-started gate", .enabled(if: hostNode != nil))
struct JobGateTests {

    /// The hook's exit status for one event.
    ///
    /// Installs the gate into a fake runner directory, then runs it as the
    /// runner would.
    private func gate(event: String, payload: String, repository: String = "acme/widgets") throws -> Int32 {
        let runner = FileManager.default.temporaryDirectory
            .appendingPathComponent("gate-\(UUID().uuidString)")
        let nodeDir = runner.appendingPathComponent("externals/node24/bin")
        try FileManager.default.createDirectory(at: nodeDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: runner) }
        try FileManager.default.createSymbolicLink(
            atPath: nodeDir.appendingPathComponent("node").path,
            withDestinationPath: try #require(hostNode))
        let payloadFile = runner.appendingPathComponent("event.json")
        try payload.write(to: payloadFile, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.currentDirectoryURL = runner
        process.arguments = [
            "-c",
            JobGate.installScript(repo: "acme/widgets") + "\nexec \"$ACTIONS_RUNNER_HOOK_JOB_STARTED\"",
        ]
        process.environment = [
            "PATH": "/usr/bin:/bin",
            "GITHUB_EVENT_NAME": event,
            "GITHUB_EVENT_PATH": payloadFile.path,
            "GITHUB_REPOSITORY": repository,
        ]
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    @Test("admits a push and a pull request from the watched repository")
    func admitsOwnCode() throws {
        #expect(try gate(event: "push", payload: #"{"ref":"refs/heads/main"}"#) == 0)
        #expect(
            try gate(
                event: "pull_request",
                payload: #"{"pull_request":{"head":{"repo":{"full_name":"Acme/Widgets"}}}}"#) == 0)
    }

    /// The bypass this exists for: a fork's job picked up by a runner Sapling
    /// minted for a job it admitted.
    @Test("refuses a fork's pull request, however it was triggered")
    func refusesForks() throws {
        let fork = #"{"pull_request":{"head":{"repo":{"full_name":"mallory/widgets"}}}}"#
        #expect(try gate(event: "pull_request", payload: fork) != 0)
        #expect(try gate(event: "pull_request_target", payload: fork) != 0)
        #expect(
            try gate(
                event: "workflow_run",
                payload: #"{"workflow_run":{"head_repository":{"full_name":"mallory/widgets"}}}"#) != 0)
        #expect(try gate(event: "pull_request", payload: #"{"pull_request":{"head":{"repo":null}}}"#) != 0)
    }

    @Test("refuses comments on pull requests and anything it cannot read")
    func refusesUnknowns() throws {
        #expect(try gate(event: "issue_comment", payload: #"{"issue":{"pull_request":{}}}"#) != 0)
        #expect(try gate(event: "issue_comment", payload: #"{"issue":{}}"#) == 0)
        #expect(try gate(event: "push", payload: "not json") != 0)
        #expect(try gate(event: "push", payload: "{}", repository: "mallory/widgets") != 0)
    }
}
