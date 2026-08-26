import Foundation
import Testing

@testable import SaplingCore
@testable import SaplingDB

@Suite("Records")
struct RecordTests {
    @Test("labels survive the JSON column round trip")
    func labelEncoding() {
        let labels = ["self-hosted", "macos", "arm64"]
        #expect(JobRecord.decodeLabels(JobRecord.encodeLabels(labels)) == labels)
        #expect(JobRecord.encodeLabels([]) == "[]")
    }

    /// A corrupt labels column shouldn't make a job undisplayable.
    @Test("degrades to no labels rather than failing on bad JSON")
    func malformedLabels() {
        #expect(JobRecord.decodeLabels("not json") == [])
        #expect(JobRecord.decodeLabels("") == [])
        #expect(JobRecord.decodeLabels("{\"a\":1}") == [])
    }

    @Test("unknown enum values from the database degrade safely")
    func unknownEnumValues() {
        var record = JobRecord(Job(id: "1", repo: "r", platform: .macos, labels: [], status: .running))
        record.status = "from-a-newer-version"
        record.platform = "solaris"
        // Better to show a failed Linux job than to crash the API.
        #expect(record.model.status == .failed)
        #expect(record.model.platform == .linux)
    }
}
