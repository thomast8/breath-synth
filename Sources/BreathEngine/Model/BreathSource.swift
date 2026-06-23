import Foundation

/// Procedural generator families available for pure-DSP rendering.
public enum ProceduralGeneratorKind: String, Sendable, Equatable, CaseIterable {
    /// 1D vocal-tract tube / waveguide model with turbulent airflow injection.
    case tract
    /// Klatt-style aspiration/frication source through vocal-tract formants.
    case klatt
    /// Stochastic micro-burst turbulence model with moving constrictions.
    case granular
    /// The original filtered-noise procedural renderer, kept for comparison.
    case legacy
}

/// Pure procedural generator settings.
public struct ProceduralBreathConfig: Sendable, Equatable {
    /// Which procedural generator family to use.
    public var generator: ProceduralGeneratorKind
    /// Overall procedural source gain before the engine's master gain/headroom.
    public var airGain: Double
    /// Resonance amount for the light mouth/nose formant bands.
    public var resonanceAmount: Double
    /// Slow gain/filter movement amount.
    public var modulationAmount: Double

    public init(
        generator: ProceduralGeneratorKind = .tract,
        airGain: Double = 0.30,
        resonanceAmount: Double = 0.35,
        modulationAmount: Double = 0.025
    ) {
        self.generator = generator
        self.airGain = airGain
        self.resonanceAmount = resonanceAmount
        self.modulationAmount = modulationAmount
    }

    /// Soft, breath-like meditation texture. This is intentionally "calm air",
    /// not close-mic hyper-real mouth detail.
    public static let calmAir = ProceduralBreathConfig()
}

/// How the engine obtains source audio.
public enum BreathSource: Sendable, Equatable {
    /// Generate breath-like audio entirely in DSP.
    case procedural(ProceduralBreathConfig = .calmAir)
    /// Assemble breaths from a sampled palette on disk.
    case assets(directory: URL, manifest: BreathManifest)
}
