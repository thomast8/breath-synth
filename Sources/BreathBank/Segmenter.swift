import BreathEngine
import Foundation

/// Cuts one recorded take into gradeable sub-take fragments and produces the signal those fragments
/// index into (the engine's prepared / energy-flat-texture cache). Pure `[Float]` math, no actor
/// isolation, so the offline builder runs it synchronously.
///
/// The fragment geometry mirrors the engine's render paths exactly, so a bank's offsets reproduce
/// what the engine renders from the same prepared signal:
///   • `texture` (calm)      → energy-flat texture grains, the `recordedShapeBranch` loop unit.
///   • `oneShotBody` (frc/rv) → the whole `trimToMainBody` maneuver (the engine re-derives it per take,
///                              so no on-disk cache is written; the bank only accept-filters takes).
///   • `cores` (packing)     → `UnitExtractor` gulp cores, the `assembleHybrid` unit.
///   • `gaps` (packing)      → inter-onset rhythm gaps, carried as a frame count (cadence only, no audio).
public enum Segmenter {
    /// Grain geometry — kept in lock-step with `recordedShapeBranch`'s 2.5 s grain and ≥0.7 s
    /// crossfade so pooled grains tile the same way the single-texture loop does.
    static let grainSec = 2.5
    static let grainCrossfadeSec = 0.7

    /// The cache signal a take's fragment offsets index into, plus the cut fragments. `cacheSignal`
    /// is `nil` for kinds the engine re-derives at render time (`oneShotBody`, `gaps`), which
    /// therefore need no on-disk prepared cache.
    public struct Output: Sendable {
        public var cacheSignal: [Float]?
        public var fragments: [Raw]
        public init(cacheSignal: [Float]?, fragments: [Raw]) {
            self.cacheSignal = cacheSignal
            self.fragments = fragments
        }
    }

    /// A cut fragment before grading: its offset into the cache signal, the audio to grade (the same
    /// audio the engine will render — post-declick for cores), and per-kind metadata.
    public struct Raw: Sendable {
        public var startFrame: Int
        public var endFrame: Int
        public var kind: FragmentKind
        /// The fragment's audio (empty for `gap`, which carries only a frame count).
        public var audio: [Float]
        public var peakHeight: Float?
        public var gapToNext: Int?
        public init(
            startFrame: Int, endFrame: Int, kind: FragmentKind,
            audio: [Float], peakHeight: Float? = nil, gapToNext: Int? = nil
        ) {
            self.startFrame = startFrame
            self.endFrame = endFrame
            self.kind = kind
            self.audio = audio
            self.peakHeight = peakHeight
            self.gapToNext = gapToNext
        }
    }

    public static func segment(
        rawTake: [Float],
        role: String,
        type: BreathType,
        settings: AssemblerSettings,
        roomToneProfile: [Float]?
    ) -> Output {
        let sr = settings.sampleRate
        let prepared = BreathAssembler.prepareSource(rawTake, settings: settings, noiseProfile: roomToneProfile)
        guard prepared.count > 1 else { return Output(cacheSignal: nil, fragments: []) }

        switch role {
        case "texture":
            return textureGrains(prepared: prepared, type: type, sampleRate: sr)
        case "oneShotBody":
            let body = BreathAssembler.trimToMainBody(prepared, sampleRate: sr)
            let frag = Raw(
                startFrame: 0, endFrame: body.count, kind: .oneShotBody,
                audio: body, peakHeight: body.map { abs($0) }.max()
            )
            return Output(cacheSignal: nil, fragments: [frag])
        case "cores":
            return gulpCoreFragments(prepared: prepared, sampleRate: sr)
        case "gaps":
            let gaps = UnitExtractor.rhythmGaps(from: prepared, sampleRate: sr)
            let frags = gaps.map { Raw(startFrame: 0, endFrame: 0, kind: .gap, audio: [], gapToNext: $0) }
            return Output(cacheSignal: nil, fragments: frags)
        default:
            return Output(cacheSignal: nil, fragments: [])
        }
    }

    // MARK: - Per-role segmentation

    private static func textureGrains(prepared: [Float], type: BreathType, sampleRate sr: Double) -> Output {
        let envelope = BreathAssembler.rmsEnvelope(prepared, sampleRate: sr)
        let texture = BreathAssembler.flattenedTexture(from: prepared, envelope: envelope, type: type, sampleRate: sr)
        guard texture.count > 1 else { return Output(cacheSignal: nil, fragments: []) }

        let grain = min(texture.count, Segments.frames(seconds: grainSec, sampleRate: sr))
        var fragments: [Raw] = []
        if texture.count <= grain {
            // Texture shorter than one grain: the whole texture is the only grain.
            fragments.append(Raw(startFrame: 0, endFrame: texture.count, kind: .grain, audio: texture))
        } else {
            let xfade = min(max(1, Segments.frames(seconds: grainCrossfadeSec, sampleRate: sr)), grain - 1)
            let stride = max(1, grain - xfade)
            var pos = 0
            while pos + grain <= texture.count {
                fragments.append(Raw(
                    startFrame: pos, endFrame: pos + grain, kind: .grain,
                    audio: Array(texture[pos..<pos + grain])
                ))
                pos += stride
            }
        }
        return Output(cacheSignal: texture, fragments: fragments)
    }

    private static func gulpCoreFragments(prepared: [Float], sampleRate sr: Double) -> Output {
        let ranges = UnitExtractor.gulpCoreRanges(from: prepared, sampleRate: sr)
        var fragments: [Raw] = []
        for (i, range) in ranges.enumerated() {
            let core = UnitExtractor.declickedCore(Array(prepared[range]), sampleRate: sr)
            let gapToNext = i + 1 < ranges.count ? ranges[i + 1].lowerBound - range.lowerBound : nil
            fragments.append(Raw(
                startFrame: range.lowerBound, endFrame: range.upperBound, kind: .gulpCore,
                audio: core, peakHeight: core.map { abs($0) }.max(), gapToNext: gapToNext
            ))
        }
        return Output(cacheSignal: prepared, fragments: fragments)
    }
}
