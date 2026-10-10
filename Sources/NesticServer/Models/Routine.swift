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

    private enum Collection: Decodable {
        case array([RoutineItem])
        case item(RoutineItem)

        init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let array = try? container.decode([RoutineItem].self) {
                self = .array(array)
            } else {
                self = .item(try container.decode(RoutineItem.self))
            }
        }
    }

    private struct Document: Decodable {
        let values: Collection?
        let items: Collection?

        private enum CodingKeys: String, CodingKey {
            case values
            case items
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            values = try container.decodeIfPresent(Collection.self, forKey: .values)
            items = try container.decodeIfPresent(Collection.self, forKey: .items)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case values
    }

    init(_ values: [RoutineItem] = []) {
        self.values = values
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()

        // Rows written by the original representation are top-level arrays.
        if let array = try? container.decode([RoutineItem].self) {
            values = array
            return
        }

        // Current rows are JSON documents. Accept both field names used by
        // the migration history so a malformed/older row cannot break the
        // entire routines response.
        if let document = try? container.decode(Document.self),
           let documentValues = document.values ?? document.items {
            switch documentValues {
            case .array(let array): values = array
            case .item(let item): values = [item]
            }
            return
        }

        // Be tolerant of a row that contains one item instead of an array.
        if let item = try? container.decode(RoutineItem.self) {
            values = [item]
            return
        }

        throw DecodingError.typeMismatch(
            [RoutineItem].self,
            DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "Expected routine items as an array or JSON document"
            )
        )
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(values, forKey: .values)
    }
}

struct RoutineTargets: Codable, Hashable, Sendable {
    var values: [RoutineTarget]

    private enum Collection: Decodable {
        case array([RoutineTarget])
        case target(RoutineTarget)

        init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let array = try? container.decode([RoutineTarget].self) {
                self = .array(array)
            } else {
                self = .target(try container.decode(RoutineTarget.self))
            }
        }
    }

    private struct Document: Decodable {
        let values: Collection?
        let targets: Collection?

        private enum CodingKeys: String, CodingKey {
            case values
            case targets
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            values = try container.decodeIfPresent(Collection.self, forKey: .values)
            targets = try container.decodeIfPresent(Collection.self, forKey: .targets)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case values
    }

    init(_ values: [RoutineTarget] = []) {
        self.values = values
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()

        if let array = try? container.decode([RoutineTarget].self) {
            values = array
            return
        }

        if let document = try? container.decode(Document.self),
           let documentValues = document.values ?? document.targets {
            switch documentValues {
            case .array(let array): values = array
            case .target(let target): values = [target]
            }
            return
        }

        if let target = try? container.decode(RoutineTarget.self) {
            values = [target]
            return
        }

        throw DecodingError.typeMismatch(
            [RoutineTarget].self,
            DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "Expected routine targets as an array or JSON document"
            )
        )
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

    @OptionalField(key: "private_owner_id")
    var privateOwnerId: UUID?

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
