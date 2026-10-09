import Fluent
import SQLKit

struct AddGoogleIdentity: AsyncMigration {
    func prepare(on db: any Database) async throws {
        guard let sql = db as? any SQLDatabase else { return }
        try await sql.raw("ALTER TABLE users ADD COLUMN IF NOT EXISTS google_subject TEXT").run()
        try await sql.raw("CREATE UNIQUE INDEX IF NOT EXISTS users_google_subject_unique ON users (google_subject) WHERE google_subject IS NOT NULL").run()
        try await sql.raw("CREATE TABLE IF NOT EXISTS google_signin_challenges (nonce_hash TEXT PRIMARY KEY, expires_at TIMESTAMPTZ NOT NULL)").run()
        try await sql.raw("CREATE INDEX IF NOT EXISTS google_signin_challenges_expiry ON google_signin_challenges (expires_at)").run()
    }
    func revert(on db: any Database) async throws {
        guard let sql = db as? any SQLDatabase else { return }
        try await sql.raw("DROP TABLE IF EXISTS google_signin_challenges").run()
        try await sql.raw("DROP INDEX IF EXISTS users_google_subject_unique").run()
        try await sql.raw("ALTER TABLE users DROP COLUMN IF EXISTS google_subject").run()
    }
}
