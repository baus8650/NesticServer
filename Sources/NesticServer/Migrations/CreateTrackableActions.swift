//
//  CreateTrackableActions.swift
//  NesticServer
//
//  Created by Tim Bausch on 2/26/26.
//

import Fluent

struct CreateTrackableActions: AsyncMigration {
    func prepare(on db: any Database) async throws {
        try await db.schema("trackable_actions")
            .id()
            .field("nest_id", .uuid, .required, .references("nests", "id", onDelete: .cascade))
            .field("name", .string, .required)        // "Fed", "Walked", "Weight", etc.
            .field("value_type", .string, .required)  // none/number/text/boolean/json
            .field("unit", .string)                   // optional
            .field("description", .string)            // optional

            .field("created_at", .datetime)
            .field("updated_at", .datetime)

            // Prevent duplicates within a nest
            .unique(on: "nest_id", "name")
            .create()
    }

    func revert(on db: any Database) async throws {
        try await db.schema("trackable_actions").delete()
    }
}
