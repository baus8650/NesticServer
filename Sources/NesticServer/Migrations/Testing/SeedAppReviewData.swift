import Foundation
import Fluent
import Vapor

/// One-shot, explicitly opt-in data for App Review and manual QA.
///
/// The account password is supplied through APP_REVIEW_SEED_PASSWORD so the
/// credential is never committed to source control. The migration is only
/// registered when SEED_APP_REVIEW_DATA=true.
struct SeedAppReviewData: AsyncMigration {
    private static let email = "test@test.com"
    private static let nestName = "Our Little Nest"

    func prepare(on db: any Database) async throws {
        guard let password = Environment.get("APP_REVIEW_SEED_PASSWORD"), !password.isEmpty else {
            throw Abort(.internalServerError, reason: "APP_REVIEW_SEED_PASSWORD must be set when SEED_APP_REVIEW_DATA=true")
        }

        let user: User
        if let existing = try await User.query(on: db).filter(\.$email == Self.email).first() {
            user = existing
            user.passwordHash = try Bcrypt.hash(password)
            user.displayName = "App Review Tester"
            user.emailVerified = true
            try await user.save(on: db)
        } else {
            let created = User(
                email: Self.email,
                passwordHash: try Bcrypt.hash(password),
                displayName: "App Review Tester",
                emailVerified: true
            )
            try await created.save(on: db)
            user = created
        }

        let userID = try user.requireID()
        let nest: Nest
        if let existing = try await existingNest(for: userID, on: db) {
            nest = existing
        } else {
            let created = Nest(name: Self.nestName)
            try await created.save(on: db)
            let membership = NestMember(nestID: try created.requireID(), userID: userID, role: .owner)
            try await membership.save(on: db)
            nest = created
        }
        let nestID = try nest.requireID()

        // Do not overwrite an account that a reviewer or tester has already
        // started using. A fresh App Review account receives the full fixture.
        if try await Entity.query(on: db).filter(\.$nest.$id == nestID).count() == 0 {
            try await seedContent(userID: userID, nestID: nestID, on: db)
        }
    }

    func revert(on db: any Database) async throws {
        // This migration is intentionally not reversible. Removing a seeded
        // account would be surprising on a hosted database.
    }

    private func existingNest(for userID: UUID, on db: any Database) async throws -> Nest? {
        let memberships = try await NestMember.query(on: db)
            .filter(\.$user.$id == userID)
            .all()
        for membership in memberships {
            guard let nest = try await Nest.find(membership.$nest.id, on: db),
                  [Self.nestName, "App Review Nest"].contains(nest.name) else { continue }
            return nest
        }
        return nil
    }

    private func seedContent(userID: UUID, nestID: UUID, on db: any Database) async throws {
        let maple = Entity(nestID: nestID, kind: .pet, name: "Parker", tags: ["companion", "demo"])
        let jordan = Entity(nestID: nestID, kind: .person, name: "Penny", tags: ["household", "demo"])
        let home = Entity(nestID: nestID, kind: .thing, name: "Home", tags: ["space", "demo"])
        try await maple.save(on: db)
        try await jordan.save(on: db)
        try await home.save(on: db)

        let mapleID = try maple.requireID()
        let jordanID = try jordan.requireID()
        let homeID = try home.requireID()

        let meal = TrackableAction(
            nestID: nestID, name: "Meal", valueType: .number, unit: "cups",
            symbol: "fork.knife", color: "#D96C57", groupName: "Daily care",
            description: "Record the amount provided during a meal."
        )
        let outdoorTime = TrackableAction(
            nestID: nestID, name: "Outdoor time", valueType: .number, unit: "minutes",
            symbol: "figure.walk", color: "#6A9F3B", groupName: "Daily care",
            description: "Record time spent outside or on an outing."
        )
        let energy = TrackableAction(
            nestID: nestID, name: "Energy", valueType: .number, unit: "score",
            symbol: "bolt.fill", color: "#D89B27", groupName: "Wellness",
            description: "A simple 1–10 daily wellness check-in."
        )
        let weight = TrackableAction(
            nestID: nestID, name: "Weight", valueType: .number, unit: "lbs",
            symbol: "chart.line.uptrend.xyaxis", color: "#2879A8", groupName: "Wellness"
        )
        let health = TrackableAction(
            nestID: nestID, name: "Health event", valueType: .health,
            symbol: "cross.case.fill", color: "#D96C57", groupName: "Wellness",
            description: "Track an episode from onset through resolution, with dated updates."
        )
        let supplement = TrackableAction(
            nestID: nestID, name: "Daily supplement", valueType: .none,
            symbol: "pills.fill", color: "#8B5E83", groupName: "Care"
        )
        let mood = TrackableAction(
            nestID: nestID, name: "Mood", valueType: .text,
            symbol: "face.smiling", color: "#8067B7", groupName: "Wellness"
        )
        let water = TrackableAction(
            nestID: nestID, name: "Water intake", valueType: .number, unit: "glasses",
            symbol: "drop.fill", color: "#2879A8", groupName: "Wellness"
        )
        let homeCheck = TrackableAction(
            nestID: nestID, name: "Home check", valueType: .none,
            symbol: "house.fill", color: "#2E6B52", groupName: "Home"
        )
        let actions = [meal, outdoorTime, energy, weight, health, supplement, mood, water, homeCheck]
        for action in actions { try await action.save(on: db) }

        let mealID = try meal.requireID()
        let outdoorTimeID = try outdoorTime.requireID()
        let energyID = try energy.requireID()
        let weightID = try weight.requireID()
        let healthID = try health.requireID()
        let supplementID = try supplement.requireID()
        let moodID = try mood.requireID()
        let waterID = try water.requireID()
        let homeCheckID = try homeCheck.requireID()

        let pins: [(UUID, UUID)] = [
            (mapleID, mealID), (mapleID, outdoorTimeID), (mapleID, energyID),
            (mapleID, weightID), (mapleID, healthID), (mapleID, supplementID),
            (jordanID, moodID), (jordanID, waterID), (homeID, homeCheckID)
        ]
        for (index, pin) in pins.enumerated() {
            try await EntityPinnedAction(entityID: pin.0, actionID: pin.1, sortOrder: index).save(on: db)
        }

        let now = Date()
        // Enough history for the Today, week, month, chart, and forecast flows.
        for day in 0..<10 {
            let base = now.addingTimeInterval(-Double(day) * 24 * 60 * 60)
            try await ActionEvent(
                nestID: nestID, entityID: mapleID, actionID: mealID, actorUserID: userID,
                occurredAt: base.addingTimeInterval(-8 * 60 * 60),
                valueNumber: day.isMultiple(of: 2) ? 1.25 : 1.0,
                note: day == 0 ? "Morning meal recorded." : nil
            ).save(on: db)
            try await ActionEvent(
                nestID: nestID, entityID: mapleID, actionID: outdoorTimeID, actorUserID: userID,
                occurredAt: base.addingTimeInterval(-6 * 60 * 60),
                valueNumber: 20 + Double(day % 4) * 5
            ).save(on: db)
            try await ActionEvent(
                nestID: nestID, entityID: mapleID, actionID: energyID, actorUserID: userID,
                occurredAt: base.addingTimeInterval(-4 * 60 * 60),
                valueNumber: 7 + Double(day % 3)
            ).save(on: db)
        }

        try await ActionEvent(
            nestID: nestID, entityID: mapleID, actionID: weightID, actorUserID: userID,
            occurredAt: now.addingTimeInterval(-2 * 24 * 60 * 60), valueNumber: 72.4,
            note: "Routine wellness check."
        ).save(on: db)
        try await ActionEvent(
            nestID: nestID, entityID: mapleID, actionID: supplementID, actorUserID: userID,
            occurredAt: now.addingTimeInterval(-90 * 60), note: "Daily care completed."
        ).save(on: db)
        try await ActionEvent(
            nestID: nestID, entityID: jordanID, actionID: moodID, actorUserID: userID,
            occurredAt: now.addingTimeInterval(-3 * 60 * 60), valueText: "Steady",
            note: "A quick household check-in."
        ).save(on: db)
        try await ActionEvent(
            nestID: nestID, entityID: jordanID, actionID: waterID, actorUserID: userID,
            occurredAt: now.addingTimeInterval(-2 * 60 * 60), valueNumber: 5
        ).save(on: db)
        try await ActionEvent(
            nestID: nestID, entityID: homeID, actionID: homeCheckID, actorUserID: userID,
            occurredAt: now.addingTimeInterval(-45 * 60), note: "Evening home check completed."
        ).save(on: db)

        let resolvedHealth = ActionEvent(
            nestID: nestID, entityID: mapleID, actionID: healthID, actorUserID: userID,
            occurredAt: now.addingTimeInterval(-8 * 24 * 60 * 60),
            valueText: "Seasonal sensitivity",
            note: "A resolved wellness episode for report history.",
            resolvedAt: now.addingTimeInterval(-7 * 24 * 60 * 60),
            resolutionNote: "Returned to normal routine."
        )
        try await resolvedHealth.save(on: db)

        let openHealth = ActionEvent(
            nestID: nestID, entityID: mapleID, actionID: healthID, actorUserID: userID,
            occurredAt: now.addingTimeInterval(-5 * 60 * 60),
            valueText: "Seasonal sensitivity",
            note: "Open wellness episode for testing dated updates and resolution."
        )
        try await openHealth.save(on: db)
        let openHealthID = try openHealth.requireID()
        try await ActionEventPhoto(
            eventID: openHealthID, actorUserID: userID,
            capturedAt: now.addingTimeInterval(-2 * 60 * 60), photoURL: "",
            note: "Follow-up text update from an evening check-in."
        ).save(on: db)

        let routine = Routine(
            nestID: nestID,
            name: "Morning care",
            targets: [
                RoutineTarget(entityID: mapleID, items: [
                    RoutineItem(trackerID: mealID, valueNumber: 1.25, valueText: nil, valueBool: nil, valueJSON: nil),
                    RoutineItem(trackerID: outdoorTimeID, valueNumber: 20, valueText: nil, valueBool: nil, valueJSON: nil),
                    RoutineItem(trackerID: energyID, valueNumber: 8, valueText: nil, valueBool: nil, valueJSON: nil)
                ]),
                RoutineTarget(entityID: jordanID, items: [
                    RoutineItem(trackerID: waterID, valueNumber: 1, valueText: nil, valueBool: nil, valueJSON: nil)
                ])
            ]
        )
        try await routine.save(on: db)

        let preferences = [
            mapleID: ReviewPredictionPreferences(
                inputTrackerIDs: [mealID, energyID],
                targetTrackerIDs: [outdoorTimeID, weightID]
            )
        ]
        let quietHours = ReviewQuietHours(
            periods: [ReviewQuietHoursPeriod(id: UUID(), startMinute: 23 * 60, endMinute: 6 * 60)],
            confidenceThresholdPercent: 75
        )
        let reminder = ReviewReminder(
            id: UUID(), nestID: nestID, subjectID: mapleID, subjectName: maple.name,
            medicationTrackerID: supplementID, medicationName: supplement.name,
            cadence: .afterMeal, linkedMealTrackerID: mealID, linkedMealName: meal.name,
            delayMinutes: 30, anchorDate: now, hour: 20, minute: 0, enabled: true
        )

        let settings = NestUserSettings(nestID: nestID, userID: userID)
        settings.predictionPreferencesJSON = try jsonString(preferences)
        settings.quietHoursJSON = try jsonString(quietHours)
        settings.remindersJSON = try jsonString([reminder])
        try await settings.save(on: db)
    }

    private func jsonString<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return String(data: try encoder.encode(value), encoding: .utf8)!
    }
}

private struct ReviewPredictionPreferences: Codable {
    let inputTrackerIDs: [UUID]
    let targetTrackerIDs: [UUID]
}

private struct ReviewQuietHoursPeriod: Codable {
    let id: UUID
    let startMinute: Int
    let endMinute: Int
}

private struct ReviewQuietHours: Codable {
    let periods: [ReviewQuietHoursPeriod]
    let confidenceThresholdPercent: Int
}

private enum ReviewReminderCadence: String, Codable {
    case afterMeal
}

private struct ReviewReminder: Codable {
    let id: UUID
    let nestID: UUID
    let subjectID: UUID
    let subjectName: String
    let medicationTrackerID: UUID
    let medicationName: String
    let cadence: ReviewReminderCadence
    let linkedMealTrackerID: UUID?
    let linkedMealName: String?
    let delayMinutes: Int
    let anchorDate: Date
    let hour: Int
    let minute: Int
    let enabled: Bool
}
