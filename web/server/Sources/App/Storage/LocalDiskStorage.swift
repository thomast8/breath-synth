import Foundation

/// `StorageDriver` backed by a plain directory tree — the Railway volume mount in prod, a local
/// `./data` directory in dev. Keys are relative paths (`sessions/<id>/<lane>_take<NN>.wav`); slashes
/// map to real subdirectories.
public struct LocalDiskStorage: StorageDriver {
    private let root: URL

    public init(root: URL) {
        self.root = root
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    /// Defense-in-depth against a path-traversal key (`"../../etc/passwd"`) reaching disk I/O —
    /// every method funnels through here, so this holds regardless of whether an individual caller
    /// (`TakesController`, `SessionExporter`, ...) already validated its own input. Compares
    /// standardized paths rather than trusting `key` not to contain `..`/absolute-path segments.
    private func url(for key: String) throws -> URL {
        let candidate = root.appendingPathComponent(key).standardizedFileURL
        let rootPath = root.standardizedFileURL.path
        let candidatePath = candidate.path
        guard candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/") else {
            throw StorageError.keyEscapesRoot(key)
        }
        return candidate
    }

    public func put(_ data: Data, key: String) async throws {
        let fileURL = try url(for: key)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
    }

    public func get(key: String) async throws -> Data {
        try Data(contentsOf: url(for: key))
    }

    public func list(prefix: String) async throws -> [String] {
        let dir = try url(for: prefix)
        guard let enumerator = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey])
        else { return [] }
        // `NSEnumerator`'s for-in iteration isn't Sendable-safe in an async context; `allObjects`
        // drains it synchronously into a plain array first, which is fine to iterate afterward.
        let fileURLs = enumerator.allObjects.compactMap { $0 as? URL }
        var keys: [String] = []
        let rootPath = root.standardizedFileURL.path
        for fileURL in fileURLs {
            let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            let path = fileURL.standardizedFileURL.path
            guard path.hasPrefix(rootPath) else { continue }
            let key = String(path.dropFirst(rootPath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            keys.append(key)
        }
        return keys.sorted()
    }

    public func exists(key: String) async throws -> Bool {
        FileManager.default.fileExists(atPath: try url(for: key).path)
    }

    public func delete(prefix: String) async throws {
        let dir = try url(for: prefix)
        guard FileManager.default.fileExists(atPath: dir.path) else { return }
        try FileManager.default.removeItem(at: dir)
    }

    public func localURL(forKey key: String) async throws -> URL {
        try url(for: key)
    }
}

enum StorageError: Error, CustomStringConvertible {
    case keyEscapesRoot(String)

    var description: String {
        switch self {
        case .keyEscapesRoot(let key): return "Storage key resolves outside its root: \(key)"
        }
    }
}
