import Fluent
import Vapor

struct AddPrivateRoutines: AsyncMigration {
    func prepare(on db: any Database) async throws {
        try await db.schema(Routine.schema).field("private_owner_id", .uuid, .references("users", "id", onDelete: .cascade)).update()
    }
    func revert(on db: any Database) async throws {
        guard try await Routine.query(on: db).filter(\.$privateOwnerId != nil).count() == 0 else {
            throw Abort(.conflict, reason: "Remove private routines before reverting; private routines must never become shared.")
        }
        try await db.schema(Routine.schema).deleteField("private_owner_id").update()
    }
}
