import Testing

@testable import SaplingAPI

@Suite("Update gate")
struct UpdateGateTests {
    @Test("a second update is turned away until the first releases the gate")
    func oneAtATime() async {
        let gate = UpdateGate()
        #expect(await gate.enter())
        #expect(await !gate.enter())
        await gate.leave()
        #expect(await gate.enter())
    }
}
