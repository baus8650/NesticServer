//
//  AddPerformanceIndexes.swift
//  NesticServer
//
//  Created by Tim Bausch on 2/28/26.
//

import Fluent
import SQLKit

struct AddPerformanceIndexes: AsyncMigration {
    func prepare(on db: any Database) async throws {
        guard let sql = db as? any SQLDatabase else { return }

        // Action events: fast “latest per entity/action” and summary queries
        try await sql.raw(#"CREATE INDEX IF NOT EXISTS idx_action_events_nest_entity_occurred_at ON action_events (nest_id, entity_id, occurred_at DESC)"#).run()
        try await sql.raw(#"CREATE INDEX IF NOT EXISTS idx_action_events_entity_action_occurred_at ON action_events (entity_id, action_id, occurred_at DESC)"#).run()
        try await sql.raw(#"CREATE INDEX IF NOT EXISTS idx_action_events_nest_action_occurred_at ON action_events (nest_id, action_id, occurred_at DESC)"#).run()

        // Nest membership: fast “my nests” / membership checks
        try await sql.raw(#"CREATE INDEX IF NOT EXISTS idx_nest_members_user_id ON nest_members (user_id)"#).run()

        // Pinned actions: fast “pins for entity ordered”
        try await sql.raw(#"CREATE INDEX IF NOT EXISTS idx_entity_pinned_actions_entity_sort ON entity_pinned_actions (entity_id, sort_order)"#).run()

        // Entities: fast list by nest
        try await sql.raw(#"CREATE INDEX IF NOT EXISTS idx_entities_nest_id ON entities (nest_id)"#).run()
    }

    func revert(on db: any Database) async throws {
        guard let sql = db as? any SQLDatabase else { return }

        try await sql.raw(#"DROP INDEX IF EXISTS idx_action_events_nest_entity_occurred_at"#).run()
        try await sql.raw(#"DROP INDEX IF EXISTS idx_action_events_entity_action_occurred_at"#).run()
        try await sql.raw(#"DROP INDEX IF EXISTS idx_action_events_nest_action_occurred_at"#).run()
        try await sql.raw(#"DROP INDEX IF EXISTS idx_nest_members_user_id"#).run()
        try await sql.raw(#"DROP INDEX IF EXISTS idx_entity_pinned_actions_entity_sort"#).run()
        try await sql.raw(#"DROP INDEX IF EXISTS idx_entities_nest_id"#).run()
    }
}
