//
//  CreateUsers.swift
//  NesticServer
//
//  Created by Tim Bausch on 2/26/26.
//

import Fluent

struct CreateUsers: AsyncMigration {
    func prepare(on db: any Database) async throws {
        try await db.schema("users")
            .id()
            .field("email", .string, .required)
            .field("password_hash", .string, .required)
            .field("email_verified", .bool, .required, .sql(.default(true)))
            .field("display_name", .string, .required)
            .field("image_url", .string)
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .unique(on: "email")
            .create()
    }

    func revert(on db: any Database) async throws {
        try await db.schema("users").delete()
    }
}
