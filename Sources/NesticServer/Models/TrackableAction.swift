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
    case photo      // a photo stored in the nest's private photo storage
    case health     // an episode with onset details, an optional photo, and resolution
}

final class TrackableAction: Model, Content, @unchecked Sendable {
    static let schema = "trackable_actions"

    @ID(key: .id)
    var id: UUID?

    @Parent(key: "nest_id")
    var nest: Nest

    @OptionalField(key: "private_owner_id")
    var privateOwnerId: UUID?

    @OptionalField(key: "allowed_member_ids")
    var allowedMemberIDs: [UUID]?

    @Field(key: "name")
    var name: String  // e.g. "Fed", "Walked", "Weight", "Medication"

    @Enum(key: "value_type")
    var valueType: ActionValueType

    @OptionalField(key: "unit")
    var unit: String? // e.g. "lb", "kg", "min"

    @OptionalField(key: "symbol")
    var symbol: String? // an SF Symbol name or emoji chosen by the user

    @OptionalField(key: "color")
    var color: String? // a six-digit hex color chosen by the user

    @OptionalField(key: "group_name")
    var groupName: String? // e.g. "Medication" for related medicine trackers

    @OptionalField(key: "description")
    var description: String?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}

    init(id: UUID? = nil, nestID: UUID, name: String, valueType: ActionValueType, unit: String? = nil, symbol: String? = nil, color: String? = nil, groupName: String? = nil, description: String? = nil) {
        self.id = id
        self.$nest.id = nestID
        self.name = name
        self.valueType = valueType
        self.unit = unit
        self.symbol = symbol
        self.color = color
        self.groupName = groupName
        self.description = description
    }
}
