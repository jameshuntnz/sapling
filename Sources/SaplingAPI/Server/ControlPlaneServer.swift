import Foundation
import SaplingAgent
import SaplingCore
import SaplingDB
import Vapor

/// The REST API the CLI and menu bar app talk to (§5.2).
///
/// There is no auth middleware by design: §8 makes tailnet membership the
/// access control, which is only sound because the listener is bound to the
/// Tailscale interface. `BindResolver` refuses to widen that on its own.
public struct ControlPlaneServer: Sendable {
    let config: SaplingConfig
    let controlPlane: ControlPlane

    /// Creates a control-plane server.
    public init(config: SaplingConfig, store: SaplingStore, agent: NodeAgent?) {
        self.config = config
        self.controlPlane = ControlPlane(store: store, config: config, agent: agent)
    }

    /// Resolves the bind address, starts the API, and serves until stopped.
    ///
    /// - Throws: `ConfigError` if the configured bind mode cannot be
    ///   resolved — notably when Tailscale binding is asked for and no
    ///   Tailscale address exists.
    public func run() async throws {
        let resolution = try await BindResolver.resolve(config.server.bindMode)

        var env = try Environment.detect()
        env.arguments = ["sapling"]
        let app = try await Application.make(env)

        do {
            app.http.server.configuration.hostname = resolution.hostname
            app.http.server.configuration.port = config.server.port
            app.http.server.configuration.serverName = "sapling/\(SaplingVersion.current)"
            app.logger.logLevel = Log.isVerbose ? .debug : .notice

            app.middleware = .init()
            app.middleware.use(JSONErrorMiddleware())

            let advertised = "http://\(resolution.hostname):\(config.server.port)"
            try registerRoutes(app, controlPlane: controlPlane, advertisedURL: advertised)

            Log.info("control plane listening on \(advertised) (\(resolution.description))")
            try await app.execute()
        } catch {
            try? await app.asyncShutdown()
            throw error
        }
        try await app.asyncShutdown()
    }
}
