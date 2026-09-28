import Fluent

struct AddRoutineTargets: AsyncMigration {
    func prepare(on db: any Database) async throws {
        try await db.schema("routines")
            .field("targets", .json)
            .update()
    }

    func revert(on db: any Database) async throws {
        try await db.schema("routines")
            .deleteField("targets")
            .update()
    }
}
