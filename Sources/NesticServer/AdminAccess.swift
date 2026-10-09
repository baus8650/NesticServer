import Vapor

private let builtInNesticAdminEmails: Set<String> = [
    "baus8650@gmail.com"
]

func nesticAdminEmails() -> Set<String> {
    let configured = (Environment.get("NESTIC_ADMIN_EMAILS") ?? "")
        .split(separator: ",")
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        .filter { !$0.isEmpty }
    return builtInNesticAdminEmails.union(configured)
}

func isNesticAdmin(_ user: User) -> Bool {
    user.emailVerified && nesticAdminEmails().contains(user.email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
}

extension Request {
    func requireNesticAdmin() async throws -> User {
        let userID = try requireUserID()
        guard let user = try await User.find(userID, on: db), isNesticAdmin(user) else {
            throw Abort(.forbidden, reason: "Administrator access is required.")
        }
        return user
    }
}

/// A saved admin decision takes precedence over the legacy email allowlist.
/// Nil keeps existing accounts on their configured access until an admin acts.
func manuallyUnlockedPro(for user: User) -> Bool {
    let emails = (Environment.get("NESTIC_MANUAL_PRO_EMAILS") ?? "")
        .split(separator: ",")
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
    return manualProAccess(override: user.manualProOverride, email: user.email,
                           configuredEmails: Set(emails))
}

func manualProAccess(override: Bool?, email: String, configuredEmails: Set<String>) -> Bool {
    if let override { return override }
    return configuredEmails.contains(email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
}

struct UpdateManualProRequest: Content {
    let enabled: Bool
}
