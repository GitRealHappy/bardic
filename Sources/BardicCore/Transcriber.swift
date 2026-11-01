import Foundation
import WhisperKit

/// Speech-to-text using WhisperKit (Core ML / Apple Neural Engine). Runs fully on-device.
public actor Transcriber {
    private var whisper: WhisperKit?
    private var loadedModel: SpeechModel?

    public init() {}

    public var isLoaded: Bool { whisper != nil }

    /// Where WhisperKit keeps a downloaded model.
    static func folder(for model: SpeechModel) -> URL {
        Paths.speechModels.appendingPathComponent("models/argmaxinc/whisperkit-coreml/\(model.rawValue)")
    }

    /// True when every part of the model is on disk. An interrupted download can leave some of them
    /// missing, which a check for a single file wouldn't notice.
    public static func isDownloaded(_ model: SpeechModel) -> Bool {
        let folder = folder(for: model)
        return ["AudioEncoder.mlmodelc", "TextDecoder.mlmodelc", "MelSpectrogram.mlmodelc", "config.json"]
            .allSatisfy { FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path) }
    }

    /// Downloads (first run only) and loads the model. Later launches load from disk and work offline.
    public func load(_ model: SpeechModel, progress: (@Sendable (String) -> Void)? = nil) async throws {
        if loadedModel == model, whisper != nil { return }
        whisper = nil
        loadedModel = nil

        var folder = Self.folder(for: model)
        var freshDownload = false
        if !Self.isDownloaded(model) {
            folder = try await download(model, progress: progress)
            freshDownload = true
        }

        do {
            whisper = try await Self.loadFromDisk(folder, progress: progress)
        } catch where !freshDownload && !isNetworkError(error) {
            // A model that's on disk but won't load is most likely damaged: fetch it again, once.
            // Network errors (e.g. the tokenizer fetch while offline) leave the files alone.
            try? FileManager.default.removeItem(at: folder)
            folder = try await download(model, progress: progress)
            whisper = try await Self.loadFromDisk(folder, progress: progress)
        }
        loadedModel = model
    }

    private func download(_ model: SpeechModel, progress: (@Sendable (String) -> Void)?) async throws -> URL {
        progress?("Downloading speech model…")
        let lastPercent = Counter()
        do {
            return try await WhisperKit.download(variant: model.rawValue, downloadBase: Paths.speechModels) { p in
                let percent = Int(p.fractionCompleted * 100)
                if lastPercent.exchange(percent) != percent, percent < 100 {
                    progress?("Downloading speech model… \(percent)%")
                }
            }
        } catch {
            // Don't leave a half-finished model behind for the next launch to trip over.
            try? FileManager.default.removeItem(at: Self.folder(for: model))
            throw error
        }
    }

    private static func loadFromDisk(_ folder: URL, progress: (@Sendable (String) -> Void)?) async throws -> WhisperKit {
        progress?("Loading speech model (the first time, preparing it for this Mac takes up to 10 minutes)…")
        let config = WhisperKitConfig(modelFolder: folder.path, tokenizerFolder: Paths.speechModels,
                                      verbose: false, logLevel: .error,
                                      prewarm: true, load: true, download: false)
        return try await WhisperKit(config)
    }

    /// Transcribes 16 kHz mono samples. `vocabulary` biases recognition toward names/jargon.
    public func transcribe(_ samples: [Float], language: String? = "en", vocabulary: [String] = []) async throws -> String {
        guard let whisper else { throw TranscriberError.notLoaded }

        var options = DecodingOptions(
            task: .transcribe,
            language: language,
            temperature: 0,
            usePrefillPrompt: true,
            skipSpecialTokens: true,
            withoutTimestamps: true,
            chunkingStrategy: .vad
        )
        if !vocabulary.isEmpty, let tokenizer = whisper.tokenizer {
            let prompt = " " + vocabulary.joined(separator: ", ") + "."
            options.promptTokens = tokenizer.encode(text: prompt)
                .filter { $0 < tokenizer.specialTokens.specialTokenBegin }
        }

        let results = try await whisper.transcribe(audioArray: samples, decodeOptions: options)
        let text = results.map(\.text).joined(separator: " ")
        return Transcriber.stripArtifacts(text)
    }

    /// Removes Whisper's bracketed non-speech tags like "[BLANK_AUDIO]" or "(music)".
    static func stripArtifacts(_ text: String) -> String {
        var t = text.replacingOccurrences(of: #"\[[^\]]*\]"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\((?:music|applause|laughter|silence|inaudible)[^)]*\)"#,
                                   with: "", options: [.regularExpression, .caseInsensitive])
        t = t.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public enum TranscriberError: LocalizedError {
        case notLoaded
        public var errorDescription: String? { "Speech model is not loaded yet." }
    }
}

/// Remembers the last progress percentage across download callbacks, which can arrive on any thread.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = -1

    /// Stores `new` and returns the previous value.
    func exchange(_ new: Int) -> Int {
        lock.lock(); defer { lock.unlock() }
        let old = value
        value = new
        return old
    }
}
