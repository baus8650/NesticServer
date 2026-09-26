//
//  CreateEntities.swift
//  NesticServer
//
//  Created by Tim Bausch on 2/26/26.
//

import Fluent

struct CreateEntities: AsyncMigration {
    func prepare(on db: any Database) async throws {
        try await db.schema("entities")
            .id()
            .field("nest_id", .uuid, .required, .references("nests", "id", onDelete: .cascade))
            .field("kind", .string, .required) // person/pet/thing/custom
            .field("name", .string, .required)

            // Optional “flex fields” to keep schema generic.
            .field("tags", .array(of: .string)) // optional
            .field("metadata", .json)           // optional JSON object

            // New optional fields
            .field("birthday", .date)
            .field("image_url", .string)

            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .create()
    }

    func revert(on db: any Database) async throws {
        try await db.schema("entities").delete()
    }
}
