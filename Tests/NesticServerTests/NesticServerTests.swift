@testable import NesticServer
import VaporTesting
import Testing
import Fluent

private struct BooleanEventRequest: Content {
    let actionID: String
    let valueBool: Bool
    let note: String
}

private struct RoutineRequest: Content {
    let entityID: UUID
    let name: String
    let items: [RoutineItem]
}

private struct UserSettingsRequest: Content {
    let predictionPreferencesJSON: String?
    let quietHoursJSON: String?
    let remindersJSON: String?
}

private struct SharedReminderRequest: Content {
    let subjectID: UUID
    let trackerID: UUID
    let cadence: NestReminderCadence
    let linkedTrackerID: UUID?
    let delayMinutes: Int
    let anchorDate: Date
    let hour: Int
    let minute: Int
}

private struct ReminderNotificationRequest: Content {
    let enabled: Bool
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
            for route in ["auth/me", "nests", "nests/\(nestID)/events", "nests/\(nestID)/members", "nests/\(nestID)/settings"] {
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

    @Test("Signup requires explicit acceptance of the published terms version")
    func termsAcceptanceRequired() async throws {
        try NesticTerms.requireAcceptance(NesticTerms.currentVersion)
        #expect(throws: (any Error).self) { try NesticTerms.requireAcceptance(nil) }
        #expect(throws: (any Error).self) { try NesticTerms.requireAcceptance("outdated") }
        try await withApp { app in
            for version in [nil, "outdated"] as [String?] {
                try await app.testing().test(.POST, "auth/register", beforeRequest: { request async throws in
                    try request.content.encode(RegisterRequest(email: "consent@example.com", password: "test-password", displayName: "Alex", imageURL: nil, acceptedTermsVersion: version))
                }, afterResponse: { response async in
                    #expect(response.status == .preconditionRequired)
                })
            }
        }
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

    @Test("Routine items encode as one JSON document")
    func routineItemsUseJSONDocument() throws {
        let items = [RoutineItem(trackerID: UUID(), valueNumber: 1.5, valueText: nil,
                                 valueBool: nil, valueJSON: nil)]
        let encoded = try JSONEncoder().encode(RoutineItems(items))
        let json = try JSONSerialization.jsonObject(with: encoded)
        #expect(json as? [String: Any] != nil)
        #expect(try JSONDecoder().decode(RoutineItems.self, from: encoded).values == items)

        let legacyArray = try JSONEncoder().encode(items)
        #expect(try JSONDecoder().decode(RoutineItems.self, from: legacyArray).values == items)

        let namedDocument = try JSONEncoder().encode(["items": items])
        #expect(try JSONDecoder().decode(RoutineItems.self, from: namedDocument).values == items)

        let singleItemDocument = try JSONEncoder().encode(["values": items[0]])
        #expect(try JSONDecoder().decode(RoutineItems.self, from: singleItemDocument).values == items)

        let singleItem = try JSONEncoder().encode(items[0])
        #expect(try JSONDecoder().decode(RoutineItems.self, from: singleItem).values == items)
    }

    @Test("Routine targets preserve multiple entities in one JSON document")
    func routineTargetsUseJSONDocument() throws {
        let first = RoutineTarget(entityID: UUID(), items: [
            RoutineItem(trackerID: UUID(), valueNumber: 2, valueText: nil, valueBool: nil, valueJSON: nil)
        ])
        let second = RoutineTarget(entityID: UUID(), items: [
            RoutineItem(trackerID: UUID(), valueNumber: nil, valueText: nil, valueBool: true, valueJSON: nil)
        ])
        let encoded = try JSONEncoder().encode(RoutineTargets([first, second]))
        let json = try JSONSerialization.jsonObject(with: encoded)
        #expect(json as? [String: Any] != nil)
        #expect(try JSONDecoder().decode(RoutineTargets.self, from: encoded).values == [first, second])

        let legacyArray = try JSONEncoder().encode([first, second])
        #expect(try JSONDecoder().decode(RoutineTargets.self, from: legacyArray).values == [first, second])

        let namedDocument = try JSONEncoder().encode(["targets": [first, second]])
        #expect(try JSONDecoder().decode(RoutineTargets.self, from: namedDocument).values == [first, second])

        let singleTargetDocument = try JSONEncoder().encode(["values": first])
        #expect(try JSONDecoder().decode(RoutineTargets.self, from: singleTargetDocument).values == [first])

        let singleTarget = try JSONEncoder().encode(first)
        #expect(try JSONDecoder().decode(RoutineTargets.self, from: singleTarget).values == [first])
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

    @Test("An allowlisted email cannot grant admin access before verification")
    func verifiedAdminIdentity() {
        let user = User(email: "baus8650@gmail.com", passwordHash: "unused", displayName: "Admin")
        #expect(!isNesticAdmin(user))
        user.emailVerified = true
        #expect(isNesticAdmin(user))
        user.email = "someone-else@example.com"
        #expect(!isNesticAdmin(user))
    }
}

@Suite("Postgres integration", .serialized, .enabled(if: Environment.get("RUN_DATABASE_TESTS") == "true"))
struct PostgresIntegrationTests {
    @Test("Account deletion removes authored shared content and queues every attached photo")
    func accountDeletion() async throws {
        let app = try await Application.make(.testing)
        let suffix = UUID().uuidString
        let departing = User(email: "departing-\(suffix)@example.com", passwordHash: "unused", displayName: "Departing", emailVerified: true)
        let remaining = User(email: "remaining-\(suffix)@example.com", passwordHash: "unused", displayName: "Remaining", emailVerified: true)
        let nest = Nest(name: "Deletion regression")
        do {
            try await configure(app)
            try await app.autoMigrate()
            try await departing.save(on: app.db)
            try await remaining.save(on: app.db)
            try await nest.save(on: app.db)
            let userID = try departing.requireID()
            let nestID = try nest.requireID()
            try await NestMember(nestID: nestID, userID: userID, role: .owner).save(on: app.db)
            try await NestMember(nestID: nestID, userID: remaining.requireID(), role: .member).save(on: app.db)
            let entity = Entity(nestID: nestID, kind: .pet, name: "Test subject")
            let tracker = TrackableAction(nestID: nestID, name: "Health", valueType: .health)
            try await entity.save(on: app.db)
            try await tracker.save(on: app.db)
            let event = ActionEvent(nestID: nestID, entityID: try entity.requireID(), actionID: try tracker.requireID(),
                                    actorUserID: userID, occurredAt: Date(), valueText: "Recorded details", photoURL: "r2://\(suffix)/onset.jpg")
            let keptEvent = ActionEvent(nestID: nestID, entityID: try entity.requireID(), actionID: try tracker.requireID(),
                                        actorUserID: try remaining.requireID(), occurredAt: Date(), valueText: "Other member’s details")
            try await event.save(on: app.db)
            try await keptEvent.save(on: app.db)
            let progress = ActionEventPhoto(eventID: try keptEvent.requireID(), actorUserID: userID,
                                            capturedAt: Date(), photoURL: "r2://\(suffix)/progress.jpg", note: "Departing member’s note")
            try await progress.save(on: app.db)
            let feedback = FeedbackThread(userID: userID, subject: "Test", category: "question")
            try await feedback.save(on: app.db)
            let jwt = try await app.jwt.keys.sign(SessionToken(userId: userID))
            let response = try await app.testing().sendRequest(.DELETE, "auth/me", headers: ["Authorization": "Bearer \(jwt)"])
            #expect(response.status == .ok)
            #expect(try response.content.decode(AccountDeletionResponse.self).deleted)
            #expect(try await User.find(userID, on: app.db) == nil)
            #expect(try await ActionEvent.find(event.requireID(), on: app.db) == nil)
            #expect(try await ActionEventPhoto.find(progress.requireID(), on: app.db) == nil)
            #expect(try await FeedbackThread.find(feedback.requireID(), on: app.db) == nil)
            #expect(try await ActionEvent.find(keptEvent.requireID(), on: app.db) != nil)
            let owner = try await NestMember.query(on: app.db).filter(\.$nest.$id == nestID).first()
            #expect(owner?.role == .owner)
            #expect(owner?.$user.id == remaining.id)
            let jobs = try await PhotoDeletionJob.query(on: app.db).all()
            #expect(jobs.filter { $0.objectKey.hasPrefix(suffix) }.count == 2)
            for job in jobs where job.objectKey.hasPrefix(suffix) { try await job.delete(on: app.db) }
            try await keptEvent.delete(on: app.db)
            try await nest.delete(on: app.db)
            try await remaining.delete(on: app.db)
            try await app.asyncShutdown()
        } catch {
            try await app.asyncShutdown()
            throw error
        }
    }

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
            for name in ["owner", "member", "outsider", "coowner"] {
                let response = try await api.sendRequest(.POST, "auth/register", beforeRequest: { req async throws in
                    try req.content.encode(RegisterRequest(email: "\(name)-\(suffix)@example.com", password: "test-password", displayName: name, imageURL: nil, acceptedTermsVersion: NesticTerms.currentVersion))
                })
                #expect(response.status == .ok)
                let token = try #require(response.content.decode(RegisterResponse.self).token)
                tokens.append(token)
                let profile = try await api.sendRequest(.GET, "auth/me", headers: ["Authorization": "Bearer \(token)"])
                #expect(!profile.body.string.contains("password"))
                let registeredID = try profile.content.decode(UserResponse.self).id
                userIDs.append(registeredID)
                let registeredUser = try #require(try await User.find(registeredID, on: app.db))
                #expect(registeredUser.termsVersion == NesticTerms.currentVersion)
                #expect(registeredUser.termsAcceptedAt != nil)
            }
            let owner: HTTPHeaders = ["Authorization": "Bearer \(tokens[0])"]
            let member: HTTPHeaders = ["Authorization": "Bearer \(tokens[1])"]
            let outsider: HTTPHeaders = ["Authorization": "Bearer \(tokens[2])"]
            let supportResponse = try await api.sendRequest(.POST, "feedback", headers: owner, beforeRequest: { req async throws in
                try req.content.encode(CreateFeedbackRequest(subject: "Support request", category: "support", message: "Please help with my account."))
            })
            #expect(supportResponse.status == .ok)
            let supportThread = try supportResponse.content.decode(FeedbackThreadResponse.self)
            #expect(supportThread.category == "support")
            #expect(supportThread.messages.count == 1)
            let privateSupport = try await api.sendRequest(.GET, "feedback/\(supportThread.id)", headers: outsider)
            #expect(privateSupport.status == .forbidden)
            let supportReply = try await api.sendRequest(.POST, "feedback/\(supportThread.id)/messages", headers: owner, beforeRequest: { req async throws in
                try req.content.encode(FeedbackMessageRequest(message: "Additional details for support."))
            })
            #expect(try supportReply.content.decode(FeedbackThreadResponse.self).messages.count == 2)
            let coowner: HTTPHeaders = ["Authorization": "Bearer \(tokens[3])"]
            let nestResponse = try await api.sendRequest(.POST, "nests", headers: owner, beforeRequest: { req async throws in
                try req.content.encode(["name": "Integration nest"])
            })
            let nest = try nestResponse.content.decode(NestResponse.self)
            let savedSettings = try await api.sendRequest(.PUT, "nests/\(nest.id)/settings", headers: owner, beforeRequest: { req async throws in
                try req.content.encode(UserSettingsRequest(
                    predictionPreferencesJSON: "{\"subject\":\"prefs\"}",
                    quietHoursJSON: "{\"periods\":[]}",
                    remindersJSON: "[]"
                ))
            })
            #expect(savedSettings.status == .ok)
            let loadedSettings = try await api.sendRequest(.GET, "nests/\(nest.id)/settings", headers: owner)
            let settings = try loadedSettings.content.decode(NestUserSettingsResponse.self)
            #expect(settings.predictionPreferencesJSON == "{\"subject\":\"prefs\"}")
            #expect(settings.quietHoursJSON == "{\"periods\":[]}")
            #expect(settings.remindersJSON == "[]")
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
            let pinned = try await api.sendRequest(.PUT, "entities/\(entity.id)/pinned-actions", headers: owner, beforeRequest: { req async throws in
                try req.content.encode(SetPinnedActionsRequest(actionIds: [action.id]))
            })
            #expect(pinned.status == .noContent)
            let routine = try await api.sendRequest(.POST, "nests/\(nest.id)/routines", headers: owner, beforeRequest: { req async throws in
                try req.content.encode(RoutineRequest(
                    entityID: entity.id,
                    name: "Morning care",
                    items: [RoutineItem(trackerID: action.id, valueNumber: nil, valueText: nil, valueBool: false, valueJSON: nil)]
                ))
            })
            #expect(routine.status == .ok)
            let routineResponse = try routine.content.decode(RoutineResponse.self)
            #expect(routineResponse.items.count == 1)
            #expect(routineResponse.targets.count == 1)
            let loggedRoutine = try await api.sendRequest(.POST, "routines/\(routineResponse.id)/log", headers: owner, beforeRequest: { req async throws in
                try req.content.encode(["note": "Routine test"])
            })
            #expect(loggedRoutine.status == .ok)
            let loggedEvents = try loggedRoutine.content.decode([ActionEventResponse].self)
            #expect(loggedEvents.count == 1)
            #expect(loggedEvents[0].photoUpdates.isEmpty)
            let addedOwner = try await api.sendRequest(.POST, "nests/\(nest.id)/members", headers: owner, beforeRequest: { req async throws in
                try req.content.encode(["email": "coowner-\(suffix)@example.com", "role": "owner"])
            })
            #expect(addedOwner.status == .ok)
            #expect(try addedOwner.content.decode(MemberResponse.self).role == .owner)
            let ownerCanManage = try await api.sendRequest(.PATCH, "actions/\(action.id)", headers: coowner, beforeRequest: { req async throws in
                try req.content.encode(["name": "Bathroom break", "valueType": "boolean"])
            })
            #expect(ownerCanManage.status == .ok)
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
            let reminderResponse = try await api.sendRequest(.POST, "nests/\(nest.id)/reminders", headers: owner, beforeRequest: { req async throws in
                try req.content.encode(SharedReminderRequest(
                    subjectID: entity.id, trackerID: action.id, cadence: .everyOtherDay,
                    linkedTrackerID: nil, delayMinutes: 0, anchorDate: Date(), hour: 9, minute: 0
                ))
            })
            #expect(reminderResponse.status == .ok)
            let sharedReminder = try reminderResponse.content.decode(NestReminderResponse.self)
            #expect(sharedReminder.notificationsEnabled)
            let memberReminders = try await api.sendRequest(.GET, "nests/\(nest.id)/reminders", headers: member)
            let memberSchedules = try memberReminders.content.decode([NestReminderResponse].self)
            #expect(memberSchedules.contains { $0.id == sharedReminder.id && $0.notificationsEnabled })
            let muted = try await api.sendRequest(.PUT, "nests/\(nest.id)/reminders/\(sharedReminder.id)/notification", headers: member, beforeRequest: { req async throws in
                try req.content.encode(ReminderNotificationRequest(enabled: false))
            })
            #expect(muted.status == .ok)
            let mutedReminder = try muted.content.decode(NestReminderResponse.self)
            #expect(!mutedReminder.notificationsEnabled)
            let ownerReminders = try await api.sendRequest(.GET, "nests/\(nest.id)/reminders", headers: owner)
            let ownerSchedules = try ownerReminders.content.decode([NestReminderResponse].self)
            #expect(ownerSchedules.contains {
                $0.id == sharedReminder.id && $0.notificationsEnabled
            })
            let created = try await api.sendRequest(.POST, "entities/\(entity.id)/events", headers: member, beforeRequest: { req async throws in
                try req.content.encode(BooleanEventRequest(actionID: action.id.uuidString, valueBool: false, note: "Outside"))
            })
            let event = try created.content.decode(ActionEventResponse.self)
            #expect(event.actorUserId == userIDs[1])
            let feed = try await api.sendRequest(.GET, "nests/\(nest.id)/events?limit=200", headers: owner)
            let feedEvents = try feed.content.decode([ActionEventResponse].self)
            #expect(feedEvents.count == loggedEvents.count + 1)
            #expect(feedEvents.contains { $0.id == event.id })
            let denied = try await api.sendRequest(.GET, "nests/\(nest.id)/events", headers: outsider)
            #expect(denied.status == .forbidden)
            let deleted = try await api.sendRequest(.DELETE, "events/\(event.id)", headers: member)
            #expect(deleted.status == HTTPStatus.noContent)
            let empty = try await api.sendRequest(.GET, "nests/\(nest.id)/events", headers: owner)
            let remainingEvents = try empty.content.decode([ActionEventResponse].self)
            #expect(Set(remainingEvents.map(\.id)) == Set(loggedEvents.map(\.id)))
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
