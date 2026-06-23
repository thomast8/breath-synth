import AVFoundation
import Foundation

/// Thin wrapper over AVAudioEngine + AVAudioPlayerNode for mono Float playback.
/// All AVFoundation objects stay on the main actor.
@MainActor
public final class BreathPlayer {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    let format: AVAudioFormat
    private var started = false

    public init(sampleRate: Double) throws {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw BreathError.audioFormatUnavailable
        }
        self.format = format
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
    }

    private func ensureRunning() throws {
        if !started {
            engine.prepare()
            do {
                try engine.start()
            } catch {
                throw BreathError.ioFailure("starting audio engine: \(error.localizedDescription)")
            }
            started = true
        }
        if !player.isPlaying {
            player.play()
        }
    }

    /// Schedule a buffer once and resume when it has finished playing.
    public func playOnce(_ buffer: AVAudioPCMBuffer) async throws {
        try ensureRunning()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            player.scheduleBuffer(buffer, at: nil, options: [], completionCallbackType: .dataPlayedBack) { _ in
                continuation.resume()
            }
        }
    }

    /// Schedule a buffer to loop forever (sample-accurate, gapless). Returns immediately.
    public func loopForever(_ buffer: AVAudioPCMBuffer) throws {
        try ensureRunning()
        player.scheduleBuffer(buffer, at: nil, options: [.loops], completionCallbackType: .dataPlayedBack) { _ in }
    }

    /// Schedule a buffer `count` times back-to-back and resume when the last finishes.
    public func play(_ buffer: AVAudioPCMBuffer, times count: Int) async throws {
        guard count > 0 else { return }
        try ensureRunning()
        for index in 0..<count {
            let isLast = index == count - 1
            if isLast {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    player.scheduleBuffer(buffer, at: nil, options: [], completionCallbackType: .dataPlayedBack) { _ in
                        continuation.resume()
                    }
                }
            } else {
                player.scheduleBuffer(buffer, at: nil, options: [], completionCallbackType: .dataPlayedBack) { _ in }
            }
        }
    }

    public func stop() {
        player.stop()
        if started {
            engine.stop()
            started = false
        }
    }
}
