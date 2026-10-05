import Fluent
import Vapor

final class PhotoDeletionJob: Model, @unchecked Sendable {
    static let schema = "photo_deletion_jobs"
    @ID(key: .id) var id: UUID?
    @Field(key: "object_key") var objectKey: String
    init() {}
    init(objectKey: String) { self.objectKey = objectKey }
}

struct CreatePhotoDeletionJobs: AsyncMigration {
    func prepare(on db: any Database) async throws {
        try await db.schema(PhotoDeletionJob.schema).id()
            .field("object_key", .string, .required).create()
    }
    func revert(on db: any Database) async throws {
        try await db.schema(PhotoDeletionJob.schema).delete()
    }
}

/// Database work is committed before remote deletion. Failed object removals
/// remain queued across restarts until storage is available again.
func processPhotoDeletions(on app: Application) async {
    guard let storage = app.r2Storage else { return }
    do {
        let jobs = try await PhotoDeletionJob.query(on: app.db).range(..<100).all()
        for job in jobs {
            do {
                try await storage.delete(key: job.objectKey, logger: app.logger)
                try await job.delete(on: app.db)
            } catch { app.logger.warning("Photo deletion will be retried") }
        }
    } catch { app.logger.warning("Could not load pending photo deletions") }
}

extension Application {
    private struct PhotoDeletionTaskKey: StorageKey { typealias Value = Task<Void, Never> }
    var photoDeletionTask: Task<Void, Never>? {
        get { storage[PhotoDeletionTaskKey.self] }
        set { storage[PhotoDeletionTaskKey.self] = newValue }
    }
}

struct PhotoDeletionLifecycle: LifecycleHandler {
    func didBootAsync(_ app: Application) async throws {
        guard app.environment != .testing else { return }
        app.photoDeletionTask = Task {
            while !Task.isCancelled {
                await processPhotoDeletions(on: app)
                do { try await Task.sleep(for: .seconds(60)) }
                catch { break }
            }
        }
    }
    func shutdownAsync(_ app: Application) async {
        app.photoDeletionTask?.cancel()
        await app.photoDeletionTask?.value
        app.photoDeletionTask = nil
    }
}
