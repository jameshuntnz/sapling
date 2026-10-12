import Foundation
import Testing

@testable import SaplingAgent

@Suite("Workflow job steps")
struct WorkflowStepTests {
    @Test("decodes the steps GitHub lists on a job")
    func decodesSteps() throws {
        let json = """
            {"id": 7, "run_id": 3, "name": "build", "status": "in_progress", "conclusion": null,
             "labels": [], "head_sha": "abc", "head_branch": "main", "started_at": "2026-10-12T01:00:00Z",
             "completed_at": null, "runner_name": "sap-macos-1",
             "steps": [
               {"name": "Set up job", "status": "completed", "conclusion": "success", "number": 1,
                "started_at": "2026-10-12T01:00:00Z", "completed_at": "2026-10-12T01:00:05Z"},
               {"name": "Build", "status": "in_progress", "conclusion": null, "number": 2,
                "started_at": "2026-10-12T01:00:05Z", "completed_at": null}
             ]}
            """
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        let job = try decoder.decode(WorkflowJob.self, from: Data(json.utf8))
        #expect(job.steps?.map(\.name) == ["Set up job", "Build"])
        #expect(job.steps?.last?.completedAt == nil)
    }
}
