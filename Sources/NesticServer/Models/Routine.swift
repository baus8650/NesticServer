import Fluent
import Vapor

struct RoutineItem: Codable, Content, Hashable, Sendable {
    let trackerID: UUID
    let valueNumber: Double?
    let valueText: String?
    let valueBool: Bool?
    let valueJSON: [String: String]?
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
    var items: [RoutineItem]

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
        self.items = items
    }
}
