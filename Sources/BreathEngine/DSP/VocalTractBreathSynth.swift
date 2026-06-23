import Foundation

enum VocalTractBreathSynth {
    private struct Shape {
        var diameters: [Float]
        var gain: Double
        var glottalReflection: Float
        var lipReflection: Float
        var constrictionIndex: Int
        var constrictionGain: Float
        var aspirationGain: Float
        var damping: Float
        var mouthLowpassHz: Double
        var bodyHz: Double
        var radiationMix: Float
        var bodyMix: Float
        var onsetSeconds: Double
        var releaseSeconds: Double
        var sourceSmoothHz: Double
        var outputSmoothHz: Double
        var lowMidDipHz: Double
        var lowMidDipAmount: Float
        var airHz: Double
        var airGain: Float
    }

    static func render(
        spec: BreathSpec,
        sampleRate: Double,
        config: ProceduralBreathConfig,
        deltas: VariationDeltas
    ) throws -> [Float] {
        guard ProceduralBreathSynth.supportedStyles.contains(spec.style) else {
            throw BreathError.unsupportedProceduralStyle(spec.style)
        }

        let frames = max(1, Segments.frames(seconds: spec.clampedDurationSec, sampleRate: sampleRate))
        let shape = makeShape(style: spec.style, type: spec.type, brightness: deltas.playbackRate)
        let areas = shape.diameters.map { max(0.05, $0 * $0) }
        let reflections = reflectionCoefficients(areas: areas)
        let sectionCount = shape.diameters.count
        var right = [Float](repeating: 0, count: sectionCount)
        var left = [Float](repeating: 0, count: sectionCount)
        var nextRight = right
        var nextLeft = left
        var out = [Float](repeating: 0, count: frames)

        let seed = spec.seed ?? Variation.stableSeed(for: spec)
        var rng = SeededRNG(seed: seed ^ 0x7551_5A11_7A6C_0001)
        var aspiration = PinkNoise()
        var constriction = PinkNoise()
        var lipMemory: Float = 0
        let drift = ProceduralSupport.randomWalk(
            frames: frames,
            sampleRate: sampleRate,
            intervalSeconds: spec.type == .inhale ? 0.33 : 0.46,
            depth: Float(0.12 + config.modulationAmount),
            rng: &rng
        )

        var constrictionHigh = Biquad(
            kind: .highpass,
            sampleRate: sampleRate,
            frequency: spec.type == .inhale ? 720 : 440,
            q: 0.7
        )
        var mouthLow = Biquad(
            kind: .lowpass,
            sampleRate: sampleRate,
            frequency: shape.mouthLowpassHz,
            q: 0.7
        )
        var aspirationSmooth = Biquad(
            kind: .lowpass,
            sampleRate: sampleRate,
            frequency: shape.sourceSmoothHz,
            q: 0.65
        )
        var constrictionSmooth = Biquad(
            kind: .lowpass,
            sampleRate: sampleRate,
            frequency: max(300, shape.sourceSmoothHz * 1.35),
            q: 0.65
        )
        var bodyBand = Biquad(kind: .bandpass, sampleRate: sampleRate, frequency: shape.bodyHz, q: 0.48)
        var bodyLow = Biquad(
            kind: .lowpass,
            sampleRate: sampleRate,
            frequency: spec.type == .inhale ? 1_100 : 860,
            q: 0.65
        )
        var finalSmooth = Biquad(
            kind: .lowpass,
            sampleRate: sampleRate,
            frequency: shape.outputSmoothHz,
            q: 0.62
        )
        var lowMidDip = Biquad(kind: .bandpass, sampleRate: sampleRate, frequency: shape.lowMidDipHz, q: 0.42)
        var airBand = Biquad(kind: .bandpass, sampleRate: sampleRate, frequency: shape.airHz, q: 0.45)

        for i in 0..<frames {
            let pressure = drift[i]
            let aspirationNoise = aspiration.next(rng: &rng)
            let asp = aspirationSmooth.process(aspirationNoise) * shape.aspirationGain * pressure
            var fric = constriction.next(rng: &rng)
            fric = constrictionSmooth.process(constrictionHigh.process(fric)) * shape.constrictionGain * pressure

            nextRight[0] = asp + left[0] * shape.glottalReflection
            nextLeft[sectionCount - 1] = right[sectionCount - 1] * shape.lipReflection

            for junction in 1..<sectionCount {
                let reflected = reflections[junction] * (right[junction - 1] + left[junction])
                nextRight[junction] = (right[junction - 1] - reflected) * shape.damping
                nextLeft[junction - 1] = (left[junction] + reflected) * shape.damping
            }

            let c = min(max(shape.constrictionIndex, 1), sectionCount - 2)
            nextRight[c] += fric * 0.42
            nextLeft[c - 1] += fric * 0.16

            let mouthPressure = nextRight[sectionCount - 1] + nextLeft[sectionCount - 1]
            let lipDelta = mouthPressure - lipMemory
            let radiatingPressure = mouthPressure * (1 - shape.radiationMix) + lipDelta * shape.radiationMix
            let radiated = mouthLow.process(radiatingPressure)
            let body = (bodyBand.process(mouthPressure) * 0.08 + bodyLow.process(mouthPressure) * 0.045)
                * shape.bodyMix
            let air = airBand.process(aspirationNoise) * shape.airGain * pressure
            let combined = radiated + body
            let lowMid = lowMidDip.process(combined)
            lipMemory = mouthPressure
            out[i] = finalSmooth.process(combined - lowMid * shape.lowMidDipAmount + air)

            swap(&right, &nextRight)
            swap(&left, &nextLeft)
            nextRight.withUnsafeMutableBufferPointer { ptr in
                ptr.initialize(repeating: 0)
            }
            nextLeft.withUnsafeMutableBufferPointer { ptr in
                ptr.initialize(repeating: 0)
            }
        }

        return ProceduralSupport.finish(
            applySoftEdgeMask(
                out,
                sampleRate: sampleRate,
                onsetSeconds: shape.onsetSeconds,
                releaseSeconds: shape.releaseSeconds
            ),
            spec: spec,
            sampleRate: sampleRate,
            gain: shape.gain,
            config: config,
            deltas: deltas
        )
    }

    private static func makeShape(style: BreathStyle, type: BreathType, brightness: Double) -> Shape {
        let sectionCount = 38
        let b = Float(min(max(brightness, 0.92), 1.08))
        var diameters = [Float](repeating: style == "calm" ? 1.35 : 1.45, count: sectionCount)
        for i in 0..<sectionCount {
            let x = Float(i) / Float(sectionCount - 1)
            let pharynx = 0.95 + 0.55 * sin(Float.pi * min(x, 0.45) / 0.45)
            let oral = 1.15 + 0.35 * sin(Float.pi * max(0, x - 0.25) / 0.75)
            diameters[i] = max(0.35, min(2.2, pharynx * 0.45 + oral * 0.65))
        }

        switch (style, type) {
        case ("calm", .inhale):
            pinch(&diameters, center: 31, radius: 4, diameter: 0.44 * b)
            softenMouth(&diameters, amount: 0.90)
            return Shape(
                diameters: diameters,
                gain: 0.54,
                glottalReflection: 0.56,
                lipReflection: -0.62,
                constrictionIndex: 31,
                constrictionGain: 0.10,
                aspirationGain: 0.28,
                damping: 0.989,
                mouthLowpassHz: 2_050,
                bodyHz: 610,
                radiationMix: 0.10,
                bodyMix: 0.35,
                onsetSeconds: 0.95,
                releaseSeconds: 1.05,
                sourceSmoothHz: 680,
                outputSmoothHz: 2_350,
                lowMidDipHz: 670,
                lowMidDipAmount: 0.48,
                airHz: 1_850,
                airGain: 0.020
            )
        case ("calm", .exhale):
            pinch(&diameters, center: 27, radius: 5, diameter: 0.55 * b)
            softenMouth(&diameters, amount: 1.02)
            return Shape(
                diameters: diameters,
                gain: 0.60,
                glottalReflection: 0.60,
                lipReflection: -0.66,
                constrictionIndex: 27,
                constrictionGain: 0.08,
                aspirationGain: 0.34,
                damping: 0.991,
                mouthLowpassHz: 1_680,
                bodyHz: 460,
                radiationMix: 0.07,
                bodyMix: 0.28,
                onsetSeconds: 1.10,
                releaseSeconds: 1.20,
                sourceSmoothHz: 540,
                outputSmoothHz: 1_850,
                lowMidDipHz: 520,
                lowMidDipAmount: 0.44,
                airHz: 1_450,
                airGain: 0.016
            )
        case ("neutral", .inhale):
            pinch(&diameters, center: 32, radius: 3, diameter: 0.38 * b)
            return Shape(
                diameters: diameters,
                gain: 0.70,
                glottalReflection: 0.58,
                lipReflection: -0.64,
                constrictionIndex: 32,
                constrictionGain: 0.14,
                aspirationGain: 0.30,
                damping: 0.989,
                mouthLowpassHz: 2_400,
                bodyHz: 680,
                radiationMix: 0.12,
                bodyMix: 0.42,
                onsetSeconds: 0.78,
                releaseSeconds: 0.90,
                sourceSmoothHz: 840,
                outputSmoothHz: 2_800,
                lowMidDipHz: 760,
                lowMidDipAmount: 0.42,
                airHz: 2_100,
                airGain: 0.026
            )
        default:
            pinch(&diameters, center: 26, radius: 4, diameter: 0.48 * b)
            return Shape(
                diameters: diameters,
                gain: 0.74,
                glottalReflection: 0.62,
                lipReflection: -0.68,
                constrictionIndex: 26,
                constrictionGain: 0.12,
                aspirationGain: 0.36,
                damping: 0.991,
                mouthLowpassHz: 1_980,
                bodyHz: 520,
                radiationMix: 0.09,
                bodyMix: 0.34,
                onsetSeconds: 0.88,
                releaseSeconds: 1.05,
                sourceSmoothHz: 660,
                outputSmoothHz: 2_250,
                lowMidDipHz: 590,
                lowMidDipAmount: 0.40,
                airHz: 1_700,
                airGain: 0.022
            )
        }
    }

    private static func reflectionCoefficients(areas: [Float]) -> [Float] {
        var reflections = [Float](repeating: 0, count: areas.count)
        guard areas.count > 1 else { return reflections }
        for i in 1..<areas.count {
            let sum = areas[i - 1] + areas[i]
            reflections[i] = sum > 0 ? (areas[i - 1] - areas[i]) / sum : 0
            reflections[i] = min(0.68, max(-0.68, reflections[i]))
        }
        return reflections
    }

    private static func pinch(_ diameters: inout [Float], center: Int, radius: Int, diameter: Float) {
        guard !diameters.isEmpty else { return }
        for i in max(0, center - radius)..<min(diameters.count, center + radius + 1) {
            let distance = abs(Float(i - center)) / Float(max(1, radius))
            let influence = 0.5 + 0.5 * cos(Float.pi * min(1, distance))
            diameters[i] = diameters[i] * (1 - influence) + diameter * influence
        }
    }

    private static func softenMouth(_ diameters: inout [Float], amount: Float) {
        guard diameters.count > 10 else { return }
        for i in (diameters.count - 10)..<diameters.count {
            diameters[i] *= amount
        }
    }

    private static func applySoftEdgeMask(
        _ samples: [Float],
        sampleRate: Double,
        onsetSeconds: Double,
        releaseSeconds: Double
    ) -> [Float] {
        guard !samples.isEmpty else { return samples }
        var out = samples
        if onsetSeconds > 0 {
            let frames = min(out.count, max(1, Int((onsetSeconds * sampleRate).rounded())))
            for i in 0..<frames {
                let x = Float(i) / Float(max(1, frames - 1))
                out[i] *= smootherstep(x)
            }
        }
        if releaseSeconds > 0 {
            let frames = min(out.count, max(1, Int((releaseSeconds * sampleRate).rounded())))
            for offset in 0..<frames {
                let x = Float(offset) / Float(max(1, frames - 1))
                out[out.count - 1 - offset] *= smootherstep(x)
            }
        }
        return out
    }

    private static func smootherstep(_ x: Float) -> Float {
        x * x * x * (x * (x * 6 - 15) + 10)
    }
}
