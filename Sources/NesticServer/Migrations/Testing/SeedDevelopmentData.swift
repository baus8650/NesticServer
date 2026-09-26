//
//  SeedDevelopmentData.swift
//  NesticServer
//
//  Created by Tim Bausch on 2/26/26.
//

import Fluent
import Vapor

struct SeedDevelopmentData: AsyncMigration {
    func prepare(on db: any Database) async throws {
        // ---- Create User ----
        let passwordHash = try Bcrypt.hash("password")

        let user = User(
            email: "test@nestic.local",
            passwordHash: passwordHash,
            displayName: "Test User",
            imageURL: nil
        )
        try await user.save(on: db)

        guard let userID = user.id else {
            throw Abort(.internalServerError)
        }

        // ---- Create Nest ----
        let nest = Nest(name: "Test Nest")
        try await nest.save(on: db)

        guard let nestID = nest.id else {
            throw Abort(.internalServerError)
        }

        // ---- Make user owner ----
        let membership = NestMember(
            nestID: nestID,
            userID: userID,
            role: .owner
        )
        try await membership.save(on: db)

        // ---- Create Entities ----
        let pet = Entity(
            nestID: nestID,
            kind: .pet,
            name: "Ranger",
            tags: ["dog", "golden"]
        )

        let person = Entity(
            nestID: nestID,
            kind: .person,
            name: "Tim"
        )

        try await pet.save(on: db)
        try await person.save(on: db)

        guard let petID = pet.id,
              let personID = person.id else {
            throw Abort(.internalServerError)
        }

        // ---- Create Trackable Actions ----
        let feed = TrackableAction(
            nestID: nestID,
            name: "Fed",
            valueType: .none
        )

        let walk = TrackableAction(
            nestID: nestID,
            name: "Walked",
            valueType: .number,
            unit: "minutes"
        )

        let weight = TrackableAction(
            nestID: nestID,
            name: "Weight",
            valueType: .number,
            unit: "lbs"
        )

        try await feed.save(on: db)
        try await walk.save(on: db)
        try await weight.save(on: db)

        guard let feedID = feed.id,
              let walkID = walk.id,
              let weightID = weight.id else {
            throw Abort(.internalServerError)
        }

        // ---- Create Action Events ----
        let now = Date()

        let feedEvent = ActionEvent(
            nestID: nestID,
            entityID: petID,
            actionID: feedID,
            actorUserID: userID,
            occurredAt: now,
            note: "Morning feeding"
        )

        let walkEvent = ActionEvent(
            nestID: nestID,
            entityID: petID,
            actionID: walkID,
            actorUserID: userID,
            occurredAt: now,
            valueNumber: 25
        )

        let weightEvent = ActionEvent(
            nestID: nestID,
            entityID: petID,
            actionID: weightID,
            actorUserID: userID,
            occurredAt: now,
            valueNumber: 72.4
        )

        try await feedEvent.save(on: db)
        try await walkEvent.save(on: db)
        try await weightEvent.save(on: db)
    }

    func revert(on db: any Database) async throws {
        // Safe dev reset: wipe everything
        try await ActionEvent.query(on: db).delete()
        try await TrackableAction.query(on: db).delete()
        try await Entity.query(on: db).delete()
        try await NestMember.query(on: db).delete()
        try await Nest.query(on: db).delete()
        try await User.query(on: db).delete()
    }
}
