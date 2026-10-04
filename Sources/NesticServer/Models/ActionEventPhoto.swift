import Fluent
import Vapor

/// A dated photo update attached to a health episode. The binary is stored in
/// private R2 storage; this record keeps the authenticated reference and the
/// time the update was added.
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

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(id: UUID? = nil, eventID: UUID, actorUserID: UUID?, capturedAt: Date,
         photoURL: String) {
        self.id = id
        self.$event.id = eventID
        self.$actor.id = actorUserID
        self.capturedAt = capturedAt
        self.photoURL = photoURL
    }
}
