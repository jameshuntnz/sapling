import ArgumentParser
import Foundation
import SaplingAPI
import SaplingAgent
import SaplingCore
import SaplingDB
import SaplingInstall

/// `sapling serve` — control plane plus local node agent in one process (§4).
///
/// This isn't a cut-down mode: with one node, the control plane and the agent
/// genuinely have no reason to be separate processes. `sapling join` is what
/// splits them, when there is a second node to split for.
struct Serve: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Run the control plane and node agent."
    )

    @Flag(name: .shortAndLong, help: "Verbose logging.")
    var verbose = false

    @Option(help: "Config file to use.")
    var config: String?

    func run() async throws {
        Log.isVerbose = verbose
        InstallContext.prepareEnvironment()

        let configURL =
            config.map { URL(fileURLWithPath: SaplingPaths.expandTilde($0)) } ?? SaplingPaths.configFile
        let configuration: SaplingConfig
        do {
            configuration = try SaplingConfig.load(from: configURL)
            try configuration.validate()
        } catch {
            fail(error.localizedDescription)
        }

        for warning in configuration.warnings() {
            Log.warn(warning)
        }

        try SaplingPaths.ensureHomeDirectory()
        let store = try SaplingStore(path: SaplingPaths.databaseFile)
        let agent = NodeAgent(config: configuration, store: store)

        do {
            try await agent.start()
        } catch {
            fail("could not start the node agent: \(error.localizedDescription)")
        }

        await installSignalHandlers(agent: agent)

        if configuration.cache.enabled {
            startCacheProxy(config: configuration.cache)
        }

        let server = ControlPlaneServer(config: configuration, store: store, agent: agent)
        do {
            try await server.run()
        } catch {
            await agent.stop()
            fail(error.localizedDescription)
        }
        await agent.stop()
    }

    /// The cache proxy listens on the bridge gateways, which exist only while
    /// job environments are running.
    ///
    /// A supervisor rather than a single bind: there are usually two gateways,
    /// one per platform, and they come and go with the jobs on them.
    private func startCacheProxy(config: CacheConfig) {
        Task.detached {
            await CacheProxySupervisor(config: config).run()
        }

        Task.detached {
            let server = CacheProxyServer(config: config)
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3600))
                await server.prune()
            }
        }
    }

    private func installSignalHandlers(agent: NodeAgent) async {
        for signalNumber in [SIGTERM, SIGINT] {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
            source.setEventHandler {
                Task {
                    Log.info("shutting down")
                    await agent.stop()
                    Foundation.exit(0)
                }
            }
            source.resume()
            Self.signalSources.append(source)
        }
    }

    /// Signal sources are cancelled when deallocated, so they have to outlive
    /// the call that created them.
    nonisolated(unsafe) private static var signalSources: [DispatchSourceSignal] = []
}
