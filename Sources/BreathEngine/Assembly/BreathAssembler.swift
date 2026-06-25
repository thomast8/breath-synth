import Foundation

/// The decoded one-shot breath recording for one render, mono Float at the working
/// sample rate. The engine renders every breath from this single recording; the earlier
/// per-role attack/sustain/release clips (`start`/`loop`/`end`) were never consumed by
/// `BreathAssembler` and were removed.
public struct BreathSourceClips: Sendable {
    public let oneShot: [Float]?

    public init(oneShot: [Float]? = nil) {
        self.oneShot = oneShot
    }
}

/// Tunables for assembly.
public struct AssemblerSettings: Sendable {
    public var sampleRate: Double
    /// Crossfade length used at every join.
    public var crossfadeSec: Double
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
        crossfadeSec: Double = 0.2,
        enableSpectralDenoise: Bool = true,
        denoiseOverSubtraction: Float = 1.75,
        denoiseFloorGain: Float = 0.05
    ) {
        self.sampleRate = sampleRate
        self.crossfadeSec = crossfadeSec
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
        seed: UInt64 = 0,
        mode: RenderMode = .textured,
        style: BreathStyle = "neutral",
        noiseProfile: [Float]? = nil,
        grainPool: [[Float]]? = nil
    ) -> [Float] {
        let sr = settings.sampleRate
        let totalFrames = max(1, Segments.frames(seconds: durationSec, sampleRate: sr))

        guard let full = clips.oneShot, full.count > 1 else {
            return [Float](repeating: 0, count: totalFrames)
        }

        var body: [Float]
        switch mode {
        case .textured:
            body = recordedShapeBranch(
                type: type,
                totalFrames: totalFrames,
                durationSec: durationSec,
                full: full,
                settings: settings,
                deltas: deltas,
                seed: seed,
                style: style,
                noiseProfile: noiseProfile,
                grainPool: grainPool
            )
        case .oneShot, .counted:
            // `.counted` is assembled at the engine layer; falling through to the
            // natural-length one-shot here keeps `assemble` safe if it is ever called
            // with `.counted` directly.
            body = oneShotBranch(
                type: type,
                totalFrames: totalFrames,
                durationSec: durationSec,
                full: full,
                settings: settings,
                deltas: deltas,
                seed: seed,
                noiseProfile: noiseProfile
            )
        }
        let g = Float(deltas.gainScalar)
        for i in body.indices {
            body[i] *= g
        }
        return body
    }

    /// Lay down `count` events by cycling through the recording's real `units` (each an adjacent
    /// slice carrying its event + natural gap). For `count <= units.count` the output is the
    /// recorded sequence truncated to N — a seamless slice of the real recording (natural sound,
    /// spacing, and variation). When more are requested than recorded, the wrap-around join (last
    /// recorded unit → first) is the only discontinuity, so it gets a short fade to stay click-free.
    public static func assembleCounted(
        units: [[Float]],
        count: Int,
        settings: AssemblerSettings
    ) -> [Float] {
        guard !units.isEmpty else { return [] }
        let n = max(1, count)
        let fade = max(1, Int(0.006 * settings.sampleRate))
        var out = [Float]()
        out.reserveCapacity(units.map(\.count).reduce(0, +) / units.count * n + 1)
        for i in 0..<n {
            var seg = units[i % units.count]
            // A wrap (cycled back to the first unit) joins non-adjacent audio; fade the seam.
            if i > 0, i % units.count == 0, out.count >= fade, seg.count >= fade {
                for k in 0..<fade {
                    let g = Float(k) / Float(fade)
                    out[out.count - fade + k] *= 1 - g
                    seg[k] *= g
                }
            }
            out.append(contentsOf: seg)
        }
        return normalizePeak(applyEdgeFades(out, sampleRate: settings.sampleRate))
    }

    /// Hybrid counted render: place `count` event `cores` (clean, declicked exemplars sampled at
    /// random — seeded — from one take) at the inter-onset `gaps` of another take's natural rhythm.
    /// Used for packing: random single packs from the deliberately-separated take, collated at the
    /// natural-rhythm take's cadence. `--seed` selects the random pack sequence (reproducible).
    public static func assembleHybrid(
        cores: [[Float]],
        gaps: [Int],
        count: Int,
        settings: AssemblerSettings,
        seed: UInt64
    ) -> [Float] {
        guard !cores.isEmpty else { return [] }
        let n = max(1, count)
        var rng = SeededRNG(seed: seed)
        var out = [Float]()
        for i in 0..<n {
            let core = cores[Int.random(in: 0..<cores.count, using: &rng)]
            // Each core occupies one rhythm slot; pad with silence to the slot length (never shorter
            // than the core, so a tight gap can't truncate a pack).
            let slot = gaps.isEmpty ? core.count : max(core.count, gaps[i % gaps.count])
            out.append(contentsOf: core)
            if slot > core.count {
                out.append(contentsOf: [Float](repeating: 0, count: slot - core.count))
            }
        }
        return normalizePeak(applyEdgeFades(out, sampleRate: settings.sampleRate))
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
        seed: UInt64,
        style: BreathStyle,
        noiseProfile: [Float]?,
        grainPool: [[Float]]?
    ) -> [Float] {
        var body: [Float]
        if let pool = grainPool, !pool.isEmpty {
            // Banked path: fill the body from the cross-take accepted-grain pool instead of looping a
            // single take's texture. The pool's grains are already energy-flat texture windows, so the
            // downstream flatten/envelope/normalize below is identical to the single-texture path.
            body = texturedLoopFromPool(pool: pool, totalFrames: totalFrames, settings: settings, seed: seed)
        } else {
            let source = prepareSource(full, settings: settings, noiseProfile: noiseProfile)
            guard source.count > 1 else { return [Float](repeating: 0, count: totalFrames) }

            // Timbre only: the loud, steady, energy-flat sustain of the breath. The
            // recording's own dynamics (quiet preamble, end-loaded ramp) are excluded by
            // the threshold in `flattenedTexture`, so they never re-enter the breath.
            let envelope = rmsEnvelope(source, sampleRate: settings.sampleRate)
            var texture = flattenedTexture(from: source, envelope: envelope, type: type, sampleRate: settings.sampleRate)

            // A forceful exhale opens with a glottal onset ("ungh") that, once looped, recurs and
            // sounds wrong. Skip the leading attack so the looped texture is the sustained airflow only.
            if style == "hyperventilation", type == .exhale {
                let skip = min(texture.count / 3, Segments.frames(seconds: 0.22, sampleRate: settings.sampleRate))
                if texture.count - skip > 1 { texture = ensureZeroEndpoints(Array(texture[skip...])) }
            }

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
            body = Crossfade.assembleTexturedLoop(
                texture: texture, targetLen: totalFrames, grainLen: grain, crossfadeLen: x, rng: &grainRNG
            )
        }
        body = flattenLocalEnergy(body, sampleRate: settings.sampleRate)

        // A forceful exhale's airflow naturally sags as the lungs empty; even after the standard
        // flatten the looped body still wobbles audibly. A stronger leveling pass (lower floor,
        // wider window) holds the power steady so it reads as sustained, not pulsing.
        if style == "hyperventilation", type == .exhale {
            body = levelize(body, sampleRate: settings.sampleRate)
        }

        // Dynamics: the designed macro contour. Prompt onset, single clean attack.
        let shape = Envelope.curve(for: type, style: style, frames: totalFrames, durationSec: durationSec)
        for i in body.indices {
            body[i] *= shape[i]
        }

        // Click-free, truly silent edges.
        body = applyEdgeFades(body, sampleRate: settings.sampleRate)
        return normalizePeak(body)
    }

    /// Cross-take variant of the single-texture loop: fill the body to length by drawing grains from
    /// the accepted-grain `pool` (seeded), instead of looping one take's texture. Mirrors the
    /// single-texture path's 2.5 s grain / ≥0.7 s crossfade geometry and its `seed`-keyed grain RNG,
    /// so a given seed always draws the same grain succession (and cycles re-seed to decorrelate).
    private static func texturedLoopFromPool(
        pool: [[Float]], totalFrames: Int, settings: AssemblerSettings, seed: UInt64
    ) -> [Float] {
        let sr = settings.sampleRate
        let grain = Segments.frames(seconds: 2.5, sampleRate: sr)
        let requestedX = Segments.frames(seconds: max(settings.crossfadeSec, 0.7), sampleRate: sr)
        let x = min(max(1, requestedX), max(1, grain - 1), max(1, totalFrames / 4))
        var grainRNG = SeededRNG(seed: seed)
        return Crossfade.assembleTexturedFromPool(
            grains: pool, targetLen: totalFrames, grainLen: grain, crossfadeLen: x, rng: &grainRNG
        )
    }

    /// Natural-length one-shot render (frc, rv). The source is prepped exactly like the
    /// textured path (trim → clean → optional denoise) but then returned at its own
    /// natural length: no texture extraction, no loop, no designed envelope and no
    /// `flattenLocalEnergy`. The maneuver's duration is intrinsic to the recording, so
    /// the requested `durationSec` / `totalFrames` are deliberately ignored. Per-render
    /// `deltas.gainScalar` is applied by `assemble` afterwards, not here.
    private static func oneShotBranch(
        type: BreathType,
        totalFrames: Int,
        durationSec: Double,
        full: [Float],
        settings: AssemblerSettings,
        deltas: VariationDeltas,
        seed: UInt64,
        noiseProfile: [Float]?
    ) -> [Float] {
        let prepared = prepareSource(full, settings: settings, noiseProfile: noiseProfile)
        guard prepared.count > 1 else { return [Float](repeating: 0, count: totalFrames) }
        // Tighten the tail to the breath body. `trimOuterSilence` keeps anything above its loose
        // threshold, so a recording's trailing dead air + a late stop-knock can survive past the
        // exhale. Keep only the longest contiguous above-threshold region (the exhale) plus a short
        // decay pad, dropping the silent gap and any late transient before normalisation.
        let body = trimToMainBody(prepared, sampleRate: settings.sampleRate)
        var out = normalizePeak(applyEdgeFades(body, sampleRate: settings.sampleRate))
        // A forced exhale (frc/rv) is a complete maneuver — append a short settle pause so it reads as
        // a natural finish and doesn't jam straight into the next inhale when placed in a cycle or
        // sequence (you wouldn't finish a full exhale and instantly draw the next breath).
        out += [Float](repeating: 0, count: Int(oneShotSettleSec * settings.sampleRate))
        return out
    }

    /// Trailing settle pause appended to every one-shot (frc/rv) render. By-ear tunable.
    private static let oneShotSettleSec = 0.45

    /// Trim a one-shot breath to its main energetic body, dropping trailing dead air and — crucially
    /// — any isolated transient that follows a short gap (a stop-knock, a vocalised "t"/"ptuh" at the
    /// end of a forced exhale, a lip smack). Uses a fine, unsmoothed energy envelope so a ~100 ms
    /// gap between the breath and a trailing plosive is resolved (the engine's broad RMS envelope
    /// would bridge it); the breath is the longest contiguous above-threshold run, the plosive a
    /// separate shorter run that is excluded.
    /// Public so the `breath-bank` builder derives the frc/rv one-shot *body* fragment exactly as
    /// the engine's `oneShotBranch` does.
    public static func trimToMainBody(_ samples: [Float], sampleRate: Double) -> [Float] {
        guard samples.count > 1 else { return samples }
        let win = max(1, Int(0.015 * sampleRate))
        let hop = max(1, Int(0.005 * sampleRate))
        var hopStart = [Int]()
        var hopRMS = [Float]()
        var s = 0
        while s < samples.count {
            let e = min(samples.count, s + win)
            var acc: Float = 0
            for j in s..<e { acc += samples[j] * samples[j] }
            hopStart.append(s)
            hopRMS.append((acc / Float(e - s)).squareRoot())
            s += hop
        }
        guard let peak = hopRMS.max(), peak > 0 else { return samples }
        let threshold = peak * 0.05
        // Longest contiguous run of hops above threshold = the breath body.
        var runStart = -1, bestStart = 0, bestEnd = 0
        for idx in hopRMS.indices {
            if hopRMS[idx] >= threshold {
                if runStart < 0 { runStart = idx }
                if idx - runStart > bestEnd - bestStart { bestStart = runStart; bestEnd = idx }
            } else {
                runStart = -1
            }
        }
        // Crop the quiet preamble that trimOuterSilence's loose 2.5% gate left in, keeping a short
        // pre-roll so the onset transient isn't clipped. (The head was previously never cropped —
        // `bestStart` was computed but unused — which left a long flat lead-in on frc/rv renders.)
        let preRoll = Int(0.03 * sampleRate)
        let start = max(0, hopStart[bestStart] - preRoll)
        // Extend past the 5%-run end to keep the breath's natural decay, down to a low tail threshold
        // (matching trimOuterSilence), so the one-shot tapers off as recorded instead of cutting at
        // the main-body end. The walk stops at the silent gap, so a trailing plosive after the gap is
        // still excluded.
        let tailThreshold = peak * 0.025
        var tailHop = bestEnd
        while tailHop + 1 < hopRMS.count, hopRMS[tailHop + 1] >= tailThreshold { tailHop += 1 }
        let tailPad = Int(0.08 * sampleRate)
        let end = min(samples.count, hopStart[tailHop] + win + tailPad)
        guard start < end else { return Array(samples[0..<end]) }
        return Array(samples[start..<end])
    }

    /// Shared source prep for every render mode: trim the outer silence, run the single
    /// low-cut clean-up, then optionally subtract the spectral noise profile. Factored
    /// out of `recordedShapeBranch` so the one-shot and counted paths see an identically
    /// cleaned signal. Public so the app-layer `breath-bank` builder cuts fragments from the
    /// *same* prepared signal the engine renders from (offset validity).
    public static func prepareSource(
        _ full: [Float],
        settings: AssemblerSettings,
        noiseProfile: [Float]?
    ) -> [Float] {
        var source = cleanRecordedSource(
            trimOuterSilence(full, sampleRate: settings.sampleRate),
            sampleRate: settings.sampleRate
        )
        guard source.count > 1 else { return source }

        // Optional spectral noise-profile subtraction. Runs once per source, before any
        // envelope/texture extraction so every mode sees the cleaned signal. The high-pass
        // in `cleanRecordedSource` only clears sub-260 Hz rumble; this gates the steady
        // broadband hiss the recording carries above that, pushing quiet stretches toward
        // true silence.
        if settings.enableSpectralDenoise {
            source = SpectralDenoise.denoise(
                source,
                sampleRate: settings.sampleRate,
                overSubtraction: settings.denoiseOverSubtraction,
                floorGain: settings.denoiseFloorGain,
                noiseProfile: noiseProfile
            )
        }
        return source
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

    /// Public so the `breath-bank` builder reuses the engine's envelope for texture extraction and
    /// fragment-quality features.
    public static func rmsEnvelope(_ samples: [Float], sampleRate: Double) -> [Float] {
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

    /// Public so the `breath-bank` builder tiles calm grains from the *same* energy-flat texture the
    /// engine's textured path produces (so pooled grains are level-comparable and crossfade cleanly).
    public static func flattenedTexture(
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

    /// A stronger energy flatten (wider window, lower floor) that holds the power near-constant.
    /// Used for the forceful exhale, whose airflow sags as the lungs empty: the standard flatten
    /// leaves an audible wobble, this evens it out. The lower floor is safe here because a forceful
    /// breath stays well above the noise floor throughout, so boosting the quieter stretches does
    /// not amplify hiss.
    private static func levelize(_ samples: [Float], sampleRate: Double) -> [Float] {
        guard samples.count > 1 else { return samples }
        var energy = rmsEnvelope(samples, sampleRate: sampleRate)
        energy = smoothEnvelope(energy, radius: Segments.frames(seconds: 0.18, sampleRate: sampleRate))
        let audible = energy.filter { $0 > 0.000_001 }
        guard !audible.isEmpty else { return samples }
        let target = audible.reduce(0, +) / Float(audible.count)

        var out = samples
        for i in out.indices {
            let divisor = max(energy[i], target * 0.15)
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
