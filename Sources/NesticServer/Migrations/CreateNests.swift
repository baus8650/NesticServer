//
//  CreateNests.swift
//  NesticServer
//
//  Created by Tim Bausch on 2/26/26.
//

import Fluent

struct CreateNests: AsyncMigration {
    func prepare(on db: any Database) async throws {
        try await db.schema("nests")
            .id()
            .field("name", .string, .required)
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .create()
    }

    func revert(on db: any Database) async throws {
        try await db.schema("nests").delete()
    }
}
