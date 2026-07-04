import Vapor

func routes(_ app: Application) throws {
    app.get("healthz") { _ in "ok" }

    try app.register(collection: ParticipantsController())
    try app.register(collection: SessionsController())
    try app.register(collection: TakesController())
    try app.register(collection: AdminController())
}
