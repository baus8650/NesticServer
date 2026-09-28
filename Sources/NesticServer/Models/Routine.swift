import Fluent
import Vapor

struct RoutineItem: Codable, Content, Hashable, Sendable {
    let trackerID: UUID
    let valueNumber: Double?
    let valueText: String?
    let valueBool: Bool?
    let valueJSON: [String: String]?
}

struct RoutineTarget: Codable, Content, Hashable, Sendable {
    let entityID: UUID
    let items: [RoutineItem]
}

/// Postgres must receive the routine item list as one JSON document, not as a
/// native array of JSON values (jsonb[]). Encoding the wrapper as an object is
/// important here: PostgresKit otherwise sees a top-level Swift array and
/// binds it as a PostgreSQL jsonb[] value instead of a single jsonb document.
struct RoutineItems: Codable, Hashable, Sendable {
    var values: [RoutineItem]

    private enum CodingKeys: String, CodingKey {
        case values
    }

    init(_ values: [RoutineItem] = []) {
        self.values = values
    }

    init(from decoder: any Decoder) throws {
        if let container = try? decoder.container(keyedBy: CodingKeys.self) {
            values = try container.decode([RoutineItem].self, forKey: .values)
        } else {
            // Rows written by the earlier array-shaped representation remain
            // readable while new writes use the object-shaped JSON document.
            values = try decoder.singleValueContainer().decode([RoutineItem].self)
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(values, forKey: .values)
    }
}

struct RoutineTargets: Codable, Hashable, Sendable {
    var values: [RoutineTarget]

    private enum CodingKeys: String, CodingKey {
        case values
    }

    init(_ values: [RoutineTarget] = []) {
        self.values = values
    }

    init(from decoder: any Decoder) throws {
        if let container = try? decoder.container(keyedBy: CodingKeys.self) {
            values = try container.decode([RoutineTarget].self, forKey: .values)
        } else {
            values = try decoder.singleValueContainer().decode([RoutineTarget].self)
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(values, forKey: .values)
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

    @OptionalField(key: "targets")
    var targets: RoutineTargets?

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
        self.targets = nil
    }

    init(id: UUID? = nil, nestID: UUID, name: String, targets: [RoutineTarget]) {
        self.id = id
        self.$nest.id = nestID
        self.$entity.id = targets[0].entityID
        self.name = name
        self.items = RoutineItems(targets[0].items)
        self.targets = RoutineTargets(targets)
    }
}
