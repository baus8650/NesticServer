//
//  EntityPinnedAction.swift
//  NesticServer
//
//  Created by Tim Bausch on 2/27/26.
//

import Fluent
import Vapor

final class EntityPinnedAction: Model, Content, @unchecked Sendable {
    static let schema = "entity_pinned_actions"

    @ID(key: .id)
    var id: UUID?

    @Parent(key: "entity_id")
    var entity: Entity

    @Parent(key: "action_id")
    var action: TrackableAction

    @Field(key: "sort_order")
    var sortOrder: Int

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}

    init(entityID: UUID, actionID: UUID, sortOrder: Int) {
        self.$entity.id = entityID
        self.$action.id = actionID
        self.sortOrder = sortOrder
    }
}
