import Foundation

struct MLXGenerationMetrics: Sendable {
    let text: String
    let tokenCount: Int
    let elapsed: TimeInterval

    var tokensPerSecond: Double {
        elapsed > 0 ? Double(tokenCount) / elapsed : 0
    }
}

private final class LocalLLMTokenCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func record(_ text: String) {
        let estimated = max(1, Int(ceil(Double(text.count) / 4.0)))
        lock.lock()
        count += estimated
        lock.unlock()
    }

    var tokenCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

extension LiteRTLocalService {
    static func normalizedModelIdentifier(from raw: String) -> String {
        normalizedModelID(raw)
    }

    static func isAvailable() -> Bool {
        #if canImport(LiteRTFoundation)
        return true
        #else
        return false
        #endif
    }

    func preloadConfiguredModel(
        modelID: String,
        maxContextTokens: Int?,
        progressHandler: @Sendable @escaping (Progress) -> Void = { _ in }
    ) async throws {
        let progress = Progress(totalUnitCount: 100)
        try await preloadModel(
            modelID: modelID,
            maxContextTokens: maxContextTokens,
            onProgress: { fraction in
                progress.completedUnitCount = Int64(max(0, min(1, fraction)) * 100)
                progressHandler(progress)
            }
        )
    }

    func warmUpConfiguredModel(modelID: String, maxContextTokens: Int?) async throws {
        _ = try await generateText(
            prompt: "Hi",
            modelID: modelID,
            maxOutputTokens: 1,
            maxContextTokens: maxContextTokens
        )
    }

    func clearTransientCache() async {
        // LiteRT keeps the loaded chat warm; no transient cache to clear.
    }

    func generateText(
        prompt: String,
        systemPrompt: String? = nil,
        modelID: String,
        maxOutputTokens: Int,
        maxContextTokens: Int?,
        onToken: (@Sendable (String) async -> Void)? = nil
    ) async throws -> String {
        try await generateTextWithMetrics(
            prompt: prompt,
            systemPrompt: systemPrompt,
            modelID: modelID,
            maxOutputTokens: maxOutputTokens,
            maxContextTokens: maxContextTokens,
            onToken: onToken
        ).text
    }

    func generateTextWithMetrics(
        prompt: String,
        systemPrompt: String? = nil,
        modelID: String,
        maxOutputTokens: Int,
        maxContextTokens: Int?,
        onToken: (@Sendable (String) async -> Void)? = nil
    ) async throws -> MLXGenerationMetrics {
        let effectivePrompt: String
        if let systemPrompt, !systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            effectivePrompt = "\(systemPrompt)\n\n\(prompt)"
        } else {
            effectivePrompt = prompt
        }

        let start = Date()
        let counter = LocalLLMTokenCounter()
        let text = try await generateTextStreaming(
            prompt: effectivePrompt,
            modelID: modelID,
            maxOutputTokens: maxOutputTokens,
            maxContextTokens: maxContextTokens,
            onToken: { token in
                counter.record(token)
                if let onToken {
                    Task { await onToken(token) }
                }
            }
        )

        let benchmark = lastBenchmark()
        let tokenCount = benchmark?.decodeTokens ?? max(counter.tokenCount, max(1, Int(ceil(Double(text.count) / 4.0))))
        let elapsed: TimeInterval
        if let benchmark, benchmark.decodeTokensPerSecond > 0, benchmark.decodeTokens > 0 {
            elapsed = Double(benchmark.decodeTokens) / benchmark.decodeTokensPerSecond
        } else {
            elapsed = Date().timeIntervalSince(start)
        }

        return MLXGenerationMetrics(text: text, tokenCount: tokenCount, elapsed: elapsed)
    }
}

extension CoreAIMLXLocalService {
    static func normalizedModelIdentifier(from raw: String) -> String {
        normalizedModelID(raw)
    }

    static func isAvailable() -> Bool {
        MLXLocalService.isAvailable()
    }

    func preloadConfiguredModel(
        modelID: String,
        progressHandler: @Sendable @escaping (Progress) -> Void = { _ in }
    ) async throws {
        try await preloadModel(modelID: modelID, onProgress: progressHandler)
    }

    func warmUpConfiguredModel(modelID: String, maxContextTokens: Int?) async throws {
        _ = try await generateText(
            prompt: "Hi",
            modelID: modelID,
            maxOutputTokens: 1,
            maxContextTokens: maxContextTokens
        )
    }

    func clearTransientCache() async {
        // CoreAI MLX uses MLXLocalService internally; no extra transient cache here.
    }

    func generateText(
        prompt: String,
        systemPrompt: String? = nil,
        modelID: String,
        maxOutputTokens: Int,
        maxContextTokens: Int?,
        onToken: (@Sendable (String) async -> Void)? = nil
    ) async throws -> String {
        try await generateTextWithMetrics(
            prompt: prompt,
            systemPrompt: systemPrompt,
            modelID: modelID,
            maxOutputTokens: maxOutputTokens,
            maxContextTokens: maxContextTokens,
            onToken: onToken
        ).text
    }

    func generateTextWithMetrics(
        prompt: String,
        systemPrompt: String? = nil,
        modelID: String,
        maxOutputTokens: Int,
        maxContextTokens: Int?,
        onToken: (@Sendable (String) async -> Void)? = nil
    ) async throws -> MLXGenerationMetrics {
        let effectivePrompt: String
        if let systemPrompt, !systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            effectivePrompt = "\(systemPrompt)\n\n\(prompt)"
        } else {
            effectivePrompt = prompt
        }

        let start = Date()
        let counter = LocalLLMTokenCounter()
        let text = try await generateTextStreaming(
            prompt: effectivePrompt,
            modelID: modelID,
            maxOutputTokens: maxOutputTokens,
            maxContextTokens: maxContextTokens,
            onToken: { token in
                counter.record(token)
                if let onToken {
                    Task { await onToken(token) }
                }
            }
        )

        let benchmark = lastBenchmark()
        let tokenCount = benchmark?.decodeTokens ?? max(counter.tokenCount, max(1, Int(ceil(Double(text.count) / 4.0))))
        let elapsed: TimeInterval
        if let benchmark, benchmark.decodeTokensPerSecond > 0, benchmark.decodeTokens > 0 {
            elapsed = Double(benchmark.decodeTokens) / benchmark.decodeTokensPerSecond
        } else {
            elapsed = Date().timeIntervalSince(start)
        }

        return MLXGenerationMetrics(text: text, tokenCount: tokenCount, elapsed: elapsed)
    }
}
