import Fluent

struct AddActionEventPhotoNote: AsyncMigration {
    func prepare(on db: any Database) async throws {
        try await db.schema(ActionEventPhoto.schema)
            .field("note", .string)
            .update()
    }

    func revert(on db: any Database) async throws {
        try await db.schema(ActionEventPhoto.schema)
            .deleteField("note")
            .update()
    }
}
