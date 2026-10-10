import Fluent
import Vapor

/// Owner maps include dependent resources so direct-ID photo, reminder, and
/// event routes enforce the same boundary as tracker collection endpoints.
struct TrackerPrivacyPolicy: Sendable {
    var owners: [UUID: UUID]
    var trackerOwners: [UUID: UUID]

    static func load(on db: any Database, eventID: UUID? = nil) async throws -> TrackerPrivacyPolicy {
        let actions = try await TrackableAction.query(on: db).filter(\.$privateOwnerId != nil).all()
        let trackerOwners = Dictionary(uniqueKeysWithValues: actions.compactMap { action -> (UUID, UUID)? in
            guard let id = action.id, let owner = action.privateOwnerId else { return nil }
            return (id, owner)
        })
        var owners = trackerOwners
        if !trackerOwners.isEmpty {
            let ids = Array(trackerOwners.keys)
            if let eventID, let event = try await ActionEvent.find(eventID, on: db), let owner = trackerOwners[event.$action.id] { owners[eventID] = owner }
            let reminders = try await NestReminder.query(on: db).group(.or) { $0.filter(\.$trackerID ~~ ids).filter(\.$linkedTrackerID ~~ ids) }.all()
            for reminder in reminders {
                if let id = reminder.id { owners[id] = trackerOwners[reminder.trackerID] ?? reminder.linkedTrackerID.flatMap { trackerOwners[$0] } }
            }
        }
        for routine in try await Routine.query(on: db).filter(\.$privateOwnerId != nil).all() {
            if let id = routine.id, let owner = routine.privateOwnerId { owners[id] = owner }
        }
        return TrackerPrivacyPolicy(owners: owners, trackerOwners: trackerOwners)
    }

    func hidden(for user: UUID?) -> Set<UUID> {
        Set(owners.filter { $0.value != user }.keys)
    }

    /// Applies to typed JSON envelopes, collections, nested home summaries,
    /// pinned ID arrays and prediction preference dictionaries alike.
    static func filtered(_ value: Any, hidden: Set<UUID>) -> Any? {
        if let string = value as? String {
            if let id = UUID(uuidString: string), hidden.contains(id) { return nil }
            if (string.hasPrefix("{") || string.hasPrefix("[")), let data = string.data(using: .utf8), let nested = try? JSONSerialization.jsonObject(with: data), let clean = filtered(nested, hidden: hidden), let encoded = try? JSONSerialization.data(withJSONObject: clean) { return String(decoding: encoded, as: UTF8.self) }
        }
        if let array = value as? [Any] { return array.compactMap { filtered($0, hidden: hidden) } }
        if let object = value as? [String: Any] {
            for key in ["id", "eventId", "eventID", "actionId", "actionID", "trackerId", "trackerID", "linkedTrackerId", "linkedTrackerID"] {
                if let string = object[key] as? String, let id = UUID(uuidString: string), hidden.contains(id) { return nil }
            }
            var result: [String: Any] = [:]
            for (key, item) in object {
                if let id = UUID(uuidString: key), hidden.contains(id) { continue }
                if let clean = filtered(item, hidden: hidden) { result[key] = clean }
            }
            // A realtime envelope whose entire payload is private is not sent.
            if object["data"] != nil && result["data"] == nil { return nil }
            return result
        }
        return value
    }

    static func referencedIDs(_ value: Any) -> Set<UUID> {
        if let string = value as? String {
            if let id = UUID(uuidString: string) { return [id] }
            if (string.hasPrefix("{") || string.hasPrefix("[")), let data = string.data(using: .utf8), let nested = try? JSONSerialization.jsonObject(with: data) { return referencedIDs(nested) }
            return []
        }
        if let array = value as? [Any] { return array.reduce(into: []) { $0.formUnion(referencedIDs($1)) } }
        if let object = value as? [String: Any] {
            return object.reduce(into: []) { result, pair in
                if let id = UUID(uuidString: pair.key) { result.insert(id) }
                result.formUnion(referencedIDs(pair.value))
            }
        }
        return []
    }
}

struct TrackerPrivacyMiddleware: AsyncMiddleware {
    func respond(to req: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        let user = req.auth.get(SessionToken.self)?.userId
        let policy = try await TrackerPrivacyPolicy.load(on: req.db, eventID: req.parameters.get("eventID").flatMap(UUID.init(uuidString:)))
        req.application.realtimeHub.rememberPrivateOwners(policy.owners)
        let hidden = policy.hidden(for: user)
        for key in ["actionID", "eventID", "reminderID", "routineID"] {
            if let raw = req.parameters.get(key), let id = UUID(uuidString: raw), hidden.contains(id) {
                throw Abort(.notFound, reason: "Resource not found")
            }
        }
        if let bytes = req.body.data,
           let json = try? JSONSerialization.jsonObject(with: Data(buffer: bytes)) {
            let references = TrackerPrivacyPolicy.referencedIDs(json)
            guard references.isDisjoint(with: hidden) else { throw Abort(.notFound, reason: "Resource not found") }
            let sharedPath = ["care-links"].contains { req.url.path.split(separator: "/").contains(Substring($0)) }
            if sharedPath && !references.isDisjoint(with: Set(policy.trackerOwners.keys)) {
                throw Abort(.badRequest, reason: "Private trackers cannot be included in caregiver access.")
            }
        }
        let response = try await next.respond(to: req)
        guard response.headers.first(name: .contentType)?.lowercased().hasPrefix("application/json") == true, let bytes = response.body.data,
              let json = try? JSONSerialization.jsonObject(with: bytes) else { return response }
        let clean = TrackerPrivacyPolicy.filtered(json, hidden: hidden) ?? NSNull()
        let data = try JSONSerialization.data(withJSONObject: clean, options: [.fragmentsAllowed])
        response.body = .init(data: data)
        response.headers.replaceOrAdd(name: .contentLength, value: String(data.count))
        return response
    }
}
