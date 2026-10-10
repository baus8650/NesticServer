import Fluent
struct AddTrackerSharing: AsyncMigration {
    func prepare(on db: any Database) async throws {
        try await db.schema("trackable_actions").field("allowed_member_ids", .array(of: .uuid)).update()
    }
    func revert(on db: any Database) async throws {
        try await db.schema("trackable_actions").deleteField("allowed_member_ids").update()
    }
}
