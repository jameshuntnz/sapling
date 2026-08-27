import Foundation
import SaplingCore
import Vapor

/// Serves the pull-through package caches to job environments.
public struct CacheProxyServer: Sendable {
    let config: CacheConfig
    let proxy: CacheProxy

    /// Creates a cache proxy server.
    public init(config: CacheConfig) {
        self.config = config
        self.proxy = CacheProxy(config: config)
    }

    init(config: CacheConfig, proxy: CacheProxy) {
        self.config = config
        self.proxy = proxy
    }

    /// Starts serving and does not return until the server stops.
    ///
    /// - Parameter bindAddress: The VM bridge gateway to listen on. Binding
    ///   wider would expose the cache to the LAN and the tailnet.
    /// - Throws: If the address cannot be bound.
    public func run(bindAddress: String) async throws {
        var env = try Environment.detect()
        env.arguments = ["sapling-cache"]
        let app = try await Application.make(env)

        do {
            app.http.server.configuration.hostname = bindAddress
            app.http.server.configuration.port = config.port
            app.logger.logLevel = .warning
            app.middleware = .init()
            app.middleware.use(JSONErrorMiddleware())

            // Proves to a job environment that the proxy is listening on
            // the gateway it resolved, before it points a package manager at
            // it. Cheap enough to sit on the critical path of every job.
            let healthRoute = CacheConfig.healthPath.split(separator: "/").map {
                PathComponent(stringLiteral: String($0))
            }
            app.get(healthRoute) { _ in "ok" }

            let proxy = self.proxy
            for (key, upstream) in await proxy.enabledUpstreams {
                let segments = upstream.prefix.split(separator: "/").map {
                    PathComponent(stringLiteral: String($0))
                }
                app.get(segments + [.catchall]) { request async throws -> Response in
                    let path = request.parameters.getCatchall().joined(separator: "/")
                    let query = request.url.query.map { "?\($0)" } ?? ""
                    let file = try await proxy.fetch(upstream: key, path: path + query)
                    let response = try await request.fileio.asyncStreamFile(at: file.path.path)
                    response.headers.replaceOrAdd(name: .contentType, value: file.contentType)
                    return response
                }
            }

            Log.info(
                "cache proxy listening on http://\(bindAddress):\(config.port) (\(await proxy.enabledUpstreams.keys.sorted().joined(separator: ", ")))"
            )
            try await app.execute()
        } catch {
            try? await app.asyncShutdown()
            throw error
        }
        try await app.asyncShutdown()
    }

    /// Trims the cache back to its configured size ceiling.
    public func prune() async {
        await proxy.prune()
    }
}
