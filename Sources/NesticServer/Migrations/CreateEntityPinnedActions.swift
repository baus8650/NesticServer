//
//  CreateEntityPinnedActions.swift
//  NesticServer
//
//  Created by Tim Bausch on 2/27/26.
//

import Fluent

struct CreateEntityPinnedActions: AsyncMigration {
    func prepare(on db: any Database) async throws {
        try await db.schema("entity_pinned_actions")
            .id()
            .field("entity_id", .uuid, .required, .references("entities", "id", onDelete: .cascade))
            .field("action_id", .uuid, .required, .references("trackable_actions", "id", onDelete: .cascade))
            .field("sort_order", .int, .required)
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .unique(on: "entity_id", "action_id")
            .create()
    }

    func revert(on db: any Database) async throws {
        try await db.schema("entity_pinned_actions").delete()
    }
}
