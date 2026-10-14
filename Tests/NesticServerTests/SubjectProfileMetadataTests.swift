import Foundation
import Testing
@testable import NesticServer

struct SubjectProfileMetadataTests {
    @Test func legacyPhotoUpdatesKeepOptionalProfileFields() {
        let current = ["emoji": "🐶", "birthday": "2000-02-29", "weightKg": "45.359237", "weightUnit": "lb"]
        let updated = SubjectProfileMetadata.updated(current: current, replacement: ["emoji": "🐱"], replaceProfileDetails: false)
        #expect(updated["emoji"] == "🐱" && updated["birthday"] == current["birthday"])
        #expect(updated["weightKg"] == current["weightKg"] && updated["weightUnit"] == "lb")
    }
    @Test func explicitProfileEditsCanClearFields() {
        let updated = SubjectProfileMetadata.updated(current: ["birthday": "2000-02-29", "weightKg": "45"], replacement: ["emoji": "🐶"], replaceProfileDetails: true)
        #expect(updated["birthday"] == nil && updated["weightKg"] == nil)
    }
    @Test func onlyExplicitProfileEditsReplacePreviousValues() {
        let updated = SubjectProfileMetadata.updated(current: ["weightKg": "45"], replacement: ["weightKg": "50"], replaceProfileDetails: false)
        #expect(updated["weightKg"] == "45")
        #expect(SubjectProfileMetadata.updated(current: ["weightKg": "45"], replacement: ["weightKg": "50"], replaceProfileDetails: true)["weightKg"] == "50")
    }
}

struct WeightHistoryTests {
    @Test func recordsOnlyChangesAndRejectsClientHistoryRewrites() throws {
        let first = SubjectProfileMetadata.updated(current: nil, replacement: ["weightKg":"10", "weightHistoryJSON":"fake"], replaceProfileDetails: true, now: Date(timeIntervalSince1970: 100))
        let unchanged = SubjectProfileMetadata.updated(current: first, replacement: first, replaceProfileDetails: true, now: Date(timeIntervalSince1970: 200))
        #expect(first["weightHistoryJSON"] == unchanged["weightHistoryJSON"])
        let second = SubjectProfileMetadata.updated(current: unchanged, replacement: ["weightKg":"20"], replaceProfileDetails: true, now: Date(timeIntervalSince1970: 300))
        let cleared = SubjectProfileMetadata.updated(current: second, replacement: [:], replaceProfileDetails: true, now: Date(timeIntervalSince1970: 400))
        let rows = try JSONDecoder().decode([SubjectProfileMetadata.WeightRecord].self, from: Data(cleared["weightHistoryJSON"]!.utf8))
        #expect(rows.count == 3 && rows[0].recordedAt == 100 && rows[1].weightKg == 20 && rows[2].weightKg == nil)
        let legacy = SubjectProfileMetadata.updated(current: second, replacement: ["emoji":"🐶", "weightHistoryJSON":"fake"], replaceProfileDetails: false)
        #expect(legacy["weightHistoryJSON"] == second["weightHistoryJSON"])
    }
}
