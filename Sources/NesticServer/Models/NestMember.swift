//
//  NestMember.swift
//  NesticServer
//
//  Created by Tim Bausch on 2/26/26.
//

import Fluent
import Vapor

enum NestRole: String, Codable {
    case owner
    case admin
    case member
    case viewer
}

final class NestMember: Model, Content, @unchecked Sendable {
    static let schema = "nest_members"

    @ID(key: .id)
    var id: UUID?

    @Parent(key: "nest_id")
    var nest: Nest

    @Parent(key: "user_id")
    var user: User

    @Enum(key: "role")
    var role: NestRole

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(id: UUID? = nil, nestID: UUID, userID: UUID, role: NestRole) {
        self.id = id
        self.$nest.id = nestID
        self.$user.id = userID
        self.role = role
    }
}
