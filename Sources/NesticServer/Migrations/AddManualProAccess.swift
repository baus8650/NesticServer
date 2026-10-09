import Fluent

struct AddManualProAccess: AsyncMigration {
    func prepare(on db: any Database) async throws {
        try await db.schema(User.schema)
            .field("manual_pro_override", .bool)
            .field("manual_pro_updated_at", .datetime)
            .field("manual_pro_updated_by", .uuid)
            .update()
    }

    func revert(on db: any Database) async throws {
        try await db.schema(User.schema)
            .deleteField("manual_pro_override")
            .deleteField("manual_pro_updated_at")
            .deleteField("manual_pro_updated_by")
            .update()
    }
}
