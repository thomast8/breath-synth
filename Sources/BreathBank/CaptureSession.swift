import BreathEngine
import Foundation

/// What one enrollment session captured: the room-tone clip plus, per technique step, the recorded
/// takes and how they should be graded/pooled. Written as `captures.json` in the enrollment folder
/// by `BreathEnrollApp`, read by the `breath-bank` builder. Shared here so neither side owns it.
public struct CaptureSession: Codable, Sendable {
    public struct Step: Codable, Sendable {
        public var slug: String
        public var style: String
        public var type: BreathType
        public var renderMode: RenderMode
        /// Builder role: "texture" (grains), "oneShotBody" (frc/rv), "cores" / "gaps" (packing).
        public var role: String
        /// Gold reference take filename (grading template), in the assets dir.
        public var reference: String?
        /// Recorded take filenames, relative to the enrollment folder.
        public var files: [String]
        /// Per-technique take-length bounds (seconds). A take outside the band is graded "length"
        /// (all its fragments rejected). `nil` (older captures) disables the length gate.
        public var minSeconds: Double?
        public var maxSeconds: Double?

        public init(
            slug: String, style: String, type: BreathType, renderMode: RenderMode,
            role: String, reference: String?, files: [String],
            minSeconds: Double? = nil, maxSeconds: Double? = nil
        ) {
            self.slug = slug
            self.style = style
            self.type = type
            self.renderMode = renderMode
            self.role = role
            self.reference = reference
            self.files = files
            self.minSeconds = minSeconds
            self.maxSeconds = maxSeconds
        }
    }

    public var roomTone: String?
    public var steps: [Step]

    public init(roomTone: String?, steps: [Step]) {
        self.roomTone = roomTone
        self.steps = steps
    }

    public func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    public static func load(from url: URL) throws -> CaptureSession {
        try JSONDecoder().decode(CaptureSession.self, from: Data(contentsOf: url))
    }
}
