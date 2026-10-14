import Foundation

enum SubjectProfileMetadata {
    static let keys: Set<String> = ["birthday", "weightKg", "weightUnit", "weightHistoryJSON"]
    struct WeightRecord: Codable { let recordedAt: Double; let weightKg: Double? }
    static func updated(current: [String: String]?, replacement: [String: String], replaceProfileDetails: Bool, now: Date = Date()) -> [String: String] {
        let previous = current ?? [:]
        var result = replaceProfileDetails ? replacement : replacement.merging(previous.filter { keys.contains($0.key) }) { _, existing in existing }
        // Weight history is server-owned: clients cannot rewrite historical observations.
        var history = previous["weightHistoryJSON"].flatMap { $0.data(using: .utf8) }.flatMap { try? JSONDecoder().decode([WeightRecord].self, from: $0) } ?? []
        let weight = result["weightKg"].flatMap(Double.init).flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        if replaceProfileDetails && (history.isEmpty && weight != nil || history.last?.weightKg != weight) {
            history.append(WeightRecord(recordedAt: now.timeIntervalSince1970, weightKg: weight))
        }
        result.removeValue(forKey: "weightHistoryJSON")
        if !history.isEmpty, let data = try? JSONEncoder().encode(history) { result["weightHistoryJSON"] = String(data: data, encoding: .utf8) }
        return result
    }
}
