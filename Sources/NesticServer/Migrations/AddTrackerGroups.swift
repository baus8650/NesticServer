import Fluent

struct AddTrackerGroups: AsyncMigration {
    func prepare(on db: any Database) async throws {
        try await db.schema("trackable_actions")
            .field("group_name", .string)
            .update()
    }

    func revert(on db: any Database) async throws {
        try await db.schema("trackable_actions")
            .deleteField("group_name")
            .update()
    }
}
