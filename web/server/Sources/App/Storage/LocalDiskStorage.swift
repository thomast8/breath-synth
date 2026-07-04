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

    private func url(for key: String) -> URL {
        root.appendingPathComponent(key)
    }

    public func put(_ data: Data, key: String) async throws {
        let fileURL = url(for: key)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
    }

    public func get(key: String) async throws -> Data {
        try Data(contentsOf: url(for: key))
    }

    public func list(prefix: String) async throws -> [String] {
        let dir = url(for: prefix)
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
        FileManager.default.fileExists(atPath: url(for: key).path)
    }

    public func localURL(forKey key: String) async throws -> URL {
        url(for: key)
    }
}
