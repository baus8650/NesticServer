import Fluent
import SQLKit
import Vapor
import JWT
import Crypto
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
    private var privateOwners: [UUID: UUID] = [:]
    func rememberPrivateOwners(_ owners: [UUID: UUID]) { lock.withLock { privateOwners.merge(owners) { _, new in new } } }
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
        let connections = lock.withLock { Array((socketsByNest[nestId] ?? [:]).values) }
        let owners = lock.withLock { privateOwners }
        let sockets = connections.map(\.socket)

        guard !sockets.isEmpty else { return }

        let payload = WSEnvelope(v: 1, type: type, nestId: nestId, ts: Date(), data: data)

        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601

            let encoded = try encoder.encode(payload)
            let json = try JSONSerialization.jsonObject(with: encoded)
            var currentOwners = owners
            if let envelope = json as? [String: Any], let object = envelope["data"] as? [String: Any],
               let idText = object["id"] as? String, let id = UUID(uuidString: idText),
               let ownerText = object["privateOwnerId"] as? String, let owner = UUID(uuidString: ownerText) {
                rememberPrivateOwners([id: owner]); currentOwners[id] = owner
            }
            for connection in connections {
                let hidden = Set(currentOwners.filter { $0.value != connection.userId }.keys)
                guard let clean = TrackerPrivacyPolicy.filtered(json, hidden: hidden) else { continue }
                let bytes = try JSONSerialization.data(withJSONObject: clean)
                guard let text = String(data: bytes, encoding: .utf8) else { continue }
                let ws = connection.socket
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

struct NestUserSettingsResponse: Content {
    let predictionPreferencesJSON: String?
    let quietHoursJSON: String?
    let remindersJSON: String?
    let updatedAt: Date?
}

struct UpdateNestUserSettingsRequest: Content {
    let predictionPreferencesJSON: String?
    let quietHoursJSON: String?
    let remindersJSON: String?
}

/// A nest-scoped forecast shared by every member. The server stores the
/// calculated result, while the private learning ledger remains on-device.
struct NestForecastResponse: Content {
    let id: UUID
    let nestId: UUID
    let subjectId: UUID
    let trackerId: UUID
    let predictedAt: Date
    let baselinePredictedAt: Date
    let contextualPredictedAt: Date?
    let model: String
    let intervalHours: Double
    let confidence: Double
    let sampleCount: Int
    let validationSampleCount: Int
    let expectedErrorHours: Double?
    let predictionWindowHours: Double
    let targetNames: [String]
    let inputNames: [String]
    let lastEventAt: Date
    let computedAt: Date
    let updatedAt: Date?
}

struct UpsertNestForecastRequest: Content {
    let subjectId: UUID
    let trackerId: UUID
    let predictedAt: Date
    let baselinePredictedAt: Date
    let contextualPredictedAt: Date?
    let model: String
    let intervalHours: Double
    let confidence: Double
    let sampleCount: Int
    let validationSampleCount: Int
    let expectedErrorHours: Double?
    let predictionWindowHours: Double
    let targetNames: [String]
    let inputNames: [String]
    let lastEventAt: Date
    let computedAt: Date
}

struct NestReminderResponse: Content {
    let id: UUID
    let nestId: UUID
    let subjectId: UUID
    let subjectName: String
    let trackerId: UUID
    let trackerName: String
    let cadence: NestReminderCadence
    let linkedTrackerId: UUID?
    let linkedTrackerName: String?
    let delayMinutes: Int
    let anchorDate: Date
    let hour: Int
    let minute: Int
    let createdByUserId: UUID
    let createdByName: String
    let notificationsEnabled: Bool
    let createdAt: Date?
    let updatedAt: Date?
}

struct NestReminderRequest: Content {
    let subjectID: UUID
    let trackerID: UUID
    let cadence: NestReminderCadence
    let linkedTrackerID: UUID?
    let delayMinutes: Int
    let anchorDate: Date
    let hour: Int
    let minute: Int
}

struct UpdateReminderNotificationRequest: Content {
    let enabled: Bool
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
    let pinnedActionIDs: [UUID]
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
    var privateOwnerId: UUID? = nil
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
    let photoURL: String?
    let photoUpdates: [ActionEventPhotoResponse]
    let resolvedAt: Date?
    let resolutionNote: String?
    let wasAccident: Bool
    let includeInPredictions: Bool
}

struct ActionEventPhotoResponse: Content {
    let id: UUID
    let capturedAt: Date
    let photoURL: String
    let note: String?
}

struct UpdateEventRequest: Content {
    let occurredAt: Date
    let valueNumber: Double?
    let valueText: String?
    let valueBool: Bool?
    let valueJSON: [String: String]?
    let note: String?
    let wasAccident: Bool?
    let includeInPredictions: Bool?
}

struct ResolveEventRequest: Content {
    let resolvedAt: Date?
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

struct RoutineResponse: Content {
    let id: UUID
    let nestId: UUID
    let entityId: UUID
    let name: String
    let items: [RoutineItem]
    let targets: [RoutineTarget]
    let createdAt: Date?
    let updatedAt: Date?
}

struct RoutineDeletedResponse: Content {
    let id: UUID
    let nestId: UUID
}

struct NestCareLinkResponse: Content {
    let id: UUID
    let nestId: UUID
    let label: String
    let expiresAt: Date
    let entityIDs: [UUID]
    let actionIDs: [UUID]
    let canLog: Bool
    let canViewHistory: Bool
    let revokedAt: Date?
    let createdAt: Date?
    let token: String?
}

struct CreateNestCareLinkRequest: Content {
    let label: String
    let expiresAt: Date
    let entityIDs: [UUID]
    let actionIDs: [UUID]
    let canLog: Bool
    let canViewHistory: Bool
}

struct CareLinkSnapshotResponse: Content {
    let link: NestCareLinkResponse
    let nestName: String
    let entities: [EntityResponse]
    let actions: [TrackableActionResponse]
    let routines: [RoutineResponse]
    let events: [ActionEventResponse]
}

struct CareLinkLogEventRequest: Content {
    let entityID: UUID
    let actionID: UUID
    let occurredAt: Date?
    let valueNumber: Double?
    let valueText: String?
    let valueBool: Bool?
    let valueJSON: [String: String]?
    let note: String?
    let wasAccident: Bool?
    let includeInPredictions: Bool?
}

struct CareLinkLogRoutineRequest: Content {
    let occurredAt: Date?
    let note: String?
}

private func careLinkTokenHash(_ token: String) -> String {
    SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
}

private func newCareLinkToken() -> String {
    var bytes = [UInt8](repeating: 0, count: 32)
    for index in bytes.indices { bytes[index] = UInt8.random(in: .min ... .max) }
    return Data(bytes).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

private func careLinkResponse(_ link: NestCareLink, token: String? = nil) throws -> NestCareLinkResponse {
    NestCareLinkResponse(id: try link.requireID(), nestId: link.$nest.id, label: link.label,
                         expiresAt: link.expiresAt, entityIDs: link.entityIDs,
                         actionIDs: link.actionIDs, canLog: link.canLog,
                         canViewHistory: link.canViewHistory, revokedAt: link.revokedAt,
                         createdAt: link.createdAt, token: token)
}

private func activeCareLink(from req: Request) async throws -> NestCareLink {
    let token = try req.parameters.require("token")
    guard token.count >= 32, let link = try await NestCareLink.query(on: req.db)
        .filter(\.$tokenHash == careLinkTokenHash(token))
        .first(), link.revokedAt == nil, link.expiresAt > Date() else {
        throw Abort(.notFound, reason: "This caregiver link is expired or no longer available.")
    }
    return link
}

private func publicCareEventResponse(_ event: ActionEvent) throws -> ActionEventResponse {
    ActionEventResponse(id: try event.requireID(), nestId: event.$nest.id,
                        entityId: event.$entity.id, actionId: event.$action.id,
                        actorUserId: nil, occurredAt: event.occurredAt,
                        valueNumber: event.valueNumber, valueText: event.valueText,
                        valueBool: event.valueBool, valueJSON: event.valueJSON,
                        note: event.note, photoURL: nil, photoUpdates: [],
                        resolvedAt: event.resolvedAt, resolutionNote: event.resolutionNote,
                        wasAccident: event.wasAccident,
                        includeInPredictions: event.includeInPredictions)
}

private func routineResponse(_ routine: Routine) throws -> RoutineResponse {
    let targets = routineTargets(routine)
    return RoutineResponse(id: try routine.requireID(), nestId: routine.$nest.id,
                    entityId: targets[0].entityID, name: routine.name, items: targets[0].items,
                    targets: targets, createdAt: routine.createdAt,
                    updatedAt: routine.updatedAt)
}

private func routineTargets(_ routine: Routine) -> [RoutineTarget] {
    if let targets = routine.targets?.values, !targets.isEmpty {
        return targets
    }
    return [RoutineTarget(entityID: routine.$entity.id, items: routine.items.values)]
}

private func validateRoutineTargets(_ targets: [RoutineTarget], nestID: UUID, on db: any Database) async throws {
    let entityIDs = targets.map(\.entityID)
    guard !targets.isEmpty, entityIDs.count <= 50, Set(entityIDs).count == entityIDs.count else {
        throw Abort(.badRequest, reason: "Choose at least one unique entity for a routine.")
    }

    let entities = try await Entity.query(on: db)
        .filter(\.$id ~~ entityIDs)
        .all()
    guard entities.count == entityIDs.count, entities.allSatisfy({ $0.$nest.id == nestID }) else {
        throw Abort(.badRequest, reason: "Every routine entity must belong to the same nest.")
    }

    let itemCount = targets.reduce(0) { $0 + $1.items.count }
    guard itemCount <= 50 else {
        throw Abort(.badRequest, reason: "Choose no more than 50 total trackers for a routine.")
    }
    for target in targets {
        try await validateRoutineItems(target.items, entityID: target.entityID, nestID: nestID, on: db)
    }
}

private func validateRoutineItems(_ items: [RoutineItem], entityID: UUID, nestID: UUID, on db: any Database) async throws {
    guard !items.isEmpty, items.count <= 50, Set(items.map(\.trackerID)).count == items.count else {
        throw Abort(.badRequest, reason: "Choose between one and 50 unique trackers for a routine.")
    }

    let trackerIDs = items.map(\.trackerID)
    let actions = try await TrackableAction.query(on: db)
        .filter(\.$id ~~ trackerIDs)
        .all()
    guard actions.count == items.count, actions.allSatisfy({ $0.$nest.id == nestID }) else {
        throw Abort(.badRequest, reason: "Every routine tracker must belong to the same nest.")
    }

    let pinnedIDs = Set(try await EntityPinnedAction.query(on: db)
        .filter(\.$entity.$id == entityID)
        .filter(\.$action.$id ~~ trackerIDs)
        .all()
        .map { $0.$action.id })
    guard pinnedIDs.count == items.count else {
        throw Abort(.badRequest, reason: "Every routine tracker must be enabled for this subject.")
    }

    for item in items {
        guard let action = actions.first(where: { $0.id == item.trackerID }) else { continue }
        try InputValidation.event(type: action.valueType, number: item.valueNumber,
                                  text: item.valueText, boolean: item.valueBool,
                                  json: item.valueJSON, note: nil)
    }
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

private func nestReminderResponse(_ reminder: NestReminder, notificationsEnabled: Bool) throws -> NestReminderResponse {
    NestReminderResponse(
        id: try reminder.requireID(), nestId: reminder.$nest.id,
        subjectId: reminder.subjectID, subjectName: reminder.subjectName,
        trackerId: reminder.trackerID, trackerName: reminder.trackerName,
        cadence: reminder.cadence, linkedTrackerId: reminder.linkedTrackerID,
        linkedTrackerName: reminder.linkedTrackerName,
        delayMinutes: reminder.delayMinutes, anchorDate: reminder.anchorDate,
        hour: reminder.hour, minute: reminder.minute,
        createdByUserId: reminder.createdByUserID, createdByName: reminder.createdByName,
        notificationsEnabled: notificationsEnabled,
        createdAt: reminder.createdAt, updatedAt: reminder.updatedAt
    )
}

private func validateReminderRequest(_ input: NestReminderRequest, nestID: UUID, on db: any Database) async throws -> (Entity, TrackableAction, TrackableAction?) {
    guard (0...23).contains(input.hour), (0...59).contains(input.minute),
          (0...1_440).contains(input.delayMinutes) else {
        throw Abort(.badRequest, reason: "Reminder time is invalid")
    }
    guard let subject = try await Entity.find(input.subjectID, on: db), subject.$nest.id == nestID else {
        throw Abort(.badRequest, reason: "Reminder subject is not in this nest")
    }
    guard let tracker = try await TrackableAction.find(input.trackerID, on: db), tracker.$nest.id == nestID else {
        throw Abort(.badRequest, reason: "Reminder tracker is not in this nest")
    }
    if input.cadence == .afterMeal {
        guard let linkedID = input.linkedTrackerID,
              let linked = try await TrackableAction.find(linkedID, on: db), linked.$nest.id == nestID,
              linkedID != input.trackerID else {
            throw Abort(.badRequest, reason: "Choose another tracker that triggers this reminder")
        }
        return (subject, tracker, linked)
    }
    return (subject, tracker, nil)
}

private func encodedForecastNames(_ names: [String]) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return String(decoding: try encoder.encode(Array(names.prefix(100))), as: UTF8.self)
}

private func decodedForecastNames(_ value: String?) -> [String] {
    guard let value, let data = value.data(using: .utf8),
          let names = try? JSONDecoder().decode([String].self, from: data) else { return [] }
    return names
}

private func forecastResponse(_ forecast: NestForecast) throws -> NestForecastResponse {
    NestForecastResponse(
        id: try forecast.requireID(),
        nestId: forecast.$nest.id,
        subjectId: forecast.$entity.id,
        trackerId: forecast.$action.id,
        predictedAt: forecast.predictedAt,
        baselinePredictedAt: forecast.baselinePredictedAt,
        contextualPredictedAt: forecast.contextualPredictedAt,
        model: forecast.model,
        intervalHours: forecast.intervalHours,
        confidence: forecast.confidence,
        sampleCount: forecast.sampleCount,
        validationSampleCount: forecast.validationSampleCount,
        expectedErrorHours: forecast.expectedErrorHours,
        predictionWindowHours: forecast.predictionWindowHours,
        targetNames: decodedForecastNames(forecast.targetNamesJSON),
        inputNames: decodedForecastNames(forecast.inputNamesJSON),
        lastEventAt: forecast.lastEventAt,
        computedAt: forecast.computedAt,
        updatedAt: forecast.updatedAt)
}

func routes(_ app: Application) throws {
    let protected = app.grouped(SessionToken.authenticator(), SessionToken.guardMiddleware(), TrackerPrivacyMiddleware())
    protected.get("capabilities") { _ in ["privateTrackers": true] }
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

    // MARK: - Public caregiver-link API
    //
    // These routes intentionally do not use the normal session middleware.
    // The unguessable, hashed bearer token is the session, and every request
    // re-checks its expiration, revocation state, and entity/tracker scope.
    app.grouped(TrackerPrivacyMiddleware()).get("care-links", ":token") { req async throws -> CareLinkSnapshotResponse in
        let link = try await activeCareLink(from: req)
        guard let nest = try await Nest.find(link.$nest.id, on: req.db) else {
            throw Abort(.notFound, reason: "Nest not found")
        }

        let entityIDs = Set(link.entityIDs)
        let actionIDs = Set(link.actionIDs)
        let entities = try await Entity.query(on: req.db)
            .filter(\.$nest.$id == link.$nest.id)
            .all()
            .filter { entityIDs.contains($0.id ?? UUID()) }
        let actions = try await TrackableAction.query(on: req.db)
            .filter(\.$nest.$id == link.$nest.id)
            .all()
            .filter { actionIDs.contains($0.id ?? UUID()) }

        let entityResponses = try entities.map { entity in
            EntityResponse(id: try entity.requireID(), nestId: entity.$nest.id,
                           kind: entity.kind, name: entity.name, tags: entity.tags,
                           metadata: entity.metadata, birthday: entity.birthday,
                           // Image references are private storage keys and are
                           // deliberately not exposed through bearer links.
                           imageURL: nil, pinnedActionIDs: [],
                           createdAt: entity.createdAt, updatedAt: entity.updatedAt)
        }
        let actionResponses = try actions.map { action in
            TrackableActionResponse(id: try action.requireID(), nestId: action.$nest.id,
                                    name: action.name, valueType: action.valueType,
                                    unit: action.unit, symbol: action.symbol,
                                    color: action.color, groupName: action.groupName,
                                    description: action.description,
                                    createdAt: action.createdAt, updatedAt: action.updatedAt, privateOwnerId: action.privateOwnerId)
        }

        let routines = try await Routine.query(on: req.db)
            .filter(\.$nest.$id == link.$nest.id)
            .sort(\.$createdAt, .ascending)
            .all()
            .filter { routine in
                let targets = routineTargets(routine)
                return targets.allSatisfy { target in
                    entityIDs.contains(target.entityID) &&
                    target.items.allSatisfy { actionIDs.contains($0.trackerID) }
                }
            }
            .map(routineResponse)

        let events: [ActionEventResponse]
        if link.canViewHistory {
            let history = try await ActionEvent.query(on: req.db)
                .filter(\.$nest.$id == link.$nest.id)
                .filter(\.$entity.$id ~~ Array(entityIDs))
                .filter(\.$action.$id ~~ Array(actionIDs))
                .sort(\.$occurredAt, .descending)
                .range(..<100)
                .all()
            events = try history.map(publicCareEventResponse)
        } else {
            events = []
        }

        return CareLinkSnapshotResponse(
            link: try careLinkResponse(link), nestName: nest.name,
            entities: entityResponses, actions: actionResponses,
            routines: routines, events: events
        )
    }

    app.grouped(TrackerPrivacyMiddleware()).post("care-links", ":token", "events") { req async throws -> ActionEventResponse in
        let link = try await activeCareLink(from: req)
        guard link.canLog else {
            throw Abort(.forbidden, reason: "This caregiver link is view-only.")
        }
        let input = try req.content.decode(CareLinkLogEventRequest.self)
        guard link.entityIDs.contains(input.entityID), link.actionIDs.contains(input.actionID) else {
            throw Abort(.forbidden, reason: "This caregiver link does not include that subject or tracker.")
        }
        guard let entity = try await Entity.find(input.entityID, on: req.db),
              entity.$nest.id == link.$nest.id,
              let action = try await TrackableAction.find(input.actionID, on: req.db),
              action.$nest.id == link.$nest.id else {
            throw Abort(.badRequest, reason: "Subject or tracker not found in this nest.")
        }

        let occurredAt = input.occurredAt ?? Date()
        try InputValidation.event(type: action.valueType, number: input.valueNumber,
                                  text: input.valueText, boolean: input.valueBool,
                                  json: input.valueJSON, note: input.note)
        guard occurredAt.timeIntervalSinceNow <= 300 else {
            throw Abort(.badRequest, reason: "Activity cannot be logged in the future.")
        }
        let event = ActionEvent(nestID: link.$nest.id, entityID: input.entityID,
                                actionID: input.actionID, actorUserID: nil,
                                occurredAt: occurredAt, valueNumber: input.valueNumber,
                                valueText: input.valueText, valueBool: input.valueBool,
                                valueJSON: input.valueJSON, note: input.note,
                                wasAccident: input.wasAccident ?? false,
                                includeInPredictions: input.includeInPredictions ?? true)
        try await event.save(on: req.db)
        let response = try publicCareEventResponse(event)
        req.application.realtimeHub.broadcast(nestId: link.$nest.id,
                                              type: "actionEvent.created", data: response)
        return response
    }

    app.grouped(TrackerPrivacyMiddleware()).post("care-links", ":token", "routines", ":routineID", "log") { req async throws -> [ActionEventResponse] in
        let link = try await activeCareLink(from: req)
        guard link.canLog else {
            throw Abort(.forbidden, reason: "This caregiver link is view-only.")
        }
        let routineID = try req.parameters.require("routineID", as: UUID.self)
        guard let routine = try await Routine.find(routineID, on: req.db),
              routine.$nest.id == link.$nest.id else {
            throw Abort(.notFound, reason: "Routine not found")
        }
        let targets = routineTargets(routine)
        guard targets.allSatisfy({ link.entityIDs.contains($0.entityID) &&
                                   $0.items.allSatisfy { link.actionIDs.contains($0.trackerID) } }) else {
            throw Abort(.forbidden, reason: "This caregiver link does not include every routine target.")
        }
        let input = try req.content.decode(CareLinkLogRoutineRequest.self)
        let occurredAt = input.occurredAt ?? Date()
        guard occurredAt.timeIntervalSinceNow <= 300 else {
            throw Abort(.badRequest, reason: "Activity cannot be logged in the future.")
        }
        try await validateRoutineTargets(targets, nestID: link.$nest.id, on: req.db)
        let trackerIDs = Array(Set(targets.flatMap { $0.items.map(\.trackerID) }))
        let actions = try await TrackableAction.query(on: req.db)
            .filter(\.$id ~~ trackerIDs).all()
        let cleanNote = input.note?.trimmingCharacters(in: .whitespacesAndNewlines)
        let events: [ActionEvent] = try await req.db.transaction { tx async throws -> [ActionEvent] in
            var created: [ActionEvent] = []
            for target in targets {
                for item in target.items {
                    guard let action = actions.first(where: { $0.id == item.trackerID }) else {
                        throw Abort(.badRequest, reason: "A routine tracker is no longer available.")
                    }
                    let event = ActionEvent(nestID: link.$nest.id, entityID: target.entityID,
                                            actionID: try action.requireID(), actorUserID: nil,
                                            occurredAt: occurredAt, valueNumber: item.valueNumber,
                                            valueText: item.valueText, valueBool: item.valueBool,
                                            valueJSON: item.valueJSON,
                                            note: cleanNote?.isEmpty == true ? nil : cleanNote)
                    try await event.save(on: tx)
                    created.append(event)
                }
            }
            return created
        }
        let responses = try events.map(publicCareEventResponse)
        for response in responses {
            req.application.realtimeHub.broadcast(nestId: link.$nest.id,
                                                  type: "actionEvent.created", data: response)
        }
        return responses
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

    // Per-user settings are stored on the server so a reinstall or a second
    // device can restore the user's forecast, quiet-hour, and reminder setup.
    protected.get("nests", ":nestID", "settings") { req async throws -> NestUserSettingsResponse in
        let session = try req.auth.require(SessionToken.self)
        let nestID = try req.parameters.require("nestID", as: UUID.self)
        guard try await NestMember.query(on: req.db)
            .filter(\.$nest.$id == nestID)
            .filter(\.$user.$id == session.userId)
            .first() != nil else {
            throw Abort(.forbidden, reason: "Not a member of this nest")
        }

        let settings = try await NestUserSettings.query(on: req.db)
            .filter(\.$nest.$id == nestID)
            .filter(\.$user.$id == session.userId)
            .first()
        return NestUserSettingsResponse(
            predictionPreferencesJSON: settings?.predictionPreferencesJSON,
            quietHoursJSON: settings?.quietHoursJSON,
            remindersJSON: settings?.remindersJSON,
            updatedAt: settings?.updatedAt
        )
    }

    protected.put("nests", ":nestID", "settings") { req async throws -> NestUserSettingsResponse in
        let session = try req.auth.require(SessionToken.self)
        let nestID = try req.parameters.require("nestID", as: UUID.self)
        guard try await NestMember.query(on: req.db)
            .filter(\.$nest.$id == nestID)
            .filter(\.$user.$id == session.userId)
            .first() != nil else {
            throw Abort(.forbidden, reason: "Not a member of this nest")
        }

        let input = try req.content.decode(UpdateNestUserSettingsRequest.self)
        let settings = try await NestUserSettings.query(on: req.db)
            .filter(\.$nest.$id == nestID)
            .filter(\.$user.$id == session.userId)
            .first() ?? NestUserSettings(nestID: nestID, userID: session.userId)
        settings.predictionPreferencesJSON = input.predictionPreferencesJSON
        settings.quietHoursJSON = input.quietHoursJSON
        settings.remindersJSON = input.remindersJSON
        try await settings.save(on: req.db)

        return NestUserSettingsResponse(
            predictionPreferencesJSON: settings.predictionPreferencesJSON,
            quietHoursJSON: settings.quietHoursJSON,
            remindersJSON: settings.remindersJSON,
            updatedAt: settings.updatedAt
        )
    }

    // Forecast output is deliberately nest-scoped. A member's device may
    // calculate it, but every member reads the same latest result here.
    protected.get("nests", ":nestID", "forecasts") { req async throws -> [NestForecastResponse] in
        let session = try req.auth.require(SessionToken.self)
        let nestID = try req.parameters.require("nestID", as: UUID.self)
        guard try await NestMember.query(on: req.db)
            .filter(\.$nest.$id == nestID)
            .filter(\.$user.$id == session.userId)
            .first() != nil else {
            throw Abort(.forbidden, reason: "Not a member of this nest")
        }

        let forecasts = try await NestForecast.query(on: req.db)
            .filter(\.$nest.$id == nestID)
            .sort(\.$computedAt, .descending)
            .all()
        return try forecasts.map(forecastResponse)
    }

    protected.put("nests", ":nestID", "forecasts") { req async throws -> [NestForecastResponse] in
        let session = try req.auth.require(SessionToken.self)
        let nestID = try req.parameters.require("nestID", as: UUID.self)
        guard try await NestMember.query(on: req.db)
            .filter(\.$nest.$id == nestID)
            .filter(\.$user.$id == session.userId)
            .first() != nil else {
            throw Abort(.forbidden, reason: "Not a member of this nest")
        }

        let input = try req.content.decode([UpsertNestForecastRequest].self)
        guard input.count <= 100 else {
            throw Abort(.badRequest, reason: "A nest can publish at most 100 forecasts at once")
        }

        // Remove results whose source event was edited, excluded, or deleted.
        // This also lets a new forecast move backward to the now-current last
        // event after someone deletes the event that used to anchor it.
        let storedForecasts = try await NestForecast.query(on: req.db)
            .filter(\.$nest.$id == nestID)
            .all()
        for forecast in storedForecasts {
            let latestIncludedEvent = try await ActionEvent.query(on: req.db)
                .filter(\.$entity.$id == forecast.$entity.id)
                .filter(\.$action.$id == forecast.$action.id)
                .sort(\.$occurredAt, .descending)
                .all()
                .first(where: { $0.includeInPredictions })
            if latestIncludedEvent?.occurredAt != forecast.lastEventAt {
                try await forecast.delete(on: req.db)
            }
        }

        for item in input {
            guard item.model == "baseline" || item.model == "contextual",
                  item.intervalHours.isFinite, item.intervalHours > 0, item.intervalHours <= 72,
                  item.confidence.isFinite, item.confidence >= 0, item.confidence <= 1,
                  item.sampleCount >= 0, item.sampleCount <= 10_000,
                  item.validationSampleCount >= 0, item.validationSampleCount <= 10_000,
                  item.predictionWindowHours.isFinite, item.predictionWindowHours >= 0,
                  item.predictedAt >= item.lastEventAt,
                  item.computedAt <= Date().addingTimeInterval(5 * 60) else {
                throw Abort(.badRequest, reason: "That forecast payload is invalid")
            }

            guard let entity = try await Entity.find(item.subjectId, on: req.db),
                  entity.$nest.id == nestID,
                  let action = try await TrackableAction.find(item.trackerId, on: req.db),
                  action.$nest.id == nestID else {
                throw Abort(.badRequest, reason: "The forecast subject or tracker is not in this nest")
            }

            let existing = try await NestForecast.query(on: req.db)
                .filter(\.$nest.$id == nestID)
                .filter(\.$entity.$id == item.subjectId)
                .filter(\.$action.$id == item.trackerId)
                .first()
            // A delayed device must not replace a forecast based on newer
            // shared activity. Equal-history writes use the most recent
            // calculation so the nest converges on one payload.
            if let existing,
               item.lastEventAt < existing.lastEventAt ||
               (item.lastEventAt == existing.lastEventAt && item.computedAt <= existing.computedAt) {
                continue
            }

            let targetNamesJSON = try encodedForecastNames(item.targetNames)
            let inputNamesJSON = try encodedForecastNames(item.inputNames)
            let forecast = existing ?? NestForecast(
                nestID: nestID, entityID: item.subjectId, actionID: item.trackerId,
                generatedByUserID: session.userId, predictedAt: item.predictedAt,
                baselinePredictedAt: item.baselinePredictedAt,
                contextualPredictedAt: item.contextualPredictedAt, model: item.model,
                intervalHours: item.intervalHours, confidence: item.confidence,
                sampleCount: item.sampleCount, validationSampleCount: item.validationSampleCount,
                expectedErrorHours: item.expectedErrorHours,
                predictionWindowHours: item.predictionWindowHours,
                targetNamesJSON: targetNamesJSON,
                inputNamesJSON: inputNamesJSON,
                lastEventAt: item.lastEventAt, computedAt: item.computedAt)
            forecast.$generatedByUser.id = session.userId
            forecast.predictedAt = item.predictedAt
            forecast.baselinePredictedAt = item.baselinePredictedAt
            forecast.contextualPredictedAt = item.contextualPredictedAt
            forecast.model = item.model
            forecast.intervalHours = item.intervalHours
            forecast.confidence = item.confidence
            forecast.sampleCount = item.sampleCount
            forecast.validationSampleCount = item.validationSampleCount
            forecast.expectedErrorHours = item.expectedErrorHours
            forecast.predictionWindowHours = item.predictionWindowHours
            forecast.targetNamesJSON = targetNamesJSON
            forecast.inputNamesJSON = inputNamesJSON
            forecast.lastEventAt = item.lastEventAt
            forecast.computedAt = item.computedAt
            try await forecast.save(on: req.db)
        }

        let forecasts = try await NestForecast.query(on: req.db)
            .filter(\.$nest.$id == nestID)
            .sort(\.$computedAt, .descending)
            .all()
        let response = try forecasts.map(forecastResponse)
        req.application.realtimeHub.broadcast(nestId: nestID, type: "forecast.updated", data: response)
        return response
    }

    // MARK: - Shared reminders

    // Reminder schedules are shared with a nest. The enabled state below is
    // resolved for the requesting member only, so one person can opt out
    // without muting anyone else.
    protected.get("nests", ":nestID", "reminders") { req async throws -> [NestReminderResponse] in
        let session = try req.auth.require(SessionToken.self)
        let nestID = try req.parameters.require("nestID", as: UUID.self)
        guard try await NestMember.query(on: req.db)
            .filter(\.$nest.$id == nestID).filter(\.$user.$id == session.userId).first() != nil else {
            throw Abort(.forbidden, reason: "Not a member of this nest")
        }
        let reminders = try await NestReminder.query(on: req.db)
            .filter(\.$nest.$id == nestID).sort(\.$createdAt, .ascending).all()
        let ids = try reminders.map { try $0.requireID() }
        let preferences = try await NestReminderPreference.query(on: req.db)
            .filter(\.$user.$id == session.userId).filter(\.$reminder.$id ~~ ids).all()
        let enabledByID = Dictionary(uniqueKeysWithValues: preferences.map { ($0.$reminder.id, $0.enabled) })
        return try reminders.map { try nestReminderResponse($0, notificationsEnabled: enabledByID[try $0.requireID()] ?? true) }
    }

    protected.post("nests", ":nestID", "reminders") { req async throws -> NestReminderResponse in
        let session = try req.auth.require(SessionToken.self)
        let nestID = try req.parameters.require("nestID", as: UUID.self)
        guard let membership = try await NestMember.query(on: req.db)
            .filter(\.$nest.$id == nestID).filter(\.$user.$id == session.userId).first(), membership.role != .viewer else {
            throw Abort(.forbidden, reason: "A member with logging access is required")
        }
        let input = try req.content.decode(NestReminderRequest.self)
        let (subject, tracker, linkedTracker) = try await validateReminderRequest(input, nestID: nestID, on: req.db)
        let user = try await User.find(session.userId, on: req.db)
        let creatorName = user?.displayName ?? user?.email ?? "Nest member"
        let reminder = NestReminder(nestID: nestID, subjectID: try subject.requireID(), subjectName: subject.name,
                                    trackerID: try tracker.requireID(), trackerName: tracker.name,
                                    cadence: input.cadence, linkedTrackerID: linkedTracker.flatMap { try? $0.requireID() },
                                    linkedTrackerName: linkedTracker?.name, delayMinutes: input.delayMinutes,
                                    anchorDate: input.anchorDate, hour: input.hour, minute: input.minute,
                                    createdByUserID: session.userId, createdByName: creatorName)
        try await reminder.save(on: req.db)
        let response = try nestReminderResponse(reminder, notificationsEnabled: true)
        req.application.realtimeHub.broadcast(nestId: nestID, type: "reminder.created", data: response)
        return response
    }

    protected.patch("nests", ":nestID", "reminders", ":reminderID") { req async throws -> NestReminderResponse in
        let session = try req.auth.require(SessionToken.self)
        let nestID = try req.parameters.require("nestID", as: UUID.self)
        let reminderID = try req.parameters.require("reminderID", as: UUID.self)
        guard let membership = try await NestMember.query(on: req.db)
            .filter(\.$nest.$id == nestID).filter(\.$user.$id == session.userId).first(), membership.role != .viewer,
              let reminder = try await NestReminder.query(on: req.db)
                .filter(\.$id == reminderID).filter(\.$nest.$id == nestID).first() else {
            throw Abort(.forbidden, reason: "You cannot edit this reminder")
        }
        guard reminder.createdByUserID == session.userId || membership.role == .owner || membership.role == .admin else {
            throw Abort(.forbidden, reason: "Only the creator, an owner, or an administrator can edit this reminder")
        }
        let input = try req.content.decode(NestReminderRequest.self)
        let (subject, tracker, linkedTracker) = try await validateReminderRequest(input, nestID: nestID, on: req.db)
        let oldTracker = try await TrackableAction.find(reminder.trackerID, on: req.db)
        let oldLinked: TrackableAction?
        if let linkedID = reminder.linkedTrackerID { oldLinked = try await TrackableAction.find(linkedID, on: req.db) } else { oldLinked = nil }
        let oldOwner = oldTracker?.privateOwnerId ?? oldLinked?.privateOwnerId
        let newOwner = tracker.privateOwnerId ?? linkedTracker?.privateOwnerId
        guard oldOwner == newOwner else {
            throw Abort(.badRequest, reason: "Create a new reminder to change between shared and private visibility.")
        }
        reminder.subjectID = try subject.requireID()
        reminder.subjectName = subject.name
        reminder.trackerID = try tracker.requireID()
        reminder.trackerName = tracker.name
        reminder.cadence = input.cadence
        reminder.linkedTrackerID = linkedTracker.flatMap { try? $0.requireID() }
        reminder.linkedTrackerName = linkedTracker?.name
        reminder.delayMinutes = input.delayMinutes
        reminder.anchorDate = input.anchorDate
        reminder.hour = input.hour
        reminder.minute = input.minute
        try await reminder.save(on: req.db)
        let preference = try await NestReminderPreference.query(on: req.db)
            .filter(\.$reminder.$id == reminderID).filter(\.$user.$id == session.userId).first()
        let response = try nestReminderResponse(reminder, notificationsEnabled: preference?.enabled ?? true)
        req.application.realtimeHub.broadcast(nestId: nestID, type: "reminder.updated", data: response)
        return response
    }

    protected.delete("nests", ":nestID", "reminders", ":reminderID") { req async throws -> HTTPStatus in
        let session = try req.auth.require(SessionToken.self)
        let nestID = try req.parameters.require("nestID", as: UUID.self)
        let reminderID = try req.parameters.require("reminderID", as: UUID.self)
        guard let membership = try await NestMember.query(on: req.db)
            .filter(\.$nest.$id == nestID).filter(\.$user.$id == session.userId).first(),
              let reminder = try await NestReminder.query(on: req.db)
                .filter(\.$id == reminderID).filter(\.$nest.$id == nestID).first() else {
            throw Abort(.notFound, reason: "Reminder not found")
        }
        guard reminder.createdByUserID == session.userId || membership.role == .owner || membership.role == .admin else {
            throw Abort(.forbidden, reason: "Only the creator, an owner, or an administrator can delete this reminder")
        }
        try await reminder.delete(on: req.db)
        req.application.realtimeHub.broadcast(nestId: nestID, type: "reminder.deleted", data: ["id": reminderID.uuidString])
        return .noContent
    }

    protected.put("nests", ":nestID", "reminders", ":reminderID", "notification") { req async throws -> NestReminderResponse in
        let session = try req.auth.require(SessionToken.self)
        let nestID = try req.parameters.require("nestID", as: UUID.self)
        let reminderID = try req.parameters.require("reminderID", as: UUID.self)
        guard try await NestMember.query(on: req.db)
            .filter(\.$nest.$id == nestID).filter(\.$user.$id == session.userId).first() != nil,
              let reminder = try await NestReminder.query(on: req.db)
                .filter(\.$id == reminderID).filter(\.$nest.$id == nestID).first() else {
            throw Abort(.notFound, reason: "Reminder not found")
        }
        let input = try req.content.decode(UpdateReminderNotificationRequest.self)
        let preference = try await NestReminderPreference.query(on: req.db)
            .filter(\.$reminder.$id == reminderID).filter(\.$user.$id == session.userId).first()
            ?? NestReminderPreference(reminderID: reminderID, userID: session.userId, enabled: input.enabled)
        preference.enabled = input.enabled
        try await preference.save(on: req.db)
        return try nestReminderResponse(reminder, notificationsEnabled: preference.enabled)
    }

    // MARK: - Caregiver-link management

    protected.get("nests", ":nestID", "care-links") { req async throws -> [NestCareLinkResponse] in
        let session = try req.auth.require(SessionToken.self)
        let nestID = try req.parameters.require("nestID", as: UUID.self)
        let canManage = try await NestMember.query(on: req.db)
            .filter(\.$nest.$id == nestID)
            .filter(\.$user.$id == session.userId)
            .group(.or) { query in
                query.filter(\.$role == .owner)
                query.filter(\.$role == .admin)
            }
            .first() != nil
        guard canManage else {
            throw Abort(.forbidden, reason: "Owner or admin role required")
        }

        return try await NestCareLink.query(on: req.db)
            .filter(\.$nest.$id == nestID)
            .sort(\.$createdAt, .descending)
            .all()
            .map { try careLinkResponse($0) }
    }

    protected.post("nests", ":nestID", "care-links") { req async throws -> NestCareLinkResponse in
        let session = try req.auth.require(SessionToken.self)
        let nestID = try req.parameters.require("nestID", as: UUID.self)
        let canManage = try await NestMember.query(on: req.db)
            .filter(\.$nest.$id == nestID)
            .filter(\.$user.$id == session.userId)
            .group(.or) { query in
                query.filter(\.$role == .owner)
                query.filter(\.$role == .admin)
            }
            .first() != nil
        guard canManage else {
            throw Abort(.forbidden, reason: "Owner or admin role required")
        }
        guard try await Nest.find(nestID, on: req.db) != nil else {
            throw Abort(.notFound, reason: "Nest not found")
        }

        let input = try req.content.decode(CreateNestCareLinkRequest.self)
        let label = try InputValidation.name(input.label, field: "Link name")
        let expiresAt = input.expiresAt
        guard expiresAt.timeIntervalSinceNow >= 300 else {
            throw Abort(.badRequest, reason: "A caregiver link must last at least five minutes.")
        }
        guard expiresAt.timeIntervalSinceNow <= 30 * 24 * 60 * 60 else {
            throw Abort(.badRequest, reason: "A caregiver link cannot last more than 30 days.")
        }
        guard input.canLog || input.canViewHistory else {
            throw Abort(.badRequest, reason: "Choose at least one caregiver permission.")
        }
        let entityIDs = Array(Set(input.entityIDs))
        let actionIDs = Array(Set(input.actionIDs))
        guard !entityIDs.isEmpty, entityIDs.count <= 50,
              !actionIDs.isEmpty, actionIDs.count <= 50 else {
            throw Abort(.badRequest, reason: "Choose between one and 50 subjects and trackers.")
        }

        let entities = try await Entity.query(on: req.db)
            .filter(\.$id ~~ entityIDs).all()
        guard entities.count == entityIDs.count,
              entities.allSatisfy({ $0.$nest.id == nestID }) else {
            throw Abort(.badRequest, reason: "Every selected subject must belong to this nest.")
        }
        let actions = try await TrackableAction.query(on: req.db)
            .filter(\.$id ~~ actionIDs).all()
        guard actions.count == actionIDs.count,
              actions.allSatisfy({ $0.$nest.id == nestID }) else {
            throw Abort(.badRequest, reason: "Every selected tracker must belong to this nest.")
        }

        let rawToken = newCareLinkToken()
        let link = NestCareLink(nestID: nestID, createdByUserID: session.userId,
                                tokenHash: careLinkTokenHash(rawToken), label: label,
                                expiresAt: expiresAt, entityIDs: entityIDs,
                                actionIDs: actionIDs, canLog: input.canLog,
                                canViewHistory: input.canViewHistory)
        try await link.save(on: req.db)
        return try careLinkResponse(link, token: rawToken)
    }

    protected.delete("nests", ":nestID", "care-links", ":linkID") { req async throws -> HTTPStatus in
        let session = try req.auth.require(SessionToken.self)
        let nestID = try req.parameters.require("nestID", as: UUID.self)
        let linkID = try req.parameters.require("linkID", as: UUID.self)
        let canManage = try await NestMember.query(on: req.db)
            .filter(\.$nest.$id == nestID)
            .filter(\.$user.$id == session.userId)
            .group(.or) { query in
                query.filter(\.$role == .owner)
                query.filter(\.$role == .admin)
            }
            .first() != nil
        guard canManage else {
            throw Abort(.forbidden, reason: "Owner or admin role required")
        }
        guard let link = try await NestCareLink.query(on: req.db)
            .filter(\.$id == linkID)
            .filter(\.$nest.$id == nestID)
            .first() else {
            throw Abort(.notFound, reason: "Caregiver link not found")
        }
        if link.revokedAt == nil {
            link.revokedAt = Date()
            try await link.save(on: req.db)
        }
        return .noContent
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

    // Remove another member (owner only), or leave a nest yourself. Leaving
    // gives every non-owner an immediate safety escape route from private
    // shared content; an owner must first transfer ownership.
    protected.delete("nests", ":nestID", "members", ":userID") { req async throws -> HTTPStatus in
        let session = try req.auth.require(SessionToken.self)
        let nestID = try req.parameters.require("nestID", as: UUID.self)
        let targetUserID = try req.parameters.require("userID", as: UUID.self)

        // An owner can remove another member. Any member can remove themself.
        let isOwner = try await NestMember.query(on: req.db)
            .filter(\.$nest.$id == nestID)
            .filter(\.$user.$id == session.userId)
            .filter(\.$role == .owner)
            .first() != nil

        guard isOwner || targetUserID == session.userId else {
            throw Abort(.forbidden, reason: "Owner role required to remove another member")
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

        try await req.db.transaction { tx in
            // Removing membership must also close any bearer links created by
            // this person, so those links cannot bypass the removal.
            let links = try await NestCareLink.query(on: tx)
                .filter(\.$nest.$id == nestID)
                .filter(\.$createdBy.$id == targetUserID).all()
            for link in links {
                link.revokedAt = Date()
                try await link.save(on: tx)
            }
            try await membership.delete(on: tx)
        }
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

        let entityIDs = entities.compactMap(\.id)
        var pinsByEntity: [UUID: [UUID]] = [:]
        if !entityIDs.isEmpty {
            let pins = try await EntityPinnedAction.query(on: req.db)
                .filter(\.$entity.$id ~~ entityIDs)
                .sort(\.$sortOrder, .ascending)
                .all()
            for pin in pins {
                pinsByEntity[pin.$entity.id, default: []].append(pin.$action.id)
            }
        }

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
                pinnedActionIDs: pinsByEntity[id] ?? [],
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
            pinnedActionIDs: [],
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
            pinnedActionIDs: [],
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

        let eventPhotoKeys = try await ActionEvent.query(on: req.db)
            .filter(\.$entity.$id == entityID)
            .all()
            .compactMap { R2Storage.key(from: $0.photoURL) }

        // Cascade-delete related rows
        try await req.db.transaction { tx in
            try await EntityPinnedAction.query(on: tx)
                .filter(\.$entity.$id == entityID)
                .delete()

            try await ActionEvent.query(on: tx)
                .filter(\.$entity.$id == entityID)
                .delete()
            let routines = try await Routine.query(on: tx)
                .filter(\.$nest.$id == nestID)
                .all()
            for routine in routines {
                let remainingTargets = routineTargets(routine).filter { $0.entityID != entityID }
                guard remainingTargets.count != routineTargets(routine).count else { continue }
                if remainingTargets.isEmpty {
                    try await routine.delete(on: tx)
                } else {
                    routine.$entity.id = remainingTargets[0].entityID
                    routine.items = RoutineItems(remainingTargets[0].items)
                    routine.targets = RoutineTargets(remainingTargets)
                    try await routine.save(on: tx)
                }
            }

            try await entity.delete(on: tx)
        }

        if let key = R2Storage.key(from: entity.imageURL),
           let storage = req.application.r2Storage {
            try? await storage.delete(key: key, logger: req.logger)
        }
        if let storage = req.application.r2Storage {
            for key in eventPhotoKeys {
                try? await storage.delete(key: key, logger: req.logger)
            }
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
                updatedAt: a.updatedAt, privateOwnerId: a.privateOwnerId
            )
        }
    }

    protected.post("nests", ":nestID", "actions") { req async throws -> TrackableActionResponse in
        let session = try req.auth.require(SessionToken.self)
        let nestID = try req.parameters.require("nestID", as: UUID.self)

        guard try await Nest.find(nestID, on: req.db) != nil else {
            throw Abort(.notFound, reason: "Nest not found")
        }

        struct PrivacyInput: Content { let isPrivate: Bool? }
        let isPrivate = (try req.content.decode(PrivacyInput.self)).isPrivate == true
        // Shared trackers require management access; private trackers require membership.
        let isOwnerOrAdmin = try await NestMember.query(on: req.db)
            .filter(\.$nest.$id == nestID)
            .filter(\.$user.$id == session.userId)
            .group(.or) { q in
                q.filter(\.$role == .owner)
                q.filter(\.$role == .admin)
            }
            .first() != nil

        let membership = try await NestMember.query(on: req.db).filter(\.$nest.$id == nestID).filter(\.$user.$id == session.userId).first()
        guard isOwnerOrAdmin || (isPrivate && membership != nil && membership?.role != .viewer) else {
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

        action.privateOwnerId = isPrivate ? session.userId : nil
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
            updatedAt: action.updatedAt, privateOwnerId: action.privateOwnerId
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
        let privateMembership = try await NestMember.query(on: req.db).filter(\.$nest.$id == nestID).filter(\.$user.$id == session.userId).filter(\.$role != .viewer).first()
        let canManagePrivate = action.privateOwnerId == session.userId && privateMembership != nil
        guard canManage || canManagePrivate else { throw Abort(.forbidden, reason: "Owner or admin role required") }

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
                                               description: action.description,
                                               createdAt: action.createdAt,
                                               updatedAt: action.updatedAt, privateOwnerId: action.privateOwnerId)
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
        let privateMembership = try await NestMember.query(on: req.db).filter(\.$nest.$id == nestID).filter(\.$user.$id == session.userId).filter(\.$role != .viewer).first()
        let canManagePrivate = action.privateOwnerId == session.userId && privateMembership != nil
        guard canManage || canManagePrivate else { throw Abort(.forbidden, reason: "Owner or admin role required") }

        let deleted = ActionDeletedResponse(id: actionID, nestId: nestID)
        let eventPhotoKeys = try await ActionEvent.query(on: req.db)
            .filter(\.$action.$id == actionID)
            .all()
            .compactMap { R2Storage.key(from: $0.photoURL) }
        try await req.db.transaction { tx in
            try await EntityPinnedAction.query(on: tx).filter(\.$action.$id == actionID).delete()
            try await ActionEvent.query(on: tx).filter(\.$action.$id == actionID).delete()
            let routines = try await Routine.query(on: tx)
                .filter(\.$nest.$id == nestID)
                .all()
            for routine in routines {
                let existingTargets = routineTargets(routine)
                let remainingTargets = existingTargets.compactMap { target -> RoutineTarget? in
                    let items = target.items.filter { $0.trackerID != actionID }
                    return items.isEmpty ? nil : RoutineTarget(entityID: target.entityID, items: items)
                }
                if remainingTargets.isEmpty {
                    try await routine.delete(on: tx)
                } else if remainingTargets != existingTargets || routine.targets != nil {
                    routine.$entity.id = remainingTargets[0].entityID
                    routine.items = RoutineItems(remainingTargets[0].items)
                    routine.targets = routine.targets == nil && remainingTargets.count == 1
                        ? nil
                        : RoutineTargets(remainingTargets)
                    try await routine.save(on: tx)
                }
            }
            try await action.delete(on: tx)
        }
        if let storage = req.application.r2Storage {
            for key in eventPhotoKeys {
                try? await storage.delete(key: key, logger: req.logger)
            }
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

        // Serialize changes per subject, retaining every other owner's private pins.
        let updatedPins = try await req.db.transaction { tx -> [UUID] in
            if let sql = tx as? any SQLDatabase {
                try await sql.raw("SELECT id FROM entities WHERE id = \(bind: entityID) FOR UPDATE").run()
            }
            let otherPrivate = try await TrackableAction.query(on: tx)
                .filter(\.$nest.$id == nestID).filter(\.$privateOwnerId != nil)
                .filter(\.$privateOwnerId != session.userId).all().compactMap(\.id)
            let retained = try await EntityPinnedAction.query(on: tx)
                .filter(\.$entity.$id == entityID).filter(\.$action.$id ~~ otherPrivate)
                .all().map { $0.$action.id }
            let combined = input.actionIds + retained
            try await EntityPinnedAction.query(on: tx).filter(\.$entity.$id == entityID).delete()
            for (idx, actionID) in combined.enumerated() {
                try await EntityPinnedAction(entityID: entityID, actionID: actionID, sortOrder: idx).save(on: tx)
            }
            return combined
        }

        req.application.realtimeHub.broadcast(
            nestId: nestID,
            type: "pinnedActions.updated",
            data: PinnedActionsUpdatedResponse(
                entityId: entityID,
                nestId: nestID,
                actionIds: updatedPins
            )
        )

        return .noContent
    }

    // MARK: - Routines API

    protected.get("nests", ":nestID", "routines") { req async throws -> [RoutineResponse] in
        let session = try req.auth.require(SessionToken.self)
        let nestID = try req.parameters.require("nestID", as: UUID.self)
        guard try await NestMember.query(on: req.db)
            .filter(\.$nest.$id == nestID)
            .filter(\.$user.$id == session.userId)
            .first() != nil else {
            throw Abort(.forbidden, reason: "Not a member of this nest")
        }

        return try await Routine.query(on: req.db)
            .filter(\.$nest.$id == nestID)
            .sort(\.$createdAt, .ascending)
            .all()
            .map(routineResponse)
    }

    protected.post("nests", ":nestID", "routines") { req async throws -> RoutineResponse in
        let session = try req.auth.require(SessionToken.self)
        let nestID = try req.parameters.require("nestID", as: UUID.self)
        let canManage = try await NestMember.query(on: req.db)
            .filter(\.$nest.$id == nestID)
            .filter(\.$user.$id == session.userId)
            .group(.or) { query in
                query.filter(\.$role == .owner)
                query.filter(\.$role == .admin)
            }
            .first() != nil
        guard canManage else {
            throw Abort(.forbidden, reason: "Owner or admin role required")
        }

        struct CreateRoutineRequest: Content {
            let entityID: UUID?
            let name: String
            let items: [RoutineItem]?
            let targets: [RoutineTarget]?
        }
        let input = try req.content.decode(CreateRoutineRequest.self)
        let selectedTargets: [RoutineTarget]
        if let targets = input.targets {
            selectedTargets = targets
        } else if let entityID = input.entityID, let items = input.items {
            selectedTargets = [RoutineTarget(entityID: entityID, items: items)]
        } else {
            throw Abort(.badRequest, reason: "Choose at least one entity and tracker for this routine.")
        }
        try await validateRoutineTargets(selectedTargets, nestID: nestID, on: req.db)

        let routine = Routine(nestID: nestID, name: try InputValidation.name(input.name), targets: selectedTargets)
        try await routine.save(on: req.db)
        let response = try routineResponse(routine)
        req.application.realtimeHub.broadcast(nestId: nestID, type: "routine.created", data: response)
        return response
    }

    protected.patch("routines", ":routineID") { req async throws -> RoutineResponse in
        let session = try req.auth.require(SessionToken.self)
        let routineID = try req.parameters.require("routineID", as: UUID.self)
        guard let routine = try await Routine.find(routineID, on: req.db) else {
            throw Abort(.notFound, reason: "Routine not found")
        }
        let nestID = routine.$nest.id
        let canManage = try await NestMember.query(on: req.db)
            .filter(\.$nest.$id == nestID)
            .filter(\.$user.$id == session.userId)
            .group(.or) { query in
                query.filter(\.$role == .owner)
                query.filter(\.$role == .admin)
            }
            .first() != nil
        guard canManage else {
            throw Abort(.forbidden, reason: "Owner or admin role required")
        }

        struct UpdateRoutineRequest: Content {
            let name: String
            let items: [RoutineItem]?
            let targets: [RoutineTarget]?
        }
        let input = try req.content.decode(UpdateRoutineRequest.self)
        let selectedTargets: [RoutineTarget]
        if let targets = input.targets {
            selectedTargets = targets
        } else if let items = input.items {
            selectedTargets = [RoutineTarget(entityID: routine.$entity.id, items: items)]
        } else {
            throw Abort(.badRequest, reason: "Choose at least one entity and tracker for this routine.")
        }
        try await validateRoutineTargets(selectedTargets, nestID: nestID, on: req.db)
        routine.name = try InputValidation.name(input.name)
        routine.$entity.id = selectedTargets[0].entityID
        routine.items = RoutineItems(selectedTargets[0].items)
        routine.targets = RoutineTargets(selectedTargets)
        try await routine.save(on: req.db)
        let response = try routineResponse(routine)
        req.application.realtimeHub.broadcast(nestId: nestID, type: "routine.updated", data: response)
        return response
    }

    protected.delete("routines", ":routineID") { req async throws -> HTTPStatus in
        let session = try req.auth.require(SessionToken.self)
        let routineID = try req.parameters.require("routineID", as: UUID.self)
        guard let routine = try await Routine.find(routineID, on: req.db) else {
            throw Abort(.notFound, reason: "Routine not found")
        }
        let nestID = routine.$nest.id
        let canManage = try await NestMember.query(on: req.db)
            .filter(\.$nest.$id == nestID)
            .filter(\.$user.$id == session.userId)
            .group(.or) { query in
                query.filter(\.$role == .owner)
                query.filter(\.$role == .admin)
            }
            .first() != nil
        guard canManage else {
            throw Abort(.forbidden, reason: "Owner or admin role required")
        }

        try await routine.delete(on: req.db)
        req.application.realtimeHub.broadcast(nestId: nestID, type: "routine.deleted",
                                              data: RoutineDeletedResponse(id: routineID, nestId: nestID))
        return .noContent
    }

    protected.post("routines", ":routineID", "log") { req async throws -> [ActionEventResponse] in
        let session = try req.auth.require(SessionToken.self)
        let routineID = try req.parameters.require("routineID", as: UUID.self)
        guard let routine = try await Routine.find(routineID, on: req.db) else {
            throw Abort(.notFound, reason: "Routine not found")
        }
        let nestID = routine.$nest.id
        guard try await NestMember.query(on: req.db)
            .filter(\.$nest.$id == nestID)
            .filter(\.$user.$id == session.userId)
            .filter(\.$role != .viewer)
            .first() != nil else {
            throw Abort(.forbidden, reason: "A member, administrator, or owner role is required to log updates")
        }

        struct LogRoutineRequest: Content {
            let occurredAt: Date?
            let note: String?
        }
        let input = try req.content.decode(LogRoutineRequest.self)
        let occurredAt = input.occurredAt ?? Date()
        guard occurredAt.timeIntervalSinceNow <= 300 else {
            throw Abort(.badRequest, reason: "Activity cannot be logged in the future.")
        }
        let targets = routineTargets(routine)
        try await validateRoutineTargets(targets, nestID: nestID, on: req.db)
        let trackerIDs = Array(Set(targets.flatMap { $0.items.map(\.trackerID) }))
        let actions = try await TrackableAction.query(on: req.db)
            .filter(\.$id ~~ trackerIDs)
            .all()
        let cleanNote = input.note?.trimmingCharacters(in: .whitespacesAndNewlines)
        let events: [ActionEvent] = try await req.db.transaction { tx async throws -> [ActionEvent] in
            var created: [ActionEvent] = []
            for target in targets {
                for item in target.items {
                    guard let action = actions.first(where: { $0.id == item.trackerID }) else {
                        throw Abort(.badRequest, reason: "A routine tracker is no longer available.")
                    }
                    let event = ActionEvent(nestID: nestID, entityID: target.entityID,
                                            actionID: try action.requireID(), actorUserID: session.userId,
                                            occurredAt: occurredAt, valueNumber: item.valueNumber,
                                            valueText: item.valueText, valueBool: item.valueBool,
                                            valueJSON: item.valueJSON,
                                            note: cleanNote?.isEmpty == true ? nil : cleanNote)
                    try await event.save(on: tx)
                    created.append(event)
                }
            }
            return created
        }

        // These events were just created and cannot have photo updates yet.
        // Do not access the @Children relation here: Fluent traps when a
        // children relationship has not been eager-loaded, which previously
        // turned routine logging into a server-side 502 after health events
        // added photoUpdates to ActionEventResponse.
        let responses = try events.map { try $0.response(photos: []) }
        for response in responses {
            req.application.realtimeHub.broadcast(nestId: nestID, type: "actionEvent.created", data: response)
        }
        return responses
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
            let wasAccident: Bool?
            let includeInPredictions: Bool?
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
            note: input.note,
            wasAccident: input.wasAccident ?? false,
            includeInPredictions: input.includeInPredictions ?? true
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
            note: event.note,
            photoURL: event.photoURL,
            photoUpdates: [],
            resolvedAt: event.resolvedAt,
            resolutionNote: event.resolutionNote,
            wasAccident: event.wasAccident,
            includeInPredictions: event.includeInPredictions
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
            .with(\.$photoUpdates)
            .sort(\.$occurredAt, .descending)
        if let before = eventCursorDate(from: req) {
            query = query.filter(\.$occurredAt < before)
        }
        let hiddenActions = try await TrackableAction.query(on: req.db).filter(\.$nest.$id == nestID).filter(\.$privateOwnerId != nil).filter(\.$privateOwnerId != session.userId).all().compactMap(\.id)
        if !hiddenActions.isEmpty { query = query.filter(\.$action.$id !~ hiddenActions) }
        let events = try await query.range(..<limit).all()

        return try events.compactMap { e in
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
                note: e.note,
                photoURL: e.photoURL,
                photoUpdates: try e.photoUpdates.map { try $0.response() },
                resolvedAt: e.resolvedAt,
                resolutionNote: e.resolutionNote,
                wasAccident: e.wasAccident,
                includeInPredictions: e.includeInPredictions
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
            .with(\.$photoUpdates)
            .sort(\.$occurredAt, .descending)
        if let before = eventCursorDate(from: req) {
            query = query.filter(\.$occurredAt < before)
        }
        let hiddenActions = try await TrackableAction.query(on: req.db).filter(\.$nest.$id == nestID).filter(\.$privateOwnerId != nil).filter(\.$privateOwnerId != session.userId).all().compactMap(\.id)
        if !hiddenActions.isEmpty { query = query.filter(\.$action.$id !~ hiddenActions) }
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
        if let resolvedAt = event.resolvedAt, resolvedAt < input.occurredAt {
            throw Abort(.badRequest, reason: "Onset cannot be later than the recorded resolution")
        }

        event.occurredAt = input.occurredAt
        event.valueNumber = input.valueNumber
        event.valueText = input.valueText?.trimmingCharacters(in: .whitespacesAndNewlines)
        event.valueBool = input.valueBool
        event.valueJSON = input.valueJSON
        if let wasAccident = input.wasAccident {
            event.wasAccident = wasAccident
        }
        if let includeInPredictions = input.includeInPredictions {
            event.includeInPredictions = includeInPredictions
        }
        let cleanedNote = input.note?.trimmingCharacters(in: .whitespacesAndNewlines)
        event.note = cleanedNote?.isEmpty == true ? nil : cleanedNote
        try await event.save(on: req.db)

        let response = try await event.response(on: req.db)
        req.application.realtimeHub.broadcast(nestId: nestID, type: "event.updated", data: response)
        return response
    }

    protected.post("events", ":eventID", "resolve") { req async throws -> ActionEventResponse in
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
            throw Abort(.forbidden, reason: "Only the person who logged this activity or a nest administrator can resolve it")
        }
        guard let action = try await TrackableAction.find(event.$action.id, on: req.db), action.valueType == .health else {
            throw Abort(.badRequest, reason: "Only health events can be resolved")
        }

        let input = try req.content.decode(ResolveEventRequest.self)
        let resolvedAt = input.resolvedAt ?? Date()
        guard resolvedAt >= event.occurredAt else {
            throw Abort(.badRequest, reason: "Resolution cannot happen before onset")
        }
        guard resolvedAt.timeIntervalSinceNow <= 300 else {
            throw Abort(.badRequest, reason: "Resolution cannot be in the future")
        }
        guard (input.note?.count ?? 0) <= 2000 else {
            throw Abort(.badRequest, reason: "Resolution notes are limited to 2,000 characters")
        }
        event.resolvedAt = resolvedAt
        let cleanNote = input.note?.trimmingCharacters(in: .whitespacesAndNewlines)
        event.resolutionNote = cleanNote?.isEmpty == true ? nil : cleanNote
        try await event.save(on: req.db)
        let response = try await event.response(on: req.db)
        req.application.realtimeHub.broadcast(nestId: nestID, type: "event.updated", data: response)
        return response
    }

    protected.delete("events", ":eventID", "resolve") { req async throws -> ActionEventResponse in
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
            throw Abort(.forbidden, reason: "Only the person who logged this activity or a nest administrator can reopen it")
        }
        guard let action = try await TrackableAction.find(event.$action.id, on: req.db), action.valueType == .health else {
            throw Abort(.badRequest, reason: "Only health events can be reopened")
        }
        event.resolvedAt = nil
        event.resolutionNote = nil
        try await event.save(on: req.db)
        let response = try await event.response(on: req.db)
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
        let photoKey = R2Storage.key(from: event.photoURL)
        let photoUpdates = try await event.$photoUpdates.get(on: req.db)
        try await event.delete(on: req.db)
        if let photoKey, let storage = req.application.r2Storage {
            try? await storage.delete(key: photoKey, logger: req.logger)
        }
        if let storage = req.application.r2Storage {
            for photo in photoUpdates {
                if let key = R2Storage.key(from: photo.photoURL) {
                    try? await storage.delete(key: key, logger: req.logger)
                }
            }
        }
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
    func response(photos: [ActionEventPhoto]? = nil) throws -> ActionEventResponse {
        let resolvedPhotos = photos ?? photoUpdates
        return ActionEventResponse(id: try requireID(), nestId: $nest.id, entityId: $entity.id,
            actionId: $action.id, actorUserId: $actor.id, occurredAt: occurredAt,
            valueNumber: valueNumber, valueText: valueText, valueBool: valueBool,
            valueJSON: valueJSON, note: note, photoURL: photoURL,
            photoUpdates: try resolvedPhotos.map { try $0.response() },
            resolvedAt: resolvedAt, resolutionNote: resolutionNote,
            wasAccident: wasAccident, includeInPredictions: includeInPredictions)
    }

    func response(on db: any Database) async throws -> ActionEventResponse {
        try response(photos: try await $photoUpdates.get(on: db))
    }
}

extension ActionEventPhoto {
    func response() throws -> ActionEventPhotoResponse {
        ActionEventPhotoResponse(id: try requireID(), capturedAt: capturedAt, photoURL: photoURL, note: note)
    }
}
