import ArgumentParser
import Foundation
import SaplingCore
import SaplingInstall

struct Doctor: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Check every dependency without changing anything."
    )

    func run() async throws {
        print(Style.bold("Sapling \(SaplingVersion.current) health check"))
        print("  home: \(InstallContext.saplingHome)")
        print("")

        let results = await Installer().doctor()
        var problems = 0
        var unverified = 0

        for result in results {
            switch result.state {
            case .ok(let summary):
                print("  \(Style.green("ok"))       \(Format.pad(result.step, to: 20)) \(Style.dim(summary))")
            case .fixable(let summary):
                problems += 1
                print("  \(Style.yellow("missing"))  \(Format.pad(result.step, to: 20)) \(summary)")
            case .manual(let summary, _):
                problems += 1
                print("  \(Style.yellow("manual"))   \(Format.pad(result.step, to: 20)) \(summary)")
            case .failed(let reason):
                problems += 1
                print("  \(Style.red("failed"))   \(Format.pad(result.step, to: 20)) \(reason)")
            case .unverified(let reason):
                // Not counted as a problem: the check could not run, which is
                // not the same as something being wrong. Saying so plainly is
                // the whole point of this case.
                unverified += 1
                print("  \(Style.dim("unknown"))  \(Format.pad(result.step, to: 20)) \(reason)")
            }
        }

        let config = SaplingConfig.loadOrDefault()
        let warnings = config.warnings()
        if !warnings.isEmpty {
            print("")
            print(Style.bold("Configuration warnings"))
            for warning in warnings { print("  \(Style.yellow("!"))  \(warning)") }
        }

        print("")
        guard problems == 0 else {
            print("\(problems) item(s) need attention. `sudo sapling install` fixes what it can.")
            throw ExitCode.failure
        }
        guard unverified == 0 else {
            print(
                Style.green("Everything that could be checked is fine")
                    + ", but \(unverified) check(s) could not run here.")
            return
        }
        print(Style.green("Everything checks out."))
    }
}
