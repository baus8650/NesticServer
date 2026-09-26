import Fluent
import SQLKit

/// Adds the optional icon selected for a tracker without changing existing
/// tracker names or history. `IF NOT EXISTS` keeps deploys safe if a database
/// was already updated manually.
struct AddTrackerSymbols: AsyncMigration {
    func prepare(on db: any Database) async throws {
        guard let sql = db as? any SQLDatabase else { return }
        try await sql.raw("ALTER TABLE trackable_actions ADD COLUMN IF NOT EXISTS symbol TEXT").run()
    }

    func revert(on db: any Database) async throws {
        guard let sql = db as? any SQLDatabase else { return }
        try await sql.raw("ALTER TABLE trackable_actions DROP COLUMN IF EXISTS symbol").run()
    }
}
