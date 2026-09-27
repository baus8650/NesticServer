import Fluent
import Vapor
import JWT
import NIOConcurrencyHelpers
// MARK: - Realtime (WebSockets)

/// Client -> Server messages
struct WSClientMessage: Content {
    let type: String
    let nestId: UUID?
}

/// Server -> Client envelope
struct WSEnvelope<T: Content>: Content {
    let v: Int
    let type: String
    let nestId: UUID
    let ts: Date
    let data: T
}

struct WSAck: Content {
    let message: String
}

/// Simple hub that tracks WebSocket connections per nest and broadcasts messages.
final class RealtimeHub: @unchecked Sendable {
    private let lock = NIOLock()
    private struct Connection { let socket: WebSocket; let userId: UUID }
    private var socketsByNest: [UUID: [ObjectIdentifier: Connection]] = [:]

    func add(_ ws: WebSocket, to nestId: UUID, userId: UUID) {
        let key = ObjectIdentifier(ws)
        lock.withLock {
            var bucket = socketsByNest[nestId] ?? [:]
            bucket[key] = Connection(socket: ws, userId: userId)
            socketsByNest[nestId] = bucket
        }

        // Ensure we clean up when the socket closes.
        ws.onClose.whenComplete { [weak self, weak ws] _ in
            guard let self, let ws else { return }
            self.remove(ws, from: nestId)
        }
    }

    func remove(_ ws: WebSocket, from nestId: UUID) {
        let key = ObjectIdentifier(ws)
        lock.withLock {
            guard var bucket = socketsByNest[nestId] else { return }
            bucket.removeValue(forKey: key)
            if bucket.isEmpty {
                socketsByNest.removeValue(forKey: nestId)
            } else {
                socketsByNest[nestId] = bucket
            }
        }
    }

    /// A removed member must stop receiving future private nest updates immediately.
    func disconnect(userId: UUID, nestId: UUID) {
        let removed: [WebSocket] = lock.withLock {
            guard var bucket = socketsByNest[nestId] else { return [] }
            let matches = bucket.filter { $0.value.userId == userId }
            for key in matches.keys { bucket.removeValue(forKey: key) }
            socketsByNest[nestId] = bucket.isEmpty ? nil : bucket
            return matches.values.map(\.socket)
        }
        for ws in removed { ws.eventLoop.execute { ws.close(promise: nil) } }
    }

    func broadcast<T: Content>(nestId: UUID, type: String, data: T) {
        let sockets: [WebSocket] = lock.withLock {
            Array((socketsByNest[nestId] ?? [:]).values).map(\.socket)
        }

        guard !sockets.isEmpty else { return }

        let payload = WSEnvelope(v: 1, type: type, nestId: nestId, ts: Date(), data: data)

        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601

            let encoded = try encoder.encode(payload)
            guard let text = String(data: encoded, encoding: .utf8) else { return }

            for ws in sockets {
                ws.eventLoop.execute {
                    ws.send(text)
                }
            }
        } catch {
            // best-effort
        }
    }
}

extension Application {
    private struct RealtimeHubKey: StorageKey {
        typealias Value = RealtimeHub
    }

    var realtimeHub: RealtimeHub {
        if let existing = storage[RealtimeHubKey.self] { return existing }
        let hub = RealtimeHub()
        storage[RealtimeHubKey.self] = hub
        return hub
    }
}

// MARK: - DTOs
struct NestResponse: Content {
    let id: UUID
    let name: String
    let createdAt: Date?
    let updatedAt: Date?
}

struct EntityResponse: Content {
    let id: UUID
    let nestId: UUID
    let kind: EntityKind
    let name: String
    let tags: [String]
    let metadata: [String: String]?
    let birthday: Date?
    let imageURL: String?
    let createdAt: Date?
    let updatedAt: Date?
}

struct TrackableActionResponse: Content {
    let id: UUID
    let nestId: UUID
    let name: String
    let valueType: ActionValueType
    let unit: String?
    let symbol: String?
    let color: String?
    let groupName: String?
    let description: String?
    let createdAt: Date?
    let updatedAt: Date?
}

struct ActionEventResponse: Content {
    let id: UUID
    let nestId: UUID
    let entityId: UUID
    let actionId: UUID
    let actorUserId: UUID?
    let occurredAt: Date
    let valueNumber: Double?
    let valueText: String?
    let valueBool: Bool?
    let valueJSON: [String: String]?
    let note: String?
}

struct UpdateEventRequest: Content {
    let occurredAt: Date
    let valueNumber: Double?
    let valueText: String?
    let valueBool: Bool?
    let valueJSON: [String: String]?
    let note: String?
}

struct MemberResponse: Content {
    let userId: UUID
    let email: String
    let displayName: String
    let role: NestRole
    let createdAt: Date?
}

struct EntityDeletedResponse: Content {
    let id: UUID
    let nestId: UUID
}

struct ActionDeletedResponse: Content {
    let id: UUID
    let nestId: UUID
}

struct MemberDeletedResponse: Content {
    let userId: UUID
    let nestId: UUID
}

struct PinnedActionsUpdatedResponse: Content {
    let entityId: UUID
    let nestId: UUID
    let actionIds: [UUID]
}

struct PinnedActionDTO: Content {
    let actionId: UUID
    let name: String
    let valueType: ActionValueType
    let unit: String?
    let symbol: String?
    let color: String?
    let sortOrder: Int
}


struct SetPinnedActionsRequest: Content {
    let actionIds: [UUID]
}

struct LastEventSummaryDTO: Content {
    let eventId: UUID
    let occurredAt: Date
    let valueNumber: Double?
    let valueText: String?
    let valueBool: Bool?
    let valueJSON: [String: String]?
    let note: String?
}

struct PinnedActionSummaryDTO: Content {
    let actionId: UUID
    let actionName: String
    let valueType: ActionValueType
    let unit: String?
    let symbol: String?
    let color: String?
    let sortOrder: Int
    let last: LastEventSummaryDTO?
}

struct EntitySummaryDTO: Content {
    let entityId: UUID
    let name: String
    let kind: EntityKind
    let birthday: Date?
    let imageURL: String?
    let pinned: [PinnedActionSummaryDTO]
}

private func eventCursorDate(from req: Request) -> Date? {
    guard let raw = try? req.query.get(String.self, at: "before") else { return nil }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: raw) { return date }
    formatter.formatOptions = [.withInternetDateTime]
    if let date = formatter.date(from: raw) { return date }
    if let seconds = Double(raw) { return Date(timeIntervalSince1970: seconds) }
    return nil
}

func routes(_ app: Application) throws {
    let protected = app.grouped(SessionToken.authenticator(), SessionToken.guardMiddleware())
    try authRoutes(app)
    registerPhotoRoutes(protected)

    app.get { req async in
        "It works!"
    }

    app.get("hello") { req async -> String in
        "Hello, world!"
    }

    app.get("health") { _ in
        return ["status": "ok"]
    }

    // Authenticate before upgrading so the first subscribe message cannot race JWT verification.
    app.webSocket("ws", shouldUpgrade: { req in
        req.eventLoop.makeFutureWithTask {
            guard let token = req.headers.bearerAuthorization?.token
                    ?? (try? req.query.get(String.self, at: "token")) else { return nil }
            guard let session = try? await req.application.jwt.keys.verify(token, as: SessionToken.self),
                  try await User.find(session.userId, on: req.db) != nil else { return nil }
            req.auth.login(session)
            return HTTPHeaders()
        }
    }, onUpgrade: { req, ws in
        guard let session = req.auth.get(SessionToken.self) else {
            ws.close(promise: nil)
            return
        }
        let subscribedNestId = NIOLockedValueBox<UUID?>(nil)
        let subscriptionRevision = NIOLockedValueBox<Int>(0)
        let expiry = ws.eventLoop.scheduleTask(in: .seconds(Int64(max(0, session.expiration.value.timeIntervalSinceNow)))) {
            ws.close(promise: nil)
        }
        ws.onClose.whenComplete { _ in
            expiry.cancel()
            if let nid = subscribedNestId.withLockedValue({ $0 }) {
                req.application.realtimeHub.remove(ws, from: nid)
            }
        }
        ws.onText { ws, text in
            guard let msg = try? JSONDecoder().decode(WSClientMessage.self, from: Data(text.utf8)),
                  msg.type == "subscribe", let nestId = msg.nestId else {
                ws.send("{\"error\":true,\"reason\":\"Send a subscribe message with nestId\"}")
                return
            }
            let revision = subscriptionRevision.withLockedValue { $0 += 1; return $0 }
            Task {
                do {
                    let membership = try await NestMember.query(on: req.db)
                        .filter(\.$nest.$id == nestId)
                        .filter(\.$user.$id == session.userId).first()
                    guard membership != nil else {
                        ws.send("{\"error\":true,\"reason\":\"Not a member of this nest\"}", promise: nil)
                        return
                    }
                    ws.eventLoop.execute {
                        guard !ws.isClosed, revision == subscriptionRevision.withLockedValue({ $0 }) else { return }
                        let old = subscribedNestId.withLockedValue { current -> UUID? in
                            let old = current; current = nestId; return old
                        }
                        if let old, old != nestId { req.application.realtimeHub.remove(ws, from: old) }
                        req.application.realtimeHub.add(ws, to: nestId, userId: session.userId)
                        let ack = WSEnvelope(v: 1, type: "ws.subscribed", nestId: nestId, ts: Date(), data: WSAck(message: "subscribed"))
                        let encoder = JSONEncoder()
                        encoder.dateEncodingStrategy = .iso8601
                        if let data = try? encoder.encode(ack), let text = String(data: data, encoding: .utf8) { ws.send(text) }
                    }
                } catch {
                    ws.send("{\"error\":true,\"reason\":\"Subscription failed\"}", promise: nil)
                }
            }
        }
        ws.send("{\"type\":\"ws.ready\"}")
    })

    // MARK: - Nest API

    protected.get("nests") { req async throws -> [NestResponse] in
        let session = try req.auth.require(SessionToken.self)

        let nests = try await Nest.query(on: req.db)
            .join(NestMember.self, on: \Nest.$id == \NestMember.$nest.$id)
            .filter(NestMember.self, \.$user.$id == session.userId)
            .all()

        return nests.compactMap { n in
            guard let id = n.id else { return nil }
            return NestResponse(id: id, name: n.name, createdAt: n.createdAt, updatedAt: n.updatedAt)
        }
    }

    protected.post("nests") { req async throws -> NestResponse in
        let session = try req.auth.require(SessionToken.self)

        struct CreateNestRequest: Content {
            let name: String
        }

        let input = try req.content.decode(CreateNestRequest.self)
        let nest = Nest(name: try InputValidation.name(input.name, field: "Nest name"))
        try await req.db.transaction { tx in
            try await nest.save(on: tx)
            let ownerMembership = NestMember(nestID: try nest.requireID(), userID: session.userId, role: .owner)
            try await ownerMembership.save(on: tx)
        }

        return NestResponse(id: try nest.requireID(), name: nest.name, createdAt: nest.createdAt, updatedAt: nest.updatedAt)
    }

    // MARK: - Nest Membership API

    // List members (any authenticated member of the nest)
    protected.get("nests", ":nestID", "members") { req async throws -> [MemberResponse] in
        let session = try req.auth.require(SessionToken.self)
        let nestID = try req.parameters.require("nestID", as: UUID.self)

        // Must be a member of the nest
        let isMember = try await NestMember.query(on: req.db)
            .filter(\.$nest.$id == nestID)
            .filter(\.$user.$id == session.userId)
            .first() != nil

        guard isMember else {
            throw Abort(.forbidden, reason: "Not a member of this nest")
        }

        let memberships = try await NestMember.query(on: req.db)
            .filter(\.$nest.$id == nestID)
            .with(\.$user)
            .all()

        return memberships.map { m in
            let uid = m.$user.id
            return MemberResponse(
                userId: uid,
                email: m.user.email,
                displayName: m.user.displayName,
                role: m.role,
                createdAt: m.createdAt
            )
        }
    }

    // Add member (owner/admin only)
    protected.post("nests", ":nestID", "members") { req async throws -> MemberResponse in
        let session = try req.auth.require(SessionToken.self)
        let nestID = try req.parameters.require("nestID", as: UUID.self)

        guard try await Nest.find(nestID, on: req.db) != nil else {
            throw Abort(.notFound, reason: "Nest not found")
        }

        // Must be owner/admin to add members
        let isOwnerOrAdmin = try await NestMember.query(on: req.db)
            .filter(\.$nest.$id == nestID)
            .filter(\.$user.$id == session.userId)
            .group(.or) { q in
                q.filter(\.$role == .owner)
                q.filter(\.$role == .admin)
            }
            .first() != nil

        guard isOwnerOrAdmin else {
            throw Abort(.forbidden, reason: "Owner or admin role required")
        }

        struct AddMemberRequest: Content {
            let email: String
            let role: NestRole
        }

        let input = try req.content.decode(AddMemberRequest.self)
        if input.role == .owner || input.role == .admin {
            let owner = try await NestMember.query(on: req.db)
                .filter(\.$nest.$id == nestID).filter(\.$user.$id == session.userId)
                .filter(\.$role == .owner).first()
            guard owner != nil else { throw Abort(.forbidden, reason: "Only an owner can add owners or administrators") }
        }

        guard let user = try await User.query(on: req.db)
            .filter(\.$email == (try InputValidation.email(input.email)))
            .first() else {
            throw Abort(.notFound, reason: "User not found")
        }

        let userID = try user.requireID()

        // If already a member, return conflict
        let existing = try await NestMember.query(on: req.db)
            .filter(\.$nest.$id == nestID)
            .filter(\.$user.$id == userID)
            .first()

        guard existing == nil else {
            throw Abort(.conflict, reason: "User is already a member of this nest")
        }

        let membership = NestMember(nestID: nestID, userID: userID, role: input.role)
        do { try await membership.save(on: req.db) }
        catch let error as any DatabaseError where error.isConstraintFailure {
            throw Abort(.conflict, reason: "User is already a member of this nest")
        }

        let response = MemberResponse(
            userId: userID,
            email: user.email,
            displayName: user.displayName,
            role: membership.role,
            createdAt: membership.createdAt
        )

        req.application.realtimeHub.broadcast(
            nestId: nestID,
            type: "member.created",
            data: response
        )

        return response
    }

    // Update member role (owner only)
    protected.patch("nests", ":nestID", "members", ":userID") { req async throws -> MemberResponse in
        let session = try req.auth.require(SessionToken.self)
        let nestID = try req.parameters.require("nestID", as: UUID.self)
        let targetUserID = try req.parameters.require("userID", as: UUID.self)

        // Must be owner to change roles
        let isOwner = try await NestMember.query(on: req.db)
            .filter(\.$nest.$id == nestID)
            .filter(\.$user.$id == session.userId)
            .filter(\.$role == .owner)
            .first() != nil

        guard isOwner else {
            throw Abort(.forbidden, reason: "Owner role required")
        }

        struct UpdateMemberRoleRequest: Content {
            let role: NestRole
        }

        let input = try req.content.decode(UpdateMemberRoleRequest.self)

        guard let membership = try await NestMember.query(on: req.db)
            .filter(\.$nest.$id == nestID)
            .filter(\.$user.$id == targetUserID)
            .first() else {
            throw Abort(.notFound, reason: "Membership not found")
        }

        guard let user = try await User.find(targetUserID, on: req.db) else {
            throw Abort(.notFound, reason: "User not found")
        }

        // Prevent demoting the last owner
        if membership.role == .owner && input.role != .owner {
            let ownerCount = try await NestMember.query(on: req.db)
                .filter(\.$nest.$id == nestID)
                .filter(\.$role == .owner)
                .count()
            if ownerCount <= 1 {
                throw Abort(.badRequest, reason: "A nest must have at least one owner")
            }
        }

        membership.role = input.role
        try await membership.save(on: req.db)

        let response = MemberResponse(
            userId: targetUserID,
            email: user.email,
            displayName: user.displayName,
            role: membership.role,
            createdAt: membership.createdAt
        )

        req.application.realtimeHub.broadcast(
            nestId: nestID,
            type: "member.updated",
            data: response
        )

        return response
    }

    // Remove member (owner only)
    protected.delete("nests", ":nestID", "members", ":userID") { req async throws -> HTTPStatus in
        let session = try req.auth.require(SessionToken.self)
        let nestID = try req.parameters.require("nestID", as: UUID.self)
        let targetUserID = try req.parameters.require("userID", as: UUID.self)

        // Must be owner to remove members
        let isOwner = try await NestMember.query(on: req.db)
            .filter(\.$nest.$id == nestID)
            .filter(\.$user.$id == session.userId)
            .filter(\.$role == .owner)
            .first() != nil

        guard isOwner else {
            throw Abort(.forbidden, reason: "Owner role required")
        }

        guard let membership = try await NestMember.query(on: req.db)
            .filter(\.$nest.$id == nestID)
            .filter(\.$user.$id == targetUserID)
            .first() else {
            throw Abort(.notFound, reason: "Membership not found")
        }

        // Prevent removing the last owner
        if membership.role == .owner {
            let ownerCount = try await NestMember.query(on: req.db)
                .filter(\.$nest.$id == nestID)
                .filter(\.$role == .owner)
                .count()
            if ownerCount <= 1 {
                throw Abort(.badRequest, reason: "A nest must have at least one owner")
            }
        }

        let deletedResponse = MemberDeletedResponse(
            userId: targetUserID,
            nestId: nestID
        )

        try await membership.delete(on: req.db)
        req.application.realtimeHub.disconnect(userId: targetUserID, nestId: nestID)
        req.application.realtimeHub.broadcast(
            nestId: nestID,
            type: "member.deleted",
            data: deletedResponse
        )
        return .noContent
    }

    // MARK: - Entity API (under a Nest)


    protected.get("nests", ":nestID", "entities") { req async throws -> [EntityResponse] in
        let session = try req.auth.require(SessionToken.self)
        let nestID = try req.parameters.require("nestID", as: UUID.self)

        // Must be a member of the nest
        let isMember = try await NestMember.query(on: req.db)
            .filter(\.$nest.$id == nestID)
            .filter(\.$user.$id == session.userId)
            .first() != nil

        guard isMember else {
            throw Abort(.forbidden, reason: "Not a member of this nest")
        }

        let entities = try await Entity.query(on: req.db)
            .filter(\.$nest.$id == nestID)
            .all()

        return entities.compactMap { e in
            guard let id = e.id else { return nil }
            return EntityResponse(
                id: id,
                nestId: e.$nest.id,
                kind: e.kind,
                name: e.name,
                tags: e.tags,
                metadata: e.metadata,
                birthday: e.birthday,
                imageURL: e.imageURL,
                createdAt: e.createdAt,
                updatedAt: e.updatedAt
            )
        }
    }

    // Summary for home screen: entities + pinned actions + last event per pinned action
    protected.get("nests", ":nestID", "entities", "summary") { req async throws -> [EntitySummaryDTO] in
        let session = try req.auth.require(SessionToken.self)
        let nestID = try req.parameters.require("nestID", as: UUID.self)

        // Must be a member of the nest
        let isMember = try await NestMember.query(on: req.db)
            .filter(\.$nest.$id == nestID)
            .filter(\.$user.$id == session.userId)
            .first() != nil

        guard isMember else {
            throw Abort(.forbidden, reason: "Not a member of this nest")
        }

        // 1) Fetch all entities in the nest
        let entities = try await Entity.query(on: req.db)
            .filter(\.$nest.$id == nestID)
            .all()

        if entities.isEmpty {
            return []
        }

        let entityIDs: [UUID] = entities.compactMap { $0.id }

        // 2) Fetch pinned actions for those entities (includes action details)
        let pins = try await EntityPinnedAction.query(on: req.db)
            .filter(\.$entity.$id ~~ entityIDs)
            .with(\.$action)
            .sort(\.$sortOrder, .ascending)
            .all()

        let pinnedActionIDs: [UUID] = Array(Set(pins.map { $0.$action.id }))

        // 3) Fetch events in the nest for those entities + pinned actions, newest first
        //    Then reduce to the latest event per (entityID, actionID)
        var latestByEntityAndAction: [String: ActionEvent] = [:]

        if !pinnedActionIDs.isEmpty {
            let events = try await ActionEvent.query(on: req.db)
                .filter(\.$nest.$id == nestID)
                .filter(\.$entity.$id ~~ entityIDs)
                .filter(\.$action.$id ~~ pinnedActionIDs)
                .sort(\.$occurredAt, .descending)
                .all()

            for e in events {
                let key = "\(e.$entity.id.uuidString)|\(e.$action.id.uuidString)"
                if latestByEntityAndAction[key] == nil {
                    latestByEntityAndAction[key] = e
                }
            }
        }

        // Group pins by entity
        var pinsByEntity: [UUID: [EntityPinnedAction]] = [:]
        for p in pins {
            pinsByEntity[p.$entity.id, default: []].append(p)
        }

        // Build summary DTOs
        return entities.compactMap { entity in
            guard let entityID = entity.id else { return nil }

            let entityPins = (pinsByEntity[entityID] ?? []).sorted { $0.sortOrder < $1.sortOrder }

            let pinnedSummaries: [PinnedActionSummaryDTO] = entityPins.map { pin in
                let actionID = pin.$action.id
                let key = "\(entityID.uuidString)|\(actionID.uuidString)"

                let lastDTO: LastEventSummaryDTO?
                if let last = latestByEntityAndAction[key] {
                    lastDTO = LastEventSummaryDTO(
                        eventId: last.id ?? UUID(),
                        occurredAt: last.occurredAt,
                        valueNumber: last.valueNumber,
                        valueText: last.valueText,
                        valueBool: last.valueBool,
                        valueJSON: last.valueJSON,
                        note: last.note
                    )
                } else {
                    lastDTO = nil
                }

                return PinnedActionSummaryDTO(
                    actionId: actionID,
                    actionName: pin.action.name,
                    valueType: pin.action.valueType,
                    unit: pin.action.unit,
                    symbol: pin.action.symbol,
                    color: pin.action.color,
                    sortOrder: pin.sortOrder,
                    last: lastDTO
                )
            }

            return EntitySummaryDTO(
                entityId: entityID,
                name: entity.name,
                kind: entity.kind,
                birthday: entity.birthday,
                imageURL: entity.imageURL,
                pinned: pinnedSummaries
            )
        }
    }

    protected.post("nests", ":nestID", "entities") { req async throws -> EntityResponse in
        let session = try req.auth.require(SessionToken.self)
        let nestID = try req.parameters.require("nestID", as: UUID.self)

        // Verify the nest exists
        guard try await Nest.find(nestID, on: req.db) != nil else {
            throw Abort(.notFound, reason: "Nest not found")
        }

        // Must be a member of the nest
        let isMember = try await NestMember.query(on: req.db)
            .filter(\.$role != .viewer)
            .filter(\.$nest.$id == nestID)
            .filter(\.$user.$id == session.userId)
            .first() != nil

        guard isMember else {
            throw Abort(.forbidden, reason: "A member, administrator, or owner role is required to make changes")
        }

        struct CreateEntityRequest: Content {
            let kind: EntityKind          // "person" | "pet" | "thing" | "custom"
            let name: String
            let tags: [String]?
            let metadata: [String: String]?
            let birthday: Date?
            let imageURL: String?
        }

        let input = try req.content.decode(CreateEntityRequest.self)

        let entity = Entity(
            nestID: nestID,
            kind: input.kind,
            name: try InputValidation.name(input.name),
            tags: input.tags ?? [],
            metadata: input.metadata,
            birthday: input.birthday,
            imageURL: input.imageURL
        )

        try await entity.save(on: req.db)
        let response = EntityResponse(
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

        req.application.realtimeHub.broadcast(
            nestId: nestID,
            type: "entity.created",
            data: response
        )

        return response
    }

    // Update entity (name/tags/metadata/birthday/imageURL) — must be a member of the entity's nest
    protected.patch("entities", ":entityID") { req async throws -> EntityResponse in
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
            throw Abort(.forbidden, reason: "A member, administrator, or owner role is required to make changes")
        }

        struct UpdateEntityRequest: Content {
            let kind: EntityKind?
            let name: String?
            let tags: [String]?
            let metadata: [String: String]?
            let birthday: Date?
            let imageURL: String?
        }

        let input = try req.content.decode(UpdateEntityRequest.self)

        if let kind = input.kind { entity.kind = kind }
        if let name = input.name { entity.name = try InputValidation.name(name) }
        if let tags = input.tags { entity.tags = tags }
        // metadata may legitimately be set to nil: allow explicit null by using a dedicated endpoint later.
        if let metadata = input.metadata { entity.metadata = metadata }
        if let birthday = input.birthday { entity.birthday = birthday }
        if let imageURL = input.imageURL { entity.imageURL = imageURL }

        try await entity.save(on: req.db)

        let response = EntityResponse(
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

        req.application.realtimeHub.broadcast(
            nestId: nestID,
            type: "entity.updated",
            data: response
        )

        return response
    }

    // Delete entity — must be a member of the entity's nest
    protected.delete("entities", ":entityID") { req async throws -> HTTPStatus in
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
            throw Abort(.forbidden, reason: "A member, administrator, or owner role is required to make changes")
        }

        let deletedResponse = EntityDeletedResponse(
            id: entityID,
            nestId: nestID
        )

        // Cascade-delete related rows
        try await req.db.transaction { tx in
            try await EntityPinnedAction.query(on: tx)
                .filter(\.$entity.$id == entityID)
                .delete()

            try await ActionEvent.query(on: tx)
                .filter(\.$entity.$id == entityID)
                .delete()

            try await entity.delete(on: tx)
        }

        if let key = R2Storage.key(from: entity.imageURL),
           let storage = req.application.r2Storage {
            try? await storage.delete(key: key, logger: req.logger)
        }

        req.application.realtimeHub.broadcast(
            nestId: nestID,
            type: "entity.deleted",
            data: deletedResponse
        )
        return .noContent
    }

    // MARK: - Trackable Actions API (under a Nest)

    protected.get("nests", ":nestID", "actions") { req async throws -> [TrackableActionResponse] in
        let session = try req.auth.require(SessionToken.self)
        let nestID = try req.parameters.require("nestID", as: UUID.self)

        // Must be a member of the nest
        let isMember = try await NestMember.query(on: req.db)
            .filter(\.$nest.$id == nestID)
            .filter(\.$user.$id == session.userId)
            .first() != nil

        guard isMember else {
            throw Abort(.forbidden, reason: "Not a member of this nest")
        }

        let actions = try await TrackableAction.query(on: req.db)
            .filter(\.$nest.$id == nestID)
            .all()

        return actions.compactMap { a in
            guard let id = a.id else { return nil }
            return TrackableActionResponse(
                id: id,
                nestId: a.$nest.id,
                name: a.name,
                valueType: a.valueType,
                unit: a.unit,
                symbol: a.symbol,
                color: a.color,
                groupName: a.groupName,
                description: a.description,
                createdAt: a.createdAt,
                updatedAt: a.updatedAt
            )
        }
    }

    protected.post("nests", ":nestID", "actions") { req async throws -> TrackableActionResponse in
        let session = try req.auth.require(SessionToken.self)
        let nestID = try req.parameters.require("nestID", as: UUID.self)

        guard try await Nest.find(nestID, on: req.db) != nil else {
            throw Abort(.notFound, reason: "Nest not found")
        }

        // Must be owner/admin to define actions
        let isOwnerOrAdmin = try await NestMember.query(on: req.db)
            .filter(\.$nest.$id == nestID)
            .filter(\.$user.$id == session.userId)
            .group(.or) { q in
                q.filter(\.$role == .owner)
                q.filter(\.$role == .admin)
            }
            .first() != nil

        guard isOwnerOrAdmin else {
            throw Abort(.forbidden, reason: "Owner or admin role required")
        }

        struct CreateActionRequest: Content {
            let name: String
            let valueType: ActionValueType   // none/number/text/boolean/json
            let unit: String?
            let symbol: String?
            let color: String?
            let groupName: String?
            let description: String?
        }

        let input = try req.content.decode(CreateActionRequest.self)
        let symbol = try InputValidation.trackerSymbol(input.symbol)
        let color = try InputValidation.trackerColor(input.color)
        let groupName = input.groupName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? input.groupName?.trimmingCharacters(in: .whitespacesAndNewlines)
            : nil

        let action = TrackableAction(
            nestID: nestID,
            name: try InputValidation.name(input.name),
            valueType: input.valueType,
            unit: input.unit,
            symbol: symbol,
            color: color,
            groupName: groupName,
            description: input.description
        )

        do { try await action.save(on: req.db) }
        catch let error as any DatabaseError where error.isConstraintFailure {
            throw Abort(.conflict, reason: "A tracker with this name already exists in the nest.")
        }
        let response = TrackableActionResponse(
            id: try action.requireID(),
            nestId: action.$nest.id,
            name: action.name,
            valueType: action.valueType,
            unit: action.unit,
            symbol: action.symbol,
            color: action.color,
            groupName: action.groupName,
            description: action.description,
            createdAt: action.createdAt,
            updatedAt: action.updatedAt
        )

        req.application.realtimeHub.broadcast(
            nestId: nestID,
            type: "action.created",
            data: response
        )

        return response
    }

    // Edit a tracker. Existing events retain their recorded values; only the tracker metadata changes.
    protected.patch("actions", ":actionID") { req async throws -> TrackableActionResponse in
        let session = try req.auth.require(SessionToken.self)
        let actionID = try req.parameters.require("actionID", as: UUID.self)
        guard let action = try await TrackableAction.find(actionID, on: req.db) else {
            throw Abort(.notFound, reason: "Tracker not found")
        }
        let nestID = action.$nest.id
        let canManage = try await NestMember.query(on: req.db)
            .filter(\.$nest.$id == nestID)
            .filter(\.$user.$id == session.userId)
            .group(.or) { q in
                q.filter(\.$role == .owner)
                q.filter(\.$role == .admin)
            }
            .first() != nil
        guard canManage else { throw Abort(.forbidden, reason: "Owner or admin role required") }

        struct UpdateActionRequest: Content {
            let name: String?
            let valueType: ActionValueType?
            let unit: String?
            let symbol: String?
            let color: String?
            let groupName: String?
            let description: String?
        }
        let input = try req.content.decode(UpdateActionRequest.self)
        if let name = input.name { action.name = try InputValidation.name(name) }
        if let valueType = input.valueType { action.valueType = valueType }
        action.unit = input.unit?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? input.unit : nil
        if action.valueType != .number { action.unit = nil }
        if let symbol = input.symbol { action.symbol = try InputValidation.trackerSymbol(symbol) }
        if let color = input.color { action.color = try InputValidation.trackerColor(color) }
        let trimmedGroupName = input.groupName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        action.groupName = trimmedGroupName.isEmpty ? nil : trimmedGroupName
        if let description = input.description { action.description = description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : description }
        try await action.save(on: req.db)

        let response = TrackableActionResponse(id: try action.requireID(), nestId: nestID, name: action.name,
                                               valueType: action.valueType, unit: action.unit,
                                               symbol: action.symbol,
                                               color: action.color,
                                               groupName: action.groupName,
                                               description: action.description, createdAt: action.createdAt,
                                               updatedAt: action.updatedAt)
        req.application.realtimeHub.broadcast(nestId: nestID, type: "action.updated", data: response)
        return response
    }

    // Delete a tracker and its quick-action pins and history in one transaction.
    protected.delete("actions", ":actionID") { req async throws -> HTTPStatus in
        let session = try req.auth.require(SessionToken.self)
        let actionID = try req.parameters.require("actionID", as: UUID.self)
        guard let action = try await TrackableAction.find(actionID, on: req.db) else {
            throw Abort(.notFound, reason: "Tracker not found")
        }
        let nestID = action.$nest.id
        let canManage = try await NestMember.query(on: req.db)
            .filter(\.$nest.$id == nestID)
            .filter(\.$user.$id == session.userId)
            .group(.or) { q in
                q.filter(\.$role == .owner)
                q.filter(\.$role == .admin)
            }
            .first() != nil
        guard canManage else { throw Abort(.forbidden, reason: "Owner or admin role required") }

        let deleted = ActionDeletedResponse(id: actionID, nestId: nestID)
        try await req.db.transaction { tx in
            try await EntityPinnedAction.query(on: tx).filter(\.$action.$id == actionID).delete()
            try await ActionEvent.query(on: tx).filter(\.$action.$id == actionID).delete()
            try await action.delete(on: tx)
        }
        req.application.realtimeHub.broadcast(nestId: nestID, type: "action.deleted", data: deleted)
        return .noContent
    }

    // MARK: - Entity Pinned Actions API

    // List pinned actions for an entity (must be a member of the entity's nest)
    protected.get("entities", ":entityID", "pinned-actions") { req async throws -> [PinnedActionDTO] in
        let session = try req.auth.require(SessionToken.self)
        let entityID = try req.parameters.require("entityID", as: UUID.self)

        guard let entity = try await Entity.find(entityID, on: req.db) else {
            throw Abort(.notFound, reason: "Entity not found")
        }

        let nestID = entity.$nest.id

        let isMember = try await NestMember.query(on: req.db)
            .filter(\.$nest.$id == nestID)
            .filter(\.$user.$id == session.userId)
            .first() != nil

        guard isMember else {
            throw Abort(.forbidden, reason: "Not a member of this nest")
        }

        let pins = try await EntityPinnedAction.query(on: req.db)
            .filter(\.$entity.$id == entityID)
            .with(\.$action)
            .sort(\.$sortOrder, .ascending)
            .all()

        return pins.map { pin in
            PinnedActionDTO(
                actionId: pin.$action.id,
                name: pin.action.name,
                valueType: pin.action.valueType,
                unit: pin.action.unit,
                symbol: pin.action.symbol,
                color: pin.action.color,
                sortOrder: pin.sortOrder
            )
        }
    }

    // Set pinned actions for an entity (must be a member of the entity's nest)
    // This replaces the full set and uses sort order based on the array order.
    protected.put("entities", ":entityID", "pinned-actions") { req async throws -> HTTPStatus in
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
            throw Abort(.forbidden, reason: "A member, administrator, or owner role is required to make changes")
        }

        let input = try req.content.decode(SetPinnedActionsRequest.self)
        guard input.actionIds.count <= 50, Set(input.actionIds).count == input.actionIds.count else {
            throw Abort(.badRequest, reason: "Choose up to 50 unique trackers.")
        }

        // Validate the actions exist and belong to the same nest as the entity
        let actions = try await TrackableAction.query(on: req.db)
            .filter(\.$id ~~ input.actionIds)
            .all()

        guard actions.count == input.actionIds.count else {
            throw Abort(.badRequest, reason: "One or more actions not found")
        }

        guard actions.allSatisfy({ $0.$nest.id == nestID }) else {
            throw Abort(.badRequest, reason: "All pinned actions must belong to the entity's nest")
        }

        // Replace pins in a transaction
        try await req.db.transaction { tx in
            try await EntityPinnedAction.query(on: tx)
                .filter(\.$entity.$id == entityID)
                .delete()

            for (idx, actionID) in input.actionIds.enumerated() {
                let pin = EntityPinnedAction(entityID: entityID, actionID: actionID, sortOrder: idx)
                try await pin.save(on: tx)
            }
        }

        req.application.realtimeHub.broadcast(
            nestId: nestID,
            type: "pinnedActions.updated",
            data: PinnedActionsUpdatedResponse(
                entityId: entityID,
                nestId: nestID,
                actionIds: input.actionIds
            )
        )

        return .noContent
    }

    // MARK: - Action Events API (for an Entity)

    protected.post("entities", ":entityID", "events") { req async throws -> ActionEventResponse in
        let session = try req.auth.require(SessionToken.self)
        let entityID = try req.parameters.require("entityID", as: UUID.self)

        guard let entity = try await Entity.find(entityID, on: req.db) else {
            throw Abort(.notFound, reason: "Entity not found")
        }

        let nestID = entity.$nest.id

        // Must be a member of the nest
        let isMember = try await NestMember.query(on: req.db)
            .filter(\.$role != .viewer)
            .filter(\.$nest.$id == nestID)
            .filter(\.$user.$id == session.userId)
            .first() != nil

        guard isMember else {
            throw Abort(.forbidden, reason: "A member, administrator, or owner role is required to make changes")
        }

        struct CreateEventRequest: Content {
            let actionID: UUID
            let occurredAt: Date?           // defaults to now

            let valueNumber: Double?
            let valueText: String?
            let valueBool: Bool?
            let valueJSON: [String: String]?

            let note: String?
        }

        let input = try req.content.decode(CreateEventRequest.self)

        guard let action = try await TrackableAction.find(input.actionID, on: req.db),
              action.$nest.id == nestID else {
            throw Abort(.badRequest, reason: "Action not found in the same nest as this entity")
        }

        try InputValidation.event(type: action.valueType, number: input.valueNumber,
                                  text: input.valueText, boolean: input.valueBool,
                                  json: input.valueJSON, note: input.note)
        guard (input.occurredAt ?? Date()).timeIntervalSinceNow <= 300 else {
            throw Abort(.badRequest, reason: "Activity cannot be logged in the future.")
        }

        let event = ActionEvent(
            nestID: nestID,
            entityID: entityID,
            actionID: input.actionID,
            actorUserID: session.userId,
            occurredAt: input.occurredAt ?? Date(),
            valueNumber: input.valueNumber,
            valueText: input.valueText,
            valueBool: input.valueBool,
            valueJSON: input.valueJSON,
            note: input.note
        )

        try await event.save(on: req.db)

        let response = ActionEventResponse(
            id: try event.requireID(),
            nestId: event.$nest.id,
            entityId: event.$entity.id,
            actionId: event.$action.id,
            actorUserId: event.$actor.id,
            occurredAt: event.occurredAt,
            valueNumber: event.valueNumber,
            valueText: event.valueText,
            valueBool: event.valueBool,
            valueJSON: event.valueJSON,
            note: event.note
        )

        // Realtime broadcast to all members connected to this nest
        req.application.realtimeHub.broadcast(
            nestId: nestID,
            type: "actionEvent.created",
            data: response
        )

        return response
    }

    protected.get("entities", ":entityID", "events") { req async throws -> [ActionEventResponse] in
        let session = try req.auth.require(SessionToken.self)
        let entityID = try req.parameters.require("entityID", as: UUID.self)

        guard let entity = try await Entity.find(entityID, on: req.db) else {
            throw Abort(.notFound, reason: "Entity not found")
        }

        let nestID = entity.$nest.id

        // Must be a member of the nest
        let isMember = try await NestMember.query(on: req.db)
            .filter(\.$nest.$id == nestID)
            .filter(\.$user.$id == session.userId)
            .first() != nil

        guard isMember else {
            throw Abort(.forbidden, reason: "Not a member of this nest")
        }

        let limit = min(200, max(1, (try? req.query.get(Int.self, at: "limit")) ?? 100))
        var query = ActionEvent.query(on: req.db)
            .filter(\.$entity.$id == entityID)
            .sort(\.$occurredAt, .descending)
        if let before = eventCursorDate(from: req) {
            query = query.filter(\.$occurredAt < before)
        }
        let events = try await query.range(..<limit).all()

        return events.compactMap { e in
            guard let id = e.id else { return nil }
            return ActionEventResponse(
                id: id,
                nestId: e.$nest.id,
                entityId: e.$entity.id,
                actionId: e.$action.id,
                actorUserId: e.$actor.id,
                occurredAt: e.occurredAt,
                valueNumber: e.valueNumber,
                valueText: e.valueText,
                valueBool: e.valueBool,
                valueJSON: e.valueJSON,
                note: e.note
            )
        }
    }

    protected.get("nests", ":nestID", "events") { req async throws -> [ActionEventResponse] in
        let session = try req.auth.require(SessionToken.self)
        let nestID = try req.parameters.require("nestID", as: UUID.self)
        guard try await NestMember.query(on: req.db)
            .filter(\.$nest.$id == nestID).filter(\.$user.$id == session.userId).first() != nil else {
            throw Abort(.forbidden, reason: "Not a member of this nest")
        }
        let limit = min(200, max(1, (try? req.query.get(Int.self, at: "limit")) ?? 100))
        var query = ActionEvent.query(on: req.db)
            .filter(\.$nest.$id == nestID)
            .sort(\.$occurredAt, .descending)
        if let before = eventCursorDate(from: req) {
            query = query.filter(\.$occurredAt < before)
        }
        let events = try await query.range(..<limit).all()
        return try events.map { try $0.response() }
    }

    protected.patch("events", ":eventID") { req async throws -> ActionEventResponse in
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
            throw Abort(.forbidden, reason: "Only the person who logged this activity or a nest administrator can edit it")
        }

        let input = try req.content.decode(UpdateEventRequest.self)
        guard let action = try await TrackableAction.find(event.$action.id, on: req.db) else {
            throw Abort(.badRequest, reason: "This tracker is no longer available")
        }
        try InputValidation.event(type: action.valueType, number: input.valueNumber,
                                  text: input.valueText, boolean: input.valueBool,
                                  json: input.valueJSON, note: input.note)
        guard input.occurredAt.timeIntervalSinceNow <= 300 else {
            throw Abort(.badRequest, reason: "Activity cannot be logged in the future.")
        }

        event.occurredAt = input.occurredAt
        event.valueNumber = input.valueNumber
        event.valueText = input.valueText?.trimmingCharacters(in: .whitespacesAndNewlines)
        event.valueBool = input.valueBool
        event.valueJSON = input.valueJSON
        let cleanedNote = input.note?.trimmingCharacters(in: .whitespacesAndNewlines)
        event.note = cleanedNote?.isEmpty == true ? nil : cleanedNote
        try await event.save(on: req.db)

        let response = try event.response()
        req.application.realtimeHub.broadcast(nestId: nestID, type: "event.updated", data: response)
        return response
    }

    protected.delete("events", ":eventID") { req async throws -> HTTPStatus in
        let session = try req.auth.require(SessionToken.self)
        let eventID = try req.parameters.require("eventID", as: UUID.self)
        guard let event = try await ActionEvent.find(eventID, on: req.db) else {
            throw Abort(.notFound, reason: "Activity not found")
        }
        let nestID = event.$nest.id
        guard let membership = try await NestMember.query(on: req.db)
            .filter(\.$nest.$id == nestID).filter(\.$user.$id == session.userId).first(),
              membership.role != .viewer,
              event.$actor.id == session.userId || membership.role == .admin || membership.role == .owner else {
            throw Abort(.forbidden, reason: "Only the person who logged this activity or a nest administrator can delete it")
        }
        try await event.delete(on: req.db)
        req.application.realtimeHub.broadcast(nestId: nestID, type: "event.deleted",
            data: EventDeletedResponse(id: eventID, nestId: nestID, entityId: event.$entity.id))
        return .noContent
    }

}



struct EventDeletedResponse: Content {
    let id: UUID
    let nestId: UUID
    let entityId: UUID
}

extension ActionEvent {
    func response() throws -> ActionEventResponse {
        ActionEventResponse(id: try requireID(), nestId: $nest.id, entityId: $entity.id,
            actionId: $action.id, actorUserId: $actor.id, occurredAt: occurredAt,
            valueNumber: valueNumber, valueText: valueText, valueBool: valueBool,
            valueJSON: valueJSON, note: note)
    }
}
