import Fluent
import NIOHTTP1
import Vapor

private let supportedPhotoContentTypes: Set<String> = [
    "image/jpeg",
    "image/jpg"
]

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
        createdAt: entity.createdAt,
        updatedAt: entity.updatedAt
    )
}

func registerPhotoRoutes(_ protected: any RoutesBuilder) {
    protected.put("entities", ":entityID", "photo") { req async throws -> EntityResponse in
        guard let storage = req.application.r2Storage else {
            throw Abort(.serviceUnavailable, reason: "Photo storage is not configured on the server")
        }

        let (entity, nestID) = try await editableEntity(for: req)
        let contentType = req.headers.contentType?.description.lowercased() ?? "image/jpeg"
        guard supportedPhotoContentTypes.contains(contentType) else {
            throw Abort(.unsupportedMediaType, reason: "Subject photos must be JPEG images")
        }
        guard let body = req.body.data, body.readableBytes > 0 else {
            throw Abort(.badRequest, reason: "The subject photo is empty")
        }

        let key = R2Storage.key(for: try entity.requireID())
        try await storage.put(key: key, body: body, contentType: contentType, logger: req.logger)
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
}
