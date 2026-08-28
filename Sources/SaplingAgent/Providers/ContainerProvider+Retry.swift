import Foundation
import SaplingCore

/// Building a container, and building it again when it comes up without a
/// network.
///
/// The same shape the macOS path has, and for the same reason: an environment
/// that never gets a network is not a job that has failed. Only the VM path had
/// this at first, and the asymmetry cost a job — a container failed twelve
/// seconds in where a rebuild would very likely have worked.
extension ContainerProvider {
    /// How many times to build this container before giving the job up.
    ///
    /// The same count the macOS path gets, and for the same reason. A
    /// container that comes up without a network is not a job that has failed:
    /// observed in production, one failed twelve seconds in where a rebuild
    /// would very likely have worked, and it failed outright because only the
    /// VM path had a retry. That asymmetry cost a job.
    static let attachAttempts = 3

    func run(_ request: JobRunRequest, events: any EventSink) async throws -> JobOutcome {
        let image = request.image ?? config.defaultImage
        var lastFailure: (any Error)?

        for attempt in 1...Self.attachAttempts {
            // A fresh name per attempt, matching the macOS path: whatever a
            // failed environment leaves behind is exactly what is not
            // understood, so nothing is reused.
            let name =
                attempt == 1
                ? Self.containerPrefix + request.runnerName
                : "\(Self.containerPrefix)\(request.runnerName)-r\(attempt)"

            do {
                let outcome = try await start(
                    name: name, image: image, request: request, events: events)
                await Self.teardown(name: name, events: events)
                return outcome
            } catch let error as JobNetworkLost {
                lastFailure = error
                // Teardown first: the repair stops every container, and this
                // one is on its way out anyway. Without the repair the next
                // attempt starts into the same dead bridge and fails the same
                // way, which is how a single lost bridge became an evening of
                // failures.
                await Self.teardown(name: name, events: events)
                await Self.repairNetwork(after: name, events: events)
                if attempt < Self.attachAttempts {
                    await events.log(
                        "\(error.localizedDescription) — rebuilding the container "
                            + "(attempt \(attempt + 1) of \(Self.attachAttempts))")
                }
            } catch {
                await Self.teardown(name: name, events: events)
                throw error
            }
        }

        throw ProviderError(
            lastFailure?.localizedDescription ?? "the container never got a network")
    }
}
