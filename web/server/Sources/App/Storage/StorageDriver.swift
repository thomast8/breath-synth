import Foundation
import Vapor

/// Where uploaded take/room-tone audio lives. One implementation today (`LocalDiskStorage`, rooted
/// at a Railway volume in prod) — kept behind a protocol so a future S3-compatible driver is a
/// drop-in swap, not a rewrite, if the corpus outgrows a single volume.
public protocol StorageDriver: Sendable {
    /// Write `data` at `key`, creating any needed parent directories.
    func put(_ data: Data, key: String) async throws
    /// Read the full contents at `key`.
    func get(key: String) async throws -> Data
    /// Every stored key under `prefix` (e.g. `"sessions/<id>/"`), for building an export.
    func list(prefix: String) async throws -> [String]
    /// Whether something is stored at `key`.
    func exists(key: String) async throws -> Bool
    /// A real on-disk file URL for `key`'s contents — the engine's decode functions
    /// (`AudioIO`/`LiveTakeGrader`) read from `URL`, not `Data`. `LocalDiskStorage` returns the
    /// actual stored file directly; a future remote driver would materialize one into a temp file.
    func localURL(forKey key: String) async throws -> URL
}

extension Application {
    private struct StorageDriverKey: StorageKey {
        typealias Value = any StorageDriver
    }

    public var storageDriver: any StorageDriver {
        get {
            guard let driver = self.storage[StorageDriverKey.self] else {
                fatalError("StorageDriver not configured — call configureStorage(_:) first")
            }
            return driver
        }
        set { self.storage[StorageDriverKey.self] = newValue }
    }
}
