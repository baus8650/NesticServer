//
//  User.swift
//  NesticServer
//
//  Created by Tim Bausch on 2/26/26.
//

import Fluent
import Vapor

final class User: Model, Content, @unchecked Sendable {
    static let schema = "users"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "display_name")
    var displayName: String

    @Field(key: "email")
    var email: String

    @Field(key: "password_hash")
    var passwordHash: String

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    @OptionalField(key: "image_url")
    var imageURL: String?

    init() {}

    init(email: String, passwordHash: String, displayName: String, imageURL: String? = nil) {
        self.email = email
        self.passwordHash = passwordHash
        self.displayName = displayName
        self.imageURL = imageURL
    }
}

extension User: ModelAuthenticatable {
    static var usernameKey: KeyPath<User, FieldProperty<User, String>> { \User.$email }
    static var passwordHashKey: KeyPath<User, FieldProperty<User, String>> { \User.$passwordHash }

    func verify(password: String) throws -> Bool {
        try Bcrypt.verify(password, created: self.passwordHash)
    }
}
