@testable import NesticServer
import Testing
import VaporTesting
import Fluent

private struct SharingInput: Content { let allowedMemberIDs: [UUID] }
private struct SharingLog: Content { let actionID: UUID; let valueNumber: Double; var occurredAt: Date? = nil }
private struct SharingRoutine: Content { let name: String; let targets: [RoutineTarget] }

@Suite("Selected tracker readers", .serialized, .enabled(if: Environment.get("RUN_DATABASE_TESTS") == "true"))
struct TrackerSharingTests {
    @Test("Grant, log, creator-only management, dependency visibility and revocation")
    func sharing() async throws {
        let app = try await Application.make(.testing)
        do {
            try await configure(app); try await app.autoMigrate()
            let suffix = UUID().uuidString
            let creator = User(email: "sharing-owner-\(suffix)@example.com", passwordHash: "unused", displayName: "Creator", emailVerified: true)
            let recipient = User(email: "sharing-reader-\(suffix)@example.com", passwordHash: "unused", displayName: "Recipient", emailVerified: true)
            let excluded = User(email: "sharing-hidden-\(suffix)@example.com", passwordHash: "unused", displayName: "Excluded", emailVerified: true)
            for user in [creator,recipient,excluded] { try await user.save(on: app.db) }
            let creatorID = try creator.requireID(), readerID = try recipient.requireID(), excludedID = try excluded.requireID()
            let nest = Nest(name: "Sharing test"); try await nest.save(on: app.db)
            let nestID = try nest.requireID()
            for (id,role) in [(creatorID, NestRole.owner),(readerID, .admin),(excludedID, .member)] {
                try await NestMember(nestID: nestID, userID: id, role: role).save(on: app.db)
            }
            let subject = Entity(nestID: nestID, kind: .person, name: "Person"); try await subject.save(on: app.db)
            let subjectID = try subject.requireID()
            let tracker = TrackableAction(nestID: nestID, name: "Selected pills", valueType: .number)
            tracker.privateOwnerId = creatorID; try await tracker.save(on: app.db)
            let trackerID = try tracker.requireID()
            try await EntityPinnedAction(entityID: subjectID, actionID: trackerID, sortOrder: 0).save(on: app.db)
            let dose = ActionEvent(nestID: nestID, entityID: subjectID, actionID: trackerID, actorUserID: creatorID, occurredAt: Date().addingTimeInterval(-3600), valueNumber: 1)
            try await dose.save(on: app.db)
            let reminder = NestReminder(nestID: nestID, subjectID: subjectID, subjectName: "Person", trackerID: trackerID, trackerName: tracker.name, cadence: .everyOtherDay, linkedTrackerID: nil, linkedTrackerName: nil, delayMinutes: 0, anchorDate: Date(), hour: 9, minute: 0, createdByUserID: creatorID, createdByName: "Creator")
            try await reminder.save(on: app.db)
            let creatorToken = try await app.jwt.keys.sign(SessionToken(userId: creatorID))
            let readerToken = try await app.jwt.keys.sign(SessionToken(userId: readerID))
            let excludedToken = try await app.jwt.keys.sign(SessionToken(userId: excludedID))
            let own: HTTPHeaders = ["Authorization": "Bearer \(creatorToken)"]
            let reader: HTTPHeaders = ["Authorization": "Bearer \(readerToken)"]
            let hidden: HTTPHeaders = ["Authorization": "Bearer \(excludedToken)"]
            let api = try app.testing()
            let granted = try await api.sendRequest(.PUT, "actions/\(trackerID)/sharing", headers: own, beforeRequest: { req async throws in try req.content.encode(SharingInput(allowedMemberIDs: [readerID])) })
            #expect(granted.status == .ok)
            #expect(try granted.content.decode(TrackableActionResponse.self).allowedMemberIDs == [readerID])
            let visible = try await api.sendRequest(.GET, "nests/\(nestID)/actions", headers: reader)
            #expect(try visible.content.decode([TrackableActionResponse].self).contains { $0.id == trackerID })
            let history = try await api.sendRequest(.GET, "nests/\(nestID)/events", headers: reader)
            #expect(try history.content.decode([ActionEventResponse].self).contains { $0.id == dose.id })
            let reminders = try await api.sendRequest(.GET, "nests/\(nestID)/reminders", headers: reader)
            #expect(try reminders.content.decode([NestReminderResponse].self).count == 1)
            let logged = try await api.sendRequest(.POST, "entities/\(subjectID)/events", headers: reader, beforeRequest: { req async throws in
                let at = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
                try req.content.encode(SharingLog(actionID: trackerID, valueNumber: 1, occurredAt: at))
            })
            #expect(logged.status == .ok)
            let last = try logged.content.decode(ActionEventResponse.self).occurredAt
            let publicInput = TrackableAction(nestID: nestID, name: "Public input", valueType: .none)
            try await publicInput.save(on: app.db)
            let secretInput = TrackableAction(nestID: nestID, name: "Creator-only signal", valueType: .none)
            secretInput.privateOwnerId = creatorID; try await secretInput.save(on: app.db)
            func forecastInput(_ ids: [UUID]?, names: [String], version: Double) -> UpsertNestForecastRequest {
                UpsertNestForecastRequest(subjectId: subjectID, trackerId: trackerID, predictedAt: last.addingTimeInterval(12 * 3600),
                    baselinePredictedAt: last.addingTimeInterval(3600), contextualPredictedAt: last.addingTimeInterval(12 * 3600),
                    model: "contextual", intervalHours: 1, confidence: 0.9, sampleCount: 2, validationSampleCount: 20,
                    expectedErrorHours: 9, predictionWindowHours: 20, targetNames: ["Untrusted private label"], inputNames: names,
                    lastEventAt: last, computedAt: Date().addingTimeInterval(version), inputTrackerIDs: ids)
            }
            for (ids,names,version,expectedModel) in [
                (nil as [UUID]?, [secretInput.name], 1.0, "baseline"),
                ([try publicInput.requireID()], [publicInput.name], 2.0, "contextual"),
                ([try secretInput.requireID()], [secretInput.name], 3.0, "baseline")
            ] {
                let published = try await api.sendRequest(.PUT, "nests/\(nestID)/forecasts", headers: own, beforeRequest: { req async throws in
                    try req.content.encode([forecastInput(ids, names: names, version: version)])
                })
                #expect(published.status == .ok)
                let result = try #require(published.content.decode([NestForecastResponse].self).first)
                #expect(result.model == expectedModel)
                #expect(result.targetNames == [tracker.name])
                if expectedModel == "baseline" {
                    #expect(result.contextualPredictedAt == nil)
                    #expect(result.inputNames.isEmpty)
                    #expect(result.predictedAt.timeIntervalSince(last) < 2 * 3600)
                } else { #expect(result.inputNames == [publicInput.name]) }
            }
            let hiddenList = try await api.sendRequest(.GET, "nests/\(nestID)/events", headers: hidden)
            #expect(try hiddenList.content.decode([ActionEventResponse].self).isEmpty)
            let adminShare = try await api.sendRequest(.PUT, "actions/\(trackerID)/sharing", headers: reader, beforeRequest: { req async throws in try req.content.encode(SharingInput(allowedMemberIDs: [excludedID])) })
            #expect(adminShare.status == .forbidden)
            let adminDelete = try await api.sendRequest(.DELETE, "actions/\(trackerID)", headers: reader)
            #expect(adminDelete.status == .forbidden)
            let adminEdit = try await api.sendRequest(.PATCH, "actions/\(trackerID)", headers: reader, beforeRequest: { req async throws in try req.content.encode(["name":"Changed"]) })
            #expect(adminEdit.status == .forbidden)
            let invalid = try await api.sendRequest(.PUT, "actions/\(trackerID)/sharing", headers: own, beforeRequest: { req async throws in try req.content.encode(SharingInput(allowedMemberIDs: [UUID()])) })
            #expect(invalid.status == .badRequest)
            let secret = TrackableAction(nestID: nestID, name: "Unselected secret", valueType: .none)
            secret.privateOwnerId = excludedID; try await secret.save(on: app.db)
            let secretForecast = NestForecast(nestID: nestID, entityID: subjectID, actionID: try secret.requireID(), generatedByUserID: excludedID,
                predictedAt: Date(), baselinePredictedAt: Date(), contextualPredictedAt: nil, model: "baseline", intervalHours: 1,
                confidence: 0.5, sampleCount: 2, validationSampleCount: 0, expectedErrorHours: nil, predictionWindowHours: 0,
                targetNamesJSON: nil, inputNamesJSON: nil, lastEventAt: Date(), computedAt: Date())
            try await secretForecast.save(on: app.db)
            let maintenance = try await api.sendRequest(.PUT, "nests/\(nestID)/forecasts", headers: reader, beforeRequest: { req async throws in try req.content.encode([UpsertNestForecastRequest]()) })
            #expect(maintenance.status == .ok)
            #expect(try await NestForecast.find(secretForecast.requireID(), on: app.db) != nil)
            let routine = try await api.sendRequest(.POST, "nests/\(nestID)/routines", headers: reader, beforeRequest: { req async throws in
                try req.content.encode(SharingRoutine(name: "Reader routine", targets: [RoutineTarget(entityID: subjectID, items: [RoutineItem(trackerID: trackerID, valueNumber: 1, valueText: nil, valueBool: nil, valueJSON: nil)])]))
            })
            #expect(routine.status == .ok)
            let routineID = try routine.content.decode(RoutineResponse.self).id
            let revoked = try await api.sendRequest(.PUT, "actions/\(trackerID)/sharing", headers: own, beforeRequest: { req async throws in try req.content.encode(SharingInput(allowedMemberIDs: [])) })
            #expect(revoked.status == .ok)
            let unavailable = try await api.sendRequest(.GET, "nests/\(nestID)/events", headers: reader)
            #expect(try unavailable.content.decode([ActionEventResponse].self).isEmpty)
            let deniedLog = try await api.sendRequest(.POST, "entities/\(subjectID)/events", headers: reader, beforeRequest: { req async throws in try req.content.encode(SharingLog(actionID: trackerID, valueNumber: 1)) })
            #expect(deniedLog.status == .notFound)
            let deniedRoutine = try await api.sendRequest(.POST, "routines/\(routineID)/log", headers: reader, beforeRequest: { req async throws in try req.content.encode([String:String]()) })
            #expect(deniedRoutine.status == .notFound)
            let deniedPhoto = try await api.sendRequest(.GET, "events/\(try dose.requireID())/photo", headers: reader)
            #expect(deniedPhoto.status == .notFound)
            let hiddenReminders = try await api.sendRequest(.GET, "nests/\(nestID)/reminders", headers: reader)
            #expect(try hiddenReminders.content.decode([NestReminderResponse].self).isEmpty)
            try await nest.delete(on: app.db)
            for user in [creator,recipient,excluded] { try await user.delete(on: app.db) }
            try await app.asyncShutdown()
        } catch { try await app.asyncShutdown(); throw error }
    }
}
