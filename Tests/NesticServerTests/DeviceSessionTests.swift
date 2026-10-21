@testable import NesticServer
import Fluent
import JWT
import Testing
import VaporTesting

@Suite("Persistent device sessions", .serialized)
struct DeviceSessionTests {
    @Test("Expired legacy tokens still fail; malformed device tokens fail without database access")
    func invalidCredentials() async throws {
        let app = try await Application.make(.testing)
        do {
            try await configure(app)
            var expired = SessionToken(userId: UUID())
            expired.expiration = ExpirationClaim(value: Date(timeIntervalSince1970: 0))
            let jwt = try await app.jwt.keys.sign(expired)
            for token in [jwt, "nestic_device_bad", "invalid"] {
                try await app.testing().test(.GET, "auth/me", headers: ["Authorization": "Bearer \(token)"]) { res async in
                    #expect(res.status == .unauthorized)
                }
            }
            try await app.asyncShutdown()
        } catch {
            try await app.asyncShutdown()
            throw error
        }
    }

    @Test("Legacy upgrade survives years of inactivity, is hashed, and sign-out revokes only this device",
          .enabled(if: Environment.get("RUN_DATABASE_TESTS") == "true"))
    func persistentSessionLifecycle() async throws {
        let app = try await Application.make(.testing)
        let user = User(email: "device-\(UUID().uuidString.lowercased())@example.com", passwordHash: "unused", displayName: "Device", emailVerified: true)
        do {
            try await configure(app)
            try await app.autoMigrate()
            user.passwordHash = try await app.password.async.hash("Persistent-test-123!")
            try await user.save(on: app.db)
            let userID = try user.requireID()
            let jwt = try await app.jwt.keys.sign(SessionToken(with: user))
            // Native sign-in opts into persistent credentials; browsers remain JWT clients.
            for persistent in [false, true] {
                var headers = HTTPHeaders()
                if persistent { headers.add(name: "X-Nestic-Persistent-Session", value: "1") }
                headers.basicAuthorization = BasicAuthorization(username: user.email, password: "Persistent-test-123!")
                try await app.testing().test(.POST, "auth/login", headers: headers, afterResponse: { res async throws in
                    #expect(res.status == .ok)
                    let token = try res.content.decode(TokenResponse.self).token
                    #expect(token.hasPrefix("nestic_device_") == persistent)
                })
            }
            // Remove the sign-in fixture's session before checking two independent upgrades.
            try await DeviceSession.query(on: app.db).filter(\.$userID == userID).delete()
            var devices: [String] = []
            for _ in 0..<2 {
                try await app.testing().test(.POST, "auth/session", headers: ["Authorization": "Bearer \(jwt)"]) { res async throws in
                    #expect(res.status == .ok)
                    devices.append(try res.content.decode(TokenResponse.self).token)
                }
            }
            #expect(devices.count == 2 && devices[0] != devices[1])
            let rows = try await DeviceSession.query(on: app.db).filter(\.$userID == userID).all()
            #expect(rows.count == 2)
            for row in rows {
                #expect(!devices.contains(row.tokenHash))
                // No activity timestamp or expiry is consulted during authentication.
                row.createdAt = Date(timeIntervalSince1970: 0)
                try await row.save(on: app.db)
            }
            for token in devices {
                let headers: HTTPHeaders = ["Authorization": "Bearer \(token)"]
                for path in ["auth/me", "nests"] {
                    try await app.testing().test(.GET, path, headers: headers) { res async in
                        #expect(res.status == .ok)
                    }
                }
                try await app.testing().test(.POST, "auth/session", headers: headers) { res async throws in
                    #expect(try res.content.decode(TokenResponse.self).token == token)
                }
            }
            try await app.testing().test(.DELETE, "auth/session", headers: ["Authorization": "Bearer \(devices[0])"]) { res async in
                #expect(res.status == .noContent)
            }
            try await app.testing().test(.GET, "auth/me", headers: ["Authorization": "Bearer \(devices[0])"]) { res async in
                #expect(res.status == .unauthorized)
            }
            try await app.testing().test(.GET, "auth/me", headers: ["Authorization": "Bearer \(devices[1])"]) { res async in
                #expect(res.status == .ok)
            }
            let resetValue = authTokenValue()
            let reset = AuthToken(userID: userID, kind: .passwordReset,
                                  tokenHash: authTokenHash(resetValue), expiresAt: Date().addingTimeInterval(3600))
            try await reset.save(on: app.db)
            try await app.testing().test(.POST, "auth/reset-password", beforeRequest: { req async throws in
                try req.content.encode(ResetPasswordRequest(token: resetValue, password: "Changed-password-123!"))
            }, afterResponse: { res async in
                #expect(res.status == .ok)
            })
            try await app.testing().test(.GET, "auth/me", headers: ["Authorization": "Bearer \(devices[1])"]) { res async in
                #expect(res.status == .unauthorized)
            }
            try await reset.delete(on: app.db)
            // Cascade removal also covers accounts deleted outside the app endpoint.
            let extra = DeviceSession(userID: userID, token: "nestic_device_" + authTokenValue())
            try await extra.save(on: app.db)
            try await user.delete(on: app.db)
            #expect(try await DeviceSession.query(on: app.db).filter(\.$userID == userID).count() == 0)
            try await app.testing().test(.GET, "auth/me", headers: ["Authorization": "Bearer \(devices[1])"]) { res async in
                #expect(res.status == .unauthorized)
            }
            try await app.asyncShutdown()
        } catch {
            if user.id != nil { try? await user.delete(on: app.db) }
            try await app.asyncShutdown()
            throw error
        }
    }
}
