@testable import NesticServer
import VaporTesting
import Testing
import Fluent

private struct BooleanEventRequest: Content {
    let actionID: String
    let valueBool: Bool
    let note: String
}

@Suite("API boundaries", .serialized)
struct NesticServerTests {
    private func withApp(_ test: (Application) async throws -> Void) async throws {
        let app = try await Application.make(.testing)
        do {
            try await configure(app)
            try await test(app)
            try await app.asyncShutdown()
        } catch {
            try await app.asyncShutdown()
            throw error
        }
    }

    @Test("Health is available without a database connection")
    func health() async throws {
        try await withApp { app in
            try await app.testing().test(.GET, "health") { response async in
                #expect(response.status == .ok)
                #expect(response.body.string.contains("ok"))
            }
        }
    }

    @Test("Nest data requires authentication")
    func unauthenticated() async throws {
        try await withApp { app in
            let nestID = UUID()
            for route in ["auth/me", "nests", "nests/\(nestID)/events", "nests/\(nestID)/members"] {
                try await app.testing().test(.GET, route) { response async in
                    #expect(response.status == .unauthorized)
                }
            }
            try await app.testing().test(.GET, "nests", headers: ["Authorization": "Bearer invalid"]) { response async in
                #expect(response.status == .unauthorized)
            }
        }
    }

    @Test("Registration rejects malformed inputs before database access")
    func invalidRegistration() async throws {
        try await withApp { app in
            try await app.testing().test(.POST, "auth/register", beforeRequest: { request async throws in
                try request.content.encode(RegisterRequest(email: "invalid", password: "short", displayName: " ", imageURL: nil))
            }, afterResponse: { response async in
                #expect(response.status == .badRequest)
            })
        }
    }

    @Test("Names, emails, and bcrypt password boundaries")
    func identityValidation() throws {
        #expect(try InputValidation.name("  Our nest \n") == "Our nest")
        #expect(try InputValidation.email(" PERSON@Example.com ") == "person@example.com")
        #expect(throws: (any Error).self) { try InputValidation.email("a@@example.com") }
        #expect(throws: (any Error).self) { try InputValidation.name(" \n ") }
        #expect(throws: (any Error).self) { try InputValidation.password(String(repeating: "🐶", count: 19)) }
        try InputValidation.password("test-password")
    }

    @Test("Event payload must match its tracker and preserve boolean false")
    func typedEvents() throws {
        try InputValidation.event(type: .none, number: nil, text: nil, boolean: nil, json: nil, note: "Pee outside")
        try InputValidation.event(type: .number, number: 0, text: nil, boolean: nil, json: nil, note: nil)
        try InputValidation.event(type: .boolean, number: nil, text: nil, boolean: false, json: nil, note: nil)
        try InputValidation.event(type: .text, number: nil, text: "Normal", boolean: nil, json: nil, note: nil)
        try InputValidation.event(type: .json, number: nil, text: nil, boolean: nil, json: ["detail": "Normal"], note: nil)
        #expect(throws: (any Error).self) { try InputValidation.event(type: .number, number: nil, text: "3", boolean: nil, json: nil, note: nil) }
        #expect(throws: (any Error).self) { try InputValidation.event(type: .none, number: nil, text: nil, boolean: true, json: nil, note: nil) }
        #expect(throws: (any Error).self) { try InputValidation.event(type: .number, number: .infinity, text: nil, boolean: nil, json: nil, note: nil) }
        #expect(throws: (any Error).self) { try InputValidation.event(type: .text, number: nil, text: " ", boolean: nil, json: nil, note: nil) }
    }

    @Test("Public profile never serializes a password hash")
    func publicProfile() throws {
        let user = User(email: "person@example.com", passwordHash: "private-hash", displayName: "Alex")
        user.id = UUID()
        let data = try JSONEncoder().encode(UserResponse(user))
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains("displayName"))
        #expect(!json.contains("private-hash"))
        #expect(!json.contains("password"))
    }
}

@Suite("Postgres integration", .serialized, .enabled(if: Environment.get("RUN_DATABASE_TESTS") == "true"))
struct PostgresIntegrationTests {
    @Test("Shared nest logging, cross-nest isolation, viewer permissions, and deletion")
    func sharedNest() async throws {
        // This suite creates isolated test users and cleans up ONLY their rows. It never reverts migrations.
        let app = try await Application.make(.testing)
        var userIDs: [UUID] = []
        do {
            try await configure(app)
            try await app.autoMigrate()
            let api = try app.testing()
            let suffix = UUID().uuidString.lowercased()
            var tokens: [String] = []
            for name in ["owner", "member", "outsider"] {
                let response = try await api.sendRequest(.POST, "auth/register", beforeRequest: { req async throws in
                    try req.content.encode(RegisterRequest(email: "\(name)-\(suffix)@example.com", password: "test-password", displayName: name, imageURL: nil))
                })
                #expect(response.status == .ok)
                let token = try #require(response.content.decode(RegisterResponse.self).token)
                tokens.append(token)
                let profile = try await api.sendRequest(.GET, "auth/me", headers: ["Authorization": "Bearer \(token)"])
                #expect(!profile.body.string.contains("password"))
                userIDs.append(try profile.content.decode(UserResponse.self).id)
            }
            let owner: HTTPHeaders = ["Authorization": "Bearer \(tokens[0])"]
            let member: HTTPHeaders = ["Authorization": "Bearer \(tokens[1])"]
            let outsider: HTTPHeaders = ["Authorization": "Bearer \(tokens[2])"]
            let nestResponse = try await api.sendRequest(.POST, "nests", headers: owner, beforeRequest: { req async throws in
                try req.content.encode(["name": "Integration nest"])
            })
            let nest = try nestResponse.content.decode(NestResponse.self)
            let entityResponse = try await api.sendRequest(.POST, "nests/\(nest.id)/entities", headers: owner, beforeRequest: { req async throws in
                try req.content.encode(["name": "Milo", "kind": "pet"])
            })
            let entity = try entityResponse.content.decode(EntityResponse.self)
            let actionResponse = try await api.sendRequest(.POST, "nests/\(nest.id)/actions", headers: owner, beforeRequest: { req async throws in
                try req.content.encode(["name": "Bathroom", "valueType": "none"])
            })
            let action = try actionResponse.content.decode(TrackableActionResponse.self)
            let editedAction = try await api.sendRequest(.PATCH, "actions/\(action.id)", headers: owner, beforeRequest: { req async throws in
                try req.content.encode(["name": "Bathroom break", "valueType": "boolean"])
            })
            #expect(editedAction.status == .ok)
            #expect(try editedAction.content.decode(TrackableActionResponse.self).name == "Bathroom break")
            let added = try await api.sendRequest(.POST, "nests/\(nest.id)/members", headers: owner, beforeRequest: { req async throws in
                try req.content.encode(["email": "member-\(suffix)@example.com", "role": "viewer"])
            })
            #expect(added.status == .ok)
            let blocked = try await api.sendRequest(.POST, "entities/\(entity.id)/events", headers: member, beforeRequest: { req async throws in
                try req.content.encode(["actionID": action.id.uuidString])
            })
            #expect(blocked.status == .forbidden)
            let changed = try await api.sendRequest(.PATCH, "nests/\(nest.id)/members/\(userIDs[1])", headers: owner, beforeRequest: { req async throws in
                try req.content.encode(["role": "member"])
            })
            #expect(changed.status == .ok)
            let created = try await api.sendRequest(.POST, "entities/\(entity.id)/events", headers: member, beforeRequest: { req async throws in
                try req.content.encode(BooleanEventRequest(actionID: action.id.uuidString, valueBool: false, note: "Outside"))
            })
            let event = try created.content.decode(ActionEventResponse.self)
            #expect(event.actorUserId == userIDs[1])
            let feed = try await api.sendRequest(.GET, "nests/\(nest.id)/events?limit=200", headers: owner)
            #expect(try feed.content.decode([ActionEventResponse].self).count == 1)
            let denied = try await api.sendRequest(.GET, "nests/\(nest.id)/events", headers: outsider)
            #expect(denied.status == .forbidden)
            let deleted = try await api.sendRequest(.DELETE, "events/\(event.id)", headers: member)
            #expect(deleted.status == HTTPStatus.noContent)
            let empty = try await api.sendRequest(.GET, "nests/\(nest.id)/events", headers: owner)
            #expect(try empty.content.decode([ActionEventResponse].self).isEmpty)
            let deletedAction = try await api.sendRequest(.DELETE, "actions/\(action.id)", headers: owner)
            #expect(deletedAction.status == HTTPStatus.noContent)
            let actionsAfterDelete = try await api.sendRequest(.GET, "nests/\(nest.id)/actions", headers: owner)
            #expect(try actionsAfterDelete.content.decode([TrackableActionResponse].self).isEmpty)
            try await Nest.find(nest.id, on: app.db)?.delete(on: app.db)
            for id in userIDs { try await User.find(id, on: app.db)?.delete(on: app.db) }
            try await app.asyncShutdown()
        } catch {
            for id in userIDs { try? await User.find(id, on: app.db)?.delete(on: app.db) }
            try await app.asyncShutdown()
            throw error
        }
    }
}
