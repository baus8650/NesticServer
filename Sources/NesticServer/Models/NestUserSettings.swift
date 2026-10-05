import Fluent
import Vapor

/// Per-user settings for one nest. The payloads are opaque JSON strings so
/// clients can evolve their local preference models without a server schema
/// change for every new setting.
final class NestUserSettings: Model, Content, @unchecked Sendable {
    static let schema = "nest_user_settings"

    @ID(key: .id)
    var id: UUID?

    @Parent(key: "nest_id")
    var nest: Nest

    @Parent(key: "user_id")
    var user: User

    @OptionalField(key: "prediction_preferences_json")
    var predictionPreferencesJSON: String?

    @OptionalField(key: "quiet_hours_json")
    var quietHoursJSON: String?

    @OptionalField(key: "reminders_json")
    var remindersJSON: String?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}

    init(nestID: UUID, userID: UUID) {
        self.$nest.id = nestID
        self.$user.id = userID
    }
}
