import Foundation

/// A noise-floor estimate that adapts across a session's takes instead of freezing at one session-start
/// reading — each take's own pre-onset ambient (see `CaptureAnalyzer.preOnsetFloorRMS`) blends in via
/// `update(with:)`, feeding the *next* take's `activityThreshold` (a take's own floor can't gate its own
/// onset — `activityThreshold` is fixed at analyzer `init`, before that take's audio exists).
///
/// The blend is asymmetric on purpose: an inflated floor silently raises `activityThreshold` and can
/// swallow a genuinely gentle breath entirely (this session's original finding, PR #11) — the failure
/// mode that matters. A floor that's too low only costs a few onset *candidates* the width/spectral
/// gates already filter, and `absActivityFloor` backstops it regardless. So a single loud reading (a
/// chair creak, a door) is clamped to a bounded step up, while the value is free to fall immediately
/// once the room quiets — asymmetric risk gets an asymmetric response.
public struct RollingNoiseFloor: Sendable, Equatable {
    /// Weight on each new reading — larger adapts faster. 0.35 settles to a new steady ambient level
    /// within ~3 takes, matching how often a session's conditions actually change (HVAC cycling,
    /// someone entering the room) rather than chasing every take's own measurement noise.
    private static let alpha: Float = 0.35
    /// An upward move is capped to this multiple of the current value per take — a one-off loud take
    /// moves the floor at most 1.35× (`alpha` of a 1.5× step), not straight to whatever it measured.
    private static let maxUpStepRatio: Float = 1.5

    public private(set) var value: Float?

    public init(value: Float? = nil) {
        self.value = value
    }

    public mutating func update(with reading: Float) {
        guard let current = value else {
            value = reading
            return
        }
        let clampedReading = reading > current ? min(reading, current * Self.maxUpStepRatio) : reading
        value = current + (clampedReading - current) * Self.alpha
    }
}
