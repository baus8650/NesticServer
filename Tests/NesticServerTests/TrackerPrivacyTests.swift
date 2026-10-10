@testable import NesticServer
import Testing
import VaporTesting
import Fluent

@Suite("Private tracker serialization")
struct TrackerPrivacyTests {
    @Test("Nested lists, pins, preferences, and realtime payloads hide private resources")
    func filtering() throws {
        let hidden = UUID(), shared = UUID()
        let payload: [String: Any] = ["pins": [hidden.uuidString, shared.uuidString], "actions": [["id": hidden.uuidString, "name": "Secret"], ["id": shared.uuidString, "name": "Water"]], "prefs": [hidden.uuidString: ["name": "Secret"]]]
        let clean = try #require(TrackerPrivacyPolicy.filtered(payload, hidden: [hidden]) as? [String: Any])
        let text = String(decoding: try JSONSerialization.data(withJSONObject: clean), as: UTF8.self)
        #expect(!text.contains("Secret"))
        #expect(!text.contains(hidden.uuidString))
        #expect(text.contains("Water"))
        #expect(TrackerPrivacyPolicy.filtered(["type": "event.created", "data": ["actionId": hidden.uuidString, "note": "Secret"]], hidden: [hidden]) == nil)
        #expect(TrackerPrivacyPolicy.referencedIDs("{\"\(hidden)\":true}").contains(hidden))
    }
    @Test("Only the tracker owner can see dependent events and reminders")
    func ownerBoundary() {
        let owner = UUID(), other = UUID(), tracker = UUID(), event = UUID(), reminder = UUID()
        let policy = TrackerPrivacyPolicy(owners: [tracker: owner, event: owner, reminder: owner], trackerOwners: [tracker: owner])
        #expect(policy.hidden(for: owner).isEmpty)
        #expect(policy.hidden(for: other) == [tracker, event, reminder])
        #expect(policy.hidden(for: nil) == [tracker, event, reminder])
    }
}

private struct PrivateTrackerInput: Content { let name: String; let valueType: String; let isPrivate: Bool }
private struct PrivateRoutineInput: Content { let name: String; let targets: [RoutineTarget] }
private struct PrivateReferenceInput: Content { let trackerID: UUID }
private struct PrivateEventInput: Content { let actionID: UUID; let note: String }

@Suite("Private trackers with Postgres", .serialized, .enabled(if: Environment.get("RUN_DATABASE_TESTS") == "true"))
struct PrivateTrackerDatabaseTests {
    @Test("Creation, cross-device reads, admin isolation, pins, history, photos, reminders, and shared boundaries")
    func privacy() async throws {
        let app = try await Application.make(.testing)
        do {
            try await configure(app)
            try await app.autoMigrate()
            let suffix = UUID().uuidString
            let owner = User(email: "private-\(suffix)@example.com", passwordHash: "unused", displayName: "Private owner", emailVerified: true)
            let admin = User(email: "admin-private-\(suffix)@example.com", passwordHash: "unused", displayName: "Nest admin", emailVerified: true)
            try await owner.save(on: app.db); try await admin.save(on: app.db)
            let ownerID = try owner.requireID(), adminID = try admin.requireID()
            let nest = Nest(name: "Private integration \(suffix)"); try await nest.save(on: app.db)
            let nestID = try nest.requireID()
            try await NestMember(nestID: nestID, userID: ownerID, role: .member).save(on: app.db)
            try await NestMember(nestID: nestID, userID: adminID, role: .owner).save(on: app.db)
            let subject = Entity(nestID: nestID, kind: .person, name: "Person"); try await subject.save(on: app.db)
            let subjectID = try subject.requireID()
            let ownToken = try await app.jwt.keys.sign(SessionToken(userId: ownerID))
            let adminToken = try await app.jwt.keys.sign(SessionToken(userId: adminID))
            let own: HTTPHeaders = ["Authorization": "Bearer \(ownToken)"]
            let other: HTTPHeaders = ["Authorization": "Bearer \(adminToken)"]
            let api = try app.testing()
            let created = try await api.sendRequest(.POST, "nests/\(nestID)/actions", headers: own, beforeRequest: { req async throws in
                try req.content.encode(PrivateTrackerInput(name: "Secret tracker", valueType: "none", isPrivate: true))
            })
            #expect(created.status == .ok)
            let tracker = try created.content.decode(TrackableActionResponse.self)
            #expect(tracker.privateOwnerId == ownerID)
            let deniedShared = try await api.sendRequest(.POST, "nests/\(nestID)/actions", headers: own, beforeRequest: { req async throws in
                try req.content.encode(PrivateTrackerInput(name: "Shared tracker", valueType: "none", isPrivate: false))
            })
            #expect(deniedShared.status == .forbidden)
            let pin = try await api.sendRequest(.PUT, "entities/\(subjectID)/pinned-actions", headers: own, beforeRequest: { req async throws in try req.content.encode(SetPinnedActionsRequest(actionIds: [tracker.id])) })
            #expect(pin.status == .noContent)
            let eventResponse = try await api.sendRequest(.POST, "entities/\(subjectID)/events", headers: own, beforeRequest: { req async throws in try req.content.encode(PrivateEventInput(actionID: tracker.id, note: "Secret note")) })
            #expect(eventResponse.status == .ok)
            let event = try eventResponse.content.decode(ActionEventResponse.self)
            let routineInput = PrivateRoutineInput(name: "Secret routine", targets: [RoutineTarget(entityID: subjectID, items: [RoutineItem(trackerID: tracker.id, valueNumber: nil, valueText: nil, valueBool: nil, valueJSON: nil)])])
            let routineResponse = try await api.sendRequest(.POST, "nests/\(nestID)/routines", headers: own, beforeRequest: { req async throws in try req.content.encode(routineInput) })
            #expect(routineResponse.status == .ok)
            let routine = try routineResponse.content.decode(RoutineResponse.self)
            #expect(routine.privateOwnerId == ownerID)
            let hiddenRoutines = try await api.sendRequest(.GET, "nests/\(nestID)/routines", headers: other)
            #expect(!hiddenRoutines.body.string.contains("Secret routine"))
            for method in [HTTPMethod.POST, .PATCH, .DELETE] {
                let path = "routines/\(routine.id)" + (method == .POST ? "/log" : "")
                let blocked = try await api.sendRequest(method, path, headers: other)
                #expect(blocked.status == .notFound)
            }
            let logged = try await api.sendRequest(.POST, "routines/\(routine.id)/log", headers: own, beforeRequest: { req async throws in try req.content.encode([String: String]()) })
            #expect(logged.status == .ok)
            let forecastInput = UpsertNestForecastRequest(subjectId: subjectID, trackerId: tracker.id, predictedAt: Date().addingTimeInterval(3600), baselinePredictedAt: Date().addingTimeInterval(3600), contextualPredictedAt: nil, model: "baseline", intervalHours: 1, confidence: 0.8, sampleCount: 2, validationSampleCount: 0, expectedErrorHours: nil, predictionWindowHours: 1, targetNames: ["Secret tracker"], inputNames: [], lastEventAt: event.occurredAt, computedAt: Date())
            let forecastResponse = try await api.sendRequest(.PUT, "nests/\(nestID)/forecasts", headers: own, beforeRequest: { req async throws in try req.content.encode([forecastInput]) })
            #expect(forecastResponse.status == .ok)
            let ownForecasts = try await api.sendRequest(.GET, "nests/\(nestID)/forecasts", headers: own)
            #expect(try ownForecasts.content.decode([NestForecastResponse].self).contains { $0.trackerId == tracker.id })
            let hiddenForecasts = try await api.sendRequest(.GET, "nests/\(nestID)/forecasts", headers: other)
            #expect(!hiddenForecasts.body.string.contains("Secret"))
            let overwriteForecast = try await api.sendRequest(.PUT, "nests/\(nestID)/forecasts", headers: other, beforeRequest: { req async throws in try req.content.encode([forecastInput]) })
            #expect(overwriteForecast.status == .notFound)
            let reminder = NestReminder(nestID: nestID, subjectID: subjectID, subjectName: "Person", trackerID: tracker.id, trackerName: "Secret tracker", cadence: .monthly, linkedTrackerID: nil, linkedTrackerName: nil, delayMinutes: 30, anchorDate: Date(), hour: 9, minute: 0, createdByUserID: ownerID, createdByName: "Private owner")
            try await reminder.save(on: app.db)
            for path in ["nests/\(nestID)/actions", "nests/\(nestID)/events", "entities/\(subjectID)/events", "nests/\(nestID)/entities/summary", "nests/\(nestID)/reminders"] {
                let visible = try await api.sendRequest(.GET, path, headers: own)
                #expect(visible.status == .ok)
                #expect(visible.body.string.contains(tracker.id.uuidString.lowercased()) || visible.body.string.contains(tracker.id.uuidString))
                let hidden = try await api.sendRequest(.GET, path, headers: other)
                #expect(hidden.status == .ok)
                #expect(!hidden.body.string.contains("Secret"))
                #expect(!hidden.body.string.lowercased().contains(tracker.id.uuidString.lowercased()))
            }
            for path in ["actions/\(tracker.id)", "events/\(event.id)", "events/\(event.id)/photo", "nests/\(nestID)/reminders/\(try reminder.requireID())"] {
                let denied = try await api.sendRequest(.DELETE, path, headers: other)
                #expect(denied.status == .notFound)
            }
            for path in ["nests/\(nestID)/routines", "nests/\(nestID)/care-links", "nests/\(nestID)/forecasts"] {
                let denied = try await api.sendRequest(path.hasSuffix("forecasts") ? .PUT : .POST, path, headers: own, beforeRequest: { req async throws in try req.content.encode(PrivateReferenceInput(trackerID: tracker.id)) })
                #expect(denied.status == .badRequest)
            }
            // Another member replacing their visible pins cannot remove this private pin.
            _ = try await api.sendRequest(.PUT, "entities/\(subjectID)/pinned-actions", headers: other, beforeRequest: { req async throws in try req.content.encode(SetPinnedActionsRequest(actionIds: [])) })
            #expect(try await EntityPinnedAction.query(on: app.db).filter(\.$entity.$id == subjectID).filter(\.$action.$id == tracker.id).count() == 1)
            let sameNameShared = try await api.sendRequest(.POST, "nests/\(nestID)/actions", headers: other, beforeRequest: { req async throws in try req.content.encode(PrivateTrackerInput(name: "Secret tracker", valueType: "none", isPrivate: false)) })
            #expect(sameNameShared.status == .ok)
            let sameNamePrivate = try await api.sendRequest(.POST, "nests/\(nestID)/actions", headers: other, beforeRequest: { req async throws in try req.content.encode(PrivateTrackerInput(name: "Secret tracker", valueType: "none", isPrivate: true)) })
            #expect(sameNamePrivate.status == .ok)
            let sharedTracker = try sameNameShared.content.decode(TrackableActionResponse.self)
            _ = try await api.sendRequest(.PUT, "entities/\(subjectID)/pinned-actions", headers: own, beforeRequest: { req async throws in try req.content.encode(SetPinnedActionsRequest(actionIds: [tracker.id, sharedTracker.id])) })
            let editedRoutine = try await api.sendRequest(.PATCH, "routines/\(routine.id)", headers: own, beforeRequest: { req async throws in try req.content.encode(PrivateRoutineInput(name: "Still secret", targets: [RoutineTarget(entityID: subjectID, items: [RoutineItem(trackerID: sharedTracker.id, valueNumber: nil, valueText: nil, valueBool: nil, valueJSON: nil)])])) })
            #expect(editedRoutine.status == .ok)
            #expect(try editedRoutine.content.decode(RoutineResponse.self).privateOwnerId == ownerID)
            let stillHidden = try await api.sendRequest(.GET, "nests/\(nestID)/routines", headers: other)
            #expect(!stillHidden.body.string.contains("Still secret"))

            let sharedEvent = ActionEvent(nestID: nestID, entityID: subjectID, actionID: sharedTracker.id, actorUserID: adminID, occurredAt: Date().addingTimeInterval(-60), note: "Shared note")
            try await sharedEvent.save(on: app.db)
            let page = try await api.sendRequest(.GET, "nests/\(nestID)/events?limit=1", headers: other)
            let pageEntries = try page.content.decode([ActionEventResponse].self)
            #expect(pageEntries.count == 1)
            #expect(pageEntries.first?.actionId == sharedTracker.id)
            let unauthorizedLog = try await api.sendRequest(.POST, "entities/\(subjectID)/events", headers: other, beforeRequest: { req async throws in try req.content.encode(PrivateEventInput(actionID: tracker.id, note: "Attempt")) })
            #expect(unauthorizedLog.status == .notFound)
            let secondDeviceToken = try await app.jwt.keys.sign(SessionToken(userId: ownerID))
            let synced = try await api.sendRequest(.GET, "nests/\(nestID)/actions", headers: ["Authorization": "Bearer \(secondDeviceToken)"])
            #expect(try synced.content.decode([TrackableActionResponse].self).contains { $0.id == tracker.id && $0.privateOwnerId == ownerID })
            try await reminder.delete(on: app.db)
            try await nest.delete(on: app.db)
            try await owner.delete(on: app.db); try await admin.delete(on: app.db)
            try await app.asyncShutdown()
        } catch { try await app.asyncShutdown(); throw error }
    }
}
