import Fluent
import Vapor

struct RoutineItem: Codable, Content, Hashable, Sendable {
    let trackerID: UUID
    let valueNumber: Double?
    let valueText: String?
    let valueBool: Bool?
    let valueJSON: [String: String]?
}

/// Postgres must receive the routine item list as one JSON document, not as a
/// native array of JSON values (jsonb[]). The wrapper preserves the API's
/// array representation while making Fluent bind the field as a single jsonb.
struct RoutineItems: Codable, Hashable, Sendable {
    var values: [RoutineItem]

    init(_ values: [RoutineItem] = []) {
        self.values = values
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        values = try container.decode([RoutineItem].self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(values)
    }
}

final class Routine: Model, Content, @unchecked Sendable {
    static let schema = "routines"

    @ID(key: .id)
    var id: UUID?

    @Parent(key: "nest_id")
    var nest: Nest

    @Parent(key: "entity_id")
    var entity: Entity

    @Field(key: "name")
    var name: String

    @Field(key: "items")
    var items: RoutineItems

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}

    init(id: UUID? = nil, nestID: UUID, entityID: UUID, name: String, items: [RoutineItem]) {
        self.id = id
        self.$nest.id = nestID
        self.$entity.id = entityID
        self.name = name
        self.items = RoutineItems(items)
    }
}
