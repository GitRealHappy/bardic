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

    /// Approximate download size, for the free-space check.
    public var approxBytes: Int64 {
        switch self {
        case .largeV3Turbo: return 630_000_000
        case .smallEnglish: return 220_000_000
        case .baseEnglish: return 150_000_000
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

    /// Approximate download size, for the free-space check.
    public var approxBytes: Int64 {
        switch self {
        case .qwen25_3B, .llama32_3B: return 1_800_000_000
        case .qwen25_1_5B: return 900_000_000
        case .qwen25_7B: return 4_300_000_000
        }
    }
}

/// True for errors caused by the network (offline, timeouts, DNS…), including ones wrapped by a library.
/// Those say nothing about whether the files on disk are damaged.
public func isNetworkError(_ error: Error) -> Bool {
    var current: NSError? = error as NSError
    while let e = current {
        if e.domain == NSURLErrorDomain { return true }
        current = e.userInfo[NSUnderlyingErrorKey] as? NSError
    }
    return false
}

public enum Paths {
    /// ~/Library/Application Support/Bardic
    public static let appSupport: URL = {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Bardic", isDirectory: true)
        // The app used to be called Whiskr Flow; move its downloaded models and history over.
        let legacy = base.appendingPathComponent("WhiskrFlow", isDirectory: true)
        if !fm.fileExists(atPath: dir.path), fm.fileExists(atPath: legacy.path) {
            try? fm.moveItem(at: legacy, to: dir)
        }
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    public static var speechModels: URL {
        let dir = appSupport.appendingPathComponent("SpeechModels", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Where mlx-swift-lm's Hugging Face client keeps a cleanup model: ~/Library/Caches/models/<repo id>.
    public static func cleanupModel(_ model: CleanupModel) -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("models/\(model.rawValue)", isDirectory: true)
    }

    /// Free space on the home volume that macOS will make available for important downloads.
    public static var freeDiskBytes: Int64? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let values = try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }
}
