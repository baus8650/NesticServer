//
//  Nest.swift
//  NesticServer
//
//  Created by Tim Bausch on 2/26/26.
//

import Fluent
import Vapor

final class Nest: Model, Content, @unchecked Sendable {
    static let schema = "nests"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "name")
    var name: String

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}
    init(id: UUID? = nil, name: String) {
        self.id = id
        self.name = name
    }
}
