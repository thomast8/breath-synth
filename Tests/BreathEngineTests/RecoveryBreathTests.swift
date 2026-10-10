import Testing
import Foundation
@testable import BreathEngine

/// Recovery hook breaths on a fixed cadence (`RecoveryCadence`).
///
/// The recorded hooks are ~1 s each. Rendered as recorded, five recovery breaths lasted ~5 s, and
/// a caller drawing a guide from the rendered length ran it at twice a usable pace. The recovery
/// render lays each breath out on the cadence instead, so the two things a caller has to rely on
/// are that the length is exact and that every part sounds where the cadence says it does.
@MainActor
struct RecoveryBreathTests {
    private let sr = AudioConstants.workingSampleRate

    // MARK: - Pure assembly

    private func burst(_ frames: Int, amp: Float, freq: Double) -> [Float] {
        (0..<frames).map { i in
            let window = Float(0.5 - 0.5 * cos(2 * Double.pi * Double(i) / Double(max(1, frames - 1))))
            return amp * window * Float(sin(2 * Double.pi * freq * Double(i) / sr))
        }
    }

    /// Six hooks shaped like `recovery.aifc`: a 0.27 s sip, 0.23 s apart from a louder 0.35 s
    /// release, ~1.03 s a hook. Each hook's release is pitched differently, so which one a render
    /// used is visible in its samples.
    private func syntheticHookTake() -> [Float] {
        var take = [Float](repeating: 0, count: Int(0.3 * sr))
        for hook in 0..<6 {
            take += burst(Int(0.27 * sr), amp: 0.3, freq: 900)
            take += [Float](repeating: 0, count: Int(0.23 * sr))
            take += burst(Int(0.35 * sr), amp: 0.5, freq: 1_100 + 150 * Double(hook))
            take += [Float](repeating: 0, count: Int(0.18 * sr))
        }
        return take + [Float](repeating: 0, count: Int(0.3 * sr))
    }

    private func rms(_ samples: ArraySlice<Float>) -> Float {
        guard !samples.isEmpty else { return 0 }
        return (samples.reduce(Float(0)) { $0 + $1 * $1 } / Float(samples.count)).squareRoot()
    }

    @Test func hookPartsSplitsEverySyntheticHookIntoSipAndRelease() {
        let take = syntheticHookTake()
        let ranges = UnitExtractor.hookPartRanges(from: take, sampleRate: sr)
        let parts = UnitExtractor.hookParts(from: take, sampleRate: sr)

        #expect(ranges.count == 6)
        #expect(parts.count == 6)
        #expect(UnitExtractor.extract(from: take, sampleRate: sr).count == 6, "same units as extract")
        for (hook, range) in ranges.enumerated() {
            // The release begins half a second after its sip: 0.3 s lead-in, 1.03 s a hook.
            let releaseOnset = 0.3 + Double(hook) * 1.03 + 0.5
            #expect(abs(Double(range.outRelease.lowerBound) / sr - releaseOnset) < 0.05, "hook \(hook)")
            #expect(!range.inSip.isEmpty, "hook \(hook) lost its sip")
            #expect(range.inSip.upperBound <= range.outRelease.lowerBound, "hook \(hook) halves overlap")
            #expect(Double(range.outRelease.count) / sr > 0.3, "hook \(hook) release was cut short")
        }
        for part in parts {
            #expect(rms(part.inSip[...]) > 0.01)
            #expect(rms(part.outRelease[...]) > 0.01)
        }
    }

    @Test func aRecoveryBreathIsExactlyItsCadence() {
        let cadences = [
            RecoveryCadence.standard,
            RecoveryCadence(inhale: 0.7, hook: 0.33, exhale: 1.21, pause: 0.0001),
        ]
        for cadence in cadences {
            let inhale = burst(Segments.frames(seconds: cadence.inhale, sampleRate: sr), amp: 0.4, freq: 3_000)
            let release = burst(Int(0.4 * sr), amp: 0.45, freq: 1_200)
            let tail = burst(Segments.frames(seconds: cadence.exhale, sampleRate: sr), amp: 0.3, freq: 700)
            let out = BreathAssembler.assembleRecoveryBreath(
                inhale: inhale, release: release, exhaleTail: tail, cadence: cadence, sampleRate: sr
            )
            #expect(out.count == Segments.frames(seconds: cadence.breathSec, sampleRate: sr))
        }

        let cadence = RecoveryCadence.standard
        let out = BreathAssembler.assembleRecoveryBreath(
            inhale: burst(Int(1.0 * sr), amp: 0.4, freq: 3_000),
            release: burst(Int(0.4 * sr), amp: 0.45, freq: 1_200),
            exhaleTail: burst(Int(1.5 * sr), amp: 0.3, freq: 700),
            cadence: cadence,
            sampleRate: sr
        )
        #expect(out.count == 176_400, "4.0 s at 44.1 kHz")
        let inhaleEnd = 44_100, exhaleStart = 88_200, exhaleEnd = 154_350
        #expect(rms(out[0..<inhaleEnd]) > 0.05, "inhale")
        #expect(out[inhaleEnd..<exhaleStart].allSatisfy { $0 == 0 }, "the hook is silent")
        #expect(rms(out[exhaleStart..<exhaleEnd]) > 0.02, "exhale")
        #expect(rms(out[(exhaleEnd - 22_050)..<(exhaleEnd - 4_410)]) > 0.001, "the tail carries the exhale on")
        #expect(out[exhaleEnd..<out.count].allSatisfy { $0 == 0 }, "the pause is silent")
    }

    @Test func aRecoveryBreathWithNothingToPlayIsStillItsLength() {
        let cadence = RecoveryCadence.standard
        let out = BreathAssembler.assembleRecoveryBreath(
            inhale: [], release: [], exhaleTail: [], cadence: cadence, sampleRate: sr
        )
        #expect(out.count == Segments.frames(seconds: cadence.breathSec, sampleRate: sr))
        #expect(out.allSatisfy { $0 == 0 })
    }

    // MARK: - The engine, on the shipped palette

    private var shippedAssets: URL {
        URL(fileURLWithPath: #filePath)   // …/Tests/BreathEngineTests/RecoveryBreathTests.swift
            .deletingLastPathComponent()  // BreathEngineTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // package root
            .appendingPathComponent("Assets/breaths")
    }

    @Test func theShippedRecoveryTakeSplitsIntoSixHooks() throws {
        let raw = try AssetLibrary.loadMonoSamples(
            url: shippedAssets.appendingPathComponent("recovery.aifc"), targetRate: sr
        )
        // The same prepare the engine renders from, with its room-tone profile.
        let profile = SpectralDenoise.magnitudeProfile(
            from: try AssetLibrary.loadMonoSamples(
                url: shippedAssets.appendingPathComponent("room_silence.aifc"), targetRate: sr
            ),
            sampleRate: sr
        )
        let prepared = BreathAssembler.prepareSource(raw, settings: AssemblerSettings(), noiseProfile: profile)
        let parts = UnitExtractor.hookParts(from: prepared, sampleRate: sr)

        #expect(parts.count == 6)
        for part in parts {
            #expect(!part.inSip.isEmpty)
            // ~0.35 s of release above the gate in the reference take, plus pre-roll and decay.
            let seconds = Double(part.outRelease.count) / sr
            #expect(seconds > 0.25 && seconds < 0.8, "release of \(seconds) s")
        }
    }

    @Test func recoveryBreathsAreExactlyTheCadenceOnTheShippedPalette() async throws {
        let engine = try BreathEngine.load(assetsDirectory: shippedAssets)
        let custom = RecoveryCadence(inhale: 1.2, hook: 0.8, exhale: 2.0, pause: 1.0, release: 3.0)
        for index in 0..<7 {
            let breath = try engine.renderRecoveryBreathSamples(index: index)
            #expect(breath.count == Segments.frames(seconds: 4.0, sampleRate: sr), "breath \(index)")
        }
        let longer = try await engine.renderRecoveryBreathSamplesOffActor(index: 2, cadence: custom)
        #expect(longer.count == Segments.frames(seconds: custom.breathSec, sampleRate: sr))
    }

    /// Nadir #382: the recovery exhale sounded like an inhale. After the recorded release the
    /// airflow swelled back up to full loudness, because the tail was the end of a calm exhale only
    /// as long as the exhale, which still held that exhale's own attack and peak. Once the release
    /// has handed over, the exhale only ever winds down.
    @Test func aShippedRecoveryExhaleNeverSwellsAfterItsRelease() throws {
        let engine = try BreathEngine.load(assetsDirectory: shippedAssets)
        let bin = Int(0.05 * sr)
        let exhaleStart = 88_200, exhaleEnd = 154_350
        for index in 0..<6 {
            let breath = try engine.renderRecoveryBreathSamples(index: index)
            // From the end of the 0.3 s crossfade, where only the tail is left.
            let bins = stride(from: exhaleStart + Int(0.3 * sr), to: exhaleEnd - bin, by: bin).map {
                rms(breath[$0..<($0 + bin)])
            }
            for k in 1..<bins.count {
                let before = bins[0..<k].max() ?? 0
                #expect(bins[k] <= before * 1.2, "breath \(index) swells at bin \(k): \(bins[k]) after \(before)")
            }
        }
    }

    @Test func everyPartOfAShippedRecoveryBreathSoundsWhereTheCadenceSaysItDoes() throws {
        let engine = try BreathEngine.load(assetsDirectory: shippedAssets)
        let breath = try engine.renderRecoveryBreathSamples(index: 0)
        let inhaleEnd = 44_100, exhaleStart = 88_200, exhaleEnd = 154_350
        #expect(rms(breath[0..<inhaleEnd]) > 0.005, "inhale")
        #expect(breath[inhaleEnd..<exhaleStart].allSatisfy { $0 == 0 }, "hook")
        #expect(rms(breath[exhaleStart..<(exhaleStart + 13_230)]) > 0.005, "the recorded release")
        #expect(rms(breath[(exhaleStart + 22_050)..<(exhaleEnd - 4_410)]) > 0.002, "the exhale after it")
        #expect(breath[exhaleEnd..<breath.count].allSatisfy { $0 == 0 }, "pause")
    }

    @Test func theReleaseIsAnAudibleExhaleOfExactlyItsLength() async throws {
        let engine = try BreathEngine.load(assetsDirectory: shippedAssets)
        let release = try engine.renderRecoveryReleaseSamples()
        #expect(release.count == Segments.frames(seconds: 2.5, sampleRate: sr))
        // The bug this replaces: the post-hold exhale was rendered from `full`, which has no
        // exhale recordings, and came out as 2.5 s of zeros under a drawn exhale.
        #expect(rms(release[...]) > 0.005)
        #expect((release.map { abs($0) }.max() ?? 0) > 0.02)

        let short = try await engine.renderRecoveryReleaseSamplesOffActor(
            cadence: RecoveryCadence(release: 0.4)
        )
        #expect(short.count == Segments.frames(seconds: 0.4, sampleRate: sr))
        #expect(try engine.renderRecoveryReleaseSamples(cadence: RecoveryCadence(release: 0)).isEmpty)
    }

    @Test func recoveryBreathsAreDeterministicAndVaryByIndexAndSeed() async throws {
        let engine = try BreathEngine.load(assetsDirectory: shippedAssets)
        let first = try engine.renderRecoveryBreathSamples(index: 1, seed: 9)
        #expect(try engine.renderRecoveryBreathSamples(index: 1, seed: 9) == first)
        #expect(try await engine.renderRecoveryBreathSamplesOffActor(index: 1, seed: 9) == first,
                "moving the render off the actor changed the audio")
        #expect(try engine.renderRecoveryBreathSamples(index: 1) == engine.renderRecoveryBreathSamples(index: 1),
                "an unseeded breath is stable")

        let exhale = 88_200..<154_350
        let otherHook = try engine.renderRecoveryBreathSamples(index: 2, seed: 9)
        #expect(Array(otherHook[exhale]) != Array(first[exhale]), "a different index plays a different hook")
        let otherSeed = try engine.renderRecoveryBreathSamples(index: 1, seed: 10)
        #expect(Array(otherSeed[0..<44_100]) != Array(first[0..<44_100]), "a different seed varies the inhale")
        let wrapped = try engine.renderRecoveryBreathSamples(index: 7, seed: 9)
        #expect(wrapped == first, "index wraps around the six recorded hooks")

        #expect(try engine.renderRecoveryReleaseSamples(seed: 3) == engine.renderRecoveryReleaseSamples(seed: 3))
    }

    /// Callers that render hooks one at a time (`count: 1, seed: event`) used to get unit 0 every
    /// time, because the single-take path ignored the seed.
    @Test func aSingleCountedHookIsPickedBySeed() throws {
        let engine = try BreathEngine.load(assetsDirectory: shippedAssets)
        let hooks = try (0..<6).map {
            try engine.renderCountedSamples(style: "recovery", type: .inhale, count: 1, seed: UInt64($0))
        }
        #expect(Set(hooks).count == 6, "six distinct recorded hooks")
        #expect(try engine.renderCountedSamples(style: "recovery", type: .inhale, count: 1, seed: 6) == hooks[0])
        // Unseeded and multi-event renders are unchanged: they still start from the first hook.
        let unseeded = try engine.renderCountedSamples(style: "recovery", type: .inhale, count: 1)
        let two = try engine.renderCountedSamples(style: "recovery", type: .inhale, count: 2, seed: 4)
        #expect(unseeded == hooks[0])
        #expect(two.count > hooks[0].count)
    }

    @Test func aRecoveryAfterAHoldIsTheReleaseThenEveryBreathAndItsLoudnessKnobsScale() throws {
        let engine = try BreathEngine.load(assetsDirectory: shippedAssets)
        let buffer = try engine.renderRecovery(breaths: 5)
        #expect(Int(buffer.frameLength) == Int((22.5 * sr).rounded()), "2.5 s release + 5 × 4 s")

        let release = try engine.renderRecoveryReleaseSamples(cadence: RecoveryCadence(releaseLevel: 1))
        let quieter = try engine.renderRecoveryReleaseSamples(cadence: RecoveryCadence(releaseLevel: 0.5))
        let peak = release.map { abs($0) }.max() ?? 0
        #expect(abs((quieter.map { abs($0) }.max() ?? 0) - peak / 2) < 1e-4)
    }
}
