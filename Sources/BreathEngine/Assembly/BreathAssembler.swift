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

    public init(
        sampleRate: Double = AudioConstants.workingSampleRate,
        startCapSec: Double = 0.6,
        endCapSec: Double = 0.8,
        crossfadeSec: Double = 0.2,
        shortThresholdSec: Double = 1.5
    ) {
        self.sampleRate = sampleRate
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
