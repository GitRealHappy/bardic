import AVFoundation
import Foundation

/// Captures microphone audio and converts it to 16 kHz mono Float32, the format Whisper expects.
public final class AudioRecorder {
    public static let sampleRate: Double = 16_000

    private let engine = AVAudioEngine()
    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: AudioRecorder.sampleRate, channels: 1, interleaved: false)!
    private var converter: AVAudioConverter?
    private let lock = NSLock()
    private var samples: [Float] = []

    /// Called on the audio thread with a 0...1 level, for the HUD meter.
    public var onLevel: ((Float) -> Void)?

    public private(set) var isRecording = false

    public init() {}

    public func start() throws {
        guard !isRecording else { return }
        lock.lock(); samples.removeAll(keepingCapacity: true); lock.unlock()

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw RecorderError.noInputDevice
        }
        converter = AVAudioConverter(from: inputFormat, to: targetFormat)

        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            self?.handle(buffer)
        }
        engine.prepare()
        try engine.start()
        isRecording = true
    }

    /// Stops recording and returns the captured 16 kHz mono samples.
    @discardableResult
    public func stop() -> [Float] {
        guard isRecording else { return [] }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRecording = false
        lock.lock(); defer { lock.unlock() }
        let out = samples
        samples.removeAll()
        return out
    }

    private func handle(_ buffer: AVAudioPCMBuffer) {
        guard let converter else { return }
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

        var consumed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let channel = out.floatChannelData?[0] else { return }
        let chunk = Array(UnsafeBufferPointer(start: channel, count: Int(out.frameLength)))

        lock.lock(); samples.append(contentsOf: chunk); lock.unlock()

        if let onLevel, !chunk.isEmpty {
            let rms = AudioRecorder.rms(chunk)
            // Map roughly -50 dB...0 dB to 0...1
            let db = 20 * log10(max(rms, 1e-6))
            onLevel(max(0, min(1, (db + 50) / 50)))
        }
    }

    public static func rms(_ x: [Float]) -> Float {
        guard !x.isEmpty else { return 0 }
        var sum: Float = 0
        for v in x { sum += v * v }
        return sqrt(sum / Float(x.count))
    }

    public static func peak(_ x: [Float]) -> Float {
        x.reduce(0) { max($0, abs($1)) }
    }

    /// Level in dBFS (0 = full scale), for logs.
    public static func dB(_ level: Float) -> Int {
        Int((20 * log10(max(level, 1e-6))).rounded())
    }

    /// Writes 16 kHz mono samples as a WAV file (debugging aid).
    public static func writeWAV(_ samples: [Float], to url: URL) throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1,
                                   interleaved: false)!
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))
        else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            buffer.floatChannelData![0].update(from: src.baseAddress!, count: samples.count)
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }

    public enum RecorderError: LocalizedError {
        case noInputDevice
        public var errorDescription: String? { "No microphone input device is available." }
    }
}
