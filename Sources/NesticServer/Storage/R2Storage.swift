import Logging
import NIOCore
import SotoCore
import SotoS3
import Vapor

struct R2StorageConfiguration: Sendable {
    let endpoint: String
    let bucket: String
    let accessKeyID: String
    let secretAccessKey: String

    init?() {
        guard let endpoint = Environment.get("R2_ENDPOINT"), !endpoint.isEmpty,
              let bucket = Environment.get("R2_BUCKET"), !bucket.isEmpty,
              let accessKeyID = Environment.get("R2_ACCESS_KEY_ID"), !accessKeyID.isEmpty,
              let secretAccessKey = Environment.get("R2_SECRET_ACCESS_KEY"), !secretAccessKey.isEmpty else {
            return nil
        }

        self.endpoint = endpoint
        self.bucket = bucket
        self.accessKeyID = accessKeyID
        self.secretAccessKey = secretAccessKey
    }
}

/// Private object storage for subject avatars and event photos. The R2 bucket
/// is never public; the API proxies reads after checking nest membership.
final class R2Storage: @unchecked Sendable {
    private let client: AWSClient
    private let s3: S3
    let bucket: String

    init(configuration: R2StorageConfiguration) {
        self.client = AWSClient(
            credentialProvider: .static(
                accessKeyId: configuration.accessKeyID,
                secretAccessKey: configuration.secretAccessKey
            )
        )
        self.s3 = S3(
            client: client,
            region: .other("auto"),
            endpoint: configuration.endpoint
        )
        self.bucket = configuration.bucket
    }

    func put(key: String, body: ByteBuffer, contentType: String, logger: Logger) async throws {
        let request = S3.PutObjectRequest(
            body: AWSHTTPBody(buffer: body),
            bucket: bucket,
            contentType: contentType,
            key: key
        )
        _ = try await s3.putObject(request, logger: logger)
    }

    func get(key: String, logger: Logger) async throws -> ByteBuffer? {
        let request = S3.GetObjectRequest(bucket: bucket, key: key)
        return try await s3.getObject(request, logger: logger).body.collect(upTo: 2 * 1024 * 1024)
    }

    func delete(key: String, logger: Logger) async throws {
        let request = S3.DeleteObjectRequest(bucket: bucket, key: key)
        _ = try await s3.deleteObject(request, logger: logger)
    }

    func shutdown() async {
        try? await client.shutdown()
    }

    static func key(for entityID: UUID) -> String {
        "subjects/\(entityID.uuidString.lowercased())/avatar.jpg"
    }

    static func key(forEventID eventID: UUID) -> String {
        "events/\(eventID.uuidString.lowercased())/photo.jpg"
    }

    static func key(forEventPhotoID photoID: UUID) -> String {
        "event-photo-updates/\(photoID.uuidString.lowercased()).jpg"
    }

    static func reference(for key: String) -> String {
        "r2://\(key)"
    }

    static func key(from reference: String?) -> String? {
        guard let reference, reference.hasPrefix("r2://") else { return nil }
        let key = String(reference.dropFirst("r2://".count))
        return key.isEmpty ? nil : key
    }
}

extension Application {
    private struct R2StorageKey: StorageKey {
        typealias Value = R2Storage
    }

    var r2Storage: R2Storage? {
        get { storage[R2StorageKey.self] }
        set { storage[R2StorageKey.self] = newValue }
    }
}

struct R2StorageLifecycle: LifecycleHandler {
    func shutdownAsync(_ application: Application) async {
        await application.r2Storage?.shutdown()
    }
}
