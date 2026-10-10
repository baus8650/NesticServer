@testable import NesticServer
import Testing
import VaporTesting
import Fluent

@Suite("Medication course reminders", .serialized, .enabled(if: Environment.get("RUN_DATABASE_TESTS") == "true"))
struct DoseReminderTests {
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
    @Test("Dose resets, course totals, corrections, account sync, and private isolation")
    func course() async throws {
        try await withApp { app in
            try await app.autoMigrate()
            let suffix = UUID().uuidString
            let user = User(email: "dose-\(suffix)@example.com", passwordHash: "unused", displayName: "Dose owner", emailVerified: true)
            let other = User(email: "dose-other-\(suffix)@example.com", passwordHash: "unused", displayName: "Other", emailVerified: true)
            try await user.save(on: app.db); try await other.save(on: app.db)
            let nest = Nest(name: "Dose tests"); try await nest.save(on: app.db)
            let nestID = try nest.requireID(), userID = try user.requireID()
            try await NestMember(nestID: nestID, userID: userID, role: .owner).save(on: app.db)
            try await NestMember(nestID: nestID, userID: try other.requireID(), role: .admin).save(on: app.db)
            let subject = Entity(nestID: nestID, kind: .person, name: "Person"); try await subject.save(on: app.db)
            let subjectID = try subject.requireID()
            let tracker = TrackableAction(nestID: nestID, name: "Pills", valueType: .number)
            tracker.privateOwnerId = userID; try await tracker.save(on: app.db)
            let trackerID = try tracker.requireID()
            let token = try await app.jwt.keys.sign(SessionToken(userId: userID))
            let headers: HTTPHeaders = ["Authorization": "Bearer \(token)"]
            let api = try app.testing()
            let start = Date().addingTimeInterval(-48 * 3600)
            let input = NestReminderRequest(subjectID: subjectID, trackerID: trackerID, intervalHours: 8, totalPills: 3, cadence: .afterDose, linkedTrackerID: nil, delayMinutes: 0, anchorDate: start, hour: 0, minute: 0)
            let created = try await api.sendRequest(.POST, "nests/\(nestID)/reminders", headers: headers, beforeRequest: { req async throws in try req.content.encode(input) })
            #expect(created.status == .ok)
            let r = try created.content.decode(NestReminderResponse.self)
            #expect(r.lastDoseAt == nil); #expect(r.pillsTaken == 0)
            let older = ActionEvent(nestID: nestID, entityID: subjectID, actionID: trackerID, actorUserID: userID, occurredAt: start.addingTimeInterval(-1), valueNumber: 20)
            try await older.save(on: app.db)
            let first = ActionEvent(nestID: nestID, entityID: subjectID, actionID: trackerID, actorUserID: userID, occurredAt: start.addingTimeInterval(3600), valueNumber: 1)
            try await first.save(on: app.db)
            let second = ActionEvent(nestID: nestID, entityID: subjectID, actionID: trackerID, actorUserID: userID, occurredAt: start.addingTimeInterval(30 * 3600), valueNumber: 2)
            try await second.save(on: app.db)
            let read = try await api.sendRequest(.GET, "nests/\(nestID)/reminders", headers: headers)
            let finished = try #require(read.content.decode([NestReminderResponse].self).first)
            #expect(finished.intervalHours == 8); #expect(finished.totalPills == 3)
            #expect(finished.pillsTaken == 3)
            #expect(abs(try #require(finished.lastDoseAt).timeIntervalSince(second.occurredAt)) < 1)
            try await second.delete(on: app.db)
            let corrected = try await api.sendRequest(.GET, "nests/\(nestID)/reminders", headers: headers)
            let active = try #require(corrected.content.decode([NestReminderResponse].self).first)
            #expect(active.pillsTaken == 1)
            #expect(abs(try #require(active.lastDoseAt).timeIntervalSince(first.occurredAt)) < 1)
            let otherToken = try await app.jwt.keys.sign(SessionToken(userId: try other.requireID()))
            let hidden = try await api.sendRequest(.GET, "nests/\(nestID)/reminders", headers: ["Authorization": "Bearer \(otherToken)"])
            #expect(try hidden.content.decode([NestReminderResponse].self).isEmpty)
            let invalid = NestReminderRequest(subjectID: subjectID, trackerID: trackerID, intervalHours: 0, totalPills: 0, cadence: .afterDose, linkedTrackerID: nil, delayMinutes: 0, anchorDate: start, hour: 0, minute: 0)
            let bad = try await api.sendRequest(.POST, "nests/\(nestID)/reminders", headers: headers, beforeRequest: { req async throws in try req.content.encode(invalid) })
            #expect(bad.status == .badRequest)
            try await nest.delete(on: app.db); try await user.delete(on: app.db); try await other.delete(on: app.db)
        }
    }
}
