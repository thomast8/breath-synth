import BreathEngine
import Foundation

/// Non-deep, data-light quality grading: plain DSP, no classifier, no labels. A fragment is accepted
/// only if it clears all three stages; rejects keep a reason code (and are never deleted, so the bank
/// stays auditable). Thresholds are by-ear constants, deliberately conservative (reject less rather
/// than discard usable takes) — they want a real-data tuning pass.
public enum Grader {
    public struct Thresholds: Sendable {
        public var clipPeak: Float
        public var clipRunSamples: Int
        public var minSNRdB: Double
        public var bandLowHz: Double
        public var bandHighHz: Double
        /// Robust-z (MAD) cutoff for the sibling-anomaly stage.
        public var madK: Double
        /// Cosine distance (0…1 for non-negative spectra) beyond which a fragment is "off-technique".
        public var maxTemplateDistance: Double
        /// An interior below-floor run this long (s) in a one-shot body is a mid-breath dropout.
        public var dropoutMinGapSec: Double
        /// Relative deviation of a packing take's median gulp spacing from the gold reference's,
        /// beyond which the cadence is judged "drift".
        public var maxRhythmDistance: Double
        /// Minimum inter-onset spacing (s) between packing gulp cores; tighter = merged/rushed.
        public var minCoreSpacingSec: Double

        public init(
            clipPeak: Float = 0.999, clipRunSamples: Int = 3, minSNRdB: Double = 10,
            bandLowHz: Double = 300, bandHighHz: Double = 3000, madK: Double = 3.5,
            maxTemplateDistance: Double = 0.6, dropoutMinGapSec: Double = 0.15,
            maxRhythmDistance: Double = 0.5, minCoreSpacingSec: Double = 0.22
        ) {
            self.clipPeak = clipPeak
            self.clipRunSamples = clipRunSamples
            self.minSNRdB = minSNRdB
            self.bandLowHz = bandLowHz
            self.bandHighHz = bandHighHz
            self.madK = madK
            self.maxTemplateDistance = maxTemplateDistance
            self.dropoutMinGapSec = dropoutMinGapSec
            self.maxRhythmDistance = maxRhythmDistance
            self.minCoreSpacingSec = minCoreSpacingSec
        }

        public static let `default` = Thresholds()
    }

    /// Per-fragment features for grading. `profile` is the 513-bin magnitude spectrum.
    public struct Features: Sendable {
        public var rmsDb: Double
        public var centroidHz: Double
        public var flatness: Double
        public var snrDb: Double
        public var profile: [Float]
        public var clipped: Bool
        public var durationSec: Double

        public init(
            rmsDb: Double, centroidHz: Double, flatness: Double, snrDb: Double,
            profile: [Float], clipped: Bool, durationSec: Double
        ) {
            self.rmsDb = rmsDb
            self.centroidHz = centroidHz
            self.flatness = flatness
            self.snrDb = snrDb
            self.profile = profile
            self.clipped = clipped
            self.durationSec = durationSec
        }
    }

    public struct Verdict: Sendable {
        public var accept: Bool
        public var reason: String?
        public var qaScore: Double
        public var anomalyScore: Double
        public var templateDistance: Double
    }

    // MARK: - Feature extraction

    /// Extract grading features (level, spectrum, SNR, clipping, duration) from a fragment's samples.
    /// Clipping is detected on whatever samples are passed in; the bank builder grades the *prepared /
    /// rendered* fragment audio (so SNR and spectrum match what the engine actually plays) and supplies
    /// the clipping verdict separately as a take-level fact — clipping is invisible post-denoise, so it
    /// is judged once on the raw take. `roomToneProfile` is this session's room-tone profile for SNR.
    public static func features(
        raw: [Float],
        sampleRate: Double,
        roomToneProfile: [Float]?,
        thresholds: Thresholds = .default
    ) -> Features {
        let profile = SpectralDenoise.magnitudeProfile(from: raw, sampleRate: sampleRate)
        let level = rms(raw)
        let binHz = sampleRate / 1024.0
        return Features(
            rmsDb: level > 0 ? 20 * log10(Double(level)) : -120,
            centroidHz: spectralCentroid(profile, binHz: binHz),
            flatness: spectralFlatness(profile),
            snrDb: snrDb(profile: profile, room: roomToneProfile, binHz: binHz,
                         low: thresholds.bandLowHz, high: thresholds.bandHighHz),
            profile: profile,
            clipped: clippingRun(raw, peak: thresholds.clipPeak, minRun: thresholds.clipRunSamples),
            durationSec: Double(raw.count) / sampleRate
        )
    }

    // MARK: - Stages

    /// Stage (c): cosine distance of a fragment's spectrum to the gold reference's. 0 when no gold.
    public static func templateDistance(_ f: Features, gold: [Float]?) -> Double {
        guard let gold, gold.count == f.profile.count, !gold.isEmpty else { return 0 }
        return cosineDistance(f.profile, gold)
    }

    /// Stage (b): robust-z (MAD) of a fragment vs its take's sibling fragments over [rmsDb, centroid,
    /// flatness]. The worst dimension wins. Needs ≥3 siblings to be meaningful (else 0 = don't reject).
    public static func anomalyScore(_ f: Features, siblings: [Features]) -> Double {
        guard siblings.count >= 3 else { return 0 }
        let dims: [KeyPath<Features, Double>] = [\.rmsDb, \.centroidHz, \.flatness]
        var worst = 0.0
        for kp in dims {
            let values = siblings.map { $0[keyPath: kp] }
            let med = median(values)
            let mad = median(values.map { abs($0 - med) })
            let scale = mad > 1e-9 ? mad * 1.4826 : 1e-9   // 1.4826 ⇒ MAD ≈ σ for normal data
            worst = max(worst, abs(f[keyPath: kp] - med) / scale)
        }
        return worst
    }

    /// Full grade: signal QA (clipping → length → dropout → SNR) → technique (merged-gulp → template →
    /// cadence) → sibling anomaly. Returns the first failure's reason, else accept. `lengthOK`,
    /// `dropoutOK` (one-shot bodies), `spacingOK` / `cadenceOK` (packing) are decided by the builder
    /// per technique using the helpers below; non-applicable gates default to passing.
    public static func grade(
        _ f: Features,
        siblings: [Features],
        gold: [Float]?,
        lengthOK: Bool,
        dropoutOK: Bool = true,
        spacingOK: Bool = true,
        cadenceOK: Bool = true,
        thresholds: Thresholds = .default
    ) -> Verdict {
        let distance = templateDistance(f, gold: gold)
        let anomaly = anomalyScore(f, siblings: siblings)
        func reject(_ reason: String) -> Verdict {
            Verdict(accept: false, reason: reason, qaScore: f.snrDb, anomalyScore: anomaly, templateDistance: distance)
        }
        if f.clipped { return reject("clipped") }
        if !lengthOK { return reject("length") }
        if !dropoutOK { return reject("dropout") }
        if f.snrDb < thresholds.minSNRdB { return reject("low_snr") }
        if !spacingOK { return reject("merged_gulp") }
        if distance > thresholds.maxTemplateDistance { return reject("off_technique") }
        if !cadenceOK { return reject("cadence_drift") }
        if anomaly > thresholds.madK { return reject("outlier") }
        return Verdict(accept: true, reason: nil, qaScore: f.snrDb, anomalyScore: anomaly, templateDistance: distance)
    }

    /// Dropout gate (one-shot bodies): true if `envelope` has an *interior* run below 10 % of its peak
    /// lasting ≥ `minGapSec` — a mid-breath silence the loud sustain shouldn't contain. Leading/trailing
    /// quiet is ignored (only the span between the first and last above-floor sample is scanned).
    public static func dropoutRun(_ envelope: [Float], sampleRate: Double, minGapSec: Double) -> Bool {
        guard let peak = envelope.max(), peak > 0 else { return false }
        let floor = peak * 0.1
        guard let first = envelope.firstIndex(where: { $0 >= floor }),
              let last = envelope.lastIndex(where: { $0 >= floor }), last > first else { return false }
        let minRun = max(1, Int(minGapSec * sampleRate))
        var run = 0
        for i in first...last {
            if envelope[i] < floor { run += 1; if run >= minRun { return true } } else { run = 0 }
        }
        return false
    }

    /// Cadence gate (packing): relative deviation of a take's median gulp spacing from the gold
    /// reference's. 0 when either side is empty (→ no cadence rejection).
    public static func rhythmDistance(_ enrollee: [Int], _ gold: [Int]) -> Double {
        guard !enrollee.isEmpty, !gold.isEmpty else { return 0 }
        let me = median(enrollee.map(Double.init))
        let ref = median(gold.map(Double.init))
        guard ref > 0 else { return 0 }
        return abs(me - ref) / ref
    }

    // MARK: - DSP helpers

    static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for s in samples { sum += s * s }
        return (sum / Float(samples.count)).squareRoot()
    }

    /// True if `samples` contains a run of at least `minRun` consecutive samples at/above `peak`.
    static func clippingRun(_ samples: [Float], peak: Float, minRun: Int) -> Bool {
        var run = 0
        for s in samples {
            if abs(s) >= peak {
                run += 1
                if run >= minRun { return true }
            } else {
                run = 0
            }
        }
        return false
    }

    static func spectralCentroid(_ profile: [Float], binHz: Double) -> Double {
        var num = 0.0, den = 0.0
        for (k, m) in profile.enumerated() {
            num += Double(k) * binHz * Double(m)
            den += Double(m)
        }
        return den > 0 ? num / den : 0
    }

    /// Spectral flatness (Wiener entropy): geometric mean / arithmetic mean of the magnitudes, in
    /// [0, 1]. 1 ≈ white/noisy, → 0 ≈ tonal. Computed over bins with non-trivial magnitude.
    static func spectralFlatness(_ profile: [Float]) -> Double {
        let mags = profile.map { Double($0) }.filter { $0 > 1e-9 }
        guard !mags.isEmpty else { return 0 }
        let logMean = mags.reduce(0) { $0 + log($1) } / Double(mags.count)
        let arithMean = mags.reduce(0, +) / Double(mags.count)
        return arithMean > 0 ? exp(logMean) / arithMean : 0
    }

    static func bandEnergy(_ profile: [Float], binHz: Double, low: Double, high: Double) -> Double {
        var energy = 0.0
        for (k, m) in profile.enumerated() {
            let hz = Double(k) * binHz
            if hz >= low, hz <= high { energy += Double(m) * Double(m) }
        }
        return energy
    }

    /// SNR in dB: in-band fragment energy over in-band room-tone energy. Returns a high value (so the
    /// SNR stage never rejects) when there is no room-tone profile to compare against.
    static func snrDb(profile: [Float], room: [Float]?, binHz: Double, low: Double, high: Double) -> Double {
        guard let room, room.count == profile.count, !room.isEmpty else { return 99 }
        let signal = bandEnergy(profile, binHz: binHz, low: low, high: high)
        let noise = bandEnergy(room, binHz: binHz, low: low, high: high)
        guard noise > 1e-12 else { return 99 }
        guard signal > 1e-12 else { return -99 }
        return 10 * log10(signal / noise)
    }

    static func cosineDistance(_ a: [Float], _ b: [Float]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot = 0.0, na = 0.0, nb = 0.0
        for i in a.indices {
            dot += Double(a[i]) * Double(b[i])
            na += Double(a[i]) * Double(a[i])
            nb += Double(b[i]) * Double(b[i])
        }
        guard na > 0, nb > 0 else { return 0 }
        return 1 - dot / (na.squareRoot() * nb.squareRoot())
    }

    static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }
}
