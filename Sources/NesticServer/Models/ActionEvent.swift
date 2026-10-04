//
//  ActionEvent.swift
//  NesticServer
//
//  Created by Tim Bausch on 2/26/26.
//

import Fluent
import Vapor

final class ActionEvent: Model, Content, @unchecked Sendable {
    static let schema = "action_events"

    @ID(key: .id)
    var id: UUID?

    @Parent(key: "nest_id")
    var nest: Nest

    @Parent(key: "entity_id")
    var entity: Entity

    @Parent(key: "action_id")
    var action: TrackableAction

    // Who logged it (optional: allow system/imported events)
    @OptionalParent(key: "actor_user_id")
    var actor: User?

    @Field(key: "occurred_at")
    var occurredAt: Date

    // Flexible payload: supports number/text/bool/json patterns
    @OptionalField(key: "value_number")
    var valueNumber: Double?

    @OptionalField(key: "value_text")
    var valueText: String?

    @OptionalField(key: "value_bool")
    var valueBool: Bool?

    // JSON payload for complex cases (medication details, dosages, etc.)
    @OptionalField(key: "value_json")
    var valueJSON: [String: String]?

    @OptionalField(key: "note")
    var note: String?

    /// Private R2 reference for a photo attached to this event. The API
    /// proxies the binary after checking nest membership; the reference is
    /// never exposed as a public URL.
    @OptionalField(key: "photo_url")
    var photoURL: String?

    @Children(for: \.$event)
    var photoUpdates: [ActionEventPhoto]

    /// A health event is open while this remains nil. The onset is stored in
    /// `occurredAt`; this timestamp closes that same episode.
    @OptionalField(key: "resolved_at")
    var resolvedAt: Date?

    @OptionalField(key: "resolution_note")
    var resolutionNote: String?

    @Field(key: "was_accident")
    var wasAccident: Bool

    @Field(key: "include_in_predictions")
    var includeInPredictions: Bool

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        nestID: UUID,
        entityID: UUID,
        actionID: UUID,
        actorUserID: UUID?,
        occurredAt: Date,
        valueNumber: Double? = nil,
        valueText: String? = nil,
        valueBool: Bool? = nil,
        valueJSON: [String: String]? = nil,
        note: String? = nil,
        photoURL: String? = nil,
        resolvedAt: Date? = nil,
        resolutionNote: String? = nil,
        wasAccident: Bool = false,
        includeInPredictions: Bool = true
    ) {
        self.id = id
        self.$nest.id = nestID
        self.$entity.id = entityID
        self.$action.id = actionID
        self.$actor.id = actorUserID
        self.occurredAt = occurredAt
        self.valueNumber = valueNumber
        self.valueText = valueText
        self.valueBool = valueBool
        self.valueJSON = valueJSON
        self.note = note
        self.photoURL = photoURL
        self.resolvedAt = resolvedAt
        self.resolutionNote = resolutionNote
        self.wasAccident = wasAccident
        self.includeInPredictions = includeInPredictions
    }
}
