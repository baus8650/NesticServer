enum SubjectProfileMetadata {
    static let keys: Set<String> = ["birthday", "weightKg", "weightUnit"]
    static func updated(current: [String: String]?, replacement: [String: String], replaceProfileDetails: Bool) -> [String: String] {
        guard !replaceProfileDetails else { return replacement }
        // Old clients send only an emoji when changing a photo. Preserve
        // profile details until a client explicitly edits or clears them.
        let protected = (current ?? [:]).filter { keys.contains($0.key) }
        return replacement.merging(protected) { _, existing in existing }
    }
}
