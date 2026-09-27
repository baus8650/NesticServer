import NIOHTTP1
import Vapor

/// A small, process-local guard for the unauthenticated auth endpoints.
///
/// This is intentionally a first line of defense, not a replacement for an
/// edge/WAF rate limit. Railway can run more than one replica, so production
/// deployments should also configure Cloudflare rate limiting in front of the
/// service. Keeping the limiter here still protects a single instance from a
/// burst of password guesses or account-creation requests.
actor AuthRateLimiter: Sendable {
    struct Decision: Sendable {
        let allowed: Bool
        let retryAfter: Int
    }

    private struct Bucket: Sendable {
        var startedAt: Date
        var count: Int
    }

    private var buckets: [String: Bucket] = [:]
    private let loginLimit: Int
    private let loginWindow: TimeInterval
    private let registerLimit: Int
    private let registerWindow: TimeInterval
    private let appleLimit: Int
    private let appleWindow: TimeInterval
    private let recoveryLimit: Int
    private let recoveryWindow: TimeInterval

    init() {
        // Conservative defaults that are still usable on a shared home or
        // office network. Every value can be overridden in Railway.
        loginLimit = max(1, Int(Environment.get("AUTH_LOGIN_LIMIT") ?? "12") ?? 12)
        loginWindow = max(10, TimeInterval(Environment.get("AUTH_LOGIN_WINDOW_SECONDS") ?? "60") ?? 60)
        registerLimit = max(1, Int(Environment.get("AUTH_REGISTER_LIMIT") ?? "6") ?? 6)
        registerWindow = max(60, TimeInterval(Environment.get("AUTH_REGISTER_WINDOW_SECONDS") ?? "3600") ?? 3600)
        appleLimit = max(1, Int(Environment.get("AUTH_APPLE_LIMIT") ?? "12") ?? 12)
        appleWindow = max(10, TimeInterval(Environment.get("AUTH_APPLE_WINDOW_SECONDS") ?? "60") ?? 60)
        recoveryLimit = max(1, Int(Environment.get("AUTH_RECOVERY_LIMIT") ?? "5") ?? 5)
        recoveryWindow = max(60, TimeInterval(Environment.get("AUTH_RECOVERY_WINDOW_SECONDS") ?? "3600") ?? 3600)
    }

    func check(operation: String, key: String) -> Decision {
        let now = Date()
        let (limit, window): (Int, TimeInterval) = {
            switch operation {
            case "register": return (registerLimit, registerWindow)
            case "apple": return (appleLimit, appleWindow)
            case "forgot", "reset", "resend", "verify": return (recoveryLimit, recoveryWindow)
            default: return (loginLimit, loginWindow)
            }
        }()

        let bucketKey = "\(operation):\(key)"
        if let current = buckets[bucketKey], now.timeIntervalSince(current.startedAt) < window {
            if current.count >= limit {
                let retry = max(1, Int(ceil(window - now.timeIntervalSince(current.startedAt))))
                return Decision(allowed: false, retryAfter: retry)
            }
            buckets[bucketKey] = Bucket(startedAt: current.startedAt, count: current.count + 1)
        } else {
            buckets[bucketKey] = Bucket(startedAt: now, count: 1)
        }

        // Keep a long-running instance from retaining one bucket per scanner
        // forever. Expired entries are safe to discard.
        if buckets.count > 10_000 {
            buckets = buckets.filter { entry in
                let window = entry.key.hasPrefix("register:") ? registerWindow :
                    (entry.key.hasPrefix("apple:") ? appleWindow :
                        (entry.key.hasPrefix("forgot:") || entry.key.hasPrefix("reset:") || entry.key.hasPrefix("resend:") || entry.key.hasPrefix("verify:") ? recoveryWindow : loginWindow))
                return now.timeIntervalSince(entry.value.startedAt) < window
            }
        }
        return Decision(allowed: true, retryAfter: 0)
    }
}

extension Application {
    private struct AuthRateLimiterKey: StorageKey {
        typealias Value = AuthRateLimiter
    }

    var authRateLimiter: AuthRateLimiter {
        get {
            if let existing = storage[AuthRateLimiterKey.self] { return existing }
            let limiter = AuthRateLimiter()
            storage[AuthRateLimiterKey.self] = limiter
            return limiter
        }
        set { storage[AuthRateLimiterKey.self] = newValue }
    }
}

extension Request {
    /// Apply a per-client auth limit. We deliberately use the socket address
    /// only; forwarded headers are not trusted unless the deployment has a
    /// trusted proxy configuration.
    func enforceAuthRateLimit(operation: String) async throws {
        let address = remoteAddress.map(String.init(describing:)) ?? "unknown"
        let decision = await application.authRateLimiter.check(operation: operation, key: address)
        guard decision.allowed else {
            var headers = HTTPHeaders()
            headers.replaceOrAdd(name: .retryAfter, value: String(decision.retryAfter))
            throw Abort(.tooManyRequests, headers: headers,
                        reason: "Too many requests. Please wait a moment and try again.")
        }
    }
}
