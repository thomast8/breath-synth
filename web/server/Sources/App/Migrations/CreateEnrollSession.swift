import Fluent

struct CreateEnrollSession: AsyncMigration {
    func prepare(on database: any Database) async throws {
        let status = try await database.enum("session_status")
            .case("in_progress")
            .case("completed")
            .case("abandoned")
            .create()

        try await database.schema(EnrollSession.schema)
            .id()
            .field("participant_id", .uuid, .required, .references(Participant.schema, "id"))
            .field("status", status, .required)
            .field("script_version", .string, .required)
            .field("sample_rate", .double, .required)
            .field("user_agent", .string)
            .field("mic_constraints_actual", .dictionary)
            .field("room_tone_object_key", .string)
            .field("started_at", .datetime)
            .field("completed_at", .datetime)
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(EnrollSession.schema).delete()
        try await database.enum("session_status").delete()
    }
}
