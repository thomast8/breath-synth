import Fluent
import Vapor

public enum ExperienceLevel: String, Codable, CaseIterable, Sendable {
    case novice
    case intermediate
    case advanced
    case instructor
}

public final class Participant: Model, Content, @unchecked Sendable {
    public static let schema = "participants"

    @ID(key: .id)
    public var id: UUID?

    @OptionalField(key: "pseudonym")
    public var pseudonym: String?

    @Enum(key: "experience_level")
    public var experienceLevel: ExperienceLevel

    @Field(key: "consent_version")
    public var consentVersion: String

    @Field(key: "consented_at")
    public var consentedAt: Date

    @Timestamp(key: "created_at", on: .create)
    public var createdAt: Date?

    public init() {}

    public init(
        id: UUID? = nil, pseudonym: String?, experienceLevel: ExperienceLevel,
        consentVersion: String, consentedAt: Date
    ) {
        self.id = id
        self.pseudonym = pseudonym
        self.experienceLevel = experienceLevel
        self.consentVersion = consentVersion
        self.consentedAt = consentedAt
    }
}
