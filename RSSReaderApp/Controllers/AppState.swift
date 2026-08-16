import Foundation
import Combine
import SwiftUI
#if canImport(WidgetKit)
import WidgetKit
#endif
#if canImport(WebKit)
import WebKit
#endif
#if canImport(Kingfisher)
import Kingfisher
#endif
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif
#if canImport(FoundationModels)
import FoundationModels
#endif

#if os(iOS)
private final class GeminiAggregateBackgroundContext {
    var handle: GeminiBackgroundTaskHandle?
}
#endif

struct LocalModelStorageItem: Identifiable, Hashable {
    enum Kind: String {
        case liteRT = "LiteRT"
        case mlx = "MLX / Hugging Face"
    }

    let id: String
    let name: String
    let detail: String
    let kind: Kind
    let sizeBytes: UInt64
    let url: URL
    let isCurrentSelection: Bool

    var sizeText: String {
        ByteCountFormatter.string(fromByteCount: Int64(sizeBytes), countStyle: .file)
    }
}

struct AppStorageBreakdownItem: Identifiable, Hashable {
    enum CleanupKind: String, Hashable {
        case caches
        case kingfisherImages
        case webKit
        case httpStorages
        case savedApplicationState
        case logs
        case temporaryFiles
    }

    let id: String
    let name: String
    let detail: String
    let sizeBytes: UInt64
    let isModelStorage: Bool
    let cleanupKind: CleanupKind?

    var sizeText: String {
        ByteCountFormatter.string(fromByteCount: Int64(sizeBytes), countStyle: .file)
    }
}

// MARK: - Global Summary Types & Service
struct GlobalSummaryItem: Codable, Identifiable {
    let id = UUID()
    let subject: String
    let summary: String
    let referenceId: String?

    // Exclude 'id' from Codable - it's only for SwiftUI Identifiable
    enum CodingKeys: String, CodingKey {
        case subject, summary, referenceId
    }
}

struct GlobalSummaryResult: Codable {
    let source: String
    let summaries: [GlobalSummaryItem]
    let error: String?
    
    static func errorResult(source: String, message: String) -> GlobalSummaryResult {
        GlobalSummaryResult(source: source, summaries: [], error: message)
    }
}

private struct OverallSummaryProviderResolution {
    let selectedProvider: AppSettings.SummaryProvider
    let effectiveProvider: AppSettings.SummaryProvider
    let localFallbackProviderName: String?

    var fallbackNotification: String? {
        guard let localFallbackProviderName else { return nil }
        return "Overall Summary requires large context — using Gemini instead of \(localFallbackProviderName) for this step."
    }
}

private func resolveOverallSummaryProvider(
    for provider: AppSettings.SummaryProvider
) -> OverallSummaryProviderResolution {
    switch provider {
    case .gemini:
        return OverallSummaryProviderResolution(
            selectedProvider: provider,
            effectiveProvider: .gemini,
            localFallbackProviderName: nil
        )
    case .appleCloud:
        return OverallSummaryProviderResolution(
            selectedProvider: provider,
            effectiveProvider: .appleCloud,
            localFallbackProviderName: nil
        )
    case .applePCCGateway:
        return OverallSummaryProviderResolution(
            selectedProvider: provider,
            effectiveProvider: .applePCCGateway,
            localFallbackProviderName: nil
        )
    case .webAI:
        return OverallSummaryProviderResolution(
            selectedProvider: provider,
            effectiveProvider: .webAI,
            localFallbackProviderName: nil
        )
    case .summarizeDaemon:
        return OverallSummaryProviderResolution(
            selectedProvider: provider,
            effectiveProvider: .summarizeDaemon,
            localFallbackProviderName: nil
        )
    case .appleLocal:
        return OverallSummaryProviderResolution(
            selectedProvider: provider,
            effectiveProvider: .gemini,
            localFallbackProviderName: "Apple Local"
        )
    case .mlxLocal:
        return OverallSummaryProviderResolution(
            selectedProvider: provider,
            effectiveProvider: .gemini,
            localFallbackProviderName: "LiteRT Local"
        )
    case .coreAIMLXLocal:
        return OverallSummaryProviderResolution(
            selectedProvider: provider,
            effectiveProvider: .gemini,
            localFallbackProviderName: "CoreAI MLX Local"
        )
    }
}

final class GlobalSummaryService {
    private let summaryService: SummaryService
    private let redditService: RedditService
    private let settingsProvider: () -> AppSettings
    private var cloudRequestHandler: ((String, @escaping (String) -> Void) -> Void)?
    private var webRequestHandler: ((WebAIProvider, String, String, WebAIResponseFormat, @escaping (Result<String, Error>) -> Void) -> Void)?
    private var throughputReporter: ((String) -> Void)?
    private var warningReporter: ((String) -> Void)?
    private var redditCommentsCacheReporter: (([(RedditPost, [String])]) -> Void)?

    init(summaryService: SummaryService, redditService: RedditService, settingsProvider: @escaping () -> AppSettings = { PersistenceManager.shared.loadSettings() }) {
        self.summaryService = summaryService
        self.redditService = redditService
        self.settingsProvider = settingsProvider
    }

    /// Set the cloud request handler (called from AppState after init)
    func setCloudRequestHandler(_ handler: @escaping (String, @escaping (String) -> Void) -> Void) {
        self.cloudRequestHandler = handler
    }

    func setWebRequestHandler(_ handler: @escaping (WebAIProvider, String, String, WebAIResponseFormat, @escaping (Result<String, Error>) -> Void) -> Void) {
        self.webRequestHandler = handler
    }

    /// Set throughput reporter so per-item MLX metrics flow back to AppState's @Published var.
    func setThroughputReporter(_ handler: @escaping (String) -> Void) {
        self.throughputReporter = handler
    }

    /// Set warning reporter to surface provider-override notices to the UI.
    func setWarningReporter(_ handler: @escaping (String) -> Void) {
        self.warningReporter = handler
    }

    /// Reports the exact Reddit comment text used to build a global summary so Q&A can reuse it.
    func setRedditCommentsCacheReporter(_ handler: @escaping ([(RedditPost, [String])]) -> Void) {
        self.redditCommentsCacheReporter = handler
    }

    private func reportThroughput(_ metrics: MLXGenerationMetrics) {
        guard metrics.tokensPerSecond > 0 else { return }
        let providerLabel = settingsProvider().selectedSummaryProvider == .coreAIMLXLocal ? "CoreAI MLX" : "LiteRT"
        let label = String(format: "\(providerLabel) · %.1f tok/s · %d tokens", metrics.tokensPerSecond, metrics.tokenCount)
        throughputReporter?(label)
    }

    private func reportAppleLocalThroughput(text: String, elapsed: TimeInterval) {
        guard elapsed > 0 else { return }
        let estimatedTokens = max(1, Int(Double(text.split(separator: " ").count) * 1.3))
        let tokPerSec = Double(estimatedTokens) / elapsed
        let label = String(format: "Apple · ~%.1f tok/s · ~%d tokens", tokPerSec, estimatedTokens)
        throughputReporter?(label)
    }
    
    func summarizeArticlesGlobally(
        articles: [Article],
        existingBackgroundTaskHandle: Any? = nil,
        providerOverride: AppSettings.SummaryProvider? = nil
    ) -> AnyPublisher<GlobalSummaryResult, Never> {
        let payload = articles.map { (id: $0.id, title: $0.title, excerpt: Self.firstNChars(Self.stripHTML($0.content), 5000)) }
        if payload.isEmpty || payload.allSatisfy({ $0.title.isEmpty && $0.excerpt.isEmpty }) {
            let msg = "No articles or excerpts available for summarization."
            print("❌ GlobalSummaryService: \(msg)")
            return Just(GlobalSummaryResult.errorResult(source: "articles", message: msg)).eraseToAnyPublisher()
        }
        print("✅ GlobalSummaryService: Prepared \(payload.count) article items (title + ≤5000-char excerpt)")

        let settings = settingsProvider()
        let selectedProvider = providerOverride ?? settings.selectedSummaryProvider

        let prompt = buildArticlesPrompt(items: payload.map { (title: $0.title, excerpt: $0.excerpt) })
        let articleIds = payload.map { $0.id }

        #if os(iOS)
        let usesGeminiBackgroundTask = (selectedProvider == .gemini)
        let provided = usesGeminiBackgroundTask ? (existingBackgroundTaskHandle as? GeminiBackgroundTaskHandle) : nil
        let shouldManageHandle = usesGeminiBackgroundTask && (provided == nil)
        let backgroundHandle: GeminiBackgroundTaskHandle? = usesGeminiBackgroundTask
            ? (provided ?? GeminiBackgroundTaskManager.shared.beginLongRunningTask(
                identifier: GeminiBackgroundTaskManager.shared.taskIdentifier(for: .summarization),
                title: "Summarizing \(payload.count) Articles"
            ))
            : nil
        backgroundHandle?.reportProgress(fractionCompleted: 0.1)
        let waitPublisher: AnyPublisher<Void, Never>
        if let backgroundHandle, shouldManageHandle {
            waitPublisher = Future { promise in
                Task {
                    await backgroundHandle.waitForTaskStartIfNeeded()
                    promise(.success(()))
                }
            }
            .eraseToAnyPublisher()
        } else {
            waitPublisher = Just(()).eraseToAnyPublisher()
        }

        return waitPublisher
            .flatMap { _ in
                self.callLLMAndDecode(
                    source: "articles",
                    prompt: prompt,
                    referenceIds: articleIds,
                    provider: selectedProvider,
                    existingBackgroundTaskHandle: backgroundHandle
                )
            }
            .handleEvents(
                receiveOutput: { _ in
                    backgroundHandle?.reportProgress(fractionCompleted: 0.9)
                },
                receiveCompletion: { _ in
                    if shouldManageHandle, let backgroundHandle {
                        backgroundHandle.finish(success: true)
                        print("✅ GlobalSummaryService: Articles background task completed (works when locked)")
                    }
                },
                receiveCancel: {
                    if shouldManageHandle, let backgroundHandle {
                        backgroundHandle.finish(success: false)
                    }
                }
            )
            .eraseToAnyPublisher()
        #else
        return callLLMAndDecode(
            source: "articles",
            prompt: prompt,
            referenceIds: articleIds,
            provider: selectedProvider
        )
            .eraseToAnyPublisher()
        #endif
    }
    
    // Helper method to process a single batch of posts with rate limiting
    private struct CommentFetchOutcome {
        let index: Int
        let post: RedditPost
        let topLevel: [RedditCommentModel]
        let rateLimitRemaining: Double?
        let rateLimitReset: Double?
        let retryAfter: Double?
    }

    private func processBatch(batch: [(index: Int, post: RedditPost)], batchIndex: Int, topComments: Int) -> AnyPublisher<[(index: Int, post: RedditPost, topLevel: [RedditCommentModel])], Never> {
        print("📱 GlobalSummaryService: Processing batch \(batchIndex + 1) with \(batch.count) posts")

        let maxRetriesPerPost = 2
        let retryScheduler = DispatchQueue.global(qos: .userInitiated)

        func delayForRateLimitExhaustion(remaining: Double?, reset: Double?) -> Double {
            guard let remaining = remaining else { return 0 }
            guard remaining <= 1 else { return 0 }
            if let reset = reset, reset > 0 {
                print("⚠️ GlobalSummaryService: Rate limit almost exhausted. Pausing for \(reset)s to allow reset.")
                return reset
            } else {
                let fallback = 1.0
                print("⚠️ GlobalSummaryService: Rate limit almost exhausted. Pausing for \(fallback)s (no reset header).")
                return fallback
            }
        }

        func fetchWithRetry(pair: (index: Int, post: RedditPost), attempt: Int) -> AnyPublisher<CommentFetchOutcome, Never> {
            self.redditService
                .fetchCommentsDetailed(for: pair.post.id, in: pair.post.subreddit, limit: topComments, depth: 0)
                .flatMap { result -> AnyPublisher<CommentFetchOutcome, Never> in
                    let sortedTopLevel = result.comments
                        .filter { $0.indentationLevel == 0 }
                        .sorted { $0.score > $1.score }
                    let limited = Array(sortedTopLevel.prefix(topComments))

                    let hadError = result.error != nil
                    let expectedComments = pair.post.commentCount > 0
                    let shouldRetryDueToError = hadError && attempt < maxRetriesPerPost
                    let shouldRetryDueToEmpty = !hadError && limited.isEmpty && expectedComments && attempt < maxRetriesPerPost

                    if shouldRetryDueToError || shouldRetryDueToEmpty {
                        let delaySeconds: Double
                        if result.httpStatusCode == 429 {
                            if let retryAfter = result.retryAfter, retryAfter > 0 {
                                delaySeconds = retryAfter
                            } else if let reset = result.rateLimitReset, reset > 0 {
                                delaySeconds = reset
                            } else {
                                delaySeconds = pow(1.5, Double(attempt))
                            }
                        } else {
                            delaySeconds = pow(1.5, Double(attempt))
                        }

                        if hadError {
                            let description = (result.error as? LocalizedError)?.errorDescription ?? result.error?.localizedDescription ?? "Unknown error"
                            print("⚠️ GlobalSummaryService: Retry \(attempt + 1) for post \(pair.post.id) due to error: \(description). Waiting \(delaySeconds)s before retry.")
                        } else {
                            print("⚠️ GlobalSummaryService: Retry \(attempt + 1) for post \(pair.post.id) — expected comments but received none. Waiting \(delaySeconds)s before retry.")
                        }

                        return Just(())
                            .delay(for: .seconds(delaySeconds), scheduler: retryScheduler)
                            .flatMap { _ in fetchWithRetry(pair: pair, attempt: attempt + 1) }
                            .eraseToAnyPublisher()
                    }

                    let topLevel: [RedditCommentModel]
                    if hadError && limited.isEmpty {
                        let baseMessage = (result.error as? LocalizedError)?.errorDescription ?? result.error?.localizedDescription ?? "Unknown error"
                        let sanitized = baseMessage.trimmingCharacters(in: .whitespacesAndNewlines)
                        let placeholderBody = sanitized.isEmpty
                            ? "Top comments unavailable due to network error."
                            : "Top comments unavailable: \(sanitized)"
                        let placeholder = RedditCommentModel(
                            id: "error-\(pair.post.id)-\(UUID().uuidString)",
                            author: "CommentFetchError",
                            body: placeholderBody,
                            score: 0,
                            createdUtc: Date().timeIntervalSince1970,
                            replies: [],
                            indentationLevel: 0
                        )
                        print("⚠️ GlobalSummaryService: Using placeholder comment for post \(pair.post.id) after retries exhausted")
                        topLevel = [placeholder]
                    } else {
                        topLevel = limited
                    }

                    let outcome = CommentFetchOutcome(
                        index: pair.index,
                        post: pair.post,
                        topLevel: topLevel,
                        rateLimitRemaining: result.rateLimitRemaining,
                        rateLimitReset: result.rateLimitReset,
                        retryAfter: result.retryAfter
                    )

                    return Just(outcome).eraseToAnyPublisher()
                }
                .eraseToAnyPublisher()
        }

        func processSequentially(remaining: ArraySlice<(index: Int, post: RedditPost)>, accumulated: [CommentFetchOutcome]) -> AnyPublisher<[CommentFetchOutcome], Never> {
            guard let current = remaining.first else {
                return Just(accumulated).eraseToAnyPublisher()
            }

            let tail = remaining.dropFirst()

            return fetchWithRetry(pair: current, attempt: 0)
                .flatMap { outcome -> AnyPublisher<[CommentFetchOutcome], Never> in
                    let updated = accumulated + [outcome]
                    let delaySeconds = delayForRateLimitExhaustion(remaining: outcome.rateLimitRemaining, reset: outcome.rateLimitReset)

                    if delaySeconds > 0 && !tail.isEmpty {
                        return Just(())
                            .delay(for: .seconds(delaySeconds), scheduler: retryScheduler)
                            .flatMap { _ in processSequentially(remaining: tail, accumulated: updated) }
                            .eraseToAnyPublisher()
                    } else {
                        return processSequentially(remaining: tail, accumulated: updated)
                    }
                }
                .eraseToAnyPublisher()
        }

        return processSequentially(remaining: ArraySlice(batch), accumulated: [])
            .map { outcomes in
                outcomes.map { (index: $0.index, post: $0.post, topLevel: $0.topLevel) }
            }
            .eraseToAnyPublisher()
    }

    func summarizeRedditGlobally(
        posts: [RedditPost],
        topComments: Int = 10,
        existingBackgroundTaskHandle: Any? = nil,
        providerOverride: AppSettings.SummaryProvider? = nil
    ) -> AnyPublisher<GlobalSummaryResult, Never> {
        guard !posts.isEmpty else {
            let msg = "No Reddit posts available for summarization."
            print("❌ GlobalSummaryService: \(msg)")
            return Just(GlobalSummaryResult.errorResult(source: "reddit", message: msg)).eraseToAnyPublisher()
        }

        let settings = settingsProvider()
        let selectedProvider = providerOverride ?? settings.selectedSummaryProvider

        #if os(iOS)
        let usesGeminiBackgroundTask = (selectedProvider == .gemini)
        let provided = usesGeminiBackgroundTask ? (existingBackgroundTaskHandle as? GeminiBackgroundTaskHandle) : nil
        let shouldManageHandle = usesGeminiBackgroundTask && (provided == nil)
        let backgroundHandle: GeminiBackgroundTaskHandle? = usesGeminiBackgroundTask
            ? (provided ?? GeminiBackgroundTaskManager.shared.beginLongRunningTask(
                identifier: GeminiBackgroundTaskManager.shared.taskIdentifier(for: .summarization),
                title: "Summarizing \(posts.count) Reddit Posts"
            ))
            : nil
        backgroundHandle?.reportProgress(fractionCompleted: 0.1)
        var backgroundSubscription: Combine.Subscription?
        backgroundHandle?.registerCancellationHandler {
            backgroundSubscription?.cancel()
            DispatchQueue.main.async {
                if shouldManageHandle, let backgroundHandle {
                    backgroundHandle.finish(success: false)
                }
            }
        }
        #endif

        let indexed = posts.enumerated().map { (idx, post) in (index: idx, post: post) }

        // OPTIMIZED: Since we now only fetch 10 top-level comments (not 100+ with replies),
        // we can use larger batches without hitting rate limits
        let batchSize = 10
        let batches = stride(from: 0, to: indexed.count, by: batchSize).map {
            Array(indexed[$0..<min($0 + batchSize, indexed.count)])
        }

        print("✅ GlobalSummaryService: Processing \(indexed.count) posts in \(batches.count) batches of up to \(batchSize)")

        #if os(iOS)
        let totalBatchCount = max(1, batches.count)
        let commentProgressStart: Double = 0.1
        let commentProgressRange: Double = 0.3
        let perBatchIncrement = commentProgressRange / Double(totalBatchCount)
        let progressQueue = DispatchQueue.main
        var completedBatchCount = 0

        func reportBatchCompletion() {
            completedBatchCount += 1
            let fraction = min(commentProgressStart + Double(completedBatchCount) * perBatchIncrement,
                               commentProgressStart + commentProgressRange)
            progressQueue.async {
                backgroundHandle?.reportProgress(fractionCompleted: fraction)
            }
        }

        func monitorBatch(_ publisher: AnyPublisher<[(index: Int, post: RedditPost, topLevel: [RedditCommentModel])], Never>) -> AnyPublisher<[(index: Int, post: RedditPost, topLevel: [RedditCommentModel])], Never> {
            publisher
                .handleEvents(receiveOutput: { _ in reportBatchCompletion() })
                .eraseToAnyPublisher()
        }
        #else
        func monitorBatch(_ publisher: AnyPublisher<[(index: Int, post: RedditPost, topLevel: [RedditCommentModel])], Never>) -> AnyPublisher<[(index: Int, post: RedditPost, topLevel: [RedditCommentModel])], Never> {
            publisher
        }
        #endif

        #if os(iOS)
        let waitPublisher: AnyPublisher<Void, Never>
        if let backgroundHandle, shouldManageHandle {
            waitPublisher = Future { promise in
                Task {
                    await backgroundHandle.waitForTaskStartIfNeeded()
                    promise(.success(()))
                }
            }
            .eraseToAnyPublisher()
        } else {
            waitPublisher = Just(()).eraseToAnyPublisher()
        }
        #else
        let waitPublisher: AnyPublisher<Void, Never> = Just(())
            .eraseToAnyPublisher()
        #endif

        // CRITICAL FIX: Process batches SEQUENTIALLY, not in parallel
        // This is the key to avoiding rate limits - we must chain batches one after another
        let firstBatchPublisher: AnyPublisher<[(index: Int, post: RedditPost, topLevel: [RedditCommentModel])], Never>
        if batches.isEmpty {
            firstBatchPublisher = Just([(index: Int, post: RedditPost, topLevel: [RedditCommentModel])]()).eraseToAnyPublisher()
        } else {
            firstBatchPublisher = monitorBatch(processBatch(batch: batches[0], batchIndex: 0, topComments: topComments))
        }

        // Chain all batches sequentially using reduce
        let allBatchesPublisher = batches.dropFirst().enumerated().reduce(firstBatchPublisher) { accumulated, pair in
            let (idx, batch) = pair
            let batchIndex = idx + 1 // Adjust index since we're using dropFirst()

            return accumulated
                .flatMap { previousResults -> AnyPublisher<[(index: Int, post: RedditPost, topLevel: [RedditCommentModel])], Never> in
                    // Reduced delay since we're now fetching much less data (10 comments vs 100+)
                    return Just(())
                        .delay(for: .milliseconds(500), scheduler: DispatchQueue.global(qos: .userInitiated)) // Reduced to 0.5s for faster summary overview
                        .flatMap { _ in
                            monitorBatch(self.processBatch(batch: batch, batchIndex: batchIndex, topComments: topComments))
                        }
                        .map { newResults in
                            previousResults + newResults // Combine with previous results
                        }
                        .eraseToAnyPublisher()
                }
                .eraseToAnyPublisher()
        }

        let batchesWithProgress = allBatchesPublisher
            .handleEvents(
                receiveSubscription: { subscription in
                    #if os(iOS)
                    backgroundSubscription = subscription
                    #endif
                },
                receiveOutput: { _ in
                    #if os(iOS)
                    backgroundHandle?.reportProgress(fractionCompleted: 0.4)
                    #endif
                },
                receiveCompletion: { _ in
                    #if os(iOS)
                    backgroundSubscription = nil
                    #endif
                },
                receiveCancel: {
                    #if os(iOS)
                    if shouldManageHandle, let backgroundHandle {
                        backgroundHandle.finish(success: false)
                    }
                    backgroundSubscription = nil
                    #endif
                }
            )
            .eraseToAnyPublisher()

        return waitPublisher
            .flatMap { _ in batchesWithProgress }
            .map { results -> AnyPublisher<GlobalSummaryResult, Never> in
                let ordered = results.sorted { $0.index < $1.index }
                let postIds = ordered.map { $0.post.id }
                let cachedContexts = ordered.map { triple in
                    (triple.post, triple.topLevel.map { "u/\($0.author): \($0.body)" })
                }
                self.redditCommentsCacheReporter?(cachedContexts)
                let payload: [RedditPayloadItem] = ordered.map { triple in
                    // Send full comment text without truncation (already limited to top 10 comments)
                    let comments = triple.topLevel.map { "u/\($0.author): \($0.body)" }
                    return RedditPayloadItem(
                        title: triple.post.title,
                        postText: Self.firstNChars(triple.post.content, 2000),
                        topComments: comments
                    )
                }
                if payload.allSatisfy({ $0.title.isEmpty && $0.postText.isEmpty && $0.topComments.isEmpty }) {
                    let msg = "No usable Reddit content (titles/text/comments) for summarization."
                    print("❌ GlobalSummaryService: \(msg)")
                    #if os(iOS)
                    backgroundHandle?.finish(success: false)
                    #endif
                    return Just(GlobalSummaryResult.errorResult(source: "reddit", message: msg)).eraseToAnyPublisher()
                }
                print("✅ GlobalSummaryService: Prepared \(payload.count) Reddit items (title + post + ≤\(topComments) comments)")
                #if os(iOS)
                backgroundHandle?.reportProgress(fractionCompleted: 0.6)
                #endif

                let prompt = self.buildRedditPrompt(items: payload, topComments: topComments)
                #if os(iOS)
                let llmBackgroundHandle: Any? = backgroundHandle
                #else
                let llmBackgroundHandle: Any? = nil
                #endif
                return self.callLLMAndDecode(
                    source: "reddit",
                    prompt: prompt,
                    referenceIds: postIds,
                    provider: selectedProvider,
                    existingBackgroundTaskHandle: llmBackgroundHandle
                )
                    .handleEvents(
                        receiveOutput: { _ in
                            #if os(iOS)
                            backgroundHandle?.reportProgress(fractionCompleted: 0.9)
                            #endif
                        },
                        receiveCompletion: { _ in
                            #if os(iOS)
                            if shouldManageHandle, let backgroundHandle {
                                backgroundHandle.finish(success: true)
                                print("✅ GlobalSummaryService: Reddit background task completed (works when locked)")
                            }
                            #endif
                        },
                        receiveCancel: {
                            #if os(iOS)
                            if shouldManageHandle, let backgroundHandle {
                                backgroundHandle.finish(success: false)
                            }
                            #endif
                        }
                    )
                    .eraseToAnyPublisher()
            }
            .switchToLatest()
            .eraseToAnyPublisher()
    }
    
    private func buildArticlesPrompt(items: [(title: String, excerpt: String)]) -> String {
        let header = """
        Task: Generate detailed, subject-focused summaries across multiple articles.
        Requirements:
        - For each input item, produce:
          { "subject": "<short noun phrase topic>", "summary": "<2–4 sentence summary covering the main points, key details, and significance>" }
        - Preserve the original input order.
        - Output ONLY a single JSON object matching exactly:
          { "source": "articles", "summaries": [ { "subject": "...", "summary": "..." } ], "error": null }
        - Do not include code fences or commentary.
        
        Inputs (ordered):
        """
        let body = items.enumerated().map { idx, item in
            """
            Item \(idx+1):
            Title: \(item.title)
            Excerpt (≤500):
            \(item.excerpt)
            """
        }.joined(separator: "\n\n")
        let footer = """

        Output:
        - A single JSON object exactly as specified, with "source":"articles".
        """
        let prompt = [header, body, footer].joined(separator: "\n")
        print("📊 BATCH DEBUG: Building prompt for \(items.count) articles, total prompt size: \(prompt.count) chars")
        return prompt
    }
    
    private struct RedditPayloadItem {
        let title: String
        let postText: String
        let topComments: [String]
    }
    
    private func buildRedditPrompt(items: [RedditPayloadItem], topComments: Int) -> String {
        let header = """
        Task: Generate concise, subject-focused summaries across multiple Reddit posts WITH comment insights.

        CRITICAL JSON FORMAT RULES:
        - Output MUST be valid JSON - no markdown, no code fences, no commentary
        - Use ONLY standard double quotes (") for strings, not smart quotes
        - Escape any quotes inside strings with backslash
        - The exact structure must be: { "source": "reddit", "summaries": [ { "subject": "...", "summary": "..." } ], "error": null }
        - Every opening brace { MUST have a closing brace }
        - Every opening bracket [ MUST have a closing bracket ]

        Content Requirements:
        - For each input item, produce a summary object with "subject" and "summary" fields
        - Subject: Short noun phrase topic (5-8 words max)
        - Summary: 2-3 sentences that include BOTH the post's main topic AND key perspectives from comments
        - You MUST incorporate at least one significant comment insight
        - Preserve the original input order

        Inputs (there are \(items.count) items to summarize):
        """
        let body = items.enumerated().map { idx, item in
            """
            Item \(idx+1):
            Title: \(item.title)
            Post:
            \(item.postText)
            TopComments:
            \(item.topComments.enumerated().map { "  \($0+1). \($1)" }.joined(separator: "\n"))
            """
        }.joined(separator: "\n\n")
        let footer = """

        IMPORTANT: Your response must be ONLY the JSON object, nothing else. Start with { and end with }.
        The JSON must have exactly this structure with all \(items.count) summaries:
        {
          "source": "reddit",
          "summaries": [
            { "subject": "topic here", "summary": "summary here" },
            ... (repeat for all \(items.count) items)
          ],
          "error": null
        }
        """
        let prompt = [header, body, footer].joined(separator: "\n")
        print("📊 BATCH DEBUG: Building prompt for \(items.count) Reddit posts, total prompt size: \(prompt.count) chars")
        return prompt
    }

    private func callLLMAndDecode(source: String,
                                  prompt: String,
                                  referenceIds: [String] = [],
                                  provider: AppSettings.SummaryProvider,
                                  existingBackgroundTaskHandle: Any? = nil) -> AnyPublisher<GlobalSummaryResult, Never> {
        let expectedCount = referenceIds.count

        switch provider {
        case .gemini:
            print("🧠 GlobalSummaryService: Using Gemini for \(source) overall summary")
            return summaryService
                .summarizeText("", customPrompt: prompt, existingBackgroundTaskHandle: existingBackgroundTaskHandle)
                .map { raw -> GlobalSummaryResult in
                    print("📊 BATCH DEBUG: Raw LLM response length: \(raw.count) chars")
                    print("📊 BATCH DEBUG: Response preview: \(String(raw.prefix(500)))...")
                    let result = self.parseAndDecodeResponse(raw: raw, source: source, referenceIds: referenceIds)
                    print("📊 BATCH DEBUG: Parsed \(result.summaries.count) summaries from LLM response (expected \(expectedCount))")
                    if result.summaries.count < expectedCount {
                        print("⚠️ BATCH DEBUG: Missing \(expectedCount - result.summaries.count) summaries! LLM may have truncated output.")
                    }
                    return result
                }
                .eraseToAnyPublisher()

        case .appleCloud:
            print("☁️ GlobalSummaryService: Using Apple Cloud for \(source) overall summary")
            guard let cloudRequestHandler else {
                let msg = "Apple Cloud handler unavailable for overall summary."
                print("❌ GlobalSummaryService: \(msg)")
                return Just(GlobalSummaryResult.errorResult(source: source, message: msg)).eraseToAnyPublisher()
            }

            return Future<GlobalSummaryResult, Never> { promise in
                cloudRequestHandler(prompt) { raw in
                    print("📊 BATCH DEBUG: Apple Cloud response length: \(raw.count) chars")
                    print("📊 BATCH DEBUG: Apple Cloud preview: \(String(raw.prefix(500)))...")
                    let result = self.parseAppleCloudResponse(raw: raw, source: source, referenceIds: referenceIds)
                    print("📊 BATCH DEBUG: Parsed \(result.summaries.count) summaries from Apple Cloud response (expected \(expectedCount))")
                    if result.summaries.count < expectedCount {
                        print("⚠️ BATCH DEBUG: Missing \(expectedCount - result.summaries.count) summaries from Apple Cloud output.")
                    }
                    promise(.success(result))
                }
            }
            .eraseToAnyPublisher()

        case .webAI:
            let provider = settingsProvider().selectedWebAIProvider
            let title = source == "reddit" ? "Reddit Batch Summary" : "Article Batch Summary"
            print("🌐 GlobalSummaryService: Using \(provider.displayName) Web AI for \(source) overall summary")
            guard let webRequestHandler else {
                let msg = "Web AI handler unavailable for overall summary."
                print("❌ GlobalSummaryService: \(msg)")
                return Just(GlobalSummaryResult.errorResult(source: source, message: msg)).eraseToAnyPublisher()
            }

            return Future<GlobalSummaryResult, Never> { promise in
                webRequestHandler(provider, title, prompt, .strictJSON) { result in
                    switch result {
                    case .success(let raw):
                        print("📊 BATCH DEBUG: Web AI response length: \(raw.count) chars")
                        print("📊 BATCH DEBUG: Web AI preview: \(String(raw.prefix(500)))...")
                        let parsed = self.parseAppleCloudResponse(raw: raw, source: source, referenceIds: referenceIds)
                        print("📊 BATCH DEBUG: Parsed \(parsed.summaries.count) summaries from Web AI response (expected \(expectedCount))")
                        if parsed.summaries.count < expectedCount {
                            print("⚠️ BATCH DEBUG: Missing \(expectedCount - parsed.summaries.count) summaries from Web AI output.")
                        }
                        promise(.success(parsed))
                    case .failure(let error):
                        let message = error.localizedDescription
                        promise(.success(GlobalSummaryResult.errorResult(source: source, message: message)))
                    }
                }
            }
            .eraseToAnyPublisher()

        case .applePCCGateway:
            let settings = settingsProvider()
            print("☁️ GlobalSummaryService: Using Apple PCC Gateway for \(source) overall summary")
            return Future<GlobalSummaryResult, Never> { promise in
                Task(priority: .userInitiated) {
                    do {
                        let start = Date()
                        let raw = try await self.summaryService.generateContentWithPCCGateway(prompt: prompt, settings: settings)
                        let elapsed = max(0.001, Date().timeIntervalSince(start))
                        let estimatedTokens = max(1, Int(Double(raw.split(separator: " ").count) * 1.3))
                        let tokPerSec = Double(estimatedTokens) / elapsed
                        self.throughputReporter?(String(format: "Apple PCC · ~%.1f tok/s · ~%d tokens", tokPerSec, estimatedTokens))

                        print("📊 BATCH DEBUG: Apple PCC Gateway response length: \(raw.count) chars")
                        print("📊 BATCH DEBUG: Apple PCC Gateway preview: \(String(raw.prefix(500)))...")
                        let parsed = self.parseAppleCloudResponse(raw: raw, source: source, referenceIds: referenceIds)
                        print("📊 BATCH DEBUG: Parsed \(parsed.summaries.count) summaries from Apple PCC Gateway response (expected \(expectedCount))")
                        if parsed.summaries.count < expectedCount {
                            print("⚠️ BATCH DEBUG: Missing \(expectedCount - parsed.summaries.count) summaries from Apple PCC Gateway output.")
                        }
                        promise(.success(parsed))
                    } catch {
                        promise(.success(GlobalSummaryResult.errorResult(source: source, message: error.localizedDescription)))
                    }
                }
            }
            .eraseToAnyPublisher()

        case .summarizeDaemon:
            let settings = settingsProvider()
            print("⚡ GlobalSummaryService: Using Codex / Summarize for \(source) overall summary")
            return Future<GlobalSummaryResult, Never> { promise in
                Task(priority: .userInitiated) {
                    do {
                        let start = Date()
                        let raw = try await self.summaryService.generateContentWithSummarize(prompt: prompt, settings: settings)
                        let elapsed = max(0.001, Date().timeIntervalSince(start))
                        let estimatedTokens = max(1, Int(Double(raw.split(separator: " ").count) * 1.3))
                        let tokPerSec = Double(estimatedTokens) / elapsed
                        self.throughputReporter?(String(format: "Codex/Summarize · ~%.1f tok/s · ~%d tokens", tokPerSec, estimatedTokens))

                        print("📊 BATCH DEBUG: Summarize response length: \(raw.count) chars")
                        print("📊 BATCH DEBUG: Summarize preview: \(String(raw.prefix(500)))...")
                        let parsed = self.parseAppleCloudResponse(raw: raw, source: source, referenceIds: referenceIds)
                        print("📊 BATCH DEBUG: Parsed \(parsed.summaries.count) summaries from Summarize response (expected \(expectedCount))")
                        if parsed.summaries.count < expectedCount {
                            print("⚠️ BATCH DEBUG: Missing \(expectedCount - parsed.summaries.count) summaries from Summarize output.")
                        }
                        promise(.success(parsed))
                    } catch {
                        promise(.success(GlobalSummaryResult.errorResult(source: source, message: error.localizedDescription)))
                    }
                }
            }
            .eraseToAnyPublisher()

        case .appleLocal, .mlxLocal, .coreAIMLXLocal:
            let message = "\(provider.displayName) cannot run this overall-summary batch directly. Choose a remote or cloud provider from the reroute menu."
            print("⚠️ GlobalSummaryService: \(message)")
            return Just(GlobalSummaryResult.errorResult(source: source, message: message))
                .eraseToAnyPublisher()
        }
    }

    private func parseAppleCloudResponse(raw: String, source: String, referenceIds: [String]) -> GlobalSummaryResult {
        if let decoded = decodeStrictJSON(raw: raw, source: source, referenceIds: referenceIds) {
            return normalizeAppleCloudResult(decoded, source: source, referenceIds: referenceIds)
        }

        if let inner = decodeJSONStringIfNeeded(raw),
           let decoded = decodeStrictJSON(raw: inner, source: source, referenceIds: referenceIds) {
            return normalizeAppleCloudResult(decoded, source: source, referenceIds: referenceIds)
        }

        let parsed = parseAndDecodeResponse(raw: raw, source: source, referenceIds: referenceIds)
        if !parsed.summaries.isEmpty || parsed.error == nil {
            return normalizeAppleCloudResult(parsed, source: source, referenceIds: referenceIds)
        }

        if let loose = parseLooseSummaries(raw: raw, source: source, referenceIds: referenceIds) {
            return normalizeAppleCloudResult(loose, source: source, referenceIds: referenceIds)
        }

        if !isJSONLikeSummaryResponse(raw),
           let salvaged = fallbackSummaryResult(from: raw, source: source, referenceIds: referenceIds) {
            return normalizeAppleCloudResult(salvaged, source: source, referenceIds: referenceIds)
        }

        return normalizeAppleCloudResult(parsed, source: source, referenceIds: referenceIds)
    }

    private func isJSONLikeSummaryResponse(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("{")
            || trimmed.hasPrefix("[")
            || trimmed.lowercased().hasPrefix("```json")
    }

    private func normalizeAppleCloudResult(_ result: GlobalSummaryResult, source: String, referenceIds: [String]) -> GlobalSummaryResult {
        var summaries = result.summaries

        if let first = summaries.first {
            let subject = first.subject.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let summary = first.summary.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let headingTokens: Set<String> = [
                "article summaries",
                "articles summaries",
                "reddit summaries",
                "summary overview",
                "summaries",
                "article summary overview"
            ]
            if headingTokens.contains(subject) || (subject == source.lowercased() && summary.isEmpty) {
                summaries.removeFirst()
            }
        }

        if summaries.isEmpty {
            return result
        }

        if !referenceIds.isEmpty {
            let adjusted = summaries.enumerated().map { idx, item -> GlobalSummaryItem in
                let ref = referenceIds.count > idx ? referenceIds[idx] : item.referenceId
                return GlobalSummaryItem(subject: item.subject, summary: item.summary, referenceId: ref)
            }
            summaries = adjusted
        }

        return GlobalSummaryResult(source: source, summaries: summaries, error: result.error)
    }

    private func decodeJSONStringIfNeeded(_ raw: String) -> String? {
        guard let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(String.self, from: data)
    }

    private func decodeStrictJSON(raw: String, source: String, referenceIds: [String]) -> GlobalSummaryResult? {
        let cleanedResponse = cleanCloudJSON(raw)
        guard !cleanedResponse.isEmpty else { return nil }

        if let decoded = decodeJSON(cleanedResponse, source: source, referenceIds: referenceIds) {
            return decoded
        }

        if let repaired = repairClosingDelimiters(cleanedResponse),
           let decoded = decodeJSON(repaired, source: source, referenceIds: referenceIds) {
            return decoded
        }

        return nil
    }

    private func decodeJSON(_ raw: String, source: String, referenceIds: [String]) -> GlobalSummaryResult? {
        guard let data = raw.data(using: .utf8),
              var result = try? JSONDecoder().decode(GlobalSummaryResult.self, from: data) else { return nil }

        if result.source != source {
            result = GlobalSummaryResult(source: source, summaries: result.summaries, error: result.error ?? "Invalid 'source' in response.")
        }

        if !referenceIds.isEmpty && result.summaries.count == referenceIds.count {
            let adjustedSummaries = zip(result.summaries, referenceIds).map { summary, ref in
                GlobalSummaryItem(subject: summary.subject, summary: summary.summary, referenceId: ref)
            }
            result = GlobalSummaryResult(source: result.source, summaries: adjustedSummaries, error: result.error)
        }

        return result
    }

    private func repairClosingDelimiters(_ raw: String) -> String? {
        let openBraces = raw.filter { $0 == "{" }.count
        let closeBraces = raw.filter { $0 == "}" }.count
        let openBrackets = raw.filter { $0 == "[" }.count
        let closeBrackets = raw.filter { $0 == "]" }.count

        var fixed = raw
        if openBrackets > closeBrackets {
            fixed.append(String(repeating: "]", count: openBrackets - closeBrackets))
        }
        if openBraces > closeBraces {
            fixed.append(String(repeating: "}", count: openBraces - closeBraces))
        }

        return fixed == raw ? nil : fixed
    }

    private func cleanCloudJSON(_ raw: String) -> String {
        var cleanedResponse = raw
        if cleanedResponse.hasPrefix("```json") {
            cleanedResponse = String(cleanedResponse.dropFirst(7))
            if cleanedResponse.hasPrefix("\n") {
                cleanedResponse = String(cleanedResponse.dropFirst(1))
            }
        } else if cleanedResponse.hasPrefix("```") {
            cleanedResponse = String(cleanedResponse.dropFirst(3))
            if cleanedResponse.hasPrefix("\n") {
                cleanedResponse = String(cleanedResponse.dropFirst(1))
            }
        }
        if cleanedResponse.hasSuffix("```") {
            cleanedResponse = String(cleanedResponse.dropLast(3))
            if cleanedResponse.hasSuffix("\n") {
                cleanedResponse = String(cleanedResponse.dropLast(1))
            }
        }
        cleanedResponse = cleanedResponse.trimmingCharacters(in: .whitespacesAndNewlines)

        if let firstBrace = cleanedResponse.firstIndex(of: "{") {
            cleanedResponse = String(cleanedResponse[firstBrace...])
        }
        if let lastBrace = cleanedResponse.lastIndex(of: "}") {
            cleanedResponse = String(cleanedResponse[...lastBrace])
        }
        cleanedResponse = cleanedResponse.replacingOccurrences(of: "\u{201C}", with: "\"")
        cleanedResponse = cleanedResponse.replacingOccurrences(of: "\u{201D}", with: "\"")
        cleanedResponse = cleanedResponse.replacingOccurrences(of: "\u{2018}", with: "'")
        cleanedResponse = cleanedResponse.replacingOccurrences(of: "\u{2019}", with: "'")

        return cleanedResponse
    }

    private func parseLooseSummaries(raw: String, source: String, referenceIds: [String]) -> GlobalSummaryResult? {
        let pattern = "\"subject\"\\s*:\\s*\"([^\"]+)\".*?\"summary\"\\s*:\\s*\"(.*?)\""
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators, .caseInsensitive]) else {
            return nil
        }
        let ns = raw as NSString
        var matches = regex.matches(in: raw, options: [], range: NSRange(location: 0, length: ns.length))

        if matches.isEmpty {
            let unescaped = raw
                .replacingOccurrences(of: "\\\"", with: "\"")
                .replacingOccurrences(of: "\\n", with: "\n")
                .replacingOccurrences(of: "\\/", with: "/")
            let unescapedNS = unescaped as NSString
            matches = regex.matches(in: unescaped, options: [], range: NSRange(location: 0, length: unescapedNS.length))
            if matches.isEmpty { return nil }
            return buildLooseResult(matches: matches, source: source, referenceIds: referenceIds, nsString: unescapedNS)
        }

        return buildLooseResult(matches: matches, source: source, referenceIds: referenceIds, nsString: ns)
    }

    private func buildLooseResult(matches: [NSTextCheckingResult], source: String, referenceIds: [String], nsString: NSString) -> GlobalSummaryResult? {
        guard !matches.isEmpty else { return nil }

        var summaries: [GlobalSummaryItem] = []
        for (index, match) in matches.enumerated() {
            guard match.numberOfRanges >= 3 else { continue }
            let subject = nsString
                .substring(with: match.range(at: 1))
                .replacingOccurrences(of: "\\\"", with: "\"")
                .replacingOccurrences(of: "\\n", with: " ")
            let summary = nsString
                .substring(with: match.range(at: 2))
                .replacingOccurrences(of: "\\\"", with: "\"")
                .replacingOccurrences(of: "\\n", with: " ")
            let referenceId = referenceIds.count > index ? referenceIds[index] : nil
            summaries.append(GlobalSummaryItem(subject: subject, summary: summary, referenceId: referenceId))
        }

        guard !summaries.isEmpty else { return nil }
        return GlobalSummaryResult(source: source, summaries: summaries, error: nil)
    }

    /// Shared response parsing logic for both Gemini and MLX
    private func parseAndDecodeResponse(raw: String, source: String, referenceIds: [String]) -> GlobalSummaryResult {
        var cleanedResponse = raw
        if cleanedResponse.hasPrefix("```json") {
            cleanedResponse = String(cleanedResponse.dropFirst(7))
            if cleanedResponse.hasPrefix("\n") {
                cleanedResponse = String(cleanedResponse.dropFirst(1))
            }
        } else if cleanedResponse.hasPrefix("```") {
            cleanedResponse = String(cleanedResponse.dropFirst(3))
            if cleanedResponse.hasPrefix("\n") {
                cleanedResponse = String(cleanedResponse.dropFirst(1))
            }
        }
        if cleanedResponse.hasSuffix("```") {
            cleanedResponse = String(cleanedResponse.dropLast(3))
            if cleanedResponse.hasSuffix("\n") {
                cleanedResponse = String(cleanedResponse.dropLast(1))
            }
        }
        cleanedResponse = cleanedResponse.trimmingCharacters(in: .whitespacesAndNewlines)

        // Additional cleaning: Fix common JSON formatting issues
        // Remove any text before the first {
        if let firstBrace = cleanedResponse.firstIndex(of: "{") {
            cleanedResponse = String(cleanedResponse[firstBrace...])
        }
        // Remove any text after the last }
        if let lastBrace = cleanedResponse.lastIndex(of: "}") {
            cleanedResponse = String(cleanedResponse[...lastBrace])
        }
        // Fix double quotes in strings (some LLMs use smart quotes)
        cleanedResponse = cleanedResponse.replacingOccurrences(of: "\u{201C}", with: "\"") // Left double quote
        cleanedResponse = cleanedResponse.replacingOccurrences(of: "\u{201D}", with: "\"") // Right double quote
        cleanedResponse = cleanedResponse.replacingOccurrences(of: "\u{2018}", with: "'")  // Left single quote
        cleanedResponse = cleanedResponse.replacingOccurrences(of: "\u{2019}", with: "'")  // Right single quote

        let lowercased = cleanedResponse.lowercased()
        if cleanedResponse.isEmpty ||
            lowercased.hasPrefix("error:") ||
            lowercased.hasPrefix("error ") ||
            cleanedResponse == "Error generating summary" ||
            lowercased.contains("api key not configured") {
            let message = cleanedResponse.isEmpty
                ? "LLM request returned an empty response."
                : cleanedResponse
            print("❌ GlobalSummaryService: Upstream error – \(message)")
            return GlobalSummaryResult.errorResult(source: source, message: message)
        }

        guard let data = cleanedResponse.data(using: .utf8) else {
            let msg = "Invalid UTF-8 data from LLM."
            print("❌ GlobalSummaryService: \(msg)")
            return GlobalSummaryResult.errorResult(source: source, message: msg)
        }
        do {
            var result = try JSONDecoder().decode(GlobalSummaryResult.self, from: data)
            if result.source != source {
                let msg = "Invalid 'source' in response. Expected '\(source)'."
                print("⚠️ GlobalSummaryService: \(msg)")
                result = GlobalSummaryResult(source: source, summaries: result.summaries, error: msg)
            }

            // Attach reference IDs when provided
            if !referenceIds.isEmpty && result.summaries.count == referenceIds.count {
                let adjustedSummaries = zip(result.summaries, referenceIds).map { summary, ref in
                    GlobalSummaryItem(subject: summary.subject, summary: summary.summary, referenceId: ref)
                }
                return GlobalSummaryResult(source: result.source, summaries: adjustedSummaries, error: result.error)
            }
            return result
        } catch {
            // Print the full JSON for debugging
            print("❌ GlobalSummaryService: JSON Decode Error: \(error.localizedDescription)")
            print("❌ GlobalSummaryService: Raw response (first 500 chars): \(String(cleanedResponse.prefix(500)))")
            print("❌ GlobalSummaryService: Raw response (last 200 chars): \(String(cleanedResponse.suffix(200)))")

            // Check if JSON appears truncated (incomplete)
            if !cleanedResponse.hasSuffix("}") {
                let msg = "LLM response appears truncated. Try reducing the number of items or retry."
                print("❌ GlobalSummaryService: JSON truncated - missing closing brace")
                return GlobalSummaryResult.errorResult(source: source, message: msg)
            }

            // Try to provide helpful error message
            let decodingError = error as? DecodingError
            var errorDetails = error.localizedDescription

            if let decodingError = decodingError {
                switch decodingError {
                case .keyNotFound(let key, _):
                    errorDetails = "Missing required field: \(key.stringValue)"
                case .typeMismatch(let type, let context):
                    errorDetails = "Type mismatch for field: \(context.codingPath.map { $0.stringValue }.joined(separator: ".")). Expected \(type)"
                case .valueNotFound(let type, let context):
                    errorDetails = "Missing value for field: \(context.codingPath.map { $0.stringValue }.joined(separator: ".")). Expected \(type)"
                case .dataCorrupted(let context):
                    errorDetails = "Data corrupted at: \(context.codingPath.map { $0.stringValue }.joined(separator: ".")). \(context.debugDescription)"
                @unknown default:
                    break
                }
            }

            if let loose = self.parseLooseSummaries(raw: cleanedResponse, source: source, referenceIds: referenceIds) {
                print("⚠️ GlobalSummaryService: Loose JSON parser recovered \(loose.summaries.count) summaries")
                return loose
            }

            // Only treat genuine prose as prose. A malformed JSON envelope must never be shown as one summary card.
            if !self.isJSONLikeSummaryResponse(cleanedResponse),
               let fallback = self.fallbackSummaryResult(from: cleanedResponse, source: source, referenceIds: referenceIds) {
                print("⚠️ GlobalSummaryService: Fallback parser created \(fallback.summaries.count) summaries for provider output that wasn't JSON")
                return fallback
            }

            let msg = "Failed to decode JSON: \(errorDetails). This usually means the LLM didn't follow the exact format. Try again."
            print("❌ GlobalSummaryService: \(msg)")
            return GlobalSummaryResult.errorResult(source: source, message: msg)
        }
    }

    private func fallbackSummaryResult(from raw: String, source: String, referenceIds: [String]) -> GlobalSummaryResult? {
        // Attempt to salvage non-JSON output (common with some providers like Apple Intelligence)
        let normalized = raw.replacingOccurrences(of: "\r\n", with: "\n")
        let chunks = normalized
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !chunks.isEmpty else { return nil }

        var summaries: [GlobalSummaryItem] = []
        for (index, chunk) in chunks.enumerated() {
            let lines = chunk.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            guard let firstLine = lines.first else { continue }

            var subject: String = ""
            var body = chunk

            if let colonRange = firstLine.range(of: ":") {
                let leading = String(firstLine[..<colonRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                let remainder = String(firstLine[colonRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !leading.isEmpty {
                    subject = leading
                    let tailLines = ([remainder] + Array(lines.dropFirst())).filter { !$0.isEmpty }
                    body = tailLines.joined(separator: " \n")
                }
            }

            if subject.isEmpty {
                // Use the first sentence or up to 8 words as a subject fallback
                let sentenceTerminators = CharacterSet(charactersIn: ".!?\n")
                if let sentenceRange = firstLine.rangeOfCharacter(from: sentenceTerminators) {
                    subject = String(firstLine[..<sentenceRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                }
                if subject.isEmpty {
                    let words = firstLine.split(separator: " ")
                    subject = words.prefix(8).joined(separator: " ")
                }
            }

            if subject.isEmpty {
                subject = "Topic \(summaries.count + 1)"
            }

            if body.isEmpty { body = chunk }

            let referenceId: String?
            if referenceIds.count == chunks.count {
                referenceId = referenceIds[index]
            } else if referenceIds.count == summaries.count + 1 {
                referenceId = referenceIds[summaries.count]
            } else {
                referenceId = nil
            }

            summaries.append(
                GlobalSummaryItem(subject: subject, summary: body, referenceId: referenceId)
            )
        }

        guard !summaries.isEmpty else { return nil }

        return GlobalSummaryResult(
            source: source,
            summaries: summaries,
            error: nil
        )
    }

    // Helpers - made public static for MLX global summary support
    static func firstNChars(_ text: String, _ n: Int) -> String {
        if text.count <= n { return text }
        return String(text.prefix(n))
    }

    static func stripHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&[^;]+;", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    // MARK: - MLX Constants & Helpers

    private let mlxMaxOutputTokenHardCap    = 1_024
    private let coreAIMLXMaxOutputTokenHardCap = 512
    private let mlxMaxContextTokenHardCap   = LiteRTLocalService.maxContextTokens
    private let coreAIMLXMaxContextTokenHardCap = CoreAIMLXLocalService.maxContextTokens
    private let mlxAutoContextTokenFallback = LiteRTLocalService.defaultContextTokens
    private let mlxInputCharacterLimit      = 12_000
    private let mlxGenerationTimeoutSeconds: TimeInterval = 90
    private let mlxQueryTimeoutSeconds: TimeInterval      = 60

    /// Cap output tokens at the provider-specific hard limit to prevent runaway generation.
    private func cappedMLXOutputTokens(_ configured: Int) -> Int {
        let hardCap = settingsProvider().selectedSummaryProvider == .coreAIMLXLocal
            ? coreAIMLXMaxOutputTokenHardCap
            : mlxMaxOutputTokenHardCap
        return min(max(1, configured), hardCap)
    }

    /// Resolve context token count: 0 → fallback, then hard-cap at 8192.
    private func cappedMLXContextTokens(_ configured: Int) -> Int {
        let selectedProvider = settingsProvider().selectedSummaryProvider
        let fallback = selectedProvider == .coreAIMLXLocal
            ? CoreAIMLXLocalService.defaultContextTokens
            : mlxAutoContextTokenFallback
        let hardCap = selectedProvider == .coreAIMLXLocal
            ? coreAIMLXMaxContextTokenHardCap
            : mlxMaxContextTokenHardCap
        let resolved = configured > 0 ? configured : fallback
        return min(max(512, resolved), hardCap)
    }

    /// Keep local-model prompts unchanged so context-fit routing sees the same prompt the model receives.
    private func optimizedPromptForMLX(_ prompt: String) -> String {
        prompt
    }

    /// Run an async operation with a timeout. Throws MLXTimeoutError on expiry.
    private struct MLXTimeoutError: LocalizedError {
        var errorDescription: String? { "MLX generation timed out. Please try again." }
    }

    private func withMLXTimeout<T: Sendable>(
        seconds: TimeInterval,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let operationTask = Task.detached(priority: .userInitiated) {
            try await operation()
        }
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                do {
                    return try await operationTask.value
                } catch is CancellationError {
                    throw MLXTimeoutError()
                } catch {
                    throw error
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                operationTask.cancel()
                throw MLXTimeoutError()
            }
            guard let result = try await group.next() else {
                operationTask.cancel()
                throw MLXTimeoutError()
            }
            group.cancelAll()
            operationTask.cancel()
            return result
        }
    }

    // MARK: - MLX Per-Item Processing
    // MLX has limited context window, so we process items one at a time and aggregate results
    
    /// Process articles one-by-one for MLX and return aggregated GlobalSummaryResult
    private func processArticlesWithMLX(
        items: [(id: String, title: String, excerpt: String)]
    ) -> AnyPublisher<GlobalSummaryResult, Never> {
        let settings = settingsProvider()
        let useCoreAIMLX = settings.selectedSummaryProvider == .coreAIMLXLocal
        let modelID = useCoreAIMLX
            ? settings.coreAIMLXModelID.trimmingCharacters(in: .whitespacesAndNewlines)
            : settings.mlxModelID.trimmingCharacters(in: .whitespacesAndNewlines)
        let maxOutputTokens = cappedMLXOutputTokens(useCoreAIMLX ? settings.coreAIMLXMaxOutputTokens : settings.mlxMaxOutputTokens)
        let maxContextTokens = cappedMLXContextTokens(useCoreAIMLX ? settings.coreAIMLXMaxContextTokens : settings.mlxMaxContextTokens)
        let providerLabel = useCoreAIMLX ? "CoreAI MLX" : "LiteRT"

        guard !modelID.isEmpty else {
            return Just(GlobalSummaryResult.errorResult(source: "articles", message: "\(providerLabel) model id is missing. Set it in Settings -> Summary Provider."))
                .eraseToAnyPublisher()
        }

        return Future<GlobalSummaryResult, Never> { promise in
            Task {
                var summaries: [GlobalSummaryItem] = []

                print("🧠 MLX: Processing \(items.count) articles individually...")

                for (index, item) in items.enumerated() {
                    let limitedExcerpt = String(item.excerpt.prefix(2000))
                    let rawPrompt = """
                    Summarize this article in 2-3 sentences. Be concise and focus on the main point.

                    Title: \(item.title)
                    Content: \(limitedExcerpt)

                    Provide your response as:
                    Subject: [short topic phrase, 5-8 words]
                    Summary: [2-3 sentence summary]
                    """
                    let singlePrompt = self.optimizedPromptForMLX(rawPrompt)

                    do {
                        let metrics = try await self.withMLXTimeout(seconds: self.mlxGenerationTimeoutSeconds) {
                            if useCoreAIMLX {
                                return try await CoreAIMLXLocalService.shared.generateTextWithMetrics(
                                    prompt: singlePrompt,
                                    modelID: modelID,
                                    maxOutputTokens: maxOutputTokens,
                                    maxContextTokens: maxContextTokens
                                )
                            }
                            return try await LiteRTLocalService.shared.generateTextWithMetrics(
                                prompt: singlePrompt,
                                modelID: modelID,
                                maxOutputTokens: maxOutputTokens,
                                maxContextTokens: maxContextTokens
                            )
                        }
                        if useCoreAIMLX {
                            await CoreAIMLXLocalService.shared.clearTransientCache()
                        } else {
                            await LiteRTLocalService.shared.clearTransientCache()
                        }
                        self.reportThroughput(metrics)

                        let (subject, summary) = self.parseMLXSingleResponse(raw: metrics.text, fallbackTitle: item.title)
                        summaries.append(GlobalSummaryItem(subject: subject, summary: summary, referenceId: item.id))
                        print("✅ MLX: Processed article \(index + 1)/\(items.count) (\(String(format: "%.1f", metrics.tokensPerSecond)) tok/s): \(item.title.prefix(30))...")

                    } catch {
                        if useCoreAIMLX {
                            await CoreAIMLXLocalService.shared.clearTransientCache()
                        } else {
                            await LiteRTLocalService.shared.clearTransientCache()
                        }
                        print("❌ MLX: Failed article \(index + 1): \(error.localizedDescription)")
                        summaries.append(GlobalSummaryItem(
                            subject: String(item.title.prefix(50)),
                            summary: "Failed to summarize: \(error.localizedDescription)",
                            referenceId: item.id
                        ))
                    }
                }

                print("✅ MLX: Completed all \(items.count) articles")
                let result = GlobalSummaryResult(source: "articles", summaries: summaries, error: nil)
                promise(.success(result))
            }
        }.eraseToAnyPublisher()
    }
    
    /// Process Reddit posts one-by-one for MLX and return aggregated GlobalSummaryResult
    private func processRedditWithMLX(
        items: [RedditPayloadItem],
        postIds: [String]
    ) -> AnyPublisher<GlobalSummaryResult, Never> {
        let settings = settingsProvider()
        let useCoreAIMLX = settings.selectedSummaryProvider == .coreAIMLXLocal
        let modelID = useCoreAIMLX
            ? settings.coreAIMLXModelID.trimmingCharacters(in: .whitespacesAndNewlines)
            : settings.mlxModelID.trimmingCharacters(in: .whitespacesAndNewlines)
        let maxOutputTokens = cappedMLXOutputTokens(useCoreAIMLX ? settings.coreAIMLXMaxOutputTokens : settings.mlxMaxOutputTokens)
        let maxContextTokens = cappedMLXContextTokens(useCoreAIMLX ? settings.coreAIMLXMaxContextTokens : settings.mlxMaxContextTokens)
        let providerLabel = useCoreAIMLX ? "CoreAI MLX" : "LiteRT"

        guard !modelID.isEmpty else {
            return Just(GlobalSummaryResult.errorResult(source: "reddit", message: "\(providerLabel) model id is missing. Set it in Settings -> Summary Provider."))
                .eraseToAnyPublisher()
        }

        return Future<GlobalSummaryResult, Never> { promise in
            Task {
                var summaries: [GlobalSummaryItem] = []

                print("🧠 MLX: Processing \(items.count) Reddit posts individually...")

                for (index, item) in items.enumerated() {
                    let limitedPost = String(item.postText.prefix(1500))
                    let limitedComments = item.topComments.prefix(5).map { String($0.prefix(300)) }.joined(separator: "\n")

                    let rawPrompt = """
                    Summarize this Reddit post in 2-3 sentences. Include key insights from comments if relevant.

                    Title: \(item.title)
                    Post: \(limitedPost)
                    Top Comments:
                    \(limitedComments)

                    Provide your response as:
                    Subject: [short topic phrase, 5-8 words]
                    Summary: [2-3 sentence summary including comment insights]
                    """
                    let singlePrompt = self.optimizedPromptForMLX(rawPrompt)

                    do {
                        let metrics = try await self.withMLXTimeout(seconds: self.mlxGenerationTimeoutSeconds) {
                            if useCoreAIMLX {
                                return try await CoreAIMLXLocalService.shared.generateTextWithMetrics(
                                    prompt: singlePrompt,
                                    modelID: modelID,
                                    maxOutputTokens: maxOutputTokens,
                                    maxContextTokens: maxContextTokens
                                )
                            }
                            return try await LiteRTLocalService.shared.generateTextWithMetrics(
                                prompt: singlePrompt,
                                modelID: modelID,
                                maxOutputTokens: maxOutputTokens,
                                maxContextTokens: maxContextTokens
                            )
                        }
                        if useCoreAIMLX {
                            await CoreAIMLXLocalService.shared.clearTransientCache()
                        } else {
                            await LiteRTLocalService.shared.clearTransientCache()
                        }
                        self.reportThroughput(metrics)

                        let (subject, summary) = self.parseMLXSingleResponse(raw: metrics.text, fallbackTitle: item.title)
                        let refId = index < postIds.count ? postIds[index] : nil
                        summaries.append(GlobalSummaryItem(subject: subject, summary: summary, referenceId: refId))
                        print("✅ MLX: Processed post \(index + 1)/\(items.count) (\(String(format: "%.1f", metrics.tokensPerSecond)) tok/s): \(item.title.prefix(30))...")

                    } catch {
                        if useCoreAIMLX {
                            await CoreAIMLXLocalService.shared.clearTransientCache()
                        } else {
                            await LiteRTLocalService.shared.clearTransientCache()
                        }
                        print("❌ MLX: Failed post \(index + 1): \(error.localizedDescription)")
                        let refId = index < postIds.count ? postIds[index] : nil
                        summaries.append(GlobalSummaryItem(
                            subject: String(item.title.prefix(50)),
                            summary: "Failed to summarize: \(error.localizedDescription)",
                            referenceId: refId
                        ))
                    }
                }

                print("✅ MLX: Completed all \(items.count) Reddit posts")
                let result = GlobalSummaryResult(source: "reddit", summaries: summaries, error: nil)
                promise(.success(result))
            }
        }.eraseToAnyPublisher()
    }
    
    /// Parse MLX response for a single item (expects "Subject: ... Summary: ..." format)
    private func parseMLXSingleResponse(raw: String, fallbackTitle: String) -> (subject: String, summary: String) {
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        
        var subject = ""
        var summary = cleaned
        
        // Try to extract Subject: line
        if let subjectRange = cleaned.range(of: "Subject:", options: .caseInsensitive) {
            let afterSubject = String(cleaned[subjectRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            // Subject ends at newline or "Summary:"
            if let summaryStart = afterSubject.range(of: "Summary:", options: .caseInsensitive) {
                subject = String(afterSubject[..<summaryStart.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                summary = String(afterSubject[summaryStart.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            } else if let newline = afterSubject.firstIndex(of: "\n") {
                subject = String(afterSubject[..<newline]).trimmingCharacters(in: .whitespacesAndNewlines)
                summary = String(afterSubject[newline...]).trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                subject = afterSubject
            }
        } else if let summaryRange = cleaned.range(of: "Summary:", options: .caseInsensitive) {
            // No subject found, just extract summary
            summary = String(cleaned[summaryRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        
        // Fallbacks
        if subject.isEmpty {
            // Use first ~8 words of the title as subject
            let words = fallbackTitle.split(separator: " ")
            subject = words.prefix(8).joined(separator: " ")
        }
        if summary.isEmpty {
            summary = cleaned.isEmpty ? "No summary generated." : cleaned
        }
        
        // Clean up any remaining markers
        subject = subject.replacingOccurrences(of: "Summary:", with: "", options: .caseInsensitive).trimmingCharacters(in: .whitespacesAndNewlines)
        
        return (subject, summary)
    }

    // MARK: - Public Prompt Builders for MLX Support

    /// Public wrapper for buildArticlesPrompt to support MLX global summaries
    func buildArticlesPromptPublic(items: [(title: String, excerpt: String)]) -> String {
        return buildArticlesPrompt(items: items)
    }

    /// Public wrapper for buildRedditPrompt to support MLX global summaries
    func buildRedditPromptPublic(items: [(title: String, postText: String, topComments: [String])], topComments: Int) -> String {
        let payloadItems = items.map { RedditPayloadItem(title: $0.title, postText: $0.postText, topComments: $0.topComments) }
        return buildRedditPrompt(items: payloadItems, topComments: topComments)
    }
}

// Define OPMLService directly in this file
private class OPMLService {
    enum OPMLParsingError: Error {
        case invalidXML
        case unexpectedFormat
        case emptyDocument
        case fileReadError
        case securityScopedResourceAccessDenied
    }
    
    // Improved parsing with better file handling
    func loadOPMLFromFile(at url: URL) -> AnyPublisher<[Subscription], Error> {
        return Future<[Subscription], Error> { promise in
            // Start accessing security-scoped resource
            let didStartAccessing = url.startAccessingSecurityScopedResource()
            
            defer {
                // Make sure to release the security-scoped resource when finished
                if didStartAccessing {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            
            do {
                // Read file contents with more robust error handling
                guard let xmlString = try? String(contentsOf: url, encoding: .utf8) else {
                    // Try alternative encodings if UTF-8 fails
                    guard let xmlString = try? String(contentsOf: url, encoding: .isoLatin1) else {
                        throw OPMLParsingError.fileReadError
                    }
                    
                    // Process with the alternative encoding
                    let subscriptions = try self.parseOPMLString(xmlString)
                    if subscriptions.isEmpty {
                        throw OPMLParsingError.emptyDocument
                    }
                    promise(.success(subscriptions))
                    return
                }
                
                // Parse using the UTF-8 encoding
                let subscriptions = try self.parseOPMLString(xmlString)
                if subscriptions.isEmpty {
                    throw OPMLParsingError.emptyDocument
                }
                promise(.success(subscriptions))
            } catch {
                if let opmlError = error as? OPMLParsingError {
                    promise(.failure(opmlError))
                } else {
                    promise(.failure(OPMLParsingError.fileReadError))
                }
            }
        }.eraseToAnyPublisher()
    }
    
    // Separate parsing logic for better organization
    private func parseOPMLString(_ xmlString: String) throws -> [Subscription] {
        var subscriptions: [Subscription] = []
        
        // Handle different formats - sometimes OPML files might not have line breaks between outline elements
        // First try line-by-line parsing
        let lines = xmlString.components(separatedBy: .newlines)
        for line in lines {
            if line.contains("<outline") && line.contains("xmlUrl=") {
                if let subscription = extractSubscription(from: line) {
                    subscriptions.append(subscription)
                }
            }
        }
        
        // If line-by-line parsing didn't find anything, try more comprehensive parsing
        if subscriptions.isEmpty {
            // Fallback parsing - extract all outline elements with xmlUrl regardless of line breaks
            let pattern = "<outline[^>]*xmlUrl=\"([^\"]*)\"[^>]*text=\"([^\"]*)\"[^>]*"
            do {
                let regex = try NSRegularExpression(pattern: pattern, options: [])
                let nsString = xmlString as NSString
                let matches = regex.matches(in: xmlString, options: [], range: NSRange(location: 0, length: nsString.length))
                
                for match in matches {
                    if match.numberOfRanges >= 3 {
                        let urlRange = match.range(at: 1)
                        let titleRange = match.range(at: 2)
                        
                        let url = nsString.substring(with: urlRange)
                        let title = nsString.substring(with: titleRange)
                        
                        // Check if this might be a Reddit feed
                        if url.contains("reddit.com") {
                            if let subredditMatch = url.range(of: "r/([^/]+)", options: .regularExpression) {
                                let subredditName = String(url[subredditMatch])
                                    .replacingOccurrences(of: "r/", with: "")
                                let subscription = Subscription(title: title, url: subredditName, type: .reddit)
                                subscriptions.append(subscription)
                                continue
                            }
                        }
                        
                        // Regular RSS feed
                        let subscription = Subscription(title: title, url: url, type: .rss)
                        subscriptions.append(subscription)
                    }
                }
            } catch {
                throw OPMLParsingError.invalidXML
            }
        }
        
        return subscriptions
    }
    
    // Helper method to extract subscription information from a line
    private func extractSubscription(from line: String) -> Subscription? {
        // Extract title
        var title = ""
        if let titleRange = line.range(of: "title=\"([^\"]*)\"", options: .regularExpression) {
            title = String(line[titleRange])
                .replacingOccurrences(of: "title=\"", with: "")
                .replacingOccurrences(of: "\"", with: "")
        } else if let textRange = line.range(of: "text=\"([^\"]*)\"", options: .regularExpression) {
            title = String(line[textRange])
                .replacingOccurrences(of: "text=\"", with: "")
                .replacingOccurrences(of: "\"", with: "")
        } else {
            return nil // No title, skip
        }
        
        // Extract XML URL
        guard let xmlUrlRange = line.range(of: "xmlUrl=\"([^\"]*)\"", options: .regularExpression) else {
            return nil
        }
        
        let xmlUrl = String(line[xmlUrlRange])
            .replacingOccurrences(of: "xmlUrl=\"", with: "")
            .replacingOccurrences(of: "\"", with: "")
        
        // Check if this might be a Reddit feed
        if xmlUrl.contains("reddit.com") {
            // Try to extract subreddit name from URL
            if let subredditMatch = xmlUrl.range(of: "r/([^/]+)", options: .regularExpression) {
                let subredditName = String(xmlUrl[subredditMatch])
                    .replacingOccurrences(of: "r/", with: "")
                return Subscription(title: title, url: subredditName, type: .reddit)
            }
        }
        
        // Regular RSS feed
        return Subscription(title: title, url: xmlUrl, type: .rss)
    }
    
    // MARK: - OPML Export
    func exportFeedsToOPML(_ subscriptions: [Subscription]) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        let currentDate = dateFormatter.string(from: Date())
        
        let xmlHeader = """
        <?xml version="1.0" encoding="UTF-8"?>
        <opml version="2.0">
        <head>
            <title>RSS Reader Subscriptions</title>
            <dateCreated>\(currentDate)</dateCreated>
            <dateModified>\(currentDate)</dateModified>
        </head>
        <body>
        """
        
        let xmlFooter = """
        </body>
        </opml>
        """
        
        var outlines: [String] = []
        
        for subscription in subscriptions {
            let escapedTitle = escapeXMLAttribute(subscription.title)
            let xmlUrl: String
            
            switch subscription.type {
            case .rss:
                xmlUrl = escapeXMLAttribute(subscription.url)
            case .reddit:
                // Convert Reddit subscriptions to RSS format
                xmlUrl = escapeXMLAttribute("https://www.reddit.com/r/\(subscription.url).rss")
            }
            
            let outline = "    <outline text=\"\(escapedTitle)\" title=\"\(escapedTitle)\" type=\"rss\" xmlUrl=\"\(xmlUrl)\" />"
            outlines.append(outline)
        }
        
        return xmlHeader + "\n" + outlines.joined(separator: "\n") + "\n" + xmlFooter
    }
    
    private func escapeXMLAttribute(_ text: String) -> String {
        return text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}

// Define QAService directly in this file
class QAService {
    private var summaryService: SummaryService
    
    init(summaryService: SummaryService? = nil) {
        self.summaryService = summaryService ?? SummaryService()
    }
    
    func updateSummaryService(_ newSummaryService: SummaryService) {
        self.summaryService = newSummaryService
    }
    
    // For article Q&A
    func answerQuestionAboutArticle(article: Article, question: String) -> AnyPublisher<String, Never> {
        let prompt = """
        Article Title: \(article.title)
        Article Content:
        \(article.content)
        
        Based solely on the information in the article above, please answer the following question:
        \(question)
        
        If the answer cannot be determined from the article, please state that the information is not available in the article.
        """
        
        return summaryService.summarizeText("", customPrompt: prompt)
            .eraseToAnyPublisher()
    }
    
    // For Reddit post Q&A
    func answerQuestionAboutRedditPost(post: RedditPost, comments: [RedditCommentModel], question: String) -> AnyPublisher<String, Never> {
        // Extract all comment text
        let commentTexts = comments.flatMap { extractAllCommentTexts(from: $0) }
        let combinedComments = commentTexts.joined(separator: "\n\n")
        
        let prompt = """
        Reddit Post Title: \(post.title)
        Post Content:
        \(post.content)
        
        Comments:
        \(combinedComments)
        
        Based solely on the information in the Reddit post and comments above, please answer the following question:
        \(question)
        
        If the answer cannot be determined from the post or comments, please state that the information is not available.
        """
        
        return summaryService.summarizeText("", customPrompt: prompt)
            .eraseToAnyPublisher()
    }
    
    // Helper function to extract all comment texts recursively
    func extractAllCommentTexts(from comment: RedditCommentModel) -> [String] {
        var texts = ["u/\(comment.author): \(comment.body)"]

        for reply in comment.replies {
            texts.append(contentsOf: extractAllCommentTexts(from: reply))
        }

        return texts
    }
}

// MARK: - Global Summary Context
enum GlobalSummaryContext {
    case allArticles
    case allReddit(topComments: Int)
    case todayArticles
    case todayReddit(topComments: Int)
    case feedArticles(url: String)
    case subreddit(name: String, topComments: Int)
    case subredditHot(name: String, topComments: Int)
    case subredditSorted(name: String, sortOption: RedditService.SortOption, topComments: Int)
}

@MainActor
final class LocalRerouteRequest: Identifiable {
    let id = UUID()
    let message: String
    let presentationScope: LocalReroutePresentationScope

    private let routeStartHandler: @MainActor (LocalRerouteProvider) -> Void
    private let routeHandler: @MainActor (LocalRerouteProvider) -> Void
    private let cancelHandler: @MainActor () -> Void

    init(
        message: String,
        presentationScope: LocalReroutePresentationScope = .global,
        routeStartHandler: @escaping @MainActor (LocalRerouteProvider) -> Void = { _ in },
        routeHandler: @escaping @MainActor (LocalRerouteProvider) -> Void,
        cancelHandler: @escaping @MainActor () -> Void
    ) {
        self.message = message
        self.presentationScope = presentationScope
        self.routeStartHandler = routeStartHandler
        self.routeHandler = routeHandler
        self.cancelHandler = cancelHandler
    }

    func route(to provider: LocalRerouteProvider) {
        routeStartHandler(provider)
        routeHandler(provider)
    }

    func cancel() {
        cancelHandler()
    }
}

enum LocalReroutePresentationScope {
    case global
    case deepAnalysis
}

struct ScrollRestorationSnapshot: Equatable {
    let anchorID: String?
    let anchorIndex: Int
    let contentOffset: CGPoint
    let contentFingerprint: UInt64
    let containerWidth: CGFloat
    let dynamicTypeSize: String
    let horizontalSizeClass: String
}

@MainActor
class AppState: ObservableObject {
    // MARK: - Published Properties
    @Published var subscriptions: [Subscription] = []
    @Published var feeds: [Feed] = []
    @Published var redditFeeds: [RedditFeed] = []

    // Test 1: Track read state updates for UI sync debugging
    @Published var readStateRevision: Int = 0
    @Published var selectedFeed: Feed?
    @Published var selectedRedditFeed: RedditFeed?
    @Published private(set) var redditFeedStatusMessages: [String: String] = [:]
    @Published private(set) var redditRateLimitCooldowns: [String: Date] = [:]
    @Published private(set) var youtubeStatusMessages: [String: String] = [:]
    
    // Navigation state properties
    @Published var selectedArticle: Article?
    @Published var selectedRedditPost: RedditPost?
    
    // Navigation selection identifiers - these are used by NavigationLink's tag/selection
    // They must be updated in sync with the selectedArticle and selectedRedditPost
    @Published var selectedArticleId: String?
    @Published var selectedRedditPostId: String?
    
    // Track currently active subscription for back navigation
    @Published var activeSubscriptionURL: String?
    @Published var lastSelectedCategory: FeedCategory = .today
    
    // Scroll restoration is intentionally not published. Updating this cache while
    // scrolling must not invalidate the entire application view hierarchy.
    private var scrollPositions: [String: String] = [:]
    private var scrollRestorationSnapshots: [String: ScrollRestorationSnapshot] = [:]
    
    // MARK: - Navigation History
    @Published private var navigationHistory: [NavigationItem] = []
    @Published private var currentHistoryIndex: Int = -1
    
    enum NavigationItem: Equatable {
        case article(Article)
        case redditPost(RedditPost)
        
        var id: String {
            switch self {
            case .article(let article):
                return "article_\(article.id)"
            case .redditPost(let post):
                return "reddit_\(post.id)"
            }
        }
        
        static func == (lhs: NavigationItem, rhs: NavigationItem) -> Bool {
            switch (lhs, rhs) {
            case (.article(let lhsArticle), .article(let rhsArticle)):
                return lhsArticle.id == rhsArticle.id
            case (.redditPost(let lhsPost), .redditPost(let rhsPost)):
                return lhsPost.id == rhsPost.id
            default:
                return false
            }
        }
    }
    
    // Navigation history computed properties
    var canGoBack: Bool {
        currentHistoryIndex > 0
    }
    
    var canGoForward: Bool {
        currentHistoryIndex < navigationHistory.count - 1
    }
    
    // MARK: - Navigation History Methods
    func navigateBackInHistory() {
        guard canGoBack else { return }
        currentHistoryIndex -= 1
        applyHistoryItem(at: currentHistoryIndex, addToHistory: false)
    }
    
    func navigateForwardInHistory() {
        guard canGoForward else { return }
        currentHistoryIndex += 1
        applyHistoryItem(at: currentHistoryIndex, addToHistory: false)
    }
    
    private func applyHistoryItem(at index: Int, addToHistory: Bool = true) {
        guard index >= 0 && index < navigationHistory.count else { return }
        
        switch navigationHistory[index] {
        case .article(let article):
            self.selectedArticle = article
            self.selectedArticleId = article.id
            self.selectedRedditPost = nil
            self.selectedRedditPostId = nil
        case .redditPost(let post):
            self.selectedRedditPost = post
            self.selectedRedditPostId = post.id
            self.selectedArticle = nil
            self.selectedArticleId = nil
        }
    }
    
    private func addToNavigationHistory(_ item: NavigationItem) {
        // Don't add if it's the same as current item
        if currentHistoryIndex >= 0 && currentHistoryIndex < navigationHistory.count {
            if navigationHistory[currentHistoryIndex] == item {
                return
            }
        }
        
        // Remove any forward history when navigating to new item
        if currentHistoryIndex < navigationHistory.count - 1 {
            navigationHistory = Array(navigationHistory.prefix(currentHistoryIndex + 1))
        }
        
        navigationHistory.append(item)
        currentHistoryIndex = navigationHistory.count - 1
        
        // Limit history size to prevent memory issues
        if navigationHistory.count > 50 {
            navigationHistory.removeFirst()
            currentHistoryIndex = navigationHistory.count - 1
        }
    }

    private func resetNavigationHistory() {
        navigationHistory.removeAll()
        currentHistoryIndex = -1
    }
    
    // Function to fully set article selection
    func setSelectedArticle(_ article: Article?, addToHistory: Bool = true) {
        guard let article = article else {
            self.selectedArticle = nil
            self.selectedArticleId = nil
            return
        }
        
        self.selectedArticle = article
        self.selectedArticleId = article.id
        
        if addToHistory {
            addToNavigationHistory(.article(article))
        }
    }
    
    // Function to fully set reddit post selection
    func setSelectedRedditPost(_ post: RedditPost?, addToHistory: Bool = true) {
        guard let post = post else {
            self.selectedRedditPost = nil
            self.selectedRedditPostId = nil
            return
        }
        
        self.selectedRedditPost = post
        self.selectedRedditPostId = post.id
        
        if addToHistory {
            addToNavigationHistory(.redditPost(post))
        }
    }
    
    // Function to remember current subscription before navigating to article/post
    func rememberCurrentSubscription(url: String?) {
        self.activeSubscriptionURL = url
    }
    
    // Save scroll position for a subscription
    func saveScrollPosition(for subscriptionURL: String, itemID: String) {
        scrollPositions[subscriptionURL] = itemID
    }

    func saveScrollRestorationSnapshot(_ snapshot: ScrollRestorationSnapshot, for key: String) {
        scrollRestorationSnapshots[key] = snapshot
        if let anchorID = snapshot.anchorID {
            scrollPositions[key] = anchorID
        }
    }

    func scrollRestorationSnapshot(for key: String) -> ScrollRestorationSnapshot? {
        scrollRestorationSnapshots[key]
    }
    
    // Get saved scroll position for a subscription
    func getSavedScrollPosition(for subscriptionURL: String) -> String? {
        return scrollPositions[subscriptionURL]
    }
    
    // Function to clear selection and navigate back to previous subscription if available
    func navigateBack() {
        selectedArticle = nil
        selectedRedditPost = nil
        selectedArticleId = nil
        selectedRedditPostId = nil
    }
    
    func exitActiveSubscriptionView() {
        activeSubscriptionURL = nil
        selectedArticle = nil
        selectedRedditPost = nil
        selectedArticleId = nil
        selectedRedditPostId = nil
        resetNavigationHistory()
    }
    
    @Published var isLoading: Bool = false
    @Published var isRefreshingFeeds: Bool = false
    @Published private var activeArticleSummaryIDs: Set<String> = []
    @Published private var activeRedditSummaryIDs: Set<String> = []
    @Published var settings: AppSettings = AppSettings() {
        didSet {
            // Save settings when changed
            persistenceManager.saveSettings(settings)
        }
    }
    @Published var redditSortOption: RedditService.SortOption = .hot
    @Published var isSummaryFromCloud: Bool = false
    @Published var isWaitingForAppleIntelligence: Bool = false // Track when waiting for Apple Intelligence
    @Published var appleIntelligenceWaitProgress: String = "" // Progress message for Apple Intelligence
    @Published var isWaitingForArticleQA: Bool = false // Track when waiting for article Q&A
    @Published var articleQAWaitProgress: String = "" // Progress message for article Q&A
    @Published var isWaitingForRedditQA: Bool = false // Track when waiting for Reddit Q&A
    @Published var redditQAWaitProgress: String = "" // Progress message for Reddit Q&A
    @Published var isWaitingForCommentSummary: Bool = false // Track when waiting for comment summary
    @Published var commentSummaryWaitProgress: String = "" // Progress message for comment summary
    @Published var fallbackNotification: String = "" // User notification for fallback events
    @Published var showFallbackNotification: Bool = false // Whether to show fallback notification
    @Published var pendingLocalReroute: LocalRerouteRequest?
    @Published var activeWebAIHandoffRequest: WebAIHandoffRequest?
    @Published var isWebAIHandoffMinimized: Bool = false
    @Published private(set) var isWebAIBatchHandoffInProgress: Bool = false
    @Published var isGeneratingTodaySummary: Bool = false
    @Published var todaySummaryResult: String?
    @Published var todaySummaryError: String?
    @Published var todaySummaryInfo: String?

    func isSummarizingArticle(_ article: Article) -> Bool {
        activeArticleSummaryIDs.contains(article.id)
    }

    func isSummarizingRedditPost(_ post: RedditPost?) -> Bool {
        guard let post else { return false }
        return activeRedditSummaryIDs.contains(post.id)
    }

    private func beginArticleSummary(_ article: Article?) {
        guard let article else { return }
        var ids = activeArticleSummaryIDs
        ids.insert(article.id)
        activeArticleSummaryIDs = ids
    }

    private func finishArticleSummary(_ article: Article?) {
        guard let article else { return }
        var ids = activeArticleSummaryIDs
        ids.remove(article.id)
        activeArticleSummaryIDs = ids
    }

    private func beginRedditSummary(_ post: RedditPost?) {
        guard let post else { return }
        var ids = activeRedditSummaryIDs
        ids.insert(post.id)
        activeRedditSummaryIDs = ids
    }

    private func finishRedditSummary(_ post: RedditPost?) {
        guard let post else { return }
        var ids = activeRedditSummaryIDs
        ids.remove(post.id)
        activeRedditSummaryIDs = ids
    }

    private func beginSummary(article: Article?, redditPost: RedditPost?) {
        beginArticleSummary(article)
        beginRedditSummary(redditPost)
    }

    private func finishSummary(article: Article?, redditPost: RedditPost?) {
        finishArticleSummary(article)
        finishRedditSummary(redditPost)
    }
    @Published var showGlobalSummary: Bool = false
    @Published var globalSummaryJSON: String = ""
    @Published var lastGlobalSummaryError: String? = nil
    @Published var hasCachedSummary: Bool = false
    @Published private(set) var lastGlobalSummaryContext: GlobalSummaryContext?
    @Published var aggregateSummaryText: String? = nil
    @Published var isGeneratingAggregateSummary: Bool = false
    @Published var aggregateSummaryError: String? = nil
    /// Last MLX generation throughput shown in the UI (e.g. "14.3 tok/s · 38 tokens")
    @Published var mlxLastThroughput: String = ""
    @Published var mlxLastQAThroughput: String = ""
    @Published var mlxStreamingText: String = ""
#if os(iOS)
    let batchPodcastSession = BatchPodcastSession()
#endif
    private var aggregateSummaryTask: Task<Void, Never>?
    private var aggregateSummarySourceFingerprint: String?
    #if os(iOS)
    private var globalBackgroundHandle: GeminiBackgroundTaskHandle?
    #endif

    private var globalSummaryArticles: [Article] = []
    private var globalSummaryPosts: [RedditPost] = []
    private var cachedRedditCommentsForQA: [(RedditPost, [String])] = []
    @Published var isWaitingForGlobalQA: Bool = false
    @Published var globalQAWaitProgress: String = ""

    /// Closes the overview and releases source material retained only for that overview's Q&A.
    func dismissGlobalSummaryAndClearContext() {
        showGlobalSummary = false
        hasCachedSummary = false
        globalSummaryJSON = ""
        cachedRedditCommentsForQA = []
#if os(iOS)
        batchPodcastSession.invalidate()
#endif
    }

#if os(iOS)
    func presentBatchPodcast() {
        let hostA = KokoroVoice(rawValue: summaryService.getKokoroVoice()) ?? .alba
        let hostB = KokoroVoice.allCases.first(where: { $0 != hostA }) ?? .marius
        do {
            let context = try makeBatchPodcastContext(allowSummariesOnly: false)
            batchPodcastSession.present(
                context: context,
                requiresSummariesOnlyConfirmation: false,
                hostAVoice: hostA,
                hostBVoice: hostB
            )
        } catch BatchPodcastError.summariesOnlyRequiresExplicitOptIn {
            do {
                let context = try makeBatchPodcastContext(allowSummariesOnly: true)
                batchPodcastSession.present(
                    context: context,
                    requiresSummariesOnlyConfirmation: true,
                    hostAVoice: hostA,
                    hostBVoice: hostB
                )
            } catch {
                batchPodcastSession.presentError(error.localizedDescription)
            }
        } catch {
            batchPodcastSession.presentError(error.localizedDescription)
        }
    }

    func makeBatchPodcastContext(allowSummariesOnly: Bool) throws -> BatchPodcastContext {
        guard let data = globalSummaryJSON.data(using: .utf8),
              let result = try? JSONDecoder().decode(GlobalSummaryResult.self, from: data) else {
            throw BatchPodcastError.noBatchEvidence
        }
        let snapshot = BatchPodcastSnapshot(
            posts: globalSummaryPosts,
            articles: globalSummaryArticles,
            cachedComments: cachedRedditCommentsForQA,
            summaryResult: result,
            overallSummary: aggregateSummaryText
        )
        return try BatchPodcastContextBuilder.build(
            snapshot: snapshot,
            allowSummariesOnly: allowSummariesOnly
        )
    }

    private func generateBatchPodcastText(
        prompt: String,
        title: String,
        provider: AppSettings.SummaryProvider,
        backgroundTaskHandle: GeminiBackgroundTaskHandle?
    ) async throws -> String {
        switch provider {
        case .webAI:
            return try await performWebAIRequestAsync(
                title: title,
                prompt: prompt,
                responseFormat: .strictJSON
            )
        case .gemini:
            return try await summaryService.summarizeTextAsync(
                "",
                customPrompt: prompt,
                preferredBackgroundTaskIdentifier: GeminiBackgroundTaskManager.shared.taskIdentifier(for: .processing),
                existingBackgroundTaskHandle: backgroundTaskHandle
            )
        case .appleCloud:
            return await withCheckedContinuation { continuation in
                launchCloudRequest(for: prompt, type: .summary) { response in
                    continuation.resume(returning: response)
                }
            }
        case .applePCCGateway:
            return try await performPCCGatewayRequestAsync(prompt: prompt, taskName: title)
        case .summarizeDaemon:
            return try await performSummarizeRequestAsync(prompt: prompt, taskName: title)
        case .appleLocal:
#if os(iOS)
            guard #available(iOS 26.0, *), LocalSummaryService.isAvailable() else {
                throw BatchPodcastError.providerFailure(appleLocalUnavailableError().localizedDescription)
            }
            return try await generateAppleLocalStreaming(prompt: prompt)
#else
            throw BatchPodcastError.providerFailure("Apple Local is only available on iOS for this feature.")
#endif
        case .mlxLocal, .coreAIMLXLocal:
            let outputTokens = cappedMLXOutputTokens(
                provider == .coreAIMLXLocal ? settings.coreAIMLXMaxOutputTokens : settings.mlxMaxOutputTokens
            )
            let contextTokens = cappedMLXContextTokens(
                provider == .coreAIMLXLocal ? settings.coreAIMLXMaxContextTokens : settings.mlxMaxContextTokens
            )
            let metrics = try await generateLocalTextWithMetrics(
                prompt: optimizedPromptForMLX(prompt),
                systemPrompt: "Use only the supplied saved evidence. Return the requested JSON and do not invent facts.",
                maxOutputTokens: outputTokens,
                maxContextTokens: contextTokens
            )
            await clearLocalModelTransientCache()
            recordMLXThroughput(metrics)
            return metrics.text
        }
    }
#endif

    func redditPostForGlobalSummaryReference(_ referenceId: String) -> RedditPost? {
        let normalizedId = referenceId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedId.isEmpty else { return nil }

        if let post = globalSummaryPosts.first(where: { $0.id == normalizedId }) {
            return post
        }

        return redditFeeds
            .lazy
            .flatMap { $0.posts }
            .first { $0.id == normalizedId }
    }

    func articleForGlobalSummaryReference(_ referenceId: String) -> Article? {
        let normalizedId = referenceId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedId.isEmpty else { return nil }

        if let article = globalSummaryArticles.first(where: { $0.id == normalizedId }) {
            return article
        }

        return feeds
            .lazy
            .flatMap { $0.articles }
            .first { $0.id == normalizedId }
    }

    private struct ArticleReadProbe {
        let id: String
        let isRead: Bool
        let url: URL?
        let title: String
        let feedURL: String
    }

    private struct RedditReadProbe {
        let id: String
        let isRead: Bool
        let subreddit: String
        let url: URL?
    }

    private struct CloudPollDiff {
        let readState: PersistenceManager.CloudPollReadState
        let changedArticleReadByID: [String: Bool]
        let changedRedditReadByID: [String: Bool]
    }

    private let cloudPollQueue = DispatchQueue(label: "RSSReaderApp.cloud-poll", qos: .utility)
    private var isCloudPollInFlight = false

    private struct CloudUIUpdateKind: OptionSet {
        let rawValue: Int

        static let articleRead = CloudUIUpdateKind(rawValue: 1 << 0)
        static let articleFavorite = CloudUIUpdateKind(rawValue: 1 << 1)
        static let redditRead = CloudUIUpdateKind(rawValue: 1 << 2)
        static let redditFavorite = CloudUIUpdateKind(rawValue: 1 << 3)
        static let subscriptions = CloudUIUpdateKind(rawValue: 1 << 4)
    }

    private var pendingCloudUIUpdates: CloudUIUpdateKind = []
    private var cloudUIUpdateScheduled = false
    private var lastCloudSnapshot: CloudSyncManager.ReadStateSnapshot?

    // MARK: - Services
    private let feedService: FeedService
    private let youtubeService: YouTubeService
    private var youtubeQuestionHistory: [String: [String]] = [:]
    // Made internal (not private) so views can access the properly configured RedditService with OAuth
    let redditService: RedditService

    // Changed from "private var" to "internal var" so we can call it in RedditDetailView
    // Or keep it private and expose a function. But simplest is to reference it directly:
    let summaryService: SummaryService

    // NEW: A single shared CommentSummaryService that uses the same summaryService
    let commentSummaryService: CommentSummaryService

    // NEW: Add QAService for article and reddit Q&A
    let qaService: QAService
    let globalSummaryService: GlobalSummaryService

    // Reddit OAuth Manager
    let redditOAuthManager: RedditOAuthManager

    private let persistenceManager: PersistenceManager
    
    // OPML Service for importing subscriptions
    private let opmlService: OPMLService = OPMLService()
    
    // No longer using FaviconService to avoid module issues

    // MARK: - Cancellables
    var cancellables = Set<AnyCancellable>()
    private var todaySummaryCancellable: AnyCancellable?
    private struct PendingWebAIRequest {
        let title: String
        let responseFormat: WebAIResponseFormat
        let onSuccess: (String) -> Void
        let onFailure: (String) -> Void
        var automaticRetryCount: Int
        var timeoutWorkItem: DispatchWorkItem?
    }
    private var pendingWebAIRequests: [UUID: PendingWebAIRequest] = [:]
    private let webAIRequestTimeoutSeconds: TimeInterval = 210

    // MARK: - Initialization
    init(feedService: FeedService? = nil,
         redditService: RedditService? = nil,
         summaryService: SummaryService? = nil,
         persistenceManager: PersistenceManager? = nil,
         youtubeService: YouTubeService? = nil) {
        
        // 1. Initialize persistenceManager
        self.persistenceManager = persistenceManager ?? .shared

        // 2. Load settings from storage
        var loadedSettings = self.persistenceManager.loadSettings()
        let normalizedMLXModelID = LiteRTLocalService.normalizedModelIdentifier(from: loadedSettings.mlxModelID)
        if normalizedMLXModelID != loadedSettings.mlxModelID {
            loadedSettings.mlxModelID = normalizedMLXModelID
            self.persistenceManager.saveSettings(loadedSettings)
        }
        let normalizedCoreAIMLXModelID = CoreAIMLXLocalService.normalizedModelIdentifier(from: loadedSettings.coreAIMLXModelID)
        if normalizedCoreAIMLXModelID != loadedSettings.coreAIMLXModelID {
            loadedSettings.coreAIMLXModelID = normalizedCoreAIMLXModelID
            self.persistenceManager.saveSettings(loadedSettings)
        }
        loadedSettings = Self.normalizedSummarizeSettings(loadedSettings)
        self.settings = loadedSettings
        #if os(macOS)
        RSSSummarizeBridgeServer.shared.reconfigure(settings: loadedSettings)
        #endif

        // 3. Initialize Reddit OAuth Manager
        self.redditOAuthManager = RedditOAuthManager()
        loadedSettings = self.persistenceManager.loadSettings()
        self.settings = loadedSettings

        // 4. Initialize summaryService with the user's Gemini key
        let geminiKey = loadedSettings.geminiApiKey
        self.summaryService = summaryService ?? SummaryService(apiKey: geminiKey)
        self.summaryService.warmUpKokoroIfNeeded()

        // 5. Initialize the other services
        self.feedService = feedService ?? FeedService()
        self.youtubeService = youtubeService ?? .shared
        self.redditService = redditService ?? RedditService(oauthManager: self.redditOAuthManager)

        // 6. Initialize the shared CommentSummaryService with the same summaryService
        self.commentSummaryService = CommentSummaryService(summaryService: self.summaryService)

        // 7. Initialize the QA service with the same summaryService
        self.qaService = QAService(summaryService: self.summaryService)

        // 8. Initialize global summary service (uses PersistenceManager for settings to support MLX)
        self.globalSummaryService = GlobalSummaryService(summaryService: self.summaryService, redditService: self.redditService)

#if os(iOS)
        self.batchPodcastSession.configureTextGenerator(
            provider: { [weak self] in self?.settings.selectedSummaryProvider ?? .gemini },
            generator: { [weak self] prompt, title, provider, backgroundTaskHandle in
                guard let self else {
                    throw BatchPodcastError.providerFailure("The RSS Reader state is no longer available.")
                }
                return try await self.generateBatchPodcastText(
                    prompt: prompt,
                    title: title,
                    provider: provider,
                    backgroundTaskHandle: backgroundTaskHandle
                )
            }
        )
#endif

        // 9. Set up Apple Cloud handler for global summaries
        self.globalSummaryService.setCloudRequestHandler { [weak self] prompt, completion in
            self?.launchCloudRequest(for: prompt, type: .summary, completion: completion)
        }

        self.globalSummaryService.setWebRequestHandler { [weak self] provider, title, prompt, responseFormat, completion in
            guard let self else { return }
            self.enqueueWebAIRequest(
                provider: provider,
                title: title,
                prompt: prompt,
                responseFormat: responseFormat,
                onSuccess: { completion(.success($0)) },
                onFailure: { completion(.failure(NSError(domain: "WebAI", code: 1, userInfo: [NSLocalizedDescriptionKey: $0]))) }
            )
        }

        // 9b. Wire throughput reporter so GlobalSummaryService can update our @Published var
        self.globalSummaryService.setThroughputReporter { [weak self] throughput in
            Task { @MainActor [weak self] in
                self?.mlxLastThroughput = throughput
            }
        }

        // 9c. Wire warning reporter so GlobalSummaryService can surface provider-override notices
        self.globalSummaryService.setWarningReporter { [weak self] message in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.fallbackNotification = message
                self.showFallbackNotification = true
                // Auto-dismiss after 5 seconds
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                    self?.showFallbackNotification = false
                }
            }
        }

        // Reuse the exact comments extracted for the global Reddit summary. Do not fetch them again for Q&A.
        self.globalSummaryService.setRedditCommentsCacheReporter { [weak self] contexts in
            Task { @MainActor [weak self] in
                self?.cachedRedditCommentsForQA = contexts
            }
        }

        // 10. Load data from storage (subscriptions, etc.)
        loadSavedData()

        // 8. Setup refresh timer
        setupRefreshTimer()

        // 9. Setup iCloud sync listener for read/favorite state changes
        setupCloudSyncListener()

        // 10. Pre-warm MLX model if it is already the selected provider
        warmUpMLXIfNeeded()
    }

    // Manual cloud refresh (pull latest from iCloud and reapply)
    enum ManualCloudSyncState: Equatable {
        case idle
        case syncing
        case completed
    }

    @Published var manualCloudSyncState: ManualCloudSyncState = .idle
    @Published var manualCloudSyncStatusMessage: String?
    private var manualCloudStateChanged = false

    func manualCloudRefresh() {
        if manualCloudSyncState == .syncing {
            return
        }

        manualCloudSyncState = .syncing
        manualCloudStateChanged = false
        manualCloudSyncStatusMessage = "Sync requested..."
        print("☁️ AppState: Manual iCloud sync requested")
        _ = CloudSyncManager.shared.forceSynchronize()

        // Run a second pull pass because KVS propagation can land slightly after synchronize().
        let pullDelays: [TimeInterval] = [1.0, 2.5]
        let finalIndex = pullDelays.count - 1

        for (index, delay) in pullDelays.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else { return }
                _ = CloudSyncManager.shared.forceSynchronize()
                self.manualCloudStateChanged = self.persistenceManager.manualPullFromCloud(synchronize: false) || self.manualCloudStateChanged

                if index == finalIndex {
                    let shouldRefreshFeeds = self.manualCloudStateChanged
                    self.manualCloudStateChanged = false
                    let latestSubscriptions = self.persistenceManager.loadSubscriptions()
                    if self.subscriptions != latestSubscriptions {
                        self.subscriptions = latestSubscriptions
                    }
                    self.updateArticleReadStatesFromCloud()
                    self.updateArticleFavoriteStatesFromCloud()
                    self.updateRedditPostReadStatesFromCloud()
                    self.updateRedditPostFavoriteStatesFromCloud()
                    if shouldRefreshFeeds {
                        self.refreshAllFeeds()
                    }
                    self.manualCloudSyncState = .completed
                    self.manualCloudSyncStatusMessage = "Sync complete"
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                        guard let self, self.manualCloudSyncState == .completed else { return }
                        self.manualCloudSyncState = .idle
                        self.manualCloudSyncStatusMessage = nil
                    }
                    print("☁️ AppState: Manual iCloud sync complete")
                }
            }
        }
    }

    // MARK: - Cloud Sync
    private func setupCloudSyncListener() {
        // Log instance identity for debugging sync issues
        print("☁️ AppState: setupCloudSyncListener - instance=\(ObjectIdentifier(self))")

        // Subscribe to snapshot publisher (CurrentValueSubject - replays latest to late subscribers)
        CloudSyncManager.shared.snapshotPublisher
            .compactMap { $0 }  // Filter out nil
            .receive(on: DispatchQueue.main)
            .sink { [weak self] snapshot in
                guard let self else { return }
                print("☁️ AppState: Received snapshot - Articles: \(snapshot.readArticles.count), Reddit: \(snapshot.readRedditPosts.count) [instance=\(ObjectIdentifier(self))]")
                self.handleSnapshotChange(snapshot)
            }
            .store(in: &cancellables)

        // Also keep legacy publisher for individual change notifications
        CloudSyncManager.shared.remoteChangesPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] change in
                self?.handleRemoteCloudChange(change)
            }
            .store(in: &cancellables)

        // Catch-up pull: immediately fetch current state after subscribing
        // This handles any events that fired before we subscribed
        print("☁️ AppState: Performing catch-up pull after subscribing")
        CloudSyncManager.shared.publishCurrentSnapshot()

        // Fallback: Poll iCloud once per minute in case notifications don't arrive.
        // Normal cloud notifications and manual synchronization remain immediate.
        Timer.publish(every: 60, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.pollCloudForChanges()
            }
            .store(in: &cancellables)
    }

    private func handleSnapshotChange(_ snapshot: CloudSyncManager.ReadStateSnapshot) {
        // Process the full snapshot - this handles late subscriber replay
        lastCloudSnapshot = snapshot
        var updateKinds: CloudUIUpdateKind = []
        if persistenceManager.handleRemoteReadArticlesChange(snapshot.readArticles) {
            updateKinds.insert(.articleRead)
        }
        if persistenceManager.handleRemoteFavoriteArticlesChange(snapshot.favoriteArticles) {
            updateKinds.insert(.articleFavorite)
        }
        if persistenceManager.handleRemoteReadRedditPostsChange(snapshot.readRedditPosts) {
            updateKinds.insert(.redditRead)
        }
        if persistenceManager.handleRemoteFavoriteRedditPostsChange(snapshot.favoriteRedditPosts) {
            updateKinds.insert(.redditFavorite)
        }
        let hasCloudSubscriptionState = !snapshot.subscriptions.isEmpty || CloudSyncManager.shared.hasCloudSubscriptionsValue()
        if hasCloudSubscriptionState,
           persistenceManager.handleRemoteSubscriptionsChange(snapshot.subscriptions) {
            updateKinds.insert(.subscriptions)
        }
        scheduleCloudUIUpdates(updateKinds)
    }

    private func pollCloudForChanges() {
        guard !isCloudPollInFlight else { return }
        isCloudPollInFlight = true

        let articleProbes: [ArticleReadProbe] = feeds.flatMap { feed in
            feed.articles.map { article in
                ArticleReadProbe(
                    id: article.id,
                    isRead: article.isRead,
                    url: article.url,
                    title: article.title,
                    feedURL: article.feedURL
                )
            }
        }

        let redditProbes: [RedditReadProbe] = redditFeeds.flatMap { feed in
            feed.posts.map { post in
                RedditReadProbe(
                    id: post.id,
                    isRead: post.isRead,
                    subreddit: post.subreddit,
                    url: post.url
                )
            }
        }

        let persistenceManager = self.persistenceManager
        cloudPollQueue.async { [weak self] in
            let readState = persistenceManager.pullFromCloudReadState()
            let diff = AppState.computeCloudPollDiff(
                articleProbes: articleProbes,
                redditProbes: redditProbes,
                persistenceManager: persistenceManager,
                readState: readState
            )

            DispatchQueue.main.async {
                guard let self else { return }
                self.persistenceManager.applyCloudPollReadState(diff.readState)
                self.applyCloudPollDiff(diff)
                self.isCloudPollInFlight = false
            }
        }
    }

    private func handleRemoteCloudChange(_ change: CloudSyncManager.CloudSyncChange) {
        // CloudSyncManager publishes a snapshot followed by legacy events for
        // compatibility. The matching legacy event carries no new information.
        if legacyChangeMatchesLastSnapshot(change) {
            return
        }

        var updateKinds: CloudUIUpdateKind = []

        switch change {
        case .readArticles(let ids):
            if persistenceManager.handleRemoteReadArticlesChange(ids) {
                updateKinds.insert(.articleRead)
            }

        case .favoriteArticles(let ids):
            if persistenceManager.handleRemoteFavoriteArticlesChange(ids) {
                updateKinds.insert(.articleFavorite)
            }

        case .readRedditPosts(let ids):
            if persistenceManager.handleRemoteReadRedditPostsChange(ids) {
                updateKinds.insert(.redditRead)
            }

        case .favoriteRedditPosts(let ids):
            if persistenceManager.handleRemoteFavoriteRedditPostsChange(ids) {
                updateKinds.insert(.redditFavorite)
            }

        case .subscriptions(let subs):
            if persistenceManager.handleRemoteSubscriptionsChange(subs, allowEmptyCloudValue: true) {
                updateKinds.insert(.subscriptions)
            }
        }

        scheduleCloudUIUpdates(updateKinds)
    }

    private func legacyChangeMatchesLastSnapshot(_ change: CloudSyncManager.CloudSyncChange) -> Bool {
        guard let snapshot = lastCloudSnapshot else { return false }

        switch change {
        case .readArticles(let ids):
            return ids == snapshot.readArticles
        case .favoriteArticles(let ids):
            return ids == snapshot.favoriteArticles
        case .readRedditPosts(let ids):
            return ids == snapshot.readRedditPosts
        case .favoriteRedditPosts(let ids):
            return ids == snapshot.favoriteRedditPosts
        case .subscriptions(let subscriptions):
            return subscriptions == snapshot.subscriptions
        }
    }

    private func scheduleCloudUIUpdates(_ updateKinds: CloudUIUpdateKind) {
        guard !updateKinds.isEmpty else { return }

        pendingCloudUIUpdates.formUnion(updateKinds)
        guard !cloudUIUpdateScheduled else { return }

        cloudUIUpdateScheduled = true
        // Defer state mutation to the next run loop and merge snapshot + legacy
        // publisher deliveries into one targeted UI pass.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            let pendingUpdates = self.pendingCloudUIUpdates
            self.pendingCloudUIUpdates = []
            self.cloudUIUpdateScheduled = false

            if pendingUpdates.contains(.articleRead) {
                self.updateArticleReadStatesFromCloud()
            }
            if pendingUpdates.contains(.articleFavorite) {
                self.updateArticleFavoriteStatesFromCloud()
            }
            if pendingUpdates.contains(.redditRead) {
                self.updateRedditPostReadStatesFromCloud()
            }
            if pendingUpdates.contains(.redditFavorite) {
                self.updateRedditPostFavoriteStatesFromCloud()
            }
            if pendingUpdates.contains(.subscriptions) {
                let latestSubscriptions = self.persistenceManager.loadSubscriptions()
                if self.subscriptions != latestSubscriptions {
                    self.subscriptions = latestSubscriptions
                    self.refreshAllFeeds()
                }
            }
        }
    }

    private func updateArticleReadStatesFromCloud() {
        var changedCount = 0

        for feedIndex in feeds.indices {
            for articleIndex in feeds[feedIndex].articles.indices {
                let wasRead = feeds[feedIndex].articles[articleIndex].isRead
                let nowRead = persistenceManager.isArticleRead(feeds[feedIndex].articles[articleIndex])
                if wasRead != nowRead {
                    changedCount += 1
                }
                feeds[feedIndex].articles[articleIndex].isRead = nowRead
            }
        }

        // Only trigger UI update if there were actual changes (prevents infinite loops)
        if changedCount > 0 {
            objectWillChange.send()
            readStateRevision &+= 1

            // Force SwiftUI to detect the change by reassigning the array
            let updatedFeeds = feeds
            feeds = updatedFeeds
        }
    }

    private func updateArticleFavoriteStatesFromCloud() {
        var changedCount = 0
        for feedIndex in feeds.indices {
            for articleIndex in feeds[feedIndex].articles.indices {
                let id = feeds[feedIndex].articles[articleIndex].id
                let wasFavorite = feeds[feedIndex].articles[articleIndex].isFavorite
                let nowFavorite = persistenceManager.isArticleFavorite(id)
                if wasFavorite != nowFavorite {
                    changedCount += 1
                }
                feeds[feedIndex].articles[articleIndex].isFavorite = nowFavorite
            }
        }
        if changedCount > 0 {
            objectWillChange.send()
        }
    }

    /// Sync Reddit read states from persistence to in-memory array (no network call)
    /// Call this when sidebar appears to ensure badge counts are accurate
    func syncRedditReadStatesFromPersistence() {
        updateRedditPostReadStatesFromCloud()
    }

    private func updateRedditPostReadStatesFromCloud() {
        var changedCount = 0

        for feedIndex in redditFeeds.indices {
            for postIndex in redditFeeds[feedIndex].posts.indices {
                let wasRead = redditFeeds[feedIndex].posts[postIndex].isRead
                let nowRead = persistenceManager.isRedditPostRead(redditFeeds[feedIndex].posts[postIndex])
                if wasRead != nowRead {
                    changedCount += 1
                }
                redditFeeds[feedIndex].posts[postIndex].isRead = nowRead
            }
        }

        // Only trigger UI update if there were actual changes (prevents infinite loops)
        if changedCount > 0 {
            objectWillChange.send()
            readStateRevision &+= 1

            // Force SwiftUI to detect the change by reassigning the array
            let updatedFeeds = redditFeeds
            redditFeeds = updatedFeeds
        }
    }

    private func updateRedditPostFavoriteStatesFromCloud() {
        var changedCount = 0
        for feedIndex in redditFeeds.indices {
            for postIndex in redditFeeds[feedIndex].posts.indices {
                let id = redditFeeds[feedIndex].posts[postIndex].id
                let wasFavorite = redditFeeds[feedIndex].posts[postIndex].isFavorite
                let nowFavorite = persistenceManager.isRedditPostFavorite(id)
                if wasFavorite != nowFavorite {
                    changedCount += 1
                }
                redditFeeds[feedIndex].posts[postIndex].isFavorite = nowFavorite
            }
        }
        if changedCount > 0 {
            objectWillChange.send()
        }
    }

    // MARK: - Data Loading
    private func loadSavedData() {
        subscriptions = persistenceManager.loadSubscriptions()
        refreshAllFeeds()
    }

    private func setupRefreshTimer() {
        Timer.publish(every: settings.refreshInterval, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.refreshAllFeeds()
            }
            .store(in: &cancellables)
    }

    private static func computeCloudPollDiff(
        articleProbes: [ArticleReadProbe],
        redditProbes: [RedditReadProbe],
        persistenceManager: PersistenceManager,
        readState: PersistenceManager.CloudPollReadState
    ) -> CloudPollDiff {
        var changedArticleReadByID: [String: Bool] = [:]
        changedArticleReadByID.reserveCapacity(min(articleProbes.count, 512))

        for probe in articleProbes {
            let tokens = persistenceManager.readTokensForPolling(
                articleID: probe.id,
                articleURL: probe.url,
                title: probe.title,
                feedURL: probe.feedURL
            )
            let isReadNow = persistenceManager.containsReadArticle(tokens: tokens, in: readState.readArticleTokens)
            if isReadNow != probe.isRead {
                changedArticleReadByID[probe.id] = isReadNow
            }
        }

        var changedRedditReadByID: [String: Bool] = [:]
        changedRedditReadByID.reserveCapacity(min(redditProbes.count, 512))

        for probe in redditProbes {
            let tokens = persistenceManager.readTokensForPolling(
                postID: probe.id,
                subreddit: probe.subreddit,
                postURL: probe.url
            )
            let isReadNow = persistenceManager.containsReadRedditPost(tokens: tokens, in: readState.readRedditTokens)
            if isReadNow != probe.isRead {
                changedRedditReadByID[probe.id] = isReadNow
            }
        }

        return CloudPollDiff(
            readState: readState,
            changedArticleReadByID: changedArticleReadByID,
            changedRedditReadByID: changedRedditReadByID
        )
    }

    private func applyCloudPollDiff(_ diff: CloudPollDiff) {
        var didMutateArticles = false
        if !diff.changedArticleReadByID.isEmpty {
            for feedIndex in feeds.indices {
                for articleIndex in feeds[feedIndex].articles.indices {
                    let id = feeds[feedIndex].articles[articleIndex].id
                    guard let isReadNow = diff.changedArticleReadByID[id] else { continue }
                    if feeds[feedIndex].articles[articleIndex].isRead != isReadNow {
                        feeds[feedIndex].articles[articleIndex].isRead = isReadNow
                        didMutateArticles = true
                    }
                }
            }
            if didMutateArticles {
                let updatedFeeds = feeds
                feeds = updatedFeeds
            }
        }

        var didMutateReddit = false
        if !diff.changedRedditReadByID.isEmpty {
            for feedIndex in redditFeeds.indices {
                for postIndex in redditFeeds[feedIndex].posts.indices {
                    let id = redditFeeds[feedIndex].posts[postIndex].id
                    guard let isReadNow = diff.changedRedditReadByID[id] else { continue }
                    if redditFeeds[feedIndex].posts[postIndex].isRead != isReadNow {
                        redditFeeds[feedIndex].posts[postIndex].isRead = isReadNow
                        didMutateReddit = true
                    }
                }
            }
            if didMutateReddit {
                let updatedFeeds = redditFeeds
                redditFeeds = updatedFeeds
            }
        }

        if didMutateArticles || didMutateReddit {
            readStateRevision &+= 1
        }
    }

    // MARK: - Feed Management
    private func fetchArticleFeed(for subscription: Subscription) -> AnyPublisher<Feed, Never> {
        guard settings.youtubeSupportEnabled, subscription.isYouTubeChannel else {
            return feedService.fetchFeed(url: subscription.url)
        }

        return Deferred { [weak self] in
            Future<Feed, Error> { promise in
                Task { @MainActor [weak self] in
                    guard let self else {
                        promise(.failure(YouTubeSupportError.channelUnavailable))
                        return
                    }
                    do {
                        let feed = try await self.youtubeService.fetchChannelFeed(urlString: subscription.url)
                        self.youtubeStatusMessages[subscription.url] = nil
                        promise(.success(feed))
                    } catch {
                        self.youtubeStatusMessages[subscription.url] = error.localizedDescription
                        promise(.failure(error))
                    }
                }
            }
        }
        .catch { _ in Empty<Feed, Never>() }
        .eraseToAnyPublisher()
    }

    func searchYouTubeChannels(_ query: String) async throws -> [YouTubeChannelSearchResult] {
        guard settings.youtubeSupportEnabled else { return [] }
        return try await youtubeService.searchChannels(query: query)
    }

    func addYouTubeSubscription(_ channel: YouTubeChannelSearchResult) async throws {
        guard settings.youtubeSupportEnabled else { return }
        let subscription = Subscription(title: channel.title, url: channel.feedURL, type: .rss)
        guard !subscriptions.contains(where: { $0.canonicalKey == subscription.canonicalKey }) else {
            throw NSError(domain: "YouTube", code: 409, userInfo: [NSLocalizedDescriptionKey: "You are already subscribed to this YouTube channel."])
        }

        // Validate and load the public Atom feed before persisting the channel.
        var feed = try await youtubeService.fetchChannelFeed(urlString: channel.feedURL)
        for index in feed.articles.indices {
            feed.articles[index].isRead = persistenceManager.isArticleRead(feed.articles[index])
            feed.articles[index].isFavorite = persistenceManager.isArticleFavorite(feed.articles[index].id) ?? false
        }
        subscriptions.append(subscription)
        persistenceManager.saveSubscriptions(subscriptions)
        feeds.removeAll { $0.url == channel.feedURL }
        feeds.append(feed)
        youtubeStatusMessages[channel.feedURL] = nil
    }

    func refreshAllFeeds() {
        isLoading = true
        isRefreshingFeeds = true
        let group = DispatchGroup()

        // Refresh RSS feeds
        for subscription in subscriptions where subscription.type == .rss {
            group.enter()
                fetchArticleFeed(for: subscription)
                    .receive(on: RunLoop.main)
                    .sink(receiveCompletion: { _ in
                    group.leave()
                }, receiveValue: { [weak self] feed in
                    // Apply read and favorite status from persistence
                    var processedFeed = feed
                    let existingSummaries = self?.feeds
                        .first(where: { $0.url == feed.url })?
                        .articles
                        .reduce(into: [String: String]()) { result, article in
                            if let summary = article.summary, !summary.isEmpty {
                                result[article.id] = summary
                            }
                        } ?? [:]
                    for i in 0..<processedFeed.articles.count {
                        processedFeed.articles[i].isRead = self?.persistenceManager.isArticleRead(processedFeed.articles[i]) ?? false
                        processedFeed.articles[i].isFavorite = self?.persistenceManager.isArticleFavorite(processedFeed.articles[i].id) ?? false
                        if processedFeed.articles[i].summary == nil {
                            processedFeed.articles[i].summary = existingSummaries[processedFeed.articles[i].id]
                        }
                    }
                    
                    if let index = self?.feeds.firstIndex(where: { $0.url == subscription.url }) {
                        self?.feeds[index] = processedFeed
                    } else {
                        self?.feeds.append(processedFeed)
                    }
                })
                .store(in: &cancellables)
        }

        // Refresh Reddit feeds
        refreshRedditFeeds(in: group)

        group.notify(queue: .main) { [weak self] in
            guard let self else { return }
            self.isLoading = false
            self.isRefreshingFeeds = false
            self.scheduleLatestNewsSnapshotIfSupported()

            // Re-sync Reddit read states after all feeds loaded
            // This catches any cloud sync data that arrived during refresh
            self.syncRedditReadStatesFromPersistence()
        }
    }

    // Specific function to refresh a single RSS feed (mimics up arrow behavior)
    func refreshSingleRSSFeed(url: String) {
        isLoading = true
        isRefreshingFeeds = true
        let subscription = subscriptions.first(where: { $0.type == .rss && $0.url == url })
            ?? Subscription(title: "RSS", url: url, type: .rss)
        fetchArticleFeed(for: subscription)
            .receive(on: RunLoop.main)
            .sink(receiveCompletion: { [weak self] _ in
                self?.isLoading = false
                self?.isRefreshingFeeds = false
            }, receiveValue: { [weak self] feed in
                guard let self = self else { return }
                var processedFeed = feed
                let existingSummaries = self.feeds
                    .first(where: { $0.url == url })?
                    .articles
                    .reduce(into: [String: String]()) { result, article in
                        if let summary = article.summary, !summary.isEmpty {
                            result[article.id] = summary
                        }
                    } ?? [:]
                for i in 0..<processedFeed.articles.count {
                    let id = processedFeed.articles[i].id
                    processedFeed.articles[i].isRead = self.persistenceManager.isArticleRead(processedFeed.articles[i])
                    processedFeed.articles[i].isFavorite = self.persistenceManager.isArticleFavorite(id) ?? false
                    if processedFeed.articles[i].summary == nil {
                        processedFeed.articles[i].summary = existingSummaries[id]
                    }
                }
                if let index = self.feeds.firstIndex(where: { $0.url == url }) {
                    self.feeds[index] = processedFeed
                } else {
                    self.feeds.append(processedFeed)
                }
            })
            .store(in: &cancellables)
    }

    // Specific function to refresh just Reddit feeds
    func refreshRedditFeeds(specificSubreddit: String? = nil, in existingGroup: DispatchGroup? = nil) {
        let group = existingGroup ?? DispatchGroup()
        
        if existingGroup == nil {
            isLoading = true
        }

        pruneExpiredRedditCooldowns()
        
        // Log the refresh operation
        if let specificSubreddit = specificSubreddit {
            print("📱 AppState: Refreshing specific Reddit feed: r/\(specificSubreddit) with sort option: \(redditSortOption.rawValue)")
        } else {
            print("📱 AppState: Refreshing ALL Reddit feeds with sort option: \(redditSortOption.rawValue)")
        }
        
        // Filter subscriptions if a specific subreddit is requested
        let redditSubscriptions: [Subscription]
        if let specificSubreddit = specificSubreddit {
            redditSubscriptions = subscriptions.filter { $0.type == .reddit && $0.url == specificSubreddit }
        } else {
            redditSubscriptions = subscriptions.filter { $0.type == .reddit }
        }
        
        print("📱 AppState: Found \(redditSubscriptions.count) Reddit subscriptions to refresh")
        
        // Refresh Reddit feeds
        for subscription in redditSubscriptions {
            group.enter()
            
            // Create a temporary feed object with loading state if needed
            if redditFeeds.firstIndex(where: { $0.subreddit == subscription.url }) == nil {
                // Add a temporary placeholder feed to show loading state
                let tempFeed = RedditFeed(subreddit: subscription.url, displayName: "Loading...", posts: [])
                self.redditFeeds.append(tempFeed)
                print("📱 AppState: Created temporary feed for r/\(subscription.url)")
            }
            
            redditService.fetchSubreddit(subreddit: subscription.url, sortOption: redditSortOption)
                .receive(on: RunLoop.main)
                .sink(receiveCompletion: { completion in
                    group.leave()
                }, receiveValue: { [weak self] redditFeed in
                    guard let self = self else { return }
                    
                    var processedFeed = redditFeed

                    // Record any status message (e.g., rate limit warnings)
                    if let message = processedFeed.fetchStatusMessage, !message.isEmpty {
                        self.redditFeedStatusMessages[subscription.url] = message
                    } else {
                        self.redditFeedStatusMessages.removeValue(forKey: subscription.url)
                    }

                    if let cooldownUntil = processedFeed.rateLimitCooldownUntil, cooldownUntil > Date() {
                        self.redditRateLimitCooldowns[subscription.url] = cooldownUntil
                    } else {
                        self.redditRateLimitCooldowns.removeValue(forKey: subscription.url)
                    }
                    
                    // Apply read and favorite status from persistence
                    let existingSummaries = self.redditFeeds
                        .first(where: { $0.subreddit == redditFeed.subreddit })?
                        .posts
                        .reduce(into: [String: String]()) { result, post in
                            if let summary = post.summary, !summary.isEmpty {
                                result[post.id] = summary
                            }
                        } ?? [:]
                    #if DEBUG
                    var restoredReadIds: [String] = []
                    var stillUnreadIds: [String] = []
                    #endif
                    for i in 0..<processedFeed.posts.count {
                        let id = processedFeed.posts[i].id
                        let persistedRead = self.persistenceManager.isRedditPostRead(processedFeed.posts[i])
                        processedFeed.posts[i].isRead = persistedRead
                        #if DEBUG
                        if persistedRead {
                            restoredReadIds.append(id)
                        } else {
                            stillUnreadIds.append(id)
                        }
                        #endif
                        processedFeed.posts[i].isFavorite = self.persistenceManager.isRedditPostFavorite(id) ?? false
                        if processedFeed.posts[i].summary == nil {
                            processedFeed.posts[i].summary = existingSummaries[id]
                        }
                    }
                    
                    #if DEBUG
                    if !restoredReadIds.isEmpty {
                        let sample = Array(restoredReadIds.prefix(10))
                        print("🧪 RefreshRedditFeeds: Restored \(restoredReadIds.count) read posts for r/\(subscription.url). Sample IDs: \(sample)")
                    }
                    if !stillUnreadIds.isEmpty {
                        let sample = Array(stillUnreadIds.prefix(10))
                        print("🧪 RefreshRedditFeeds: \(stillUnreadIds.count) posts currently unread after hydration for r/\(subscription.url). Sample IDs: \(sample)")
                    }
                    #endif

                    // Sort posts: stickied posts first, then by date (newest first) for "New" sort
                    // For "Hot" sort, Reddit's API order is already correct (by hotness algorithm)
                    if self.redditSortOption == .new {
                        let stickied = processedFeed.posts.filter { $0.isStickied }
                        let nonStickied = processedFeed.posts.filter { !$0.isStickied }
                            .sorted { $0.publishDate > $1.publishDate }
                        processedFeed.posts = stickied + nonStickied
                        print("📱 AppState: Sorted posts for 'New' - \(stickied.count) stickied, \(nonStickied.count) by date")
                    }

                    print("📱 AppState: Received feed for r/\(subscription.url) with \(processedFeed.posts.count) posts")

                    // CRITICAL FIX: Don't replace existing feed with empty data
                    // This prevents the bug where posts disappear after summaries
                    if let index = self.redditFeeds.firstIndex(where: { $0.subreddit == subscription.url }) {
                        let existingFeed = self.redditFeeds[index]

                        // Only update if new feed has data OR if existing feed was empty/loading
                        if processedFeed.posts.isEmpty && !existingFeed.posts.isEmpty {
                            print("⚠️ AppState: Refusing to replace \(existingFeed.posts.count) existing posts with empty feed for r/\(subscription.url)")
                            print("⚠️ AppState: This is likely due to Reddit API rate limiting. Keeping existing data.")
                            // Don't update the feed - keep the existing one
                        } else {
                            print("📱 AppState: Updating existing feed at index \(index)")
                            // Create a new array with the updated feed to trigger UI refresh
                            var updatedFeeds = self.redditFeeds
                            updatedFeeds[index] = processedFeed
                            self.redditFeeds = updatedFeeds // This should trigger UI refresh
                            print("📱 AppState: Feed array updated with new content, sort option: \(self.redditSortOption.rawValue)")
                        }
                    } else {
                        print("📱 AppState: Adding new feed to collection")
                        self.redditFeeds.append(processedFeed)
                    }
                    
                    // Force UI update by re-publishing the current selected Reddit post if it's from this feed
                    if let selectedPost = self.selectedRedditPost, selectedPost.subreddit == subscription.url {
                        if var updatedPost = processedFeed.posts.first(where: { $0.id == selectedPost.id }) {
                            if updatedPost.summary == nil {
                                updatedPost.summary = selectedPost.summary
                            }
                            print("📱 AppState: Re-publishing selected post")
                            self.selectedRedditPost = updatedPost
                        } else {
                            print("⚠️ AppState: Selected post no longer exists in the updated feed")
                        }
                    }
                })
                .store(in: &cancellables)
        }
        
        if existingGroup == nil {
            group.notify(queue: .main) { [weak self] in
                guard let self else { return }
                self.isLoading = false
                self.scheduleLatestNewsSnapshotIfSupported()
            }
        }
    }

#if canImport(WidgetKit)
    private func scheduleLatestNewsSnapshotIfSupported() {
        guard #available(iOS 14.0, macOS 11.0, *) else { return }

        let articleFeedsSnapshot = feeds
        let redditFeedsSnapshot = redditFeeds

        Task(priority: .utility) {
            guard let snapshot = await LatestNewsSnapshotBuilder.buildSnapshot(
                fromFeeds: articleFeedsSnapshot,
                redditFeeds: redditFeedsSnapshot
            ) else {
                print("ℹ️ AppState: No latest news snapshot generated (no content).")
                return
            }

            await MainActor.run {
                LatestNewsStore.shared.save(snapshot)
                WidgetCenter.shared.reloadTimelines(ofKind: "LatestNewsWidget")
                WidgetCenter.shared.reloadAllTimelines()
            }
        }
    }
#else
    private func scheduleLatestNewsSnapshotIfSupported() {}
#endif

    private func pruneExpiredRedditCooldowns() {
        let now = Date()
        let filtered = redditRateLimitCooldowns.filter { $0.value > now }
        if filtered.count != redditRateLimitCooldowns.count {
            redditRateLimitCooldowns = filtered
        }
    }

    private func activeCooldowns(forSubreddits subreddits: Set<String>) -> [(String, Date)] {
        pruneExpiredRedditCooldowns()
        let now = Date()
        return subreddits.compactMap { subreddit in
            guard let expiry = redditRateLimitCooldowns[subreddit], expiry > now else { return nil }
            return (subreddit, expiry)
        }.sorted { $0.1 < $1.1 }
    }

    private func formatCooldownDuration(_ seconds: TimeInterval) -> String {
        let clampedSeconds = max(0, Int(ceil(seconds)))
        let hours = clampedSeconds / 3600
        let minutes = (clampedSeconds % 3600) / 60
        let secs = clampedSeconds % 60

        var components: [String] = []
        if hours > 0 { components.append("\(hours)h") }
        if minutes > 0 { components.append("\(minutes)m") }
        if secs > 0 || components.isEmpty { components.append("\(secs)s") }
        return components.joined(separator: " ")
    }

    private func formatCooldownReadyTime(_ date: Date) -> String {
        DateFormatter.localizedString(from: date, dateStyle: .none, timeStyle: .short)
    }

    private func makeCooldownMessage(for entries: [(String, Date)]) -> String {
        guard let first = entries.first else {
            return "Reddit API cooldown active. Please try again shortly."
        }

        let earliestSeconds = max(first.1.timeIntervalSinceNow, 0)
        let durationText = formatCooldownDuration(earliestSeconds)
        let readyText = formatCooldownReadyTime(first.1)

        if entries.count == 1 {
            return "Reddit API cooldown active for r/\(first.0). Next refresh available in \(durationText) (~\(readyText))."
        }

        let subredditNames = entries.map { "r/\($0.0)" }
        let highlighted: String
        if entries.count == 2 {
            highlighted = subredditNames.joined(separator: " and ")
        } else {
            highlighted = "\(subredditNames[0]), \(subredditNames[1]), +\(entries.count - 2) more"
        }

        return "Reddit API cooldown active for \(highlighted). Earliest refresh in \(durationText) (~\(readyText))."
    }

    private func handleRedditSummaryCooldown(entries: [(String, Date)]) {
        let message = makeCooldownMessage(for: entries)
        lastGlobalSummaryError = message
        let escaped = message.replacingOccurrences(of: "\"", with: "\\\"")
        globalSummaryJSON = "{\"source\":\"reddit\",\"summaries\":[],\"error\":\"\(escaped)\"}"
        hasCachedSummary = false
        showGlobalSummary = true
        isLoading = false
    }

    // MARK: - Subscription Management
    func addSubscription(title: String, url: String, type: SubscriptionType) {
        let subscription = Subscription(title: title, url: url, type: type)
        subscriptions.append(subscription)
        persistenceManager.saveSubscriptions(subscriptions)

        // Fetch the new feed
        if type == .rss {
            fetchArticleFeed(for: subscription)
                .receive(on: RunLoop.main)
                .sink(receiveCompletion: { _ in },
                      receiveValue: { [weak self] feed in
                    // Apply read and favorite status for new subscriptions too
                    var processedFeed = feed
                    for i in 0..<processedFeed.articles.count {
                        processedFeed.articles[i].isRead = self?.persistenceManager.isArticleRead(processedFeed.articles[i]) ?? false
                        processedFeed.articles[i].isFavorite = self?.persistenceManager.isArticleFavorite(processedFeed.articles[i].id) ?? false
                    }
                    self?.feeds.append(processedFeed)
                })
                .store(in: &cancellables)
        } else {
            redditService.fetchSubreddit(subreddit: url, sortOption: redditSortOption)
                .receive(on: RunLoop.main)
                .sink(receiveCompletion: { _ in },
                      receiveValue: { [weak self] redditFeed in
                    guard let self = self else { return }
                    
                    // Apply read and favorite status for new Reddit subscriptions too
                    var processedFeed = redditFeed
                    for i in 0..<processedFeed.posts.count {
                        let id = processedFeed.posts[i].id
                        processedFeed.posts[i].isRead = self.persistenceManager.isRedditPostRead(processedFeed.posts[i])
                        processedFeed.posts[i].isFavorite = self.persistenceManager.isRedditPostFavorite(id) ?? false
                    }
                    // Sort posts: stickied first, then by date for "New" sort
                    if self.redditSortOption == .new {
                        let stickied = processedFeed.posts.filter { $0.isStickied }
                        let nonStickied = processedFeed.posts.filter { !$0.isStickied }
                            .sorted { $0.publishDate > $1.publishDate }
                        processedFeed.posts = stickied + nonStickied
                    }
                    self.redditFeeds.append(processedFeed)
                })
                .store(in: &cancellables)
        }
    }

    func removeSubscription(at indexSet: IndexSet) {
        let subscriptionsToRemove = indexSet.map { subscriptions[$0] }

        for subscription in subscriptionsToRemove {
            if subscription.type == .rss {
                feeds.removeAll { $0.url == subscription.url }
            } else {
                redditFeeds.removeAll { $0.subreddit == subscription.url }
            }
        }

        subscriptions.remove(atOffsets: indexSet)
        persistenceManager.saveSubscriptions(subscriptions)
    }

    // MARK: - Article Management
    func markArticleAsRead(_ article: Article) {
        print("📖 markArticleAsRead called - id=\(article.id.prefix(50)), feedURL=\(article.feedURL ?? "nil")")
        print("   feeds.count=\(feeds.count), feeds.urls=\(feeds.map { $0.url })")

        if let feedIndex = feeds.firstIndex(where: { $0.url == article.feedURL }),
           let articleIndex = feeds[feedIndex].articles.firstIndex(where: { $0.id == article.id }) {
            let wasRead = feeds[feedIndex].articles[articleIndex].isRead
            feeds[feedIndex].articles[articleIndex].isRead = true
            persistenceManager.markArticleAsRead(feeds[feedIndex].articles[articleIndex])
            print("📖 ✅ Found article - feedIndex=\(feedIndex), articleIndex=\(articleIndex), wasRead=\(wasRead) → isRead=true")

            // Ensure the navigation state is consistent
            if selectedArticle?.id == article.id {
                // Use the consistent setter function
                setSelectedArticle(feeds[feedIndex].articles[articleIndex])
            }
        } else {
            // FALLBACK: Article not found in feeds, but still persist the read state
            print("📖 ⚠️ Article NOT found in feeds! Persisting anyway...")
            persistenceManager.markArticleAsRead(article)
        }
    }

    func toggleArticleFavorite(_ article: Article) {
        if let feedIndex = feeds.firstIndex(where: { $0.url == article.feedURL }),
           let articleIndex = feeds[feedIndex].articles.firstIndex(where: { $0.id == article.id }) {
            let isFavorite = !feeds[feedIndex].articles[articleIndex].isFavorite
            feeds[feedIndex].articles[articleIndex].isFavorite = isFavorite

            if isFavorite {
                persistenceManager.addFavoriteArticle(article.id)
            } else {
                persistenceManager.removeFavoriteArticle(article.id)
            }
            
            // Ensure the navigation state is consistent if this is the currently selected article
            if selectedArticle?.id == article.id {
                setSelectedArticle(feeds[feedIndex].articles[articleIndex])
            }
        }
    }

    func summarizeArticle(_ article: Article) {
        // Check if we should use Apple Intelligence instead
        if settings.selectedSummaryProvider != .gemini {
            // Don't use Gemini, let the UI handle it
            print("📱 AppState: Summary provider is set to \(settings.selectedSummaryProvider.rawValue), not using Gemini")
            return
        }

        isLoading = true
        beginArticleSummary(article)
        
        let articlePrompt = geminiArticleSummaryPrompt(for: article)

        summaryService.summarizeText(article.content, customPrompt: articlePrompt)
            .receive(on: RunLoop.main)
            .sink { [weak self] summary in
                guard let self = self else { return }
                
                if let feedIndex = self.feeds.firstIndex(where: { $0.url == article.feedURL }),
                   let articleIndex = self.feeds[feedIndex].articles.firstIndex(where: { $0.id == article.id }) {
                    
                    // First, create a mutable copy of the article to update
                    var articleToUpdate = self.feeds[feedIndex].articles[articleIndex]
                    
                    // Update the article with the summary
                    let cleanedSummary = self.cleanAndFormatSummaryTextForDisplay(summary)
                    articleToUpdate.summary = cleanedSummary
                    
                    // Update the article in the feeds array
                    self.feeds[feedIndex].articles[articleIndex] = articleToUpdate
                    
                    // If this is the currently selected article, update the selection
                    if self.selectedArticle?.id == article.id {
                        self.selectedArticle = articleToUpdate
                        print("📱 AppState: Updated article summary for article ID: \(article.id)")
                    }
                }
                self.finishArticleSummary(article)
                self.isLoading = false
            }
            .store(in: &cancellables)
    }

    // MARK: - Reddit Post Management
    func markRedditPostAsRead(_ post: RedditPost) {
        print("📖 markRedditPostAsRead called - id=\(post.id.prefix(50))")
        if let feedIndex = redditFeeds.firstIndex(where: { $0.subreddit == post.subreddit }),
           let postIndex = redditFeeds[feedIndex].posts.firstIndex(where: { $0.id == post.id }) {
            redditFeeds[feedIndex].posts[postIndex].isRead = true
            persistenceManager.markRedditPostAsRead(redditFeeds[feedIndex].posts[postIndex])
            
            // Ensure the navigation state is consistent
            if selectedRedditPost?.id == post.id {
                // Use the consistent setter function
                setSelectedRedditPost(redditFeeds[feedIndex].posts[postIndex])
            }
        }
    }

    func toggleRedditPostFavorite(_ post: RedditPost) {
        if let feedIndex = redditFeeds.firstIndex(where: { $0.subreddit == post.subreddit }),
           let postIndex = redditFeeds[feedIndex].posts.firstIndex(where: { $0.id == post.id }) {
            let isFavorite = !redditFeeds[feedIndex].posts[postIndex].isFavorite
            redditFeeds[feedIndex].posts[postIndex].isFavorite = isFavorite

            if isFavorite {
                persistenceManager.addFavoriteRedditPost(post.id)
            } else {
                persistenceManager.removeFavoriteRedditPost(post.id)
            }
            
            // Ensure the navigation state is consistent if this is the currently selected post
            if selectedRedditPost?.id == post.id {
                setSelectedRedditPost(redditFeeds[feedIndex].posts[postIndex])
            }
        }
    }

    func summarizeRedditPost(_ post: RedditPost, comments: [RedditCommentModel] = []) {
        // Check if we should use Apple Intelligence instead
        if settings.selectedSummaryProvider != .gemini {
            // Don't use Gemini, let the UI handle it
            print("📱 AppState: Summary provider is set to \(settings.selectedSummaryProvider.rawValue), not using Gemini")
            return
        }

        isLoading = true
        beginRedditSummary(post)

        let commentTexts = comments.flatMap { extractAllCommentTexts(from: $0) }
        let combinedComments = commentTexts.joined(separator: "\n\n")

        let redditPostPrompt = """
        Reddit Post Title: \(post.title)
        Post Content:
        \(post.content)

        Comments:
        \(combinedComments)

        Provide a concise, 3 paragraph summary maximum, of the following Reddit post and its comments. First paragraph should cover the main post topic and content. Following paragraphs should highlight key themes and viewpoints present in the discussion in the comments section. Ensure the summary is clear and provide a final summary.
        Output plain text only (no markdown symbols like #, *, _, or `).
        """

        summaryService.summarizeText("", customPrompt: redditPostPrompt)
            .receive(on: RunLoop.main)
            .sink { [weak self] summary in
                guard let self = self else { return }
                
                if let feedIndex = self.redditFeeds.firstIndex(where: { $0.subreddit == post.subreddit }),
                   let postIndex = self.redditFeeds[feedIndex].posts.firstIndex(where: { $0.id == post.id }) {
                    
                    // First, create a mutable copy of the post to update
                    var postToUpdate = self.redditFeeds[feedIndex].posts[postIndex]
                    
                    // Update the post with a markdown-artifact-free summary
                    let cleanedSummary = self.cleanMarkdownArtifactsForDisplay(summary)
                    postToUpdate.summary = cleanedSummary
                    
                    // Update the post in the redditFeeds array
                    self.redditFeeds[feedIndex].posts[postIndex] = postToUpdate

                    // If this is the currently selected post, update the selection
                    if self.selectedRedditPost?.id == post.id {
                        self.selectedRedditPost = postToUpdate
                        print("📱 AppState: Updated Reddit post summary for post ID: \(post.id)")
                    }
                }
                self.finishRedditSummary(post)
                self.isLoading = false
            }
            .store(in: &cancellables)
    }
    
    private func presentWebAIHandoff(prompt: String, title: String) {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            showWebAIStatus("Nothing to send to \(settings.selectedWebAIProvider.displayName) yet.")
            return
        }

        let displacedCompletion = displaceActiveWebAIRequestIfNeeded(replacingWith: title)

        let request = WebAIHandoffRequest(
            provider: settings.selectedWebAIProvider,
            title: title,
            prompt: trimmed,
            responseFormat: .plainText,
            shouldAutoCapture: false,
            shouldStartMinimized: true
        )
        isWebAIHandoffMinimized = request.shouldStartMinimized
        activeWebAIHandoffRequest = request
        displacedCompletion?()
    }

    func openWebAILoginSession(for provider: WebAIProvider) {
        let title = "\(provider.displayName) Login"
        let displacedCompletion = displaceActiveWebAIRequestIfNeeded(replacingWith: title)

        let request = WebAIHandoffRequest(
            provider: provider,
            title: title,
            prompt: "",
            responseFormat: .plainText,
            shouldAutoCapture: false,
            shouldStartMinimized: false
        )
        isWebAIHandoffMinimized = false
        activeWebAIHandoffRequest = request
        displacedCompletion?()
    }

    func resetWebAISession(for provider: WebAIProvider) {
        WebAISessionManager.shared.resetSession(for: provider) { [weak self] message in
            DispatchQueue.main.async {
                self?.showWebAIStatus(message)
            }
        }
    }

    private func displaceActiveWebAIRequestIfNeeded(replacingWith replacementTitle: String) -> (() -> Void)? {
        guard let activeRequest = activeWebAIHandoffRequest,
              let pending = pendingWebAIRequests.removeValue(forKey: activeRequest.id) else {
            return nil
        }

        pending.timeoutWorkItem?.cancel()
        WebAISessionManager.shared.cancelActiveRequest(for: activeRequest.provider)
        activeWebAIHandoffRequest = nil
        isWebAIHandoffMinimized = false
        return {
            pending.onFailure("\(pending.title) was replaced by \(replacementTitle). Please try again.")
        }
    }

    @discardableResult
    private func enqueueWebAIRequest(
        provider: WebAIProvider? = nil,
        title: String,
        prompt: String,
        responseFormat: WebAIResponseFormat = .plainText,
        onSuccess: @escaping (String) -> Void,
        onFailure: @escaping (String) -> Void
    ) -> UUID? {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            let message = "Nothing to send to \(settings.selectedWebAIProvider.displayName) yet."
            showWebAIStatus(message)
            onFailure(message)
            return nil
        }

        let request = WebAIHandoffRequest(
            provider: provider ?? settings.selectedWebAIProvider,
            title: title,
            prompt: trimmed,
            responseFormat: responseFormat,
            shouldAutoCapture: true,
            shouldStartMinimized: true
        )

        let displacedCompletion = displaceActiveWebAIRequestIfNeeded(replacingWith: title)

        var pending = PendingWebAIRequest(
            title: title,
            responseFormat: responseFormat,
            onSuccess: onSuccess,
            onFailure: onFailure,
            automaticRetryCount: 0,
            timeoutWorkItem: nil
        )
        let requestID = request.id
        let timeoutWorkItem = makeWebAIRequestTimeoutWorkItem(for: request)
        pending.timeoutWorkItem = timeoutWorkItem
        pendingWebAIRequests[request.id] = pending
        DispatchQueue.main.asyncAfter(
            deadline: .now() + webAIRequestTimeoutSeconds,
            execute: timeoutWorkItem
        )

        if activeWebAIHandoffRequest == nil && !isWebAIBatchHandoffInProgress {
            isWebAIHandoffMinimized = request.shouldStartMinimized
        }
        activeWebAIHandoffRequest = request
        displacedCompletion?()
        return request.id
    }

    private func makeWebAIRequestTimeoutWorkItem(for request: WebAIHandoffRequest) -> DispatchWorkItem {
        let timeoutSeconds = webAIRequestTimeoutSeconds
        return DispatchWorkItem { [weak self] in
            self?.handleWebAIRequestFailure(
                requestID: request.id,
                message: "\(request.provider.displayName) did not return a response within \(Int(timeoutSeconds)) seconds. Please try again.",
                dismissPanel: true
            )
        }
    }

    private func isRecoverableWebAIRequestFailure(_ message: String) -> Bool {
        let normalized = message.lowercased()
        return normalized.contains("content failed to load") ||
            normalized.contains("could not load") ||
            normalized.contains("couldn't load") ||
            normalized.contains("unable to load") ||
            normalized.contains("message box") ||
            normalized.contains("composer") ||
            normalized.contains("automatic response capture") ||
            normalized.contains("did not return a response") ||
            normalized.contains("web process terminated") ||
            normalized.contains("something went wrong")
    }

    private func retryWebAIRequestIfPossible(
        failedRequest: WebAIHandoffRequest,
        pending: inout PendingWebAIRequest,
        message: String
    ) -> Bool {
        guard failedRequest.shouldAutoCapture,
              pending.automaticRetryCount == 0,
              isRecoverableWebAIRequestFailure(message) else {
            return false
        }

        WebAISessionManager.shared.cancelActiveRequest(for: failedRequest.provider)

        let retryRequest = WebAIHandoffRequest(
            provider: failedRequest.provider,
            title: failedRequest.title,
            prompt: failedRequest.prompt,
            responseFormat: failedRequest.responseFormat,
            shouldAutoCapture: true,
            shouldStartMinimized: failedRequest.shouldStartMinimized
        )

        pending.automaticRetryCount += 1
        let timeoutWorkItem = makeWebAIRequestTimeoutWorkItem(for: retryRequest)
        pending.timeoutWorkItem = timeoutWorkItem
        pendingWebAIRequests[retryRequest.id] = pending
        isWebAIHandoffMinimized = retryRequest.shouldStartMinimized
        activeWebAIHandoffRequest = retryRequest
        DispatchQueue.main.asyncAfter(
            deadline: .now() + webAIRequestTimeoutSeconds,
            execute: timeoutWorkItem
        )
        showWebAIStatus("\(failedRequest.provider.displayName) is retrying with a fresh page.")
        return true
    }

    private func isWebAIContentLoadFailureResponse(_ response: String) -> Bool {
        let normalized = response
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        guard !normalized.isEmpty, normalized.count <= 500 else { return false }
        return normalized.contains("content failed to load") ||
            normalized.contains("could not load content") ||
            normalized.contains("couldn't load content") ||
            normalized.contains("unable to load content") ||
            (normalized.contains("something went wrong") && normalized.contains("1096"))
    }

    func handleCapturedWebAIResponse(requestID: UUID, response: String) {
        guard let pending = pendingWebAIRequests.removeValue(forKey: requestID) else { return }
        pending.timeoutWorkItem?.cancel()

        if activeWebAIHandoffRequest?.id == requestID {
            activeWebAIHandoffRequest = nil
        }

        let cleaned = response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else {
            pending.onFailure("Web AI returned an empty response.")
            return
        }

        guard !isWebAIContentLoadFailureResponse(cleaned) else {
            pending.onFailure("\(settings.selectedWebAIProvider.displayName) could not load the response. Try again.")
            return
        }

        pending.onSuccess(cleaned)
    }

    func handleWebAIRequestFailure(requestID: UUID, message: String, dismissPanel: Bool = false) {
        guard var pending = pendingWebAIRequests.removeValue(forKey: requestID) else { return }
        pending.timeoutWorkItem?.cancel()

        if let failedRequest = activeWebAIHandoffRequest,
           failedRequest.id == requestID,
           retryWebAIRequestIfPossible(
               failedRequest: failedRequest,
               pending: &pending,
               message: message
           ) {
            return
        }

        if activeWebAIHandoffRequest?.id == requestID {
            isWebAIHandoffMinimized = false
            if dismissPanel, let activeRequest = activeWebAIHandoffRequest {
                WebAISessionManager.shared.cancelActiveRequest(for: activeRequest.provider)
                activeWebAIHandoffRequest = nil
            }
        }

        showWebAIStatus(message)
        pending.onFailure(message)
    }

    func dismissActiveWebAIHandoff(userInitiated: Bool = false) {
        guard let request = activeWebAIHandoffRequest else {
            isWebAIHandoffMinimized = false
            return
        }

        activeWebAIHandoffRequest = nil
        isWebAIHandoffMinimized = false

        if userInitiated,
           let pending = pendingWebAIRequests.removeValue(forKey: request.id) {
            pending.timeoutWorkItem?.cancel()
            pending.onFailure("\(pending.title) was cancelled before a response was captured.")
        }
    }

    func performWebAIRequest(
        title: String,
        prompt: String,
        responseFormat: WebAIResponseFormat = .plainText,
        onSuccess: @escaping (String) -> Void,
        onFailure: @escaping (String) -> Void
    ) {
        let launch = {
            _ = self.enqueueWebAIRequest(
                title: title,
                prompt: prompt,
                responseFormat: responseFormat,
                onSuccess: onSuccess,
                onFailure: onFailure
            )
        }

        if Thread.isMainThread {
            launch()
        } else {
            DispatchQueue.main.async(execute: launch)
        }
    }

    func performWebAIRequestAsync(
        title: String,
        prompt: String,
        responseFormat: WebAIResponseFormat = .plainText
    ) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.main.async {
                self.performWebAIRequest(
                    title: title,
                    prompt: prompt,
                    responseFormat: responseFormat,
                    onSuccess: { continuation.resume(returning: $0) },
                    onFailure: {
                        continuation.resume(throwing: NSError(
                            domain: "WebAI",
                            code: 1,
                            userInfo: [NSLocalizedDescriptionKey: $0]
                        ))
                    }
                )
            }
        }
    }

    func minimizeActiveWebAIHandoff() {
        guard activeWebAIHandoffRequest != nil else { return }
        isWebAIHandoffMinimized = true
    }

    func restoreMinimizedWebAIHandoff() {
        guard activeWebAIHandoffRequest != nil else { return }
        isWebAIHandoffMinimized = false
    }

    func performSummarizeRequestAsync(prompt: String, taskName: String = "Codex / Summarize") async throws -> String {
        let start = Date()
        let output = try await summaryService.generateContentWithSummarize(prompt: prompt, settings: settings)
        let elapsed = Date().timeIntervalSince(start)
        recordSummarizeThroughput(text: output, elapsed: elapsed)
        print("✅ AppState: Summarize succeeded for \(taskName)")
        return output
    }

    func performSummarizeSummaryPublic(
        prompt: String,
        taskName: String = "Codex / Summarize",
        completion: @escaping (String) -> Void
    ) {
        isLoading = true
        Task(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            do {
                let output = try await self.performSummarizeRequestAsync(prompt: prompt, taskName: taskName)
                await MainActor.run {
                    self.isLoading = false
                    completion(output)
                }
            } catch {
                await MainActor.run {
                    self.isLoading = false
                    completion("Codex / Summarize error: \(error.localizedDescription)")
                }
            }
        }
    }

    func performPCCGatewayRequestAsync(
        prompt: String,
        taskName: String = "Apple PCC Gateway",
        isQA: Bool = false
    ) async throws -> String {
        let start = Date()
        let output = try await summaryService.generateContentWithPCCGateway(prompt: prompt, settings: settings)
        let elapsed = Date().timeIntervalSince(start)
        await recordPCCGatewayThroughput(text: output, elapsed: elapsed, isQA: isQA)
        print("✅ AppState: Apple PCC Gateway succeeded for \(taskName)")
        return output
    }

    func performPCCPlainTextRequestAsync(
        prompt: String,
        taskName: String = "Apple PCC Gateway",
        isQA: Bool = false
    ) async throws -> String {
        let prosePrompt = prompt + "\n\nReturn only readable plain text or natural-language Markdown. Do not return JSON, a property list, or a code block."
        let output = try await performPCCGatewayRequestAsync(
            prompt: prosePrompt,
            taskName: taskName,
            isQA: isQA
        )
        return PCCDisplayTextFormatter.displayText(from: output)
    }

    func performPCCGatewaySummaryPublic(
        prompt: String,
        taskName: String = "Apple PCC Gateway",
        completion: @escaping (String) -> Void
    ) {
        isLoading = true
        Task(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            do {
                let output = try await self.performPCCPlainTextRequestAsync(prompt: prompt, taskName: taskName)
                await MainActor.run {
                    self.isLoading = false
                    completion(output)
                }
            } catch {
                await MainActor.run {
                    self.isLoading = false
                    completion("Apple PCC Gateway error: \(error.localizedDescription)")
                }
            }
        }
    }

    private func showWebAIStatus(_ message: String) {
        fallbackNotification = message
        showFallbackNotification = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
            self?.showFallbackNotification = false
        }
    }

    private func cleanedArticleContent(_ article: Article) -> String {
        let htmlContent = article.content
        return htmlContent
            .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func redditSummarySourceText(post: RedditPost, comments: [RedditCommentModel], maxComments: Int? = nil) -> String {
        let allCommentLines = flattenedFullCommentLinesForSummary(comments)
        let commentLines: [String]
        if let maxComments {
            commentLines = Array(allCommentLines.prefix(maxComments))
        } else {
            commentLines = allCommentLines
        }
        if commentLines.isEmpty {
            return normalizedSummarySourceText(post.content, maxCharacters: 6_000)
        }
        let mergedComments = commentLines.joined(separator: "\n")
        return """
        Title: \(post.title)
        Post:
        \(normalizedSummarySourceText(post.content, maxCharacters: 3_000))

        Top comments:
        \(mergedComments)
        """
    }

    private func normalizedSummarySourceText(_ text: String, maxCharacters: Int? = nil) -> String {
        var normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if let maxCharacters, normalized.count > maxCharacters {
            normalized = String(normalized.prefix(maxCharacters))
        }

        return normalized
    }

    private func flattenedFullCommentLinesForSummary(
        _ comments: [RedditCommentModel],
        depth: Int = 0
    ) -> [String] {
        var lines: [String] = []
        let indent = String(repeating: "    ", count: depth)

        for comment in comments {
            let body = normalizedSummarySourceText(
                comment.body.replacingOccurrences(of: "\n", with: " ")
            )
            if !body.isEmpty {
                lines.append("\(indent)- \(body)")
            }

            if !comment.replies.isEmpty {
                lines.append(contentsOf: flattenedFullCommentLinesForSummary(comment.replies, depth: depth + 1))
            }
        }

        return lines
    }

    private func strictSummaryPrompt(
        task: String,
        sourceLabel: String,
        sourceText: String,
        wordLimit: Int
    ) -> String {
        """
        Write a short summary of the source material.

        Rules:
        - Summarize the meaning only.
        - Do not continue, rewrite, or imitate the source.
        - Do not quote, copy, or list comments one by one.
        - Merge repeated ideas into a few clear themes.
        - Return plain text only.
        - Write 2 short paragraphs maximum.
        - Stay under \(wordLimit) words.

        Task:
        \(task)

        <source_label>\(sourceLabel)</source_label>
        <source_text>
        \(sourceText)
        </source_text>

        Return only the final summary.
        """
    }

    func articleSummaryPrompt(for article: Article) -> String {
        let sourceText = cleanedArticleContent(article)
        return strictSummaryPrompt(
            task: "Explain the main point of the article and the most important takeaway.",
            sourceLabel: "Article",
            sourceText: normalizedSummarySourceText(sourceText, maxCharacters: 12_000),
            wordLimit: 90
        )
    }

    func geminiArticleSummaryPrompt(for article: Article) -> String {
        "Provide a brief 3-4 sentence summary of this article. Include only the main point and most important conclusion. Keep it under 100 words. Return plain text only (no Markdown, no headings, no bullets). Use short readable paragraphs and include a blank line between paragraphs when possible:\n\n\(article.content)"
    }

    func redditPostSummaryPrompt(post: RedditPost, comments: [RedditCommentModel] = [], maxComments: Int? = nil) -> String {
        let sourceText = redditSummarySourceText(post: post, comments: comments, maxComments: maxComments)
        if comments.isEmpty {
            return strictSummaryPrompt(
                task: "State what the Reddit post is about and the key point being made.",
                sourceLabel: "Reddit post",
                sourceText: sourceText,
                wordLimit: 90
            )
        }
        return strictSummaryPrompt(
            task: "State the main topic of the post, then synthesize the main reactions, agreements, and disagreements from the comments.",
            sourceLabel: "Reddit post and comments",
            sourceText: sourceText,
            wordLimit: 110
        )
    }

    private func strictQAPrompt(
        sourceLabel: String,
        sourceText: String,
        question: String,
        preferCompleteAnswer: Bool = false
    ) -> String {
        let answerLengthRule = preferCompleteAnswer
            ? "- Give a complete answer using as much relevant detail as the source supports; use short paragraphs if needed."
            : "- Keep the answer concise, using short paragraphs if needed."

        return """
        Answer the question using only the source material.

        Rules:
        - Use only facts present in the source.
        - If the source does not answer the question, say the information is not available in the source.
        - Return plain text only.
        - Do not use Markdown symbols, headings, bullets, or code fences.
        \(answerLengthRule)

        <source_label>\(sourceLabel)</source_label>
        <source_text>
        \(sourceText)
        </source_text>

        Question:
        \(question.trimmingCharacters(in: .whitespacesAndNewlines))

        Return only the answer.
        """
    }

    func articleQAPrompt(article: Article, question: String, preferCompleteAnswer: Bool = false) -> String {
        let content = cleanedArticleContent(article)
        let sourceText = """
        Title: \(article.title)

        \(normalizedSummarySourceText(content, maxCharacters: 12_000))
        """
        return strictQAPrompt(
            sourceLabel: "Article",
            sourceText: sourceText,
            question: question,
            preferCompleteAnswer: preferCompleteAnswer
        )
    }

    func redditQAPrompt(post: RedditPost, comments: [RedditCommentModel], question: String, maxComments: Int? = nil, preferCompleteAnswer: Bool = false) -> String {
        strictQAPrompt(
            sourceLabel: comments.isEmpty ? "Reddit post" : "Reddit post and comments",
            sourceText: redditSummarySourceText(post: post, comments: comments, maxComments: maxComments),
            question: question,
            preferCompleteAnswer: preferCompleteAnswer
        )
    }

    func articleSelectionSourceContext(for article: Article) -> (label: String, text: String) {
        let content = cleanedArticleContent(article)
        let sourceText = """
        Title: \(article.title)
        Source: \(article.feedTitle)
        Link: \(article.url?.absoluteString ?? article.feedURL)

        \(normalizedSummarySourceText(content, maxCharacters: 18_000))
        """
        return ("Original article source", sourceText)
    }

    func redditSelectionSourceContext(
        post: RedditPost,
        comments: [RedditCommentModel],
        maxComments: Int? = nil
    ) -> (label: String, text: String) {
        (
            comments.isEmpty ? "Original Reddit post source" : "Original Reddit post and comments source",
            redditSummarySourceText(post: post, comments: comments, maxComments: maxComments)
        )
    }

    func globalSummarySelectionSourceContext(
        referenceId: String?,
        isReddit: Bool
    ) -> (label: String, text: String)? {
        let normalizedId = referenceId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if !normalizedId.isEmpty {
            if isReddit, let post = redditPostForGlobalSummaryReference(normalizedId) {
                let cachedComments = cachedRedditCommentsForQA.first { $0.0.id == post.id }?.1 ?? []
                return (
                    cachedComments.isEmpty ? "Original Reddit post source" : "Original Reddit post and comments source",
                    redditSelectionSourceText(post: post, commentTexts: cachedComments)
                )
            }

            if !isReddit, let article = articleForGlobalSummaryReference(normalizedId) {
                return articleSelectionSourceContext(for: article)
            }
        }

        if isReddit {
            let contexts = !cachedRedditCommentsForQA.isEmpty
                ? cachedRedditCommentsForQA
                : globalSummaryPosts.prefix(20).map { ($0, []) }
            guard !contexts.isEmpty else { return nil }
            let text = contexts.prefix(20).enumerated().map { index, entry in
                let post = entry.0
                let comments = entry.1
                return """
                Reddit Item \(index + 1):
                \(redditSelectionSourceText(post: post, commentTexts: comments))
                """
            }.joined(separator: "\n\n")
            return ("Original Reddit batch source", text)
        }

        guard !globalSummaryArticles.isEmpty else { return nil }
        let text = globalSummaryArticles.prefix(20).enumerated().map { index, article in
            let content = cleanedArticleContent(article)
            return """
            Article \(index + 1):
            Title: \(article.title)
            Source: \(article.feedTitle)
            Link: \(article.url?.absoluteString ?? article.feedURL)
            Content:
            \(normalizedSummarySourceText(content, maxCharacters: 1_500))
            """
        }.joined(separator: "\n\n")
        return ("Original article batch source", text)
    }

    private func redditSelectionSourceText(post: RedditPost, commentTexts: [String]) -> String {
        let commentSection: String
        if commentTexts.isEmpty {
            commentSection = "No comments captured."
        } else {
            commentSection = commentTexts
                .prefix(80)
                .map { "- \(truncateText(normalizedSummarySourceText($0), limit: 500))" }
                .joined(separator: "\n")
        }

        return """
        Title: \(post.title)
        Subreddit: r/\(post.subreddit)
        Post:
        \(normalizedSummarySourceText(post.content, maxCharacters: 3_000))

        Comments:
        \(commentSection)
        """
    }

    func commentSummaryPrompt(comments: [RedditCommentModel], maxComments: Int? = nil) -> String {
        let allCommentLines = flattenedFullCommentLinesForSummary(comments)
        let commentLines: [String]
        if let maxComments {
            commentLines = Array(allCommentLines.prefix(maxComments))
        } else {
            commentLines = allCommentLines
        }
        let combinedComments = commentLines
            .joined(separator: "\n\n")

        return """
        Provide a comprehensive summary of the key themes and main points from ALL the comments provided below. Include:
        - Major themes discussed
        - Key points made by commenters
        - Notable disagreements or different perspectives
        - Any consensus reached
        Keep the summary organized and detailed.
        Return plain text only. Do not use Markdown symbols, headings, or code fences.

        \(combinedComments)
        """
    }

    func flattenedCommentCountForSummary(comments: [RedditCommentModel], maxComments: Int? = nil) -> Int {
        let count = flattenedFullCommentLinesForSummary(comments).count
        if let maxComments {
            return min(count, maxComments)
        }
        return count
    }

    private func formatCommentsForAnalysisPrompt(_ comments: [RedditCommentModel], depth: Int = 0) -> String {
        var formattedString = ""
        let indent = String(repeating: "  ", count: depth)

        for comment in comments {
            let scoreText = " (\(comment.score) points)"
            let authorText = comment.author.isEmpty ? "[deleted]" : comment.author
            let bodyText = comment.body
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\n", with: " ")
            formattedString += "\(indent)- \(authorText)\(scoreText): \(bodyText)\n"
            if !comment.replies.isEmpty {
                formattedString += formatCommentsForAnalysisPrompt(comment.replies, depth: depth + 1)
            }
        }

        return formattedString
    }

    func thematicAnalysisPrompt(comments: [RedditCommentModel]) -> String {
        let formattedCommentsString = formatCommentsForAnalysisPrompt(comments)
        return """
        Summarize the following Reddit discussion thread, highlighting key opinions, consensus views, and any significant disagreements. Focus on the main topics being discussed:

        \(formattedCommentsString)
        
        Return plain text only. Do not use Markdown symbols, headings, bullet markers, or HTML tags.
        """
    }

    private func webCommentExampleLines(_ comments: [RedditCommentModel], title: String) -> String {
        guard !comments.isEmpty else { return "" }
        let lines = comments.map { comment in
            let author = comment.author.isEmpty ? "[deleted]" : comment.author
            let body = comment.body
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedBody = body.count > 220 ? String(body.prefix(220)) + "…" : body
            return "- u/\(author) (\(comment.score) upvotes): \(trimmedBody)"
        }.joined(separator: "\n")

        return """
        \(title):
        \(lines)
        """
    }

    func commentAnalysisWebPrompt(comments: [RedditCommentModel]) -> String {
        let analytics = redditService.generateCommentAnalytics(from: comments)
        let baseThematicAnalysisPrompt = thematicAnalysisPrompt(comments: comments)
        let percentages = analytics.sentimentPercentages
        let topics = analytics.commentTopics.isEmpty ? "None identified" : analytics.commentTopics.prefix(5).joined(separator: ", ")
        let mostActiveAuthorLine: String
        if let mostActiveAuthor = analytics.mostActiveAuthor {
            mostActiveAuthorLine = "Most active author: u/\(mostActiveAuthor.name) with \(mostActiveAuthor.count) comments."
        } else {
            mostActiveAuthorLine = "Most active author: unavailable."
        }

        let positiveExamples = webCommentExampleLines(
            redditService.getTopCommentsBySentiment(comments: comments, type: .positive),
            title: "Top positive comments"
        )
        let neutralExamples = webCommentExampleLines(
            redditService.getTopCommentsBySentiment(comments: comments, type: .neutral),
            title: "Notable neutral comments"
        )
        let negativeExamples = webCommentExampleLines(
            redditService.getTopCommentsBySentiment(comments: comments, type: .negative),
            title: "Top negative comments"
        )
        let highlyVoted = webCommentExampleLines(
            analytics.highlyVotedComments,
            title: "Highest voted comments overall"
        )

        return """
        Create the actual comment-analysis dashboard from the Reddit discussion below.

        IMPORTANT:
        - Do NOT return JSON.
        - Do NOT explain how to build the dashboard.
        - Produce the dashboard itself as a rendered artifact/preview.
        - Create a single self-contained HTML document with inline CSS only.
        - If you need charts or shapes, use inline SVG inside that HTML.
        - Put the HTML in a code artifact / preview so the result renders visually.
        - Do NOT dump raw SVG, XML, or HTML source code into the main chat reply.
        - The visible result should be the rendered preview, not plain text.
        - The result should look like a polished analysis panel, not a plain text summary.
        - Keep the SAME substantive thematic summary you would normally produce from the analysis prompt below, then present it visually.
        - Nothing may be clipped, cropped, or cut off.
        - Prefer a taller canvas over shrinking text too far.
        - All text must wrap inside its card/container.
        - Increase the SVG/artboard height if needed so every section is fully visible.

        The dashboard should include:
        - A summary section near the top that preserves the same discussion analysis the normal AI summary would give
        - A sentiment analysis section with positive / neutral / negative counts and a chart
        - Overall comment stats
        - Key insights
        - A thematic analysis section
        - Comment examples by sentiment
        - A compact, readable visual hierarchy suitable for a laptop screen

        Use this computed analysis data:
        - Total comments analyzed: \(analytics.totalComments)
        - Sentiment counts: positive \(analytics.sentimentCounts.positive), neutral \(analytics.sentimentCounts.neutral), negative \(analytics.sentimentCounts.negative)
        - Sentiment percentages: positive \(Int(percentages.positive.rounded()))%, neutral \(Int(percentages.neutral.rounded()))%, negative \(Int(percentages.negative.rounded()))%
        - Average comment length: \(analytics.averageCommentLength) characters
        - Unique authors: \(analytics.uniqueAuthorsCount)
        - \(mostActiveAuthorLine)
        - Most common length bucket: \(analytics.getMostCommonLengthDescription())
        - Common topics: \(topics)

        Summary requirements:
        - Use the same core reasoning and coverage as the standard thematic analysis prompt
        - Explicitly summarize what people are saying, not just the metrics
        - Mention the main topic, the dominant mood, and the biggest point of agreement or disagreement
        - Keep the summary easy to read inside the dashboard
        - Limit the visible summary block to 4-6 bullets or short paragraphs
        - Each bullet/line should be short enough to wrap cleanly in a dashboard card

        Layout requirements:
        - Target a desktop-sized card or page around 1200px wide with auto height
        - Use a clean dashboard grid with enough padding and margins
        - Prevent text overlap between sections
        - Keep stat cards compact
        - If space is tight, shorten wording before reducing font size
        - Comment example cards should show only short excerpts, not full comments
        - Keep key insights to 3-5 concise bullets
        - Keep topics/trends to short labels, not long sentences
        - Use polished visual styling: cards, clear hierarchy, subtle contrast, accent colors, readable spacing
        - Never respond with raw markup source as the visible answer

        First derive the thematic summary using this exact instruction set, then present that analysis inside the dashboard:
        \(baseThematicAnalysisPrompt)

        Include concise text grounded in the discussion. Favor charts, stat cards, section blocks, and short bullets over long paragraphs, but do include the summary section.

        \(highlyVoted)

        \(positiveExamples)

        \(neutralExamples)

        \(negativeExamples)
        """
    }

    private func combinedGlobalSummaryPrompt(for result: GlobalSummaryResult) -> String? {
        guard !result.summaries.isEmpty else { return nil }

        let question = """
        Identify and explain all significant themes discussed across this material. Group closely related points, preserve distinct topics, note agreements or disagreements where relevant, and conclude with the most important collective insights.
        """

        if result.source == "reddit", !globalSummaryPosts.isEmpty {
            let currentPostIds = Set(globalSummaryPosts.map(\.id))
            let cachedPostIds = Set(cachedRedditCommentsForQA.map { $0.0.id })
            let contexts = cachedPostIds == currentPostIds
                ? cachedRedditCommentsForQA
                : globalSummaryPosts.map { ($0, []) }
            return buildGlobalRedditQuestionPrompt(contexts: contexts, question: question)
        }

        if result.source == "articles", !globalSummaryArticles.isEmpty {
            return buildGlobalArticlesQuestionPrompt(articles: globalSummaryArticles, question: question)
        }

        let savedSummaries = result.summaries.enumerated().map { index, item in
            "Item \(index + 1): \(item.subject) - \(item.summary)"
        }.joined(separator: "\n")

        return """
        Use ONLY the saved material below to answer the question.

        SAVED MATERIAL:
        \(savedSummaries)

        QUESTION:
        \(question)

        If the material does not support a conclusion, say so explicitly. Respond in plain text only. Do not use Markdown symbols, headings, or code fences.
        """
    }

    func openWebSummary(for article: Article) {
        presentWebAIHandoff(prompt: geminiArticleSummaryPrompt(for: article), title: "Article Summary")
    }

    func openWebSummary(for post: RedditPost, comments: [RedditCommentModel] = []) {
        presentWebAIHandoff(prompt: redditPostSummaryPrompt(post: post, comments: comments), title: "Reddit Summary")
    }

    func openWebArticleQuestion(article: Article, question: String) {
        presentWebAIHandoff(prompt: articleQAPrompt(article: article, question: question), title: "Article Q&A")
    }

    func openWebRedditQuestion(post: RedditPost, comments: [RedditCommentModel], question: String) {
        presentWebAIHandoff(prompt: redditQAPrompt(post: post, comments: comments, question: question), title: "Reddit Q&A")
    }

    func openWebCommentSummary(comments: [RedditCommentModel]) {
        presentWebAIHandoff(prompt: commentSummaryPrompt(comments: comments), title: "Comment Summary")
    }

    func openWebThematicAnalysis(comments: [RedditCommentModel]) {
        presentWebAIHandoff(prompt: commentAnalysisWebPrompt(comments: comments), title: "Comment Analysis")
    }

    func openWebCombinedGlobalSummary() {
        guard let data = globalSummaryJSON.data(using: .utf8),
              let result = try? JSONDecoder().decode(GlobalSummaryResult.self, from: data),
              let prompt = combinedGlobalSummaryPrompt(for: result) else {
            showWebAIStatus("Generate a summary overview first, then send it to \(settings.selectedWebAIProvider.displayName).")
            return
        }

        presentWebAIHandoff(prompt: prompt, title: "Global Summary Overview")
    }

    func requestWebCombinedGlobalSummary(force: Bool = true) {
        let sourceFingerprint = globalSummaryJSON
        let existingSummary = aggregateSummaryText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard force || existingSummary.isEmpty else { return }

        guard let data = globalSummaryJSON.data(using: .utf8),
              let result = try? JSONDecoder().decode(GlobalSummaryResult.self, from: data),
              !result.summaries.isEmpty,
              let prompt = combinedGlobalSummaryPrompt(for: result) else {
            aggregateSummaryError = "No summary data available to combine."
            aggregateSummaryText = nil
            aggregateSummarySourceFingerprint = nil
            isGeneratingAggregateSummary = false
            showWebAIStatus("Generate a summary overview first, then send it to \(settings.selectedWebAIProvider.displayName).")
            return
        }

        aggregateSummaryTask?.cancel()
        aggregateSummaryTask = nil
        isGeneratingAggregateSummary = true
        aggregateSummaryError = nil
        aggregateSummaryText = nil
        aggregateSummarySourceFingerprint = nil
        isWebAIHandoffMinimized = true

        performWebAIRequest(
            title: result.source == "reddit" ? "Combined Reddit Summary" : "Combined Article Summary",
            prompt: prompt,
            onSuccess: { [weak self] summary in
                guard let self else { return }
                let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
                let lowercased = trimmed.lowercased()
                self.isGeneratingAggregateSummary = false

                if trimmed.isEmpty || lowercased.hasPrefix("error") || lowercased.contains("api key not configured") {
                    self.aggregateSummaryError = trimmed.isEmpty ? "Failed to generate combined summary." : trimmed
                    self.aggregateSummaryText = nil
                    self.aggregateSummarySourceFingerprint = nil
                } else {
                    self.aggregateSummaryText = trimmed
                    self.aggregateSummarySourceFingerprint = sourceFingerprint
                    self.aggregateSummaryError = nil
                }
            },
            onFailure: { [weak self] message in
                guard let self else { return }
                self.isGeneratingAggregateSummary = false
                self.aggregateSummaryError = message
                self.aggregateSummaryText = nil
                self.aggregateSummarySourceFingerprint = nil
            }
        )
    }

    func openWebGlobalSummaryQuestion(question: String) {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            showWebAIStatus("Enter a question first.")
            return
        }

        guard lastGlobalSummaryContext != nil else {
            showWebAIStatus("Generate a summary overview first, then ask a question.")
            return
        }

        if !globalSummaryArticles.isEmpty {
            let prompt = buildGlobalArticlesQuestionPrompt(articles: globalSummaryArticles, question: trimmed)
            presentWebAIHandoff(prompt: prompt, title: "Global Summary Q&A")
            return
        }

        if !globalSummaryPosts.isEmpty {
            let posts = globalSummaryPosts
            let cachedPostIds = Set(cachedRedditCommentsForQA.map { $0.0.id })
            let currentPostIds = Set(posts.map { $0.id })
            let cacheIsValid = !cachedRedditCommentsForQA.isEmpty && cachedPostIds == currentPostIds

            if cacheIsValid {
                let usableContexts = cachedRedditCommentsForQA.filter { !$0.1.isEmpty || !self.sanitizedSnippet(from: $0.0.content, limit: 800).isEmpty }
                guard !usableContexts.isEmpty else {
                    showWebAIStatus("Unable to load Reddit comments for this summary.")
                    return
                }
                let prompt = buildGlobalRedditQuestionPrompt(contexts: usableContexts, question: trimmed)
                presentWebAIHandoff(prompt: prompt, title: "Global Summary Q&A")
                return
            }

            let topComments = lastGlobalSummaryContext.flatMap { topCommentsCount(for: $0) } ?? 3
            fetchCommentsForGlobalSummary(posts: posts, topComments: topComments) { [weak self] contexts in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.cachedRedditCommentsForQA = contexts
                    let usableContexts = contexts.filter { !$0.1.isEmpty || !self.sanitizedSnippet(from: $0.0.content, limit: 800).isEmpty }
                    guard !usableContexts.isEmpty else {
                        self.showWebAIStatus("Unable to load Reddit comments for this summary.")
                        return
                    }
                    let prompt = self.buildGlobalRedditQuestionPrompt(contexts: usableContexts, question: trimmed)
                    self.presentWebAIHandoff(prompt: prompt, title: "Global Summary Q&A")
                }
            }
            return
        }

        showWebAIStatus("No summary data is available for Q&A at the moment.")
    }

    func askWebQuestionAboutGlobalSummary(question: String, completion: @escaping (String) -> Void) {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            completion("Please enter a question to ask about the summary overview.")
            return
        }

        guard let context = lastGlobalSummaryContext else {
            completion("Generate a summary overview first, then try asking a question.")
            return
        }

        if !globalSummaryArticles.isEmpty {
            let prompt = buildGlobalArticlesQuestionPrompt(articles: globalSummaryArticles, question: trimmed)
            executeWebGlobalQAPrompt(prompt: prompt, completion: completion)
            return
        }

        if !globalSummaryPosts.isEmpty {
            let posts = globalSummaryPosts
            let cachedPostIds = Set(cachedRedditCommentsForQA.map { $0.0.id })
            let currentPostIds = Set(posts.map { $0.id })
            let cacheIsValid = !cachedRedditCommentsForQA.isEmpty && cachedPostIds == currentPostIds

            if cacheIsValid {
                let usableContexts = cachedRedditCommentsForQA.filter { !$0.1.isEmpty || !self.sanitizedSnippet(from: $0.0.content, limit: 800).isEmpty }
                guard !usableContexts.isEmpty else {
                    completion("Unable to load Reddit comments for this summary. Please try again later.")
                    return
                }
                let prompt = buildGlobalRedditQuestionPrompt(contexts: usableContexts, question: trimmed)
                executeWebGlobalQAPrompt(prompt: prompt, completion: completion)
                return
            }

            let topComments = topCommentsCount(for: context) ?? 3
            fetchCommentsForGlobalSummary(posts: posts, topComments: topComments) { [weak self] contexts in
                guard let self else { return }
                self.cachedRedditCommentsForQA = contexts
                let usableContexts = contexts.filter { !$0.1.isEmpty || !self.sanitizedSnippet(from: $0.0.content, limit: 800).isEmpty }
                guard !usableContexts.isEmpty else {
                    completion("Unable to load Reddit comments for this summary. Please try again later.")
                    return
                }
                let prompt = self.buildGlobalRedditQuestionPrompt(contexts: usableContexts, question: trimmed)
                self.executeWebGlobalQAPrompt(prompt: prompt, completion: completion)
            }
            return
        }

        completion("No summary data is available for Q&A at the moment. Please generate a summary first.")
    }

    private func executeWebGlobalQAPrompt(prompt: String, completion: @escaping (String) -> Void) {
        let cleanedCompletion: (String) -> Void = { [weak self] answer in
            guard let self else {
                completion(answer)
                return
            }
            completion(self.cleanMarkdownArtifactsForDisplay(answer))
        }

        performWebAIRequest(
            title: "Global Summary Q&A",
            prompt: prompt,
            onSuccess: cleanedCompletion,
            onFailure: { cleanedCompletion($0) }
        )
    }

    func openWebWhiteboard(prompt: String) {
        presentWebAIHandoff(prompt: prompt, title: "Whiteboard")
    }

    func openWebInfographic(prompt: String) {
        presentWebAIHandoff(prompt: prompt, title: "Infographic")
    }

    func requestWebSummary(for article: Article) {
        isLoading = true
        beginArticleSummary(article)
        let sourceText = cleanedArticleContent(article)
        performWebAIRequest(
            title: "Article Summary",
            prompt: articleSummaryPrompt(for: article),
            onSuccess: { [weak self] summary in
                guard let self else { return }
                let constrained = self.enforceArticleSummaryLength(summary, sourceText: sourceText)
                self.updateArticleSummaryFromCloud(article, summary: constrained)
                self.isLoading = false
            },
            onFailure: { [weak self] _ in
                self?.finishArticleSummary(article)
                self?.isLoading = false
            }
        )
    }

    func requestWebSummary(for post: RedditPost, comments: [RedditCommentModel] = []) {
        isLoading = true
        beginRedditSummary(post)
        performWebAIRequest(
            title: "Reddit Summary",
            prompt: redditPostSummaryPrompt(post: post, comments: comments),
            onSuccess: { [weak self] summary in
                self?.updateRedditPostSummaryFromCloud(post, summary: summary)
                self?.isLoading = false
            },
            onFailure: { [weak self] _ in
                self?.finishRedditSummary(post)
                self?.isLoading = false
            }
        )
    }

    func askWebQuestionAboutArticle(
        article: Article,
        question: String,
        completion: @escaping (String) -> Void
    ) {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            completion("Please enter a question first.")
            return
        }

        performExplicitWebAIQuestion(
            title: "Article Q&A",
            prompt: articleQAPrompt(article: article, question: trimmed),
            completion: completion
        )
    }

    func askWebQuestionAboutRedditPost(
        post: RedditPost,
        comments: [RedditCommentModel],
        question: String,
        completion: @escaping (String) -> Void
    ) {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            completion("Please enter a question first.")
            return
        }

        performExplicitWebAIQuestion(
            title: "Reddit Q&A",
            prompt: redditQAPrompt(post: post, comments: comments, question: trimmed),
            completion: completion
        )
    }

    private func performExplicitWebAIQuestion(
        title: String,
        prompt: String,
        completion: @escaping (String) -> Void
    ) {
        let cleanedCompletion: (String) -> Void = { [weak self] answer in
            guard let self else {
                completion(answer)
                return
            }
            completion(self.cleanAndFormatQATextForDisplay(answer))
        }

        performWebAIRequest(
            title: title,
            prompt: prompt,
            onSuccess: cleanedCompletion,
            onFailure: { cleanedCompletion($0) }
        )
    }

    func askQuestionAboutSelection(
        prompt: String,
        completion: @escaping @MainActor (String) -> Void
    ) {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            Task { await completion("Select some text first.") }
            return
        }

        answerQuestion(trimmed, context: "", completion: completion)
    }

    func askWebQuestionAboutSelection(
        prompt: String,
        title: String = "Ask AI Web",
        completion: @escaping (String) -> Void
    ) {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            completion("Select some text first.")
            return
        }

        performExplicitWebAIQuestion(
            title: title,
            prompt: trimmed,
            completion: completion
        )
    }

    #if os(iOS)
    private func generateYouTubeText(prompt: String, title: String) async throws -> String {
        if settings.selectedSummaryProvider == .webAI {
            return try await performWebAIRequestAsync(title: title, prompt: prompt, responseFormat: .plainText)
        }
        return try await generateBatchPodcastText(
            prompt: prompt,
            title: title,
            provider: settings.selectedSummaryProvider,
            backgroundTaskHandle: nil
        )
    }

    private func requestYouTubeSummary(for article: Article) {
        guard let videoID = article.youtubeVideoID else {
            finishSummary(article: article, redditPost: nil)
            isLoading = false
            return
        }

        youtubeStatusMessages[videoID] = "Retrieving the video transcript…"
        Task(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            do {
                let transcript = try await self.youtubeService.transcript(videoID: videoID)
                let chunks = YouTubeTranscriptProcessor.chunks(from: transcript)
                guard !chunks.isEmpty else { throw YouTubeSupportError.transcriptUnavailable }

                var notes: [String] = []
                notes.reserveCapacity(chunks.count)
                for (offset, chunk) in chunks.enumerated() {
                    self.youtubeStatusMessages[videoID] = "Analyzing transcript section \(offset + 1) of \(chunks.count)…"
                    let prompt = """
                    You are preparing grounded notes for a summary of the YouTube video “\(article.title)”.

                    Use ONLY the timestamped transcript excerpt below. Capture the speaker's claims, reasoning, examples, and conclusions. Preserve the timestamp label for every important point. Do not use the title or description as evidence and do not add outside knowledge.

                    TRANSCRIPT EXCERPT
                    \(chunk.timestampLabel) \(chunk.text)

                    Return concise plain-text notes.
                    """
                    notes.append(try await self.generateYouTubeText(prompt: prompt, title: "YouTube Transcript \(offset + 1)/\(chunks.count)"))
                }

                // Hierarchically condense notes when a long video produces more
                // text than one model request can safely carry. Every transcript
                // chunk has already been processed before this reduction step.
                var reducedNotes = notes
                while reducedNotes.joined(separator: "\n\n").count > 14_000, reducedNotes.count > 1 {
                    var next: [String] = []
                    for groupStart in stride(from: 0, to: reducedNotes.count, by: 4) {
                        let group = Array(reducedNotes[groupStart..<min(groupStart + 4, reducedNotes.count)])
                        let prompt = """
                        Condense these transcript-grounded notes without dropping distinct claims, examples, conclusions, or timestamp references. Use only the notes supplied.

                        \(group.joined(separator: "\n\n"))
                        """
                        next.append(try await self.generateYouTubeText(prompt: prompt, title: "YouTube Summary Reduction"))
                    }
                    reducedNotes = next
                }

                self.youtubeStatusMessages[videoID] = "Writing the grounded video summary…"
                let finalPrompt = """
                Write a clear summary of the actual spoken content of the YouTube video “\(article.title)” using ONLY the transcript-grounded notes below.

                Requirements:
                - Explain the main argument or subject, key supporting points, important examples, and conclusions.
                - Do not treat the video title, description, comments, or outside knowledge as evidence.
                - Retain useful timestamp references in square brackets.
                - If the transcript itself is ambiguous, say so rather than guessing.
                - Return readable plain text, not JSON.

                TRANSCRIPT-GROUNDED NOTES
                \(reducedNotes.joined(separator: "\n\n"))
                """
                let summary = try await self.generateYouTubeText(prompt: finalPrompt, title: "YouTube Video Summary")
                self.youtubeStatusMessages[videoID] = nil
                self.updateArticleSummaryFromCloud(article, summary: summary)
                self.isLoading = false
            } catch {
                self.youtubeStatusMessages[videoID] = error.localizedDescription
                self.finishSummary(article: article, redditPost: nil)
                self.isLoading = false
            }
        }
    }

    private func askQuestionAboutYouTubeVideo(article: Article, question: String, completion: @escaping (String) -> Void) {
        guard let videoID = article.youtubeVideoID else {
            completion(YouTubeSupportError.videoUnavailable.localizedDescription)
            return
        }
        let trimmedQuestion = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuestion.isEmpty else {
            completion("Enter a question about the video.")
            return
        }

        isLoading = true
        youtubeStatusMessages[videoID] = "Finding relevant transcript sections…"
        Task(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            do {
                let transcript = try await self.youtubeService.transcript(videoID: videoID)
                let allChunks = YouTubeTranscriptProcessor.chunks(from: transcript)
                let earlierQuestions = self.youtubeQuestionHistory[videoID, default: []].suffix(2)
                let retrievalQuery = ([trimmedQuestion] + Array(earlierQuestions)).joined(separator: " ")
                let evidenceChunks = YouTubeTranscriptProcessor.relevantChunks(for: retrievalQuery, in: allChunks)
                guard !evidenceChunks.isEmpty else { throw YouTubeSupportError.transcriptUnavailable }

                let conversationContext = earlierQuestions.isEmpty
                    ? "No earlier questions."
                    : earlierQuestions.enumerated().map { "Earlier question \($0.offset + 1): \($0.element)" }.joined(separator: "\n")
                let prompt = """
                Answer the user's question about the YouTube video “\(article.title)” using ONLY the timestamped transcript evidence below.

                Rules:
                - Do not use the video title, description, comments, or outside knowledge as evidence.
                - Cite supporting timestamps in square brackets.
                - If the evidence does not support an answer, reply exactly: “I couldn't find that in the available video transcript.”
                - Earlier questions are supplied only to understand follow-up wording; they are not evidence.
                - Return plain text, not JSON.

                \(conversationContext)

                TRANSCRIPT EVIDENCE
                \(YouTubeTranscriptProcessor.evidenceText(evidenceChunks))

                USER QUESTION
                \(trimmedQuestion)
                """
                self.youtubeStatusMessages[videoID] = "Answering from the transcript…"
                let answer = try await self.generateYouTubeText(prompt: prompt, title: "YouTube Video Q&A")
                var history = self.youtubeQuestionHistory[videoID, default: []]
                history.append(trimmedQuestion)
                self.youtubeQuestionHistory[videoID] = Array(history.suffix(8))
                self.youtubeStatusMessages[videoID] = nil
                self.isLoading = false
                completion(answer)
            } catch {
                self.youtubeStatusMessages[videoID] = error.localizedDescription
                self.isLoading = false
                completion(error.localizedDescription)
            }
        }
    }
    #endif

    // MARK: - Unified Summary Request Handler
    func requestSummary(for article: Article? = nil, redditPost: RedditPost? = nil, redditComments: [RedditCommentModel] = []) {
        #if os(iOS)
        if let article,
           settings.youtubeSupportEnabled,
           article.isYouTubeVideo {
            isLoading = true
            beginSummary(article: article, redditPost: nil)
            requestYouTubeSummary(for: article)
            return
        }
        #endif

        // Set loading state immediately for articles and reddit posts
        if article != nil || redditPost != nil {
            isLoading = true
        }
        beginSummary(article: article, redditPost: redditPost)

        if settings.selectedSummaryProvider == .webAI {
            if let article = article {
                let sourceText = cleanedArticleContent(article)
                performWebAIRequest(
                    title: "Article Summary",
                    prompt: articleSummaryPrompt(for: article),
                    onSuccess: { [weak self] summary in
                        guard let self else { return }
                        let constrained = self.enforceArticleSummaryLength(summary, sourceText: sourceText)
                        self.updateArticleSummaryFromCloud(article, summary: constrained)
                        self.isLoading = false
                    },
                    onFailure: { [weak self] _ in
                        self?.finishSummary(article: article, redditPost: redditPost)
                        self?.isLoading = false
                    }
                )
            } else if let post = redditPost {
                performWebAIRequest(
                    title: "Reddit Summary",
                    prompt: redditPostSummaryPrompt(post: post, comments: redditComments),
                    onSuccess: { [weak self] summary in
                        self?.updateRedditPostSummaryFromCloud(post, summary: summary)
                        self?.isLoading = false
                    },
                    onFailure: { [weak self] _ in
                        self?.finishSummary(article: article, redditPost: redditPost)
                        self?.isLoading = false
                    }
                )
            } else {
                finishSummary(article: article, redditPost: redditPost)
                isLoading = false
            }
            return
        }

        // Only use Gemini if it's selected
        if settings.selectedSummaryProvider == .gemini {
            if let article = article {
                summarizeArticle(article)
            } else if let post = redditPost {
                summarizeRedditPost(post, comments: redditComments)
            } else {
                finishSummary(article: article, redditPost: redditPost)
            }
        } else if settings.selectedSummaryProvider == .appleLocal {
            // Use on-device AI with Gemini fallback
            let textToSummarize = article.map(cleanedArticleContent)
                ?? redditPost.map { redditSummarySourceText(post: $0, comments: redditComments) }
                ?? ""
            let prompt = article.map(articleSummaryPrompt(for:))
                ?? redditPost.map { redditPostSummaryPrompt(post: $0, comments: redditComments) }
                ?? ""
            let taskName = article != nil ? "Article Summary" : "Reddit Post Summary"
            let articleSourceForLength = textToSummarize

            let t0 = Date()
            performLocalWithGeminiFallback(prompt: prompt, taskName: taskName, completion: { [weak self] summary in
                let elapsed = Date().timeIntervalSince(t0)
                Task { @MainActor [weak self] in self?.recordAppleLocalThroughput(text: summary, elapsed: elapsed) }
                if let article = article {
                    let constrained = self?.enforceArticleSummaryLength(summary, sourceText: articleSourceForLength) ?? summary
                    self?.updateArticleSummaryFromCloud(article, summary: constrained)
                } else if let post = redditPost {
                    self?.updateRedditPostSummaryFromCloud(post, summary: summary)
                }
                self?.finishSummary(article: article, redditPost: redditPost)
            }, onCancel: { [weak self] in
                self?.finishSummary(article: article, redditPost: redditPost)
            })
        } else if settings.selectedSummaryProvider == .mlxLocal || settings.selectedSummaryProvider == .coreAIMLXLocal {
            // Use selected local model
            let textToSummarize = article.map(cleanedArticleContent)
                ?? redditPost.map { redditSummarySourceText(post: $0, comments: redditComments) }
                ?? ""
            let mlxPrompt = article.map(articleSummaryPrompt(for:))
                ?? redditPost.map { redditPostSummaryPrompt(post: $0, comments: redditComments) }
                ?? ""
            let articleSourceForLength = textToSummarize
            performMLXLocalSummary(prompt: mlxPrompt, completion: { [weak self] summary in
                if let article = article {
                    let constrained = self?.enforceArticleSummaryLength(summary, sourceText: articleSourceForLength) ?? summary
                    self?.updateArticleSummaryFromCloud(article, summary: constrained)
                } else if let post = redditPost {
                    self?.updateRedditPostSummaryFromCloud(post, summary: summary)
                }
                self?.finishSummary(article: article, redditPost: redditPost)
            }, onCancel: { [weak self] in
                self?.finishSummary(article: article, redditPost: redditPost)
            })
        } else if settings.selectedSummaryProvider == .summarizeDaemon {
            let textToSummarize = article.map(cleanedArticleContent)
                ?? redditPost.map { redditSummarySourceText(post: $0, comments: redditComments) }
                ?? ""
            let prompt = article.map(articleSummaryPrompt(for:))
                ?? redditPost.map { redditPostSummaryPrompt(post: $0, comments: redditComments) }
                ?? ""
            let taskName = article != nil ? "Article Summary" : "Reddit Post Summary"
            performSummarizeSummaryPublic(prompt: prompt, taskName: taskName) { [weak self] summary in
                if let article = article {
                    let constrained = self?.enforceArticleSummaryLength(summary, sourceText: textToSummarize) ?? summary
                    self?.updateArticleSummaryFromCloud(article, summary: constrained)
                } else if let post = redditPost {
                    self?.updateRedditPostSummaryFromCloud(post, summary: summary)
                }
                self?.finishSummary(article: article, redditPost: redditPost)
            }
        } else if settings.selectedSummaryProvider == .applePCCGateway {
            let textToSummarize = article.map(cleanedArticleContent)
                ?? redditPost.map { redditSummarySourceText(post: $0, comments: redditComments) }
                ?? ""
            let prompt = article.map(articleSummaryPrompt(for:))
                ?? redditPost.map { redditPostSummaryPrompt(post: $0, comments: redditComments) }
                ?? ""
            let taskName = article != nil ? "Article Summary" : "Reddit Post Summary"
            performPCCGatewaySummaryPublic(prompt: prompt, taskName: taskName) { [weak self] summary in
                if let article = article {
                    let constrained = self?.enforceArticleSummaryLength(summary, sourceText: textToSummarize) ?? summary
                    self?.updateArticleSummaryFromCloud(article, summary: constrained)
                } else if let post = redditPost {
                    self?.updateRedditPostSummaryFromCloud(post, summary: summary)
                }
                self?.finishSummary(article: article, redditPost: redditPost)
            }
        } else {
            // Apple Cloud via Private Cloud Compute
            launchCloudSummaryForContent(article: article, redditPost: redditPost)
        }
    }

    // MARK: - Today Summary
    func summarizeTodayTopics() {
        todaySummaryCancellable?.cancel()
        todaySummaryCancellable = nil

        let calendar = Calendar.current

        let todayArticles = feeds.flatMap { $0.articles }
            .filter { calendar.isDateInToday($0.publishDate) && !$0.isRead }
            .sorted(by: { $0.publishDate > $1.publishDate })

        let todayRedditPosts = redditFeeds.flatMap { $0.posts }
            .filter { calendar.isDateInToday($0.publishDate) && !$0.isRead }
            .sorted(by: { $0.publishDate > $1.publishDate })

        guard !todayArticles.isEmpty || !todayRedditPosts.isEmpty else {
            todaySummaryResult = nil
            todaySummaryError = "No unseen articles or Reddit discussions from today to summarize."
            isGeneratingTodaySummary = false
            return
        }

        isGeneratingTodaySummary = true
        todaySummaryResult = nil
        todaySummaryError = nil
        todaySummaryInfo = nil

        let commentFetches = todayRedditPosts.map { post -> AnyPublisher<(RedditPost, [RedditCommentModel]), Never> in
            redditService.fetchComments(for: post.id, in: post.subreddit)
                .map { comments -> (RedditPost, [RedditCommentModel]) in
                    let topLevel = comments
                        .filter { $0.indentationLevel == 0 }
                        .sorted(by: { $0.score > $1.score })
                    return (post, Array(topLevel.prefix(5)))
                }
                .eraseToAnyPublisher()
        }

        let commentPublisher: AnyPublisher<[(RedditPost, [RedditCommentModel])], Never>
        if commentFetches.isEmpty {
            commentPublisher = Just([]).eraseToAnyPublisher()
        } else {
            commentPublisher = Publishers.MergeMany(commentFetches)
                .collect()
                .eraseToAnyPublisher()
        }

        todaySummaryCancellable = commentPublisher
            .flatMap { [weak self] commentPairs -> AnyPublisher<String, Never> in
                guard let self = self else {
                    return Just("Error: Unable to prepare summary context.").eraseToAnyPublisher()
                }
                let prompt = self.buildTodaySummaryPrompt(
                    articles: todayArticles,
                    redditPosts: todayRedditPosts,
                    commentsByPost: commentPairs
                )
                return self.todaySummaryPublisher(for: prompt)
            }
            .receive(on: RunLoop.main)
            .sink { [weak self] summary in
                guard let self = self else { return }
                self.isGeneratingTodaySummary = false
                let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
                // Detect provider max-length errors and surface a helpful UI hint
                let lower = trimmed.lowercased()
                if lower.contains("exceeded the maximum allowed length") || lower.contains("maximum allowed length") || lower.contains("too long") || lower.contains("request too large") {
                    self.todaySummaryResult = nil
                    self.todaySummaryError = "This request is too long for the selected provider. Please switch to the Gemini model in Settings → Summary Provider, or reduce the amount of content."
                    self.todaySummaryInfo = nil
                } else if let jsonMarkdown = self.parseTodaySummaryJSON(trimmed) {
                    if jsonMarkdown.isEmpty {
                        self.todaySummaryResult = nil
                        self.todaySummaryError = "The LLM returned an empty response."
                    } else {
                        self.todaySummaryResult = jsonMarkdown
                        self.todaySummaryError = nil
                        self.todaySummaryInfo = nil
                    }
                } else {
                    let normalized = self.normalizeTodaySummaryMarkdown(trimmed)
                    if normalized.isEmpty {
                        self.todaySummaryResult = nil
                        self.todaySummaryError = "The LLM returned an empty response."
                        self.todaySummaryInfo = nil
                    } else if normalized.lowercased().hasPrefix("error:") || normalized.contains("API key not configured") {
                        self.todaySummaryResult = nil
                        self.todaySummaryError = normalized
                        self.todaySummaryInfo = nil
                    } else {
                        self.todaySummaryResult = normalized
                        self.todaySummaryError = nil
                        self.todaySummaryInfo = nil
                    }
                }
                self.todaySummaryCancellable = nil
            }
    }

    func clearTodaySummary() {
        todaySummaryCancellable?.cancel()
        todaySummaryCancellable = nil
        isGeneratingTodaySummary = false
        todaySummaryResult = nil
        todaySummaryError = nil
    }

    private func overallSummaryProviderResolution() -> OverallSummaryProviderResolution {
        resolveOverallSummaryProvider(for: settings.selectedSummaryProvider)
    }

    private var hasExistingAggregateSummary: Bool {
        guard let summary = aggregateSummaryText?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return false
        }
        return !summary.isEmpty
    }

    private func globalSummaryContextKey(_ context: GlobalSummaryContext?) -> String? {
        guard let context else { return nil }
        switch context {
        case .allArticles:
            return "allArticles"
        case .allReddit(let topComments):
            return "allReddit:\(topComments)"
        case .todayArticles:
            return "todayArticles"
        case .todayReddit(let topComments):
            return "todayReddit:\(topComments)"
        case .feedArticles(let url):
            return "feedArticles:\(url)"
        case .subreddit(let name, let topComments):
            return "subreddit:\(name):\(topComments)"
        case .subredditHot(let name, let topComments):
            return "subredditHot:\(name):\(topComments)"
        case .subredditSorted(let name, let sortOption, let topComments):
            return "subredditSorted:\(name):\(sortOption.rawValue):\(topComments)"
        }
    }

    private func shouldPreserveAggregateSummary(for context: GlobalSummaryContext) -> Bool {
        hasExistingAggregateSummary && globalSummaryContextKey(lastGlobalSummaryContext) == globalSummaryContextKey(context)
    }

    #if os(iOS)
    private func prepareGlobalSummaryBackgroundHandleIfNeeded(title: String, providerOverride: AppSettings.SummaryProvider? = nil) -> Any? {
        let provider = providerOverride ?? overallSummaryProviderResolution().effectiveProvider
        guard provider == .gemini else {
            globalBackgroundHandle = nil
            return nil
        }

        let handle = GeminiBackgroundTaskManager.shared.beginLongRunningTask(
            identifier: GeminiBackgroundTaskManager.shared.taskIdentifier(for: .summarization),
            title: title
        )
        globalBackgroundHandle = handle
        return handle
    }
    #else
    private func prepareGlobalSummaryBackgroundHandleIfNeeded(title: String, providerOverride: AppSettings.SummaryProvider? = nil) -> Any? {
        nil
    }
    #endif

    private var selectedOverallLocalProviderName: String? {
        switch settings.selectedSummaryProvider {
        case .appleLocal:
            return "Apple Local"
        case .mlxLocal:
            return "LiteRT Local"
        case .coreAIMLXLocal:
            return "CoreAI MLX Local"
        case .gemini, .appleCloud, .applePCCGateway, .webAI, .summarizeDaemon:
            return nil
        }
    }

    @MainActor
    private func presentOverallSummaryReroute(
        providerName: String,
        itemCount: Int,
        sourceName: String,
        onRoute: @escaping @MainActor (AppSettings.SummaryProvider) -> Void
    ) {
        isLoading = false
        let message = "\(providerName) cannot run this Overall Summary directly for \(itemCount) \(sourceName). Choose a remote or cloud provider to run it."
        pendingLocalReroute = LocalRerouteRequest(
            message: message,
            routeStartHandler: { [weak self] _ in
                self?.isLoading = true
                self?.lastGlobalSummaryError = nil
            },
            routeHandler: { provider in
                onRoute(provider.summaryProvider)
            },
            cancelHandler: { [weak self] in
                self?.isLoading = false
                self?.lastGlobalSummaryError = "Overall Summary routing cancelled."
            }
        )
    }

    private func runArticlesGlobalSummary(
        articles: [Article],
        providerOverride: AppSettings.SummaryProvider? = nil
    ) {
        let existingHandle = prepareGlobalSummaryBackgroundHandleIfNeeded(
            title: "Summarizing \(articles.count) Articles",
            providerOverride: providerOverride
        )

        globalSummaryService
            .summarizeArticlesGlobally(
                articles: articles,
                existingBackgroundTaskHandle: existingHandle,
                providerOverride: providerOverride
            )
            .receive(on: RunLoop.main)
            .sink { [weak self] result in
                guard let self = self else { return }
                self.processGlobalSummaryResult(result)
            }
            .store(in: &cancellables)
    }

    private func runRedditGlobalSummary(
        posts: [RedditPost],
        topComments: Int,
        providerOverride: AppSettings.SummaryProvider? = nil
    ) {
        let existingHandle = prepareGlobalSummaryBackgroundHandleIfNeeded(
            title: "Summarizing \(posts.count) Reddit Posts",
            providerOverride: providerOverride
        )

        globalSummaryService
            .summarizeRedditGlobally(
                posts: posts,
                topComments: topComments,
                existingBackgroundTaskHandle: existingHandle,
                providerOverride: providerOverride
            )
            .receive(on: RunLoop.main)
            .sink { [weak self] result in
                guard let self = self else { return }
                self.processGlobalSummaryResult(result)
            }
            .store(in: &cancellables)
    }

    private func hydratedRedditFeed(_ redditFeed: RedditFeed, sortOption: RedditService.SortOption) -> RedditFeed {
        var processedFeed = redditFeed
        let existingSummaries = redditFeeds
            .first(where: { $0.subreddit == redditFeed.subreddit })?
            .posts
            .reduce(into: [String: String]()) { result, post in
                if let summary = post.summary, !summary.isEmpty {
                    result[post.id] = summary
                }
            } ?? [:]
        for index in 0..<processedFeed.posts.count {
            let id = processedFeed.posts[index].id
            processedFeed.posts[index].isRead = persistenceManager.isRedditPostRead(processedFeed.posts[index])
            processedFeed.posts[index].isFavorite = persistenceManager.isRedditPostFavorite(id) ?? false
            if processedFeed.posts[index].summary == nil {
                processedFeed.posts[index].summary = existingSummaries[id]
            }
        }

        if sortOption == .new {
            let stickied = processedFeed.posts.filter { $0.isStickied }
            let nonStickied = processedFeed.posts.filter { !$0.isStickied }
                .sorted { $0.publishDate > $1.publishDate }
            processedFeed.posts = stickied + nonStickied
        }

        return processedFeed
    }

    private func recordRedditFetchMetadata(_ redditFeed: RedditFeed, subreddit: String) {
        if let message = redditFeed.fetchStatusMessage, !message.isEmpty {
            redditFeedStatusMessages[subreddit] = message
        } else {
            redditFeedStatusMessages.removeValue(forKey: subreddit)
        }

        if let cooldownUntil = redditFeed.rateLimitCooldownUntil, cooldownUntil > Date() {
            redditRateLimitCooldowns[subreddit] = cooldownUntil
        } else {
            redditRateLimitCooldowns.removeValue(forKey: subreddit)
        }
    }

    private func updateVisibleRedditFeedIfNeeded(_ redditFeed: RedditFeed, sortOption: RedditService.SortOption) {
        guard sortOption == redditSortOption else { return }

        if let index = redditFeeds.firstIndex(where: { $0.subreddit == redditFeed.subreddit }) {
            var updatedFeeds = redditFeeds
            updatedFeeds[index] = redditFeed
            redditFeeds = updatedFeeds
        } else {
            redditFeeds.append(redditFeed)
        }
    }

    private func subredditSummaryContext(
        subreddit: String,
        sortOption: RedditService.SortOption,
        topComments: Int
    ) -> GlobalSummaryContext {
        if sortOption == .hot {
            return .subredditHot(name: subreddit, topComments: topComments)
        }
        return .subredditSorted(name: subreddit, sortOption: sortOption, topComments: topComments)
    }

    private func beginSubredditGlobalSummary(
        posts: [RedditPost],
        subreddit: String,
        topComments: Int,
        context: GlobalSummaryContext,
        emptyLogMessage: String,
        emptyUserMessage: String
    ) {
#if os(iOS)
        batchPodcastSession.invalidate()
#endif
        globalSummaryPosts = posts
        globalSummaryArticles = []
        cachedRedditCommentsForQA = []
        hasCachedSummary = false

        let subredditCooldowns = activeCooldowns(forSubreddits: Set([subreddit]))
        if !subredditCooldowns.isEmpty {
            let affected = "r/\(subreddit)"
            print("⚠️ AppState.Global: Blocking subreddit summary — API cooldown active for \(affected)")
            lastGlobalSummaryContext = context
            handleRedditSummaryCooldown(entries: subredditCooldowns)
            return
        }

        guard !posts.isEmpty else {
            print("❌ AppState.Global: \(emptyLogMessage)")
            lastGlobalSummaryError = emptyUserMessage
            let escaped = emptyUserMessage.replacingOccurrences(of: "\"", with: "\\\"")
            globalSummaryJSON = "{\"source\":\"reddit\",\"summaries\":[],\"error\":\"\(escaped)\"}"
            hasCachedSummary = false
            showGlobalSummary = true
            isLoading = false
            lastGlobalSummaryContext = context
            return
        }

        let preserveExistingAggregateSummary = shouldPreserveAggregateSummary(for: context)
        resetAggregateSummaryState(preservingCurrentSummary: preserveExistingAggregateSummary)
        isLoading = true
        lastGlobalSummaryError = nil
        if !preserveExistingAggregateSummary {
            globalSummaryJSON = "{\"source\":\"reddit\",\"summaries\":[],\"error\":null}"
        }
        hasCachedSummary = true
        showGlobalSummary = true
        lastGlobalSummaryContext = context

        if settings.selectedSummaryProvider == .webAI {
            summarizeRedditPostsGloballyWithWebAI(posts, topComments: topComments)
            return
        }

        if let providerName = selectedOverallLocalProviderName {
            presentOverallSummaryReroute(
                providerName: providerName,
                itemCount: posts.count,
                sourceName: "Reddit posts"
            ) { [weak self] provider in
                self?.runRedditGlobalSummary(posts: posts, topComments: topComments, providerOverride: provider)
            }
            return
        }

        runRedditGlobalSummary(posts: posts, topComments: topComments)
    }

    private func summarizeSubredditSortedPostsGlobally(
        subreddit: String,
        sortOption: RedditService.SortOption,
        includeReadPosts: Bool = true,
        topComments: Int = 10
    ) {
        let context = subredditSummaryContext(
            subreddit: subreddit,
            sortOption: sortOption,
            topComments: topComments
        )

        let subredditCooldowns = activeCooldowns(forSubreddits: Set([subreddit]))
        if !subredditCooldowns.isEmpty {
            let affected = "r/\(subreddit)"
            print("⚠️ AppState.Global: Blocking \(sortOption.displayName) subreddit summary — API cooldown active for \(affected)")
            lastGlobalSummaryContext = context
            handleRedditSummaryCooldown(entries: subredditCooldowns)
            return
        }

        let preserveExistingAggregateSummary = shouldPreserveAggregateSummary(for: context)
        resetAggregateSummaryState(preservingCurrentSummary: preserveExistingAggregateSummary)
        isLoading = true
        lastGlobalSummaryError = nil
        if !preserveExistingAggregateSummary {
            globalSummaryJSON = "{\"source\":\"reddit\",\"summaries\":[],\"error\":null}"
        }
        hasCachedSummary = true
        showGlobalSummary = true
        lastGlobalSummaryContext = context

        redditService.fetchSubreddit(subreddit: subreddit, sortOption: sortOption)
            .receive(on: RunLoop.main)
            .sink { [weak self] redditFeed in
                guard let self else { return }

                self.recordRedditFetchMetadata(redditFeed, subreddit: subreddit)
                let processedFeed = self.hydratedRedditFeed(redditFeed, sortOption: sortOption)
                self.updateVisibleRedditFeedIfNeeded(processedFeed, sortOption: sortOption)

                let selectedPosts = includeReadPosts
                    ? processedFeed.posts
                    : processedFeed.posts.filter { !$0.isRead }
                let posts = Array(selectedPosts.prefix(50))
                let fallbackEmptyMessage = includeReadPosts
                    ? "No \(sortOption.displayName.lowercased()) posts in this subreddit to summarize."
                    : "No unread \(sortOption.displayName.lowercased()) posts in this subreddit to summarize."
                let fetchMessage = processedFeed.fetchStatusMessage?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let emptyUserMessage = fetchMessage.isEmpty ? fallbackEmptyMessage : fetchMessage

                self.beginSubredditGlobalSummary(
                    posts: posts,
                    subreddit: subreddit,
                    topComments: topComments,
                    context: context,
                    emptyLogMessage: "No \(sortOption.displayName) posts in subreddit to summarize.",
                    emptyUserMessage: emptyUserMessage
                )
            }
            .store(in: &cancellables)
    }

    // MARK: - Global Summaries
    func summarizeAllArticlesGlobally() {
        let articles = feeds
            .flatMap { $0.articles }
            .filter { !$0.isRead }
            .sorted(by: { $0.publishDate > $1.publishDate })

#if os(iOS)
        batchPodcastSession.invalidate()
#endif
        globalSummaryArticles = articles
        globalSummaryPosts = []
        cachedRedditCommentsForQA = []  // Clear comment cache when generating new summary
        hasCachedSummary = false

        guard !articles.isEmpty else {
            print("❌ AppState.Global: No unread articles available to summarize.")
            lastGlobalSummaryError = "No unread articles available to summarize."
            globalSummaryJSON = "{\"source\":\"articles\",\"summaries\":[],\"error\":\"No unread articles available.\"}"
            hasCachedSummary = false
            showGlobalSummary = true
            return
        }

        let context: GlobalSummaryContext = .allArticles
        let preserveExistingAggregateSummary = shouldPreserveAggregateSummary(for: context)
        resetAggregateSummaryState(preservingCurrentSummary: preserveExistingAggregateSummary)
        isLoading = true
        lastGlobalSummaryError = nil
        if !preserveExistingAggregateSummary {
            globalSummaryJSON = "{\"source\":\"articles\",\"summaries\":[],\"error\":null}"
        }
        hasCachedSummary = true  // Enable minimize button immediately
        showGlobalSummary = true
        lastGlobalSummaryContext = context

        if settings.selectedSummaryProvider == .webAI {
            summarizeArticlesGloballyWithWebAI(articles)
            return
        }

        if let providerName = selectedOverallLocalProviderName {
            presentOverallSummaryReroute(
                providerName: providerName,
                itemCount: articles.count,
                sourceName: "articles"
            ) { [weak self] provider in
                self?.runArticlesGlobalSummary(articles: articles, providerOverride: provider)
            }
            return
        }

        runArticlesGlobalSummary(articles: articles)
    }

    func summarizeAllRedditGlobally(topComments: Int = 3) {
        let posts = redditFeeds
            .flatMap { $0.posts }
            .filter { !$0.isRead }
            .sorted(by: { $0.publishDate > $1.publishDate })

#if os(iOS)
        batchPodcastSession.invalidate()
#endif
        globalSummaryPosts = posts
        globalSummaryArticles = []
        cachedRedditCommentsForQA = []  // Clear comment cache when generating new summary
        hasCachedSummary = false

        guard !posts.isEmpty else {
            print("❌ AppState.Global: No unread Reddit posts available to summarize.")
            lastGlobalSummaryError = "No unread Reddit posts available to summarize."
            globalSummaryJSON = "{\"source\":\"reddit\",\"summaries\":[],\"error\":\"No unread Reddit posts available.\"}"
            hasCachedSummary = false
            showGlobalSummary = true
            return
        }

        let cooldownEntries = activeCooldowns(forSubreddits: Set(posts.map { $0.subreddit }))
        if !cooldownEntries.isEmpty {
            let affected = cooldownEntries.map { "r/\($0.0)" }.joined(separator: ", ")
            print("⚠️ AppState.Global: Blocking Reddit summary — API cooldown active for \(affected)")
            lastGlobalSummaryContext = .allReddit(topComments: topComments)
            handleRedditSummaryCooldown(entries: cooldownEntries)
            return
        }

        let context: GlobalSummaryContext = .allReddit(topComments: topComments)
        let preserveExistingAggregateSummary = shouldPreserveAggregateSummary(for: context)
        resetAggregateSummaryState(preservingCurrentSummary: preserveExistingAggregateSummary)
        isLoading = true
        lastGlobalSummaryError = nil
        if !preserveExistingAggregateSummary {
            globalSummaryJSON = "{\"source\":\"reddit\",\"summaries\":[],\"error\":null}"
        }
        hasCachedSummary = true  // Enable minimize button immediately
        showGlobalSummary = true
        lastGlobalSummaryContext = context

        if settings.selectedSummaryProvider == .webAI {
            summarizeRedditPostsGloballyWithWebAI(posts, topComments: topComments)
            return
        }

        if let providerName = selectedOverallLocalProviderName {
            presentOverallSummaryReroute(
                providerName: providerName,
                itemCount: posts.count,
                sourceName: "Reddit posts"
            ) { [weak self] provider in
                self?.runRedditGlobalSummary(posts: posts, topComments: topComments, providerOverride: provider)
            }
            return
        }

        runRedditGlobalSummary(posts: posts, topComments: topComments)
    }

    func summarizeFeedArticlesGlobally(feedURL: String) {
        guard let feed = feeds.first(where: { $0.url == feedURL }) else {
            print("❌ AppState.Global: Feed not found for URL: \(feedURL)")
            lastGlobalSummaryError = "Feed not found."
            globalSummaryJSON = "{\"source\":\"articles\",\"summaries\":[],\"error\":\"Feed not found.\"}"
            hasCachedSummary = false
            showGlobalSummary = true
            return
        }

        let articles = feed.articles
            .filter { !$0.isRead }
            .sorted(by: { $0.publishDate > $1.publishDate })

#if os(iOS)
        batchPodcastSession.invalidate()
#endif
        globalSummaryArticles = articles
        globalSummaryPosts = []
        cachedRedditCommentsForQA = []  // Clear comment cache when generating new summary
        hasCachedSummary = false

        guard !articles.isEmpty else {
            print("❌ AppState.Global: No unread articles in feed to summarize.")
            lastGlobalSummaryError = "No unread articles in this feed to summarize."
            globalSummaryJSON = "{\"source\":\"articles\",\"summaries\":[],\"error\":\"No unread articles in this feed to summarize.\"}"
            hasCachedSummary = false
            showGlobalSummary = true
            return
        }

        let context: GlobalSummaryContext = .feedArticles(url: feedURL)
        let preserveExistingAggregateSummary = shouldPreserveAggregateSummary(for: context)
        resetAggregateSummaryState(preservingCurrentSummary: preserveExistingAggregateSummary)
        isLoading = true
        lastGlobalSummaryError = nil
        if !preserveExistingAggregateSummary {
            globalSummaryJSON = "{\"source\":\"articles\",\"summaries\":[],\"error\":null}"
        }
        hasCachedSummary = true  // Enable minimize button immediately
        showGlobalSummary = true
        lastGlobalSummaryContext = context

        if settings.selectedSummaryProvider == .webAI {
            summarizeArticlesGloballyWithWebAI(articles)
            return
        }

        if let providerName = selectedOverallLocalProviderName {
            presentOverallSummaryReroute(
                providerName: providerName,
                itemCount: articles.count,
                sourceName: "articles"
            ) { [weak self] provider in
                self?.runArticlesGlobalSummary(articles: articles, providerOverride: provider)
            }
            return
        }

        runArticlesGlobalSummary(articles: articles)
    }

    func summarizeSubredditPostsGlobally(subreddit: String, topComments: Int = 10) {
        summarizeSubredditSortedPostsGlobally(subreddit: subreddit, sortOption: .new, includeReadPosts: false, topComments: topComments)
    }

    func summarizeSubredditHotPostsGlobally(subreddit: String, topComments: Int = 10) {
        summarizeSubredditSortedPostsGlobally(subreddit: subreddit, sortOption: .hot, topComments: topComments)
    }

    func summarizeSubredditTopDayPostsGlobally(subreddit: String, topComments: Int = 10) {
        summarizeSubredditSortedPostsGlobally(subreddit: subreddit, sortOption: .topDay, topComments: topComments)
    }

    func summarizeSubredditTopWeekPostsGlobally(subreddit: String, topComments: Int = 10) {
        summarizeSubredditSortedPostsGlobally(subreddit: subreddit, sortOption: .topWeek, topComments: topComments)
    }

    private func summarizeSubredditPostsGloballyInternal(subreddit: String, topComments: Int, includeReadPosts: Bool) {
        guard let feed = redditFeeds.first(where: { $0.subreddit == subreddit }) else {
            print("❌ AppState.Global: Subreddit not found: \(subreddit)")
            lastGlobalSummaryError = "Subreddit feed not found."
            globalSummaryJSON = "{\"source\":\"reddit\",\"summaries\":[],\"error\":\"Subreddit feed not found.\"}"
            hasCachedSummary = false
            showGlobalSummary = true
            return
        }

        let posts: [RedditPost]
        let context: GlobalSummaryContext
        if includeReadPosts {
            posts = Array(feed.posts.prefix(50))
            context = .subredditHot(name: subreddit, topComments: topComments)
        } else {
            posts = feed.posts
                .filter { !$0.isRead }
                .sorted(by: { $0.publishDate > $1.publishDate })
            context = .subreddit(name: subreddit, topComments: topComments)
        }

        let emptyLogMessage = includeReadPosts
            ? "No posts in subreddit to summarize."
            : "No unread posts in subreddit to summarize."
        let emptyUserMessage = includeReadPosts
            ? "No posts in this subreddit to summarize."
            : "No unread posts in this subreddit to summarize."

        beginSubredditGlobalSummary(
            posts: posts,
            subreddit: subreddit,
            topComments: topComments,
            context: context,
            emptyLogMessage: emptyLogMessage,
            emptyUserMessage: emptyUserMessage
        )
    }

    private func summarizeArticlesGloballyWithWebAI(_ articles: [Article]) {
        Task(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            await MainActor.run {
                self.isWebAIHandoffMinimized = true
                self.isWebAIBatchHandoffInProgress = true
            }

            var summaries: [GlobalSummaryItem] = []
            var errorMessage: String?

            for (index, article) in articles.enumerated() {
                do {
                    let rawSummary = try await self.performWebAIRequestAsync(
                        title: "Article Summary \(index + 1) of \(articles.count)",
                        prompt: self.articleSummaryPrompt(for: article)
                    )
                    let sourceText = self.cleanedArticleContent(article)
                    let constrained = self.enforceArticleSummaryLength(rawSummary, sourceText: sourceText)
                    let cleaned = self.cleanAndFormatSummaryTextForDisplay(constrained)

                    await MainActor.run {
                        self.updateArticleSummaryFromCloud(article, summary: cleaned)
                    }

                    summaries.append(
                        GlobalSummaryItem(
                            subject: article.title.isEmpty ? "Article \(index + 1)" : article.title,
                            summary: cleaned,
                            referenceId: article.id
                        )
                    )
                } catch {
                    errorMessage = error.localizedDescription
                    break
                }
            }

            let result = GlobalSummaryResult(source: "articles", summaries: summaries, error: errorMessage)
            await MainActor.run {
                self.isWebAIBatchHandoffInProgress = false
                self.isWebAIHandoffMinimized = false
                self.processGlobalSummaryResult(result)
            }
        }
    }

    private func summarizeRedditPostsGloballyWithWebAI(_ posts: [RedditPost], topComments: Int) {
        Task(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            await MainActor.run {
                self.isWebAIHandoffMinimized = true
                self.isWebAIBatchHandoffInProgress = true
            }

            var summaries: [GlobalSummaryItem] = []
            var errorMessage: String?
            var cachedCommentContexts: [(RedditPost, [String])] = []

            for (index, post) in posts.enumerated() {
                let comments = await self.fetchTopCommentsForWebGlobalSummary(post: post, topComments: topComments)
                cachedCommentContexts.append(
                    (post, comments.map { "u/\($0.author): \($0.body)" })
                )

                do {
                    let rawSummary = try await self.performWebAIRequestAsync(
                        title: "Reddit Summary \(index + 1) of \(posts.count)",
                        prompt: self.redditPostSummaryPrompt(post: post, comments: comments)
                    )
                    let cleaned = self.cleanAndFormatRedditSummaryTextForDisplay(rawSummary)

                    await MainActor.run {
                        self.updateRedditPostSummaryFromCloud(post, summary: cleaned)
                    }

                    summaries.append(
                        GlobalSummaryItem(
                            subject: post.title.isEmpty ? "Reddit Post \(index + 1)" : post.title,
                            summary: cleaned,
                            referenceId: post.id
                        )
                    )
                } catch {
                    errorMessage = error.localizedDescription
                    break
                }
            }

            let result = GlobalSummaryResult(source: "reddit", summaries: summaries, error: errorMessage)
            await MainActor.run {
                self.cachedRedditCommentsForQA = cachedCommentContexts
                self.isWebAIBatchHandoffInProgress = false
                self.isWebAIHandoffMinimized = false
                self.processGlobalSummaryResult(result)
            }
        }
    }

    private func fetchTopCommentsForWebGlobalSummary(post: RedditPost, topComments: Int) async -> [RedditCommentModel] {
        await withCheckedContinuation { continuation in
            var cancellable: AnyCancellable?
            cancellable = redditService
                .fetchCommentsDetailed(for: post.id, in: post.subreddit, limit: topComments, depth: 0)
                .receive(on: RunLoop.main)
                .sink { result in
                    if let error = result.error {
                        print("⚠️ AppState.WebAI: Comment fetch error for \(post.id): \(error.localizedDescription)")
                    }

                    let filtered = result.comments
                        .filter { $0.author.lowercased() != "automoderator" }
                        .sorted { $0.score > $1.score }

                    continuation.resume(returning: Array(filtered.prefix(max(1, topComments))))
                    cancellable?.cancel()
                }
            if let cancellable {
                self.cancellables.insert(cancellable)
            }
        }
    }

    private func processGlobalSummaryResult(_ result: GlobalSummaryResult) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        if let data = try? encoder.encode(result),
           let json = String(data: data, encoding: .utf8) {
            globalSummaryJSON = json
            hasCachedSummary = true
            print("✅ AppState.Global: Stored summary JSON (\(json.count) chars)")
        } else {
            globalSummaryJSON = "{\"source\":\"\(result.source)\",\"summaries\":[],\"error\":\"Encoding failure\"}"
            print("❌ AppState.Global: Failed to encode summary JSON")
        }
        lastGlobalSummaryError = result.error
        isLoading = false
        showGlobalSummary = true

        // Overall summary is user-triggered from the UI; do not auto-start it here.
        // Finish the background handle now that the source summaries are stored.
        #if os(iOS)
        if let handle = globalBackgroundHandle {
            handle.finish(success: (result.error == nil))
            globalBackgroundHandle = nil
        }
        #endif
    }

    // MARK: - Global Summary Retry
    func retryLastGlobalSummary() {
        guard let context = lastGlobalSummaryContext else { return }
        switch context {
        case .allArticles:
            summarizeAllArticlesGlobally()
        case .allReddit(let topComments):
            summarizeAllRedditGlobally(topComments: topComments)
        case .todayArticles, .todayReddit:
            // Today summaries not implemented in iPhone version
            break
        case .feedArticles(let url):
            summarizeFeedArticlesGlobally(feedURL: url)
        case .subreddit(let name, let topComments):
            summarizeSubredditPostsGlobally(subreddit: name, topComments: topComments)
        case .subredditHot(let name, let topComments):
            summarizeSubredditHotPostsGlobally(subreddit: name, topComments: topComments)
        case .subredditSorted(let name, let sortOption, let topComments):
            summarizeSubredditSortedPostsGlobally(subreddit: name, sortOption: sortOption, topComments: topComments)
        }
    }

    // MARK: - Aggregate Summary
    private func resetAggregateSummaryState(preservingCurrentSummary: Bool = false) {
        if preservingCurrentSummary {
            logAggregateSummaryEvent("Preserving existing overall summary for same global summary context")
        } else {
            aggregateSummaryText = nil
            aggregateSummarySourceFingerprint = nil
        }
        aggregateSummaryError = nil
        isGeneratingAggregateSummary = false
        aggregateSummaryTask?.cancel()
        aggregateSummaryTask = nil
    }

    private func logAggregateSummaryEvent(_ message: String) {
        let stack = Thread.callStackSymbols
            .dropFirst()
            .prefix(8)
            .joined(separator: "\n")
        print("📊 AppState.Aggregate: \(message)\nCall stack:\n\(stack)")
    }

    func generateCombinedGlobalSummary(force: Bool = false) {
        let sourceFingerprint = globalSummaryJSON
        let existingSummary = aggregateSummaryText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        logAggregateSummaryEvent(
            "Generate requested force=\(force) isGenerating=\(isGeneratingAggregateSummary) hasExistingSummary=\(!existingSummary.isEmpty) sourceChars=\(sourceFingerprint.count)"
        )

        guard !isGeneratingAggregateSummary else {
            logAggregateSummaryEvent("Ignoring request because aggregate generation is already running")
            return
        }

        if !force, !existingSummary.isEmpty {
            logAggregateSummaryEvent("Ignoring non-forced request because an overall summary is already visible")
            return
        }

        if force {
            logAggregateSummaryEvent("Forced overall summary regeneration accepted")
        }

        guard let data = globalSummaryJSON.data(using: .utf8),
              let result = try? JSONDecoder().decode(GlobalSummaryResult.self, from: data),
              !result.summaries.isEmpty else {
            aggregateSummaryError = "No summary data available to combine."
            aggregateSummaryText = nil
            aggregateSummarySourceFingerprint = nil
            isGeneratingAggregateSummary = false
            return
        }

        isGeneratingAggregateSummary = true
        aggregateSummaryError = nil
        aggregateSummaryText = nil
        aggregateSummarySourceFingerprint = nil
#if os(iOS)
        batchPodcastSession.invalidate()
#endif

        print("📊 AppState.Aggregate: Combining all \(result.summaries.count) summaries into aggregate")
        guard let prompt = combinedGlobalSummaryPrompt(for: result) else {
            aggregateSummaryError = "No summary data available to combine."
            aggregateSummaryText = nil
            aggregateSummarySourceFingerprint = nil
            isGeneratingAggregateSummary = false
            return
        }

        let providerResolution = overallSummaryProviderResolution()
        if providerResolution.localFallbackProviderName != nil {
            let providerName = providerResolution.localFallbackProviderName ?? settings.selectedSummaryProvider.displayName
            presentLocalReroute(
                providerName: providerName,
                prompt: prompt,
                taskName: "Overall Summary",
                appleRequestType: .globalSummary,
                completion: { [weak self] routedSummary in
                    guard let self else { return }
                    let trimmed = routedSummary.trimmingCharacters(in: .whitespacesAndNewlines)
                    let lowercased = trimmed.lowercased()
                    self.isGeneratingAggregateSummary = false
                    self.aggregateSummaryTask = nil
                    if trimmed.isEmpty {
                        self.aggregateSummaryError = "Failed to generate combined summary."
                        self.aggregateSummaryText = nil
                        self.aggregateSummarySourceFingerprint = nil
                    } else if lowercased.hasPrefix("error")
                        || lowercased.contains("api key not configured")
                        || lowercased.contains("choose a cloud or remote provider") {
                        self.aggregateSummaryError = trimmed
                        self.aggregateSummaryText = nil
                        self.aggregateSummarySourceFingerprint = nil
                    } else {
                        self.aggregateSummaryText = trimmed
                        self.aggregateSummarySourceFingerprint = sourceFingerprint
                        self.aggregateSummaryError = nil
                    }
                },
                onCancel: { [weak self] in
                    self?.isGeneratingAggregateSummary = false
                    self?.aggregateSummaryTask = nil
                },
                onRouteStart: { [weak self] _ in
                    self?.isGeneratingAggregateSummary = true
                    self?.aggregateSummaryError = nil
                    self?.aggregateSummaryText = nil
                    self?.aggregateSummarySourceFingerprint = nil
                }
            )
            return
        }

        #if os(iOS)
        let usesGeminiBackgroundTask = (providerResolution.effectiveProvider == .gemini)
        let manager = GeminiBackgroundTaskManager.shared
        let summarizationIdentifier: String? = usesGeminiBackgroundTask ? manager.taskIdentifier(for: .summarization) : nil
        let activityTitle = result.source == "reddit" ? "Combining Reddit Insights" : "Combining Article Insights"
        let aggregateContext = GeminiAggregateBackgroundContext()
        aggregateContext.handle = usesGeminiBackgroundTask ? globalBackgroundHandle : nil
        #else
        let summarizationIdentifier: String? = nil
        #endif

        aggregateSummaryTask?.cancel()
        aggregateSummaryTask = Task(priority: .userInitiated) { [weak self] in
            guard let self else { return }

            var generatedSummary: String?
            var errorMessage: String?

            #if os(iOS)
            // We already own the long-running session; no need to wait for idle
            if Task.isCancelled {
                await MainActor.run {
                    self.isGeneratingAggregateSummary = false
                    self.aggregateSummaryTask = nil
                }
                return
            }

            if usesGeminiBackgroundTask, aggregateContext.handle == nil {
                if let identifier = summarizationIdentifier {
                    let handle = manager.beginLongRunningTask(
                        identifier: identifier,
                        title: activityTitle
                    )
                    aggregateContext.handle = handle
                    handle.reportProgress(fractionCompleted: 0.1)
                    await handle.waitForTaskStartIfNeeded()
                }
            }

            if Task.isCancelled {
                if usesGeminiBackgroundTask {
                    aggregateContext.handle?.finish(success: false)
                    aggregateContext.handle = nil
                    globalBackgroundHandle = nil
                }
                await MainActor.run {
                    self.isGeneratingAggregateSummary = false
                    self.aggregateSummaryTask = nil
                }
                return
            }
            #endif

            if Task.isCancelled {
                await MainActor.run {
                    self.isGeneratingAggregateSummary = false
                    self.aggregateSummaryTask = nil
                }
                #if os(iOS)
                if usesGeminiBackgroundTask, let handle = aggregateContext.handle {
                    handle.finish(success: false)
                    aggregateContext.handle = nil
                    globalBackgroundHandle = nil
                }
                #endif
                return
            }
            do {
                let summary: String

                if let warning = providerResolution.fallbackNotification {
                    await MainActor.run {
                        self.fallbackNotification = warning
                        self.showFallbackNotification = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 6.0) { [weak self] in
                            self?.showFallbackNotification = false
                        }
                    }
                }

                switch providerResolution.effectiveProvider {
                case .gemini:
                    #if os(iOS)
                    let existingHandle: GeminiBackgroundTaskHandle? = aggregateContext.handle
                    #else
                    let existingHandle: Any? = nil
                    #endif

                    summary = try await self.summaryService.summarizeTextAsync(
                        "",
                        customPrompt: prompt,
                        preferredBackgroundTaskIdentifier: summarizationIdentifier,
                        existingBackgroundTaskHandle: existingHandle
                    )

                case .appleCloud:
                    print("☁️ AppState.Aggregate: Using Apple Cloud for overall summary")
                    summary = await withCheckedContinuation { continuation in
                        self.launchCloudRequest(for: prompt, type: .globalSummary, completion: { result in
                            continuation.resume(returning: result)
                        })
                    }

                case .webAI:
                    print("🌐 AppState.Aggregate: Using \(self.settings.selectedWebAIProvider.displayName) for overall summary")
                    await MainActor.run {
                        self.isWebAIHandoffMinimized = true
                    }
                    summary = try await self.performWebAIRequestAsync(
                        title: result.source == "reddit" ? "Combined Reddit Summary" : "Combined Article Summary",
                        prompt: prompt
                    )

                case .applePCCGateway:
                    print("☁️ AppState.Aggregate: Using Apple PCC Gateway for overall summary")
                    summary = try await self.performPCCPlainTextRequestAsync(
                        prompt: prompt,
                        taskName: result.source == "reddit" ? "Combined Reddit Summary" : "Combined Article Summary"
                    )

                case .summarizeDaemon:
                    print("⚡ AppState.Aggregate: Using Codex / Summarize for overall summary")
                    summary = try await self.performSummarizeRequestAsync(
                        prompt: prompt,
                        taskName: result.source == "reddit" ? "Combined Reddit Summary" : "Combined Article Summary"
                    )

                case .appleLocal, .mlxLocal, .coreAIMLXLocal:
                    #if os(iOS)
                    let existingHandle: GeminiBackgroundTaskHandle? = aggregateContext.handle
                    #else
                    let existingHandle: Any? = nil
                    #endif

                    summary = try await self.summaryService.summarizeTextAsync(
                        "",
                        customPrompt: prompt,
                        preferredBackgroundTaskIdentifier: summarizationIdentifier,
                        existingBackgroundTaskHandle: existingHandle
                    )
                }

                let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
                let lowercased = trimmed.lowercased()
                if trimmed.isEmpty || lowercased.hasPrefix("error") || lowercased.contains("api key not configured") {
                    errorMessage = trimmed.isEmpty ? "Failed to generate combined summary." : trimmed
                } else {
                    generatedSummary = trimmed
                }

                #if os(iOS)
                if usesGeminiBackgroundTask, let handle = aggregateContext.handle {
                    handle.reportProgress(fractionCompleted: 1.0)
                    handle.finish(success: generatedSummary != nil)
                    aggregateContext.handle = nil
                    globalBackgroundHandle = nil
                }
                #endif
            } catch is CancellationError {
                #if os(iOS)
                if usesGeminiBackgroundTask, let handle = aggregateContext.handle {
                    handle.finish(success: false)
                    aggregateContext.handle = nil
                    globalBackgroundHandle = nil
                }
                #endif
                if !Task.isCancelled {
                    errorMessage = "Error: Request cancelled."
                }
            } catch {
                #if os(iOS)
                if usesGeminiBackgroundTask, let handle = aggregateContext.handle {
                    handle.finish(success: false)
                    aggregateContext.handle = nil
                    globalBackgroundHandle = nil
                }
                #endif
                let trimmed = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
                errorMessage = trimmed.isEmpty ? "Failed to generate combined summary." : trimmed
            }

            await MainActor.run {
                self.isGeneratingAggregateSummary = false
                if let summary = generatedSummary {
                    self.aggregateSummaryText = summary
                    self.aggregateSummarySourceFingerprint = sourceFingerprint
                    self.aggregateSummaryError = nil
                } else if let message = errorMessage {
                    self.aggregateSummaryError = message
                    self.aggregateSummaryText = nil
                    self.aggregateSummarySourceFingerprint = nil
                }
                self.aggregateSummaryTask = nil
            }
        }
    }

    private func buildTodaySummaryPrompt(articles: [Article],
                                         redditPosts: [RedditPost],
                                         commentsByPost: [(RedditPost, [RedditCommentModel])]) -> String {
        let articleSection: String
        if articles.isEmpty {
            articleSection = "- None"
        } else {
            articleSection = articles.map { article in
                let source = article.summary ?? article.content
                let excerpt = previewText(from: source, maxCharacters: 5000)
                let displayExcerpt = excerpt.isEmpty ? "No excerpt available." : excerpt
                return "- \(article.title) [Source: \(article.feedTitle)]\n  Excerpt: \(displayExcerpt)"
            }.joined(separator: "\n")
        }

        var commentsLookup: [String: [RedditCommentModel]] = [:]
        for (post, comments) in commentsByPost {
            if let existing = commentsLookup[post.id] {
                commentsLookup[post.id] = existing + comments
            } else {
                commentsLookup[post.id] = comments
            }
        }

        let redditSection: String
        if redditPosts.isEmpty {
            redditSection = "- None"
        } else {
            redditSection = redditPosts.map { post in
                let postSnippet = previewText(from: post.content, maxCharacters: 2000)
                let snippet = postSnippet.isEmpty ? "No post text available." : postSnippet
                let comments = commentsLookup[post.id] ?? []
                let commentLines: [String]
                if comments.isEmpty {
                    commentLines = ["  Top Comments: none collected."]
                } else {
                    commentLines = ["  Top Comments:"] + comments.enumerated().map { index, comment in
                        // Send full comment text without truncation
                        let bodySnippet = comment.body.isEmpty ? "(no text)" : comment.body
                        return "    \(index + 1). u/\(comment.author): \(bodySnippet)"
                    }
                }
                let header = "- \(post.title) [r/\(post.subreddit)]\n  Post Snippet: \(snippet)"
                return ([header] + commentLines).joined(separator: "\n")
            }.joined(separator: "\n")
        }

        return """
        You are a topic clustering analyst. Analyze TODAY's items and merge RSS articles + Reddit posts that talk about the same subject.

        Articles:
        \(articleSection)

        Reddit Discussions:
        \(redditSection)

        Rules:
        - "Subject" = a concise label (≤6 words) that best covers multiple items (prefer merging over splitting).
        - Consider an item multi-topic only if unmistakably so; otherwise assign it to its primary subject.
        - Order subjects by: (1) number of items covered, then (2) recency of the newest item.
        - Cite sources only in the summary text; NEVER invent a source or subreddit. If unsure, omit it.
        - Output as many subjects as necessary while staying within 900 words total.
        - Double-check that every meaningful subject present in the inputs appears in the JSON summary.
        - Language: match the majority language of the inputs.
        - If nothing meaningfully clusters, return an empty array [].
        - Format must be VALID JSON (no code fences, no trailing commas), array of objects with EXACT keys:
          {
            "subject": string,   // ≤6 words
            "summary": string    // 1–2 sentences; mention notable sources and subreddits as (r/Name)
          }
        - No text before/after the JSON. Do not include item IDs, bullets, or extra keys.

        Return ONLY the JSON array. Keep TOTAL output ≤900 words.
        """
    }

    private func previewText(from rawText: String, maxCharacters: Int) -> String {
        let cleaned = cleanedText(rawText)
        guard !cleaned.isEmpty else { return "" }
        if cleaned.count <= maxCharacters { return cleaned }
        let index = cleaned.index(cleaned.startIndex, offsetBy: maxCharacters)
        let truncated = cleaned[..<index]
        if let lastSpace = truncated.lastIndex(of: " ") {
            return String(truncated[..<lastSpace]) + "…"
        }
        return String(truncated) + "…"
    }

    private func cleanedText(_ text: String) -> String {
        guard !text.isEmpty else { return "" }
        var stripped = text.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        let entities: [String: String] = [
            "&amp;": "&",
            "&lt;": "<",
            "&gt;": ">",
            "&quot;": "\"",
            "&#39;": "'",
            "&nbsp;": " "
        ]
        for (entity, replacement) in entities {
            stripped = stripped.replacingOccurrences(of: entity, with: replacement)
        }
        let components = stripped.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        return components.joined(separator: " ")
    }

    // Normalize common Markdown issues from LLM output so headings and paragraphs display clearly
    private func normalizeTodaySummaryMarkdown(_ text: String) -> String {
        var t = text
        // Ensure there's a newline BEFORE each heading token when missing
        t = t.replacingOccurrences(of: "(?<!\\n)(#{1,6}\\s+)", with: "\n$1", options: .regularExpression)
        // Ensure a newline AFTER a heading line when missing
        if let regex = try? NSRegularExpression(pattern: "^(#{1,6}\\s+[^\\n]+)(?!\\n)", options: [.anchorsMatchLines]) {
            let range = NSRange(t.startIndex..., in: t)
            t = regex.stringByReplacingMatches(in: t, options: [], range: range, withTemplate: "$1\n")
        }
        // Ensure a BLANK line between heading and its paragraph
        if let regex2 = try? NSRegularExpression(pattern: "^(#{1,6}\\s+[^\\n]+)\n(\\S)", options: [.anchorsMatchLines]) {
            let range2 = NSRange(t.startIndex..., in: t)
            t = regex2.stringByReplacingMatches(in: t, options: [], range: range2, withTemplate: "$1\n\n$2")
        }
        // Convert ATX headings (## Title) into bold inline headings so Text(.init(...)) renders them as headings
        if let headingToBold = try? NSRegularExpression(pattern: "^(?:\\s{0,3})#{1,6}\\s+(.+)$", options: [.anchorsMatchLines]) {
            let range = NSRange(t.startIndex..., in: t)
            t = headingToBold.stringByReplacingMatches(in: t, options: [], range: range, withTemplate: "**$1**\n")
        }
        // Remove stray bullet markers that may appear
        if let bulletCleanup = try? NSRegularExpression(pattern: "(?m)^-\\s*", options: []) {
            let range = NSRange(t.startIndex..., in: t)
            t = bulletCleanup.stringByReplacingMatches(in: t, options: [], range: range, withTemplate: "")
        }
        // Fallback: paragraph breaks after sentence punctuation
        if let sentenceRegex = try? NSRegularExpression(pattern: "([\\.\\!\\?])\\s+(?=[A-Z0-9])", options: []) {
            let range = NSRange(t.startIndex..., in: t)
            t = sentenceRegex.stringByReplacingMatches(in: t, options: [], range: range, withTemplate: "$1\n\n")
        }
        // Compact 3+ newlines into just two
        t = t.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        return t
    }

    private struct TodaySummaryTopic: Decodable {
        let subject: String
        let summary: String
    }

    private func parseTodaySummaryJSON(_ text: String) -> String? {
        guard let range = text.range(of: "\\[[\\s\\S]*\\]", options: .regularExpression) else {
            return nil
        }

        let jsonString = String(text[range])
        guard let data = jsonString.data(using: .utf8) else {
            return nil
        }

        do {
            let topics = try JSONDecoder().decode([TodaySummaryTopic].self, from: data)
            guard !topics.isEmpty else { return nil }

            let markdown = topics.map { topic -> String in
                let subject = topic.subject.trimmingCharacters(in: .whitespacesAndNewlines)
                let summary = topic.summary.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !subject.isEmpty, !summary.isEmpty else { return "" }
                return "**\(subject)**\n\n\(summary)\n"
            }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")

            return markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            print("⚠️ AppState: Failed to decode Today summary JSON: \(error)")
            return nil
        }
    }


    private func todaySummaryPublisher(for prompt: String) -> AnyPublisher<String, Never> {
        switch settings.selectedSummaryProvider {
        case .gemini:
            return summaryService.summarizeText("", customPrompt: prompt)

        case .appleLocal, .mlxLocal, .coreAIMLXLocal:
            // Overall summary combines many articles — too large for local models.
            // Immediately route to Gemini and surface an info banner.
            DispatchQueue.main.async { [weak self] in
                self?.todaySummaryInfo = "Local model exceeded context — using Gemini."
            }
            return summaryService.summarizeText("", customPrompt: prompt)

        case .appleCloud:
            return Future<String, Never> { promise in
                self.launchCloudRequest(for: prompt, type: .commentSummary) { result in
                    promise(.success(result))
                }
            }.eraseToAnyPublisher()
        case .webAI:
            return Future<String, Never> { promise in
                self.performWebAIRequest(
                    title: "Today Summary",
                    prompt: prompt,
                    onSuccess: { promise(.success($0)) },
                    onFailure: { promise(.success($0)) }
                )
            }
            .eraseToAnyPublisher()

        case .applePCCGateway:
            return Future<String, Never> { promise in
                Task(priority: .userInitiated) {
                    do {
                        let output = try await self.performPCCGatewayRequestAsync(prompt: prompt, taskName: "Today Summary")
                        promise(.success(output))
                    } catch {
                        promise(.success("Apple PCC Gateway error: \(error.localizedDescription)"))
                    }
                }
            }
            .eraseToAnyPublisher()

        case .summarizeDaemon:
            return Future<String, Never> { promise in
                Task(priority: .userInitiated) {
                    do {
                        let output = try await self.performSummarizeRequestAsync(prompt: prompt, taskName: "Today Summary")
                        promise(.success(output))
                    } catch {
                        promise(.success("Codex / Summarize error: \(error.localizedDescription)"))
                    }
                }
            }
            .eraseToAnyPublisher()
        }
    }

    private func launchCloudSummaryForContent(article: Article? = nil, redditPost: RedditPost? = nil) {
        var content = ""
        if let article = article {
            let cleanedContent = cleanedArticleContent(article)
            
            // Add prompt for paragraph-length summary
            let prompt = "Provide a one-paragraph summary (4-6 sentences) of this article's main points:\n\n"
            
            // Limit content length to avoid URL limits (around 10k chars)
            let maxLength = 10000
            let truncatedContent = cleanedContent.count > maxLength ? 
                String(cleanedContent.prefix(maxLength)) + "..." : cleanedContent
            
            // Use cleaned content if available, otherwise fall back to title
            content = cleanedContent.isEmpty ? article.title : (prompt + truncatedContent)
        } else if let post = redditPost {
            let prompt = "Provide a one-paragraph summary (4-6 sentences) of this Reddit post:\n\n"
            let maxLength = 10000
            let truncatedContent = post.content.count > maxLength ? 
                String(post.content.prefix(maxLength)) + "..." : post.content
            content = prompt + truncatedContent
        }
        
        print("📱 AppState: Launching \(settings.selectedSummaryProvider.rawValue) request")
        print("📱 AppState: Content length: \(content.count) characters")
        launchCloudRequest(for: content, type: .summary, completion: { [weak self] result in
            guard let self else { return }
            if let article {
                self.updateArticleSummaryFromCloud(article, summary: result)
            } else if let redditPost {
                self.updateRedditPostSummaryFromCloud(redditPost, summary: result)
            } else {
                self.finishSummary(article: article, redditPost: redditPost)
            }
        })
    }
    
    func launchCloudSummary(for text: String) {
        launchCloudRequest(for: text, type: .summary, completion: nil)
    }

    func launchCloudRequest(for text: String, type: AppleIntelligenceRequestType, useClipboardMonitoring: Bool = true, completion: ((String) -> Void)?) {
        #if canImport(FoundationModels)
        if #available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *) {
            launchPrivateCloudComputeRequest(for: text, type: type, completion: completion)
        } else {
            handleCloudResult(
                "Apple Cloud requires iOS 27, macOS 27, visionOS 27, or watchOS 27 with Apple Intelligence enabled.",
                for: type,
                completion: completion
            )
        }
        #else
        handleCloudResult(
            "Apple Cloud is unavailable because FoundationModels is not available in this build.",
            for: type,
            completion: completion
        )
        #endif
    }

    #if canImport(FoundationModels)
    @available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
    private func launchPrivateCloudComputeRequest(for text: String, type: AppleIntelligenceRequestType, completion: ((String) -> Void)?) {
        print("☁️ AppState: Using Apple Private Cloud Compute for \(type)")
        print("☁️ AppState: Prompt length: \(text.count) characters")
        setWaitingState(for: type)

        Task(priority: .userInitiated) { [weak self] in
            guard let self else { return }

            do {
                let response = try await self.performPrivateCloudComputeRequest(text)
                await MainActor.run {
                    self.clearWaitingState(for: type)
                    self.handleCloudResult(response, for: type, completion: completion)
                }
            } catch {
                let message = self.privateCloudComputeErrorMessage(error)
                await MainActor.run {
                    self.clearWaitingState(for: type)
                    self.handleCloudResult(message, for: type, completion: completion)
                }
            }
        }
    }

    @available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
    private func performPrivateCloudComputeRequest(_ prompt: String) async throws -> String {
        let model = PrivateCloudComputeLanguageModel()

        guard model.isAvailable else {
            throw NSError(domain: "ApplePrivateCloudCompute", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Apple Private Cloud Compute is unavailable: \(model.availability)"
            ])
        }

        let session = LanguageModelSession(model: model)
        let response = try await session.respond(
            to: prompt,
            contextOptions: ContextOptions(reasoningLevel: .moderate)
        )

        return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
    private func privateCloudComputeErrorMessage(_ error: Error) -> String {
        if let cloudError = error as? PrivateCloudComputeLanguageModel.Error {
            switch cloudError {
            case .networkFailure:
                return "Apple Cloud network error. Check your connection and try again."
            case .quotaLimitReached(let quota):
                if let resetDate = quota.resetDate {
                    return "Apple Cloud quota limit reached. Try again after \(resetDate.formatted())."
                }
                return "Apple Cloud quota limit reached."
            case .serviceUnavailable:
                return "Apple Cloud service is currently unavailable. Try again later."
            @unknown default:
                return "Apple Cloud error: \(cloudError.localizedDescription)"
            }
        }

        let description = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        if description.contains("private-cloud-compute") || description.contains("entitlement") {
            return "Apple Cloud requires the managed Private Cloud Compute entitlement: com.apple.developer.private-cloud-compute."
        }

        return description.isEmpty ? "Apple Cloud request failed." : "Apple Cloud error: \(description)"
    }
    #endif

    private func launchShortcutViaXCallback(text: String, type: AppleIntelligenceRequestType) {
        let callbackURL = "shortcuts://x-callback-url/run-shortcut"
        var components = URLComponents(string: callbackURL)!
        components.queryItems = [
            URLQueryItem(name: "name", value: "RSS Reader Cloud Summary"),
            URLQueryItem(name: "input", value: "text"),
            URLQueryItem(name: "text", value: text),
            URLQueryItem(name: "x-source", value: "RSS Reader"),
            URLQueryItem(name: "x-success", value: "rssreader://success"),
            URLQueryItem(name: "x-error", value: "rssreader://error")
        ]

        guard let url = components.url else {
            print("⚠️ AppState: Could not create x-callback URL")
            fallbackToRegularURL(text: text, type: type)
            return
        }

        print("📱 AppState: Using x-callback-url to run shortcut (type: \(type))")
        print("📱 AppState: Text length: \(text.count) characters")

        #if os(iOS)
        UIApplication.shared.open(url, options: [:]) { success in
            if success {
                print("✅ AppState: Successfully launched shortcut via x-callback-url")
            } else {
                print("⚠️ AppState: x-callback-url failed, falling back to regular URL")
                self.fallbackToRegularURL(text: text, type: type)
            }
        }
        #elseif os(macOS)
        NSWorkspace.shared.open(url)
        print("✅ AppState: Launched shortcut via x-callback-url on macOS")
        #endif
    }
    
    private func fallbackToRegularURL(text: String, type: AppleIntelligenceRequestType) {
        print("📱 AppState: Falling back to regular URL scheme (may open Shortcuts app)")
        
        // Create the regular Shortcuts URL with text as input
        let baseURL = "shortcuts://run-shortcut"
        var components = URLComponents(string: baseURL)!
        
        components.queryItems = [
            URLQueryItem(name: "name", value: "RSS Reader Cloud Summary"),
            URLQueryItem(name: "input", value: "text"),
            URLQueryItem(name: "text", value: text)
        ]
        
        guard let url = components.url else {
            print("⚠️ AppState: Could not create URL from components")
            return
        }
        
        print("📱 AppState: Launching Shortcuts with direct text input for \(type)")
        print("📱 AppState: Text length: \(text.count) characters")
        
        // Launch Shortcuts app (will open the app)
        #if os(iOS)
        UIApplication.shared.open(url) { success in
            if success {
                print("✅ AppState: Successfully launched Shortcuts")
            } else {
                print("⚠️ AppState: Failed to launch Shortcuts")
            }
        }
        #elseif os(macOS)
        NSWorkspace.shared.open(url)
        print("✅ AppState: Launched Shortcuts on macOS")
        #endif
    }

#if os(macOS) || targetEnvironment(macCatalyst)
    private func runShortcutViaCLI(name: String, input: String, type: AppleIntelligenceRequestType, completion: ((String) -> Void)?) {
        setWaitingState(for: type)

        let tempDir = FileManager.default.temporaryDirectory
        let inputFile = tempDir.appendingPathComponent("shortcut_input_\(UUID().uuidString).txt")
        let outputFile = tempDir.appendingPathComponent("shortcut_output_\(UUID().uuidString).txt")

        do {
            try input.write(to: inputFile, atomically: true, encoding: .utf8)
        } catch {
            print("⚠️ AppState: Failed to write CLI input file - \(error.localizedDescription)")
            fallbackToXCallbackFromCLI(text: input, type: type, completion: completion)
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        process.arguments = [
            "run",
            name,
            "--input-path", inputFile.path,
            "--output-path", outputFile.path,
            "--output-type", "public.plain-text"
        ]

        let errorPipe = Pipe()
        process.standardError = errorPipe

        DispatchQueue.global(qos: .userInitiated).async {
            defer {
                try? FileManager.default.removeItem(at: inputFile)
                try? FileManager.default.removeItem(at: outputFile)
            }

            do {
                try process.run()
                process.waitUntilExit()

                let status = process.terminationStatus
                let stderrData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                let stderr = String(data: stderrData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                if status == 0 {
                    let output = (try? String(contentsOf: outputFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    DispatchQueue.main.async {
                        self.clearWaitingState(for: type)
                        self.handleCloudResult(output, for: type, completion: completion)
                    }
                } else {
                    let error = NSError(domain: "ShortcutsCLI", code: Int(status), userInfo: [NSLocalizedDescriptionKey: stderr.isEmpty ? "Shortcuts CLI failed" : stderr])
                    DispatchQueue.main.async {
                        print("⚠️ AppState: Shortcuts CLI failed (status \(status)): \(error.localizedDescription)")
                        self.clearWaitingState(for: type)
                        self.fallbackToXCallbackFromCLI(text: input, type: type, completion: completion)
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    print("⚠️ AppState: Shortcuts CLI threw error: \(error.localizedDescription)")
                    self.clearWaitingState(for: type)
                    self.fallbackToXCallbackFromCLI(text: input, type: type, completion: completion)
                }
            }
        }
    }

    private func fallbackToXCallbackFromCLI(text: String, type: AppleIntelligenceRequestType, completion: ((String) -> Void)?) {
        self.currentRequestType = type
        self.currentRequestCompletion = completion
        self.startClipboardMonitoring(for: type)
        self.launchShortcutViaXCallback(text: text, type: type)
    }
#endif

    private func handleCloudResult(_ result: String, for type: AppleIntelligenceRequestType, completion: ((String) -> Void)?) {
        // Surface provider-limit guidance to the user if applicable
        let lower = result.lowercased()
        if lower.contains("exceeded the maximum allowed length") || lower.contains("maximum allowed length") || lower.contains("request too large") || lower.contains("too long") {
            DispatchQueue.main.async {
                self.fallbackNotification = "This request is too long for Apple Intelligence. Please switch to the Gemini model in Settings → Summary Provider."
                self.showFallbackNotification = true
            }
        }

        if let completion = completion {
            completion(result)
            return
        }

        switch type {
        case .summary:
            if let article = self.selectedArticle {
                self.updateArticleSummaryFromCloud(article, summary: result)
            } else if let post = self.selectedRedditPost {
                self.updateRedditPostSummaryFromCloud(post, summary: result)
            } else {
                print("⚠️ AppState: Received summary result but no article or post is selected")
            }
        case .articleQA, .redditQA, .commentSummary, .globalSummaryQA, .globalSummary:
            print("⚠️ AppState: Received \(type) result without a completion handler")
        }
    }

    private func setWaitingState(for type: AppleIntelligenceRequestType) {
        DispatchQueue.main.async {
            switch type {
            case .summary:
                self.isWaitingForAppleIntelligence = true
                self.appleIntelligenceWaitProgress = "Waiting for Apple Intelligence... (0/\(self.maxClipboardChecks * 5)s)"
            case .articleQA:
                self.isWaitingForArticleQA = true
                self.articleQAWaitProgress = "Waiting for answer... (0/\(self.maxClipboardChecks * 5)s)"
            case .redditQA:
                self.isWaitingForRedditQA = true
                self.redditQAWaitProgress = "Waiting for answer... (0/\(self.maxClipboardChecks * 5)s)"
            case .commentSummary:
                self.isWaitingForCommentSummary = true
                self.commentSummaryWaitProgress = "Waiting for comment summary... (0/\(self.maxClipboardChecks * 5)s)"
            case .globalSummaryQA:
                self.isWaitingForGlobalQA = true
                self.globalQAWaitProgress = "Waiting for answer... (0/\(self.maxClipboardChecks * 5)s)"
            case .globalSummary:
                break
            }
        }
    }
    private var pendingCloudSummaryText: String = ""
    private var clipboardTimer: Timer?
    private var clipboardCheckCount: Int = 0
    private var maxClipboardChecks: Int = 24 // Check for up to 2 minutes (24 × 5 seconds)
    
    enum AppleIntelligenceRequestType {
        case summary
        case articleQA
        case redditQA
        case commentSummary
        case globalSummaryQA
        case globalSummary
    }
    
    private var currentRequestType: AppleIntelligenceRequestType = .summary
    private var currentRequestCompletion: ((String) -> Void)?
    
    // MARK: - Apple Cloud file-based handoff (mirrors red sample)
    private lazy var shortcutDirectory: URL = {
        #if os(iOS)
        if ProcessInfo.processInfo.isiOSAppOnMac {
            let localDocs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            return localDocs
        }
        #endif
        if let iCloudURL = FileManager.default.url(forUbiquityContainerIdentifier: nil) {
            let documentsURL = iCloudURL.appendingPathComponent("Documents")
            if !FileManager.default.fileExists(atPath: documentsURL.path) {
                try? FileManager.default.createDirectory(at: documentsURL, withIntermediateDirectories: true)
            }
            return documentsURL
        }
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }()
    
    var shortcutInputFileURL: URL {
        shortcutDirectory.appendingPathComponent("ShortcutInput.txt")
    }
    
    var shortcutOutputFileURL: URL {
        shortcutDirectory.appendingPathComponent("ShortcutOutput.txt")
    }
    
    func writeShortcutInputFile(_ text: String) {
        try? text.write(to: shortcutInputFileURL, atomically: true, encoding: .utf8)
    }
    
    func readShortcutOutputFile() -> String? {
        guard FileManager.default.fileExists(atPath: shortcutOutputFileURL.path) else { return nil }
        return try? String(contentsOf: shortcutOutputFileURL, encoding: .utf8)
    }
    
    func clearShortcutOutputFile() {
        try? FileManager.default.removeItem(at: shortcutOutputFileURL)
    }
    
    private func startClipboardMonitoring(for type: AppleIntelligenceRequestType = .summary) {
        // Cancel any existing timer
        clipboardTimer?.invalidate()
        clipboardCheckCount = 0
        
        // Store the original clipboard content
        #if os(iOS)
        let originalClipboard = UIPasteboard.general.string ?? ""
        #elseif os(macOS)
        let originalClipboard = NSPasteboard.general.string(forType: .string) ?? ""
        #endif
        
        print("📋 Starting clipboard monitoring for Apple Intelligence response (\(type))...")

        setWaitingState(for: type)
        
        // Check clipboard every 5 seconds, up to 2 minutes
        clipboardTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] timer in
            guard let self = self else {
                timer.invalidate()
                return
            }
            
            self.clipboardCheckCount += 1
            let elapsedTime = self.clipboardCheckCount * 5
            let totalTime = self.maxClipboardChecks * 5
            
            // File-based result (Shortcuts writes to output file)
            if let fileResult = self.readShortcutOutputFile(),
               !fileResult.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               fileResult.count > 10 {
                print("✅ Found \(type) response in ShortcutOutput.txt after \(elapsedTime) seconds!")
                self.clearShortcutOutputFile()
                DispatchQueue.main.async {
                    self.clearWaitingState(for: type)
                    self.handleCloudResult(fileResult, for: type, completion: self.currentRequestCompletion)
                    self.currentRequestCompletion = nil
                }
                timer.invalidate()
                self.clipboardTimer = nil
                return
            }

            #if os(iOS)
            let currentClipboard = UIPasteboard.general.string ?? ""
            #elseif os(macOS)
            let currentClipboard = NSPasteboard.general.string(forType: .string) ?? ""
            #endif
            
            print("📋 Checking clipboard for \(type)... (attempt \(self.clipboardCheckCount)/\(self.maxClipboardChecks))")
            
            // Update progress based on request type
            DispatchQueue.main.async {
                switch type {
                case .summary:
                    self.appleIntelligenceWaitProgress = "Waiting for Apple Intelligence... (\(elapsedTime)/\(totalTime)s)"
                case .articleQA:
                    self.articleQAWaitProgress = "Waiting for answer... (\(elapsedTime)/\(totalTime)s)"
                case .redditQA:
                    self.redditQAWaitProgress = "Waiting for answer... (\(elapsedTime)/\(totalTime)s)"
                case .commentSummary:
                    self.commentSummaryWaitProgress = "Waiting for comment summary... (\(elapsedTime)/\(totalTime)s)"
                case .globalSummaryQA:
                    self.globalQAWaitProgress = "Waiting for answer... (\(elapsedTime)/\(totalTime)s)"
                case .globalSummary:
                    break
                }
            }
            
            // If clipboard changed and contains meaningful content
            if currentClipboard != originalClipboard && !currentClipboard.isEmpty && currentClipboard.count > 10 {
                print("✅ Found \(type) response in clipboard after \(elapsedTime) seconds!")
                
                // Handle the response based on request type
                DispatchQueue.main.async {
                    self.clearWaitingState(for: type)
                    self.handleCloudResult(currentClipboard, for: type, completion: self.currentRequestCompletion)
                    self.currentRequestCompletion = nil
                }
                
                // Stop monitoring
                timer.invalidate()
                self.clipboardTimer = nil
                return
            }
            
            // Check if we've exceeded the maximum attempts
            if self.clipboardCheckCount >= self.maxClipboardChecks {
                print("⏱️ Clipboard monitoring timed out after \(totalTime) seconds for \(type)")
                
                // Show timeout message
                DispatchQueue.main.async {
                    self.clearWaitingState(for: type)
                    let timeoutMessage = "Apple Intelligence processing took longer than expected. Please check your clipboard manually or try again."
                    self.handleCloudResult(timeoutMessage, for: type, completion: self.currentRequestCompletion)
                    self.currentRequestCompletion = nil
                }
                
                // Stop monitoring
                timer.invalidate()
                self.clipboardTimer = nil
            }
        }
    }
    
    private func clearWaitingState(for type: AppleIntelligenceRequestType) {
        switch type {
        case .summary:
            self.isWaitingForAppleIntelligence = false
            self.appleIntelligenceWaitProgress = ""
        case .articleQA:
            self.isWaitingForArticleQA = false
            self.articleQAWaitProgress = ""
        case .redditQA:
            self.isWaitingForRedditQA = false
            self.redditQAWaitProgress = ""
        case .commentSummary:
            self.isWaitingForCommentSummary = false
            self.commentSummaryWaitProgress = ""
        case .globalSummaryQA:
            self.isWaitingForGlobalQA = false
            self.globalQAWaitProgress = ""
        case .globalSummary:
            break
        }
    }
    
    
    // MARK: - Cloud Summary Updates
    func updateArticleSummaryFromCloud(_ article: Article, summary: String) {
        defer { finishArticleSummary(article) }

        if let feedIndex = feeds.firstIndex(where: { $0.url == article.feedURL }),
           let articleIndex = feeds[feedIndex].articles.firstIndex(where: { $0.id == article.id }) {
            
            // Create a mutable copy of the article to update
            var articleToUpdate = feeds[feedIndex].articles[articleIndex]
            
            // Update the article with the cloud summary
            articleToUpdate.summary = cleanAndFormatSummaryTextForDisplay(summary)
            
            // Update the article in the feeds array
            feeds[feedIndex].articles[articleIndex] = articleToUpdate
            
            // If this is the currently selected article, update the selection
            if selectedArticle?.id == article.id {
                selectedArticle = articleToUpdate
                isSummaryFromCloud = true
                print("📱 AppState: Updated article summary from cloud for article ID: \(article.id)")
            }
        }
    }
    
    func updateRedditPostSummaryFromCloud(_ post: RedditPost, summary: String) {
        defer { finishRedditSummary(post) }

        if let feedIndex = redditFeeds.firstIndex(where: { $0.subreddit == post.subreddit }),
           let postIndex = redditFeeds[feedIndex].posts.firstIndex(where: { $0.id == post.id }) {
            
            // Create a mutable copy of the post to update
            var postToUpdate = redditFeeds[feedIndex].posts[postIndex]
            
            // Update the post with the cloud summary
            postToUpdate.summary = cleanAndFormatRedditSummaryTextForDisplay(summary)
            
            // Update the post in the redditFeeds array
            redditFeeds[feedIndex].posts[postIndex] = postToUpdate

            // If this is the currently selected post, update the selection
            if selectedRedditPost?.id == post.id {
                selectedRedditPost = postToUpdate
                isSummaryFromCloud = true
                print("📱 AppState: Updated Reddit post summary from cloud for post ID: \(post.id)")
            }
        }
    }

    // MARK: - Text Cleanup
    private func cleanMarkdownArtifactsForDisplay(_ input: String) -> String {
        var value = input
        value = value.replacingOccurrences(of: "\r\n", with: "\n")
        value = value.replacingOccurrences(of: "\r", with: "\n")
        value = value.replacingOccurrences(of: "(?s)```[a-zA-Z0-9_-]*\\s*(.*?)\\s*```", with: "$1", options: .regularExpression)
        value = value.replacingOccurrences(of: "```", with: "")
        value = value.replacingOccurrences(of: "\\*\\*(.*?)\\*\\*", with: "$1", options: .regularExpression)
        value = value.replacingOccurrences(of: "\\*(.*?)\\*", with: "$1", options: .regularExpression)
        value = value.replacingOccurrences(of: "__(.*?)__", with: "$1", options: .regularExpression)
        value = value.replacingOccurrences(of: "_(.*?)_", with: "$1", options: .regularExpression)
        value = value.replacingOccurrences(of: "`([^`]*)`", with: "$1", options: .regularExpression)
        value = value.replacingOccurrences(of: "(?m)^\\s{0,3}#{1,6}\\s*", with: "", options: .regularExpression)
        value = value.replacingOccurrences(of: "(?m)(^\\s*[-•]?\\s*)#{1,6}\\s*", with: "$1", options: .regularExpression)
        value = value.replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func enforceArticleSummaryLength(_ summary: String, sourceText: String) -> String {
        let cleaned = cleanMarkdownArtifactsForDisplay(summary)
        guard !cleaned.isEmpty else { return cleaned }
        let maxWords = targetArticleSummaryWordLimit(for: sourceText)
        return truncateSummaryBySentences(cleaned, maxWords: maxWords)
    }

    private func targetArticleSummaryWordLimit(for sourceText: String) -> Int {
        let sourceWords = countWords(in: sourceText)
        switch sourceWords {
        case ..<80: return 32
        case ..<140: return 45
        case ..<260: return 60
        case ..<420: return 80
        default: return 100
        }
    }

    private func truncateSummaryBySentences(_ text: String, maxWords: Int) -> String {
        guard maxWords > 0 else { return "" }
        let normalized = text
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return normalized }

        let marked = normalized.replacingOccurrences(
            of: "([\\.\\!\\?])\\s+(?=[A-Z0-9])",
            with: "$1|||",
            options: .regularExpression
        )
        let sentences = marked
            .components(separatedBy: "|||")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if sentences.isEmpty {
            return truncateToWordCount(normalized, maxWords: maxWords)
        }

        var selected: [String] = []
        var usedWords = 0

        for sentence in sentences {
            let sentenceWords = countWords(in: sentence)
            if sentenceWords == 0 { continue }
            if selected.isEmpty && sentenceWords > maxWords {
                return truncateToWordCount(sentence, maxWords: maxWords)
            }
            if usedWords + sentenceWords > maxWords {
                break
            }
            selected.append(sentence)
            usedWords += sentenceWords
        }

        if selected.isEmpty {
            return truncateToWordCount(normalized, maxWords: maxWords)
        }
        return selected.joined(separator: " ")
    }

    private func truncateToWordCount(_ text: String, maxWords: Int) -> String {
        let words = text.split(whereSeparator: { $0.isWhitespace })
        guard words.count > maxWords else { return text }
        let clipped = words.prefix(maxWords).map(String.init).joined(separator: " ")
        return clipped + "…"
    }

    private func countWords(in text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace }).count
    }

    private func cleanAndFormatSummaryTextForDisplay(_ input: String) -> String {
        var value = cleanMarkdownArtifactsForDisplay(input)
        guard !value.isEmpty else { return value }

        if !value.contains("\n\n") && !value.contains("\n") && value.count > 180 {
            let normalized = value
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)

            let marked = normalized.replacingOccurrences(
                of: "([\\.\\!\\?])\\s+(?=[A-Z0-9])",
                with: "$1|||",
                options: .regularExpression
            )
            let sentences = marked
                .components(separatedBy: "|||")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }

            if sentences.count >= 3 {
                var paragraphs: [String] = []
                var index = 0
                while index < sentences.count {
                    let end = min(index + 2, sentences.count)
                    paragraphs.append(sentences[index..<end].joined(separator: " "))
                    index += 2
                }
                value = paragraphs.joined(separator: "\n\n")
            } else {
                value = normalized
            }
        }

        value = value.replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func cleanAndFormatRedditSummaryTextForDisplay(_ input: String) -> String {
        var value = cleanMarkdownArtifactsForDisplay(input)
        guard !value.isEmpty else { return value }

        // Reddit summaries are short; split each sentence into its own paragraph for readability.
        if !value.contains("\n\n") {
            let normalized = value
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)

            let marked = normalized.replacingOccurrences(
                of: "([\\.\\!\\?])\\s+(?=[A-Z0-9])",
                with: "$1|||",
                options: .regularExpression
            )
            let sentences = marked
                .components(separatedBy: "|||")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }

            if sentences.count >= 2 {
                value = sentences.joined(separator: "\n\n")
            } else {
                value = normalized
            }
        }

        value = value.replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func cleanAndFormatQATextForDisplay(_ input: String) -> String {
        var value = cleanMarkdownArtifactsForDisplay(input)
        guard !value.isEmpty else { return value }

        // If the model returns one dense block, split long answers into readable paragraphs.
        if !value.contains("\n\n") && !value.contains("\n") && value.count > 180 {
            if let sentenceBreaks = try? NSRegularExpression(
                pattern: "([a-z0-9][\\.\\!\\?])\\s+(?=[A-Z0-9])",
                options: []
            ) {
                let range = NSRange(value.startIndex..., in: value)
                value = sentenceBreaks.stringByReplacingMatches(
                    in: value,
                    options: [],
                    range: range,
                    withTemplate: "$1\n\n"
                )
            }
        }

        value = value.replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Settings Management
    private static func normalizedSummarizeSettings(_ settings: AppSettings) -> AppSettings {
        var normalized = settings
        normalized.summarizeDaemonToken = AppSettings.sanitizedSummarizeSecret(settings.summarizeDaemonToken)
        normalized.summarizeBridgeSecret = AppSettings.sanitizedSummarizeSecret(settings.summarizeBridgeSecret)
        normalized.summarizeDaemonHost = AppSettings.sanitizedSummarizeHost(settings.summarizeDaemonHost)
        normalized.summarizeDaemonPort = AppSettings.sanitizedSummarizePort(settings.summarizeDaemonPort, fallback: 8787)
        normalized.summarizeDaemonModel = AppSettings.normalizedSummarizeDaemonModel(settings.summarizeDaemonModel)
        normalized.summarizeBridgeHost = AppSettings.sanitizedSummarizeHost(settings.summarizeBridgeHost)
        normalized.summarizeBridgePort = AppSettings.sanitizedSummarizePort(settings.summarizeBridgePort, fallback: AppSettings.defaultSummarizeBridgePort)
        normalized.pccGatewayHost = AppSettings.sanitizedSummarizeHost(settings.pccGatewayHost, fallback: AppSettings.defaultPCCGatewayHost)
        normalized.pccGatewayPort = AppSettings.sanitizedSummarizePort(settings.pccGatewayPort, fallback: AppSettings.defaultPCCGatewayPort)
        normalized.pccGatewayToken = AppSettings.sanitizedSummarizeSecret(settings.pccGatewayToken)
        normalized.pccGatewayModel = AppSettings.normalizedPCCGatewayModel(settings.pccGatewayModel)
        normalized.mlxMaxContextTokens = AppSettings.normalizedLiteRTContextTokens(settings.mlxMaxContextTokens)
        normalized.mlxMaxOutputTokens = AppSettings.normalizedLiteRTOutputTokens(
            settings.mlxMaxOutputTokens,
            contextTokens: AppSettings.effectiveLiteRTContextTokens(normalized.mlxMaxContextTokens)
        )
        normalized.coreAIMLXMaxContextTokens = AppSettings.normalizedCoreAIMLXContextTokens(settings.coreAIMLXMaxContextTokens)
        normalized.coreAIMLXMaxOutputTokens = AppSettings.normalizedCoreAIMLXOutputTokens(
            settings.coreAIMLXMaxOutputTokens,
            contextTokens: AppSettings.effectiveCoreAIMLXContextTokens(normalized.coreAIMLXMaxContextTokens)
        )
        return normalized
    }

    func updateSettings(_ newSettings: AppSettings) {
        var normalizedSettings = newSettings
        normalizedSettings.mlxModelID = LiteRTLocalService.normalizedModelIdentifier(from: normalizedSettings.mlxModelID)
        normalizedSettings.coreAIMLXModelID = CoreAIMLXLocalService.normalizedModelIdentifier(from: normalizedSettings.coreAIMLXModelID)
        normalizedSettings = Self.normalizedSummarizeSettings(normalizedSettings)

        let persistedSettings = persistenceManager.loadSettings()
        if normalizedSettings.redditClientId == persistedSettings.redditClientId {
            normalizedSettings.redditAccessToken = persistedSettings.redditAccessToken
            normalizedSettings.redditRefreshToken = persistedSettings.redditRefreshToken
            normalizedSettings.redditTokenExpiry = persistedSettings.redditTokenExpiry
            normalizedSettings.redditUsername = persistedSettings.redditUsername
            normalizedSettings.redditGrantedScopes = persistedSettings.redditGrantedScopes
        } else {
            normalizedSettings.redditAccessToken = ""
            normalizedSettings.redditRefreshToken = ""
            normalizedSettings.redditTokenExpiry = nil
            normalizedSettings.redditUsername = ""
            normalizedSettings.redditGrantedScopes = ""
        }

        // If Gemini API key changed, update all services that use it
        if normalizedSettings.geminiApiKey != settings.geminiApiKey {
            summaryService.updateApiKey(normalizedSettings.geminiApiKey)
            commentSummaryService.updateSummaryService(summaryService)
            qaService.updateSummaryService(summaryService)
        }

        // If OpenAI API key changed, update summary service
        if normalizedSettings.openaiApiKey != settings.openaiApiKey {
            summaryService.updateOpenAIApiKey(normalizedSettings.openaiApiKey)
        }

        // Clear stale throughput labels when switching providers
        if normalizedSettings.selectedSummaryProvider != settings.selectedSummaryProvider {
            mlxLastThroughput = ""
            mlxLastQAThroughput = ""
        }

        // Update the stored settings
        settings = normalizedSettings
        persistenceManager.saveSettings(normalizedSettings)

        #if os(macOS)
        RSSSummarizeBridgeServer.shared.reconfigure(settings: normalizedSettings)
        #endif

        // If refresh interval changed, restart timer
        if settings.refreshInterval != normalizedSettings.refreshInterval {
            cancellables.removeAll()
            setupRefreshTimer()
        }
    }

    func setSummarizeDaemonToken(_ token: String) {
        var newSettings = settings
        newSettings.summarizeDaemonToken = AppSettings.sanitizedSummarizeSecret(token)
        updateSettings(newSettings)
    }

    func setSummarizeBridgeSecret(_ secret: String) {
        var newSettings = settings
        newSettings.summarizeBridgeSecret = AppSettings.sanitizedSummarizeSecret(secret)
        updateSettings(newSettings)
    }

    func setSummarizeBridgeHost(_ host: String) {
        var newSettings = settings
        newSettings.summarizeBridgeHost = AppSettings.sanitizedSummarizeHost(host)
        updateSettings(newSettings)
    }

    func setSummarizeBridgePort(_ port: Int) {
        var newSettings = settings
        newSettings.summarizeBridgePort = AppSettings.sanitizedSummarizePort(port, fallback: AppSettings.defaultSummarizeBridgePort)
        updateSettings(newSettings)
    }

    func setSummarizeDaemonHost(_ host: String) {
        var newSettings = settings
        newSettings.summarizeDaemonHost = AppSettings.sanitizedSummarizeHost(host)
        updateSettings(newSettings)
    }

    func setSummarizeDaemonPort(_ port: Int) {
        var newSettings = settings
        newSettings.summarizeDaemonPort = AppSettings.sanitizedSummarizePort(port, fallback: 8787)
        updateSettings(newSettings)
    }

    func setSummarizeDaemonModel(_ model: String) {
        var newSettings = settings
        newSettings.summarizeDaemonModel = AppSettings.normalizedSummarizeDaemonModel(model)
        updateSettings(newSettings)
    }

    func setPCCGatewayHost(_ host: String) {
        var newSettings = settings
        newSettings.pccGatewayHost = AppSettings.sanitizedSummarizeHost(host, fallback: AppSettings.defaultPCCGatewayHost)
        updateSettings(newSettings)
    }

    func setPCCGatewayPort(_ port: Int) {
        var newSettings = settings
        newSettings.pccGatewayPort = AppSettings.sanitizedSummarizePort(port, fallback: AppSettings.defaultPCCGatewayPort)
        updateSettings(newSettings)
    }

    func setPCCGatewayToken(_ token: String) {
        var newSettings = settings
        newSettings.pccGatewayToken = AppSettings.sanitizedSummarizeSecret(token)
        updateSettings(newSettings)
    }

    func setPCCGatewayModel(_ model: String) {
        var newSettings = settings
        newSettings.pccGatewayModel = AppSettings.normalizedPCCGatewayModel(model)
        updateSettings(newSettings)
    }

    func testSummarizeConnection(completion: @escaping (Result<String, Error>) -> Void) {
        let snapshot = settings
        Task(priority: .userInitiated) {
            do {
                let response = try await RSSSummarizeProviderClient.ping(settings: snapshot)
                await MainActor.run { completion(.success(response)) }
            } catch {
                await MainActor.run { completion(.failure(error)) }
            }
        }
    }

    func testPCCGatewayConnection(completion: @escaping (Result<String, Error>) -> Void) {
        let snapshot = settings
        Task(priority: .userInitiated) {
            do {
                let host = AppSettings.sanitizedSummarizeHost(
                    snapshot.pccGatewayHost,
                    fallback: AppSettings.defaultPCCGatewayHost
                )
                guard !host.isEmpty else { throw FMPCCGatewayError.missingHost }
                let port = AppSettings.sanitizedSummarizePort(
                    snapshot.pccGatewayPort,
                    fallback: AppSettings.defaultPCCGatewayPort
                )
                guard (1...65_535).contains(port) else { throw FMPCCGatewayError.invalidPort(port) }
                let token = AppSettings.sanitizedSummarizeSecret(snapshot.pccGatewayToken)
                guard !token.isEmpty else { throw FMPCCGatewayError.missingToken }

                let response = try await FMPCCGatewayClient(
                    configuration: FMPCCGatewayConfiguration(
                        host: host,
                        port: port,
                        token: token,
                        model: AppSettings.normalizedPCCGatewayModel(snapshot.pccGatewayModel)
                    )
                ).health()
                await MainActor.run { completion(.success(response)) }
            } catch {
                await MainActor.run { completion(.failure(error)) }
            }
        }
    }

    // MARK: - Cache Management

    func clearAllCaches(completion: (() -> Void)? = nil) {
        print("🗑️ AppState: Clearing all caches...")

        // Clear Reddit comment cache
        redditService.clearCache()
        print("🗑️ AppState: Cleared Reddit comment cache")

        // Clear TTS audio cache
        summaryService.clearTTSCache()
        print("🗑️ AppState: Cleared TTS audio cache")

        // Clear URLSession cache (images, API responses)
        URLCache.shared.removeAllCachedResponses()
        print("🗑️ AppState: Cleared URLSession cache")

        let removableCacheBytes = cleanStorageBreakdownItem(.caches)
        print("🗑️ AppState: Cleared removable cache files (\(formattedByteCount(removableCacheBytes))); preserved local model caches")

        let group = DispatchGroup()

        #if canImport(Kingfisher)
        ImageCache.default.clearMemoryCache()
        group.enter()
        ImageCache.default.clearDiskCache {
            print("🗑️ AppState: Cleared Kingfisher disk cache")
            group.leave()
        }
        #endif

        clearTemporaryDirectory()

        group.notify(queue: .main) {
            print("✅ AppState: All caches cleared successfully")
            completion?()
        }
    }

    func clearFailedModelDownloads(completion: @escaping (String) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let freedBytes = self.removeFailedModelDownloadFiles()
            let message: String
            if freedBytes > 0 {
                message = "Removed \(self.formattedByteCount(freedBytes)) of failed model downloads."
            } else {
                message = "No failed model downloads found."
            }

            DispatchQueue.main.async {
                completion(message)
            }
        }
    }

    func loadLocalModelStorage(completion: @escaping ([LocalModelStorageItem]) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let items = self.collectLocalModelStorageItems()
            DispatchQueue.main.async {
                completion(items)
            }
        }
    }

    func deleteLocalModelStorageItem(_ item: LocalModelStorageItem, completion: @escaping (String) -> Void) {
        Task(priority: .utility) {
            await LiteRTLocalService.shared.unloadAllModels()
            await CoreAIMLXLocalService.shared.unloadAllModels()

            let message: String
            do {
                let size = directorySizeIncludingHidden(at: item.url)
                try FileManager.default.removeItem(at: item.url)
                message = "Deleted \(item.name) and freed \(formattedByteCount(size))."
            } catch {
                message = "Could not delete \(item.name): \(error.localizedDescription)"
            }

            await MainActor.run {
                completion(message)
            }
        }
    }

    func loadAppStorageBreakdown(completion: @escaping ([AppStorageBreakdownItem]) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let items = self.collectAppStorageBreakdownItems()
            DispatchQueue.main.async {
                completion(items)
            }
        }
    }

    func deleteAppStorageBreakdownItem(_ item: AppStorageBreakdownItem, completion: @escaping (String) -> Void) {
        Task(priority: .utility) {
            let message: String
            if item.isModelStorage {
                await LiteRTLocalService.shared.unloadAllModels()
                await CoreAIMLXLocalService.shared.unloadAllModels()

                let url = URL(fileURLWithPath: item.id)
                let size = self.directorySizeIncludingHidden(at: url)
                if (try? FileManager.default.removeItem(at: url)) != nil {
                    message = "Deleted \(item.name) and freed \(self.formattedByteCount(size))."
                } else {
                    message = "Could not delete \(item.name)."
                }
            } else if let cleanupKind = item.cleanupKind {
                let freedBytes = self.cleanStorageBreakdownItem(cleanupKind)
                if freedBytes > 0 {
                    message = "Deleted \(item.name) and freed \(self.formattedByteCount(freedBytes))."
                } else {
                    message = "No removable files found in \(item.name)."
                }
            } else {
                message = "\(item.name) is not safe to delete automatically."
            }

            await MainActor.run {
                completion(message)
            }
        }
    }

    func getCacheSize() -> String {
        var total: UInt64 = 0

        total += UInt64(URLCache.shared.currentDiskUsage)

        total += directorySize(at: FileManager.default.temporaryDirectory)

        if let cachesURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
            total += directorySizeIncludingHidden(at: cachesURL, excluding: modelCacheRoots())
        }

        if let libraryURL = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first {
            let webKitURL = libraryURL.appendingPathComponent("WebKit", isDirectory: true)
            total += directorySize(at: webKitURL)
            let httpStoragesURL = libraryURL.appendingPathComponent("HTTPStorages", isDirectory: true)
            total += directorySize(at: httpStoragesURL)
        }

        let totalMB = Double(total) / 1_048_576
        return String(format: "%.1f MB", totalMB)
    }

    private func collectAppStorageBreakdownItems() -> [AppStorageBreakdownItem] {
        let fm = FileManager.default
        var items: [AppStorageBreakdownItem] = []
        var seenPaths = Set<String>()

        func add(_ name: String, detail: String, url: URL, isModelStorage: Bool = false, cleanupKind: AppStorageBreakdownItem.CleanupKind? = nil, sizeOverride: UInt64? = nil) {
            guard fm.fileExists(atPath: url.path), !seenPaths.contains(url.path) else { return }
            let size = sizeOverride ?? directorySizeIncludingHidden(at: url)
            guard size > 0 else { return }
            seenPaths.insert(url.path)
            items.append(AppStorageBreakdownItem(
                id: url.path,
                name: name,
                detail: detail,
                sizeBytes: size,
                isModelStorage: isModelStorage,
                cleanupKind: cleanupKind
            ))
        }

        if let documentsURL = fm.urls(for: .documentDirectory, in: .userDomainMask).first {
            add("Documents", detail: documentsURL.path, url: documentsURL)
        }

        if let appSupportURL = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let liteRTModelsURL = appSupportURL.appendingPathComponent("LiteRTModels", isDirectory: true)
            add(
                "Application Support Data",
                detail: "App support files excluding LiteRT models",
                url: appSupportURL,
                sizeOverride: directorySizeIncludingHidden(at: appSupportURL, excluding: [liteRTModelsURL])
            )
            add("LiteRT Models", detail: "Downloaded .litertlm files", url: liteRTModelsURL, isModelStorage: true)
        }

        if let cachesURL = fm.urls(for: .cachesDirectory, in: .userDomainMask).first {
            add(
                "Removable Caches",
                detail: "Caches excluding MLX / Hugging Face models",
                url: cachesURL,
                cleanupKind: .caches,
                sizeOverride: directorySizeIncludingHidden(at: cachesURL, excluding: modelCacheRoots())
            )
            add("Kingfisher Images", detail: "Image cache", url: cachesURL.appendingPathComponent("com.onevcat.Kingfisher.ImageCache", isDirectory: true), cleanupKind: .kingfisherImages)
        }

        if let libraryURL = fm.urls(for: .libraryDirectory, in: .userDomainMask).first {
            add("WebKit", detail: "Web AI browser data", url: libraryURL.appendingPathComponent("WebKit", isDirectory: true), cleanupKind: .webKit)
            add("HTTPStorages", detail: "URLSession and web storage", url: libraryURL.appendingPathComponent("HTTPStorages", isDirectory: true), cleanupKind: .httpStorages)
            add("Saved Application State", detail: "System window/session state", url: libraryURL.appendingPathComponent("Saved Application State", isDirectory: true), cleanupKind: .savedApplicationState)
            add("Logs", detail: "App and framework logs", url: libraryURL.appendingPathComponent("Logs", isDirectory: true), cleanupKind: .logs)
        }

        add("Temporary Files", detail: FileManager.default.temporaryDirectory.path, url: FileManager.default.temporaryDirectory, cleanupKind: .temporaryFiles)

        for root in modelCacheRoots() {
            add("MLX / Hugging Face Models", detail: root.path, url: root, isModelStorage: true)
        }

        return items.sorted { $0.sizeBytes > $1.sizeBytes }
    }

    private func directorySize(at url: URL) -> UInt64 {
        guard FileManager.default.fileExists(atPath: url.path) else { return 0 }

        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey], options: [.skipsHiddenFiles]) else {
            return 0
        }

        var total: UInt64 = 0
        for case let fileURL as URL in enumerator {
            do {
                let values = try fileURL.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
                if values.isDirectory == true { continue }
                total += UInt64(values.fileSize ?? 0)
            } catch {
                continue
            }
        }
        return total
    }

    private func collectLocalModelStorageItems() -> [LocalModelStorageItem] {
        let fm = FileManager.default
        var items: [LocalModelStorageItem] = []

        let currentLiteRTFileName = LiteRTLocalService.defaultModelFileName
        if let appSupportURL = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let liteRTURL = appSupportURL.appendingPathComponent("LiteRTModels", isDirectory: true)
            if let files = try? fm.contentsOfDirectory(
                at: liteRTURL,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            ) {
                for file in files where file.pathExtension == "litertlm" {
                    let size = directorySizeIncludingHidden(at: file)
                    items.append(LocalModelStorageItem(
                        id: file.path,
                        name: file.lastPathComponent,
                        detail: "LiteRT model file",
                        kind: .liteRT,
                        sizeBytes: size,
                        url: file,
                        isCurrentSelection: file.lastPathComponent == currentLiteRTFileName
                    ))
                }
            }
        }

        for root in modelCacheRoots() where fm.fileExists(atPath: root.path) {
            if let entries = try? fm.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            ) {
                for entry in entries {
                    let values = try? entry.resourceValues(forKeys: [.isDirectoryKey])
                    guard values?.isDirectory == true else { continue }
                    let size = directorySizeIncludingHidden(at: entry)
                    guard size > 0 else { continue }
                    items.append(LocalModelStorageItem(
                        id: entry.path,
                        name: displayNameForModelCacheDirectory(entry.lastPathComponent),
                        detail: "MLX / Hugging Face model folder",
                        kind: .mlx,
                        sizeBytes: size,
                        url: entry,
                        isCurrentSelection: isCurrentMLXModelDirectory(entry.lastPathComponent)
                    ))
                }
            }
        }

        return items.sorted {
            if $0.kind.rawValue != $1.kind.rawValue { return $0.kind.rawValue < $1.kind.rawValue }
            return $0.sizeBytes > $1.sizeBytes
        }
    }

    private func modelCacheRoots() -> [URL] {
        #if os(macOS)
        return [URL.homeDirectory.appending(path: ".cache/huggingface/hub")]
        #else
        return [URL.cachesDirectory.appending(path: "huggingface")]
        #endif
    }

    private func displayNameForModelCacheDirectory(_ name: String) -> String {
        if name.hasPrefix("models--") {
            return String(name.dropFirst("models--".count)).replacingOccurrences(of: "--", with: "/")
        }
        return name
    }

    private func isCurrentMLXModelDirectory(_ name: String) -> Bool {
        let current = settings.coreAIMLXModelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !current.isEmpty else { return false }
        let safeID = current.replacingOccurrences(of: "/", with: "--")
        return name == "models--\(safeID)" || name == safeID || displayNameForModelCacheDirectory(name) == current
    }

    private func removeFailedModelDownloadFiles() -> UInt64 {
        let fm = FileManager.default
        var freedBytes: UInt64 = 0
        var roots = modelCacheRoots()
        if let appSupportURL = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            roots.append(appSupportURL.appendingPathComponent("LiteRTModels", isDirectory: true))
        }

        for root in roots where fm.fileExists(atPath: root.path) {
            guard let enumerator = fm.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
                options: []
            ) else { continue }

            for case let fileURL as URL in enumerator {
                let name = fileURL.lastPathComponent
                guard name.hasSuffix(".download") || name.hasSuffix(".partial") || name.hasSuffix(".dl-bits") else { continue }
                let size = directorySizeIncludingHidden(at: fileURL)
                if (try? fm.removeItem(at: fileURL)) != nil {
                    freedBytes += size
                    print("🗑️ AppState: Removed failed model download \(fileURL.lastPathComponent)")
                }
            }
        }

        return freedBytes
    }

    private func cleanStorageBreakdownItem(_ cleanupKind: AppStorageBreakdownItem.CleanupKind) -> UInt64 {
        let fm = FileManager.default

        switch cleanupKind {
        case .caches:
            URLCache.shared.removeAllCachedResponses()
            guard let cachesURL = fm.urls(for: .cachesDirectory, in: .userDomainMask).first else { return 0 }
            return removeDirectoryContents(at: cachesURL, preserving: modelCacheRoots())

        case .kingfisherImages:
            #if canImport(Kingfisher)
            ImageCache.default.clearMemoryCache()
            #endif
            guard let cachesURL = fm.urls(for: .cachesDirectory, in: .userDomainMask).first else { return 0 }
            return removeItemIfExists(at: cachesURL.appendingPathComponent("com.onevcat.Kingfisher.ImageCache", isDirectory: true))

        case .webKit:
            guard let libraryURL = fm.urls(for: .libraryDirectory, in: .userDomainMask).first else { return 0 }
            return removeItemIfExists(at: libraryURL.appendingPathComponent("WebKit", isDirectory: true))

        case .httpStorages:
            guard let libraryURL = fm.urls(for: .libraryDirectory, in: .userDomainMask).first else { return 0 }
            return removeItemIfExists(at: libraryURL.appendingPathComponent("HTTPStorages", isDirectory: true))

        case .savedApplicationState:
            guard let libraryURL = fm.urls(for: .libraryDirectory, in: .userDomainMask).first else { return 0 }
            return removeItemIfExists(at: libraryURL.appendingPathComponent("Saved Application State", isDirectory: true))

        case .logs:
            guard let libraryURL = fm.urls(for: .libraryDirectory, in: .userDomainMask).first else { return 0 }
            return removeItemIfExists(at: libraryURL.appendingPathComponent("Logs", isDirectory: true))

        case .temporaryFiles:
            return removeDirectoryContents(at: fm.temporaryDirectory, preserving: [])
        }
    }

    private func removeDirectoryContents(at directory: URL, preserving protectedURLs: [URL]) -> UInt64 {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: []) else { return 0 }
        var freedBytes: UInt64 = 0

        for item in contents {
            if shouldPreserveStorageItem(item, protectedURLs: protectedURLs) {
                continue
            }

            let size = directorySizeIncludingHidden(at: item)
            if (try? fm.removeItem(at: item)) != nil {
                freedBytes += size
            }
        }

        return freedBytes
    }

    private func removeItemIfExists(at url: URL) -> UInt64 {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return 0 }
        let size = directorySizeIncludingHidden(at: url)
        if (try? fm.removeItem(at: url)) != nil {
            return size
        }
        return 0
    }

    private func shouldPreserveStorageItem(_ item: URL, protectedURLs: [URL]) -> Bool {
        let itemPath = item.standardizedFileURL.path
        return protectedURLs.contains { protectedURL in
            let protectedPath = protectedURL.standardizedFileURL.path
            return itemPath == protectedPath
                || itemPath.hasPrefix(protectedPath + "/")
                || protectedPath.hasPrefix(itemPath + "/")
        }
    }

    private func directorySizeIncludingHidden(at url: URL) -> UInt64 {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return 0 }
        if !isDirectory.boolValue {
            return UInt64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }

        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
            options: []
        ) else { return 0 }

        var total: UInt64 = 0
        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            if values?.isDirectory == true { continue }
            total += UInt64(values?.fileSize ?? 0)
        }
        return total
    }

    private func directorySizeIncludingHidden(at url: URL, excluding excludedURLs: [URL]) -> UInt64 {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return 0 }
        guard isDirectory.boolValue else {
            return shouldPreserveStorageItem(url, protectedURLs: excludedURLs) ? 0 : directorySizeIncludingHidden(at: url)
        }

        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
            options: []
        ) else { return 0 }

        var total: UInt64 = 0
        for case let fileURL as URL in enumerator {
            if shouldPreserveStorageItem(fileURL, protectedURLs: excludedURLs) {
                enumerator.skipDescendants()
                continue
            }
            let values = try? fileURL.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            if values?.isDirectory == true { continue }
            total += UInt64(values?.fileSize ?? 0)
        }
        return total
    }

    private func formattedByteCount(_ bytes: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }

    private func clearTemporaryDirectory() {
        let tempDirectory = FileManager.default.temporaryDirectory
        do {
            let tempContents = try FileManager.default.contentsOfDirectory(at: tempDirectory, includingPropertiesForKeys: nil)
            for fileURL in tempContents {
                try? FileManager.default.removeItem(at: fileURL)
            }
            print("🗑️ AppState: Cleared temporary directory")
        } catch {
            print("⚠️ AppState: Failed to enumerate temporary directory - \(error.localizedDescription)")
        }
    }

    // MARK: - OPML Import
    func importOPMLFromURL(_ url: URL, completion: @escaping (Result<Int, Error>) -> Void) {
        // Start loading indicator
        self.isLoading = true
        
        opmlService.loadOPMLFromFile(at: url)
            .receive(on: RunLoop.main)
            .sink(receiveCompletion: { [weak self] result in
                guard let self = self else { return }
                self.isLoading = false
                
                // Handle errors
                if case .failure(let error) = result {
                    print("OPML import error: \(error)")
                    completion(.failure(error))
                }
            }, receiveValue: { [weak self] newSubscriptions in
                guard let self = self else { return }
                
                // Filter out subscriptions that already exist
                let existingURLs = Set(self.subscriptions.map { $0.url })
                let uniqueSubscriptions = newSubscriptions.filter { !existingURLs.contains($0.url) }
                
                // Add new subscriptions
                if !uniqueSubscriptions.isEmpty {
                    self.subscriptions.append(contentsOf: uniqueSubscriptions)
                    self.persistenceManager.saveSubscriptions(self.subscriptions)
                    
                    // Load the feeds for new subscriptions
                    for subscription in uniqueSubscriptions {
                        if subscription.type == .rss {
                            self.fetchArticleFeed(for: subscription)
                                .receive(on: RunLoop.main)
                                .sink(receiveCompletion: { _ in },
                                      receiveValue: { [weak self] feed in
                                    guard let self = self else { return }
                                    // Apply read and favorite status
                                    var processedFeed = feed
                                    for i in 0..<processedFeed.articles.count {
                                        let id = processedFeed.articles[i].id
                                        processedFeed.articles[i].isRead = self.persistenceManager.isArticleRead(processedFeed.articles[i])
                                        processedFeed.articles[i].isFavorite = self.persistenceManager.isArticleFavorite(id)
                                    }
                                    self.feeds.append(processedFeed)
                                })
                                .store(in: &self.cancellables)
                        } else if subscription.type == .reddit {
                            self.redditService.fetchSubreddit(subreddit: subscription.url, sortOption: self.redditSortOption)
                                .receive(on: RunLoop.main)
                                .sink(receiveCompletion: { _ in },
                                      receiveValue: { [weak self] redditFeed in
                                    guard let self = self else { return }
                                    // Apply read and favorite status
                                    var processedFeed = redditFeed
                                    for i in 0..<processedFeed.posts.count {
                                        let id = processedFeed.posts[i].id
                                        processedFeed.posts[i].isRead = self.persistenceManager.isRedditPostRead(processedFeed.posts[i])
                                        processedFeed.posts[i].isFavorite = self.persistenceManager.isRedditPostFavorite(id) ?? false
                                    }
                                    // Sort posts: stickied first, then by date for "New" sort
                                    if self.redditSortOption == .new {
                                        let stickied = processedFeed.posts.filter { $0.isStickied }
                                        let nonStickied = processedFeed.posts.filter { !$0.isStickied }
                                            .sorted { $0.publishDate > $1.publishDate }
                                        processedFeed.posts = stickied + nonStickied
                                    }
                                    self.redditFeeds.append(processedFeed)
                                })
                                .store(in: &self.cancellables)
                        }
                    }
                }
                
                // Return the count of new subscriptions
                completion(.success(uniqueSubscriptions.count))
            })
            .store(in: &cancellables)
    }
    
    // MARK: - OPML Export
    func exportOPMLToFile(completion: @escaping (Result<URL, Error>) -> Void) {
        // Generate OPML content
        let opmlContent = opmlService.exportFeedsToOPML(subscriptions)
        
        // Create filename with timestamp
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let timestamp = dateFormatter.string(from: Date())
        let filename = "RSS_Subscriptions_\(timestamp).opml"
        
        // Get temporary directory
        let tempDirectory = FileManager.default.temporaryDirectory
        let fileURL = tempDirectory.appendingPathComponent(filename)
        
        do {
            // Write OPML content to file
            try opmlContent.write(to: fileURL, atomically: true, encoding: .utf8)
            completion(.success(fileURL))
        } catch {
            completion(.failure(error))
        }
    }
    
    // MARK: - Mark All as Read
    func markAllUnreadAsRead() {
        var updatedFeeds = feeds
        var articlesToPersist: [Article] = []
        for feedIndex in updatedFeeds.indices {
            for articleIndex in updatedFeeds[feedIndex].articles.indices {
                if !updatedFeeds[feedIndex].articles[articleIndex].isRead {
                    updatedFeeds[feedIndex].articles[articleIndex].isRead = true
                    articlesToPersist.append(updatedFeeds[feedIndex].articles[articleIndex])
                }
            }
        }

        var updatedRedditFeeds = redditFeeds
        var postsToPersist: [RedditPost] = []
        for feedIndex in updatedRedditFeeds.indices {
            for postIndex in updatedRedditFeeds[feedIndex].posts.indices {
                if !updatedRedditFeeds[feedIndex].posts[postIndex].isRead {
                    updatedRedditFeeds[feedIndex].posts[postIndex].isRead = true
                    postsToPersist.append(updatedRedditFeeds[feedIndex].posts[postIndex])
                }
            }
        }

        if !articlesToPersist.isEmpty {
            feeds = updatedFeeds
            persistenceManager.markArticlesAsRead(articlesToPersist)
        }
        if !postsToPersist.isEmpty {
            redditFeeds = updatedRedditFeeds
            persistenceManager.markRedditPostsAsRead(postsToPersist)
        }

        print("📱 AppState: Marked \(articlesToPersist.count) articles and \(postsToPersist.count) Reddit posts as read")
    }

    func markAllArticlesAsRead(for feedURL: String) {
        guard let feedIndex = feeds.firstIndex(where: { $0.url == feedURL }) else { return }

        var updatedFeed = feeds[feedIndex]
        var articlesToPersist: [Article] = []
        for articleIndex in updatedFeed.articles.indices {
            if !updatedFeed.articles[articleIndex].isRead {
                updatedFeed.articles[articleIndex].isRead = true
                articlesToPersist.append(updatedFeed.articles[articleIndex])
            }
        }

        if !articlesToPersist.isEmpty {
            feeds[feedIndex] = updatedFeed
            persistenceManager.markArticlesAsRead(articlesToPersist)
            print("📱 AppState: Marked \(articlesToPersist.count) articles as read for feed \(feedURL)")
        }
    }

    func markAllRedditPostsAsRead(for subreddit: String) {
        guard let feedIndex = redditFeeds.firstIndex(where: { $0.subreddit == subreddit }) else { return }

        var updatedFeed = redditFeeds[feedIndex]
        var postsToPersist: [RedditPost] = []
        #if DEBUG
        var markedPostIds: [String] = []
        #endif
        for postIndex in updatedFeed.posts.indices {
            if !updatedFeed.posts[postIndex].isRead {
                updatedFeed.posts[postIndex].isRead = true
                postsToPersist.append(updatedFeed.posts[postIndex])
                #if DEBUG
                markedPostIds.append(updatedFeed.posts[postIndex].id)
                #endif
            }
        }

        if !postsToPersist.isEmpty {
            redditFeeds[feedIndex] = updatedFeed
            persistenceManager.markRedditPostsAsRead(postsToPersist)
            print("📱 AppState: Marked \(postsToPersist.count) Reddit posts as read for r/\(subreddit)")
            #if DEBUG
            let sampleIds = Array(markedPostIds.prefix(10))
            print("🧪 MarkAllRedditPostsAsRead: Marked IDs sample: \(sampleIds)")
            #endif
        }
    }

    // Navigate to the next subscription in the list (used after marking all as read)
    func navigateToNextSubscription(after currentURL: String) {
        guard let currentIndex = subscriptions.firstIndex(where: { $0.url == currentURL }) else { return }
        let nextIndex = currentIndex + 1
        if nextIndex < subscriptions.count {
            let nextURL = subscriptions[nextIndex].url
            print("📱 AppState: Navigating to next subscription: \(subscriptions[nextIndex].title)")
            // Small delay to ensure mark-all-as-read completes first, then navigate
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                withAnimation(.easeInOut(duration: 0.25)) {
                    self.activeSubscriptionURL = nextURL
                }
            }
        } else {
            // Last subscription - stay on current (scroll positions are preserved separately)
            print("📱 AppState: Already on last subscription, staying here")
        }
    }

    // MARK: - Local Model Fallback Helper
    private func isContextError(_ error: Error) -> Bool {
        let errorMessage = error.localizedDescription.lowercased()

        let contextPhrases = [
            "context length",
            "context window",
            "context limit",
            "maximum context",
            "maximum allowed length",
            "input length",
            "input too large",
            "content too long",
            "text too long",
            "request too large",
            "payload too large",
            "too long",
            "too large",
            "exceeded the maximum",
            "exceeds the maximum",
            "exceeded context",
            "exceeds context"
        ]

        for phrase in contextPhrases {
            if errorMessage.contains(phrase) {
                return true
            }
        }

        if let nsError = error as? NSError {
            let contextErrorCodes = [413, 431]
            if contextErrorCodes.contains(nsError.code) {
                return true
            }
        }
        
        return false
    }

    private func isLocalProviderContextError(_ error: Error) -> Bool {
        LiteRTLocalService.isContextTooLargeError(error)
            || CoreAIMLXLocalService.isContextTooLargeError(error)
            || isContextError(error)
    }

    @MainActor
    private func showContextRerouteNotification(from providerName: String, to targetName: String = "Gemini") {
        fallbackNotification = "Request too long for \(providerName). Routing to \(targetName)."
        todaySummaryInfo = "\(providerName) exceeded context — using \(targetName)."
        showFallbackNotification = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 6.0) { [weak self] in
            self?.showFallbackNotification = false
        }
    }

    @MainActor
    func reroutePendingLocalRequest(to provider: LocalRerouteProvider) {
        guard let request = pendingLocalReroute else { return }
        pendingLocalReroute = nil
        request.route(to: provider)
    }

    @MainActor
    func dismissPendingLocalReroute() {
        guard let request = pendingLocalReroute else { return }
        pendingLocalReroute = nil
        request.cancel()
    }

    private func estimatedTokensForLocalRouting(_ text: String) -> Int {
        max(1, Int(ceil(Double(text.count) / 4.0)))
    }

    @MainActor
    private func presentLocalReroute(
        providerName: String,
        prompt: String,
        taskName: String,
        appleRequestType: AppleIntelligenceRequestType = .summary,
        isQA: Bool = false,
        error: Error? = nil,
        completion: @escaping (String) -> Void,
        onCancel: (() -> Void)? = nil,
        onRouteStart: ((LocalRerouteProvider) -> Void)? = nil,
        presentationScope: LocalReroutePresentationScope = .global
    ) {
        mlxStreamingText = ""
        isLoading = false

        let estimatedTokens = estimatedTokensForLocalRouting(prompt)
        let message: String
        if let error {
            message = "\(providerName) could not handle this request locally: \(error.localizedDescription) Choose another model to reroute it."
        } else {
            message = "\(providerName) needs about \(estimatedTokens) input tokens for this request, which is larger than the available local context. Choose another model to reroute it."
        }

        pendingLocalReroute = LocalRerouteRequest(
            message: message,
            presentationScope: presentationScope,
            routeStartHandler: { provider in
                onRouteStart?(provider)
            },
            routeHandler: { [weak self] provider in
                guard let self else { return }
                self.performReroutedLocalPrompt(
                    prompt: prompt,
                    taskName: taskName,
                    provider: provider,
                    appleRequestType: appleRequestType,
                    isQA: isQA,
                    completion: completion
                )
            },
            cancelHandler: { [weak self] in
                self?.mlxStreamingText = ""
                self?.isLoading = false
                onCancel?()
            }
        )
    }

    @MainActor
    private func performReroutedLocalPrompt(
        prompt: String,
        taskName: String,
        provider: LocalRerouteProvider,
        appleRequestType: AppleIntelligenceRequestType,
        isQA: Bool,
        completion: @escaping (String) -> Void
    ) {
        let target = provider.summaryProvider
        fallbackNotification = "Routing \(taskName) to \(provider.displayName)."
        showFallbackNotification = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { [weak self] in
            self?.showFallbackNotification = false
        }

        switch target {
        case .gemini:
            performGeminiFallback(prompt: prompt, taskName: taskName, completion: completion)

        case .applePCCGateway:
            isLoading = true
            Task(priority: .userInitiated) { [weak self] in
                guard let self else { return }
                do {
                    let answer = try await self.performPCCPlainTextRequestAsync(prompt: prompt, taskName: taskName, isQA: isQA)
                    await MainActor.run {
                        self.isLoading = false
                        completion(answer)
                    }
                } catch {
                    await MainActor.run {
                        self.isLoading = false
                        completion("Apple PCC Gateway error: \(error.localizedDescription)")
                    }
                }
            }

        case .summarizeDaemon:
            isLoading = true
            Task(priority: .userInitiated) { [weak self] in
                guard let self else { return }
                do {
                    let start = Date()
                    let answer = try await self.summaryService.generateContentWithSummarize(prompt: prompt, settings: self.settings)
                    let elapsed = Date().timeIntervalSince(start)
                    await MainActor.run {
                        self.recordSummarizeThroughput(text: answer, elapsed: elapsed, isQA: isQA)
                        self.isLoading = false
                        completion(answer)
                    }
                } catch {
                    await MainActor.run {
                        self.isLoading = false
                        completion("Codex / Summarize error: \(error.localizedDescription)")
                    }
                }
            }

        case .appleCloud:
            isLoading = true
            launchCloudRequest(for: prompt, type: appleRequestType, completion: completion)

        case .webAI:
            isLoading = true
            performWebAIRequest(
                title: taskName,
                prompt: prompt,
                onSuccess: { [weak self] answer in
                    self?.isLoading = false
                    completion(answer)
                },
                onFailure: { [weak self] message in
                    self?.isLoading = false
                    completion(message)
                }
            )

        case .appleLocal, .mlxLocal, .coreAIMLXLocal:
            completion("Choose a cloud or remote provider to reroute this request.")
        }
    }

    private func appleLocalUnavailableError() -> NSError {
        NSError(
            domain: "AppleLocal.Unavailable",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Apple Local AI is not available on this device."]
        )
    }

    @available(iOS 26.0, macOS 26.0, visionOS 26.0, watchOS 27.0, *)
    private func generateAppleLocalStreaming(prompt: String) async throws -> String {
        await MainActor.run { self.mlxStreamingText = "" }
        let session = LanguageModelSession()
        var output = ""

        for try await snapshot in session.streamResponse(to: prompt) {
            if Task.isCancelled { throw CancellationError() }
            output = snapshot.content
            await MainActor.run {
                self.mlxStreamingText = output
            }
        }

        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    private func performLocalWithGeminiFallback(
        prompt: String,
        taskName: String,
        appleRequestType: AppleIntelligenceRequestType = .summary,
        isQA: Bool = false,
        completion: @escaping (String) -> Void,
        onCancel: (() -> Void)? = nil,
        onRouteStart: ((LocalRerouteProvider) -> Void)? = nil
    ) {
        if settings.selectedSummaryProvider == .appleLocal,
           estimateTokens(for: prompt) > appStateAppleLocalMaxTokens {
            presentLocalReroute(
                providerName: "Apple Local",
                prompt: prompt,
                taskName: taskName,
                appleRequestType: appleRequestType,
                isQA: isQA,
                completion: completion,
                onCancel: onCancel,
                onRouteStart: onRouteStart
            )
            return
        }

        if #available(iOS 26.0, *), LocalSummaryService.isAvailable() {
            print("📱 AppState: Trying local model for \(taskName)")
            Task(priority: .userInitiated) { [weak self] in
                guard let self else { return }
                do {
                    let response = try await self.generateAppleLocalStreaming(prompt: prompt)
                    await MainActor.run {
                        self.mlxStreamingText = ""
                        print("✅ AppState: Local model succeeded for \(taskName)")
                        completion(response)
                    }
                } catch {
                    await MainActor.run {
                        self.mlxStreamingText = ""
                        print("⚠️ AppState: Local model failed for \(taskName): \(error.localizedDescription)")
                        print("🔍 AppState: Error type: \(type(of: error))")
                        self.presentLocalReroute(
                            providerName: "Apple Local",
                            prompt: prompt,
                            taskName: taskName,
                            appleRequestType: appleRequestType,
                            isQA: isQA,
                            error: error,
                            completion: completion,
                            onCancel: onCancel
                        )
                    }
                }
            }
        } else {
            print("⚠️ AppState: Local model not available, asking for reroute for \(taskName)")
            presentLocalReroute(
                providerName: "Apple Local",
                prompt: prompt,
                taskName: taskName,
                appleRequestType: appleRequestType,
                isQA: isQA,
                error: appleLocalUnavailableError(),
                completion: completion,
                onCancel: onCancel
            )
        }
    }
    
    private func performGeminiFallback(
        prompt: String,
        taskName: String,
        completion: @escaping (String) -> Void
    ) {
        guard !settings.geminiApiKey.isEmpty else {
            completion("Local AI failed and Gemini API key not configured. Please add your Gemini API key in Settings.")
            return
        }

        print("🔄 AppState: Using Gemini fallback for \(taskName)")
        isLoading = true

        summaryService.summarizeText("", customPrompt: prompt)
            .receive(on: RunLoop.main)
            .sink { answer in
                self.isLoading = false
                print("✅ AppState: Gemini fallback succeeded for \(taskName)")
                completion(answer)
            }
            .store(in: &cancellables)
    }

    // MARK: - MLX Warm-Up

    /// Pre-load + prime Metal shader cache for the configured MLX model.
    /// Safe to call at any time; silently does nothing when MLX is not the active provider.
    func warmUpMLXIfNeeded() {
        guard settings.selectedSummaryProvider == .mlxLocal || settings.selectedSummaryProvider == .coreAIMLXLocal else { return }
        let useCoreAIMLX = settings.selectedSummaryProvider == .coreAIMLXLocal
        let modelID = useCoreAIMLX
            ? settings.coreAIMLXModelID.trimmingCharacters(in: .whitespacesAndNewlines)
            : settings.mlxModelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !modelID.isEmpty else { return }
        let maxCtx = useCoreAIMLX
            ? (settings.coreAIMLXMaxContextTokens > 0 ? settings.coreAIMLXMaxContextTokens : CoreAIMLXLocalService.defaultContextTokens)
            : (settings.mlxMaxContextTokens > 0 ? settings.mlxMaxContextTokens : LiteRTLocalService.defaultContextTokens)
        Task.detached(priority: .utility) { [modelID, maxCtx, useCoreAIMLX] in
            do {
                if useCoreAIMLX {
                    try await CoreAIMLXLocalService.shared.preloadConfiguredModel(modelID: modelID)
                    try await CoreAIMLXLocalService.shared.warmUpConfiguredModel(modelID: modelID, maxContextTokens: maxCtx)
                    await CoreAIMLXLocalService.shared.clearTransientCache()
                    print("🔥 [CoreAI MLX] Warm-up complete for '\(modelID)'")
                } else {
                    try await LiteRTLocalService.shared.preloadConfiguredModel(modelID: modelID, maxContextTokens: maxCtx)
                    try await LiteRTLocalService.shared.warmUpConfiguredModel(modelID: modelID, maxContextTokens: maxCtx)
                    await LiteRTLocalService.shared.clearTransientCache()
                    print("🔥 [LiteRT] Warm-up complete for '\(modelID)'")
                }
            } catch {
                print("⚠️ [\(useCoreAIMLX ? "CoreAI MLX" : "LiteRT")] Warm-up failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - MLX Throughput helper

    private var selectedLocalModelLabel: String {
        settings.selectedSummaryProvider == .coreAIMLXLocal ? "CoreAI MLX" : "LiteRT"
    }

    private var selectedLocalModelID: String {
        if settings.selectedSummaryProvider == .coreAIMLXLocal {
            return settings.coreAIMLXModelID.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return settings.mlxModelID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func generateLocalTextWithMetrics(
        prompt: String,
        systemPrompt: String? = nil,
        maxOutputTokens: Int,
        maxContextTokens: Int?,
        onToken: (@Sendable (String) async -> Void)? = nil
    ) async throws -> MLXGenerationMetrics {
        let modelID = selectedLocalModelID
        guard !modelID.isEmpty else {
            throw NSError(
                domain: "SummaryService.LocalModel",
                code: 0,
                userInfo: [NSLocalizedDescriptionKey: "\(selectedLocalModelLabel) model id is missing. Set it in Settings -> Summary Provider."]
            )
        }

        if settings.selectedSummaryProvider == .coreAIMLXLocal {
            return try await CoreAIMLXLocalService.shared.generateTextWithMetrics(
                prompt: prompt,
                systemPrompt: systemPrompt,
                modelID: modelID,
                maxOutputTokens: maxOutputTokens,
                maxContextTokens: maxContextTokens,
                onToken: onToken
            )
        }

        return try await LiteRTLocalService.shared.generateTextWithMetrics(
            prompt: prompt,
            systemPrompt: systemPrompt,
            modelID: modelID,
            maxOutputTokens: maxOutputTokens,
            maxContextTokens: maxContextTokens,
            onToken: onToken
        )
    }

    private func clearLocalModelTransientCache() async {
        if settings.selectedSummaryProvider == .coreAIMLXLocal {
            await CoreAIMLXLocalService.shared.clearTransientCache()
        } else {
            await LiteRTLocalService.shared.clearTransientCache()
        }
    }

    /// Format and publish throughput after a successful MLX generation.
    @MainActor
    private func recordMLXThroughput(_ metrics: MLXGenerationMetrics) {
        guard metrics.tokensPerSecond > 0 else { return }
        mlxLastThroughput = String(
            format: "\(selectedLocalModelLabel) · %.1f tok/s · %d tokens",
            metrics.tokensPerSecond,
            metrics.tokenCount
        )
    }

    /// Estimate and publish throughput for Apple Local (FoundationModels) generations.
    @MainActor
    private func recordAppleLocalThroughput(text: String, elapsed: TimeInterval) {
        guard elapsed > 0 else { return }
        let estimatedTokens = max(1, Int(Double(text.split(separator: " ").count) * 1.3))
        let tokPerSec = Double(estimatedTokens) / elapsed
        mlxLastThroughput = String(format: "Apple · ~%.1f tok/s · ~%d tokens", tokPerSec, estimatedTokens)
    }

    @MainActor
    private func recordSummarizeThroughput(text: String, elapsed: TimeInterval, isQA: Bool = false) {
        guard elapsed > 0 else { return }
        let estimatedTokens = max(1, Int(Double(text.split(separator: " ").count) * 1.3))
        let tokPerSec = Double(estimatedTokens) / elapsed
        let label = String(format: "Codex/Summarize · ~%.1f tok/s · ~%d tokens", tokPerSec, estimatedTokens)
        if isQA {
            mlxLastQAThroughput = label
        } else {
            mlxLastThroughput = label
        }
    }

    @MainActor
    private func recordPCCGatewayThroughput(text: String, elapsed: TimeInterval, isQA: Bool = false) {
        guard elapsed > 0 else { return }
        let estimatedTokens = max(1, Int(Double(text.split(separator: " ").count) * 1.3))
        let tokPerSec = Double(estimatedTokens) / elapsed
        let label = String(format: "Apple PCC · ~%.1f tok/s · ~%d tokens", tokPerSec, estimatedTokens)
        if isQA {
            mlxLastQAThroughput = label
        } else {
            mlxLastThroughput = label
        }
    }

    /// Public version for use in Views (e.g. RedditDetailView thematic analysis).
    @MainActor
    func recordAppleLocalThroughputPublic(text: String, elapsed: TimeInterval) {
        recordAppleLocalThroughput(text: text, elapsed: elapsed)
    }

    /// Apple Local only. On context overflow, failure, or unavailable model, asks the user where to reroute.
    func performAppleLocalOnlyPublic(
        prompt: String,
        taskName: String,
        appleRequestType: AppleIntelligenceRequestType = .summary,
        isQA: Bool = false,
        completion: @escaping (String) -> Void,
        onCancel: (() -> Void)? = nil,
        onRouteStart: ((LocalRerouteProvider) -> Void)? = nil,
        presentationScope: LocalReroutePresentationScope = .global
    ) {
        if estimateTokens(for: prompt) > appStateAppleLocalMaxTokens {
            presentLocalReroute(
                providerName: "Apple Local",
                prompt: prompt,
                taskName: taskName,
                appleRequestType: appleRequestType,
                isQA: isQA,
                completion: completion,
                onCancel: onCancel,
                onRouteStart: onRouteStart,
                presentationScope: presentationScope
            )
            return
        }

        guard #available(iOS 26.0, *), LocalSummaryService.isAvailable() else {
            presentLocalReroute(
                providerName: "Apple Local",
                prompt: prompt,
                taskName: taskName,
                appleRequestType: appleRequestType,
                isQA: isQA,
                error: appleLocalUnavailableError(),
                completion: completion,
                onCancel: onCancel,
                onRouteStart: onRouteStart,
                presentationScope: presentationScope
            )
            return
        }
        print("📱 AppState: Trying Apple Local (no fallback) for \(taskName)")
        Task(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            do {
                let response = try await self.generateAppleLocalStreaming(prompt: prompt)
                await MainActor.run {
                    self.mlxStreamingText = ""
                    print("✅ AppState: Apple Local succeeded for \(taskName)")
                    completion(response)
                }
            } catch {
                await MainActor.run {
                    self.mlxStreamingText = ""
                    print("❌ AppState: Apple Local failed for \(taskName): \(error.localizedDescription)")
                    self.presentLocalReroute(
                        providerName: "Apple Local",
                        prompt: prompt,
                        taskName: taskName,
                        appleRequestType: appleRequestType,
                        isQA: isQA,
                        error: error,
                        completion: completion,
                        onCancel: onCancel,
                        onRouteStart: onRouteStart,
                        presentationScope: presentationScope
                    )
                }
            }
        }
    }

    /// Format and publish Q&A throughput after a successful MLX generation.
    @MainActor
    private func recordMLXQAThroughput(_ metrics: MLXGenerationMetrics) {
        guard metrics.tokensPerSecond > 0 else { return }
        mlxLastQAThroughput = String(
            format: "\(selectedLocalModelLabel) · %.1f tok/s · %d tokens",
            metrics.tokensPerSecond,
            metrics.tokenCount
        )
    }

    /// Estimate and publish Q&A throughput for Apple Local generations.
    @MainActor
    private func recordAppleLocalQAThroughput(text: String, elapsed: TimeInterval) {
        guard elapsed > 0 else { return }
        let estimatedTokens = max(1, Int(Double(text.split(separator: " ").count) * 1.3))
        let tokPerSec = Double(estimatedTokens) / elapsed
        mlxLastQAThroughput = String(format: "Apple · ~%.1f tok/s · ~%d tokens", tokPerSec, estimatedTokens)
    }

    // MARK: - MLX Helpers (AppState copy)
    // These mirror the same helpers in GlobalSummaryService so both classes can use them
    // without cross-class private access.

    private let appStateMLXMaxOutputHardCap    = 1_024
    private let appStateCoreAIMLXMaxOutputHardCap = 512
    private let appStateMLXMaxContextHardCap   = LiteRTLocalService.maxContextTokens
    private let appStateCoreAIMLXMaxContextHardCap = CoreAIMLXLocalService.maxContextTokens
    private let appStateMLXContextFallback     = LiteRTLocalService.defaultContextTokens
    private let appStateAppleLocalMaxTokens    = 4096
    private let appStateMLXGenTimeout: TimeInterval   = 90
    private let appStateMLXQueryTimeout: TimeInterval = 60

    private func cappedMLXOutputTokens(_ configured: Int) -> Int {
        let hardCap = settings.selectedSummaryProvider == .coreAIMLXLocal
            ? appStateCoreAIMLXMaxOutputHardCap
            : appStateMLXMaxOutputHardCap
        return min(max(1, configured), hardCap)
    }

    private func cappedMLXContextTokens(_ configured: Int) -> Int {
        let fallback = settings.selectedSummaryProvider == .coreAIMLXLocal
            ? CoreAIMLXLocalService.defaultContextTokens
            : appStateMLXContextFallback
        let hardCap = settings.selectedSummaryProvider == .coreAIMLXLocal
            ? appStateCoreAIMLXMaxContextHardCap
            : appStateMLXMaxContextHardCap
        let resolved = configured > 0 ? configured : fallback
        return min(max(512, resolved), hardCap)
    }

    private func optimizedPromptForMLX(_ prompt: String) -> String {
        prompt
    }

    private func estimateTokens(for text: String) -> Int {
        max(1, Int(ceil(Double(text.count) / 4.0)))
    }

    private func mlxLocalPromptFits(_ prompt: String, outputTokens: Int? = nil) async -> Bool {
        let optimizedPrompt = optimizedPromptForMLX(prompt)
        let maxOutputTokens = outputTokens.map { max(1, $0) } ?? cappedMLXOutputTokens(settings.mlxMaxOutputTokens)
        let maxContextTokens = cappedMLXContextTokens(settings.mlxMaxContextTokens)
        return await LiteRTLocalService.shared.promptFits(
            optimizedPrompt,
            maxOutputTokens: maxOutputTokens,
            maxContextTokens: maxContextTokens
        )
    }

    private func coreAIMLXLocalPromptFits(_ prompt: String, outputTokens: Int? = nil) async -> Bool {
        let optimizedPrompt = optimizedPromptForMLX(prompt)
        let maxOutputTokens = outputTokens.map { max(1, $0) } ?? cappedMLXOutputTokens(settings.coreAIMLXMaxOutputTokens)
        let maxContextTokens = cappedMLXContextTokens(settings.coreAIMLXMaxContextTokens)
        return await CoreAIMLXLocalService.shared.promptFits(
            optimizedPrompt,
            maxOutputTokens: maxOutputTokens,
            maxContextTokens: maxContextTokens
        )
    }

    private func shouldRerouteLocalPrompt(_ prompt: String, outputTokens: Int? = nil) async -> Bool {
        switch settings.selectedSummaryProvider {
        case .mlxLocal:
            return !(await mlxLocalPromptFits(prompt, outputTokens: outputTokens))
        case .coreAIMLXLocal:
            return !(await coreAIMLXLocalPromptFits(prompt, outputTokens: outputTokens))
        case .appleLocal:
            return estimateTokens(for: prompt) > appStateAppleLocalMaxTokens
        default:
            return false
        }
    }

    private func isGemma4ModelID(_ modelID: String) -> Bool {
        let lowercased = modelID.lowercased()
        return lowercased.contains("gemma-4") || lowercased.contains("gemma4")
    }

    private func gemma4SummarySystemPrompt() -> String {
        """
        You summarize provided source text.
        Only use the supplied source.
        Do not continue the source text.
        Do not invent details.
        Do not quote or copy source sentences.
        Return only a short plain-text summary.
        """
    }

    private func adaptedPromptForGemma4Summary(_ prompt: String) -> String {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            let sourceTextStart = trimmed.range(of: "<source_text>"),
            let sourceTextEnd = trimmed.range(of: "</source_text>")
        else {
            return trimmed
        }

        let taskLine = trimmed
            .components(separatedBy: "Task:")
            .dropFirst()
            .joined(separator: "Task:")
            .components(separatedBy: "<source_label>")
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            ?? "Summarize the source."

        let sourceText = String(trimmed[sourceTextStart.upperBound..<sourceTextEnd.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return """
        \(taskLine)

        Source:
        \(sourceText)

        Write only the summary.
        """
    }

    private func isLikelyExtractiveSummary(_ output: String, sourcePrompt: String) -> Bool {
        let normalizedOutput = output
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedPrompt = sourcePrompt
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)

        guard normalizedOutput.count >= 48 else { return false }

        if normalizedPrompt.localizedCaseInsensitiveContains(normalizedOutput) {
            return true
        }

        let outputLines = output
            .split(whereSeparator: { $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 24 }

        guard !outputLines.isEmpty else { return false }

        let copiedLineCount = outputLines.filter {
            normalizedPrompt.localizedCaseInsensitiveContains($0)
        }.count

        return copiedLineCount * 2 >= outputLines.count
    }

    private func gemma4RetryPrompt(for originalPrompt: String) -> String {
        """
        The previous response copied the source material too closely. Try again.

        Hard rules:
        - Summarize only the substance.
        - Do not quote or copy any sentence from the source.
        - Do not repeat usernames.
        - Do not list comments one by one.
        - Combine duplicate opinions into a single theme.
        - Output only the final summary as plain text.
        - Maximum 2 short paragraphs and 90 words.

        \(originalPrompt)
        """
    }

    private struct AppStateMLXTimeoutError: LocalizedError {
        var errorDescription: String? { "MLX generation timed out. Please try again." }
    }

    private func withMLXTimeout<T: Sendable>(
        seconds: TimeInterval,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let operationTask = Task.detached(priority: .userInitiated) {
            try await operation()
        }
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                do {
                    return try await operationTask.value
                } catch is CancellationError {
                    throw AppStateMLXTimeoutError()
                } catch {
                    throw error
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                operationTask.cancel()
                throw AppStateMLXTimeoutError()
            }
            guard let result = try await group.next() else {
                operationTask.cancel()
                throw AppStateMLXTimeoutError()
            }
            group.cancelAll()
            operationTask.cancel()
            return result
        }
    }

    private var mlxGenerationTimeoutSeconds: TimeInterval { appStateMLXGenTimeout }
    private var mlxQueryTimeoutSeconds: TimeInterval { appStateMLXQueryTimeout }
    private var interactiveAskAITimeoutSeconds: TimeInterval { 120 }

    // MARK: - Public Q&A entry point

    /// Route a free-form question (with optional article context) to the configured AI provider.
    /// Call this from any view that doesn't have direct access to the internal services.
    func answerQuestion(
        _ question: String,
        context: String,
        completion: @escaping @MainActor (String) -> Void
    ) {
        let provider = settings.selectedSummaryProvider

        switch provider {
        case .mlxLocal, .coreAIMLXLocal:
            let systemPrompt = "You answer questions about an article. Use ONLY the provided text. If the answer is not in the text, say you cannot find it."
            var parts: [String] = []
            if !context.isEmpty { parts.append("Text from article:\n\(context)") }
            parts.append("Based on the text above, answer the following question.\n\nQuestion: \(question)")
            let prompt = parts.joined(separator: "\n\n")

            let modelID = selectedLocalModelID
            guard !modelID.isEmpty else {
                Task { await completion("\(selectedLocalModelLabel) model id is not configured. Set it in Settings -> Summary Provider.") }
                return
            }
            let maxOutput = cappedMLXOutputTokens(settings.selectedSummaryProvider == .coreAIMLXLocal ? settings.coreAIMLXMaxOutputTokens : settings.mlxMaxOutputTokens)
            let maxCtx = cappedMLXContextTokens(settings.selectedSummaryProvider == .coreAIMLXLocal ? settings.coreAIMLXMaxContextTokens : settings.mlxMaxContextTokens)

            Task {
                await MainActor.run { self.mlxStreamingText = "" }
                let queryOutput = maxOutput
                if await self.shouldRerouteLocalPrompt(prompt, outputTokens: queryOutput) {
                    await MainActor.run {
                        self.presentLocalReroute(
                            providerName: self.selectedLocalModelLabel,
                            prompt: prompt,
                            taskName: "Ask AI",
                            appleRequestType: .articleQA,
                            isQA: true,
                            completion: completion
                        )
                    }
                    return
                }

                do {
                    let metrics = try await withMLXTimeout(seconds: mlxQueryTimeoutSeconds) {
                        try await self.generateLocalTextWithMetrics(
                            prompt: prompt,
                            systemPrompt: systemPrompt,
                            maxOutputTokens: queryOutput,
                            maxContextTokens: maxCtx,
                            onToken: { [weak self] chunk in
                                Task { @MainActor [weak self] in self?.mlxStreamingText += chunk }
                            }
                        )
                    }
                    await self.clearLocalModelTransientCache()
                    await recordMLXQAThroughput(metrics)
                    await MainActor.run { self.mlxStreamingText = "" }
                    await completion(metrics.text)
                } catch {
                    await self.clearLocalModelTransientCache()
                    if self.isLocalProviderContextError(error) {
                        await MainActor.run {
                            self.mlxStreamingText = ""
                            self.presentLocalReroute(
                                providerName: self.selectedLocalModelLabel,
                                prompt: prompt,
                                taskName: "Ask AI",
                                appleRequestType: .articleQA,
                                isQA: true,
                                error: error,
                                completion: completion
                            )
                        }
                        return
                    }
                    await MainActor.run { self.mlxStreamingText = "" }
                    await completion("\(self.selectedLocalModelLabel) error: \(error.localizedDescription)")
                }
            }

        case .appleLocal:
            let fallbackPrompt = context.isEmpty
                ? question
                : "Based on the following article, answer this question: \(question)\n\nArticle:\n\(context)"
            if estimateTokens(for: fallbackPrompt) > appStateAppleLocalMaxTokens {
                presentLocalReroute(
                    providerName: "Apple Local",
                    prompt: fallbackPrompt,
                    taskName: "Ask AI",
                    appleRequestType: .articleQA,
                    isQA: true,
                    completion: completion
                )
                return
            }

            if #available(iOS 18.2, macOS 15.2, *), LocalSummaryService.isAvailable() {
                let t0 = Date()
                LocalSummaryService.askQuestion(about: context, question: question) { result in
                    Task {
                        let elapsed = Date().timeIntervalSince(t0)
                        switch result {
                        case .success(let text):
                            await self.recordAppleLocalQAThroughput(text: text, elapsed: elapsed)
                            await completion(text)
                        case .failure(let error):
                            if self.isLocalProviderContextError(error) {
                                await self.presentLocalReroute(
                                    providerName: "Apple Local",
                                    prompt: fallbackPrompt,
                                    taskName: "Ask AI",
                                    appleRequestType: .articleQA,
                                    isQA: true,
                                    error: error,
                                    completion: completion
                                )
                            } else {
                                await completion("Apple Local error: \(error.localizedDescription)")
                            }
                        }
                    }
                }
            } else {
                // Fall through to Gemini
                answerQuestion(question, context: context, provider: .gemini, completion: completion)
            }

        case .webAI:
            answerQuestion(question, context: context, provider: .webAI, completion: completion)

        case .summarizeDaemon:
            answerQuestion(question, context: context, provider: .summarizeDaemon, completion: completion)

        case .applePCCGateway:
            answerQuestion(question, context: context, provider: .applePCCGateway, completion: completion)

        default:
            answerQuestion(question, context: context, provider: provider, completion: completion)
        }
    }

    private func answerQuestion(
        _ question: String,
        context: String,
        provider: AppSettings.SummaryProvider,
        completion: @escaping @MainActor (String) -> Void
    ) {
        let prompt: String
        if context.isEmpty {
            prompt = question
        } else {
            prompt = "Based on the following article, answer this question: \(question)\n\nArticle:\n\(context)"
        }

        if provider == .webAI {
            performWebAIRequest(
                title: "Ask AI",
                prompt: prompt,
                onSuccess: { answer in
                    Task { await completion(answer) }
                },
                onFailure: { message in
                    Task { await completion(message) }
                }
            )
            return
        }

        if provider == .summarizeDaemon {
            Task(priority: .userInitiated) {
                do {
                    let start = Date()
                    let answer = try await self.summaryService.generateContentWithSummarize(
                        prompt: prompt,
                        settings: self.settings,
                        timeout: self.interactiveAskAITimeoutSeconds
                    )
                    let elapsed = Date().timeIntervalSince(start)
                    await MainActor.run {
                        self.recordSummarizeThroughput(text: answer, elapsed: elapsed, isQA: true)
                        completion(answer)
                    }
                } catch {
                    await MainActor.run {
                        completion("Codex / Summarize error: \(error.localizedDescription)")
                    }
                }
            }
            return
        }

        if provider == .applePCCGateway {
            Task(priority: .userInitiated) {
                do {
                    let pccPrompt = """
                    \(prompt)

                    Answer style:
                    Give a complete answer using as much relevant detail as the source supports. Do not make the answer one sentence unless the question explicitly asks for a one-sentence or very brief answer.
                    """
                    let answer = try await self.performPCCPlainTextRequestAsync(
                        prompt: pccPrompt,
                        taskName: "Ask AI",
                        isQA: true
                    )
                    await MainActor.run {
                        completion(answer)
                    }
                } catch {
                    await MainActor.run {
                        completion("Apple PCC Gateway error: \(error.localizedDescription)")
                    }
                }
            }
            return
        }

        guard !settings.geminiApiKey.isEmpty else {
            Task { await completion("No AI provider is configured. Please set an API key in Settings.") }
            return
        }
        summaryService.summarizeText("", customPrompt: prompt)
            .receive(on: RunLoop.main)
            .sink { [weak self] answer in
                guard self != nil else { return }
                Task { await completion(answer) }
            }
            .store(in: &cancellables)
    }

    // MARK: - MLX Local Summary
    private func performMLXLocalSummary(
        prompt: String,
        appleRequestType: AppleIntelligenceRequestType = .summary,
        completion: @escaping (String) -> Void,
        onCancel: (() -> Void)? = nil
    ) {
        print("🧠 AppState: Using \(selectedLocalModelLabel) model for summary")
        isLoading = true

        Task {
            await MainActor.run { self.mlxStreamingText = "" }
            if await self.shouldRerouteLocalPrompt(prompt) {
                await MainActor.run {
                    self.presentLocalReroute(
                        providerName: self.selectedLocalModelLabel,
                        prompt: prompt,
                        taskName: "Local Summary",
                        appleRequestType: appleRequestType,
                        completion: completion,
                        onCancel: onCancel
                    )
                }
                return
            }

            do {
                let result = try await summarizeWithMLXLocal(prompt: prompt)

                await MainActor.run {
                    self.mlxStreamingText = ""
                    self.isLoading = false
                    print("✅ AppState: \(self.selectedLocalModelLabel) model succeeded")
                    completion(result)
                }
            } catch {
                if isLocalProviderContextError(error) {
                    await clearLocalModelTransientCache()
                    await MainActor.run {
                        self.mlxStreamingText = ""
                        self.presentLocalReroute(
                            providerName: self.selectedLocalModelLabel,
                            prompt: prompt,
                            taskName: "Local Summary",
                            appleRequestType: appleRequestType,
                            error: error,
                            completion: completion,
                            onCancel: onCancel
                        )
                    }
                    return
                }

                await MainActor.run {
                    self.mlxStreamingText = ""
                    self.isLoading = false
                    print("❌ AppState: \(self.selectedLocalModelLabel) model failed: \(error.localizedDescription)")
                    completion("\(self.selectedLocalModelLabel) model error: \(error.localizedDescription)")
                }
            }
        }
    }

    /// Core MLX Local summarization with validation (matches red folder implementation)
    private func summarizeWithMLXLocal(prompt: String) async throws -> String {
        let modelID = selectedLocalModelID
        guard !modelID.isEmpty else {
            throw NSError(
                domain: "SummaryService.MLXLocal",
                code: 0,
                userInfo: [NSLocalizedDescriptionKey: "\(selectedLocalModelLabel) model id is missing. Set it in Settings -> Summary Provider."]
            )
        }

        let isGemma4External: Bool
        if settings.selectedSummaryProvider == .coreAIMLXLocal {
            isGemma4External = await MLXLocalService.shared.isGemma4ExternalModel(modelID: modelID)
        } else {
            isGemma4External = false
        }
        let isGemma4 = settings.selectedSummaryProvider == .coreAIMLXLocal && (isGemma4ModelID(modelID) || isGemma4External)
        let maxOutputTokens = isGemma4
            ? min(cappedMLXOutputTokens(settings.coreAIMLXMaxOutputTokens), 160)
            : cappedMLXOutputTokens(settings.selectedSummaryProvider == .coreAIMLXLocal ? settings.coreAIMLXMaxOutputTokens : settings.mlxMaxOutputTokens)
        let maxContextTokens = cappedMLXContextTokens(settings.selectedSummaryProvider == .coreAIMLXLocal ? settings.coreAIMLXMaxContextTokens : settings.mlxMaxContextTokens)
        let preparedPrompt = optimizedPromptForMLX(
            isGemma4 ? adaptedPromptForGemma4Summary(prompt) : prompt
        )

        let systemPrompt = isGemma4 ? gemma4SummarySystemPrompt() : nil

        func generateMetrics(for prompt: String) async throws -> MLXGenerationMetrics {
            try await withMLXTimeout(seconds: mlxGenerationTimeoutSeconds) {
                try await self.generateLocalTextWithMetrics(
                    prompt: prompt,
                    systemPrompt: systemPrompt,
                    maxOutputTokens: maxOutputTokens,
                    maxContextTokens: maxContextTokens,
                    onToken: { [weak self] chunk in
                        Task { @MainActor [weak self] in self?.mlxStreamingText += chunk }
                    }
                )
            }
        }

        var metrics = try await generateMetrics(for: preparedPrompt)

        if isGemma4 && isLikelyExtractiveSummary(metrics.text, sourcePrompt: preparedPrompt) {
            print("⚠️ AppState: Gemma 4 returned an extractive summary, retrying with stricter grounding prompt")
            await clearLocalModelTransientCache()
            await MainActor.run { self.mlxStreamingText = "" }
            metrics = try await generateMetrics(for: gemma4RetryPrompt(for: preparedPrompt))
        }

        await clearLocalModelTransientCache()
        await recordMLXThroughput(metrics)
        return metrics.text
    }

    /// For structured JSON output (infographics/whiteboards), MLX redirects to Apple Local
    /// because MLX struggles with strict JSON formatting
    func performMLXLocalStructuredJSON(
        prompt: String,
        kind: MLXStructuredJSONKind,
        completion: @escaping (Result<Data, Error>) -> Void
    ) {
        print("🔀 AppState: MLX selected for structured JSON - redirecting to Apple Local")

        // MLX struggles with strict JSON, so redirect to Apple Local for structured output
        if #available(iOS 18.2, *), LocalSummaryService.isAvailable() {
            LocalSummaryService.summarizeText(prompt) { [weak self] result in
                guard let self = self else { return }
                switch result {
                case .success(let response):
                    if let data = response.data(using: .utf8) {
                        // Try to parse, if it fails, attempt repair
                        do {
                            _ = try MLXJSONRepairUtils.parseLLMJSONDictionary(from: data, domain: "StructuredJSON")
                            completion(.success(data))
                        } catch {
                            // JSON parsing failed, try repair
                            Task {
                                do {
                                    let repairedData = try await MLXJSONRepairUtils.repairInvalidJSONFromMLX(
                                        kind: kind,
                                        rawOutput: response,
                                        summaryProvider: self.settings.selectedSummaryProvider,
                                        performGeminiFallback: { repairPrompt in
                                            try await withCheckedThrowingContinuation { continuation in
                                                self.summaryService.summarizeText("", customPrompt: repairPrompt)
                                                    .first()
                                                    .sink { result in
                                                        continuation.resume(returning: result)
                                                    }
                                                    .store(in: &self.cancellables)
                                            }
                                        }
                                    )
                                    await MainActor.run {
                                        completion(.success(repairedData))
                                    }
                                } catch {
                                    await MainActor.run {
                                        completion(.failure(error))
                                    }
                                }
                            }
                        }
                    } else {
                        completion(.failure(NSError(domain: "MLXStructured", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not convert response to data."])))
                    }
                case .failure(let error):
                    // Fall back to Gemini
                    print("⚠️ AppState: Apple Local failed for structured JSON, falling back to Gemini")
                    self.performGeminiFallbackForStructuredJSON(prompt: prompt, completion: completion)
                }
            }
        } else {
            // Apple Local not available, fall back to Gemini
            performGeminiFallbackForStructuredJSON(prompt: prompt, completion: completion)
        }
    }

    private func performGeminiFallbackForStructuredJSON(
        prompt: String,
        completion: @escaping (Result<Data, Error>) -> Void
    ) {
        guard !settings.geminiApiKey.isEmpty else {
            completion(.failure(NSError(domain: "MLXStructured", code: 2, userInfo: [NSLocalizedDescriptionKey: "Gemini API key not configured."])))
            return
        }

        summaryService.summarizeText("", customPrompt: prompt)
            .first()
            .sink { response in
                if let data = response.data(using: .utf8) {
                    completion(.success(data))
                } else {
                    completion(.failure(NSError(domain: "MLXStructured", code: 3, userInfo: [NSLocalizedDescriptionKey: "Could not convert Gemini response to data."])))
                }
            }
            .store(in: &cancellables)
    }

    func performMLXLocalSummaryPublic(
        prompt: String,
        completion: @escaping (String) -> Void
    ) {
        performMLXLocalSummary(prompt: prompt, completion: completion)
    }

    private func cappedMLXAnalysisOutputTokens(configured: Int, maxContextTokens: Int) -> Int {
        let hardCap = settings.selectedSummaryProvider == .coreAIMLXLocal ? 512 : 2_048
        let contextReservedCap = max(128, maxContextTokens / 4)
        let minimumForAnalysis = settings.selectedSummaryProvider == .coreAIMLXLocal ? 512 : 1_024
        let requested = max(minimumForAnalysis, configured)
        return min(requested, hardCap, contextReservedCap)
    }

    /// Local analysis with a larger but context-aware output budget for deep/thematic analysis.
    func performMLXLocalAnalysisPublic(
        prompt: String,
        completion: @escaping (String) -> Void,
        onCancel: (() -> Void)? = nil,
        onRouteStart: ((LocalRerouteProvider) -> Void)? = nil,
        presentationScope: LocalReroutePresentationScope = .global
    ) {
        let modelID = selectedLocalModelID
        guard !modelID.isEmpty else {
            completion("\(selectedLocalModelLabel) model id is not configured. Set it in Settings -> Summary Provider.")
            return
        }
        let maxCtx = cappedMLXContextTokens(settings.selectedSummaryProvider == .coreAIMLXLocal ? settings.coreAIMLXMaxContextTokens : settings.mlxMaxContextTokens)
        let configuredOutput = settings.selectedSummaryProvider == .coreAIMLXLocal ? settings.coreAIMLXMaxOutputTokens : settings.mlxMaxOutputTokens
        let maxOutput = cappedMLXAnalysisOutputTokens(configured: configuredOutput, maxContextTokens: maxCtx)
        isLoading = true
        Task { [self] in
            await MainActor.run { self.mlxStreamingText = "" }
            if await self.shouldRerouteLocalPrompt(prompt, outputTokens: maxOutput) {
                await MainActor.run {
                    self.presentLocalReroute(
                        providerName: self.selectedLocalModelLabel,
                        prompt: prompt,
                        taskName: "Local Analysis",
                        appleRequestType: .commentSummary,
                        completion: completion,
                        onCancel: onCancel,
                        onRouteStart: onRouteStart,
                        presentationScope: presentationScope
                    )
                }
                return
            }

            do {
                let metrics = try await withMLXTimeout(seconds: mlxGenerationTimeoutSeconds) {
                    try await self.generateLocalTextWithMetrics(
                        prompt: optimizedPromptForMLX(prompt),
                        maxOutputTokens: maxOutput,
                        maxContextTokens: maxCtx,
                        onToken: { [weak self] chunk in
                            Task { @MainActor [weak self] in self?.mlxStreamingText += chunk }
                        }
                    )
                }
                await self.clearLocalModelTransientCache()
                await recordMLXThroughput(metrics)
                await MainActor.run {
                    self.mlxStreamingText = ""
                    self.isLoading = false
                    completion(metrics.text)
                }
            } catch {
                await self.clearLocalModelTransientCache()
                if self.isLocalProviderContextError(error) {
                    await MainActor.run {
                        self.mlxStreamingText = ""
                        self.presentLocalReroute(
                            providerName: self.selectedLocalModelLabel,
                            prompt: prompt,
                            taskName: "Local Analysis",
                            appleRequestType: .commentSummary,
                            error: error,
                            completion: completion,
                            onCancel: onCancel,
                            onRouteStart: onRouteStart,
                            presentationScope: presentationScope
                        )
                    }
                    return
                }
                await MainActor.run {
                    self.mlxStreamingText = ""
                    self.isLoading = false
                    completion("\(self.selectedLocalModelLabel) error: \(error.localizedDescription)")
                }
            }
        }
    }

    // Public version for use in Views
    func performLocalWithGeminiFallbackPublic(
        prompt: String,
        taskName: String,
        completion: @escaping (String) -> Void
    ) {
        performLocalWithGeminiFallback(prompt: prompt, taskName: taskName, completion: completion)
    }

    // MARK: - Q&A Functionality
    func askQuestionAboutArticle(article: Article, question: String, completion: @escaping (String) -> Void) {
        print("📱 AppState: Processing question about article: \"\(question)\"")
        let cleanedCompletion: (String) -> Void = { [weak self] answer in
            guard let self = self else {
                completion(answer)
                return
            }
            completion(self.cleanAndFormatQATextForDisplay(answer))
        }

        #if os(iOS)
        if settings.youtubeSupportEnabled, article.isYouTubeVideo {
            askQuestionAboutYouTubeVideo(article: article, question: question, completion: cleanedCompletion)
            return
        }
        #endif

        if settings.selectedSummaryProvider == .webAI {
            isLoading = true
            let prompt = articleQAPrompt(article: article, question: question)
            performWebAIRequest(
                title: "Article Q&A",
                prompt: prompt,
                onSuccess: { [weak self] answer in
                    self?.isLoading = false
                    cleanedCompletion(answer)
                },
                onFailure: { [weak self] message in
                    self?.isLoading = false
                    cleanedCompletion(message)
                }
            )
            return
        }

        if settings.selectedSummaryProvider == .summarizeDaemon {
            isLoading = true
            let prompt = articleQAPrompt(article: article, question: question)
            Task(priority: .userInitiated) { [weak self] in
                guard let self else { return }
                do {
                    let start = Date()
                    let answer = try await self.summaryService.generateContentWithSummarize(prompt: prompt, settings: self.settings)
                    let elapsed = Date().timeIntervalSince(start)
                    await MainActor.run {
                        self.recordSummarizeThroughput(text: answer, elapsed: elapsed, isQA: true)
                        self.isLoading = false
                        cleanedCompletion(answer)
                    }
                } catch {
                    await MainActor.run {
                        self.isLoading = false
                        cleanedCompletion("Codex / Summarize error: \(error.localizedDescription)")
                    }
                }
            }
            return
        }

        if settings.selectedSummaryProvider == .applePCCGateway {
            isLoading = true
            let prompt = articleQAPrompt(article: article, question: question, preferCompleteAnswer: true)
            Task(priority: .userInitiated) { [weak self] in
                guard let self else { return }
                do {
                    let answer = try await self.performPCCPlainTextRequestAsync(
                        prompt: prompt,
                        taskName: "Article Q&A",
                        isQA: true
                    )
                    await MainActor.run {
                        self.isLoading = false
                        cleanedCompletion(answer)
                    }
                } catch {
                    await MainActor.run {
                        self.isLoading = false
                        cleanedCompletion("Apple PCC Gateway error: \(error.localizedDescription)")
                    }
                }
            }
            return
        }

        // Check if we should use Apple Intelligence instead
        if settings.selectedSummaryProvider == .appleLocal {
            // Use LocalSummaryService.askQuestion directly to avoid the summarizeText wrapper
            // which prepends "Provide a one-paragraph summary..." and conflicts with Q&A instructions
            // Strip HTML first — raw HTML causes LanguageModelSession to exceed context and throw
            let fallbackPrompt = articleQAPrompt(article: article, question: question)
            if estimateTokens(for: fallbackPrompt) > appStateAppleLocalMaxTokens {
                presentLocalReroute(
                    providerName: "Apple Local",
                    prompt: fallbackPrompt,
                    taskName: "Article Q&A",
                    appleRequestType: .articleQA,
                    isQA: true,
                    completion: cleanedCompletion
                )
                return
            }
            if #available(iOS 26.0, *), LocalSummaryService.isAvailable() {
                let t0 = Date()
                Task(priority: .userInitiated) { [weak self] in
                    guard let self else { return }
                    do {
                        let text = try await self.generateAppleLocalStreaming(prompt: fallbackPrompt)
                        let elapsed = Date().timeIntervalSince(t0)
                        await MainActor.run {
                            self.mlxStreamingText = ""
                            self.recordAppleLocalQAThroughput(text: text, elapsed: elapsed)
                            cleanedCompletion(text)
                        }
                    } catch {
                        await MainActor.run {
                            self.mlxStreamingText = ""
                            self.presentLocalReroute(
                                providerName: "Apple Local",
                                prompt: fallbackPrompt,
                                taskName: "Article Q&A",
                                appleRequestType: .articleQA,
                                isQA: true,
                                error: error,
                                completion: cleanedCompletion
                            )
                        }
                    }
                }
            } else {
                presentLocalReroute(
                    providerName: "Apple Local",
                    prompt: fallbackPrompt,
                    taskName: "Article Q&A",
                    appleRequestType: .articleQA,
                    isQA: true,
                    error: appleLocalUnavailableError(),
                    completion: cleanedCompletion
                )
            }
            return
        } else if settings.selectedSummaryProvider == .appleCloud {
            // Use Apple Cloud via Private Cloud Compute
            let prompt = """
            Article Title: \(article.title)
            Article Content:
            \(article.content)

            Based solely on the information in the article above, please answer the following question:
            \(question)

            If the answer cannot be determined from the article, please state that the information is not available in the article.
            Respond in plain text only. Do not use Markdown symbols, headings, or code fences.
            For longer answers, use short paragraphs separated by a blank line.
            """

            print("📱 AppState: Using Apple Cloud for Article Q&A")
            launchCloudRequest(for: prompt, type: .articleQA, completion: cleanedCompletion)
            return
        } else if settings.selectedSummaryProvider == .mlxLocal || settings.selectedSummaryProvider == .coreAIMLXLocal {
            // Use local model for Q&A with Q&A-appropriate parameters
            // Strip HTML first — raw HTML is 3-5× longer than clean text and inflates prefill time
            let rawContent = article.content ?? article.title
            let content = rawContent
                .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
                .replacingOccurrences(of: "&nbsp;", with: " ")
                .replacingOccurrences(of: "&quot;", with: "\"")
                .replacingOccurrences(of: "&amp;", with: "&")
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let systemPrompt = "You answer questions about an article. Use ONLY the provided text. If the answer is not in the text, say you cannot find it."
            let prompt = """
            Article Title: \(article.title)
            Article Content:
            \(content)

            Based solely on the information in the article above, please answer the following question:
            \(question)

            If the answer cannot be determined from the article, please state that the information is not available in the article.
            Respond in plain text only. Do not use Markdown symbols, headings, or code fences.
            For longer answers, use short paragraphs separated by a blank line.
            """

            let modelID = selectedLocalModelID
            guard !modelID.isEmpty else {
                cleanedCompletion("\(selectedLocalModelLabel) model id is not configured. Set it in Settings -> Summary Provider.")
                return
            }
            let maxOutput = cappedMLXOutputTokens(settings.selectedSummaryProvider == .coreAIMLXLocal ? settings.coreAIMLXMaxOutputTokens : settings.mlxMaxOutputTokens)
            let maxCtx = cappedMLXContextTokens(settings.selectedSummaryProvider == .coreAIMLXLocal ? settings.coreAIMLXMaxContextTokens : settings.mlxMaxContextTokens)
            isLoading = true
            Task { [self] in
                await MainActor.run { self.mlxStreamingText = "" }
                if await self.shouldRerouteLocalPrompt(prompt, outputTokens: maxOutput) {
                    await MainActor.run {
                        self.presentLocalReroute(
                            providerName: self.selectedLocalModelLabel,
                            prompt: prompt,
                            taskName: "Article Q&A",
                            appleRequestType: .articleQA,
                            isQA: true,
                            completion: cleanedCompletion
                        )
                    }
                    return
                }

                do {
                    let metrics = try await withMLXTimeout(seconds: mlxQueryTimeoutSeconds) {
                        try await self.generateLocalTextWithMetrics(
                            prompt: optimizedPromptForMLX(prompt),
                            systemPrompt: systemPrompt,
                            maxOutputTokens: maxOutput,
                            maxContextTokens: maxCtx,
                            onToken: { [weak self] chunk in
                                Task { @MainActor [weak self] in self?.mlxStreamingText += chunk }
                            }
                        )
                    }
                    await self.clearLocalModelTransientCache()
                    await recordMLXQAThroughput(metrics)
                    await MainActor.run {
                        self.mlxStreamingText = ""
                        self.isLoading = false
                        cleanedCompletion(metrics.text)
                    }
                } catch {
                    await self.clearLocalModelTransientCache()
                    if self.isLocalProviderContextError(error) {
                        await MainActor.run {
                            self.mlxStreamingText = ""
                            self.presentLocalReroute(
                                providerName: self.selectedLocalModelLabel,
                                prompt: prompt,
                                taskName: "Article Q&A",
                                appleRequestType: .articleQA,
                                isQA: true,
                                error: error,
                                completion: cleanedCompletion
                            )
                        }
                        return
                    }
                    await MainActor.run {
                        self.mlxStreamingText = ""
                        self.isLoading = false
                        cleanedCompletion("\(self.selectedLocalModelLabel) error: \(error.localizedDescription)")
                    }
                }
            }
            return
        }

        // Original Gemini code
        isLoading = true

        let prompt = articleQAPrompt(article: article, question: question)

        summaryService.summarizeText("", customPrompt: prompt)
            .receive(on: RunLoop.main)
            .sink { answer in
                self.isLoading = false
                print("📱 AppState: Received answer to question")
                cleanedCompletion(answer)
            }
            .store(in: &cancellables)
    }
    
    func askQuestionAboutRedditPost(post: RedditPost, comments: [RedditCommentModel], question: String, completion: @escaping (String) -> Void) {
        print("📱 AppState: Processing question about Reddit post: \"\(question)\"")
        let cleanedCompletion: (String) -> Void = { [weak self] answer in
            guard let self = self else {
                completion(answer)
                return
            }
            completion(self.cleanAndFormatQATextForDisplay(answer))
        }

        // Extract all comment text
        let commentTexts = comments.flatMap { extractAllCommentTexts(from: $0) }
        let combinedComments = commentTexts.joined(separator: "\n\n")

        if settings.selectedSummaryProvider == .webAI {
            isLoading = true
            let prompt = redditQAPrompt(post: post, comments: comments, question: question)
            performWebAIRequest(
                title: "Reddit Q&A",
                prompt: prompt,
                onSuccess: { [weak self] answer in
                    self?.isLoading = false
                    cleanedCompletion(answer)
                },
                onFailure: { [weak self] message in
                    self?.isLoading = false
                    cleanedCompletion(message)
                }
            )
            return
        }

        if settings.selectedSummaryProvider == .summarizeDaemon {
            isLoading = true
            let prompt = redditQAPrompt(post: post, comments: comments, question: question)
            Task(priority: .userInitiated) { [weak self] in
                guard let self else { return }
                do {
                    let start = Date()
                    let answer = try await self.summaryService.generateContentWithSummarize(prompt: prompt, settings: self.settings)
                    let elapsed = Date().timeIntervalSince(start)
                    await MainActor.run {
                        self.recordSummarizeThroughput(text: answer, elapsed: elapsed, isQA: true)
                        self.isLoading = false
                        cleanedCompletion(answer)
                    }
                } catch {
                    await MainActor.run {
                        self.isLoading = false
                        cleanedCompletion("Codex / Summarize error: \(error.localizedDescription)")
                    }
                }
            }
            return
        }

        if settings.selectedSummaryProvider == .applePCCGateway {
            isLoading = true
            let prompt = redditQAPrompt(post: post, comments: comments, question: question, preferCompleteAnswer: true)
            Task(priority: .userInitiated) { [weak self] in
                guard let self else { return }
                do {
                    let answer = try await self.performPCCPlainTextRequestAsync(
                        prompt: prompt,
                        taskName: "Reddit Q&A",
                        isQA: true
                    )
                    await MainActor.run {
                        self.isLoading = false
                        cleanedCompletion(answer)
                    }
                } catch {
                    await MainActor.run {
                        self.isLoading = false
                        cleanedCompletion("Apple PCC Gateway error: \(error.localizedDescription)")
                    }
                }
            }
            return
        }

        // Check if we should use Apple Intelligence instead
        if settings.selectedSummaryProvider == .appleLocal {
            // Use LocalSummaryService.askQuestion directly (like article Q&A) to avoid
            // the summarizeText wrapper which prepends "Provide a summary..." and confuses Apple Intelligence
            let fallbackPrompt = redditQAPrompt(post: post, comments: comments, question: question)
            if estimateTokens(for: fallbackPrompt) > appStateAppleLocalMaxTokens {
                presentLocalReroute(
                    providerName: "Apple Local",
                    prompt: fallbackPrompt,
                    taskName: "Reddit Q&A",
                    appleRequestType: .redditQA,
                    isQA: true,
                    completion: cleanedCompletion
                )
                return
            }
            if #available(iOS 26.0, *), LocalSummaryService.isAvailable() {
                let t0 = Date()
                Task(priority: .userInitiated) { [weak self] in
                    guard let self else { return }
                    do {
                        let text = try await self.generateAppleLocalStreaming(prompt: fallbackPrompt)
                        let elapsed = Date().timeIntervalSince(t0)
                        await MainActor.run {
                            self.mlxStreamingText = ""
                            self.recordAppleLocalQAThroughput(text: text, elapsed: elapsed)
                            cleanedCompletion(text)
                        }
                    } catch {
                        await MainActor.run {
                            self.mlxStreamingText = ""
                            self.presentLocalReroute(
                                providerName: "Apple Local",
                                prompt: fallbackPrompt,
                                taskName: "Reddit Q&A",
                                appleRequestType: .redditQA,
                                isQA: true,
                                error: error,
                                completion: cleanedCompletion
                            )
                        }
                    }
                }
            } else {
                presentLocalReroute(
                    providerName: "Apple Local",
                    prompt: fallbackPrompt,
                    taskName: "Reddit Q&A",
                    appleRequestType: .redditQA,
                    isQA: true,
                    error: appleLocalUnavailableError(),
                    completion: cleanedCompletion
                )
            }
            return
        } else if settings.selectedSummaryProvider == .appleCloud {
            // Use Apple Cloud via Private Cloud Compute
            let prompt = """
            Reddit Post Title: \(post.title)
            Post Content:
            \(post.content)

            Comments:
            \(combinedComments)

            Based solely on the information in the Reddit post and comments above, please answer the following question:
            \(question)

            If the answer cannot be determined from the post or comments, please state that the information is not available.
            Respond in plain text only. Do not use Markdown symbols, headings, or code fences.
            For longer answers, use short paragraphs separated by a blank line.
            """

            print("📱 AppState: Using Apple Cloud for Reddit Q&A")
            launchCloudRequest(for: prompt, type: .redditQA, completion: cleanedCompletion)
            return
        } else if settings.selectedSummaryProvider == .mlxLocal || settings.selectedSummaryProvider == .coreAIMLXLocal {
            // Use local model for Q&A with Q&A-appropriate parameters
            let systemPrompt = "You answer questions about a Reddit post and its comments. Use ONLY the provided text. If the answer is not in the text, say you cannot find it."
            let prompt = """
            Reddit Post Title: \(post.title)
            Post Content:
            \(post.content)

            Comments:
            \(combinedComments)

            Based solely on the information in the Reddit post and comments above, please answer the following question:
            \(question)

            If the answer cannot be determined from the post or comments, please state that the information is not available.
            Respond in plain text only. Do not use Markdown symbols, headings, or code fences.
            For longer answers, use short paragraphs separated by a blank line.
            """

            let modelID = selectedLocalModelID
            guard !modelID.isEmpty else {
                cleanedCompletion("\(selectedLocalModelLabel) model id is not configured. Set it in Settings -> Summary Provider.")
                return
            }
            let maxOutput = cappedMLXOutputTokens(settings.selectedSummaryProvider == .coreAIMLXLocal ? settings.coreAIMLXMaxOutputTokens : settings.mlxMaxOutputTokens)
            let maxCtx = cappedMLXContextTokens(settings.selectedSummaryProvider == .coreAIMLXLocal ? settings.coreAIMLXMaxContextTokens : settings.mlxMaxContextTokens)
            isLoading = true
            Task { [self] in
                await MainActor.run { self.mlxStreamingText = "" }
                if await self.shouldRerouteLocalPrompt(prompt, outputTokens: maxOutput) {
                    await MainActor.run {
                        self.presentLocalReroute(
                            providerName: self.selectedLocalModelLabel,
                            prompt: prompt,
                            taskName: "Reddit Q&A",
                            appleRequestType: .redditQA,
                            isQA: true,
                            completion: cleanedCompletion
                        )
                    }
                    return
                }

                do {
                    let metrics = try await withMLXTimeout(seconds: mlxQueryTimeoutSeconds) {
                        try await self.generateLocalTextWithMetrics(
                            prompt: optimizedPromptForMLX(prompt),
                            systemPrompt: systemPrompt,
                            maxOutputTokens: maxOutput,
                            maxContextTokens: maxCtx,
                            onToken: { [weak self] chunk in
                                Task { @MainActor [weak self] in self?.mlxStreamingText += chunk }
                            }
                        )
                    }
                    await self.clearLocalModelTransientCache()
                    await recordMLXQAThroughput(metrics)
                    await MainActor.run {
                        self.mlxStreamingText = ""
                        self.isLoading = false
                        cleanedCompletion(metrics.text)
                    }
                } catch {
                    await self.clearLocalModelTransientCache()
                    if self.isLocalProviderContextError(error) {
                        await MainActor.run {
                            self.mlxStreamingText = ""
                            self.presentLocalReroute(
                                providerName: self.selectedLocalModelLabel,
                                prompt: prompt,
                                taskName: "Reddit Q&A",
                                appleRequestType: .redditQA,
                                isQA: true,
                                error: error,
                                completion: cleanedCompletion
                            )
                        }
                        return
                    }
                    await MainActor.run {
                        self.mlxStreamingText = ""
                        self.isLoading = false
                        cleanedCompletion("\(self.selectedLocalModelLabel) error: \(error.localizedDescription)")
                    }
                }
            }
            return
        }

        // Original Gemini code
        isLoading = true

        let prompt = redditQAPrompt(post: post, comments: comments, question: question, maxComments: 800)

        summaryService.summarizeText("", customPrompt: prompt)
            .receive(on: RunLoop.main)
            .sink { answer in
                self.isLoading = false
                print("📱 AppState: Received answer to Reddit question")
                cleanedCompletion(answer)
            }
            .store(in: &cancellables)
    }
    
    func askQuestionAboutGlobalSummary(question: String, completion: @escaping (String) -> Void) {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            completion("Please enter a question to ask about the summary overview.")
            return
        }
        guard let context = lastGlobalSummaryContext else {
            completion("Generate a summary overview first, then try asking a question.")
            return
        }
        
        if !globalSummaryArticles.isEmpty {
            let articles = globalSummaryArticles
            guard !articles.isEmpty else {
                completion("No articles are available for this question. Please regenerate the summary.")
                return
            }
            let prompt = buildGlobalArticlesQuestionPrompt(articles: articles, question: trimmed)
            executeGlobalQAPrompt(prompt: prompt, completion: completion)
            return
        }
        
        if !globalSummaryPosts.isEmpty {
            let posts = globalSummaryPosts
            guard !posts.isEmpty else {
                completion("No Reddit posts are available for this question. Please regenerate the summary.")
                return
            }
            
            // Check if we have valid cached comments for the current posts
            let cachedPostIds = Set(cachedRedditCommentsForQA.map { $0.0.id })
            let currentPostIds = Set(posts.map { $0.id })
            let cacheIsValid = !cachedRedditCommentsForQA.isEmpty && cachedPostIds == currentPostIds
            
            if cacheIsValid {
                // Use cached comments - no API calls needed
                print("✅ AppState.GlobalQA: Using cached comments for \(cachedRedditCommentsForQA.count) posts")
                let usableContexts = cachedRedditCommentsForQA.filter { !$0.1.isEmpty || !self.sanitizedSnippet(from: $0.0.content, limit: 800).isEmpty }
                guard !usableContexts.isEmpty else {
                    completion("Unable to load Reddit comments for this summary. Please try again later.")
                    return
                }
                let prompt = self.buildGlobalRedditQuestionPrompt(contexts: usableContexts, question: trimmed)
                self.executeGlobalQAPrompt(prompt: prompt, completion: completion)
            } else {
                // Fetch comments and cache them for subsequent questions
                print("📡 AppState.GlobalQA: Fetching and caching comments for \(posts.count) posts")
                let topComments = topCommentsCount(for: context) ?? 3
                fetchCommentsForGlobalSummary(posts: posts, topComments: topComments) { [weak self] contexts in
                    guard let self = self else { return }
                    
                    // Cache the fetched comments for subsequent Q&A questions
                    self.cachedRedditCommentsForQA = contexts
                    print("✅ AppState.GlobalQA: Cached comments for \(contexts.count) posts")
                    
                    let usableContexts = contexts.filter { !$0.1.isEmpty || !self.sanitizedSnippet(from: $0.0.content, limit: 800).isEmpty }
                    guard !usableContexts.isEmpty else {
                        completion("Unable to load Reddit comments for this summary. Please try again later.")
                        return
                    }
                    let prompt = self.buildGlobalRedditQuestionPrompt(contexts: usableContexts, question: trimmed)
                    self.executeGlobalQAPrompt(prompt: prompt, completion: completion)
                }
            }
            return
        }
        
        completion("No summary data is available for Q&A at the moment. Please generate a summary first.")
    }

    /// Answers from the already-saved per-item summaries only. This deliberately performs no Reddit fetch.
    func askQuestionAboutSavedGlobalSummaries(
        question: String,
        useWebAI: Bool,
        completion: @escaping (String) -> Void
    ) {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            completion("Please enter a question to ask about the summary overview.")
            return
        }
        guard let data = globalSummaryJSON.data(using: .utf8),
              let result = try? JSONDecoder().decode(GlobalSummaryResult.self, from: data),
              !result.summaries.isEmpty else {
            completion("No saved item summaries are available for this question.")
            return
        }

        let sections = result.summaries.enumerated().map { index, item in
            "Item \(index + 1):\nSubject: \(item.subject)\nSummary: \(item.summary)"
        }.joined(separator: "\n\n")
        let prompt = """
        Answer the question using only the saved per-item summaries below. These are condensed summaries, not the full extracted Reddit comments, so clearly acknowledge when the available summaries do not contain enough detail.

        SAVED ITEM SUMMARIES:
        \(sections)

        QUESTION:
        \(trimmed)

        Return plain text only. Do not use Markdown symbols, headings, bullets, or code fences.
        """

        if useWebAI {
            executeWebGlobalQAPrompt(prompt: prompt, completion: completion)
        } else {
            executeGlobalQAPrompt(prompt: prompt, completion: completion)
        }
    }

    /// Uses the exact cached comments from the summary extraction. Large sources are processed in
    /// 40,000-character chunks and then combined, so no second Reddit extraction is performed.
    func askQuestionAboutGlobalSummarySelection(
        selectedText: String,
        extractedContext: String,
        referenceId: String? = nil,
        useWebAI: Bool,
        completion: @escaping (String) -> Void
    ) {
        let selected = normalizedSelectionText(selectedText, limit: 8_000)
        let nearby = normalizedSelectionText(extractedContext, limit: 16_000)
        guard !selected.isEmpty else {
            completion("Select some text first.")
            return
        }

        let normalizedReference = referenceId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var contexts = cachedRedditCommentsForQA
        if !normalizedReference.isEmpty {
            contexts = contexts.filter { $0.0.id == normalizedReference }
        } else if !globalSummaryPosts.isEmpty {
            let currentPostIds = Set(globalSummaryPosts.map { $0.id })
            contexts = contexts.filter { currentPostIds.contains($0.0.id) }
        }

        guard !contexts.isEmpty else {
            let source = globalSummarySelectionSourceContext(referenceId: referenceId, isReddit: !globalSummaryPosts.isEmpty)
            let fallbackPrompt = buildAskAISelectionPrompt(
                selectedText: selected,
                extractedContext: nearby,
                sourceContext: source?.text ?? "",
                sourceLabel: source?.label ?? ""
            )
            guard !fallbackPrompt.isEmpty else {
                completion("No saved source material is available for this selection.")
                return
            }
            if useWebAI {
                askWebQuestionAboutSelection(prompt: fallbackPrompt, completion: completion)
            } else {
                askQuestionAboutSelection(prompt: fallbackPrompt, completion: completion)
            }
            return
        }

        let sections = contexts.enumerated().map { index, entry in
            let post = entry.0
            let comments = entry.1.isEmpty
                ? "(No comments were captured for this post.)"
                : entry.1.map { "- \($0)" }.joined(separator: "\n")
            return """
            Reddit Item \(index + 1):
            Subreddit: r/\(post.subreddit)
            Title: \(post.title)
            Post:
            \(normalizedSelectionText(post.content, limit: 2_000))
            Extracted comments used for the summary:
            \(comments)
            """
        }
        let chunks = chunkedSelectionSources(sections, maxCharacters: 40_000)
        guard !chunks.isEmpty else {
            completion("No saved source material is available for this selection.")
            return
        }

        if chunks.count == 1 {
            let prompt = selectionAnswerPrompt(selected: selected, nearby: nearby, source: chunks[0])
            executeSelectionPrompt(prompt, useWebAI: useWebAI, completion: completion)
            return
        }

        func processChunk(_ index: Int, evidence: [String]) {
            guard index < chunks.count else {
                let finalPrompt = """
                Produce the final answer to the selection question using only the evidence extracted from all source chunks below.

                Selected text:
                \(selected)

                Nearby rendered context:
                \(nearby.isEmpty ? "(None captured.)" : nearby)

                CHUNK EVIDENCE:
                \(evidence.enumerated().map { "Chunk \($0.offset + 1):\n\($0.element)" }.joined(separator: "\n\n"))

                If the evidence does not answer the selection, say that explicitly. Return plain text only, using short paragraphs and no Markdown symbols, headings, bullets, or code fences.
                """
                executeSelectionPrompt(finalPrompt, useWebAI: useWebAI, completion: completion)
                return
            }

            let evidencePrompt = """
            Inspect this source chunk for evidence that explains or adds relevant detail about the selected text. Do not invent facts and do not rely on outside knowledge.

            Selected text:
            \(selected)

            Nearby rendered context:
            \(nearby.isEmpty ? "(None captured.)" : nearby)

            SOURCE CHUNK \(index + 1) OF \(chunks.count):
            \(chunks[index])

            Return a compact plain-text evidence note of at most 250 words. If this chunk has no relevant evidence, return exactly: NO RELEVANT EVIDENCE
            """
            executeSelectionPrompt(evidencePrompt, useWebAI: useWebAI) { answer in
                processChunk(index + 1, evidence: evidence + [answer])
            }
        }

        processChunk(0, evidence: [])
    }

    private func executeSelectionPrompt(
        _ prompt: String,
        useWebAI: Bool,
        completion: @escaping (String) -> Void
    ) {
        if useWebAI {
            executeWebGlobalQAPrompt(prompt: prompt, completion: completion)
        } else {
            executeGlobalQAPrompt(prompt: prompt, completion: completion)
        }
    }

    private func selectionAnswerPrompt(selected: String, nearby: String, source: String) -> String {
        """
        Answer what the saved Reddit posts and extracted comments say about the selected text. Use only the supplied source material.

        Selected text:
        \(selected)

        Nearby rendered context:
        \(nearby.isEmpty ? "(None captured.)" : nearby)

        SAVED SOURCE MATERIAL:
        \(source)

        If the source does not answer it, say so explicitly. Return plain text only, using short paragraphs and no Markdown symbols, headings, bullets, or code fences.
        """
    }

    private func normalizedSelectionText(_ text: String, limit: Int) -> String {
        let value = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.count <= limit ? value : String(value.prefix(limit))
    }

    private func chunkedSelectionSources(_ sections: [String], maxCharacters: Int) -> [String] {
        var chunks: [String] = []
        var current = ""

        func appendCurrent() {
            guard !current.isEmpty else { return }
            chunks.append(current)
            current = ""
        }

        for section in sections {
            if section.count > maxCharacters {
                appendCurrent()
                var remaining = section[...]
                while !remaining.isEmpty {
                    let end = remaining.index(remaining.startIndex, offsetBy: min(maxCharacters, remaining.count))
                    chunks.append(String(remaining[..<end]))
                    remaining = remaining[end...]
                }
            } else if current.isEmpty {
                current = section
            } else if current.count + 2 + section.count <= maxCharacters {
                current += "\n\n" + section
            } else {
                appendCurrent()
                current = section
            }
        }
        appendCurrent()
        return chunks
    }
    
    private func executeGlobalQAPrompt(prompt: String, completion: @escaping (String) -> Void) {
        let cleanedCompletion: (String) -> Void = { [weak self] answer in
            guard let self = self else {
                completion(answer)
                return
            }
            completion(self.cleanMarkdownArtifactsForDisplay(answer))
        }

        switch settings.selectedSummaryProvider {
        case .appleLocal:
            performLocalWithGeminiFallback(prompt: prompt, taskName: "Global Summary Q&A", completion: cleanedCompletion)
        case .appleCloud:
            launchCloudRequest(for: prompt, type: .globalSummaryQA, completion: cleanedCompletion)
        case .applePCCGateway:
            Task(priority: .userInitiated) {
                do {
                    let answer = try await self.performPCCPlainTextRequestAsync(
                        prompt: prompt,
                        taskName: "Global Summary Q&A",
                        isQA: true
                    )
                    await MainActor.run {
                        cleanedCompletion(answer)
                    }
                } catch {
                    await MainActor.run {
                        cleanedCompletion("Apple PCC Gateway error: \(error.localizedDescription)")
                    }
                }
            }
        case .mlxLocal, .coreAIMLXLocal:
            performMLXLocalSummary(prompt: prompt, completion: cleanedCompletion)
        case .webAI:
            performWebAIRequest(
                title: "Global Summary Q&A",
                prompt: prompt,
                onSuccess: cleanedCompletion,
                onFailure: { cleanedCompletion($0) }
            )
        case .summarizeDaemon:
            Task(priority: .userInitiated) {
                do {
                    let start = Date()
                    let answer = try await self.summaryService.generateContentWithSummarize(prompt: prompt, settings: self.settings)
                    let elapsed = Date().timeIntervalSince(start)
                    await MainActor.run {
                        self.recordSummarizeThroughput(text: answer, elapsed: elapsed, isQA: true)
                        cleanedCompletion(answer)
                    }
                } catch {
                    await MainActor.run {
                        cleanedCompletion("Codex / Summarize error: \(error.localizedDescription)")
                    }
                }
            }
        default:
            summaryService.summarizeText("", customPrompt: prompt)
                .receive(on: RunLoop.main)
                .sink { answer in
                    cleanedCompletion(answer)
                }
                .store(in: &cancellables)
        }
    }
    
    private func buildGlobalArticlesQuestionPrompt(articles: [Article], question: String) -> String {
        let sections = articles.enumerated().map { index, article in
            let content = sanitizedSnippet(from: article.content, limit: 1800)
            let fallback = article.summary ?? ""
            let body = content.isEmpty ? fallback : content
            let source = article.feedTitle
            let link = article.url?.absoluteString ?? article.feedURL
            return """
            Article \(index + 1):
            Source: \(source)
            Title: \(article.title)
            Link: \(link)
            Content:
            \(body)
            """
        }.joined(separator: "\n\n")
        
        return """
        You are answering a question using ONLY the following news articles. Reference them when helpful and avoid speculation.

        ARTICLES:
        \(sections)

        QUESTION:
        \(question)

        INSTRUCTIONS:
        - Cite specific articles when relevant (e.g., "Article 2 mentions…").
        - If the information is not available, clearly say so.
        - Respond in plain text only. Do not use Markdown symbols, headings, or code fences.
        """
    }
    
    private func buildGlobalRedditQuestionPrompt(contexts: [(RedditPost, [String])], question: String) -> String {
        let sections = contexts.enumerated().map { index, entry in
            let post = entry.0
            let comments = entry.1
            let body = sanitizedSnippet(from: post.content, limit: 1200)
            let commentSection: String
            if comments.isEmpty {
                commentSection = "  - No top comments captured."
            } else {
                commentSection = comments.map { "  - \(truncateText($0, limit: 400))" }.joined(separator: "\n")
            }
            return """
            Reddit Item \(index + 1):
            Subreddit: r/\(post.subreddit)
            Title: \(post.title)
            Body:
            \(body.isEmpty ? "(No body text provided)" : body)
            Top Comments:
            \(commentSection)
            """
        }.joined(separator: "\n\n")
        
        return """
        You are answering a question about multiple Reddit discussions. Use ONLY the information provided here.

        POSTS & COMMENTS:
        \(sections)

        QUESTION:
        \(question)

        INSTRUCTIONS:
        - Mention specific posts when supporting your answer.
        - Reflect relevant comment sentiment when available.
        - If the answer isn't contained here, explicitly say it's unavailable.
        - Respond in plain text only. Do not use Markdown symbols, headings, or code fences.
        """
    }
    
    private func fetchCommentsForGlobalSummary(posts: [RedditPost], topComments: Int, completion: @escaping ([(RedditPost, [String])]) -> Void) {
        guard !posts.isEmpty else {
            completion([])
            return
        }
        
        let publishers = posts.map { post in
            redditService.fetchCommentsDetailed(for: post.id, in: post.subreddit, limit: topComments, depth: 0)
                .map { result -> (RedditPost, [String]) in
                    if let error = result.error {
                        print("⚠️ AppState.GlobalQA: Comment fetch error for \(post.id): \(error.localizedDescription)")
                    }
                    let filtered = result.comments.filter { $0.author.lowercased() != "automoderator" }
                    let comments = Array(filtered.prefix(max(1, topComments))).map { "u/\($0.author): \($0.body)" }
                    if comments.isEmpty {
                        return (post, ["No comments captured for this post."])
                    }
                    return (post, comments)
                }
                .eraseToAnyPublisher()
        }
        
        Publishers.MergeMany(publishers)
            .collect()
            .receive(on: RunLoop.main)
            .sink { contexts in
                let ordered = posts.compactMap { post in
                    contexts.first(where: { $0.0.id == post.id })
                }
                completion(ordered)
            }
            .store(in: &cancellables)
    }
    
    private func sanitizedSnippet(from text: String?, limit: Int) -> String {
        guard let text = text, !text.isEmpty else { return "" }
        let stripped = text
            .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&[^;]+;", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if stripped.count <= limit { return stripped }
        let endIndex = stripped.index(stripped.startIndex, offsetBy: limit)
        return String(stripped[..<endIndex]) + "…"
    }
    
    private func truncateText(_ text: String, limit: Int) -> String {
        if text.count <= limit { return text }
        let index = text.index(text.startIndex, offsetBy: limit)
        return String(text[..<index]) + "…"
    }
    
    private func topCommentsCount(for context: GlobalSummaryContext) -> Int? {
        switch context {
        case .allReddit(let count),
             .todayReddit(let count),
             .subreddit(_, let count),
             .subredditHot(_, let count),
             .subredditSorted(_, _, let count):
            return count
        default:
            return nil
        }
    }
    
    // Helper function to extract all comment texts recursively
    func extractAllCommentTexts(from comment: RedditCommentModel) -> [String] {
        var texts = ["u/\(comment.author): \(comment.body)"]

        for reply in comment.replies {
            texts.append(contentsOf: extractAllCommentTexts(from: reply))
        }

        return texts
    }
}

// MARK: - LocalSummaryService
// Temporary: Including LocalSummaryService here until it's properly added to the Xcode project

@available(iOS 18.2, macOS 15.2, *)
class LocalSummaryService {
    
    // Check if Apple Intelligence is available on this device
    static func isAvailable() -> Bool {
        // Check if FoundationModels is available
        // This will return true on compatible devices with iOS 18.2+
        return true
    }
    
    // Summarize text using on-device model
    static func summarizeText(_ text: String, completion: @escaping (Result<String, Error>) -> Void) {
        Task {
            do {
                let session = LanguageModelSession()
                let prompt = "Provide a one-paragraph summary (4-6 sentences) of the following text:\n\n\(text)"
                let response = try await session.respond(to: prompt)
                
                DispatchQueue.main.async {
                    completion(.success(response.content))
                }
            } catch {
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
            }
        }
    }
    
    // Ask question about text using on-device model
    static func askQuestion(about text: String, question: String, completion: @escaping (Result<String, Error>) -> Void) {
        Task {
            do {
                let session = LanguageModelSession()
                let prompt = """
                Based on the following text, please answer this question:
                
                Question: \(question)
                
                Text:
                \(text)
                
                If the answer cannot be determined from the text, please state that the information is not available.
                """
                
                let response = try await session.respond(to: prompt)
                
                DispatchQueue.main.async {
                    completion(.success(response.content))
                }
            } catch {
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
            }
        }
    }
}

struct LatestNewsSnapshotBuilder {
    static func buildSnapshot(fromFeeds feeds: [Feed], redditFeeds: [RedditFeed]) async -> LatestNewsSnapshot? {
        guard #available(iOS 14.0, macOS 11.0, *) else { return nil }

        let articleItems: [LatestNewsItem] = feeds.flatMap { feed in
            feed.articles.map { article in
                let subtitleSource = firstNonEmptyString(article.summary, article.content.removingHTML())
                return LatestNewsItem(
                    id: "article-\(article.id)",
                    title: article.title,
                    source: article.feedTitle,
                    subtitle: makeSnippet(from: subtitleSource),
                    publishedAt: article.publishDate,
                    deeplink: makeDeeplink(for: "article", id: article.id),
                    imageURL: article.imageURL ?? article.faviconURL,
                    imageData: nil
                )
            }
        }

        let redditItems: [LatestNewsItem] = redditFeeds.flatMap { feed in
            feed.posts.map { post in
                let subtitleSource = firstNonEmptyString(post.content, "u/\(post.author)")
                return LatestNewsItem(
                    id: "reddit-\(post.id)",
                    title: post.title,
                    source: "r/\(post.subreddit)",
                    subtitle: makeSnippet(from: subtitleSource),
                    publishedAt: post.publishDate,
                    deeplink: makeDeeplink(for: "reddit", id: post.id),
                    imageURL: post.bestImageURL ?? post.thumbnail.flatMap { URL(string: $0) },
                    imageData: nil
                )
            }
        }

        let combined = (articleItems + redditItems).sorted { $0.publishedAt > $1.publishedAt }
        guard !combined.isEmpty else { return nil }

        let trimmed = Array(combined.prefix(20))
        let enriched = await enrichItemsWithImages(trimmed)
        return LatestNewsSnapshot(generatedAt: Date(), items: enriched)
    }

    private static func makeSnippet(from text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return nil
        }

        let clean = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let maxLength = 120
        if clean.count <= maxLength {
            return clean
        }

        let index = clean.index(clean.startIndex, offsetBy: maxLength)
        let prefix = clean[..<index]
        return prefix.trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }

    private static func makeDeeplink(for kind: String, id: String) -> URL? {
        guard let encoded = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            return nil
        }
        return URL(string: "rssreader://\(kind)/\(encoded)")
    }

    private static func firstNonEmptyString(_ values: String?...) -> String? {
        for value in values {
            if let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty {
                return trimmed
            }
        }
        return nil
    }

    @available(iOS 14.0, macOS 11.0, *)
    private static func enrichItemsWithImages(_ items: [LatestNewsItem]) async -> [LatestNewsItem] {
        await withTaskGroup(of: LatestNewsItem.self) { group in
            for item in items {
                group.addTask {
                    var copy = item
                    if copy.imageData == nil, let url = item.imageURL {
                        copy.imageData = await fetchImageData(for: url)
                    }
                    return copy
                }
            }
            var enriched: [LatestNewsItem] = []
            for await item in group {
                enriched.append(item)
            }
            return enriched.sorted { $0.publishedAt > $1.publishedAt }
        }
    }

    @available(iOS 14.0, macOS 11.0, *)
    private static func fetchImageData(for url: URL) async -> Data? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 6
        request.setValue("RSSReaderWidget/1.0", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                return nil
            }

            if data.count > 200_000 {
                return downscaleImageData(data, maxDimension: 256)
            }
            return data
        } catch {
            print("⚠️ LatestNewsStore: Failed to fetch image data for \(url): \(error.localizedDescription)")
            return nil
        }
    }

    @available(iOS 14.0, macOS 11.0, *)
    private static func downscaleImageData(_ data: Data, maxDimension: CGFloat) -> Data? {
        #if os(iOS)
        guard let image = UIImage(data: data) else { return nil }
        let largestSide = max(image.size.width, image.size.height)
        guard largestSide > maxDimension else { return data }
        let scale = maxDimension / largestSide
        let newSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)

        UIGraphicsBeginImageContextWithOptions(newSize, false, 1)
        image.draw(in: CGRect(origin: .zero, size: newSize))
        let resized = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        return resized?.jpegData(compressionQuality: 0.8)
        #elseif os(macOS)
        guard let image = NSImage(data: data) else { return nil }
        let largestSide = max(image.size.width, image.size.height)
        guard largestSide > maxDimension else { return data }
        let scale = maxDimension / largestSide
        let newSize = NSSize(width: image.size.width * scale, height: image.size.height * scale)

        let resized = NSImage(size: newSize)
        resized.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: newSize), from: .zero, operation: .copy, fraction: 1.0)
        resized.unlockFocus()
        guard let tiff = resized.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.8])
        #else
        return data
        #endif
    }
}

enum LocalSummaryError: LocalizedError {
    case notAvailable
    case notYetImplemented
    case modelNotReady
    
    var errorDescription: String? {
        switch self {
        case .notAvailable:
            return "Apple Intelligence is not available on this device. Please use Cloud or Gemini instead."
        case .notYetImplemented:
            return "On-device AI is coming soon. Please use Cloud or Gemini for now."
        case .modelNotReady:
            return "The on-device model is not ready. Please try again later."
        }
    }
}
