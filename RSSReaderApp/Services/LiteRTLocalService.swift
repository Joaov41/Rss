import Foundation

#if canImport(LiteRTFoundation)
import LiteRTFoundation

actor LiteRTLocalService {
    static let shared = LiteRTLocalService()

    static let defaultModelRepo = "litert-community/gemma-4-E2B-it-litert-lm"
    static let defaultModelFileName = "gemma-4-E2B-it.litertlm"
    static let defaultContextTokens = 2_048
    static let stableContextTokens = 4_096
    static let maxContextTokens = 8_192
    static let contextTooLargeDomain = "LiteRTLocalService.ContextTooLarge"

    private var chat: LiteRTChat?
    private var activeKey: String?
    private var inFlightLoad: Task<LiteRTChat, Error>?
    private var inFlightKey: String?
    private var runtimeMaxContextTokens = maxContextTokens

    struct BenchmarkSnapshot: Sendable {
        let timeToFirstToken: Double
        let prefillTokensPerSecond: Double
        let decodeTokensPerSecond: Double
        let prefillTokens: Int
        let decodeTokens: Int
    }

    func preloadModel(
        modelID: String,
        maxContextTokens: Int?,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws {
        _ = try await loadChat(modelID: modelID, maxContextTokens: maxContextTokens, onProgress: onProgress)
    }

    func unloadAllModels() {
        inFlightLoad?.cancel()
        inFlightLoad = nil
        inFlightKey = nil
        chat = nil
        activeKey = nil
    }

    func resetConversation() async throws {
        try await chat?.resetConversation()
    }

    func promptFits(
        _ prompt: String,
        maxOutputTokens: Int,
        maxContextTokens configuredContextTokens: Int?
    ) -> Bool {
        let contextBudget = resolvedContextTokens(configuredContextTokens)
        return estimatedTokenCount(for: prompt) + max(1, maxOutputTokens) <= contextBudget
    }

    func generateTextStreaming(
        prompt: String,
        modelID: String,
        maxOutputTokens: Int,
        maxContextTokens configuredContextTokens: Int?,
        onToken: @Sendable @escaping (String) -> Void
    ) async throws -> String {
        let requestedContextBudget = resolvedContextTokens(configuredContextTokens)
        let promptTokens = estimatedTokenCount(for: prompt)
        let outputBudget = max(1, maxOutputTokens)
        guard promptTokens + outputBudget <= requestedContextBudget else {
            throw Self.contextTooLargeError(promptTokens: promptTokens, outputTokens: outputBudget, contextTokens: requestedContextBudget)
        }

        let loaded = try await loadChat(modelID: modelID, maxContextTokens: requestedContextBudget)
        guard promptTokens + outputBudget <= loaded.contextTokens else {
            throw Self.contextTooLargeError(promptTokens: promptTokens, outputTokens: outputBudget, contextTokens: loaded.contextTokens)
        }
        let activeChat = loaded.chat
        try await activeChat.resetConversation()

        var output = ""
        var generatedTokens = 0
        let generationPrompt = """
        \(prompt)

        Keep the answer within \(outputBudget) tokens.
        """

        for try await delta in activeChat.stream(generationPrompt) {
            if Task.isCancelled { throw CancellationError() }
            let filtered = sanitize(delta)
            guard !filtered.isEmpty else { continue }
            output += filtered
            generatedTokens += max(1, estimatedTokenCount(for: filtered))
            onToken(filtered)
            if generatedTokens >= outputBudget {
                try? activeChat.cancel()
                break
            }
        }

        return sanitize(output)
    }

    func lastBenchmark() -> BenchmarkSnapshot? {
        guard let chat else { return nil }
        do {
            let benchmark = try chat.lastBenchmark()
            return BenchmarkSnapshot(
                timeToFirstToken: benchmark.timeToFirstTokenInSecond,
                prefillTokensPerSecond: benchmark.lastPrefillTokensPerSecond,
                decodeTokensPerSecond: benchmark.lastDecodeTokensPerSecond,
                prefillTokens: benchmark.lastPrefillTokenCount,
                decodeTokens: benchmark.lastDecodeTokenCount
            )
        } catch {
            return nil
        }
    }

    private func loadChat(
        modelID: String,
        maxContextTokens configuredContextTokens: Int?,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> LoadedChat {
        let normalized = Self.normalizedModelID(modelID)
        let contextTokens = resolvedContextTokens(configuredContextTokens)
        let key = "\(normalized)|ctx:\(contextTokens)"

        if let chat, activeKey == key {
            return LoadedChat(chat: chat, contextTokens: contextTokens)
        }

        if let inFlightLoad, inFlightKey == key {
            return LoadedChat(chat: try await inFlightLoad.value, contextTokens: contextTokens)
        }

        let task = Task<LiteRTChat, Error> {
            let sampler = try SamplerConfig(topK: 40, topP: 0.95, temperature: 0.2)
            return try await Self.createChat(
                normalizedModelID: normalized,
                contextTokens: contextTokens,
                sampler: sampler,
                onProgress: onProgress
            )
        }

        inFlightLoad = task
        inFlightKey = key
        do {
            let loaded = try await task.value
            chat = loaded
            activeKey = key
            inFlightLoad = nil
            inFlightKey = nil
            return LoadedChat(chat: loaded, contextTokens: contextTokens)
        } catch {
            inFlightLoad = nil
            inFlightKey = nil
            guard contextTokens > Self.stableContextTokens, Self.isEngineCreationFailure(error) else {
                throw error
            }

            print("⚠️ [LiteRT] Engine rejected \(contextTokens) context tokens. Falling back to \(Self.stableContextTokens).")
            runtimeMaxContextTokens = Self.stableContextTokens
            let fallbackContextTokens = resolvedContextTokens(Self.stableContextTokens)
            let fallbackKey = "\(normalized)|ctx:\(fallbackContextTokens)"

            if let chat, activeKey == fallbackKey {
                return LoadedChat(chat: chat, contextTokens: fallbackContextTokens)
            }

            let sampler = try SamplerConfig(topK: 40, topP: 0.95, temperature: 0.2)
            let loaded = try await Self.createChat(
                normalizedModelID: normalized,
                contextTokens: fallbackContextTokens,
                sampler: sampler,
                onProgress: onProgress
            )
            chat = loaded
            activeKey = fallbackKey
            return LoadedChat(chat: loaded, contextTokens: fallbackContextTokens)
        }
    }

    private struct LoadedChat {
        let chat: LiteRTChat
        let contextTokens: Int
    }

    private static func createChat(
        normalizedModelID: String,
        contextTokens: Int,
        sampler: SamplerConfig,
        onProgress: (@Sendable (Double) -> Void)?
    ) async throws -> LiteRTChat {
        if normalizedModelID.hasPrefix("external:") {
            let url = try resolveExternalModelURL()
            return try await LiteRTChat(
                modelFileURL: url,
                modalities: [],
                maxTokens: contextTokens,
                minimumDeviceRAM: 7_000_000_000,
                enableBenchmark: true,
                sampler: sampler,
                prewarm: true
            )
        }

        return try await LiteRTChat(
            huggingFaceRepo: normalizedModelID,
            fileName: defaultModelFileName,
            modalities: [],
            maxTokens: contextTokens,
            minimumDeviceRAM: 7_000_000_000,
            enableBenchmark: true,
            sampler: sampler,
            prewarm: true,
            onDownloadProgress: { progress in
                onProgress?(progress.fraction)
            }
        )
    }

    private static func isEngineCreationFailure(_ error: Error) -> Bool {
        if case LiteRTLMError.engine(.failedToCreateEngine) = error {
            return true
        }
        return error.localizedDescription.localizedCaseInsensitiveContains("failed to create engine")
    }

    private func resolvedContextTokens(_ configured: Int?) -> Int {
        guard let configured, configured > 0 else {
            return Self.defaultContextTokens
        }
        return min(max(512, configured), runtimeMaxContextTokens)
    }

    private func estimatedTokenCount(for text: String) -> Int {
        max(1, Int(ceil(Double(text.count) / 4.0)))
    }

    private func sanitize(_ text: String) -> String {
        let stopTokens = [
            "<end_of_turn>",
            "</s>",
            "<|end_of_text|>",
            "<|eot_id|>",
            "<|im_end|>",
        ]
        var cleaned = text
        for token in stopTokens {
            cleaned = cleaned.replacingOccurrences(of: token, with: "")
        }
        return cleaned
    }

    static func normalizedModelID(_ modelID: String) -> String {
        let trimmed = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return defaultModelRepo }
        if trimmed.hasPrefix("external:") { return defaultModelRepo }
        if trimmed.hasPrefix("mlx-community/") { return defaultModelRepo }
        return trimmed
    }

    static func contextTooLargeError(promptTokens: Int, outputTokens: Int, contextTokens: Int) -> NSError {
        NSError(
            domain: contextTooLargeDomain,
            code: 413,
            userInfo: [
                NSLocalizedDescriptionKey: "LiteRT local context is too small for this request (\(promptTokens + outputTokens) estimated tokens needed, \(contextTokens) available). Choose Gemini, Apple PCC Gateway, Codex/Summarize, Apple Cloud, or Web AI for this large batch."
            ]
        )
    }

    static func isContextTooLargeError(_ error: Error) -> Bool {
        (error as NSError).domain == contextTooLargeDomain
    }

    private static func resolveExternalModelURL() throws -> URL {
        let bookmarkKey = "MLXExternalModelBookmark"
        guard let bookmarkData = UserDefaults.standard.data(forKey: bookmarkKey) else {
            throw NSError(
                domain: "LiteRTBookmark",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "External LiteRT model bookmark not found. Reselect the .litertlm model file in Settings."]
            )
        }

        var isStale = false
        #if os(iOS)
        let url = try URL(resolvingBookmarkData: bookmarkData, options: [], relativeTo: nil, bookmarkDataIsStale: &isStale)
        #else
        let url = try URL(resolvingBookmarkData: bookmarkData, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale)
        #endif
        guard !isStale else {
            throw NSError(
                domain: "LiteRTBookmark",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "External LiteRT model bookmark is stale. Reselect the .litertlm model file in Settings."]
            )
        }
        if url.pathExtension == "litertlm" {
            return url
        }
        if let file = try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).first(where: { $0.pathExtension == "litertlm" }) {
            return file
        }
        throw NSError(
            domain: "LiteRTBookmark",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: "Selected model must be a .litertlm file or a folder containing one."]
        )
    }
}
#else
actor LiteRTLocalService {
    static let shared = LiteRTLocalService()

    static let defaultModelRepo = "litert-community/gemma-4-E2B-it-litert-lm"
    static let defaultModelFileName = "gemma-4-E2B-it.litertlm"
    static let defaultContextTokens = 2_048
    static let maxContextTokens = 8_192
    static let contextTooLargeDomain = "LiteRTLocalService.ContextTooLarge"

    struct BenchmarkSnapshot: Sendable {
        let timeToFirstToken: Double
        let prefillTokensPerSecond: Double
        let decodeTokensPerSecond: Double
        let prefillTokens: Int
        let decodeTokens: Int
    }

    func preloadModel(modelID: String, maxContextTokens: Int?, onProgress: (@Sendable (Double) -> Void)? = nil) async throws {
        throw unavailableError()
    }

    func unloadAllModels() { }

    func resetConversation() async throws { }

    func promptFits(_ prompt: String, maxOutputTokens: Int, maxContextTokens configuredContextTokens: Int?) -> Bool {
        let contextBudget = configuredContextTokens.map { min(max(512, $0), Self.maxContextTokens) } ?? Self.defaultContextTokens
        return max(1, Int(ceil(Double(prompt.count) / 4.0))) + max(1, maxOutputTokens) <= contextBudget
    }

    func generateTextStreaming(
        prompt: String,
        modelID: String,
        maxOutputTokens: Int,
        maxContextTokens: Int?,
        onToken: @Sendable @escaping (String) -> Void
    ) async throws -> String {
        throw unavailableError()
    }

    func lastBenchmark() -> BenchmarkSnapshot? { nil }

    static func normalizedModelID(_ modelID: String) -> String {
        let trimmed = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return defaultModelRepo }
        if trimmed.hasPrefix("external:") { return defaultModelRepo }
        if trimmed.hasPrefix("mlx-community/") { return defaultModelRepo }
        return trimmed
    }

    static func contextTooLargeError(promptTokens: Int, outputTokens: Int, contextTokens: Int) -> NSError {
        NSError(
            domain: contextTooLargeDomain,
            code: 413,
            userInfo: [NSLocalizedDescriptionKey: "LiteRT local context is too small for this request."]
        )
    }

    static func isContextTooLargeError(_ error: Error) -> Bool {
        (error as NSError).domain == contextTooLargeDomain
    }

    private func unavailableError() -> NSError {
        NSError(
            domain: "LiteRTLocalService",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "LiteRT Local is unavailable in this build (missing LiteRTFoundation package)."]
        )
    }
}
#endif
