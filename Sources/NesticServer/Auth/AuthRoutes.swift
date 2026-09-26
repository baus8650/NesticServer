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

    init(_ user: User) throws {
        id = try user.requireID()
        email = user.email
        displayName = user.displayName
        imageURL = user.imageURL
        createdAt = user.createdAt
        updatedAt = user.updatedAt
    }
}

struct RegisterRequest: Content {
    let email: String
    let password: String
    let displayName: String
    let imageURL: String?
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

    let protected = app.grouped(SessionToken.authenticator(), SessionToken.guardMiddleware())
    protected.get("auth", "me") { req async throws -> UserResponse in
        let session = try req.auth.require(SessionToken.self)
        guard let user = try await User.find(session.userId, on: req.db) else {
            throw Abort(.unauthorized)
        }
        return try UserResponse(user)
    }
}
