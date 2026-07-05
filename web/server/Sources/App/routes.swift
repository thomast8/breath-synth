import Fluent
import Vapor

func routes(_ app: Application) throws {
    app.get("healthz") { _ in "ok" }

    try app.register(collection: ParticipantsController())
    try app.register(collection: SessionsController())
    try app.register(collection: AdminController())

    app.webSocket("api", "sessions", ":sessionID", "live") { req, ws in
        // Only a synchronous parameter parse before `attach` — no `await` here. Vapor's async
        // webSocket bridge runs this whole closure inside an unstructured `Task`, so the client can
        // already be sending frames the instant it sees the HTTP 101 response; any `await` before
        // `EnrollmentSocketController.attach` registers its callbacks widens a window where those
        // frames vanish into WebSocketKit's default no-op handler (see `attach`'s own doc comment).
        guard let sessionID = req.parameters.get("sessionID", as: UUID.self) else {
            try? await ws.close(code: .unacceptableData)
            return
        }
        await EnrollmentSocketController.attach(ws, sessionID: sessionID, req: req)
    }
}
