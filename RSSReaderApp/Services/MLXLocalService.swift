import Foundation

#if canImport(MLX) && canImport(MLXLLM) && canImport(MLXLMCommon)
import MLX
import MLXLLM
import MLXLMCommon
import HuggingFace
import Tokenizers
#if canImport(MLXVLM)
import MLXVLM
#endif

// MARK: - RSS app compatibility surface

private final class RSSMLXTokenCounter: @unchecked Sendable {
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

extension MLXLocalService {
    static func normalizedModelIdentifier(from raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return CoreAIMLXLocalService.defaultModelRepo }
        return CoreAIMLXLocalService.normalizedModelID(trimmed)
    }

    static func isAvailable() -> Bool {
        #if canImport(MLX) && canImport(MLXLLM) && canImport(MLXLMCommon)
        return true
        #else
        return false
        #endif
    }

    func preloadConfiguredModel(
        modelID: String,
        progressHandler: @Sendable @escaping (Progress) -> Void = { _ in }
    ) async throws {
        let normalized = Self.normalizedModelIdentifier(from: modelID)
        if normalized.lowercased().hasPrefix("external:") {
            let directory = URL(fileURLWithPath: String(normalized.dropFirst("external:".count)))
            try await preloadModelFromDirectory(directory)
        } else {
            try await preloadModel(modelID: normalized, progressHandler: progressHandler)
        }
    }

    func warmUpConfiguredModel(
        modelID: String,
        maxContextTokens: Int?,
        progressHandler: @Sendable @escaping (Progress) -> Void = { _ in }
    ) async throws {
        let normalized = Self.normalizedModelIdentifier(from: modelID)
        _ = try await generateText(
            prompt: "Hi",
            modelID: normalized,
            maxOutputTokens: 1,
            maxContextTokens: maxContextTokens
        )
    }

    func generateText(
        prompt: String,
        systemPrompt: String?,
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
        let normalized = Self.normalizedModelIdentifier(from: modelID)
        let effectivePrompt: String
        if let systemPrompt, !systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            effectivePrompt = """
            \(systemPrompt)

            \(prompt)
            """
        } else {
            effectivePrompt = prompt
        }

        let start = Date()
        let counter = RSSMLXTokenCounter()
        let text: String
        if normalized.lowercased().hasPrefix("external:") {
            let directory = URL(fileURLWithPath: String(normalized.dropFirst("external:".count)))
            text = try await generateTextStreaming(
                prompt: effectivePrompt,
                modelDirectory: directory,
                maxOutputTokens: maxOutputTokens,
                maxContextTokens: maxContextTokens,
                onToken: { token in
                    counter.record(token)
                    if let onToken {
                        Task { await onToken(token) }
                    }
                }
            )
        } else {
            text = try await generateTextStreaming(
                prompt: effectivePrompt,
                modelID: normalized,
                maxOutputTokens: maxOutputTokens,
                maxContextTokens: maxContextTokens,
                onToken: { token in
                    counter.record(token)
                    if let onToken {
                        Task { await onToken(token) }
                    }
                }
            )
        }

        return MLXGenerationMetrics(
            text: text,
            tokenCount: max(counter.tokenCount, max(1, Int(ceil(Double(text.count) / 4.0)))),
            elapsed: Date().timeIntervalSince(start)
        )
    }

    func isGemma4ExternalModel(modelID: String) async -> Bool {
        let normalized = Self.normalizedModelIdentifier(from: modelID).lowercased()
        if normalized.contains("gemma-4") || normalized.contains("gemma4") {
            return true
        }
        guard normalized.hasPrefix("external:") else { return false }
        let path = String(normalized.dropFirst("external:".count))
        let configURL = URL(fileURLWithPath: path).appending(path: "config.json")
        guard let data = try? Data(contentsOf: configURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let modelType = object["model_type"] as? String
        else { return false }
        return modelType.lowercased().contains("gemma4") || modelType.lowercased().contains("gemma-4")
    }
}

private struct HuggingFaceDownloadBridge: MLXLMCommon.Downloader {
    private final class DirectFileDownloadDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private let progress: Progress
        private let fileHandle: FileHandle
        private let expectedSize: Int64
        private let lock = NSLock()
        private var receivedBytes: Int64 = 0
        private var continuation: CheckedContinuation<Void, Error>?

        init(progress: Progress, fileHandle: FileHandle, expectedSize: Int64) {
            self.progress = progress
            self.fileHandle = fileHandle
            self.expectedSize = expectedSize
        }

        func setContinuation(_ continuation: CheckedContinuation<Void, Error>) {
            lock.lock()
            self.continuation = continuation
            lock.unlock()
        }

        func urlSession(
            _ session: URLSession,
            dataTask: URLSessionDataTask,
            didReceive response: URLResponse,
            completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
        ) {
            let total = response.expectedContentLength > 0 ? response.expectedContentLength : expectedSize
            progress.totalUnitCount = max(total, 1)
            completionHandler(.allow)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            do {
                try fileHandle.write(contentsOf: data)
                lock.lock()
                receivedBytes += Int64(data.count)
                let received = receivedBytes
                lock.unlock()
                progress.completedUnitCount = received
            } catch {
                dataTask.cancel()
                resume(with: .failure(error))
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            do {
                try fileHandle.close()
            } catch {
                resume(with: .failure(error))
                return
            }

            if let error {
                resume(with: .failure(error))
            } else {
                progress.completedUnitCount = progress.totalUnitCount
                resume(with: .success(()))
            }
        }

        private func resume(with result: Result<Void, Error>) {
            lock.lock()
            let continuation = continuation
            self.continuation = nil
            lock.unlock()

            switch result {
            case .success:
                continuation?.resume()
            case .failure(let error):
                continuation?.resume(throwing: error)
            }
        }
    }

    private final class DownloadCompletion: @unchecked Sendable {
        private let lock = NSLock()
        private var finished = false

        func markFinished() {
            lock.lock()
            finished = true
            lock.unlock()
        }

        var isFinished: Bool {
            lock.lock()
            defer { lock.unlock() }
            return finished
        }
    }

    private let client: HuggingFace.HubClient
    private let downloadBase: URL
    private let progressPollInterval: UInt64 = 250_000_000

    init(
        client: HuggingFace.HubClient = .default,
        downloadBase: URL
    ) {
        self.client = client
        self.downloadBase = downloadBase
    }

    func download(
        id: String,
        revision: String?,
        matching patterns: [String],
        useLatest: Bool,
        progressHandler: @Sendable @escaping (Progress) -> Void
    ) async throws -> URL {
        guard let repoID = HuggingFace.Repo.ID(rawValue: id) else {
            throw NSError(
                domain: "MLXLocalService",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Invalid Hugging Face repository id: \(id)"]
            )
        }

        let resolvedRevision = revision ?? "main"
        let safeID = id.replacingOccurrences(of: "/", with: "--")
        let destination = downloadBase
            .appendingPathComponent("models--\(safeID)", isDirectory: true)
            .appendingPathComponent(resolvedRevision, isDirectory: true)
        try FileManager.default.createDirectory(
            at: destination,
            withIntermediateDirectories: true
        )

        let entries = try await client.listFiles(
            in: repoID,
            revision: resolvedRevision,
            recursive: true
        )
        .filter { entry in
            entry.type == .file && matches(entry.path, patterns: patterns)
        }

        let byteSized = entries.allSatisfy { ($0.size ?? 0) > 0 }
        let totalUnitCount = byteSized
            ? entries.reduce(Int64(0)) { $0 + Int64($1.size ?? 0) }
            : Int64(max(entries.count, 1))
        var completedBeforeCurrentFile: Int64 = 0
        progressHandler(Self.snapshotProgress(total: totalUnitCount, completed: 0))

        for entry in entries {
            if Task.isCancelled { return destination }

            let fileTotal = byteSized ? Int64(entry.size ?? 0) : 1
            let fileProgress = Progress(totalUnitCount: max(fileTotal, 1))
            let fileDestination = destination.appendingPathComponent(entry.path)
            let completion = DownloadCompletion()
            let downloadTask = Task {
                defer { completion.markFinished() }
                try await downloadFileDirectly(
                    entry,
                    repoID: repoID,
                    revision: resolvedRevision,
                    to: fileDestination,
                    progress: fileProgress
                )
            }

            while !completion.isFinished {
                if Task.isCancelled {
                    downloadTask.cancel()
                    break
                }
                let completed = completedBeforeCurrentFile
                    + min(max(fileProgress.completedUnitCount, 0), max(fileProgress.totalUnitCount, fileTotal))
                progressHandler(Self.snapshotProgress(total: totalUnitCount, completed: completed))
                try await Task.sleep(nanoseconds: progressPollInterval)
            }

            _ = try await downloadTask.value
            completedBeforeCurrentFile += fileTotal
            progressHandler(Self.snapshotProgress(total: totalUnitCount, completed: completedBeforeCurrentFile))
        }

        return destination
    }

    private func downloadFileDirectly(
        _ entry: HuggingFace.Git.TreeEntry,
        repoID: HuggingFace.Repo.ID,
        revision: String,
        to destination: URL,
        progress: Progress
    ) async throws {
        let expectedSize = Int64(entry.size ?? 0)
        if expectedSize > 0,
           let existingSize = try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           Int64(existingSize) == expectedSize {
            progress.totalUnitCount = expectedSize
            progress.completedUnitCount = expectedSize
            return
        }

        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let temporaryURL = destination
            .deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).download")
        try? FileManager.default.removeItem(at: temporaryURL)
        FileManager.default.createFile(atPath: temporaryURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: temporaryURL)

        var url = URL(string: "https://huggingface.co")!
            .appendingPathComponent(repoID.namespace)
            .appendingPathComponent(repoID.name)
            .appendingPathComponent("resolve")
            .appendingPathComponent(revision)
        for component in entry.path.split(separator: "/") {
            url.appendPathComponent(String(component))
        }

        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 60

        let delegate = DirectFileDownloadDelegate(
            progress: progress,
            fileHandle: handle,
            expectedSize: expectedSize
        )
        let session = URLSession(
            configuration: .default,
            delegate: delegate,
            delegateQueue: nil
        )
        defer {
            session.invalidateAndCancel()
        }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                delegate.setContinuation(continuation)
                session.dataTask(with: request).resume()
            }
        } onCancel: {
            session.invalidateAndCancel()
        }

        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temporaryURL, to: destination)
    }

    private static func snapshotProgress(total: Int64, completed: Int64) -> Progress {
        let progress = Progress(totalUnitCount: max(total, 1))
        progress.completedUnitCount = min(max(completed, 0), progress.totalUnitCount)
        return progress
    }

    private func matches(_ path: String, patterns: [String]) -> Bool {
        guard !patterns.isEmpty else { return true }
        return patterns.contains { pattern in
            let escaped = NSRegularExpression.escapedPattern(for: pattern)
                .replacingOccurrences(of: "\\*", with: ".*")
                .replacingOccurrences(of: "\\?", with: ".")
            let regex = "^\(escaped)$"
            return path.range(of: regex, options: .regularExpression) != nil
        }
    }
}

private struct HuggingFaceTokenizerBridge: MLXLMCommon.Tokenizer {
    private let upstream: any Tokenizers.Tokenizer

    init(_ upstream: any Tokenizers.Tokenizer) {
        self.upstream = upstream
    }

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        upstream.encode(text: text, addSpecialTokens: addSpecialTokens)
    }

    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
    }

    func convertTokenToId(_ token: String) -> Int? {
        upstream.convertTokenToId(token)
    }

    func convertIdToToken(_ id: Int) -> String? {
        upstream.convertIdToToken(id)
    }

    var bosToken: String? { upstream.bosToken }
    var eosToken: String? { upstream.eosToken }
    var unknownToken: String? { upstream.unknownToken }

    func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        do {
            return try upstream.applyChatTemplate(
                messages: messages,
                tools: tools,
                additionalContext: additionalContext
            )
        } catch Tokenizers.TokenizerError.missingChatTemplate {
            throw MLXLMCommon.TokenizerError.missingChatTemplate
        } catch {
            let message = error.localizedDescription.lowercased()
            if message.contains("parser error") && message.contains("modulo") {
                throw MLXLMCommon.TokenizerError.missingChatTemplate
            }
            throw error
        }
    }
}

private struct HuggingFaceTokenizerLoader: MLXLMCommon.TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        let upstream = try await Tokenizers.AutoTokenizer.from(modelFolder: directory)
        return HuggingFaceTokenizerBridge(upstream)
    }
}

actor MLXLocalService {
    static let shared = MLXLocalService()

    private var modelCache: [String: ModelContainer] = [:]
    private var inFlightLoads: [String: Task<ModelContainer, Error>] = [:]
    private var hasConfiguredMemory = false
    private var lastGenerationCompletedAt: Date?
    private let generationRecoveryGapSeconds: TimeInterval = 0.8

    /// Downloader configured to use the appropriate cache location per platform.
    /// - macOS: Uses ~/.cache/huggingface/hub (shared with Python, mlx-lm, etc.)
    /// - iOS: Uses app's Caches directory (sandboxed, no sharing possible)
    #if os(macOS)
    private let sharedDownloader = HuggingFaceDownloadBridge(
        downloadBase: URL.homeDirectory.appending(path: ".cache/huggingface/hub")
    )
    #else
    private let sharedDownloader = HuggingFaceDownloadBridge(
        downloadBase: URL.cachesDirectory.appending(path: "huggingface")
    )
    #endif
    private let tokenizerLoader = HuggingFaceTokenizerLoader()

    private func configureMemoryIfNeeded() {
        guard !hasConfiguredMemory else { return }
        // Keep MLX cache bounded so WebKit/Metal rendering can coexist with local inference.
        GPU.set(cacheLimit: 512 * 1024 * 1024)
        hasConfiguredMemory = true
    }

    func preloadModel(
        modelID: String,
        progressHandler: @Sendable @escaping (Progress) -> Void = { _ in }
    ) async throws {
        _ = try await loadModel(modelID: modelID, progressHandler: progressHandler)
    }

    func clearTransientCache() {
        GPU.clearCache()
    }

    func unloadModel(modelID: String) {
        let id = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        if let task = inFlightLoads[id] {
            task.cancel()
            inFlightLoads[id] = nil
        }
        modelCache[id] = nil
        GPU.clearCache()
    }

    func unloadAllModels() {
        for (_, task) in inFlightLoads {
            task.cancel()
        }
        inFlightLoads.removeAll()
        modelCache.removeAll()
        GPU.clearCache()
    }

    func generateText(
        prompt: String,
        modelID: String,
        maxOutputTokens: Int,
        maxContextTokens: Int?
    ) async throws -> String {
        try await generateTextStreaming(
            prompt: prompt,
            modelID: modelID,
            maxOutputTokens: maxOutputTokens,
            maxContextTokens: maxContextTokens,
            onToken: { _ in }
        )
    }

    func generateTextStreaming(
        prompt: String,
        modelID: String,
        maxOutputTokens: Int,
        maxContextTokens: Int?,
        onToken: @Sendable @escaping (String) -> Void
    ) async throws -> String {
        configureMemoryIfNeeded()
        let container = try await loadModel(modelID: modelID)
        return try await generateWithContainer(
            container,
            prompt: prompt,
            modelIdentifierHint: modelID,
            maxOutputTokens: maxOutputTokens,
            maxContextTokens: maxContextTokens,
            onToken: onToken
        )
    }

    /// Generate text using a model loaded from a local directory.
    /// Use this when loading models from user-selected folders (e.g., via Files app on iOS).
    /// - Parameters:
    ///   - prompt: The user prompt
    ///   - modelDirectory: URL to the folder containing model files (config.json, *.safetensors, etc.)
    ///   - maxOutputTokens: Maximum tokens to generate
    ///   - maxContextTokens: Optional context window limit
    func generateText(
        prompt: String,
        modelDirectory: URL,
        maxOutputTokens: Int,
        maxContextTokens: Int?
    ) async throws -> String {
        try await generateTextStreaming(
            prompt: prompt,
            modelDirectory: modelDirectory,
            maxOutputTokens: maxOutputTokens,
            maxContextTokens: maxContextTokens,
            onToken: { _ in }
        )
    }

    func generateTextStreaming(
        prompt: String,
        modelDirectory: URL,
        maxOutputTokens: Int,
        maxContextTokens: Int?,
        onToken: @Sendable @escaping (String) -> Void
    ) async throws -> String {
        configureMemoryIfNeeded()
        let container = try await loadModelFromDirectory(modelDirectory)
        return try await generateWithContainer(
            container,
            prompt: prompt,
            modelIdentifierHint: modelDirectory.lastPathComponent,
            maxOutputTokens: maxOutputTokens,
            maxContextTokens: maxContextTokens,
            onToken: onToken
        )
    }

    private func generateWithContainer(
        _ container: ModelContainer,
        prompt: String,
        modelIdentifierHint: String? = nil,
        maxOutputTokens: Int,
        maxContextTokens: Int?,
        onToken: @Sendable @escaping (String) -> Void
    ) async throws -> String {
        if let completed = lastGenerationCompletedAt {
            let elapsed = -completed.timeIntervalSinceNow
            if elapsed < generationRecoveryGapSeconds {
                let remaining = UInt64((generationRecoveryGapSeconds - elapsed) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: remaining)
            }
        }

        let startTime = Date()
        let systemPrompt = "You are a helpful assistant."
        let disableThinking = shouldDisableThinking(for: modelIdentifierHint)
        let bypassChatTemplate = shouldBypassChatTemplate(for: modelIdentifierHint)
        let resolvedPrompt = disableThinking ? ensureNoThinkDirective(in: prompt) : prompt
        let userInput: UserInput
        if bypassChatTemplate {
            userInput = UserInput(prompt: .text("""
            \(systemPrompt)

            Answer the task below directly. Write the answer itself, not a description of the answer.
            Never start with "The provided summary", "The summary", or "This summary".
            Do not repeat any sentence or paragraph. Stop after the answer is complete.

            \(resolvedPrompt)

            Answer:
            """))
        } else if disableThinking {
            let chat: [Chat.Message] = [
                .system(systemPrompt),
                .user(resolvedPrompt),
            ]
            let additionalContext: [String: any Sendable] = ["enable_thinking": false]
            userInput = UserInput(chat: chat, additionalContext: additionalContext)
        } else {
            let chat: [Chat.Message] = [
                .system(systemPrompt),
                .user(resolvedPrompt),
            ]
            userInput = UserInput(chat: chat)
        }
        print("⏱️ [MLX] Starting generation (maxTokens: \(maxOutputTokens))")

        let stream = try await container.perform { context in
            let lmInput = try await context.processor.prepare(input: userInput)
            let parameters = GenerateParameters(
                maxTokens: bypassChatTemplate ? min(maxOutputTokens, 220) : maxOutputTokens,
                maxKVSize: maxContextTokens,
                temperature: bypassChatTemplate ? 0.1 : 0.2,
                topP: bypassChatTemplate ? 0.75 : 0.95,
                topK: bypassChatTemplate ? 16 : 0,
                repetitionPenalty: bypassChatTemplate ? 1.25 : 1.08,
                repetitionContextSize: 256,
                presencePenalty: bypassChatTemplate ? 0.35 : nil,
                presenceContextSize: 128,
                frequencyPenalty: bypassChatTemplate ? 0.25 : nil,
                frequencyContextSize: 128
            )
            return try MLXLMCommon.generate(input: lmInput, parameters: parameters, context: context)
        }

        var output = ""
        var tokenCount = 0
        for await token in stream {
            if Task.isCancelled { throw CancellationError() }
            if let chunk = token.chunk {
                let filtered = chunk
                    .replacingOccurrences(of: "<end_of_turn>", with: "")
                    .replacingOccurrences(of: "</s>", with: "")
                if !filtered.isEmpty {
                    let prospectiveOutput = output + filtered
                    if bypassChatTemplate, shouldStopForRepeatedContent(in: prospectiveOutput) {
                        break
                    }
                    output = prospectiveOutput
                    tokenCount += 1
                    onToken(filtered)
                }
            }
        }

        let elapsed = Date().timeIntervalSince(startTime)
        let tokensPerSecond = elapsed > 0 ? Double(tokenCount) / elapsed : 0
        print("✅ [MLX] Generated \(tokenCount) tokens in \(String(format: "%.1f", elapsed))s (\(String(format: "%.1f", tokensPerSecond)) tok/s)")

        lastGenerationCompletedAt = Date()
        return sanitizeModelOutput(output)
    }

    private func shouldStopForRepeatedContent(in output: String) -> Bool {
        shouldStopForRepeatedParagraph(in: output) || shouldStopForRepeatedSentence(in: output)
    }

    private func shouldStopForRepeatedParagraph(in output: String) -> Bool {
        let paragraphs = output
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 80 }

        guard paragraphs.count >= 2 else { return false }

        guard let latest = paragraphs.last else { return false }
        let latestKey = normalizedRepetitionKey(latest)
        guard latestKey.count > 40 else { return false }

        let previousKeys = Set(paragraphs.dropLast().map(normalizedRepetitionKey(_:)))
        return previousKeys.contains(latestKey)
    }

    private func shouldStopForRepeatedSentence(in output: String) -> Bool {
        let sentenceCandidates = output
            .replacingOccurrences(of: "\n", with: " ")
            .components(separatedBy: ".")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 70 }

        guard sentenceCandidates.count >= 2, let latest = sentenceCandidates.last else {
            return false
        }

        let latestKey = normalizedRepetitionKey(latest)
        guard latestKey.count > 40 else { return false }

        let previousKeys = Set(sentenceCandidates.dropLast().map(normalizedRepetitionKey(_:)))
        return previousKeys.contains(latestKey)
    }

    private func normalizedRepetitionKey(_ text: String) -> String {
        text
            .lowercased()
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: " ", options: .regularExpression)
            .split(separator: " ")
            .prefix(32)
            .joined(separator: " ")
    }

    private func ensureNoThinkDirective(in prompt: String) -> String {
        guard !promptHasNoThinkDirective(prompt) else { return prompt }
        return "/no_think\n\(prompt)"
    }

    private func promptHasNoThinkDirective(_ prompt: String) -> Bool {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.lowercased().hasPrefix("/no_think")
    }

    private func shouldDisableThinking(for modelIdentifier: String?) -> Bool {
        guard let modelIdentifier else { return false }
        return modelIdentifier.lowercased().contains("qwen")
    }

    private func shouldBypassChatTemplate(for modelIdentifier: String?) -> Bool {
        guard let modelIdentifier else { return false }
        let id = modelIdentifier.lowercased()
        return id.contains("gemma-4") || id.contains("gemma4")
    }

    private func sanitizeModelOutput(_ text: String) -> String {
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
        cleaned = cleaned.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        return removeRepeatedParagraphs(from: cleaned).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func removeRepeatedParagraphs(from text: String) -> String {
        var seen = Set<String>()
        var kept: [String] = []

        for paragraph in text.components(separatedBy: "\n\n") {
            let trimmed = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let key = normalizedRepetitionKey(trimmed)
            if key.count > 40, seen.contains(key) {
                continue
            }
            if key.count > 40 {
                seen.insert(key)
            }
            kept.append(trimmed)
        }

        return kept.joined(separator: "\n\n")
    }

    private func loadModel(
        modelID: String,
        progressHandler: @Sendable @escaping (Progress) -> Void = { _ in }
    ) async throws -> ModelContainer {
        configureMemoryIfNeeded()
        let id = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else {
            throw NSError(
                domain: "MLXLocalService",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Missing Hugging Face model id."]
            )
        }

        if let cached = modelCache[id] {
            return cached
        }

        if let task = inFlightLoads[id] {
            return try await task.value
        }

        let task = Task<ModelContainer, Error> {
            try await loadContainerFromModelID(
                id,
                downloader: sharedDownloader,
                progressHandler: progressHandler
            )
        }

        inFlightLoads[id] = task
        do {
            let container = try await task.value
            modelCache[id] = container
            inFlightLoads[id] = nil
            return container
        } catch {
            inFlightLoads[id] = nil
            throw error
        }
    }

    /// Load a model from a local directory (e.g., user-selected via Files app).
    /// Handles security-scoped resource access for iOS sandboxing.
    private func loadModelFromDirectory(_ directory: URL) async throws -> ModelContainer {
        configureMemoryIfNeeded()

        let cacheKey = directory.absoluteString
        if let cached = modelCache[cacheKey] {
            print("🚀 [MLX] Using cached model")
            return cached
        }
        print("⏳ [MLX] Loading model from disk...")

        if let task = inFlightLoads[cacheKey] {
            return try await task.value
        }

        let task = Task<ModelContainer, Error> {
            // Handle security-scoped resources (required for iOS file picker URLs)
            let didStartAccessing = directory.startAccessingSecurityScopedResource()
            defer {
                if didStartAccessing {
                    directory.stopAccessingSecurityScopedResource()
                }
            }

            // Verify the directory contains required model files
            let configPath = directory.appending(path: "config.json")
            guard FileManager.default.fileExists(atPath: configPath.path) else {
                throw NSError(
                    domain: "MLXLocalService",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Invalid model directory: missing config.json"]
                )
            }

            return try await loadContainerFromDirectory(
                directory,
                progressHandler: { _ in }
            )
        }

        inFlightLoads[cacheKey] = task
        do {
            let container = try await task.value
            modelCache[cacheKey] = container
            inFlightLoads[cacheKey] = nil
            return container
        } catch {
            inFlightLoads[cacheKey] = nil
            throw error
        }
    }

    /// Preload a model from a local directory for faster first inference.
    func preloadModelFromDirectory(_ directory: URL) async throws {
        _ = try await loadModelFromDirectory(directory)
    }

    /// Unload a model that was loaded from a local directory.
    func unloadModelFromDirectory(_ directory: URL) {
        let cacheKey = directory.absoluteString
        if let task = inFlightLoads[cacheKey] {
            task.cancel()
            inFlightLoads[cacheKey] = nil
        }
        modelCache[cacheKey] = nil
        GPU.clearCache()
    }

    /// Download a model to a custom location (e.g., iCloud Drive for sharing).
    /// - Parameters:
    ///   - modelID: The HuggingFace model ID (e.g., "mlx-community/Llama-3.2-1B-4bit")
    ///   - location: The folder to download to (must be accessible)
    ///   - progressHandler: Progress callback
    func downloadModelToLocation(
        modelID: String,
        location: URL,
        progressHandler: @Sendable @escaping (Progress) -> Void = { _ in }
    ) async throws {
        let id = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else {
            throw NSError(
                domain: "MLXLocalService",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Missing Hugging Face model id."]
            )
        }

        let downloader = HuggingFaceDownloadBridge(downloadBase: location)

        // Download to the custom location (this just downloads, doesn't load into memory)
        _ = try await loadContainerFromModelID(
            id,
            downloader: downloader,
            progressHandler: progressHandler
        )
    }

    private func loadContainerFromModelID(
        _ modelID: String,
        downloader: any MLXLMCommon.Downloader,
        progressHandler: @Sendable @escaping (Progress) -> Void = { _ in }
    ) async throws -> ModelContainer {
        do {
            let configuration = LLMRegistry.shared.configuration(id: modelID)
            return try await LLMModelFactory.shared.loadContainer(
                from: downloader,
                using: tokenizerLoader,
                configuration: configuration,
                progressHandler: progressHandler
            )
        } catch {
            guard shouldFallbackToVLM(error) else { throw error }
            #if canImport(MLXVLM)
            let configuration = VLMModelFactory.shared.configuration(id: modelID)
            return try await VLMModelFactory.shared.loadContainer(
                from: downloader,
                using: tokenizerLoader,
                configuration: configuration,
                progressHandler: progressHandler
            )
            #else
            throw error
            #endif
        }
    }

    private func loadContainerFromDirectory(
        _ directory: URL,
        progressHandler: @Sendable @escaping (Progress) -> Void = { _ in }
    ) async throws -> ModelContainer {
        do {
            return try await LLMModelFactory.shared.loadContainer(
                from: directory,
                using: tokenizerLoader
            )
        } catch {
            guard shouldFallbackToVLM(error) else { throw error }
            #if canImport(MLXVLM)
            return try await VLMModelFactory.shared.loadContainer(
                from: directory,
                using: tokenizerLoader
            )
            #else
            throw error
            #endif
        }
    }

    private func shouldFallbackToVLM(_ error: Error) -> Bool {
        if let factoryError = error as? ModelFactoryError {
            if case .unsupportedModelType = factoryError {
                return true
            }
        }
        return error.localizedDescription.localizedCaseInsensitiveContains("unsupported model type")
    }
}
#else
actor MLXLocalService {
    static let shared = MLXLocalService()

    func preloadModel(
        modelID: String,
        progressHandler: @Sendable @escaping (Progress) -> Void = { _ in }
    ) async throws {
        throw NSError(
            domain: "MLXLocalService",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "MLX Local is unavailable in this build (missing MLX packages)."]
        )
    }

    func clearTransientCache() {
        // no-op
    }

    func unloadModel(modelID: String) {
        // no-op
    }

    func unloadAllModels() {
        // no-op
    }

    func generateText(
        prompt: String,
        modelID: String,
        maxOutputTokens: Int,
        maxContextTokens: Int?
    ) async throws -> String {
        throw NSError(
            domain: "MLXLocalService",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "MLX Local is unavailable in this build (missing MLX packages)."]
        )
    }

    func generateTextStreaming(
        prompt: String,
        modelID: String,
        maxOutputTokens: Int,
        maxContextTokens: Int?,
        onToken: @Sendable @escaping (String) -> Void
    ) async throws -> String {
        throw NSError(
            domain: "MLXLocalService",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "MLX Local is unavailable in this build (missing MLX packages)."]
        )
    }

    func generateText(
        prompt: String,
        modelDirectory: URL,
        maxOutputTokens: Int,
        maxContextTokens: Int?
    ) async throws -> String {
        throw NSError(
            domain: "MLXLocalService",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "MLX Local is unavailable in this build (missing MLX packages)."]
        )
    }

    func preloadModelFromDirectory(_ directory: URL) async throws {
        throw NSError(
            domain: "MLXLocalService",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "MLX Local is unavailable in this build (missing MLX packages)."]
        )
    }

    func unloadModelFromDirectory(_ directory: URL) {
        // no-op
    }

    func downloadModelToLocation(
        modelID: String,
        location: URL,
        progressHandler: @Sendable @escaping (Progress) -> Void = { _ in }
    ) async throws {
        throw NSError(
            domain: "MLXLocalService",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "MLX Local is unavailable in this build (missing MLX packages)."]
        )
    }
}
#endif
