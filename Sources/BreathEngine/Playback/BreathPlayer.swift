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

    /// Pause playback, keeping the schedule and position so `resume()` continues from here.
    public func pause() {
        player.pause()
    }

    /// Resume after `pause()`.
    public func resume() {
        if started, !player.isPlaying { player.play() }
    }

    /// Play `buffer` once from `startFrame` (a seek), resolving when it finishes. Resets the node clock,
    /// so `currentSampleTime` then counts from the slice start — the caller offsets by `startFrame` for
    /// an absolute buffer position. (`scheduleSegment` is file-only, so we schedule a copied slice.)
    public func play(_ buffer: AVAudioPCMBuffer, fromFrame startFrame: AVAudioFramePosition) async throws {
        player.stop()
        try ensureRunning()
        guard let segment = Self.slice(buffer, fromFrame: startFrame) else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            player.scheduleBuffer(segment, at: nil, options: [], completionCallbackType: .dataPlayedBack) { _ in
                continuation.resume()
            }
        }
    }

    /// A copy of `buffer` from `startFrame` to the end (mono/multi-channel), or nil if empty.
    private static func slice(_ buffer: AVAudioPCMBuffer, fromFrame startFrame: AVAudioFramePosition) -> AVAudioPCMBuffer? {
        let total = AVAudioFramePosition(buffer.frameLength)
        let start = AVAudioFrameCount(max(0, min(startFrame, total)))
        let count = AVAudioFrameCount(total) - start
        guard count > 0, let out = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: count) else { return nil }
        out.frameLength = count
        if let src = buffer.floatChannelData, let dst = out.floatChannelData {
            for ch in 0..<Int(buffer.format.channelCount) {
                dst[ch].update(from: src[ch] + Int(start), count: Int(count))
            }
        }
        return out
    }

    /// The player node's current render position in frames since playback started, or nil when not
    /// playing / before the render clock is valid. Monotonic and continuous across back-to-back
    /// `play(_:times:)` buffers and `loopForever` (it does NOT wrap at the buffer boundary), so a
    /// caller wanting a within-buffer position must modulo by the buffer length itself.
    public var currentSampleTime: AVAudioFramePosition? {
        guard started, player.isPlaying,
              let nodeTime = player.lastRenderTime,
              let playerTime = player.playerTime(forNodeTime: nodeTime) else { return nil }
        return playerTime.sampleTime
    }
}
