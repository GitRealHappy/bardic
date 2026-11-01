import Foundation

/// Speech-to-text model choices (WhisperKit Core ML variants from `argmaxinc/whisperkit-coreml`).
public enum SpeechModel: String, CaseIterable, Identifiable, Sendable {
    case largeV3Turbo = "openai_whisper-large-v3-v20240930_turbo_632MB"
    case smallEnglish = "openai_whisper-small.en_217MB"
    case baseEnglish = "openai_whisper-base.en"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .largeV3Turbo: return "Whisper Large v3 Turbo (best, ~630 MB)"
        case .smallEnglish: return "Whisper Small, English (faster, ~220 MB)"
        case .baseEnglish: return "Whisper Base, English (fastest, ~150 MB)"
        }
    }
}

/// Local LLM choices for the cleanup pass (MLX 4-bit models from `mlx-community`).
public enum CleanupModel: String, CaseIterable, Identifiable, Sendable {
    case qwen25_3B = "mlx-community/Qwen2.5-3B-Instruct-4bit"
    case qwen25_1_5B = "mlx-community/Qwen2.5-1.5B-Instruct-4bit"
    case llama32_3B = "mlx-community/Llama-3.2-3B-Instruct-4bit"
    case qwen25_7B = "mlx-community/Qwen2.5-7B-Instruct-4bit"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .qwen25_3B: return "Qwen 2.5 3B (recommended, ~1.8 GB)"
        case .qwen25_1_5B: return "Qwen 2.5 1.5B (fastest, ~0.9 GB)"
        case .llama32_3B: return "Llama 3.2 3B (~1.8 GB)"
        case .qwen25_7B: return "Qwen 2.5 7B (best quality, ~4.3 GB, slower)"
        }
    }
}

public enum Paths {
    /// ~/Library/Application Support/WhiskrFlow
    public static var appSupport: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("WhiskrFlow", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    public static var speechModels: URL {
        let dir = appSupport.appendingPathComponent("SpeechModels", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
