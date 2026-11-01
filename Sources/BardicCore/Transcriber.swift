import Foundation
import WhisperKit

/// Speech-to-text using WhisperKit (Core ML / Apple Neural Engine). Runs fully on-device.
public actor Transcriber {
    private var whisper: WhisperKit?
    private var loadedModel: SpeechModel?

    public init() {}

    public var isLoaded: Bool { whisper != nil }

    /// Downloads (first run only) and loads the model. Later launches load from disk and work offline.
    public func load(_ model: SpeechModel, progress: (@Sendable (String) -> Void)? = nil) async throws {
        if loadedModel == model, whisper != nil { return }
        whisper = nil

        // Already downloaded? Load straight from disk so no network is needed.
        let localFolder = Paths.speechModels
            .appendingPathComponent("models/argmaxinc/whisperkit-coreml/\(model.rawValue)")
        let isDownloaded = FileManager.default.fileExists(
            atPath: localFolder.appendingPathComponent("AudioEncoder.mlmodelc").path)

        var config: WhisperKitConfig
        if isDownloaded {
            progress?("Loading speech model (first launch compiles for the Neural Engine, can take a few minutes)…")
            config = WhisperKitConfig(modelFolder: localFolder.path, tokenizerFolder: Paths.speechModels,
                                      verbose: false, logLevel: .error,
                                      prewarm: true, load: true, download: false)
        } else {
            progress?("Downloading speech model (first run)…")
            config = WhisperKitConfig(model: model.rawValue, downloadBase: Paths.speechModels,
                                      tokenizerFolder: Paths.speechModels,
                                      verbose: false, logLevel: .error,
                                      prewarm: true, load: true, download: true)
        }

        whisper = try await WhisperKit(config)
        loadedModel = model
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
