import Vapor
import JWT
import Fluent
import SQLKit
import Crypto

struct GoogleSignInRequest: Content {
    let identityToken: String
    let nonce: String
    var acceptedTermsVersion: String? = nil
}
struct GoogleChallengeResponse: Content { let nonce: String; let expiresIn: Int }

/// Only Google's fixed HTTPS JWKS endpoint is trusted; cached for five minutes.
actor GoogleIdentityKeys {
    private var keys: JWTKeyCollection?
    private var refreshedAt = Date.distantPast
    init(testKeys: JWTKeyCollection? = nil) { keys = testKeys; if testKeys != nil { refreshedAt = Date() } }
    func verify(_ token: String, client: any Client) async throws -> GoogleIdentityToken {
        if keys == nil || Date().timeIntervalSince(refreshedAt) > 300 {
            let response = try await client.get("https://www.googleapis.com/oauth2/v3/certs")
            guard response.status == .ok, var body = response.body,
                  let json = body.readString(length: body.readableBytes) else {
                throw Abort(.badGateway, reason: "Google sign-in is temporarily unavailable.")
            }
            let fresh = JWTKeyCollection()
            try await fresh.add(jwksJSON: json)
            keys = fresh; refreshedAt = Date()
        }
        guard let keys else { throw Abort(.badGateway) }
        return try await keys.verify(token, as: GoogleIdentityToken.self)
    }
}
extension Application {
    private struct GoogleKeysKey: StorageKey { typealias Value = GoogleIdentityKeys }
    private struct GoogleAudiencesKey: StorageKey { typealias Value = [String] }
    var googleIdentityKeys: GoogleIdentityKeys {
        get { if let keys = storage[GoogleKeysKey.self] { return keys }; let keys = GoogleIdentityKeys(); storage[GoogleKeysKey.self] = keys; return keys }
        set { precondition(environment == .testing); storage[GoogleKeysKey.self] = newValue }
    }
    var googleClientIDs: [String] {
        get { storage[GoogleAudiencesKey.self] ?? (Environment.get("GOOGLE_CLIENT_IDS") ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty } }
        set { precondition(environment == .testing); storage[GoogleAudiencesKey.self] = newValue }
    }
}
func validateGoogleIdentity(_ identity: GoogleIdentityToken, audiences: [String], nonce: String, at date: Date = Date()) throws {
    guard !audiences.isEmpty else { throw Abort(.serviceUnavailable, reason: "Google sign-in has not been configured on this server.") }
    guard audiences.contains(where: { (try? identity.audience.verifyIntendedAudience(includes: $0)) != nil }),
          !identity.subject.value.isEmpty,
          identity.issuedAt.value <= date.addingTimeInterval(60),
          identity.emailVerified?.value == true,
          identity.nonce == nonce, nonce.count >= 32, nonce.count <= 256 else {
        throw Abort(.unauthorized, reason: "Google sign-in could not be verified. Please try again.")
    }
}
private func googleNonceHash(_ nonce: String) -> String { SHA256.hash(data: Data(nonce.utf8)).map { String(format: "%02x", $0) }.joined() }
private func verifiedGoogleIdentity(_ req: Request, _ input: GoogleSignInRequest) async throws -> GoogleIdentityToken {
    guard !req.application.googleClientIDs.isEmpty else { throw Abort(.serviceUnavailable, reason: "Google sign-in has not been configured on this server.") }
    guard input.identityToken.count <= 16000, !input.identityToken.isEmpty, (32...256).contains(input.nonce.count) else { throw Abort(.badRequest, reason: "Google sign-in did not return a usable identity.") }
    let identity: GoogleIdentityToken
    do { identity = try await req.application.googleIdentityKeys.verify(input.identityToken, client: req.client) }
    catch let error as Abort where error.status == .badGateway { throw error }
    catch { throw Abort(.unauthorized, reason: "Google sign-in could not be verified. Please try again.") }
    try validateGoogleIdentity(identity, audiences: req.application.googleClientIDs, nonce: input.nonce)
    return identity
}
private func consumeGoogleNonce(_ nonce: String, on db: any Database) async throws {
    guard let sql = db as? any SQLDatabase else { throw Abort(.internalServerError) }
    let rows = try await sql.raw("DELETE FROM google_signin_challenges WHERE nonce_hash = \(bind: googleNonceHash(nonce)) AND expires_at > NOW() RETURNING nonce_hash").all()
    guard rows.count == 1 else { throw Abort(.unauthorized, reason: "Google sign-in expired or was already used. Please try again.") }
}

func googleAuthRoutes(_ app: Application) {
    app.post("auth", "google", "challenge") { req async throws -> GoogleChallengeResponse in
        try await req.enforceAuthRateLimit(operation: "google-challenge")
        guard !req.application.googleClientIDs.isEmpty else { throw Abort(.serviceUnavailable, reason: "Google sign-in has not been configured on this server.") }
        guard let sql = req.db as? any SQLDatabase else { throw Abort(.internalServerError) }
        let nonce = (0..<32).map { _ in UInt8.random(in: .min ... .max) }.map { String(format: "%02x", $0) }.joined()
        try await sql.raw("DELETE FROM google_signin_challenges WHERE expires_at <= NOW()").run()
        try await sql.raw("INSERT INTO google_signin_challenges (nonce_hash, expires_at) VALUES (\(bind: googleNonceHash(nonce)), \(bind: Date().addingTimeInterval(300)))").run()
        return GoogleChallengeResponse(nonce: nonce, expiresIn: 300)
    }
    app.post("auth", "google") { req async throws -> TokenResponse in
        try await req.enforceAuthRateLimit(operation: "google")
        let input = try req.content.decode(GoogleSignInRequest.self)
        let identity = try await verifiedGoogleIdentity(req, input)
        let user = try await req.db.transaction { db -> User in
            if let existing = try await User.query(on: db).filter(\.$googleSubject == identity.subject.value).first() {
                try await consumeGoogleNonce(input.nonce, on: db)
                return existing
            }
            try NesticTerms.requireAcceptance(input.acceptedTermsVersion)
            guard let rawEmail = identity.email, let email = try? InputValidation.email(rawEmail) else { throw Abort(.badRequest, reason: "Google did not provide a verified email address.") }
            // Never merge by email: possession of an existing Nestic session is required.
            guard try await User.query(on: db).filter(\.$email == email).first() == nil else { throw Abort(.conflict, reason: "A Nestic account already uses that email. Sign in with your password, then link Google from Your nest. If you use Apple, link Google after signing in to the same account, or contact support.") }
            try await consumeGoogleNonce(input.nonce, on: db)
            let name = (try? InputValidation.name(identity.name ?? "")) ?? String(email.split(separator: "@")[0])
            let user = User(email: email, passwordHash: try await req.password.async.hash(UUID().uuidString + UUID().uuidString), displayName: name, emailVerified: true)
            user.googleSubject = identity.subject.value; user.termsVersion = input.acceptedTermsVersion; user.termsAcceptedAt = Date()
            do { try await user.save(on: db) }
            catch let error as any DatabaseError where error.isConstraintFailure { throw Abort(.conflict, reason: "That Google account or email is already in use. Sign in again.") }
            return user
        }
        return TokenResponse(token: try await req.jwt.sign(SessionToken(with: user)))
    }
    let protected = app.grouped(SessionToken.authenticator(), SessionToken.guardMiddleware())
    protected.post("auth", "google", "link") { req async throws -> UserResponse in
        try await req.enforceAuthRateLimit(operation: "google")
        let session = try req.auth.require(SessionToken.self)
        let input = try req.content.decode(GoogleSignInRequest.self)
        let identity = try await verifiedGoogleIdentity(req, input)
        let user = try await req.db.transaction { db -> User in
            guard let user = try await User.find(session.userId, on: db) else { throw Abort(.unauthorized) }
            guard user.googleSubject == nil || user.googleSubject == identity.subject.value else { throw Abort(.conflict, reason: "A different Google account is already linked to this Nestic account.") }
            if let linked = try await User.query(on: db).filter(\.$googleSubject == identity.subject.value).first(), linked.id != user.id { throw Abort(.conflict, reason: "That Google account is already linked to another Nestic account.") }
            try await consumeGoogleNonce(input.nonce, on: db)
            user.googleSubject = identity.subject.value
            do { try await user.save(on: db) }
            catch let error as any DatabaseError where error.isConstraintFailure { throw Abort(.conflict, reason: "That Google account is already linked to another Nestic account.") }
            return user
        }
        return try UserResponse(user)
    }
}
