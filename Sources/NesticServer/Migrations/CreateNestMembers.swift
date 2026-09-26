//
//  CreateNestMembers.swift
//  NesticServer
//
//  Created by Tim Bausch on 2/26/26.
//

import Fluent

struct CreateNestMembers: AsyncMigration {
    func prepare(on db: any Database) async throws {
        try await db.schema("nest_members")
            .id()
            .field("nest_id", .uuid, .required, .references("nests", "id", onDelete: .cascade))
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("role", .string, .required) // owner/admin/member/viewer
            .field("created_at", .datetime)
            .unique(on: "nest_id", "user_id")
            .create()
    }

    func revert(on db: any Database) async throws {
        try await db.schema("nest_members").delete()
    }
}
