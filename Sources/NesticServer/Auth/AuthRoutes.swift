import Vapor
import JWT
import Fluent

struct SessionToken: Content, Authenticatable, JWTPayload {
    static let expirationTime: TimeInterval = 60 * 60 * 24 * 7
    var expiration: ExpirationClaim
    var userId: UUID

    init(userId: UUID) {
        self.userId = userId
        self.expiration = ExpirationClaim(value: Date().addingTimeInterval(Self.expirationTime))
    }

    init(with user: User) throws { self.init(userId: try user.requireID()) }

    func verify(using algorithm: some JWTAlgorithm) throws {
        try expiration.verifyNotExpired()
    }
}

struct TokenResponse: Content { let token: String }

struct UserResponse: Content {
    let id: UUID
    let email: String
    let displayName: String
    let imageURL: String?
    let createdAt: Date?
    let updatedAt: Date?
    let appleLinked: Bool

    init(_ user: User) throws {
        id = try user.requireID()
        email = user.email
        displayName = user.displayName
        imageURL = user.imageURL
        createdAt = user.createdAt
        updatedAt = user.updatedAt
        appleLinked = user.appleSubject != nil
    }
}

struct RegisterRequest: Content {
    let email: String
    let password: String
    let displayName: String
    let imageURL: String?
}

struct AppleSignInRequest: Content {
    let identityToken: String
    let user: String
    let email: String?
    let displayName: String?
    let nonce: String?
}

private func appleClientIDs() -> [String] {
    let configured = Environment.get("APPLE_CLIENT_IDS")
        ?? Environment.get("APPLE_CLIENT_ID")
        ?? "com.bausch.Nestic-iOS"
    return configured
        .split(separator: ",")
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
}

private func verifyAppleIdentity(_ req: Request, input: AppleSignInRequest) async throws -> AppleIdentityToken {
    guard !input.identityToken.isEmpty, !input.user.isEmpty else {
        throw Abort(.badRequest, reason: "Apple sign-in did not return a usable identity.")
    }

    let response = try await req.application.client.get(URI(string: "https://appleid.apple.com/auth/keys"))
    guard response.status == .ok, var body = response.body,
          let jwksJSON = body.readString(length: body.readableBytes) else {
        throw Abort(.badGateway, reason: "Apple sign-in is temporarily unavailable.")
    }

    let appleKeys = JWTKeyCollection()
    try await appleKeys.add(jwksJSON: jwksJSON)
    let identity = try await appleKeys.verify(input.identityToken, as: AppleIdentityToken.self)

    let acceptedAudience = appleClientIDs().contains { clientID in
        (try? identity.audience.verifyIntendedAudience(includes: clientID)) != nil
    }
    guard acceptedAudience else {
        throw Abort(.unauthorized, reason: "Apple sign-in was issued for a different Nestic client.")
    }
    guard identity.subject.value == input.user else {
        throw Abort(.unauthorized, reason: "Apple sign-in identity did not match the request.")
    }
    guard let requestNonce = input.nonce, !requestNonce.isEmpty,
          identity.nonce == requestNonce else {
        throw Abort(.unauthorized, reason: "Apple sign-in could not be verified.")
    }
    return identity
}

private func appleDisplayName(_ input: AppleSignInRequest, email: String?) -> String {
    if let supplied = input.displayName,
       let clean = try? InputValidation.name(supplied), !clean.isEmpty {
        return clean
    }
    if let email, let prefix = email.split(separator: "@").first, !prefix.isEmpty {
        return String(prefix)
    }
    return "Apple user"
}

func authRoutes(_ app: Application) throws {
    app.post("auth", "register") { req async throws -> TokenResponse in
        try await req.enforceAuthRateLimit(operation: "register")
        let input = try req.content.decode(RegisterRequest.self)
        let email = try InputValidation.email(input.email)
        let displayName = try InputValidation.name(input.displayName, field: "Display name")
        try InputValidation.password(input.password)
        if try await User.query(on: req.db).filter(\.$email == email).first() != nil {
            throw Abort(.conflict, reason: "Email already in use.")
        }
        let user = User(email: email, passwordHash: try await req.password.async.hash(input.password),
                        displayName: displayName, imageURL: input.imageURL)
        do { try await user.save(on: req.db) }
        catch let error as any DatabaseError where error.isConstraintFailure {
            throw Abort(.conflict, reason: "Email already in use.")
        }
        return TokenResponse(token: try await req.jwt.sign(SessionToken(with: user)))
    }

    // HTTP Basic authentication, with case-insensitive account email normalization.
    app.post("auth", "login") { req async throws -> TokenResponse in
        try await req.enforceAuthRateLimit(operation: "login")
        guard let credentials = req.headers.basicAuthorization,
              let email = try? InputValidation.email(credentials.username),
              let user = try await User.query(on: req.db).filter(\.$email == email).first(),
              try await req.password.async.verify(credentials.password, created: user.passwordHash) else {
            throw Abort(.unauthorized, reason: "Email or password is incorrect.")
        }
        return TokenResponse(token: try await req.jwt.sign(SessionToken(with: user)))
    }

    app.post("auth", "apple") { req async throws -> TokenResponse in
        try await req.enforceAuthRateLimit(operation: "apple")
        let input = try req.content.decode(AppleSignInRequest.self)
        let identity = try await verifyAppleIdentity(req, input: input)

        if let existing = try await User.query(on: req.db)
            .filter(\.$appleSubject == identity.subject.value).first() {
            return TokenResponse(token: try await req.jwt.sign(SessionToken(with: existing)))
        }

        guard let rawEmail = identity.email ?? input.email,
              let email = try? InputValidation.email(rawEmail) else {
            throw Abort(.badRequest, reason: "Apple did not provide an email address. Please try again.")
        }
        if try await User.query(on: req.db).filter(\.$email == email).first() != nil {
            throw Abort(.conflict, reason: "An account already uses that email. Sign in with your password, then link Apple from account settings.")
        }

        let user = User(
            email: email,
            passwordHash: try await req.password.async.hash(UUID().uuidString),
            displayName: appleDisplayName(input, email: email),
            appleSubject: identity.subject.value
        )
        do { try await user.save(on: req.db) }
        catch let error as any DatabaseError where error.isConstraintFailure {
            throw Abort(.conflict, reason: "That Apple account is already in use.")
        }
        return TokenResponse(token: try await req.jwt.sign(SessionToken(with: user)))
    }

    let protected = app.grouped(SessionToken.authenticator(), SessionToken.guardMiddleware())
    protected.post("auth", "apple", "link") { req async throws -> UserResponse in
        try await req.enforceAuthRateLimit(operation: "apple")
        let session = try req.auth.require(SessionToken.self)
        guard let user = try await User.find(session.userId, on: req.db) else {
            throw Abort(.unauthorized)
        }
        let input = try req.content.decode(AppleSignInRequest.self)
        let identity = try await verifyAppleIdentity(req, input: input)
        if let existing = try await User.query(on: req.db)
            .filter(\.$appleSubject == identity.subject.value).first(), existing.id != user.id {
            throw Abort(.conflict, reason: "That Apple account is already linked to another Nestic account.")
        }
        user.appleSubject = identity.subject.value
        try await user.save(on: req.db)
        return try UserResponse(user)
    }

    protected.get("auth", "me") { req async throws -> UserResponse in
        let session = try req.auth.require(SessionToken.self)
        guard let user = try await User.find(session.userId, on: req.db) else {
            throw Abort(.unauthorized)
        }
        return try UserResponse(user)
    }

    /// Permanently removes the authenticated account and its private data.
    ///
    /// A shared nest survives account deletion when another member exists; the
    /// oldest administrator/member is promoted to owner so the nest never gets
    /// stranded. A nest owned only by the deleting account is removed with its
    /// entities, trackers, and activity. R2 avatars are cleaned up after the
    /// database transaction on a best-effort basis.
    protected.delete("auth", "me") { req async throws -> AccountDeletionResponse in
        let session = try req.auth.require(SessionToken.self)
        guard let user = try await User.find(session.userId, on: req.db) else {
            throw Abort(.unauthorized, reason: "That account no longer exists.")
        }

        let memberships = try await NestMember.query(on: req.db)
            .filter(\.$user.$id == session.userId)
            .all()
        let ownedNestIDs = memberships.filter { $0.role == .owner }.map { $0.$nest.id }
        var nestIDsToDelete: [UUID] = []
        var avatarKeysToDelete: [String] = []

        for nestID in ownedNestIDs {
            let remainingMembers = (try await NestMember.query(on: req.db)
                .filter(\.$nest.$id == nestID)
                .all())
                .filter { $0.$user.id != session.userId }
            if remainingMembers.isEmpty {
                nestIDsToDelete.append(nestID)
            }
        }

        for nestID in nestIDsToDelete {
            let entities = try await Entity.query(on: req.db)
                .filter(\.$nest.$id == nestID)
                .all()
            avatarKeysToDelete.append(contentsOf: entities.compactMap { R2Storage.key(from: $0.imageURL) })
        }
        let deletableNestIDs = Set(nestIDsToDelete)

        try await req.db.transaction { tx in
            for nestID in ownedNestIDs {
                let nestMembers = try await NestMember.query(on: tx)
                    .filter(\.$nest.$id == nestID)
                    .all()
                let remaining = nestMembers.filter { $0.$user.id != session.userId }

                if let replacement = remaining.sorted(by: ownerReplacementOrder).first {
                    replacement.role = .owner
                    try await replacement.save(on: tx)
                } else if deletableNestIDs.contains(nestID), let nest = try await Nest.find(nestID, on: tx) {
                    try await nest.delete(on: tx)
                }
            }

            try await user.delete(on: tx)
        }

        for nestID in memberships.map({ $0.$nest.id }) {
            req.application.realtimeHub.disconnect(userId: session.userId, nestId: nestID)
        }
        if let storage = req.application.r2Storage {
            for key in avatarKeysToDelete {
                do { try await storage.delete(key: key, logger: req.logger) }
                catch { req.logger.warning("Could not delete account avatar from R2", metadata: ["key": .string(key)]) }
            }
        }

        return AccountDeletionResponse(deleted: true)
    }
}

struct AccountDeletionResponse: Content {
    let deleted: Bool
}

private func ownerReplacementOrder(_ lhs: NestMember, _ rhs: NestMember) -> Bool {
    let rank: [NestRole: Int] = [.admin: 0, .member: 1, .viewer: 2, .owner: 3]
    let lhsRank = rank[lhs.role, default: 3]
    let rhsRank = rank[rhs.role, default: 3]
    if lhsRank != rhsRank { return lhsRank < rhsRank }
    return (lhs.createdAt ?? .distantFuture) < (rhs.createdAt ?? .distantFuture)
}
