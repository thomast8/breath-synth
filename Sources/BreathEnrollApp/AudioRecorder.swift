import AVFoundation
import Foundation

/// Owns the output file and writes buffers straight from the audio render thread. `@unchecked
/// Sendable` is sound: `write` is only ever called from the single AVAudioEngine tap callback,
/// which is serialized, and the file is released only after the tap is removed.
private final class RecordingSink: @unchecked Sendable {
    private let file: AVAudioFile
    init(url: URL, format: AVAudioFormat) throws {
        file = try AVAudioFile(forWriting: url, settings: format.settings)
    }
    func write(_ buffer: AVAudioPCMBuffer) { try? file.write(from: buffer) }
}

/// RMS of a buffer's first channel in [0, 1]. Free function so it stays callable from the
/// non-isolated tap closure.
private func bufferRMS(_ buffer: AVAudioPCMBuffer) -> Float {
    guard let channel = buffer.floatChannelData, buffer.frameLength > 0 else { return 0 }
    let n = Int(buffer.frameLength)
    let p = channel[0]
    var sum: Float = 0
    for i in 0..<n { sum += p[i] * p[i] }
    return (sum / Float(n)).squareRoot()
}

/// Captures the default input device to a file via `AVAudioEngine`, reporting a live input level.
/// macOS has no `AVAudioSession`; the engine taps the hardware input directly. The first start
/// triggers the OS microphone-permission prompt (needs `NSMicrophoneUsageDescription` in Info.plist).
@MainActor
final class AudioRecorder {
    private let engine = AVAudioEngine()
    private var sink: RecordingSink?
    private(set) var isRecording = false

    /// The hardware input sample rate (≤ 0 if no input device is available).
    var inputSampleRate: Double { engine.inputNode.outputFormat(forBus: 0).sampleRate }
    var inputChannels: Int { Int(engine.inputNode.outputFormat(forBus: 0).channelCount) }

    /// Start capturing to `url`. `onLevel` is invoked on the main actor ~per buffer with RMS in [0,1].
    func start(writingTo url: URL, onLevel: @escaping @MainActor (Float) -> Void) throws {
        guard !isRecording else { return }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw NSError(domain: "BreathEnroll", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No usable microphone input device was found."])
        }
        let sink = try RecordingSink(url: url, format: format)
        self.sink = sink
        input.installTap(onBus: 0, bufferSize: 4_096, format: format) { buffer, _ in
            sink.write(buffer)
            let level = bufferRMS(buffer)
            Task { @MainActor in onLevel(level) }
        }
        engine.prepare()
        try engine.start()
        isRecording = true
    }

    func stop() {
        guard isRecording else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        sink = nil
        isRecording = false
    }
}
