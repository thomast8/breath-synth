import Fluent

struct CreateTake: AsyncMigration {
    func prepare(on database: any Database) async throws {
        let status = try await database.enum("take_status")
            .case("kept")
            .case("redone")
            .create()

        try await database.schema(Take.schema)
            .id()
            .field("session_id", .uuid, .required, .references(EnrollSession.schema, "id"))
            .field("step_slug", .string, .required)
            .field("lane_slug", .string, .required)
            .field("style", .string, .required)
            .field("breath_type", .string, .required)
            .field("render_mode", .string, .required)
            .field("role", .string, .required)
            .field("take_index", .int, .required)
            .field("reference", .string)
            .field("object_key", .string, .required)
            .field("duration_sec", .double, .required)
            .field("sample_rate", .double, .required)
            .field("peak", .double)
            .field("rms", .double)
            .field("verdict_accept", .bool, .required)
            .field("verdict_reason", .string)
            .field("verdict_advisory", .array(of: .string), .required)
            .field("fragments_accepted", .int)
            .field("fragments_total", .int)
            .field("status", status, .required)
            .field("client_meta", .dictionary)
            .field("created_at", .datetime)
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(Take.schema).delete()
        try await database.enum("take_status").delete()
    }
}
