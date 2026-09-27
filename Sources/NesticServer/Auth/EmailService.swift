import Vapor

private struct ResendEmailRequest: Content {
    let from: String
    let to: [String]
    let subject: String
    let html: String
    let text: String
}

enum NesticEmailService {
    static func sendVerification(on req: Request, to email: String, displayName: String, token: String) async throws {
        let link = makeLink(base: apiURL(), path: "/auth/verify", queryName: "token", token: token)
        try await send(
            on: req,
            to: email,
            subject: "Verify your Nestic email",
            html: page(title: "Verify your Nestic email", greeting: "Hi \(escape(displayName)),", body: "Confirm your email address to finish creating your Nestic account.", button: "Verify email", link: link),
            text: "Hi \(displayName),\n\nVerify your Nestic email address here:\n\(link)\n\nThis link expires in 24 hours."
        )
    }

    static func sendPasswordReset(on req: Request, to email: String, displayName: String, token: String) async throws {
        let link = makeLink(base: webURL(), path: "/", queryName: "reset_token", token: token)
        try await send(
            on: req,
            to: email,
            subject: "Reset your Nestic password",
            html: page(title: "Reset your Nestic password", greeting: "Hi \(escape(displayName)),", body: "Someone requested a new password for your Nestic account. If that was you, continue below.", button: "Choose a new password", link: link),
            text: "Hi \(displayName),\n\nChoose a new Nestic password here:\n\(link)\n\nThis link expires in one hour. If you did not request this, you can ignore this email."
        )
    }

    private static func send(on req: Request, to email: String, subject: String, html: String, text: String) async throws {
        guard let apiKey = Environment.get("RESEND_API_KEY"), !apiKey.isEmpty else {
            throw Abort(.failedDependency, reason: "Email delivery is not configured yet.")
        }

        let payload = ResendEmailRequest(
            from: Environment.get("RESEND_FROM") ?? "Nestic <noreply@nestic-app.com>",
            to: [email], subject: subject, html: html, text: text
        )
        let response = try await req.application.client.post(URI(string: "https://api.resend.com/emails")) { request in
            request.headers.replaceOrAdd(name: .authorization, value: "Bearer \(apiKey)")
            request.headers.replaceOrAdd(name: .contentType, value: "application/json")
            try request.content.encode(payload)
        }
        guard response.status.code >= 200, response.status.code < 300 else {
            req.logger.error("Resend rejected an email", metadata: ["status": .string(String(response.status.code))])
            throw Abort(.badGateway, reason: "Email delivery is temporarily unavailable.")
        }
    }

    private static func webURL() -> String {
        (Environment.get("WEB_APP_URL") ?? "https://www.nestic-app.com").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private static func apiURL() -> String {
        (Environment.get("API_PUBLIC_URL") ?? "https://api.nestic-app.com").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private static func makeLink(base: String, path: String, queryName: String, token: String) -> String {
        var components = URLComponents(string: base + path)
        components?.queryItems = [URLQueryItem(name: queryName, value: token)]
        return components?.url?.absoluteString ?? "\(base)\(path)?\(queryName)=\(token)"
    }

    private static func page(title: String, greeting: String, body: String, button: String, link: String) -> String {
        """
        <!doctype html><html><body style="margin:0;background:#f5f1e8;color:#183b2c;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif"><main style="max-width:560px;margin:48px auto;padding:36px;background:#fffdf8;border:1px solid #ded8cb;border-radius:18px"><div style="font-size:26px;font-weight:800;letter-spacing:-.04em">nestic</div><h1 style="font-size:28px;margin:30px 0 12px">\(title)</h1><p style="font-size:16px;line-height:1.6">\(greeting)</p><p style="font-size:16px;line-height:1.6">\(body)</p><p style="margin:30px 0"><a href="\(link)" style="display:inline-block;background:#183b2c;color:#fff;padding:14px 20px;border-radius:10px;text-decoration:none;font-weight:700">\(button)</a></p><p style="font-size:13px;line-height:1.5;color:#68746d">If the button does not work, copy this link into your browser:<br>\(link)</p></main></body></html>
        """
    }

    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
