import Vapor

/// Shared API boundaries. Keeping these independent of the database makes failures testable.
enum InputValidation {
    static func name(_ value: String, field: String = "Name") throws -> String {
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.count <= 100 else {
            throw Abort(.badRequest, reason: "\(field) must contain 1–100 characters.")
        }
        return clean
    }

    static func email(_ value: String) throws -> String {
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let parts = clean.split(separator: "@", omittingEmptySubsequences: false)
        guard clean.count <= 254, parts.count == 2, !parts[0].isEmpty,
              parts[1].contains("."), !parts[1].hasPrefix("."), !parts[1].hasSuffix("."),
              !clean.contains(where: { $0.isWhitespace }) else {
            throw Abort(.badRequest, reason: "Enter a valid email address.")
        }
        return clean
    }

    static func password(_ value: String) throws {
        guard value.count >= 8, value.utf8.count <= 72 else {
            throw Abort(.badRequest, reason: "Password must be at least 8 characters and at most 72 UTF-8 bytes.")
        }
    }

    static func trackerSymbol(_ value: String?) throws -> String? {
        guard let value else { return nil }
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.count <= 64 else {
            throw Abort(.badRequest, reason: "Choose a shorter tracker icon.")
        }
        return clean.isEmpty ? nil : clean
    }

    static func trackerColor(_ value: String?) throws -> String? {
        guard let value else { return nil }
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return nil }
        let digits = clean.hasPrefix("#") ? String(clean.dropFirst()) : clean
        guard digits.count == 6, UInt64(digits, radix: 16) != nil else {
            throw Abort(.badRequest, reason: "Choose a valid tracker color.")
        }
        return "#\(digits.uppercased())"
    }

    static func event(type: ActionValueType, number: Double?, text: String?, boolean: Bool?,
                      json: [String: String]?, note: String?) throws {
        let supplied = [number != nil, text != nil, boolean != nil, json != nil].filter { $0 }.count
        let matches: Bool
        switch type {
        case .none: matches = supplied == 0
        case .number: matches = supplied == 1 && number?.isFinite == true
        case .text: matches = supplied == 1 && text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        case .boolean: matches = supplied == 1 && boolean != nil
        case .json: matches = supplied == 1 && json?.isEmpty == false
        case .photo: matches = supplied == 0
        }
        guard matches else { throw Abort(.badRequest, reason: "This tracker requires a \(type.rawValue) value.") }
        guard (text?.count ?? 0) <= 2000, (note?.count ?? 0) <= 2000,
              (json?.count ?? 0) <= 50,
              json?.allSatisfy({ $0.key.count <= 100 && $0.value.count <= 2000 }) ?? true else {
            throw Abort(.badRequest, reason: "Notes and text are limited to 2,000 characters; structured values to 50 fields.")
        }
    }
}
