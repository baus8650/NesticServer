import Fluent
import Vapor

enum FeedbackStatus {
    static let open = "open"
    static let inProgress = "in_progress"
    static let resolved = "resolved"

    static let all = [open, inProgress, resolved]
}

struct CreateFeedbackRequest: Content {
    let subject: String
    let category: String
    let message: String
}

struct FeedbackMessageRequest: Content {
    let message: String
}

struct UpdateFeedbackStatusRequest: Content {
    let status: String
}

struct FeedbackMessageResponse: Content {
    let id: UUID
    let authorUserId: UUID
    let authorDisplayName: String
    let authorEmail: String
    let isAdmin: Bool
    let body: String
    let createdAt: Date?
}

struct FeedbackThreadResponse: Content {
    let id: UUID
    let userId: UUID
    let userDisplayName: String
    let userEmail: String
    let subject: String
    let category: String
    let status: String
    let createdAt: Date?
    let lastActivityAt: Date
    let messageCount: Int
    let lastMessagePreview: String?
    let lastMessageIsAdmin: Bool?
    let messages: [FeedbackMessageResponse]
}

struct AdminUserResponse: Content {
    let id: UUID
    let email: String
    let displayName: String
    let emailVerified: Bool
    let createdAt: Date?
    let nestCount: Int
}

struct AdminDashboardResponse: Content {
    let totalUsers: Int
    let verifiedUsers: Int
    let totalNests: Int
    let totalEvents: Int
    let activeUsersLast30Days: Int
    let openFeedback: Int
    let inProgressFeedback: Int
    let resolvedFeedback: Int
    let recentUsers: [AdminUserResponse]
    let recentFeedback: [FeedbackThreadResponse]
}

private func feedbackText(_ value: String, field: String) throws -> String {
    let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !clean.isEmpty, clean.count <= 4000 else {
        throw Abort(.badRequest, reason: "\(field) must contain 1–4,000 characters.")
    }
    return clean
}

private func feedbackCategory(_ value: String) throws -> String {
    let clean = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let allowed = ["idea", "bug", "question", "account", "other"]
    guard allowed.contains(clean) else {
        throw Abort(.badRequest, reason: "Choose a valid feedback category.")
    }
    return clean
}

private func feedbackUser(from req: Request) async throws -> User {
    let userID = try req.requireUserID()
    guard let user = try await User.find(userID, on: req.db) else {
        throw Abort(.unauthorized)
    }
    return user
}

private func feedbackThread(from req: Request) async throws -> FeedbackThread {
    let threadID = try req.parameters.require("id", as: UUID.self)
    guard let thread = try await FeedbackThread.find(threadID, on: req.db) else {
        throw Abort(.notFound, reason: "Feedback conversation not found.")
    }
    return thread
}

private func canSee(_ thread: FeedbackThread, user: User) -> Bool {
    thread.$user.id == user.id || isNesticAdmin(user)
}

private func feedbackResponse(_ thread: FeedbackThread, on db: any Database, includeMessages: Bool = true) async throws -> FeedbackThreadResponse {
    guard let owner = try await User.find(thread.$user.id, on: db) else {
        throw Abort(.internalServerError, reason: "Feedback owner no longer exists.")
    }
    let threadID = try thread.requireID()
    let messages = try await FeedbackMessage.query(on: db)
        .filter(\.$thread.$id == threadID)
        .sort(\.$createdAt, .ascending)
        .all()
    let authorIDs = Array(Set(messages.map { $0.$author.id }))
    let authors = try await User.query(on: db).filter(\.$id ~~ authorIDs).all()
    let authorByID = Dictionary(uniqueKeysWithValues: authors.compactMap { user in
        user.id.map { ($0, user) }
    })
    let responses = messages.compactMap { message -> FeedbackMessageResponse? in
        guard let author = authorByID[message.$author.id], let messageID = message.id else { return nil }
        return FeedbackMessageResponse(id: messageID, authorUserId: message.$author.id,
                                       authorDisplayName: author.displayName, authorEmail: author.email,
                                       isAdmin: isNesticAdmin(author), body: message.body,
                                       createdAt: message.createdAt)
    }
    let last = responses.last
    return FeedbackThreadResponse(id: threadID, userId: try owner.requireID(),
                                  userDisplayName: owner.displayName, userEmail: owner.email,
                                  subject: thread.subject, category: thread.category, status: thread.status,
                                  createdAt: thread.createdAt, lastActivityAt: thread.lastActivityAt,
                                  messageCount: responses.count, lastMessagePreview: last?.body,
                                  lastMessageIsAdmin: last?.isAdmin,
                                  messages: includeMessages ? responses : [])
}

func feedbackRoutes(_ app: Application) throws {
    let protected = app.grouped(SessionToken.authenticator(), SessionToken.guardMiddleware())
    let admin = protected.grouped(AdminRouteMiddleware())

    protected.get("feedback") { req async throws -> [FeedbackThreadResponse] in
        let user = try await feedbackUser(from: req)
        let userID = try user.requireID()
        let threads = try await FeedbackThread.query(on: req.db)
            .filter(\.$user.$id == userID)
            .sort(\.$lastActivityAt, .descending)
            .range(..<100)
            .all()
        var responses: [FeedbackThreadResponse] = []
        for thread in threads {
            responses.append(try await feedbackResponse(thread, on: req.db, includeMessages: false))
        }
        return responses
    }

    protected.post("feedback") { req async throws -> FeedbackThreadResponse in
        let user = try await feedbackUser(from: req)
        let input = try req.content.decode(CreateFeedbackRequest.self)
        let subject = try feedbackText(input.subject, field: "Subject")
        let category = try feedbackCategory(input.category)
        let body = try feedbackText(input.message, field: "Message")
        let userID = try user.requireID()
        let thread = FeedbackThread(userID: userID, subject: subject, category: category)
        try await thread.save(on: req.db)
        let message = FeedbackMessage(threadID: try thread.requireID(), authorUserID: userID, body: body)
        try await message.save(on: req.db)
        return try await feedbackResponse(thread, on: req.db)
    }

    protected.get("feedback", ":id") { req async throws -> FeedbackThreadResponse in
        let user = try await feedbackUser(from: req)
        let thread = try await feedbackThread(from: req)
        guard canSee(thread, user: user) else { throw Abort(.forbidden) }
        return try await feedbackResponse(thread, on: req.db)
    }

    protected.post("feedback", ":id", "messages") { req async throws -> FeedbackThreadResponse in
        let user = try await feedbackUser(from: req)
        let thread = try await feedbackThread(from: req)
        guard canSee(thread, user: user) else { throw Abort(.forbidden) }
        let input = try req.content.decode(FeedbackMessageRequest.self)
        let body = try feedbackText(input.message, field: "Message")
        let userID = try user.requireID()
        thread.lastActivityAt = Date()
        if !isNesticAdmin(user) { thread.status = FeedbackStatus.open }
        try await thread.save(on: req.db)
        try await FeedbackMessage(threadID: try thread.requireID(), authorUserID: userID, body: body).save(on: req.db)
        return try await feedbackResponse(thread, on: req.db)
    }

    admin.get("admin", "dashboard") { req async throws -> AdminDashboardResponse in
        _ = try await req.requireNesticAdmin()
        let users = try await User.query(on: req.db).all()
        let nests = try await Nest.query(on: req.db).all()
        let events = try await ActionEvent.query(on: req.db).all()
        let cutoff = Date().addingTimeInterval(-30 * 24 * 60 * 60)
        let activeUsers = Set(events.filter { $0.occurredAt >= cutoff }.compactMap { $0.$actor.id })
        let feedback = try await FeedbackThread.query(on: req.db).all()
        var recentUsers: [AdminUserResponse] = []
        for user in users.sorted(by: { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }).prefix(10) {
            recentUsers.append(try await adminUserResponse(user, on: req.db))
        }
        var recentFeedback: [FeedbackThreadResponse] = []
        for thread in feedback.sorted(by: { $0.lastActivityAt > $1.lastActivityAt }).prefix(10) {
            recentFeedback.append(try await feedbackResponse(thread, on: req.db, includeMessages: false))
        }
        return AdminDashboardResponse(totalUsers: users.count,
                                      verifiedUsers: users.filter(\.emailVerified).count,
                                      totalNests: nests.count, totalEvents: events.count,
                                      activeUsersLast30Days: activeUsers.count,
                                      openFeedback: feedback.filter { $0.status == FeedbackStatus.open }.count,
                                      inProgressFeedback: feedback.filter { $0.status == FeedbackStatus.inProgress }.count,
                                      resolvedFeedback: feedback.filter { $0.status == FeedbackStatus.resolved }.count,
                                      recentUsers: recentUsers, recentFeedback: recentFeedback)
    }

    admin.get("admin", "users") { req async throws -> [AdminUserResponse] in
        _ = try await req.requireNesticAdmin()
        let search = (try? req.query.get(String.self, at: "search"))?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let users = try await User.query(on: req.db).sort(\.$createdAt, .descending).range(..<200).all()
        let filteredUsers = users.filter { user in
            guard let search, !search.isEmpty else { return true }
            return user.email.lowercased().contains(search) || user.displayName.lowercased().contains(search)
        }
        var responses: [AdminUserResponse] = []
        for user in filteredUsers { responses.append(try await adminUserResponse(user, on: req.db)) }
        return responses
    }

    admin.get("admin", "feedback") { req async throws -> [FeedbackThreadResponse] in
        _ = try await req.requireNesticAdmin()
        let requestedStatus = try? req.query.get(String.self, at: "status")
        let threads = try await FeedbackThread.query(on: req.db)
            .sort(\.$lastActivityAt, .descending)
            .range(..<200)
            .all()
        let filteredThreads = threads.filter { requestedStatus == nil || requestedStatus == $0.status }
        var responses: [FeedbackThreadResponse] = []
        for thread in filteredThreads { responses.append(try await feedbackResponse(thread, on: req.db)) }
        return responses
    }

    admin.patch("admin", "feedback", ":id") { req async throws -> FeedbackThreadResponse in
        _ = try await req.requireNesticAdmin()
        let thread = try await feedbackThread(from: req)
        let input = try req.content.decode(UpdateFeedbackStatusRequest.self)
        guard FeedbackStatus.all.contains(input.status) else {
            throw Abort(.badRequest, reason: "Choose a valid feedback status.")
        }
        thread.status = input.status
        thread.lastActivityAt = Date()
        try await thread.save(on: req.db)
        return try await feedbackResponse(thread, on: req.db)
    }

    admin.post("admin", "feedback", ":id", "messages") { req async throws -> FeedbackThreadResponse in
        let adminUser = try await req.requireNesticAdmin()
        let thread = try await feedbackThread(from: req)
        let input = try req.content.decode(FeedbackMessageRequest.self)
        let body = try feedbackText(input.message, field: "Message")
        thread.lastActivityAt = Date()
        if thread.status == FeedbackStatus.open { thread.status = FeedbackStatus.inProgress }
        try await thread.save(on: req.db)
        try await FeedbackMessage(threadID: try thread.requireID(), authorUserID: try adminUser.requireID(), body: body).save(on: req.db)
        return try await feedbackResponse(thread, on: req.db)
    }
}

private func adminUserResponse(_ user: User, on db: any Database) async throws -> AdminUserResponse {
    let userID = try user.requireID()
    let nestCount = try await NestMember.query(on: db).filter(\.$user.$id == userID).count()
    return AdminUserResponse(id: userID, email: user.email, displayName: user.displayName,
                             emailVerified: user.emailVerified, createdAt: user.createdAt,
                             nestCount: nestCount)
}

private struct AdminRouteMiddleware: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        _ = try await request.requireNesticAdmin()
        return try await next.respond(to: request)
    }
}
