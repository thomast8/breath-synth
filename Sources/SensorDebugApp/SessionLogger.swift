import Foundation

/// Fans every debug event out to two sinks so an external observer sees exactly what the GUI sees:
///   1. a live SSE stream  — `curl -N http://127.0.0.1:<port>/`  (default port 8787)
///   2. a newline-delimited JSON file — persistent capture + fixture source
///
/// File path: `$SENSOR_DEBUG_LOG` if set, else `~/Library/Logs/SensorDebug/session.jsonl` (truncated
/// at launch). Stream port: `$SENSOR_DEBUG_PORT` if set, else 8787. Writes go through a private serial
/// queue with fsync per line, so a `tail -F` / `curl -N` sees events immediately. `@unchecked Sendable`
/// is sound: the file descriptor is written exclusively on that queue and is immutable after init.
final class SessionLogger: @unchecked Sendable {
    let url: URL
    let server: DebugStreamServer
    private let fd: Int32
    private let queue = DispatchQueue(label: "com.breathsynth.SessionLogger")

    init() {
        let env = ProcessInfo.processInfo.environment
        if let override = env["SENSOR_DEBUG_LOG"], !override.isEmpty {
            url = URL(fileURLWithPath: override)
        } else {
            let dir = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Logs/SensorDebug", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            url = dir.appendingPathComponent("session.jsonl")
        }
        fd = open(url.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)

        let port = env["SENSOR_DEBUG_PORT"].flatMap { UInt16($0) } ?? 8787
        server = DebugStreamServer(port: port)
        server.start()
    }

    deinit {
        server.stop()
        if fd >= 0 { close(fd) }
    }

    /// Append + broadcast one event. `fields` values must be JSON-serializable
    /// (String/Number/Bool/Array/Dict/NSNull).
    func log(_ event: String, _ fields: [String: Any] = [:]) {
        var object = fields
        object["event"] = event
        object["wall"] = Date().timeIntervalSince1970
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return }
        let line = String(decoding: data, as: UTF8.self)
        server.broadcast(line)
        guard fd >= 0 else { return }
        queue.async { [fd] in
            _ = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            _ = [UInt8(0x0A)].withUnsafeBytes { write(fd, $0.baseAddress, 1) }
            fsync(fd)
        }
    }
}
