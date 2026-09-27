import Fluent

struct CreateRoutines: AsyncMigration {
    func prepare(on db: any Database) async throws {
        try await db.schema("routines")
            .id()
            .field("nest_id", .uuid, .required, .references("nests", "id", onDelete: .cascade))
            .field("entity_id", .uuid, .required, .references("entities", "id", onDelete: .cascade))
            .field("name", .string, .required)
            .field("items", .json, .required)
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .create()
    }

    func revert(on db: any Database) async throws {
        try await db.schema("routines").delete()
    }
}
