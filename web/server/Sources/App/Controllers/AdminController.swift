import Fluent
import Vapor

struct AdminController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let admin = routes.grouped("api", "admin").grouped(AdminAuthMiddleware())
        admin.get("sessions", use: list)
        admin.get("sessions", ":sessionID", "export", use: export)
    }

    @Sendable
    func list(req: Request) async throws -> [EnrollSession] {
        try await EnrollSession.query(on: req.db).sort(\.$startedAt, .descending).all()
    }

    @Sendable
    func export(req: Request) async throws -> Response {
        let sessionID = try req.parameters.require("sessionID", as: UUID.self)
        guard let session = try await EnrollSession.find(sessionID, on: req.db) else {
            throw Abort(.notFound)
        }
        let zip = try await SessionExporter.export(
            session: session, on: req.db, storage: req.application.storageDriver)
        var headers = HTTPHeaders()
        headers.add(name: .contentType, value: "application/zip")
        headers.add(
            name: .contentDisposition,
            value: "attachment; filename=\"session-\(sessionID).zip\"")
        return Response(status: .ok, headers: headers, body: .init(data: zip))
    }
}

/// Bearer-token gate for every `/api/admin/*` route. Deliberately fails open with a warning (not
/// closed) when no token is configured — the same "unauthenticated in dev" tradeoff `configure.swift`
/// already logs a warning about, not silently reintroduced here.
struct AdminAuthMiddleware: AsyncMiddleware {
    func respond(to req: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        guard let required = req.application.adminToken else {
            return try await next.respond(to: req)
        }
        guard let bearer = req.headers.bearerAuthorization,
              ConstantTimeCompare.equals(bearer.token, required) else {
            throw Abort(.unauthorized)
        }
        return try await next.respond(to: req)
    }
}
