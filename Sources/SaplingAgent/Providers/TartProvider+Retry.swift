import Foundation
import SaplingCore

/// Building a VM, and building it again when it comes up without a network.
///
/// The retry is the important part, and it is deliberately not conditional on
/// understanding why a VM sometimes gets no network — that cause is still
/// unidentified. Measured in production three times: the attempt after one of
/// these boots in eight seconds and runs the job to completion.
extension TartProvider {
    /// How many times to build this VM before giving the job up.
    ///
    /// The retry is the whole point. A VM that does not get a network is not a
    /// job that has failed — measured in production, the *next* attempt boots
    /// in eight seconds and runs the job to completion, every time. Sapling
    /// already relied on that, badly: it failed the job, waited out a two
    /// minute cooldown, and requeued. Retrying here costs seconds and keeps
    /// the job.
    static let attachAttempts = 3

    /// How long a VM gets to report an address before it is written off.
    ///
    /// Measured healthy: nine seconds, on a node also running a container.
    /// Ninety is a tenfold margin, which leaves room for a clone competing
    /// with a container build for the one SSD — a real effect, and the reason
    /// this is not tighter. The old limit was the full five-minute boot
    /// timeout, and that is what let a dead VM sit long enough for its
    /// teardown to take another job's network with it.
    static let attachTimeout: Duration = .seconds(90)

    func run(_ request: JobRunRequest, events: any EventSink) async throws -> JobOutcome {
        var lastFailure: (any Error)?

        for attempt in 1...Self.attachAttempts {
            // A fresh name per attempt: the state a failed VM leaves behind is
            // exactly what is not understood here, so nothing is reused.
            let vmName =
                attempt == 1
                ? Self.vmPrefix + request.runnerName
                : "\(Self.vmPrefix)\(request.runnerName)-r\(attempt)"

            // Teardown has to happen no matter how we leave this function — a
            // leaked VM holds one of only two macOS slots until someone
            // notices — and it has to be *awaited*, because the caller
            // releases the slot as soon as this returns.
            do {
                let outcome = try await boot(vmName: vmName, request: request, events: events)
                await Self.teardown(vmName: vmName, events: events)
                await NetworkAftercare.afterVMTeardown(events: events)
                return outcome
            } catch let error as VMAttachFailed {
                lastFailure = error
                // Captured before teardown, while the broken state still
                // exists. The root cause is unknown and cannot be reproduced
                // on demand, so this file is the only chance of diagnosing it.
                await NetworkDiagnostics.captureAttachFailure(vmName: vmName, events: events)
                await Self.teardown(vmName: vmName, events: events)
                await NetworkAftercare.afterVMTeardown(events: events)
                if attempt < Self.attachAttempts {
                    await events.log(
                        "\(error.localizedDescription) — rebuilding the VM "
                            + "(attempt \(attempt + 1) of \(Self.attachAttempts))")
                }
            } catch {
                await Self.teardown(vmName: vmName, events: events)
                // Both paths, because the failing teardown is the one that did
                // the damage: a VM that never booted properly took a running
                // container's bridge with it when it was cleaned up.
                await NetworkAftercare.afterVMTeardown(events: events)
                throw error
            }
        }

        throw ProviderError(
            """
            \(lastFailure?.localizedDescription ?? "the VM never got a network") \
            This is the fault whose cause is still unidentified — it appears on a node that \
            has been up for hours and never on one freshly rebooted. See the capture in \
            \(NetworkDiagnostics.directory.path), and docs/NETWORKING.md.
            """)
    }
}
