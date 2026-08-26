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

    /// The cache proxy binds to the VM bridge gateway, which only exists once
    /// something has run.
    ///
    /// Rather than fail at startup on a cold boot, wait for it in the background
    /// and bind when it appears.
    private func startCacheProxy(config: CacheConfig) {
        Task.detached {
            let server = CacheProxyServer(config: config)
            for attempt in 0..<60 {
                if let interfaces = try? await NetworkGuard.discoverBridgeInterfaces(),
                    let gateway = interfaces.first?.address
                {
                    do {
                        try await server.run(bindAddress: gateway)
                    } catch {
                        Log.error("cache proxy stopped: \(error.localizedDescription)")
                    }
                    return
                }
                if attempt == 0 {
                    Log.info("cache proxy waiting for a VM bridge interface to appear")
                }
                try? await Task.sleep(for: .seconds(30))
            }
            Log.warn(
                "no VM bridge interface appeared; cache proxy not started (jobs will fetch packages directly)"
            )
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
