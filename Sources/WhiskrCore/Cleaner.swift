import Foundation
import MLX
import MLXLLM
import MLXLMCommon

/// On-device LLM that turns a raw transcript into the text the speaker meant (MLX on the GPU).
///
/// The system prompt and few-shot examples (~700 tokens) are identical on every call, so their
/// KV cache is prefilled once at load. Each request copies that cache and only prefills its own
/// short suffix, which cuts cleanup latency from ~1.5 s to a few hundred ms.
public actor Cleaner {
    private var container: ModelContainer?
    private var loadedModel: CleanupModel?

    /// Token IDs of the shared prompt prefix, and the KV cache holding exactly those tokens.
    private var prefixTokens: [Int] = []
    private var prefixCache: [KVCache]?

    /// Set to false to prefill the whole prompt every time (for A/B testing the cache).
    private var usePromptCache: Bool

    public init(usePromptCache: Bool = true) {
        self.usePromptCache = usePromptCache
    }

    public var isLoaded: Bool { container != nil }

    public func load(_ model: CleanupModel, progress: (@Sendable (String) -> Void)? = nil) async throws {
        if loadedModel == model, container != nil { return }
        container = nil
        prefixCache = nil
        prefixTokens = []
        Memory.cacheLimit = 32 * 1024 * 1024

        progress?("Loading language model…")
        let configuration = LLMModelFactory.shared.configuration(id: model.rawValue)
        container = try await LLMModelFactory.shared.loadContainer(configuration: configuration) { p in
            if p.fractionCompleted < 1 {
                progress?("Downloading language model… \(Int(p.fractionCompleted * 100))%")
            }
        }
        loadedModel = model
        try await buildPrefixCache()
        // Warm up the generation path so the first real dictation isn't slow.
        _ = try? await clean("hello there", style: .standard, vocabulary: [])
    }

    /// Returns the cleaned text, or the raw transcript if the model output fails validation.
    public func clean(_ raw: String, style: DictationStyle, vocabulary: [String]) async throws -> CleanResult {
        guard container != nil else { throw CleanerError.notLoaded }
        let messages = CleanupPrompt.messages(raw: raw, style: style, vocabulary: vocabulary)
        let maxTokens = CleanupPrompt.wordCount(raw) * 3 + 64
        let output = try await generate(messages, maxTokens: maxTokens)
        if let valid = CleanupPrompt.validate(output: output, raw: raw) {
            return CleanResult(text: valid, usedLLM: true, rejectedOutput: nil)
        }
        return CleanResult(text: raw, usedLLM: false, rejectedOutput: output)
    }

    // MARK: - Prompt prefix cache

    private func tokens(for messages: [CleanupPrompt.Message]) async throws -> [Int] {
        guard let container else { throw CleanerError.notLoaded }
        let input = try await container.prepare(input: UserInput(chat: messages.map(\.chat)))
        return input.text.tokens.asArray(Int32.self).map(Int.init)
    }

    /// Finds the token prefix shared by every request (system prompt + examples + the start of the
    /// final user turn) by tokenizing two different requests, then prefills it into a KV cache.
    private func buildPrefixCache() async throws {
        guard let container else { return }
        let a = try await tokens(for: CleanupPrompt.messages(raw: "alpha", style: .standard, vocabulary: []))
        let b = try await tokens(for: CleanupPrompt.messages(raw: "zulu yankee", style: .code, vocabulary: ["Xylo"]))
        var common = 0
        while common < min(a.count, b.count), a[common] == b[common] { common += 1 }
        // Back off a couple of tokens so BPE merges at the boundary can't differ between requests.
        let length = common - 2
        guard length > 16 else { return }
        let prefix = Array(a[..<length])

        let cache: [KVCache] = try await container.perform { context in
            let cache = context.model.newCache(parameters: nil)
            let input = LMInput(tokens: MLXArray(prefix))
            // Creating the iterator runs the prefill, which writes the prefix into `cache`.
            _ = try TokenIterator(input: input, model: context.model, cache: cache,
                                  parameters: GenerateParameters(maxTokens: 1, temperature: 0))
            eval(cache.flatMap(\.state))
            return cache
        }
        prefixTokens = prefix
        prefixCache = cache
    }

    // MARK: - Generation

    private func generate(_ messages: [CleanupPrompt.Message], maxTokens: Int) async throws -> String {
        guard let container else { throw CleanerError.notLoaded }
        let all = try await tokens(for: messages)
        let params = GenerateParameters(maxTokens: maxTokens, temperature: 0)

        // Reuse the cached prefix when this request starts with it; otherwise prefill everything.
        let canReuse = usePromptCache && prefixCache != nil
            && all.count > prefixTokens.count && all.starts(with: prefixTokens)
        let cache: [KVCache]? = canReuse ? prefixCache?.map { $0.copy() } : nil
        let feed = canReuse ? Array(all[prefixTokens.count...]) : all
        let input = LMInput(tokens: MLXArray(feed))

        return try await container.perform { context in
            var text = ""
            for await event in try MLXLMCommon.generate(input: input, cache: cache, parameters: params, context: context) {
                if case .chunk(let s) = event { text += s }
            }
            return text
        }
    }

    public struct CleanResult: Sendable {
        public let text: String
        public let usedLLM: Bool
        /// The model output that failed validation, for debugging.
        public let rejectedOutput: String?
    }

    public enum CleanerError: LocalizedError {
        case notLoaded
        public var errorDescription: String? { "Language model is not loaded yet." }
    }
}

private extension CleanupPrompt.Message {
    var chat: Chat.Message {
        switch role {
        case .system: return .system(content)
        case .user: return .user(content)
        case .assistant: return .assistant(content)
        }
    }
}
