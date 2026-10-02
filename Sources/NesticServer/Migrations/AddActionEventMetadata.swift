import Fluent

struct AddActionEventMetadata: AsyncMigration {
    func prepare(on db: any Database) async throws {
        try await db.schema("action_events")
            .field("was_accident", .bool, .required, .sql(.default(false)))
            .field("include_in_predictions", .bool, .required, .sql(.default(true)))
            .update()
    }

    func revert(on db: any Database) async throws {
        try await db.schema("action_events")
            .deleteField("was_accident")
            .deleteField("include_in_predictions")
            .update()
    }
}
