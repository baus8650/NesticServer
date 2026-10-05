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
