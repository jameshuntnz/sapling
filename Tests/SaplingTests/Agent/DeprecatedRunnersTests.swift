import Testing

@testable import SaplingAgent

@Suite("Deprecated runners")
struct DeprecatedRunnersTests {
    @Test("reads the version from the runner's refusal")
    func parsesRefusal() {
        let line = "An error occurred: Runner version v2.336.0 is deprecated and cannot receive messages."
        #expect(DeprecatedRunners.refusedVersion(in: line) == "2.336.0")
        #expect(DeprecatedRunners.refusedVersion(in: "Current runner version: '2.336.0'") == nil)
    }

    @Test("a refusal covers that version and older, not newer")
    func comparesVersions() async {
        let runners = DeprecatedRunners()
        #expect(await !runners.isRefused("2.336.0"))

        await runners.record("2.336.0")
        #expect(await runners.isRefused("2.336.0\n"))
        #expect(await runners.isRefused("2.335.9"))
        #expect(await !runners.isRefused("2.338.2"))
        #expect(await !runners.isRefused("missing"))

        await runners.record("2.300.0")
        #expect(await runners.isRefused("2.336.0"))
    }
}
