import Fluent

/// Leave legacy/seeded accounts unset; never manufacture prior consent.
struct AddTermsAcceptance: AsyncMigration {
    func prepare(on db: any Database) async throws {
        try await db.schema(User.schema)
            .field("terms_version", .string)
            .field("terms_accepted_at", .datetime)
            .update()
    }

    func revert(on db: any Database) async throws {
        try await db.schema(User.schema)
            .deleteField("terms_version")
            .deleteField("terms_accepted_at")
            .update()
    }
}
