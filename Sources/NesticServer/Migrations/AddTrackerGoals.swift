import Fluent

struct AddTrackerGoals: AsyncMigration {
    func prepare(on db: any Database) async throws {
        try await db.schema("trackable_actions")
            .field("goal_description", .string)
            .field("goal_target", .double)
            .field("goal_date", .datetime)
            .update()
    }

    func revert(on db: any Database) async throws {
        try await db.schema("trackable_actions")
            .deleteField("goal_description")
            .deleteField("goal_target")
            .deleteField("goal_date")
            .update()
    }
}
