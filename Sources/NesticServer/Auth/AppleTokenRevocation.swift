import Vapor
import JWT

private struct AppleClientSecret: JWTPayload {
    let iss: String
    let iat: Int
    let exp: Int
    let aud: String
    let sub: String
    func verify(using algorithm: some JWTAlgorithm) throws {}
}

/// Exchange a fresh code for deletion without persisting Apple access tokens.
func revokeAppleAuthorization(on req: Request, code: String, clientID: String) async throws {
    guard let teamID = Environment.get("APPLE_TEAM_ID"),
          let keyID = Environment.get("APPLE_KEY_ID"),
          let pem = Environment.get("APPLE_PRIVATE_KEY"), !code.isEmpty else {
        throw Abort(.serviceUnavailable, reason: "Apple authorization revocation is not configured.")
    }
    let keys = JWTKeyCollection()
    let key = try ECDSA.PrivateKey<P256>(pem: pem.replacingOccurrences(of: "\\n", with: "\n"))
    let kid = JWKIdentifier(string: keyID)
    await keys.add(ecdsa: key, kid: kid)
    let now = Int(Date().timeIntervalSince1970)
    let secret = try await keys.sign(AppleClientSecret(iss: teamID, iat: now, exp: now + 300,
                                                     aud: "https://appleid.apple.com", sub: clientID), kid: kid)
    let tokens = try await req.client.post("https://appleid.apple.com/auth/token") { request in
        try request.content.encode(["client_id": clientID, "client_secret": secret,
                                    "code": code, "grant_type": "authorization_code"], as: .urlEncodedForm)
    }
    guard tokens.status == .ok else { throw Abort(.badGateway, reason: "Apple could not confirm account authorization.") }
    struct Tokens: Content { let refresh_token: String }
    let token = try tokens.content.decode(Tokens.self).refresh_token
    let response = try await req.client.post("https://appleid.apple.com/auth/revoke") { request in
        try request.content.encode(["client_id": clientID, "client_secret": secret,
                                    "token": token, "token_type_hint": "refresh_token"], as: .urlEncodedForm)
    }
    guard response.status == .ok else { throw Abort(.badGateway, reason: "Apple could not revoke account authorization.") }
}
