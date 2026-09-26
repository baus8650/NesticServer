import Fluent
import SQLKit

struct AddAppleIdentity: AsyncMigration {
    func prepare(on db: any Database) async throws {
        guard let sql = db as? any SQLDatabase else { return }
        try await sql.raw("ALTER TABLE users ADD COLUMN IF NOT EXISTS apple_subject TEXT").run()
        try await sql.raw("CREATE UNIQUE INDEX IF NOT EXISTS users_apple_subject_unique ON users (apple_subject) WHERE apple_subject IS NOT NULL").run()
    }

    func revert(on db: any Database) async throws {
        guard let sql = db as? any SQLDatabase else { return }
        try await sql.raw("DROP INDEX IF EXISTS users_apple_subject_unique").run()
        try await sql.raw("ALTER TABLE users DROP COLUMN IF EXISTS apple_subject").run()
    }
}
