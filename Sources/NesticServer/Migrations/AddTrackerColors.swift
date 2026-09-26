import Fluent
import SQLKit

/// Adds the optional accent color selected for a tracker.
struct AddTrackerColors: AsyncMigration {
    func prepare(on db: any Database) async throws {
        guard let sql = db as? any SQLDatabase else { return }
        try await sql.raw("ALTER TABLE trackable_actions ADD COLUMN IF NOT EXISTS color TEXT").run()
    }

    func revert(on db: any Database) async throws {
        guard let sql = db as? any SQLDatabase else { return }
        try await sql.raw("ALTER TABLE trackable_actions DROP COLUMN IF EXISTS color").run()
    }
}
