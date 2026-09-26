//
//  Entity.swift
//  NesticServer
//
//  Created by Tim Bausch on 2/26/26.
//

import Fluent
import Vapor

enum EntityKind: String, Codable {
    case person
    case pet
    case thing
    case custom
}

final class Entity: Model, Content, @unchecked Sendable {
    static let schema = "entities"

    @ID(key: .id)
    var id: UUID?

    @Parent(key: "nest_id")
    var nest: Nest

    @Enum(key: "kind")
    var kind: EntityKind

    @Field(key: "name")
    var name: String

    // Free-form tags so you can group/filter later (e.g., ["dog","golden"], ["vehicle","truck"])
    @Field(key: "tags")
    var tags: [String]

    @OptionalField(key: "metadata")
    var metadata: [String: String]?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    @OptionalField(key: "birthday")
    var birthday: Date?

    @OptionalField(key: "image_url")
    var imageURL: String?

    init() {}

    init(nestID: UUID, kind: EntityKind, name: String, tags: [String] = [], metadata: [String: String]? = nil, birthday: Date? = nil, imageURL: String? = nil) {
        self.$nest.id = nestID
        self.kind = kind
        self.name = name
        self.tags = tags
        self.metadata = metadata
        self.birthday = birthday
        self.imageURL = imageURL
    }
}
