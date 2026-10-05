import Fluent
import Vapor

/// A dated update attached to a health episode. Photo binaries are stored in
/// private R2 storage; text-only updates use an empty photo reference.
final class ActionEventPhoto: Model, Content, @unchecked Sendable {
    static let schema = "action_event_photos"

    @ID(key: .id)
    var id: UUID?

    @Parent(key: "event_id")
    var event: ActionEvent

    @OptionalParent(key: "actor_user_id")
    var actor: User?

    @Field(key: "captured_at")
    var capturedAt: Date

    @Field(key: "photo_url")
    var photoURL: String

    @OptionalField(key: "note")
    var note: String?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(id: UUID? = nil, eventID: UUID, actorUserID: UUID?, capturedAt: Date,
         photoURL: String, note: String? = nil) {
        self.id = id
        self.$event.id = eventID
        self.$actor.id = actorUserID
        self.capturedAt = capturedAt
        self.photoURL = photoURL
        self.note = note
    }
}
