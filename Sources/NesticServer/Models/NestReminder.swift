import Fluent
import Vapor

enum NestReminderCadence: String, Codable {
    case afterMeal
    case everyOtherDay
    case monthly
    case yearly
}

/// A reminder schedule belongs to the nest, rather than to the person who
/// created it. Delivery is controlled separately by `NestReminderPreference`.
final class NestReminder: Model, Content, @unchecked Sendable {
    static let schema = "nest_reminders"

    @ID(key: .id) var id: UUID?
    @Parent(key: "nest_id") var nest: Nest
    @Field(key: "subject_id") var subjectID: UUID
    @Field(key: "subject_name") var subjectName: String
    @Field(key: "tracker_id") var trackerID: UUID
    @Field(key: "tracker_name") var trackerName: String
    @Enum(key: "cadence") var cadence: NestReminderCadence
    @OptionalField(key: "linked_tracker_id") var linkedTrackerID: UUID?
    @OptionalField(key: "linked_tracker_name") var linkedTrackerName: String?
    @Field(key: "delay_minutes") var delayMinutes: Int
    @Field(key: "anchor_date") var anchorDate: Date
    @Field(key: "hour") var hour: Int
    @Field(key: "minute") var minute: Int
    @Field(key: "created_by_user_id") var createdByUserID: UUID
    @Field(key: "created_by_name") var createdByName: String
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?

    init() {}

    init(id: UUID? = nil, nestID: UUID, subjectID: UUID, subjectName: String,
         trackerID: UUID, trackerName: String, cadence: NestReminderCadence,
         linkedTrackerID: UUID?, linkedTrackerName: String?, delayMinutes: Int,
         anchorDate: Date, hour: Int, minute: Int, createdByUserID: UUID,
         createdByName: String) {
        self.id = id
        self.$nest.id = nestID
        self.subjectID = subjectID
        self.subjectName = subjectName
        self.trackerID = trackerID
        self.trackerName = trackerName
        self.cadence = cadence
        self.linkedTrackerID = linkedTrackerID
        self.linkedTrackerName = linkedTrackerName
        self.delayMinutes = delayMinutes
        self.anchorDate = anchorDate
        self.hour = hour
        self.minute = minute
        self.createdByUserID = createdByUserID
        self.createdByName = createdByName
    }
}

/// Notification delivery is deliberately a per-user preference. Turning a
/// shared reminder off never changes it for the rest of the nest.
final class NestReminderPreference: Model, Content, @unchecked Sendable {
    static let schema = "nest_reminder_preferences"

    @ID(key: .id) var id: UUID?
    @Parent(key: "reminder_id") var reminder: NestReminder
    @Parent(key: "user_id") var user: User
    @Field(key: "enabled") var enabled: Bool
    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?

    init() {}

    init(reminderID: UUID, userID: UUID, enabled: Bool) {
        self.$reminder.id = reminderID
        self.$user.id = userID
        self.enabled = enabled
    }
}
