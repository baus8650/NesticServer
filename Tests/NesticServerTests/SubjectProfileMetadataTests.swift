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
