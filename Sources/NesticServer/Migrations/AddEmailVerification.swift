import Fluent
import SQLKit

/// Existing accounts were already usable, so they remain verified when this
/// column is introduced. New password accounts explicitly start unverified.
struct AddEmailVerification: AsyncMigration {
    func prepare(on db: any Database) async throws {
        guard let sql = db as? any SQLDatabase else { return }
        try await sql.raw("ALTER TABLE users ADD COLUMN IF NOT EXISTS email_verified BOOLEAN NOT NULL DEFAULT TRUE").run()
    }

    func revert(on db: any Database) async throws {
        guard let sql = db as? any SQLDatabase else { return }
        try await sql.raw("ALTER TABLE users DROP COLUMN IF EXISTS email_verified").run()
    }
}
