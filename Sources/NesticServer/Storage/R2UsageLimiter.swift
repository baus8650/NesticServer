import Foundation
import NIOHTTP1
import Vapor

struct R2UsageLimits: Sendable {
    let maxUploadBytesPerPhoto: Int64
    let dailyUploadBytesPerUser: Int64
    let dailyUploadsPerUser: Int
    let uploadsPerMinutePerUser: Int
    let dailyReadsPerUser: Int
    let readsPerMinutePerUser: Int
    let dailyUploadBytesTotal: Int64
    let dailyUploadsTotal: Int
    let dailyReadsTotal: Int

    init(
        maxUploadBytesPerPhoto: Int64 = 512 * 1024,
        dailyUploadBytesPerUser: Int64 = 5 * 1024 * 1024,
        dailyUploadsPerUser: Int = 20,
        uploadsPerMinutePerUser: Int = 6,
        dailyReadsPerUser: Int = 1_000,
        readsPerMinutePerUser: Int = 60,
        dailyUploadBytesTotal: Int64 = 100 * 1024 * 1024,
        dailyUploadsTotal: Int = 500,
        dailyReadsTotal: Int = 10_000
    ) {
        self.maxUploadBytesPerPhoto = max(1, maxUploadBytesPerPhoto)
        self.dailyUploadBytesPerUser = max(1, dailyUploadBytesPerUser)
        self.dailyUploadsPerUser = max(1, dailyUploadsPerUser)
        self.uploadsPerMinutePerUser = max(1, uploadsPerMinutePerUser)
        self.dailyReadsPerUser = max(1, dailyReadsPerUser)
        self.readsPerMinutePerUser = max(1, readsPerMinutePerUser)
        self.dailyUploadBytesTotal = max(1, dailyUploadBytesTotal)
        self.dailyUploadsTotal = max(1, dailyUploadsTotal)
        self.dailyReadsTotal = max(1, dailyReadsTotal)
    }

    init() {
        self.init(
            maxUploadBytesPerPhoto: Self.int64("R2_MAX_UPLOAD_BYTES", default: 512 * 1024),
            dailyUploadBytesPerUser: Self.int64("R2_DAILY_UPLOAD_BYTES_PER_USER", default: 5 * 1024 * 1024),
            dailyUploadsPerUser: Self.int("R2_DAILY_UPLOADS_PER_USER", default: 20),
            uploadsPerMinutePerUser: Self.int("R2_UPLOADS_PER_MINUTE_PER_USER", default: 6),
            dailyReadsPerUser: Self.int("R2_DAILY_READS_PER_USER", default: 1_000),
            readsPerMinutePerUser: Self.int("R2_READS_PER_MINUTE_PER_USER", default: 60),
            dailyUploadBytesTotal: Self.int64("R2_DAILY_UPLOAD_BYTES_TOTAL", default: 100 * 1024 * 1024),
            dailyUploadsTotal: Self.int("R2_DAILY_UPLOADS_TOTAL", default: 500),
            dailyReadsTotal: Self.int("R2_DAILY_READS_TOTAL", default: 10_000)
        )
    }

    private static func int(_ name: String, default fallback: Int) -> Int {
        Int(Environment.get(name) ?? "") ?? fallback
    }

    private static func int64(_ name: String, default fallback: Int64) -> Int64 {
        Int64(Environment.get(name) ?? "") ?? fallback
    }
}

enum R2UsageLimitError: Error, Sendable {
    case photoTooLarge(maxBytes: Int64)
    case uploadBurst
    case uploadDailyUser
    case uploadDailyService
    case readBurst
    case readDailyUser
    case readDailyService

    var status: HTTPResponseStatus {
        if case .photoTooLarge = self { return .payloadTooLarge }
        return .tooManyRequests
    }

    var reason: String {
        switch self {
        case .photoTooLarge(let maxBytes):
            return "This photo is too large. Please choose an image under \(Self.byteDescription(maxBytes))."
        case .uploadBurst:
            return "Too many photo uploads in a short period. Please wait a moment and try again."
        case .uploadDailyUser:
            return "Your daily photo upload limit has been reached. Please try again tomorrow."
        case .uploadDailyService:
            return "The service has reached its daily photo safety limit. Please try again tomorrow."
        case .readBurst:
            return "Too many photo requests in a short period. Please wait a moment and try again."
        case .readDailyUser:
            return "Your daily photo viewing limit has been reached. Please try again tomorrow."
        case .readDailyService:
            return "The service has reached its daily photo viewing limit. Please try again tomorrow."
        }
    }

    var retryAfterSeconds: Int? {
        switch self {
        case .photoTooLarge: nil
        case .uploadBurst, .readBurst: 60
        case .uploadDailyUser, .uploadDailyService, .readDailyUser, .readDailyService: 24 * 60 * 60
        }
    }

    var abort: Abort {
        var headers = HTTPHeaders()
        if let retryAfterSeconds {
            headers.replaceOrAdd(name: "Retry-After", value: String(retryAfterSeconds))
        }
        return Abort(status, headers: headers, reason: reason)
    }

    private static func byteDescription(_ bytes: Int64) -> String {
        if bytes >= 1024 * 1024 {
            return "\(max(1, bytes / (1024 * 1024))) MB"
        }
        return "\(max(1, bytes / 1024)) KB"
    }
}

private struct R2UsageKey: Hashable {
    let userID: UUID?
    let day: String
}

private struct R2DailyUsage {
    var uploads = 0
    var uploadBytes: Int64 = 0
    var reads = 0
}

private struct R2BurstWindow {
    var startedAt: Date
    var count: Int
}

/// A process-local guard for the private R2 proxy. Railway currently runs one
/// API replica, so this protects the live service without adding Redis. The
/// daily limits are intentionally conservative and configurable in Railway.
actor R2UsageLimiter: Sendable {
    let limits: R2UsageLimits
    private var daily: [R2UsageKey: R2DailyUsage] = [:]
    private var uploadWindows: [UUID: R2BurstWindow] = [:]
    private var readWindows: [UUID: R2BurstWindow] = [:]

    init(limits: R2UsageLimits = R2UsageLimits()) {
        self.limits = limits
    }

    func reserveUpload(userID: UUID, bytes: Int64, now: Date = Date()) throws {
        guard bytes > 0 else { return }
        guard bytes <= limits.maxUploadBytesPerPhoto else {
            throw R2UsageLimitError.photoTooLarge(maxBytes: limits.maxUploadBytesPerPhoto)
        }

        let day = dayKey(for: now)
        prune(previousTo: day)
        try reserveBurst(userID: userID, now: now, windows: &uploadWindows, limit: limits.uploadsPerMinutePerUser, error: .uploadBurst)

        let userKey = R2UsageKey(userID: userID, day: day)
        let serviceKey = R2UsageKey(userID: nil, day: day)
        var userUsage = daily[userKey, default: R2DailyUsage()]
        var serviceUsage = daily[serviceKey, default: R2DailyUsage()]
        guard userUsage.uploads < limits.dailyUploadsPerUser,
              userUsage.uploadBytes + bytes <= limits.dailyUploadBytesPerUser else {
            throw R2UsageLimitError.uploadDailyUser
        }
        guard serviceUsage.uploads < limits.dailyUploadsTotal,
              serviceUsage.uploadBytes + bytes <= limits.dailyUploadBytesTotal else {
            throw R2UsageLimitError.uploadDailyService
        }

        userUsage.uploads += 1
        userUsage.uploadBytes += bytes
        serviceUsage.uploads += 1
        serviceUsage.uploadBytes += bytes
        daily[userKey] = userUsage
        daily[serviceKey] = serviceUsage
    }

    func refundUpload(userID: UUID, bytes: Int64, now: Date = Date()) {
        guard bytes > 0 else { return }
        let day = dayKey(for: now)
        let userKey = R2UsageKey(userID: userID, day: day)
        let serviceKey = R2UsageKey(userID: nil, day: day)
        if var userUsage = daily[userKey] {
            userUsage.uploads = max(0, userUsage.uploads - 1)
            userUsage.uploadBytes = max(0, userUsage.uploadBytes - bytes)
            daily[userKey] = userUsage
        }
        if var serviceUsage = daily[serviceKey] {
            serviceUsage.uploads = max(0, serviceUsage.uploads - 1)
            serviceUsage.uploadBytes = max(0, serviceUsage.uploadBytes - bytes)
            daily[serviceKey] = serviceUsage
        }
    }

    func reserveRead(userID: UUID, now: Date = Date()) throws {
        let day = dayKey(for: now)
        prune(previousTo: day)
        try reserveBurst(userID: userID, now: now, windows: &readWindows, limit: limits.readsPerMinutePerUser, error: .readBurst)

        let userKey = R2UsageKey(userID: userID, day: day)
        let serviceKey = R2UsageKey(userID: nil, day: day)
        var userUsage = daily[userKey, default: R2DailyUsage()]
        var serviceUsage = daily[serviceKey, default: R2DailyUsage()]
        guard userUsage.reads < limits.dailyReadsPerUser else { throw R2UsageLimitError.readDailyUser }
        guard serviceUsage.reads < limits.dailyReadsTotal else { throw R2UsageLimitError.readDailyService }

        userUsage.reads += 1
        serviceUsage.reads += 1
        daily[userKey] = userUsage
        daily[serviceKey] = serviceUsage
    }

    private func reserveBurst(
        userID: UUID,
        now: Date,
        windows: inout [UUID: R2BurstWindow],
        limit: Int,
        error: R2UsageLimitError
    ) throws {
        if let current = windows[userID], now.timeIntervalSince(current.startedAt) < 60 {
            guard current.count < limit else { throw error }
            windows[userID] = R2BurstWindow(startedAt: current.startedAt, count: current.count + 1)
        } else {
            windows[userID] = R2BurstWindow(startedAt: now, count: 1)
        }
    }

    private func prune(previousTo day: String) {
        daily = daily.filter { $0.key.day >= day }
    }

    private func dayKey(for date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }
}

extension Application {
    private struct R2UsageLimiterKey: StorageKey {
        typealias Value = R2UsageLimiter
    }

    var r2UsageLimiter: R2UsageLimiter {
        get {
            if let existing = storage[R2UsageLimiterKey.self] { return existing }
            let limiter = R2UsageLimiter()
            storage[R2UsageLimiterKey.self] = limiter
            return limiter
        }
        set { storage[R2UsageLimiterKey.self] = newValue }
    }
}
