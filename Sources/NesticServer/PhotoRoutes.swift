import Fluent
import NIOHTTP1
import Vapor

private let supportedPhotoContentTypes: Set<String> = [
    "image/jpeg",
    "image/jpg"
]

private struct HealthUpdateMetadata: Content {
    let capturedAt: String?
    let note: String?
}

private func healthUpdateDate(_ value: String?, onset: Date) throws -> Date {
    let date: Date
    if let value {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let parsed = formatter.date(from: value) {
            date = parsed
        } else {
            formatter.formatOptions = [.withInternetDateTime]
            guard let parsed = formatter.date(from: value) else {
                throw Abort(.badRequest, reason: "Choose a valid update time.")
            }
            date = parsed
        }
    } else {
        date = Date()
    }
    guard date >= onset else {
        throw Abort(.badRequest, reason: "A health update cannot be recorded before onset.")
    }
    guard date.timeIntervalSinceNow <= 300 else {
        throw Abort(.badRequest, reason: "A health update cannot be recorded in the future.")
    }
    return date
}

private func healthUpdateNote(_ value: String?, required: Bool) throws -> String? {
    let cleaned = value?.trimmingCharacters(in: .whitespacesAndNewlines)
    guard (cleaned?.count ?? 0) <= 2_000 else {
        throw Abort(.badRequest, reason: "Health update notes are limited to 2,000 characters")
    }
    if required && (cleaned?.isEmpty != false) {
        throw Abort(.badRequest, reason: "Add a note or choose a photo for this update")
    }
    return cleaned?.isEmpty == true ? nil : cleaned
}

private func editableEntity(for req: Request) async throws -> (Entity, UUID) {
    let session = try req.auth.require(SessionToken.self)
    let entityID = try req.parameters.require("entityID", as: UUID.self)

    guard let entity = try await Entity.find(entityID, on: req.db) else {
        throw Abort(.notFound, reason: "Entity not found")
    }

    let nestID = entity.$nest.id
    let isMember = try await NestMember.query(on: req.db)
        .filter(\.$role != .viewer)
        .filter(\.$nest.$id == nestID)
        .filter(\.$user.$id == session.userId)
        .first() != nil

    guard isMember else {
        throw Abort(.forbidden, reason: "A member, administrator, or owner role is required to change subject photos")
    }
    return (entity, nestID)
}

private func readableEntity(for req: Request) async throws -> Entity {
    let session = try req.auth.require(SessionToken.self)
    let entityID = try req.parameters.require("entityID", as: UUID.self)

    guard let entity = try await Entity.find(entityID, on: req.db) else {
        throw Abort(.notFound, reason: "Entity not found")
    }

    let isMember = try await NestMember.query(on: req.db)
        .filter(\.$nest.$id == entity.$nest.id)
        .filter(\.$user.$id == session.userId)
        .first() != nil

    guard isMember else {
        throw Abort(.forbidden, reason: "Not a member of this nest")
    }
    return entity
}

private func editableEvent(for req: Request) async throws -> (ActionEvent, UUID, UUID) {
    let session = try req.auth.require(SessionToken.self)
    let eventID = try req.parameters.require("eventID", as: UUID.self)
    guard let event = try await ActionEvent.find(eventID, on: req.db) else {
        throw Abort(.notFound, reason: "Activity not found")
    }

    let nestID = event.$nest.id
    guard let membership = try await NestMember.query(on: req.db)
        .filter(\.$nest.$id == nestID)
        .filter(\.$user.$id == session.userId)
        .first(), membership.role != .viewer,
        event.$actor.id == session.userId || membership.role == .admin || membership.role == .owner else {
        throw Abort(.forbidden, reason: "Only the person who logged this activity or a nest administrator can change its photo")
    }
    return (event, nestID, session.userId)
}

private func readableEvent(for req: Request) async throws -> ActionEvent {
    let session = try req.auth.require(SessionToken.self)
    let eventID = try req.parameters.require("eventID", as: UUID.self)
    guard let event = try await ActionEvent.find(eventID, on: req.db) else {
        throw Abort(.notFound, reason: "Activity not found")
    }
    guard try await NestMember.query(on: req.db)
        .filter(\.$nest.$id == event.$nest.id)
        .filter(\.$user.$id == session.userId)
        .first() != nil else {
        throw Abort(.forbidden, reason: "Not a member of this nest")
    }
    return event
}

private func entityResponse(for entity: Entity) throws -> EntityResponse {
    EntityResponse(
        id: try entity.requireID(),
        nestId: entity.$nest.id,
        kind: entity.kind,
        name: entity.name,
        tags: entity.tags,
        metadata: entity.metadata,
        birthday: entity.birthday,
        imageURL: entity.imageURL,
        pinnedActionIDs: [],
        createdAt: entity.createdAt,
        updatedAt: entity.updatedAt
    )
}

func registerPhotoRoutes(_ protected: any RoutesBuilder) {
    protected.put("entities", ":entityID", "photo") { req async throws -> EntityResponse in
        guard let storage = req.application.r2Storage else {
            throw Abort(.serviceUnavailable, reason: "Photo storage is not configured on the server")
        }

        let session = try req.auth.require(SessionToken.self)
        let (entity, nestID) = try await editableEntity(for: req)
        let contentType = req.headers.contentType?.description.lowercased() ?? "image/jpeg"
        guard supportedPhotoContentTypes.contains(contentType) else {
            throw Abort(.unsupportedMediaType, reason: "Subject photos must be JPEG images")
        }
        let maximumPhotoBytes = req.application.r2UsageLimiter.limits.maxUploadBytesPerPhoto
        if let contentLength = req.headers.first(name: .contentLength).flatMap(Int64.init),
           contentLength > maximumPhotoBytes {
            throw R2UsageLimitError.photoTooLarge(maxBytes: maximumPhotoBytes).abort
        }
        guard let body = req.body.data, body.readableBytes > 0 else {
            throw Abort(.badRequest, reason: "The subject photo is empty")
        }

        let key = R2Storage.key(for: try entity.requireID())
        let byteCount = Int64(body.readableBytes)
        do {
            try await req.application.r2UsageLimiter.reserveUpload(userID: session.userId, bytes: byteCount)
        } catch let error as R2UsageLimitError {
            throw error.abort
        }
        do {
            try await storage.put(key: key, body: body, contentType: contentType, logger: req.logger)
        } catch {
            await req.application.r2UsageLimiter.refundUpload(userID: session.userId, bytes: byteCount)
            throw error
        }
        entity.imageURL = R2Storage.reference(for: key)
        try await entity.save(on: req.db)

        let response = try entityResponse(for: entity)
        req.application.realtimeHub.broadcast(nestId: nestID, type: "entity.updated", data: response)
        return response
    }

    protected.get("entities", ":entityID", "photo") { req async throws -> Response in
        guard let storage = req.application.r2Storage else {
            throw Abort(.serviceUnavailable, reason: "Photo storage is not configured on the server")
        }

        let entity = try await readableEntity(for: req)
        guard let key = R2Storage.key(from: entity.imageURL) else {
            throw Abort(.notFound, reason: "This subject does not have a photo")
        }
        do {
            try await req.application.r2UsageLimiter.reserveRead(userID: try req.requireUserID())
        } catch let error as R2UsageLimitError {
            throw error.abort
        }
        guard let body = try await storage.get(key: key, logger: req.logger) else {
            throw Abort(.notFound, reason: "This subject photo is unavailable")
        }

        var headers = HTTPHeaders()
        headers.replaceOrAdd(name: .contentType, value: "image/jpeg")
        return Response(status: .ok, headers: headers, body: .init(buffer: body))
    }

    protected.delete("entities", ":entityID", "photo") { req async throws -> EntityResponse in
        guard let storage = req.application.r2Storage else {
            throw Abort(.serviceUnavailable, reason: "Photo storage is not configured on the server")
        }

        let (entity, nestID) = try await editableEntity(for: req)
        if let key = R2Storage.key(from: entity.imageURL) {
            try await storage.delete(key: key, logger: req.logger)
        }
        entity.imageURL = nil
        try await entity.save(on: req.db)

        let response = try entityResponse(for: entity)
        req.application.realtimeHub.broadcast(nestId: nestID, type: "entity.updated", data: response)
        return response
    }

    protected.put("events", ":eventID", "photo") { req async throws -> ActionEventResponse in
        guard let storage = req.application.r2Storage else {
            throw Abort(.serviceUnavailable, reason: "Photo storage is not configured on the server")
        }

        let (event, nestID, userID) = try await editableEvent(for: req)
        let contentType = req.headers.contentType?.description.lowercased() ?? "image/jpeg"
        guard supportedPhotoContentTypes.contains(contentType) else {
            throw Abort(.unsupportedMediaType, reason: "Event photos must be JPEG images")
        }
        let maximumPhotoBytes = req.application.r2UsageLimiter.limits.maxUploadBytesPerPhoto
        if let contentLength = req.headers.first(name: .contentLength).flatMap(Int64.init),
           contentLength > maximumPhotoBytes {
            throw R2UsageLimitError.photoTooLarge(maxBytes: maximumPhotoBytes).abort
        }
        guard let body = req.body.data, body.readableBytes > 0 else {
            throw Abort(.badRequest, reason: "The event photo is empty")
        }

        let eventID = try event.requireID()
        let key = R2Storage.key(forEventID: eventID)
        let byteCount = Int64(body.readableBytes)
        do {
            try await req.application.r2UsageLimiter.reserveUpload(userID: userID, bytes: byteCount)
        } catch let error as R2UsageLimitError {
            throw error.abort
        }
        do {
            try await storage.put(key: key, body: body, contentType: contentType, logger: req.logger)
        } catch {
            await req.application.r2UsageLimiter.refundUpload(userID: userID, bytes: byteCount)
            throw error
        }

        event.photoURL = R2Storage.reference(for: key)
        try await event.save(on: req.db)
        let response = try await event.response(on: req.db)
        req.application.realtimeHub.broadcast(nestId: nestID, type: "event.updated", data: response)
        return response
    }

    protected.get("events", ":eventID", "photo") { req async throws -> Response in
        guard let storage = req.application.r2Storage else {
            throw Abort(.serviceUnavailable, reason: "Photo storage is not configured on the server")
        }

        let event = try await readableEvent(for: req)
        guard let key = R2Storage.key(from: event.photoURL) else {
            throw Abort(.notFound, reason: "This activity does not have a photo")
        }
        do {
            try await req.application.r2UsageLimiter.reserveRead(userID: try req.requireUserID())
        } catch let error as R2UsageLimitError {
            throw error.abort
        }
        guard let body = try await storage.get(key: key, logger: req.logger) else {
            throw Abort(.notFound, reason: "This activity photo is unavailable")
        }

        var headers = HTTPHeaders()
        headers.replaceOrAdd(name: .contentType, value: "image/jpeg")
        return Response(status: .ok, headers: headers, body: .init(buffer: body))
    }

    protected.delete("events", ":eventID", "photo") { req async throws -> ActionEventResponse in
        guard let storage = req.application.r2Storage else {
            throw Abort(.serviceUnavailable, reason: "Photo storage is not configured on the server")
        }

        let (event, nestID, _) = try await editableEvent(for: req)
        if let key = R2Storage.key(from: event.photoURL) {
            try await storage.delete(key: key, logger: req.logger)
        }
        event.photoURL = nil
        try await event.save(on: req.db)
        let response = try await event.response(on: req.db)
        req.application.realtimeHub.broadcast(nestId: nestID, type: "event.updated", data: response)
        return response
    }

    protected.post("events", ":eventID", "photos") { req async throws -> ActionEventResponse in
        guard let storage = req.application.r2Storage else {
            throw Abort(.serviceUnavailable, reason: "Photo storage is not configured on the server")
        }

        let (event, nestID, userID) = try await editableEvent(for: req)
        guard let action = try await TrackableAction.find(event.$action.id, on: req.db), action.valueType == .health else {
            throw Abort(.badRequest, reason: "Only health events can have photo updates")
        }
        let metadata = (try? req.query.decode(HealthUpdateMetadata.self)) ?? HealthUpdateMetadata(capturedAt: nil, note: nil)
        let capturedAt = try healthUpdateDate(metadata.capturedAt, onset: event.occurredAt)
        let note = try healthUpdateNote(metadata.note, required: false)
        let contentType = req.headers.contentType?.description.lowercased() ?? "image/jpeg"
        guard supportedPhotoContentTypes.contains(contentType) else {
            throw Abort(.unsupportedMediaType, reason: "Health event photos must be JPEG images")
        }
        let maximumPhotoBytes = req.application.r2UsageLimiter.limits.maxUploadBytesPerPhoto
        if let contentLength = req.headers.first(name: .contentLength).flatMap(Int64.init),
           contentLength > maximumPhotoBytes {
            throw R2UsageLimitError.photoTooLarge(maxBytes: maximumPhotoBytes).abort
        }
        guard let body = req.body.data, body.readableBytes > 0 else {
            throw Abort(.badRequest, reason: "The health event photo is empty")
        }

        let photoID = UUID()
        let key = R2Storage.key(forEventPhotoID: photoID)
        let byteCount = Int64(body.readableBytes)
        do {
            try await req.application.r2UsageLimiter.reserveUpload(userID: userID, bytes: byteCount)
        } catch let error as R2UsageLimitError {
            throw error.abort
        }
        do {
            try await storage.put(key: key, body: body, contentType: contentType, logger: req.logger)
            let photo = ActionEventPhoto(id: photoID, eventID: try event.requireID(), actorUserID: userID,
                                         capturedAt: capturedAt, photoURL: R2Storage.reference(for: key), note: note)
            try await photo.save(on: req.db)
        } catch {
            await req.application.r2UsageLimiter.refundUpload(userID: userID, bytes: byteCount)
            try? await storage.delete(key: key, logger: req.logger)
            throw error
        }

        let response = try await event.response(on: req.db)
        req.application.realtimeHub.broadcast(nestId: nestID, type: "event.updated", data: response)
        return response
    }

    protected.post("events", ":eventID", "updates") { req async throws -> ActionEventResponse in
        let (event, nestID, userID) = try await editableEvent(for: req)
        guard let action = try await TrackableAction.find(event.$action.id, on: req.db), action.valueType == .health else {
            throw Abort(.badRequest, reason: "Only health events can have text updates")
        }
        let input = try req.content.decode(HealthUpdateMetadata.self)
        let capturedAt = try healthUpdateDate(input.capturedAt, onset: event.occurredAt)
        guard let note = try healthUpdateNote(input.note, required: true) else {
            throw Abort(.badRequest, reason: "Add a note for this update")
        }

        let update = ActionEventPhoto(id: UUID(), eventID: try event.requireID(), actorUserID: userID,
                                      capturedAt: capturedAt, photoURL: "", note: note)
        try await update.save(on: req.db)
        let response = try await event.response(on: req.db)
        req.application.realtimeHub.broadcast(nestId: nestID, type: "event.updated", data: response)
        return response
    }

    protected.get("events", ":eventID", "photos", ":photoID") { req async throws -> Response in
        guard let storage = req.application.r2Storage else {
            throw Abort(.serviceUnavailable, reason: "Photo storage is not configured on the server")
        }

        let event = try await readableEvent(for: req)
        guard let action = try await TrackableAction.find(event.$action.id, on: req.db), action.valueType == .health else {
            throw Abort(.badRequest, reason: "Only health events have photo updates")
        }
        let photoID = try req.parameters.require("photoID", as: UUID.self)
        guard let photo = try await ActionEventPhoto.find(photoID, on: req.db),
              photo.$event.id == event.id,
              let key = R2Storage.key(from: photo.photoURL) else {
            throw Abort(.notFound, reason: "Health event photo not found")
        }
        do {
            try await req.application.r2UsageLimiter.reserveRead(userID: try req.requireUserID())
        } catch let error as R2UsageLimitError {
            throw error.abort
        }
        guard let body = try await storage.get(key: key, logger: req.logger) else {
            throw Abort(.notFound, reason: "This health event photo is unavailable")
        }

        var headers = HTTPHeaders()
        headers.replaceOrAdd(name: .contentType, value: "image/jpeg")
        return Response(status: .ok, headers: headers, body: .init(buffer: body))
    }

    protected.delete("events", ":eventID", "photos", ":photoID") { req async throws -> ActionEventResponse in
        guard let storage = req.application.r2Storage else {
            throw Abort(.serviceUnavailable, reason: "Photo storage is not configured on the server")
        }

        let (event, nestID, _) = try await editableEvent(for: req)
        guard let action = try await TrackableAction.find(event.$action.id, on: req.db), action.valueType == .health else {
            throw Abort(.badRequest, reason: "Only health events have photo updates")
        }
        let photoID = try req.parameters.require("photoID", as: UUID.self)
        guard let photo = try await ActionEventPhoto.find(photoID, on: req.db),
              photo.$event.id == event.id else {
            throw Abort(.notFound, reason: "Health event photo not found")
        }
        if let key = R2Storage.key(from: photo.photoURL) {
            try? await storage.delete(key: key, logger: req.logger)
        }
        try await photo.delete(on: req.db)
        let response = try await event.response(on: req.db)
        req.application.realtimeHub.broadcast(nestId: nestID, type: "event.updated", data: response)
        return response
    }
}
