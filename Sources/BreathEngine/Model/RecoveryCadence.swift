import Foundation

/// The timing of one recovery hook breath, and of the release that precedes the first one after
/// a full or packed hold. All values are seconds.
///
/// A recorded hook (`recovery.aifc`) is a quick sip in and an out-release about half a second
/// later, ~1 s per breath. Played back as recorded, five recovery breaths took ~5 s where a
/// trainer budgets ~20 s, and a guide drawn from the rendered length ran at twice a usable pace.
/// The recovery-breath render lays each breath out on this cadence instead, so a caller that draws
/// a guide from the same numbers is in step with the audio by construction:
///
/// - `inhale`: a quick, deep textured inhale.
/// - `hook`: the held, pressured pause after the inhale (silence).
/// - `exhale`: the recording's own out-release, crossfaded into a calm exhale for the remainder.
/// - `pause`: silence before the next breath.
/// - `release`: the audible exhale that empties full lungs before the first hook breath. Not part
///   of a breath; rendered on its own by `renderRecoveryReleaseSamples`.
public struct RecoveryCadence: Sendable, Hashable {
    public var inhale: Double
    public var hook: Double
    public var exhale: Double
    public var pause: Double
    public var release: Double
    /// Peak of each hook's recorded out-release. By-ear tunable.
    public var hookPeak: Float
    /// The calm exhale after a hook's release, as a fraction of the release's attack RMS. A release
    /// is a short burst and the exhale after it is passive airflow, so the tail sits below it.
    public var tailLevel: Float
    /// Gain on the post-hold release, relative to a normally rendered calm exhale.
    public var releaseLevel: Float

    public init(
        inhale: Double = 1.0,
        hook: Double = 1.0,
        exhale: Double = 1.5,
        pause: Double = 0.5,
        release: Double = 2.5,
        hookPeak: Float = 0.6,
        tailLevel: Float = 0.85,
        releaseLevel: Float = 1.3
    ) {
        self.inhale = inhale
        self.hook = hook
        self.exhale = exhale
        self.pause = pause
        self.release = release
        self.hookPeak = hookPeak
        self.tailLevel = tailLevel
        self.releaseLevel = releaseLevel
    }

    /// One in, one hook, one out, one pause: four seconds a breath.
    public static let standard = RecoveryCadence()

    /// The length of one hook breath (everything but `release`).
    public var breathSec: Double { max(0, inhale) + max(0, hook) + max(0, exhale) + max(0, pause) }

    /// Stable text for seeding (timing only, so a loudness change keeps the same breaths), so an unseeded render of a given cadence is reproducible.
    var canonicalString: String { "\(inhale)|\(hook)|\(exhale)|\(pause)|\(release)" }
}
