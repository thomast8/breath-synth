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

public enum BreathAssemblyMode: String, Sendable, Equatable, CaseIterable {
    /// Use start + loop + end clips with crossfaded joins.
    case segmented
    /// Use only the loop/sustain clip, shaped with smooth fades.
    case sustainOnly
    /// Use a full recorded breath as the envelope teacher and texture source.
    case recordedShape
}

/// Tunables for assembly.
public struct AssemblerSettings: Sendable {
    public var sampleRate: Double
    public var assemblyMode: BreathAssemblyMode
    /// Cap on how much of the start clip (the onset) to use.
    public var startCapSec: Double
    /// Cap on how much of the end clip (the release tail) to use.
    public var endCapSec: Double
    /// Crossfade length used at every join.
    public var crossfadeSec: Double
    /// Below this duration we use the one-shot / resampled-loop short branch.
    public var shortThresholdSec: Double

    public init(
        sampleRate: Double = AudioConstants.workingSampleRate,
        assemblyMode: BreathAssemblyMode = .segmented,
        startCapSec: Double = 0.6,
        endCapSec: Double = 0.8,
        crossfadeSec: Double = 0.2,
        shortThresholdSec: Double = 1.5
    ) {
        self.sampleRate = sampleRate
        self.assemblyMode = assemblyMode
        self.startCapSec = startCapSec
        self.endCapSec = endCapSec
        self.crossfadeSec = crossfadeSec
        self.shortThresholdSec = shortThresholdSec
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
        deltas: VariationDeltas = .identity
    ) -> [Float] {
        let sr = settings.sampleRate
        let totalFrames = max(1, Segments.frames(seconds: durationSec, sampleRate: sr))

        // Apply playback-rate variation to the loop texture only (keeps duration exact).
        let loop = deltas.playbackRate == 1 ? clips.loop : Resample.byFactor(clips.loop, deltas.playbackRate)

        if settings.assemblyMode == .recordedShape, let full = clips.oneShot, full.count > 1 {
            var body = recordedShapeBranch(type: type, totalFrames: totalFrames, full: full, settings: settings)
            let g = Float(deltas.gainScalar)
            for i in 0..<totalFrames {
                body[i] *= g
            }
            return body
        }

        if settings.assemblyMode == .sustainOnly {
            var body = sustainOnlyBranch(type: type, totalFrames: totalFrames, loop: loop, settings: settings)
            let g = Float(deltas.gainScalar)
            for i in 0..<totalFrames {
                body[i] *= g
            }
            return body
        }

        let startCap = Segments.frames(seconds: settings.startCapSec, sampleRate: sr)
        let endCap = Segments.frames(seconds: settings.endCapSec, sampleRate: sr)
        let startUse = min(clips.start.count, startCap)
        let endUse = min(clips.end.count, endCap)

        let canNormal = startUse > 0 && endUse > 0 && loop.count > 1
            && totalFrames >= startUse + endUse

        var body: [Float]
        if durationSec < settings.shortThresholdSec || !canNormal {
            body = shortBranch(totalFrames: totalFrames, loop: loop, clips: clips)
        } else {
            body = normalBranch(
                totalFrames: totalFrames,
                startUse: startUse,
                endUse: endUse,
                loop: loop,
                clips: clips,
                settings: settings
            )
        }

        // Macro contour + variation gain.
        let env = Envelope.curve(for: type, frames: totalFrames, durationSec: durationSec)
        let g = Float(deltas.gainScalar)
        for i in 0..<totalFrames {
            body[i] = body[i] * env[i] * g
        }
        return body
    }

    // MARK: - Branches

    private static func recordedShapeBranch(
        type: BreathType,
        totalFrames: Int,
        full: [Float],
        settings: AssemblerSettings
    ) -> [Float] {
        let source = cleanRecordedSource(
            trimOuterSilence(full, sampleRate: settings.sampleRate),
            sampleRate: settings.sampleRate
        )
        guard source.count > 1 else { return [Float](repeating: 0, count: totalFrames) }

        let envelope = rmsEnvelope(source, sampleRate: settings.sampleRate)
        let shape = recordedShapeEnvelope(
            envelope,
            totalFrames: totalFrames,
            sampleRate: settings.sampleRate
        )
        let ratio = Double(totalFrames) / Double(source.count)
        if ratio >= 0.72 && ratio <= 1.18 {
            var direct = Resample.toFrames(source, totalFrames)
            for _ in 0..<3 {
                direct = matchLocalEnergy(direct, targetEnvelope: shape, sampleRate: settings.sampleRate)
            }
            direct = enforceRenderedEnergyShape(direct, sampleRate: settings.sampleRate)
            return normalizePeak(ensureZeroEndpoints(direct))
        }

        let texture = flattenedTexture(from: source, envelope: envelope, type: type, sampleRate: settings.sampleRate)
        let requestedX = Segments.frames(seconds: max(settings.crossfadeSec, 0.55), sampleRate: settings.sampleRate)
        let x = min(max(1, requestedX), max(1, texture.count - 1), max(1, totalFrames / 4))
        var carrier = Crossfade.assembleLoopedMiddle(loop: texture, targetLen: totalFrames, crossfadeLen: x)
        carrier = flattenLocalEnergy(carrier, sampleRate: settings.sampleRate)
        for i in carrier.indices {
            carrier[i] *= shape[i]
        }
        for _ in 0..<3 {
            carrier = matchLocalEnergy(carrier, targetEnvelope: shape, sampleRate: settings.sampleRate)
        }
        carrier = enforceRenderedEnergyShape(carrier, sampleRate: settings.sampleRate)
        return normalizePeak(ensureZeroEndpoints(carrier))
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
        // Remove recording-room rumble and headphone/mic handling noise while leaving
        // the airy breath band intact.
        var lowCut = Biquad(kind: .highpass, sampleRate: sampleRate, frequency: 120, q: 0.7)
        lowCut.process(&out)
        out[0] = 0
        out[out.count - 1] = 0
        return out
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

    private static func recordedShapeEnvelope(_ envelope: [Float], totalFrames: Int, sampleRate: Double) -> [Float] {
        guard totalFrames > 0 else { return [] }
        var shape = Resample.toFrames(normalizeEnvelope(envelope), totalFrames)
        let smoothing = Segments.frames(seconds: 0.28, sampleRate: sampleRate)
        shape = smoothEnvelope(shape, radius: smoothing)
        shape = enforceAttackAndReleaseAroundPeak(shape)
        return ensureZeroEndpoints(shape)
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

    private static func enforceAttackAndReleaseAroundPeak(_ values: [Float]) -> [Float] {
        guard values.count > 1 else { return values }
        var out = values
        guard let peakIndex = out.indices.max(by: { out[$0] < out[$1] }) else {
            return out
        }
        let peak = out[peakIndex]
        guard peak > 0 else { return out }
        let plateauFloor = peak * 0.96
        let peakStart = out.firstIndex(where: { $0 >= plateauFloor }) ?? peakIndex
        let peakEnd = out.lastIndex(where: { $0 >= plateauFloor }) ?? peakIndex

        if peakStart <= peakEnd {
            for i in peakStart...peakEnd {
                out[i] = peak
            }
        }
        if peakStart > 0 {
            for i in stride(from: peakStart - 1, through: 0, by: -1) where out[i] > out[i + 1] {
                out[i] = out[i + 1]
            }
        }
        if peakEnd + 1 < out.count {
            for i in (peakEnd + 1)..<out.count where out[i] > out[i - 1] {
                out[i] = out[i - 1]
            }
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
        let threshold: Float = type == .inhale ? 0.32 : 0.25
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

    private static func matchLocalEnergy(
        _ samples: [Float],
        targetEnvelope: [Float],
        sampleRate: Double
    ) -> [Float] {
        guard samples.count > 1, samples.count == targetEnvelope.count else { return samples }
        var current = rmsEnvelope(samples, sampleRate: sampleRate)
        current = smoothEnvelope(current, radius: Segments.frames(seconds: 0.05, sampleRate: sampleRate))
        guard let currentPeak = current.max(), currentPeak > 0,
              let targetPeak = targetEnvelope.max(), targetPeak > 0 else {
            return samples
        }

        var out = samples
        for i in out.indices {
            let target = max(0, targetEnvelope[i] / targetPeak)
            if target < 0.000_1 {
                out[i] = 0
                continue
            }
            let measured = max(current[i] / currentPeak, 0.04)
            let scale = min(max(target / measured, 0), 8)
            out[i] *= scale
        }
        return out
    }

    private static func enforceRenderedEnergyShape(_ samples: [Float], sampleRate: Double) -> [Float] {
        guard samples.count > 1 else { return samples }
        var current = rmsEnvelope(samples, sampleRate: sampleRate)
        current = smoothEnvelope(current, radius: Segments.frames(seconds: 0.05, sampleRate: sampleRate))
        let target = enforceAttackAndReleaseAroundPeak(current)

        var out = samples
        for i in out.indices {
            guard current[i] > 0.000_001 else {
                out[i] = 0
                continue
            }
            let scale = min(max(target[i] / current[i], 0.25), 3.0)
            out[i] *= scale
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

    private static func sustainOnlyBranch(
        type: BreathType,
        totalFrames: Int,
        loop: [Float],
        settings: AssemblerSettings
    ) -> [Float] {
        guard loop.count > 1 else { return [Float](repeating: 0, count: totalFrames) }
        let sustainWindow = sustainLoopTexture(for: type, loop: loop, sampleRate: settings.sampleRate)
        let sustainCrossfadeSec = max(settings.crossfadeSec, 0.45)
        let requestedX = Segments.frames(seconds: sustainCrossfadeSec, sampleRate: settings.sampleRate)
        let x = min(max(1, requestedX), max(1, sustainWindow.count - 1), max(1, totalFrames / 4))
        var body = Crossfade.assembleLoopedMiddle(loop: sustainWindow, targetLen: totalFrames, crossfadeLen: x)
        let curve = sustainEnvelope(for: type, frames: totalFrames, sampleRate: settings.sampleRate)
        for i in body.indices {
            body[i] *= curve[i]
        }
        if !body.isEmpty {
            body[0] = 0
            body[body.count - 1] = 0
        }
        return body
    }

    static func sustainLoopTexture(for type: BreathType, loop: [Float], sampleRate: Double) -> [Float] {
        let window = sustainLoopWindow(for: type, loop: loop, sampleRate: sampleRate)
        guard type == .inhale, window.count > 2 else { return window }
        return window + Array(window.reversed())
    }

    static func sustainLoopWindow(for type: BreathType, loop: [Float], sampleRate: Double) -> [Float] {
        guard loop.count > 1 else { return loop }
        let targetSeconds: Double = type == .inhale ? 2.20 : 1.65
        let minSeconds: Double = type == .inhale ? 1.25 : 1.10
        let targetFrames = min(loop.count, max(1, Segments.frames(seconds: targetSeconds, sampleRate: sampleRate)))
        let minFrames = min(loop.count, max(1, Segments.frames(seconds: minSeconds, sampleRate: sampleRate)))
        guard loop.count > targetFrames else { return loop }

        let analysisFrames = max(64, Segments.frames(seconds: 0.10, sampleRate: sampleRate))
        let hop = max(1, analysisFrames / 2)
        let maxEnergy = rms(loop, range: 0..<loop.count)
        guard maxEnergy > 0 else { return loop }
        let floor = maxEnergy * 0.28

        if let window = bestSustainWindow(
            loop: loop,
            length: targetFrames,
            hop: hop,
            analysisFrames: analysisFrames,
            floor: floor
        ) {
            return window
        }
        if minFrames < targetFrames,
           let window = bestSustainWindow(
            loop: loop,
            length: minFrames,
            hop: hop,
            analysisFrames: analysisFrames,
            floor: floor
           ) {
            return window
        }

        return Array(loop[0..<targetFrames])
    }

    private static func bestSustainWindow(
        loop: [Float],
        length: Int,
        hop: Int,
        analysisFrames: Int,
        floor: Double
    ) -> [Float]? {
        guard length > 0, length <= loop.count else { return nil }
        var bestStart = 0
        var bestScore = -Double.infinity

        let lastStart = loop.count - length
        for start in stride(from: 0, through: lastStart, by: hop) {
            let score = sustainWindowScore(loop: loop, start: start, length: length, analysisFrames: analysisFrames, floor: floor)
            if score > bestScore {
                bestScore = score
                bestStart = start
            }
        }

        if bestScore.isFinite {
            return Array(loop[bestStart..<(bestStart + length)])
        }
        return nil
    }

    private static func sustainWindowScore(
        loop: [Float],
        start: Int,
        length: Int,
        analysisFrames: Int,
        floor: Double
    ) -> Double {
        var values: [Double] = []
        let end = start + length
        var cursor = start
        while cursor < end {
            let next = min(end, cursor + analysisFrames)
            let value = rms(loop, range: cursor..<next)
            values.append(value)
            cursor = next
        }

        guard !values.isEmpty else { return -Double.infinity }
        let mean = values.reduce(0, +) / Double(values.count)
        guard mean >= floor else { return -Double.infinity }
        let minValue = values.min() ?? 0
        guard minValue >= floor * 0.45 else { return -Double.infinity }

        let variance = values.reduce(0) { partial, value in
            let delta = value - mean
            return partial + delta * delta
        } / Double(values.count)
        let coefficientOfVariation = sqrt(variance) / max(mean, 1e-9)

        let edgeFrames = min(max(1, analysisFrames), length)
        let head = rms(loop, range: start..<(start + edgeFrames))
        let tail = rms(loop, range: (end - edgeFrames)..<end)
        let edgeMismatch = abs(head - tail) / max(mean, 1e-9)

        return mean - mean * 0.75 * coefficientOfVariation - mean * 0.35 * edgeMismatch
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

    private static func sustainEnvelope(for type: BreathType, frames: Int, sampleRate: Double) -> [Float] {
        guard frames > 0 else { return [] }
        if frames == 1 { return [0] }
        var out = [Float](repeating: 1, count: frames)
        let duration = Double(frames) / sampleRate
        let fadeInSec: Double
        let fadeOutSec: Double
        switch type {
        case .inhale:
            fadeInSec = min(1.6, duration * 0.34)
            fadeOutSec = min(2.4, duration * 0.46)
        case .exhale:
            fadeInSec = min(0.95, duration * 0.20)
            fadeOutSec = min(3.4, duration * 0.62)
        }
        let fadeIn = min(frames, max(1, Segments.frames(seconds: fadeInSec, sampleRate: sampleRate)))
        let fadeOut = min(frames, max(1, Segments.frames(seconds: fadeOutSec, sampleRate: sampleRate)))
        for i in 0..<fadeIn {
            let t = Float(i) / Float(max(1, fadeIn - 1))
            out[i] *= 0.5 - 0.5 * cos(t * Float.pi)
        }
        for i in 0..<fadeOut {
            let t = Float(i) / Float(max(1, fadeOut - 1))
            out[frames - 1 - i] *= 0.5 - 0.5 * cos(t * Float.pi)
        }
        out[0] = 0
        out[frames - 1] = 0
        return out
    }

    private static func shortBranch(totalFrames: Int, loop: [Float], clips: BreathSourceClips) -> [Float] {
        let source: [Float]
        if let oneShot = clips.oneShot, oneShot.count > 1 {
            source = oneShot
        } else if loop.count > 1 {
            source = loop
        } else if clips.start.count > 1 {
            source = clips.start
        } else {
            return [Float](repeating: 0, count: totalFrames)
        }
        return Resample.toFrames(source, totalFrames)
    }

    private static func normalBranch(
        totalFrames: Int,
        startUse: Int,
        endUse: Int,
        loop: [Float],
        clips: BreathSourceClips,
        settings: AssemblerSettings
    ) -> [Float] {
        let head = Array(clips.start[0..<startUse])
        let tail = Array(clips.end[(clips.end.count - endUse)...])
        let requestedX = Segments.frames(seconds: settings.crossfadeSec, sampleRate: settings.sampleRate)
        let x = Segments.clampCrossfade(requestedX, loopLen: loop.count, startLen: startUse, endLen: endUse)

        // total = startUse + middleLen - 2x + endUse  ⇒  middleLen = total - start - end + 2x
        let middleLen = totalFrames - startUse - endUse + 2 * x
        guard middleLen >= 1 else {
            return shortBranch(totalFrames: totalFrames, loop: loop, clips: clips)
        }

        let middle = Crossfade.assembleLoopedMiddle(loop: loop, targetLen: middleLen, crossfadeLen: x)
        var out = [Float](repeating: 0, count: totalFrames)
        Crossfade.place(into: &out, segment: head, at: 0, headCrossfade: 0)
        Crossfade.place(into: &out, segment: middle, at: startUse - x, headCrossfade: x)
        Crossfade.place(into: &out, segment: tail, at: startUse + middleLen - 2 * x, headCrossfade: x)
        return out
    }
}
