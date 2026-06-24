import Foundation

/// The source clips for one breath render, already decoded to mono Float at the
/// working sample rate. `oneShot` is optional.
public struct BreathSourceClips: Sendable {
    public let start: [Float]
    public let loop: [Float]
    public let end: [Float]
    public let oneShot: [Float]?

    public init(start: [Float], loop: [Float], end: [Float], oneShot: [Float]? = nil) {
        self.start = start
        self.loop = loop
        self.end = end
        self.oneShot = oneShot
    }
}

/// Tunables for assembly.
public struct AssemblerSettings: Sendable {
    public var sampleRate: Double
    /// Cap on how much of the start clip (the onset) to use.
    public var startCapSec: Double
    /// Cap on how much of the end clip (the release tail) to use.
    public var endCapSec: Double
    /// Crossfade length used at every join.
    public var crossfadeSec: Double
    /// Below this duration we use the one-shot / resampled-loop short branch.
    public var shortThresholdSec: Double
    /// Spectral noise-profile subtraction on the source before texture extraction. Off by
    /// default: Stage 1 already stopped the energy flattening from amplifying the hiss, so the
    /// audible upside is modest and over-subtraction can introduce musical noise. Validate by
    /// ear before turning on.
    public var enableSpectralDenoise: Bool
    /// Over-subtraction factor for the denoiser (~1.5-2.0). See `SpectralDenoise.denoise`.
    public var denoiseOverSubtraction: Float
    /// Per-bin residual floor for the denoiser (~0.03-0.1). See `SpectralDenoise.denoise`.
    public var denoiseFloorGain: Float

    public init(
        sampleRate: Double = AudioConstants.workingSampleRate,
        startCapSec: Double = 0.6,
        endCapSec: Double = 0.8,
        crossfadeSec: Double = 0.2,
        shortThresholdSec: Double = 1.5,
        enableSpectralDenoise: Bool = false,
        denoiseOverSubtraction: Float = 1.75,
        denoiseFloorGain: Float = 0.05
    ) {
        self.sampleRate = sampleRate
        self.startCapSec = startCapSec
        self.endCapSec = endCapSec
        self.crossfadeSec = crossfadeSec
        self.shortThresholdSec = shortThresholdSec
        self.enableSpectralDenoise = enableSpectralDenoise
        self.denoiseOverSubtraction = denoiseOverSubtraction
        self.denoiseFloorGain = denoiseFloorGain
    }
}

/// Assembles an exact-duration breath from source clips. Pure `[Float]` math so it
/// can be unit-tested without any audio hardware.
public enum BreathAssembler {
    /// Produce `round(durationSec * sr)` mono samples for the breath, enveloped and
    /// varied. Peak stays within roughly the source's normalized level; the engine
    /// applies master gain + headroom afterwards.
    public static func assemble(
        type: BreathType,
        durationSec: Double,
        clips: BreathSourceClips,
        settings: AssemblerSettings,
        deltas: VariationDeltas = .identity,
        seed: UInt64 = 0
    ) -> [Float] {
        let sr = settings.sampleRate
        let totalFrames = max(1, Segments.frames(seconds: durationSec, sampleRate: sr))

        guard let full = clips.oneShot, full.count > 1 else {
            return [Float](repeating: 0, count: totalFrames)
        }

        var body = recordedShapeBranch(
            type: type,
            totalFrames: totalFrames,
            durationSec: durationSec,
            full: full,
            settings: settings,
            deltas: deltas,
            seed: seed
        )
        let g = Float(deltas.gainScalar)
        for i in 0..<totalFrames {
            body[i] *= g
        }
        return body
    }

    // MARK: - Render path

    /// Single unified render path. Timbre comes from a flattened slice of the
    /// recording; dynamics come from a *designed* envelope (`Envelope.curve`),
    /// identical for every duration. Decoupling the two is what fixes the recording's
    /// messy onsets (slow lead-in ramp, stepped exhale double-attack) and the hiss the
    /// old energy-matching stages amplified in quiet regions.
    private static func recordedShapeBranch(
        type: BreathType,
        totalFrames: Int,
        durationSec: Double,
        full: [Float],
        settings: AssemblerSettings,
        deltas: VariationDeltas,
        seed: UInt64
    ) -> [Float] {
        var source = cleanRecordedSource(
            trimOuterSilence(full, sampleRate: settings.sampleRate),
            sampleRate: settings.sampleRate
        )
        guard source.count > 1 else { return [Float](repeating: 0, count: totalFrames) }

        // Optional spectral noise-profile subtraction. Runs once per source, before the
        // envelope/texture extraction so both see the cleaned signal. The high-pass above only
        // clears sub-260 Hz rumble; this gates the steady broadband hiss the recording carries
        // above that, pushing quiet stretches toward true silence.
        if settings.enableSpectralDenoise {
            source = SpectralDenoise.denoise(
                source,
                sampleRate: settings.sampleRate,
                overSubtraction: settings.denoiseOverSubtraction,
                floorGain: settings.denoiseFloorGain
            )
        }

        // Timbre only: the loud, steady, energy-flat sustain of the breath. The
        // recording's own dynamics (quiet preamble, end-loaded ramp) are excluded by
        // the threshold in `flattenedTexture`, so they never re-enter the breath.
        let envelope = rmsEnvelope(source, sampleRate: settings.sampleRate)
        var texture = flattenedTexture(from: source, envelope: envelope, type: type, sampleRate: settings.sampleRate)

        // Per-render pitch/length variation (previously computed but never applied).
        // The loop below re-fills to the exact target length, so duration stays exact.
        if deltas.playbackRate > 0, abs(deltas.playbackRate - 1) > 1e-6 {
            texture = ensureZeroEndpoints(Resample.byFactor(texture, deltas.playbackRate))
        }
        guard texture.count > 1 else { return [Float](repeating: 0, count: totalFrames) }

        // Build the body to the exact length from the timbre slice. When the breath is
        // longer than the texture we fill it with grains pulled from spread-out offsets
        // (see `assembleTexturedLoop`) so long breaths don't develop a periodic loop
        // "wobble". Grains are a few seconds with a generous crossfade so timbre shifts
        // between them stay smooth.
        let grain = min(texture.count, Segments.frames(seconds: 2.5, sampleRate: settings.sampleRate))
        let requestedX = Segments.frames(seconds: max(settings.crossfadeSec, 0.7), sampleRate: settings.sampleRate)
        let x = min(max(1, requestedX), max(1, grain - 1), max(1, totalFrames / 4))
        var grainRNG = SeededRNG(seed: seed)
        var body = Crossfade.assembleTexturedLoop(
            texture: texture, targetLen: totalFrames, grainLen: grain, crossfadeLen: x, rng: &grainRNG
        )
        body = flattenLocalEnergy(body, sampleRate: settings.sampleRate)

        // Dynamics: the designed macro contour. Prompt onset, single clean attack.
        let shape = Envelope.curve(for: type, frames: totalFrames, durationSec: durationSec)
        for i in body.indices {
            body[i] *= shape[i]
        }

        // Click-free, truly silent edges.
        body = applyEdgeFades(body, sampleRate: settings.sampleRate)
        return normalizePeak(body)
    }

    private static func trimOuterSilence(_ samples: [Float], sampleRate: Double) -> [Float] {
        guard samples.count > 1 else { return samples }
        let envelope = rmsEnvelope(samples, sampleRate: sampleRate)
        guard let peak = envelope.max(), peak > 0 else { return samples }
        let threshold = peak * 0.025
        guard let first = envelope.firstIndex(where: { $0 >= threshold }),
              let last = envelope.lastIndex(where: { $0 >= threshold }) else {
            return samples
        }
        let pad = Segments.frames(seconds: 0.10, sampleRate: sampleRate)
        let start = max(0, first - pad)
        let end = min(samples.count - 1, last + pad)
        return Array(samples[start...end])
    }

    private static func cleanRecordedSource(_ samples: [Float], sampleRate: Double) -> [Float] {
        guard samples.count > 1 else { return samples }
        var out = samples
        // The single low-cut for the whole path. Removing room rumble and mic-handling
        // noise *before* the energy flattening below is essential - flattening would
        // otherwise amplify that sub-band floor by ~20 dB during quiet passages. The
        // measured knee is ~320 Hz (a breath's lowest real energy), so a 260 Hz 4th-
        // order cut clears the audible rumble band yet leaves the breath's warmth
        // intact, and is steep enough to stand as the delivery guarantee on its own.
        highpass4th(&out, sampleRate: sampleRate, frequency: 260)
        out[0] = 0
        out[out.count - 1] = 0
        return out
    }

    /// 4th-order Butterworth high-pass (two cascaded RBJ biquads with the standard
    /// Butterworth section Qs, so the response is maximally flat with no resonant
    /// bump at the corner that would re-introduce rumble).
    private static func highpass4th(_ samples: inout [Float], sampleRate: Double, frequency: Double) {
        var stage1 = Biquad(kind: .highpass, sampleRate: sampleRate, frequency: frequency, q: 0.541_196)
        var stage2 = Biquad(kind: .highpass, sampleRate: sampleRate, frequency: frequency, q: 1.306_563)
        stage1.process(&samples)
        stage2.process(&samples)
    }

    /// Short raised-cosine fades into/out of true zero at both edges, so every breath
    /// starts and ends silently and click-free regardless of where the looped body
    /// happened to begin or end.
    private static func applyEdgeFades(_ samples: [Float], sampleRate: Double) -> [Float] {
        guard samples.count > 2 else { return ensureZeroEndpoints(samples) }
        var out = samples
        let fade = min(Segments.frames(seconds: 0.02, sampleRate: sampleRate), out.count / 2)
        if fade > 1 {
            let fadeIn = Crossfade.fadeIn(fade)
            let fadeOut = Crossfade.fadeOut(fade)
            for i in 0..<fade {
                out[i] *= fadeIn[i]
                out[out.count - fade + i] *= fadeOut[i]
            }
        }
        return ensureZeroEndpoints(out)
    }

    private static func rmsEnvelope(_ samples: [Float], sampleRate: Double) -> [Float] {
        guard !samples.isEmpty else { return [] }
        let window = max(32, Segments.frames(seconds: 0.050, sampleRate: sampleRate))
        let hop = max(1, Segments.frames(seconds: 0.025, sampleRate: sampleRate))
        var points: [(index: Int, value: Float)] = []

        var start = 0
        while start < samples.count {
            let end = min(samples.count, start + window)
            let value = Float(rms(samples, range: start..<end))
            points.append((index: start + (end - start) / 2, value: value))
            start += hop
        }

        guard !points.isEmpty else { return [Float](repeating: 0, count: samples.count) }
        var values = points.map(\.value)
        for _ in 0..<2 {
            var smoothed = values
            for i in values.indices {
                let lo = max(0, i - 2)
                let hi = min(values.count - 1, i + 2)
                let slice = values[lo...hi]
                smoothed[i] = slice.reduce(0, +) / Float(slice.count)
            }
            values = smoothed
        }

        var out = [Float](repeating: 0, count: samples.count)
        for i in 0..<(points.count - 1) {
            let aIndex = points[i].index
            let bIndex = points[i + 1].index
            let aValue = values[i]
            let bValue = values[i + 1]
            guard bIndex > aIndex else { continue }
            for j in aIndex..<min(bIndex, out.count) {
                let t = Float(j - aIndex) / Float(bIndex - aIndex)
                out[j] = aValue + (bValue - aValue) * t
            }
        }
        if let first = points.first {
            for i in 0..<min(first.index, out.count) {
                out[i] = values[0]
            }
        }
        if let last = points.last {
            for i in max(0, last.index)..<out.count {
                out[i] = values[values.count - 1]
            }
        }
        return out
    }

    private static func smoothEnvelope(_ values: [Float], radius: Int) -> [Float] {
        guard values.count > 2, radius > 0 else { return values }
        var prefix = [Double](repeating: 0, count: values.count + 1)
        for i in values.indices {
            prefix[i + 1] = prefix[i] + Double(values[i])
        }

        var out = [Float](repeating: 0, count: values.count)
        for i in values.indices {
            let lo = max(0, i - radius)
            let hi = min(values.count - 1, i + radius)
            let sum = prefix[hi + 1] - prefix[lo]
            out[i] = Float(sum / Double(hi - lo + 1))
        }
        return out
    }

    private static func normalizeEnvelope(_ envelope: [Float]) -> [Float] {
        guard let peak = envelope.max(), peak > 0 else {
            return [Float](repeating: 0, count: envelope.count)
        }
        return envelope.map { min(1, max(0, $0 / peak)) }
    }

    private static func flattenedTexture(
        from source: [Float],
        envelope: [Float],
        type: BreathType,
        sampleRate: Double
    ) -> [Float] {
        let normalized = normalizeEnvelope(envelope)
        guard let peak = normalized.max(), peak > 0 else { return source }
        // The texture is the longest contiguous stretch of breath above this fraction
        // of peak energy. The exhale settles to a low (~0.2 of peak) but *steady*
        // airflow it sustains for most of the breath; a higher threshold would clip the
        // texture to a short ~4.5 s slice that then loops audibly (a periodic "wobble"),
        // so the exhale threshold sits below that plateau to capture the full ~7 s of
        // steady airflow - long and stationary enough to loop without a perceptible
        // repeat. The inhale is a continuous draw that stays well above 0.32 throughout.
        let threshold: Float = type == .inhale ? 0.32 : 0.16
        let selectedRange = largestRange(above: threshold, in: normalized)
            ?? 0..<source.count

        let minLength = min(source.count, Segments.frames(seconds: type == .inhale ? 3.0 : 2.0, sampleRate: sampleRate))
        let range = expanded(selectedRange, toAtLeast: minLength, limit: source.count)
        var texture = [Float]()
        texture.reserveCapacity(range.count)
        for i in range {
            let divisor = max(normalized[i], 0.22)
            texture.append(source[i] / divisor)
        }
        return ensureZeroEndpoints(flattenLocalEnergy(texture, sampleRate: sampleRate))
    }

    private static func flattenLocalEnergy(_ samples: [Float], sampleRate: Double) -> [Float] {
        guard samples.count > 1 else { return samples }
        var energy = rmsEnvelope(samples, sampleRate: sampleRate)
        let smoothing = Segments.frames(seconds: 0.12, sampleRate: sampleRate)
        energy = smoothEnvelope(energy, radius: smoothing)
        let audible = energy.filter { $0 > 0.000_001 }
        guard !audible.isEmpty else { return samples }
        let target = audible.reduce(0, +) / Float(audible.count)

        var out = samples
        for i in out.indices {
            let divisor = max(energy[i], target * 0.35)
            out[i] *= target / divisor
        }
        return out
    }

    private static func largestRange(above threshold: Float, in values: [Float]) -> Range<Int>? {
        var best: Range<Int>?
        var start: Int?
        for i in values.indices {
            if values[i] >= threshold {
                if start == nil { start = i }
            } else if let s = start {
                let range = s..<i
                if best == nil || range.count > best!.count {
                    best = range
                }
                start = nil
            }
        }
        if let s = start {
            let range = s..<values.count
            if best == nil || range.count > best!.count {
                best = range
            }
        }
        return best
    }

    private static func expanded(_ range: Range<Int>, toAtLeast minLength: Int, limit: Int) -> Range<Int> {
        guard range.count < minLength, limit > range.count else { return range }
        let extra = minLength - range.count
        let before = min(range.lowerBound, extra / 2)
        let after = min(limit - range.upperBound, extra - before)
        let start = range.lowerBound - before
        let end = min(limit, range.upperBound + after)
        if end - start >= minLength || start == 0 {
            return start..<end
        }
        let missing = minLength - (end - start)
        return max(0, start - missing)..<end
    }

    private static func ensureZeroEndpoints(_ samples: [Float]) -> [Float] {
        guard !samples.isEmpty else { return samples }
        var out = samples
        out[0] = 0
        out[out.count - 1] = 0
        return out
    }

    private static func normalizePeak(_ samples: [Float], targetPeak: Float = 0.45) -> [Float] {
        guard let peak = samples.map({ abs($0) }).max(), peak > 0 else { return samples }
        let gain = targetPeak / peak
        return samples.map { $0 * gain }
    }

    private static func rms(_ samples: [Float], range: Range<Int>) -> Double {
        guard !range.isEmpty else { return 0 }
        var sum = 0.0
        for i in range {
            let value = Double(samples[i])
            sum += value * value
        }
        return sqrt(sum / Double(range.count))
    }
}
