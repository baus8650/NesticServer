//
//  TrackableAction.swift
//  NesticServer
//
//  Created by Tim Bausch on 2/26/26.
//

import Fluent
import Vapor

enum ActionValueType: String, Codable {
    case none       // just “did it”
    case number     // e.g. weight, temperature
    case text       // e.g. note-only actions
    case boolean    // e.g. yes/no checks
    case json       // anything else structured
}

final class TrackableAction: Model, Content, @unchecked Sendable {
    static let schema = "trackable_actions"

    @ID(key: .id)
    var id: UUID?

    @Parent(key: "nest_id")
    var nest: Nest

    @Field(key: "name")
    var name: String  // e.g. "Fed", "Walked", "Weight", "Medication"

    @Enum(key: "value_type")
    var valueType: ActionValueType

    @OptionalField(key: "unit")
    var unit: String? // e.g. "lb", "kg", "min"

    @OptionalField(key: "description")
    var description: String?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}

    init(id: UUID? = nil, nestID: UUID, name: String, valueType: ActionValueType, unit: String? = nil, description: String? = nil) {
        self.id = id
        self.$nest.id = nestID
        self.name = name
        self.valueType = valueType
        self.unit = unit
        self.description = description
    }
}
