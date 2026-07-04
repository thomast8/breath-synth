import Fluent
import Vapor

func routes(_ app: Application) throws {
    app.get("healthz") { _ in "ok" }

    try app.register(collection: ParticipantsController())
    try app.register(collection: SessionsController())
    try app.register(collection: AdminController())

    app.webSocket("api", "sessions", ":sessionID", "live") { req, ws in
        guard let sessionID = req.parameters.get("sessionID", as: UUID.self),
              (try? await EnrollSession.find(sessionID, on: req.db)) != nil
        else {
            try? await ws.close(code: .unacceptableData)
            return
        }
        await EnrollmentSocketController.attach(ws, sessionID: sessionID, req: req)
    }
}
