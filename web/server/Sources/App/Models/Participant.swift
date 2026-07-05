import Fluent
import Vapor

public final class Participant: Model, Content, @unchecked Sendable {
    public static let schema = "participants"

    @ID(key: .id)
    public var id: UUID?

    @OptionalField(key: "pseudonym")
    public var pseudonym: String?

    @Field(key: "consent_version")
    public var consentVersion: String

    @Field(key: "consented_at")
    public var consentedAt: Date

    @Timestamp(key: "created_at", on: .create)
    public var createdAt: Date?

    public init() {}

    public init(
        id: UUID? = nil, pseudonym: String?, consentVersion: String, consentedAt: Date
    ) {
        self.id = id
        self.pseudonym = pseudonym
        self.consentVersion = consentVersion
        self.consentedAt = consentedAt
    }
}
