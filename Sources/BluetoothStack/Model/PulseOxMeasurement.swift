import Foundation

/// Signal-quality summary derived from a parsed frame.
public enum SignalQuality: String, Sendable, Equatable, CaseIterable {
    case good
    case searching
    case lowPerfusion
    case noFinger
    case unknown
}

/// One decoded reading from a pulse oximeter.
///
/// `spo2`/`pulseRate` are optional: a frame can be structurally valid yet carry no usable number
/// (finger removed, still searching, or a sentinel like `0x7F`/`0xFF`). `raw` always carries the
/// source bytes so even an undecoded frame can be dumped during reverse-engineering.
public struct PulseOxMeasurement: Sendable, Equatable {
    public var spo2: Double?
    public var pulseRate: Double?
    public var perfusionIndex: Double?
    public var plethRaw: Int?
    public var fingerDetected: Bool
    public var quality: SignalQuality
    public var timestamp: Date
    public var raw: Data

    public init(
        spo2: Double? = nil,
        pulseRate: Double? = nil,
        perfusionIndex: Double? = nil,
        plethRaw: Int? = nil,
        fingerDetected: Bool = false,
        quality: SignalQuality = .unknown,
        timestamp: Date = Date(),
        raw: Data = Data()
    ) {
        self.spo2 = spo2
        self.pulseRate = pulseRate
        self.perfusionIndex = perfusionIndex
        self.plethRaw = plethRaw
        self.fingerDetected = fingerDetected
        self.quality = quality
        self.timestamp = timestamp
        self.raw = raw
    }
}
