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

    @Field(key: "email_verified")
    var emailVerified: Bool

    @OptionalField(key: "manual_pro_override")
    var manualProOverride: Bool?

    @OptionalField(key: "manual_pro_updated_at")
    var manualProUpdatedAt: Date?

    @OptionalField(key: "manual_pro_updated_by")
    var manualProUpdatedBy: UUID?

    @OptionalField(key: "apple_subject")
    var appleSubject: String?

    @OptionalField(key: "google_subject")
    var googleSubject: String?

    @OptionalField(key: "terms_version")
    var termsVersion: String?

    @OptionalField(key: "terms_accepted_at")
    var termsAcceptedAt: Date?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    @OptionalField(key: "image_url")
    var imageURL: String?

    init() {}

    init(email: String, passwordHash: String, displayName: String, imageURL: String? = nil, appleSubject: String? = nil, emailVerified: Bool = false) {
        self.email = email
        self.passwordHash = passwordHash
        self.emailVerified = emailVerified
        self.displayName = displayName
        self.imageURL = imageURL
        self.appleSubject = appleSubject
    }
}

extension User: ModelAuthenticatable {
    static var usernameKey: KeyPath<User, FieldProperty<User, String>> { \User.$email }
    static var passwordHashKey: KeyPath<User, FieldProperty<User, String>> { \User.$passwordHash }

    func verify(password: String) throws -> Bool {
        try Bcrypt.verify(password, created: self.passwordHash)
    }
}
