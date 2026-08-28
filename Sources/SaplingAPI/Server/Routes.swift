import Foundation
import SaplingCore
import Vapor

/// Encode a DTO straight to a response.
///
/// Deliberately avoids conforming the `SaplingCore` DTOs to Vapor's `Content`:
/// those types are shared with the CLI and the menu bar app, and neither
/// should have to link Vapor to speak to this API.
func jsonResponse<T: Encodable>(_ value: T, status: HTTPResponseStatus = .ok) throws -> Response {
    let data = try SaplingJSON.encoder.encode(value)
    var headers = HTTPHeaders()
    headers.contentType = .json
    return Response(status: status, headers: headers, body: .init(data: data))
}

func errorResponse(_ status: HTTPResponseStatus, _ error: String, _ reason: String) -> Response {
    let payload = APIErrorResponse(error: error, reason: reason)
    let data = (try? SaplingJSON.encoder.encode(payload)) ?? Data()
    var headers = HTTPHeaders()
    headers.contentType = .json
    return Response(status: status, headers: headers, body: .init(data: data))
}

/// Turns thrown errors into the same JSON shape clients see for 404s, so the
/// CLI and menu bar app never have to parse an HTML error page.
struct JSONErrorMiddleware: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        do {
            return try await next.respond(to: request)
        } catch let abort as any AbortError {
            return errorResponse(abort.status, abort.status.reasonPhrase, abort.reason)
        } catch {
            request.logger.report(error: error)
            return errorResponse(.internalServerError, "internal_error", error.localizedDescription)
        }
    }
}

/// The v1 surface from §9, and nothing more — endpoints get added when the
/// CLI or the UI actually needs them.
func registerRoutes(_ app: Application, controlPlane: ControlPlane, advertisedURL: String) throws {
    let v1 = app.grouped("api", "v1")

    v1.get("status") { _ async throws -> Response in
        try jsonResponse(try await controlPlane.status())
    }

    v1.get("nodes") { _ async throws -> Response in
        try jsonResponse(NodeListResponse(nodes: try await controlPlane.nodes()))
    }

    v1.post("nodes", "join-token") { _ async throws -> Response in
        try jsonResponse(try await controlPlane.createJoinToken(controlPlaneURL: advertisedURL))
    }

    v1.get("jobs") { request async throws -> Response in
        let rawStatus = try? request.query.get(String.self, at: "status")
        if let rawStatus, JobStatus(rawValue: rawStatus) == nil {
            return errorResponse(
                .badRequest,
                "invalid_status",
                "unknown status \"\(rawStatus)\"; expected one of \(JobStatus.allCases.map(\.rawValue).joined(separator: ", "))"
            )
        }
        let limit = (try? request.query.get(Int.self, at: "limit")) ?? 50
        let jobs = try await controlPlane.jobs(
            status: rawStatus.flatMap(JobStatus.init(rawValue:)), limit: limit)
        return try jsonResponse(JobListResponse(jobs: jobs))
    }

    v1.get("jobs", ":id") { request async throws -> Response in
        guard let id = request.parameters.get("id") else {
            return errorResponse(.badRequest, "missing_id", "no job id in path")
        }
        guard let detail = try await controlPlane.job(id: id) else {
            return errorResponse(.notFound, "not_found", "no job with id \(id)")
        }
        return try jsonResponse(detail)
    }

    v1.get("jobs", ":id", "logs") { request async throws -> Response in
        guard let id = request.parameters.get("id") else {
            return errorResponse(.badRequest, "missing_id", "no job id in path")
        }
        // `after` is the last event id the client already has, so a tailing
        // client fetches only what's new.
        let after = try? request.query.get(Int64.self, at: "after")
        guard let logs = try await controlPlane.logs(jobID: id, after: after) else {
            return errorResponse(.notFound, "not_found", "no job with id \(id)")
        }
        return try jsonResponse(logs)
    }

    v1.get("jobs", ":id", "resources") { request async throws -> Response in
        guard let id = request.parameters.get("id") else {
            return errorResponse(.badRequest, "missing_id", "no job id in path")
        }
        let limit = try? request.query.get(Int.self, at: "limit")
        guard let resources = try await controlPlane.jobResources(id: id, limit: limit) else {
            return errorResponse(.notFound, "not_found", "no job with id \(id)")
        }
        return try jsonResponse(resources)
    }

    v1.get("metrics") { request async throws -> Response in
        let limit = try? request.query.get(Int.self, at: "limit")
        return try jsonResponse(await controlPlane.metricsHistory(limit: limit))
    }

    v1.get("update") { _ async throws -> Response in
        try jsonResponse(await controlPlane.checkForUpdate())
    }

    v1.post("update") { request async throws -> Response in
        // Updating restarts the daemon, which fails every running job, so it
        // has to be asked for explicitly while the node is busy.
        let force = (try? request.query.get(Bool.self, at: "force")) ?? false
        return try jsonResponse(await controlPlane.applyUpdate(force: force))
    }

    v1.post("drain") { _ async throws -> Response in
        try jsonResponse(try await controlPlane.drain())
    }

    v1.post("cordon") { _ async throws -> Response in
        try jsonResponse(try await controlPlane.cordon())
    }

    v1.post("uncordon") { _ async throws -> Response in
        try jsonResponse(try await controlPlane.uncordon())
    }
}
