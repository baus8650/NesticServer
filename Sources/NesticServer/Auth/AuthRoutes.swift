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
    let clientID = Environment.get("APPLE_CLIENT_ID") ?? "com.bausch.Nestic-iOS"

    try identity.audience.verifyIntendedAudience(includes: clientID)
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
        guard let credentials = req.headers.basicAuthorization,
              let email = try? InputValidation.email(credentials.username),
              let user = try await User.query(on: req.db).filter(\.$email == email).first(),
              try await req.password.async.verify(credentials.password, created: user.passwordHash) else {
            throw Abort(.unauthorized, reason: "Email or password is incorrect.")
        }
        return TokenResponse(token: try await req.jwt.sign(SessionToken(with: user)))
    }

    app.post("auth", "apple") { req async throws -> TokenResponse in
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
}
