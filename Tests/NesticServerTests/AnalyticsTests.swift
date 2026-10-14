@testable import NesticServer
import Testing
import VaporTesting
import Fluent

@Suite("Analytics access and privacy", .serialized, .enabled(if: Environment.get("RUN_DATABASE_TESTS") == "true"))
struct AnalyticsTests {
    @Test("Anonymous counts, opt-in details, privacy signals and administrator-only access")
    func dashboard() async throws {
        let app = try await Application.make(.testing)
        do {
            try await configure(app); try await app.autoMigrate()
            let admin = User(email:"baus8650@gmail.com",passwordHash:"unused",displayName:"Admin",emailVerified:true)
            let reader = User(email:"analytics-reader-\(UUID())@example.com",passwordHash:"unused",displayName:"Reader",emailVerified:true)
            try await admin.save(on:app.db); try await reader.save(on:app.db)
            let adminHeaders: HTTPHeaders = ["Authorization":"Bearer \(try await app.jwt.keys.sign(SessionToken(userId:admin.requireID())))"]
            let readerHeaders: HTTPHeaders = ["Authorization":"Bearer \(try await app.jwt.keys.sign(SessionToken(userId:reader.requireID())))"]
            let api = try app.testing()
            let id = UUID(), session = UUID()
            let input = UsageEventRequest(id:id,source:"web",kind:"page_view",path:"/",consented:false,sessionID:session,device:"Mobile",browser:"Safari",os:"iOS",language:"en-US",timezone:"America/New_York",referrer:"https://example.com/private?token=secret",campaign:"launch")
            let basic = try await api.sendRequest(.POST,"analytics/events",headers:["X-Forwarded-For":"8.8.8.8"],beforeRequest:{ req async throws in try req.content.encode(input) })
            #expect(basic.status == .noContent)
            let stored = try #require(try await UsageEvent.find(id,on:app.db))
            #expect(stored.country == nil && stored.city == nil && stored.region == nil && stored.sessionID == nil && stored.referrer == nil && stored.browser == nil)
            let detailedInput = UsageEventRequest(id:id,source:"web",kind:"page_view",path:"/",consented:true,sessionID:session,device:"Mobile",browser:"Safari",os:"iOS",language:"en-US",timezone:"America/New_York",referrer:"https://example.com/private?token=secret",campaign:"launch")
            let opted = try await api.sendRequest(.POST,"analytics/events",headers:["X-Forwarded-For":"8.8.8.8"],beforeRequest:{ req async throws in try req.content.encode(detailedInput) })
            #expect(opted.status == .noContent)
            let detailed = try #require(try await UsageEvent.find(id,on:app.db))
            #expect(detailed.country == "US"); #expect(detailed.city != nil && detailed.region != nil); #expect(detailed.sessionID == session); #expect(detailed.referrer == "example.com")
            #expect(try await UsageEvent.query(on:app.db).filter(\.$id == id).count() == 1)
            let denied = try await api.sendRequest(.GET,"admin/analytics",headers:readerHeaders); #expect(denied.status == .forbidden)
            let anonymous = try await api.sendRequest(.GET,"admin/analytics"); #expect(anonymous.status == .unauthorized)
            let allowed = try await api.sendRequest(.GET,"admin/analytics?days=7",headers:adminHeaders); #expect(allowed.status == .ok)
            let dashboard = try allowed.content.decode(UsageDashboard.self)
            #expect(dashboard.days == 7 && dashboard.daily.count == 7); #expect(dashboard.consentedSessions >= 1)
            #expect(dashboard.countries.contains { $0.name == "US" })
            let raw = String(buffer:allowed.body); #expect(!raw.contains("8.8.8.8") && !raw.contains("token=secret") && !raw.contains(reader.email))
            let privateID = UUID()
            let privateInput = UsageEventRequest(id:privateID,source:"web",kind:"page_view",path:"/features",consented:true,sessionID:session,device:"Desktop")
            let privacy = try await api.sendRequest(.POST,"analytics/events",headers:["Sec-GPC":"1","X-Forwarded-For":"8.8.8.8"],beforeRequest:{ req async throws in try req.content.encode(privateInput) })
            #expect(privacy.status == .noContent)
            let protected = try #require(try await UsageEvent.find(privateID,on:app.db)); #expect(!protected.consented && protected.country == nil && protected.sessionID == nil)
            let invalid = UsageEventRequest(id:UUID(),source:"web",kind:"page_view",path:"/trackers/private-secret",consented:true)
            let bad = try await api.sendRequest(.POST,"analytics/events",beforeRequest:{ req async throws in try req.content.encode(invalid) }); #expect(bad.status == .badRequest)
            try await UsageEvent.query(on:app.db).filter(\.$id ~~ [id,privateID]).delete()
            try await admin.delete(on:app.db); try await reader.delete(on:app.db)
            try await app.asyncShutdown()
        } catch { try await app.asyncShutdown(); throw error }
    }
}
@Suite("Offline country lookup") struct OfflineCountryTests {
    @Test func knownAndInvalidAddresses() {
        #expect(OfflineCountryLookup.shared.country(for:"8.8.8.8") == "US")
        #expect(OfflineCountryLookup.shared.country(for:"::ffff:8.8.8.8") == "US")
        #expect(OfflineCountryLookup.shared.country(for:"127.0.0.1") == nil)
        #expect(OfflineCountryLookup.shared.country(for:"not-an-ip") == nil)
    }
}
