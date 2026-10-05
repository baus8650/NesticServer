import Fluent
import Vapor

final class FeedbackThread: Model, Content, @unchecked Sendable {
    static let schema = "feedback_threads"

    @ID(key: .id)
    var id: UUID?

    @Parent(key: "user_id")
    var user: User

    @Field(key: "subject")
    var subject: String

    @Field(key: "category")
    var category: String

    @Field(key: "status")
    var status: String

    @Field(key: "last_activity_at")
    var lastActivityAt: Date

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    @Children(for: \.$thread)
    var messages: [FeedbackMessage]

    init() {}

    init(userID: UUID, subject: String, category: String, status: String = "open", lastActivityAt: Date = Date()) {
        self.$user.id = userID
        self.subject = subject
        self.category = category
        self.status = status
        self.lastActivityAt = lastActivityAt
    }
}

final class FeedbackMessage: Model, Content, @unchecked Sendable {
    static let schema = "feedback_messages"

    @ID(key: .id)
    var id: UUID?

    @Parent(key: "thread_id")
    var thread: FeedbackThread

    @Parent(key: "author_user_id")
    var author: User

    @Field(key: "body")
    var body: String

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(threadID: UUID, authorUserID: UUID, body: String) {
        self.$thread.id = threadID
        self.$author.id = authorUserID
        self.body = body
    }
}
