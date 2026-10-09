@testable import NesticServer
import Testing
import VaporTesting
import JWT
import Fluent

// Public test fixture from JWTKit; never trusted by a production application.
private let googleTestKey = """
    -----BEGIN PRIVATE KEY-----
    MIIEvAIBADANBgkqhkiG9w0BAQEFAASCBKYwggSiAgEAAoIBAQDL8W1D9w5zHpmD
    JqpTngIRJ+Sm21e42cRnTudhdejzKUiJQWkHSvQV5yC/+0iEXUsUJYEdSyrKhJFD
    PT+IFGdjIiwb7IX+rUreWXlD/YYBL3/byMG4kYoO4oiPp2A+WvfeyLpuN549OXhk
    7o5kXEZjKfjHTfmnAbCMoYW5BEpiHQC3HAeJZ5EiwAn8HZn5UY6lxJcf7H9hR83x
    D0W7IZTNyxUu4aLNuihFIxJKgP/L/y95Y6ddZsyyHQopM43/7JOYBwufa07MWaxi
    AdBdq1bR/ZeOt2aZaXhV+J6QUoUO8Z6fG6b2cQmvMgk4ybqoeciLII0DfFsyqavu
    ip4hRr59AgMBAAECggEAUIw994XwMw922hG/W98gOd5jtHMVJnD73UGQqTGEm+VG
    PM+Ux8iWtr/ec3Svo3elW4OkhwlVET9ikAf0u64zVzf769ty4K9YzpDQEEZlUrqL
    6SZVPKxetppKDVKx9G7BT0BAQZ+947h7EIIXwxOeyTOeijkFzSwhqqlwwy4qoqzV
    FTQS20QHE62hxzwuS5HBqw8ds183qAg9NbzR0Cp4za9qTiBB6C8KEcLqeatO+q+d
    VCDsJcAMZOvW14N6BozKgbQ/WXZQ/3kNUPBndZLzzqaILFNmB1Zf2DVVJ9gU7+EK
    xOac60StIfG81NllCTBrmRVq8yitNqwmutHMlxrIkQKBgQDvp39MkEHtNunFGkI5
    R8IB5BZjtx5OdRBKkmPasmNU8U0XoQAJUKY/9piIpCtRi87tMXv8WWmlbULi66pu
    4BnMIisw78xlIWRZTSizFrkFcEoVgEnbZBtSrOg/J5PAcjLEGCQoAdmMXAekR2/m
    htv7FPijHPNUjyIFLaxwjl9izwKBgQDZ2mQeKNRHjIb5ZBzB0ZCvUy2y4+kaLrhZ
    +CWMN1flL4dd1KuZKvCEfHY9kWOjqw6XneN4yT0aPmbBft4fihiiNW0Sm8i+fSpy
    g0klw2HJl49wnwctBpRgTdMKGo9n14OGeu0xKOAy7I4j1tKrUXiRWnP9R583Ti7c
    w7YHgdHM8wKBgEV147SaPzF08A6bzMPzY2zO4hpmsdcFoQIsKdryR04QXkrR9EO+
    52C0pYM9Kf0Jq6Ed7ZS3iaJT58YDjjNyqqd648/cQP6yzfYAIiK+HERSRnay5zU6
    b5zn1qyvWOi3cLVbVedumdJPvjtEJU/ImKvOaT5FntVMYwzjLw60hTsLAoGAZJnt
    UeAY51GFovUQMpDL96q5l7qXknewuhtVe4KzHCrun+3tsDWcDBJNp/DTymjbvDg1
    KzoC9XOLkB8+A+KJrZ5uWAGImi7Cw07NIJsxNR7AJonJjolTS4Wkxy2su49SNW/e
    yKzPm7SRjwtNDb/5pWXX2kaQx8Fa8qeOD7lrYPECgYAwQ6o0vYmr+L1tOZZgMVv9
    Jusa8beVUH5hyduJjmxbYOtFTkggAozdx7rs4BgyRsmDlV48cEmcVf/7IH4gMJLb
    O+bbERwCYUChe+piANhnwfwDHzbRd8mmQus54P06X7bWu6Rmi7gbQGVN/Z6VhbIm
    D2cOo0w4bk/3yb01xz1MEw==
    -----END PRIVATE KEY-----
    """
private let audience = "nestic-test.apps.googleusercontent.com"
private func googleIdentity(nonce: String, subject: String = "google-test-subject", email: String = "google@example.com", aud: String = audience, verified: Bool = true, issued: Date = Date(), expires: Date = Date().addingTimeInterval(3600), issuer: String = "https://accounts.google.com") -> GoogleIdentityToken {
    GoogleIdentityToken(issuer: .init(value: issuer), subject: .init(value: subject), audience: .init(value: aud), authorizedPresenter: "android-test.apps.googleusercontent.com", issuedAt: .init(value: issued), expires: .init(value: expires), email: email, emailVerified: .init(value: verified), name: "Google Tester", nonce: nonce)
}
private func testKeys() async throws -> JWTKeyCollection { try await JWTKeyCollection().add(rsa: Insecure.RSA.PrivateKey(pem: googleTestKey), digestAlgorithm: .sha256, kid: "google-test") }

@Suite("Google token boundaries")
struct GoogleTokenTests {
    @Test("Audience, nonce, verified email, subject, future issue time and configuration are required")
    func claims() throws {
        let nonce = String(repeating: "a", count: 64)
        try validateGoogleIdentity(googleIdentity(nonce: nonce), audiences: [audience], nonce: nonce)
        for identity in [googleIdentity(nonce: nonce, aud: "another.apps.googleusercontent.com"), googleIdentity(nonce: "wrong"), googleIdentity(nonce: nonce, verified: false), googleIdentity(nonce: nonce, issued: Date().addingTimeInterval(120)), googleIdentity(nonce: nonce, subject: "")] {
            #expect(throws: (any Error).self) { try validateGoogleIdentity(identity, audiences: [audience], nonce: nonce) }
        }
        #expect(throws: (any Error).self) { try validateGoogleIdentity(googleIdentity(nonce: nonce), audiences: [], nonce: nonce) }
    }
    @Test("RSA signature, Google issuer and expiration are checked by JWTKit")
    func cryptography() async throws {
        let keys = try await testKeys(); let nonce = String(repeating: "b", count: 64)
        let token = try await keys.sign(googleIdentity(nonce: nonce), kid: "google-test")
        let result = try await keys.verify(token, as: GoogleIdentityToken.self)
        #expect(result.subject.value == "google-test-subject")
        for identity in [googleIdentity(nonce: nonce, expires: Date().addingTimeInterval(-60)), googleIdentity(nonce: nonce, issuer: "https://attacker.example")] {
            let invalid = try await keys.sign(identity, kid: "google-test")
            await #expect(throws: (any Error).self) { _ = try await keys.verify(invalid, as: GoogleIdentityToken.self) }
        }
        let other = JWTKeyCollection(); await other.add(hmac: HMACKey(from: "untrusted-key"), digestAlgorithm: .sha256)
        let forged = try await other.sign(googleIdentity(nonce: nonce))
        await #expect(throws: (any Error).self) { _ = try await keys.verify(forged, as: GoogleIdentityToken.self) }
    }
    @Test("Unconfigured Google sign-in fails closed before database access")
    func unconfigured() async throws {
        let app = try await Application.make(.testing)
        do {
            try await configure(app); app.googleClientIDs = []
            try await app.testing().test(.POST, "auth/google/challenge") { response async in #expect(response.status == .serviceUnavailable) }
            try await app.asyncShutdown()
        } catch { try await app.asyncShutdown(); throw error }
    }
}
@Suite("Google Postgres lifecycle", .serialized, .enabled(if: Environment.get("RUN_DATABASE_TESTS") == "true"))
struct GoogleDatabaseTests {
    @Test("Explicit signup, stable subject login, one-time nonce, email collision and authenticated linking")
    func lifecycle() async throws {
        let app = try await Application.make(.testing); let suffix = UUID().uuidString.lowercased()
        let email = "google-\(suffix)@example.com"; let legacyEmail = "legacy-\(suffix)@example.com"
        do {
            try await configure(app); try await app.autoMigrate()
            let keys = try await testKeys(); app.googleIdentityKeys = GoogleIdentityKeys(testKeys: keys); app.googleClientIDs = [audience]
            func nonce() async throws -> String {
                var value = ""
                try await app.testing().test(.POST, "auth/google/challenge") { response async throws in #expect(response.status == .ok); value = try response.content.decode(GoogleChallengeResponse.self).nonce }
                return value
            }
            func sign(_ nonce: String, subject: String, email: String) async throws -> String { try await keys.sign(googleIdentity(nonce: nonce, subject: subject, email: email), kid: "google-test") }
            func login(_ input: GoogleSignInRequest, expected: HTTPStatus) async throws -> String? {
                var token: String?
                try await app.testing().test(.POST, "auth/google", beforeRequest: { request async throws in try request.content.encode(input) }, afterResponse: { response async throws in #expect(response.status == expected); if response.status == .ok { token = try response.content.decode(TokenResponse.self).token } })
                return token
            }
            let firstNonce = try await nonce(); let firstToken = try await sign(firstNonce, subject: suffix, email: email)
            _ = try await login(.init(identityToken: firstToken, nonce: firstNonce), expected: .preconditionRequired)
            let signedIn = try #require(await login(.init(identityToken: firstToken, nonce: firstNonce, acceptedTermsVersion: NesticTerms.currentVersion), expected: .ok))
            _ = try await login(.init(identityToken: firstToken, nonce: firstNonce), expected: .unauthorized)
            let user = try #require(await User.query(on: app.db).filter(\.$googleSubject == suffix).first())
            #expect(user.emailVerified); #expect(user.termsVersion == NesticTerms.currentVersion)
            let nextNonce = try await nonce(); let nextToken = try await sign(nextNonce, subject: suffix, email: email)
            _ = try await login(.init(identityToken: nextToken, nonce: nextNonce), expected: .ok)
            try await app.testing().test(.GET, "auth/me", headers: ["Authorization": "Bearer \(signedIn)"]) { response async throws in #expect(try response.content.decode(UserResponse.self).googleLinked) }
            let legacy = User(email: legacyEmail, passwordHash: "unused", displayName: "Existing member", emailVerified: true); try await legacy.save(on: app.db)
            let linkNonce = try await nonce(); let linkToken = try await sign(linkNonce, subject: "legacy-\(suffix)", email: legacyEmail)
            let input = GoogleSignInRequest(identityToken: linkToken, nonce: linkNonce, acceptedTermsVersion: NesticTerms.currentVersion)
            _ = try await login(input, expected: .conflict)
            #expect(try await User.query(on: app.db).filter(\.$email == legacyEmail).first()?.googleSubject == nil)
            let session = try await app.jwt.keys.sign(SessionToken(with: legacy))
            try await app.testing().test(.POST, "auth/google/link", headers: ["Authorization": "Bearer \(session)"], beforeRequest: { request async throws in try request.content.encode(input) }, afterResponse: { response async throws in #expect(response.status == .ok); #expect(try response.content.decode(UserResponse.self).googleLinked) })
            let missingNonce = String(repeating: "c", count: 64); let missingToken = try await sign(missingNonce, subject: suffix, email: email)
            _ = try await login(.init(identityToken: missingToken, nonce: missingNonce), expected: .unauthorized)
            try await user.delete(on: app.db); try await legacy.delete(on: app.db); try await app.asyncShutdown()
        } catch { try? await User.query(on: app.db).filter(\.$email ~~ [email, legacyEmail]).delete(); try await app.asyncShutdown(); throw error }
    }
}
