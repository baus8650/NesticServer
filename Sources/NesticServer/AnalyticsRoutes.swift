import Vapor
import Fluent
import Crypto
import SQLKit

final class UsageEvent: Model, @unchecked Sendable {
    static let schema = "usage_events"
    @ID(key: .id) var id: UUID?
    @Field(key: "source") var source: String
    @Field(key: "kind") var kind: String
    @Field(key: "path") var path: String
    @Field(key: "consented") var consented: Bool
    @OptionalField(key: "session_id") var sessionID: UUID?
    @OptionalField(key: "country") var country: String?
    @OptionalField(key: "region") var region: String?
    @OptionalField(key: "city") var city: String?
    @OptionalField(key: "device") var device: String?
    @OptionalField(key: "browser") var browser: String?
    @OptionalField(key: "os") var os: String?
    @OptionalField(key: "version") var version: String?
    @OptionalField(key: "language") var language: String?
    @OptionalField(key: "timezone") var timezone: String?
    @OptionalField(key: "referrer") var referrer: String?
    @OptionalField(key: "campaign") var campaign: String?
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    init() {}
}
struct CreateUsageEvents: AsyncMigration {
    func prepare(on db: any Database) async throws {
        var schema = db.schema(UsageEvent.schema).id().field("source",.string,.required).field("kind",.string,.required).field("path",.string,.required).field("consented",.bool,.required).field("session_id",.uuid).field("created_at",.datetime)
        for field in ["country","device","browser","os","version","language","timezone","referrer","campaign"] { schema = schema.field(.string(field),.string) }
        try await schema.create()
        if let sql = db as? any SQLDatabase { try await sql.raw("CREATE INDEX usage_events_created_at_idx ON usage_events (created_at)").run() }
    }
    func revert(on db: any Database) async throws { try await db.schema(UsageEvent.schema).delete() }
}
struct UsageEventRequest: Content {
    let id: UUID; let source: String; let kind: String; let path: String; let consented: Bool
    var sessionID: UUID? = nil; var device: String? = nil; var browser: String? = nil; var os: String? = nil; var version: String? = nil; var language: String? = nil; var timezone: String? = nil; var referrer: String? = nil; var campaign: String? = nil
}
struct UsageDimension: Content { let name: String; let count: Int }
struct UsageDay: Content { let date: String; let pageViews: Int; let appOpens: Int; let appStoreClicks: Int; let newAccounts: Int; let recordedUpdates: Int }
struct UsageVisit: Content {
    let id: UUID; let date: Date; let source: String; let kind: String; let path: String; let consented: Bool
    let country: String?; let region: String?; let city: String?; let device: String?; let browser: String?; let os: String?; let version: String?; let language: String?; let timezone: String?; let referrer: String?; let campaign: String?
}
struct UsageDashboard: Content {
    let days: Int; let pageViews: Int; let appOpens: Int; let appStoreClicks: Int; let consentedSessions: Int; let detailedEvents: Int; let newAccounts: Int; let recordedUpdates: Int
    let daily: [UsageDay]; let countries: [UsageDimension]; let cities: [UsageDimension]; let devices: [UsageDimension]; let browsers: [UsageDimension]; let operatingSystems: [UsageDimension]; let referrers: [UsageDimension]; let pages: [UsageDimension]; let campaigns: [UsageDimension]; let timezones: [UsageDimension]; let recent: [UsageVisit]
}
private actor UsageIngress {
    static let shared = UsageIngress()
    private let salt = UUID().uuidString
    private var requests: [String:(Date,Int)] = [:]
    func allowed(_ ip: String, limit: Int = 60) -> Bool {
        let key = SHA256.hash(data:Data((salt+ip).utf8)).map { String(format:"%02x",$0) }.joined()
        let now = Date()
        if requests.count > 10000 { requests = requests.filter { now.timeIntervalSince($0.value.0) < 60 } }
        if requests.count >= 10000 && requests[key] == nil { return false }
        var value = requests[key] ?? (now,0)
        if now.timeIntervalSince(value.0) > 60 { value = (now,0) }
        value.1 += 1; requests[key] = value; return value.1 <= limit
    }
}
func usageText(_ value: String?, limit: Int = 80) -> String? {
    guard let value else { return nil }
    let clean = String(value.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.prefix(limit)).trimmingCharacters(in:.whitespacesAndNewlines)
    return clean.isEmpty ? nil : clean
}
func analyticsRoutes(_ app: Application) throws {
    app.post("analytics","events") { req async throws -> HTTPStatus in
        let input = try req.content.decode(UsageEventRequest.self)
        guard ["web","ios","android"].contains(input.source), ["page_view","app_open","app_store_click"].contains(input.kind), ["/","/features","/privacy","/terms","/support","/legal","home","activity","insights","settings"].contains(input.path) else { throw Abort(.badRequest) }
        let agent = req.headers.first(name:.userAgent)?.lowercased() ?? ""
        if ["bot","crawler","spider","headless"].contains(where:agent.contains) { return .noContent }
        let ip = req.headers.first(name:"x-real-ip") ?? req.headers.first(name:"x-forwarded-for")?.split(separator:",").first.map { $0.trimmingCharacters(in:.whitespaces) } ?? req.remoteAddress?.ipAddress ?? "unknown"
        guard await UsageIngress.shared.allowed(ip), await UsageIngress.shared.allowed("peer:" + (req.remoteAddress?.ipAddress ?? "unknown"), limit: 600) else { throw Abort(.tooManyRequests) }
        let consent = input.consented && req.headers.first(name:"DNT") != "1" && req.headers.first(name:"Sec-GPC") != "1"
        let event = try await UsageEvent.find(input.id,on:req.db) ?? UsageEvent()
        event.id = input.id; event.source = input.source; event.kind = input.kind; event.path = input.path; event.consented = consent
        event.sessionID = consent ? input.sessionID : nil
        let location = consent ? OfflineLocationLookup.shared.location(for:ip) : nil
        event.country = consent ? location?.country ?? OfflineCountryLookup.shared.country(for:ip) : nil
        event.region = consent ? usageText(location?.region) : nil
        event.city = consent ? usageText(location?.city) : nil
        event.device = consent ? usageText(input.device) : nil; event.browser = consent ? usageText(input.browser) : nil; event.os = consent ? usageText(input.os) : nil; event.version = consent ? usageText(input.version,limit:30) : nil
        event.language = consent ? usageText(input.language,limit:40) : nil; event.timezone = consent ? usageText(input.timezone) : nil
        event.referrer = consent ? input.referrer.flatMap { URLComponents(string:$0)?.host }.flatMap { usageText($0,limit:200) } : nil
        event.campaign = consent ? input.campaign.flatMap { $0.range(of:"^[A-Za-z0-9_-]{1,80}$",options:.regularExpression) != nil ? $0 : nil } : nil
        try await event.save(on:req.db)
        try await UsageEvent.query(on:req.db).filter(\.$createdAt < Date().addingTimeInterval(-90*86400)).delete()
        return .noContent
    }
    let protected = app.grouped(SessionToken.authenticator(),SessionToken.guardMiddleware())
    protected.get("admin","analytics") { req async throws -> UsageDashboard in
        _ = try await req.requireNesticAdmin()
        let requested = req.query[Int.self,at:"days"] ?? 30
        let days = [7,30,90].contains(requested) ? requested : 30
        var calendar = Calendar(identifier:.gregorian); calendar.timeZone = TimeZone(secondsFromGMT:0)!
        let today = calendar.startOfDay(for:Date()), cutoff = calendar.date(byAdding:.day,value:-(days-1),to:today)!
        let events = try await UsageEvent.query(on:req.db).filter(\.$createdAt >= cutoff).sort(\.$createdAt,.descending).all()
        let users = try await User.query(on:req.db).filter(\.$createdAt >= cutoff).all()
        let updates = try await ActionEvent.query(on:req.db).filter(\.$createdAt >= cutoff).all()
        let formatter = DateFormatter(); formatter.locale = Locale(identifier:"en_US_POSIX"); formatter.timeZone = calendar.timeZone; formatter.dateFormat = "yyyy-MM-dd"
        let eventDays = Dictionary(grouping:events) { formatter.string(from:$0.createdAt ?? .distantPast) }
        let userDays = Dictionary(grouping:users) { formatter.string(from:$0.createdAt ?? .distantPast) }
        let updateDays = Dictionary(grouping:updates) { formatter.string(from:$0.createdAt ?? .distantPast) }
        func dimensions(_ values: [String?]) -> [UsageDimension] { Dictionary(grouping:values.compactMap { $0 },by: { $0 }).map { UsageDimension(name:$0.key,count:$0.value.count) }.sorted { $0.count == $1.count ? $0.name < $1.name : $0.count > $1.count } }
        let detailed = events.filter(\.consented)
        let daily = (0..<days).map { offset -> UsageDay in
            let day = formatter.string(from:calendar.date(byAdding:.day,value:offset,to:cutoff)!), rows = eventDays[day] ?? []
            return UsageDay(date:day,pageViews:rows.filter { $0.kind == "page_view" }.count,appOpens:rows.filter { $0.kind == "app_open" }.count,appStoreClicks:rows.filter { $0.kind == "app_store_click" }.count,newAccounts:userDays[day]?.count ?? 0,recordedUpdates:updateDays[day]?.count ?? 0)
        }
        return UsageDashboard(days:days,pageViews:events.filter { $0.kind == "page_view" }.count,appOpens:events.filter { $0.kind == "app_open" }.count,appStoreClicks:events.filter { $0.kind == "app_store_click" }.count,consentedSessions:Set(detailed.compactMap(\.sessionID)).count,detailedEvents:detailed.count,newAccounts:users.count,recordedUpdates:updates.count,daily:daily,countries:dimensions(detailed.map(\.country)),cities:dimensions(detailed.map { event in event.city.map { city in [city,event.region,event.country].compactMap { $0 }.joined(separator:", ") } }),devices:dimensions(detailed.map(\.device)),browsers:dimensions(detailed.map(\.browser)),operatingSystems:dimensions(detailed.map(\.os)),referrers:dimensions(detailed.map(\.referrer)),pages:dimensions(events.map { $0.path }),campaigns:dimensions(detailed.map(\.campaign)),timezones:dimensions(detailed.map(\.timezone)),recent:try events.prefix(100).map { e in UsageVisit(id:try e.requireID(),date:e.createdAt ?? Date(),source:e.source,kind:e.kind,path:e.path,consented:e.consented,country:e.country,region:e.region,city:e.city,device:e.device,browser:e.browser,os:e.os,version:e.version,language:e.language,timezone:e.timezone,referrer:e.referrer,campaign:e.campaign) })
    }
}

private struct UsageRetentionTaskKey: StorageKey { typealias Value = Task<Void,Never> }
struct UsageRetentionLifecycle: LifecycleHandler {
    func didBootAsync(_ app: Application) async throws {
        guard app.environment != .testing else { return }
        _ = OfflineLocationLookup.shared
        app.storage[UsageRetentionTaskKey.self] = Task {
            while !Task.isCancelled {
                do { try await UsageEvent.query(on:app.db).filter(\.$createdAt < Date().addingTimeInterval(-90*86400)).delete() }
                catch { app.logger.warning("Analytics retention cleanup could not complete") }
                do { try await Task.sleep(for:.seconds(6*60*60)) } catch { break }
            }
        }
    }
    func shutdownAsync(_ app: Application) async {
        app.storage[UsageRetentionTaskKey.self]?.cancel()
        await app.storage[UsageRetentionTaskKey.self]?.value
        app.storage[UsageRetentionTaskKey.self] = nil
    }
}

struct AddUsageLocationDetails: AsyncMigration {
    func prepare(on db: any Database) async throws {
        if let sql = db as? any SQLDatabase {
            try await sql.raw("ALTER TABLE usage_events ADD COLUMN IF NOT EXISTS region TEXT, ADD COLUMN IF NOT EXISTS city TEXT").run()
        } else { try await db.schema(UsageEvent.schema).field("region",.string).field("city",.string).update() }
    }
    func revert(on db: any Database) async throws { try await db.schema(UsageEvent.schema).deleteField("region").deleteField("city").update() }
}
