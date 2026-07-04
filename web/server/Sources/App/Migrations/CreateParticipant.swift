import Fluent

struct CreateParticipant: AsyncMigration {
    func prepare(on database: any Database) async throws {
        let experienceLevel = try await database.enum("experience_level")
            .case("novice")
            .case("intermediate")
            .case("advanced")
            .case("instructor")
            .create()

        try await database.schema(Participant.schema)
            .id()
            .field("pseudonym", .string)
            .field("experience_level", experienceLevel, .required)
            .field("consent_version", .string, .required)
            .field("consented_at", .datetime, .required)
            .field("created_at", .datetime)
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(Participant.schema).delete()
        try await database.enum("experience_level").delete()
    }
}
