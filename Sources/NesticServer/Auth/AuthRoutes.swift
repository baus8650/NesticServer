import Vapor
import JWT
import Fluent
import Crypto
import Foundation

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

struct RegisterResponse: Content {
    let token: String?
    let requiresEmailVerification: Bool

    init(token: String? = nil, requiresEmailVerification: Bool) {
        self.token = token
        self.requiresEmailVerification = requiresEmailVerification
    }
}

struct AuthMessageResponse: Content {
    let message: String
}

struct EmailRequest: Content {
    let email: String
}

struct ResetPasswordRequest: Content {
    let token: String
    let password: String
}

struct UserResponse: Content {
    let id: UUID
    let email: String
    let displayName: String
    let imageURL: String?
    let createdAt: Date?
    let updatedAt: Date?
    let appleLinked: Bool
    let emailVerified: Bool
    let manualPro: Bool

    init(_ user: User) throws {
        id = try user.requireID()
        email = user.email
        displayName = user.displayName
        imageURL = user.imageURL
        createdAt = user.createdAt
        updatedAt = user.updatedAt
        appleLinked = user.appleSubject != nil
        emailVerified = user.emailVerified
        manualPro = manuallyUnlockedPro(for: user)
    }
}

/// Comma-separated account emails can be granted Pro access from the server
/// environment without changing the app or touching StoreKit transactions.
/// This is intentionally evaluated on every auth/me response so a Railway
/// environment-variable change takes effect after the next session refresh.
private func manuallyUnlockedPro(for user: User) -> Bool {
    let configured = Environment.get("NESTIC_MANUAL_PRO_EMAILS") ?? ""
    let emails = configured
        .split(separator: ",")
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        .filter { !$0.isEmpty }
    return emails.contains(user.email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
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

private func authTokenValue() -> String {
    var generator = SystemRandomNumberGenerator()
    let bytes = (0..<32).map { _ in UInt8.random(in: 0...UInt8.max, using: &generator) }
    return Data(bytes).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

private func authTokenHash(_ value: String) -> String {
    SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
}

private func makeAuthToken(for user: User, kind: AuthToken.Kind, lifetime: TimeInterval, on db: any Database) async throws -> (String, AuthToken) {
    let userID = try user.requireID()
    let existing = try await AuthToken.query(on: db)
        .filter(\.$userID == userID)
        .filter(\.$kind == kind.rawValue)
        .all()
    for token in existing { try await token.delete(on: db) }
    let value = authTokenValue()
    let token = AuthToken(userID: userID, kind: kind, tokenHash: authTokenHash(value), expiresAt: Date().addingTimeInterval(lifetime))
    return (value, token)
}

private func htmlResponse(title: String, message: String) -> Response {
    var headers = HTTPHeaders()
    headers.replaceOrAdd(name: .contentType, value: "text/html; charset=utf-8")
    let html = "<!doctype html><html><head><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"><title>\(title)</title></head><body style=\"margin:0;background:#f5f1e8;color:#183b2c;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif\"><main style=\"max-width:560px;margin:48px auto;padding:36px;background:#fffdf8;border:1px solid #ded8cb;border-radius:18px\"><div style=\"font-size:26px;font-weight:800\">nestic</div><h1>\(title)</h1><p style=\"font-size:17px;line-height:1.6\">\(message)</p><p>You can close this window and return to Nestic.</p></main></body></html>"
    return Response(status: .ok, headers: headers, body: .init(string: html))
}

func authRoutes(_ app: Application) throws {
    app.post("auth", "register") { req async throws -> RegisterResponse in
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
        // Integration tests intentionally avoid an external email provider.
        // Production and development accounts always take the verification path.
        if req.application.environment == .testing {
            user.emailVerified = true
            try await user.save(on: req.db)
            return RegisterResponse(token: try await req.jwt.sign(SessionToken(with: user)), requiresEmailVerification: false)
        }
        let (value, token) = try await makeAuthToken(for: user, kind: .emailVerification, lifetime: 60 * 60 * 24, on: req.db)
        try await token.save(on: req.db)
        do {
            try await NesticEmailService.sendVerification(on: req, to: email, displayName: displayName, token: value)
        } catch {
            try? await token.delete(on: req.db)
            try? await user.delete(on: req.db)
            throw error
        }
        return RegisterResponse(requiresEmailVerification: true)
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
        guard user.emailVerified else {
            throw Abort(.forbidden, reason: "Please verify your email address before signing in. Check your inbox for the verification link.")
        }
        return TokenResponse(token: try await req.jwt.sign(SessionToken(with: user)))
    }

    app.post("auth", "apple") { req async throws -> TokenResponse in
        try await req.enforceAuthRateLimit(operation: "apple")
        let input = try req.content.decode(AppleSignInRequest.self)
        let identity = try await verifyAppleIdentity(req, input: input)

        if let existing = try await User.query(on: req.db)
            .filter(\.$appleSubject == identity.subject.value).first() {
            if !existing.emailVerified {
                existing.emailVerified = true
                try await existing.save(on: req.db)
            }
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
            appleSubject: identity.subject.value,
            emailVerified: true
        )
        do { try await user.save(on: req.db) }
        catch let error as any DatabaseError where error.isConstraintFailure {
            throw Abort(.conflict, reason: "That Apple account is already in use.")
        }
        return TokenResponse(token: try await req.jwt.sign(SessionToken(with: user)))
    }

    app.get("auth", "verify") { req async throws -> Response in
        guard let value = try? req.query.get(String.self, at: "token"), !value.isEmpty,
              let token = try await AuthToken.query(on: req.db)
                .filter(\.$tokenHash == authTokenHash(value))
                .filter(\.$kind == AuthToken.Kind.emailVerification.rawValue)
                .first(), token.usedAt == nil, token.expiresAt > Date(),
              let user = try await User.find(token.userID, on: req.db) else {
            return htmlResponse(title: "This verification link is no longer valid", message: "Request a new verification email from the Nestic sign-in screen and try again.")
        }
        user.emailVerified = true
        token.usedAt = Date()
        try await user.save(on: req.db)
        try await token.save(on: req.db)
        return htmlResponse(title: "Email verified", message: "Your Nestic account is ready. Return to the app or website and sign in.")
    }

    app.post("auth", "resend-verification") { req async throws -> AuthMessageResponse in
        try await req.enforceAuthRateLimit(operation: "resend")
        let input = try req.content.decode(EmailRequest.self)
        let email = try InputValidation.email(input.email)
        if let user = try await User.query(on: req.db).filter(\.$email == email).first(), !user.emailVerified {
            do {
                let (value, token) = try await makeAuthToken(for: user, kind: .emailVerification, lifetime: 60 * 60 * 24, on: req.db)
                try await token.save(on: req.db)
                try await NesticEmailService.sendVerification(on: req, to: user.email, displayName: user.displayName, token: value)
            } catch {
                req.logger.error("Could not resend verification email", metadata: ["error": .string(String(describing: error))])
            }
        }
        return AuthMessageResponse(message: "If that email has an unverified Nestic account, a new verification link is on its way.")
    }

    app.post("auth", "forgot-password") { req async throws -> AuthMessageResponse in
        try await req.enforceAuthRateLimit(operation: "forgot")
        let input = try req.content.decode(EmailRequest.self)
        let email = try InputValidation.email(input.email)
        if let user = try await User.query(on: req.db).filter(\.$email == email).first(), user.emailVerified {
            do {
                let (value, token) = try await makeAuthToken(for: user, kind: .passwordReset, lifetime: 60 * 60, on: req.db)
                try await token.save(on: req.db)
                try await NesticEmailService.sendPasswordReset(on: req, to: user.email, displayName: user.displayName, token: value)
            } catch {
                req.logger.error("Could not send password reset email", metadata: ["error": .string(String(describing: error))])
            }
        }
        return AuthMessageResponse(message: "If an account exists for that email, a password reset link is on its way.")
    }

    app.post("auth", "reset-password") { req async throws -> AuthMessageResponse in
        try await req.enforceAuthRateLimit(operation: "reset")
        let input = try req.content.decode(ResetPasswordRequest.self)
        guard !input.token.isEmpty else { throw Abort(.badRequest, reason: "That password reset link is not valid.") }
        try InputValidation.password(input.password)
        guard let token = try await AuthToken.query(on: req.db)
            .filter(\.$tokenHash == authTokenHash(input.token))
            .filter(\.$kind == AuthToken.Kind.passwordReset.rawValue)
            .first(), token.usedAt == nil, token.expiresAt > Date(),
              let user = try await User.find(token.userID, on: req.db) else {
            throw Abort(.badRequest, reason: "That password reset link is expired or invalid. Request a new one.")
        }
        user.passwordHash = try await req.password.async.hash(input.password)
        token.usedAt = Date()
        try await user.save(on: req.db)
        try await token.save(on: req.db)
        return AuthMessageResponse(message: "Your password was changed. You can sign in now.")
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
        user.emailVerified = true
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

            try await AuthToken.query(on: tx)
                .filter(\.$userID == session.userId)
                .delete()
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
