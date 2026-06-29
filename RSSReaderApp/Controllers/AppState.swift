import Foundation
import Combine
import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif
#if canImport(Kingfisher)
import Kingfisher
#endif
#if canImport(WebKit)
import WebKit
#endif
#if canImport(FoundationModels)
import FoundationModels
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

// MARK: - Inline Global Summary (models + service) for simplicity
// These are defined inline so we don't rely on separate target membership.
// If you later enable the standalone files, remove this inline block to avoid duplicate types.

struct GlobalSummaryItem: Codable, Identifiable {
    let id = UUID()
    let subject: String
    let summary: String
    let referenceId: String?  // Article ID or Reddit Post ID for navigation
}

struct GlobalSummaryResult: Codable {
    let source: String
    let summaries: [GlobalSummaryItem]
    let error: String?
    
    static func errorResult(source: String, message: String) -> GlobalSummaryResult {
        GlobalSummaryResult(source: source, summaries: [], error: message)
    }
}

struct RedditStatusMessage: Equatable {
    let subreddit: String
    let text: String
    let statusCode: Int
    let resetDate: Date?
    let remaining: Double?
    let capturedAt: Date

    var formattedReset: String? {
        guard let resetDate else { return nil }
        let seconds = max(Int(resetDate.timeIntervalSinceNow.rounded()), 0)
        return seconds > 0 ? "\(seconds)s" : nil
    }
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

final class GlobalSummaryService {
    private let summaryService: SummaryService
    private let redditService: RedditService
    private let settingsProvider: () -> AppSettings
    private var cloudRequestHandler: ((String, @escaping (String) -> Void) -> Void)?
    private var webRequestHandler: ((WebAIProvider, String, String, WebAIResponseFormat, @escaping (Result<String, Error>) -> Void) -> Void)?
    var warningReporter: ((String) -> Void)?
    var throughputReporter: ((String) -> Void)?

    init(summaryService: SummaryService, redditService: RedditService, settingsProvider: @escaping () -> AppSettings = { PersistenceManager.shared.loadSettings() }, cloudRequestHandler: ((String, @escaping (String) -> Void) -> Void)? = nil) {
        self.summaryService = summaryService
        self.redditService = redditService
        self.settingsProvider = settingsProvider
        self.cloudRequestHandler = cloudRequestHandler
    }

    func setCloudRequestHandler(_ handler: @escaping (String, @escaping (String) -> Void) -> Void) {
        self.cloudRequestHandler = handler
    }

    func setWebRequestHandler(_ handler: @escaping (WebAIProvider, String, String, WebAIResponseFormat, @escaping (Result<String, Error>) -> Void) -> Void) {
        self.webRequestHandler = handler
    }

    // Articles: title + first 5000 chars excerpt (HTML-stripped) + article IDs
    func summarizeArticlesGlobally(
        articles: [Article],
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
        return callLLMAndDecode(source: "articles", prompt: prompt, referenceIds: articleIds, selectedProvider: selectedProvider)
    }
    
    func summarizeRedditGlobally(
        posts: [RedditPost],
        topComments: Int = 10,
        providerOverride: AppSettings.SummaryProvider? = nil
    ) -> AnyPublisher<GlobalSummaryResult, Never> {
        guard !posts.isEmpty else {
            let msg = "No Reddit posts available for summarization."
            print("❌ GlobalSummaryService: \(msg)")
            return Just(GlobalSummaryResult.errorResult(source: "reddit", message: msg)).eraseToAnyPublisher()
        }

        let orderedPosts = posts.enumerated().map { (index: $0.offset, post: $0.element) }

        return Deferred {
            Future { [weak self] promise in
                guard let self else {
                    promise(.success(GlobalSummaryResult.errorResult(source: "reddit", message: "Reddit summary service unavailable.")))
                    return
                }

                Task(priority: .userInitiated) {
                    var results: Array<(index: Int, post: RedditPost, topLevel: [RedditCommentModel])?> = Array(repeating: nil, count: orderedPosts.count)
                    var pendingIndices = Set(orderedPosts.map { $0.index })
                    var sequentialIndices = Set<Int>()
                    var triggeredSequential = false

                    func storeResult(for index: Int, result: RedditCommentFetchResult) {
                        let post = orderedPosts[index].post
                        let topLevel = result.comments
                            .filter { $0.indentationLevel == 0 }
                            .sorted { $0.score > $1.score }
                        let limited = Array(topLevel.prefix(topComments))
                        results[index] = (index: index, post: post, topLevel: limited)
                        print("📱 GlobalSummaryService: Collected \(limited.count) comments for post ID: \(post.id)")
                        if let error = result.errorDescription, !error.isEmpty {
                            print("⚠️ GlobalSummaryService: Comment fetch warning for post ID \(post.id) – \(error)")
                        }
                    }

                    let maxParallel = min(3, orderedPosts.count)
                    var nextParallelIndex = 0

                    await withTaskGroup(of: (Int, RedditCommentFetchResult).self) { group in
                        func scheduleNext() {
                            guard !triggeredSequential else { return }
                            guard nextParallelIndex < orderedPosts.count else { return }
                            let entry = orderedPosts[nextParallelIndex]
                            nextParallelIndex += 1
                            group.addTask {
                                let result = await self.redditService.fetchCommentsDetailed(for: entry.post.id, in: entry.post.subreddit, limit: topComments, depth: 0)
                                return (entry.index, result)
                            }
                        }

                        for _ in 0..<maxParallel {
                            scheduleNext()
                        }

                        for await (index, fetchResult) in group {
                            pendingIndices.remove(index)

                            if Task.isCancelled {
                                return
                            }

                            if let status = fetchResult.rateLimit, status.statusCode == 429 {
                                print("⚠️ GlobalSummaryService: Rate limit hit during parallel fetch for index \(index)")
                                triggeredSequential = true
                                sequentialIndices.insert(index)
                            } else {
                                storeResult(for: index, result: fetchResult)
                            }

                            if !triggeredSequential {
                                scheduleNext()
                            }
                        }
                    }

                    if Task.isCancelled {
                        promise(.success(GlobalSummaryResult.errorResult(source: "reddit", message: "Reddit summarization cancelled.")))
                        return
                    }

                    if triggeredSequential {
                        // Any indices we never scheduled, plus those that hit 429, get processed sequentially
                        for index in pendingIndices {
                            sequentialIndices.insert(index)
                        }

                        var lastRateStatus: RedditRateLimitStatus? = nil
                        for index in sequentialIndices.sorted() {
                            if Task.isCancelled {
                                promise(.success(GlobalSummaryResult.errorResult(source: "reddit", message: "Reddit summarization cancelled.")))
                                return
                            }

                            if let status = lastRateStatus {
                                var delay = self.redditService.suggestedDelay(after: status, baseline: 0.75)
                                if delay > 2 {
                                    print("⚠️ GlobalSummaryService: Clamping sequential delay from \(String(format: "%.2f", delay))s to 2s")
                                    delay = 2
                                }
                                if delay > 0 {
                                    print("⏱️ GlobalSummaryService: Sequential delay \(String(format: "%.2f", delay))s before refetching index \(index)")
                                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                                }
                            }

                            let entry = orderedPosts[index]
                            print("📱 GlobalSummaryService: Sequentially refetching comments for post index \(index) in r/\(entry.post.subreddit)")
                            let fetchResult = await self.redditService.fetchCommentsDetailed(for: entry.post.id, in: entry.post.subreddit, limit: topComments, depth: 0)
                            storeResult(for: index, result: fetchResult)
                            if let updatedStatus = fetchResult.rateLimit {
                                lastRateStatus = updatedStatus
                            }
                        }
                    }

                    for index in 0..<orderedPosts.count {
                        if results[index] == nil {
                            let post = orderedPosts[index].post
                            results[index] = (index: index, post: post, topLevel: [])
                        }
                    }

                    let ordered = results.compactMap { $0 }.sorted { $0.index < $1.index }
                    let postIds = ordered.map { $0.post.id }
                    let payload: [RedditPayloadItem] = ordered.map { triple in
                        let truncated = triple.topLevel.map { "u/\($0.author): \(Self.firstNChars($0.body, 500))" }
                        return RedditPayloadItem(
                            title: triple.post.title,
                            postText: Self.firstNChars(triple.post.content, 2000),
                            topComments: truncated
                        )
                    }

                    if payload.allSatisfy({ $0.title.isEmpty && $0.postText.isEmpty && $0.topComments.isEmpty }) {
                        let msg = "No usable Reddit content (titles/text/comments) for summarization."
                        print("❌ GlobalSummaryService: \(msg)")
                        promise(.success(GlobalSummaryResult.errorResult(source: "reddit", message: msg)))
                        return
                    }

                    print("✅ GlobalSummaryService: Prepared \(payload.count) Reddit items (title + post + ≤\(topComments) comments)")

                    let settings = self.settingsProvider()
                    let selectedProvider = providerOverride ?? settings.selectedSummaryProvider

                    let prompt = self.buildRedditPrompt(items: payload, topComments: topComments)
                    let publisher = self.callLLMAndDecode(source: "reddit", prompt: prompt, referenceIds: postIds, selectedProvider: selectedProvider)

                    let summaryResult = await withCheckedContinuation { continuation in
                        var sinkCancellable: AnyCancellable?
                        sinkCancellable = publisher.sink { result in
                            continuation.resume(returning: result)
                            sinkCancellable?.cancel()
                        }
                    }

                    promise(.success(summaryResult))
                }
            }
        }
        .eraseToAnyPublisher()
    }
    
    // MARK: - Prompt Builders
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
            Excerpt (≤500 chars):
            \(item.excerpt)
            """
        }.joined(separator: "\n\n")
        let footer = """
        
        Output:
        - A single JSON object exactly as specified, with "source":"articles".
        """
        return [header, body, footer].joined(separator: "\n")
    }
    
    private struct RedditPayloadItem {
        let title: String
        let postText: String
        let topComments: [String]
    }
    
    private func buildRedditPrompt(items: [RedditPayloadItem], topComments: Int) -> String {
        let header = """
        Task: For each Reddit thread, craft a subject-focused summary that fuses the post’s theme with the debate happening in the comments.
        Requirements:
        - For every item, produce JSON objects shaped exactly like:
          { "subject": "<concise theme>", "summary": "<2–3 sentences combining the post's premise with prevailing comment takeaways>" }
        - Make the summary answer BOTH:
            1. What the original post is about.
            2. How commenters reacted — highlight consensus, disagreements, memorable quotes, or shifts in sentiment drawn from the \(topComments) top-level comments.
        - Identify when commenters reinforce the post, challenge it, or introduce new angles; mention notable divides or agreements.
        - Preserve the input order and write in neutral, factual tone.
        - Output ONLY a single JSON object:
          { "source": "reddit", "summaries": [ { "subject": "...", "summary": "..." } ], "error": null }
        - No code fences or commentary.

        Inputs (ordered):
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
        
        Output:
        - A single JSON object exactly as specified, with "source":"reddit".
        """
        return [header, body, footer].joined(separator: "\n")
    }
    
    // MARK: - LLM Call + JSON Decode
    private func callLLMAndDecode(
        source: String,
        prompt: String,
        referenceIds: [String] = [],
        selectedProvider: AppSettings.SummaryProvider? = nil
    ) -> AnyPublisher<GlobalSummaryResult, Never> {
        let settings = settingsProvider()
        let provider = selectedProvider ?? settings.selectedSummaryProvider

        if provider == .summarizeDaemon {
            print("⚙️ GlobalSummaryService: Using Codex / Summarize for \(source) summary")
            return Future<GlobalSummaryResult, Never> { promise in
                Task(priority: .userInitiated) {
                    do {
                        let raw = try await self.summaryService.generateContentWithSummarize(prompt: prompt, settings: settings)
                        let result = self.parseAndDecodeResponse(raw: raw, source: source, referenceIds: referenceIds)
                        promise(.success(result))
                    } catch {
                        let result = GlobalSummaryResult.errorResult(source: source, message: "Codex / Summarize error: \(error.localizedDescription)")
                        promise(.success(result))
                    }
                }
            }
            .eraseToAnyPublisher()
        }

        if provider == .applePCCGateway {
            print("☁️ GlobalSummaryService: Using Apple PCC fm CLI for \(source) summary")
            return Future<GlobalSummaryResult, Never> { promise in
                Task(priority: .userInitiated) {
                    do {
                        let start = Date()
                        let raw = try await self.summaryService.generateContentWithPCCGateway(prompt: prompt, settings: settings)
                        let elapsed = max(0.001, Date().timeIntervalSince(start))
                        let estimatedTokens = max(1, Int(Double(raw.split(separator: " ").count) * 1.3))
                        let tokPerSec = Double(estimatedTokens) / elapsed
                        self.throughputReporter?(String(format: "Apple PCC · ~%.1f tok/s · ~%d tokens", tokPerSec, estimatedTokens))
                        let result = self.parseAndDecodeResponse(raw: raw, source: source, referenceIds: referenceIds)
                        promise(.success(result))
                    } catch {
                        let result = GlobalSummaryResult.errorResult(source: source, message: "Apple PCC error: \(error.localizedDescription)")
                        promise(.success(result))
                    }
                }
            }
            .eraseToAnyPublisher()
        }

        // Route to local model if selected
        if provider == .mlxLocal || provider == .coreAIMLXLocal {
            let useCoreAIMLX = provider == .coreAIMLXLocal
            let providerLabel = useCoreAIMLX ? "CoreAI MLX Local" : "LiteRT Local"
            print("🧠 GlobalSummaryService: Using \(providerLabel) for \(source) summary")
            return Future<GlobalSummaryResult, Never> { promise in
                Task {
                    do {
                        let modelID = (useCoreAIMLX ? settings.coreAIMLXModelID : settings.mlxModelID).trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !modelID.isEmpty else {
                            let result = GlobalSummaryResult.errorResult(source: source, message: "\(providerLabel) model id is missing. Set it in Settings -> Summary Provider.")
                            promise(.success(result))
                            return
                        }

                        let maxContextTokens = useCoreAIMLX
                            ? AppSettings.effectiveCoreAIMLXContextTokens(settings.coreAIMLXMaxContextTokens)
                            : AppSettings.effectiveLiteRTContextTokens(settings.mlxMaxContextTokens)
                        let maxOutputTokens = useCoreAIMLX
                            ? AppSettings.normalizedCoreAIMLXOutputTokens(settings.coreAIMLXMaxOutputTokens, contextTokens: maxContextTokens)
                            : AppSettings.normalizedLiteRTOutputTokens(settings.mlxMaxOutputTokens, contextTokens: maxContextTokens)
                        
                        // Truncate prompt to prevent OOM (~4 chars per token, reserve space for output)
                        let maxPromptChars = max(1000, (maxContextTokens - maxOutputTokens - 100) * 4)
                        let safePrompt = prompt.count > maxPromptChars
                            ? String(prompt.prefix(maxPromptChars)) + "\n[Truncated]"
                            : prompt

                        let raw: String
                        if useCoreAIMLX {
                            raw = try await CoreAIMLXLocalService.shared.generateText(
                                prompt: safePrompt,
                                modelID: modelID,
                                maxOutputTokens: maxOutputTokens,
                                maxContextTokens: maxContextTokens
                            )
                        } else {
                            raw = try await LiteRTLocalService.shared.generateText(
                                prompt: safePrompt,
                                modelID: modelID,
                                maxOutputTokens: maxOutputTokens,
                                maxContextTokens: maxContextTokens
                            )
                        }

                        let result = self.parseAndDecodeResponse(raw: raw, source: source, referenceIds: referenceIds)
                        promise(.success(result))
                    } catch {
                        let result = GlobalSummaryResult.errorResult(source: source, message: "\(providerLabel) error: \(error.localizedDescription)")
                        promise(.success(result))
                    }
                }
            }.eraseToAnyPublisher()
        }

        // Route to Apple Local if selected
        if provider == .appleLocal {
            print("📱 GlobalSummaryService: Using Apple Local for \(source) summary")
            return Future<GlobalSummaryResult, Never> { promise in
                if #available(iOS 18.2, macOS 15.2, *), LocalSummaryService.isAvailable() {
                    LocalSummaryService.summarizeText(prompt) { result in
                        switch result {
                        case .success(let raw):
                            let parsed = self.parseAndDecodeResponse(raw: raw, source: source, referenceIds: referenceIds)
                            promise(.success(parsed))
                        case .failure(let error):
                            let errorResult = GlobalSummaryResult.errorResult(source: source, message: "Apple Local error: \(error.localizedDescription)")
                            promise(.success(errorResult))
                        }
                    }
                } else {
                    let errorResult = GlobalSummaryResult.errorResult(source: source, message: "Apple Local is not available on this device.")
                    promise(.success(errorResult))
                }
            }.eraseToAnyPublisher()
        }

        // Route to Apple Cloud if selected
        if provider == .appleCloud {
            print("☁️ GlobalSummaryService: Using Apple Cloud for \(source) summary")
            guard let handler = cloudRequestHandler else {
                print("❌ GlobalSummaryService: Apple Cloud handler not configured")
                return Just(GlobalSummaryResult.errorResult(source: source, message: "Apple Cloud is not configured. Please try again."))
                    .eraseToAnyPublisher()
            }
            return Future<GlobalSummaryResult, Never> { promise in
                handler(prompt) { raw in
                    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.isEmpty {
                        let result = GlobalSummaryResult.errorResult(source: source, message: "Apple Cloud returned an empty response.")
                        promise(.success(result))
                        return
                    }
                    let result = self.parseAndDecodeResponse(raw: trimmed, source: source, referenceIds: referenceIds)
                    print("☁️ GlobalSummaryService: Apple Cloud returned \(trimmed.count) characters for \(source), parsed result has \(result.summaries.count) summaries")
                    promise(.success(result))
                }
            }.eraseToAnyPublisher()
        }

        if provider == .webAI {
            let provider = settingsProvider().selectedWebAIProvider
            let title = source == "reddit" ? "Reddit Batch Summary" : "Article Batch Summary"
            print("🌐 GlobalSummaryService: Using \(provider.displayName) Web AI for \(source) summary")
            guard let handler = webRequestHandler else {
                let msg = "Web AI handler unavailable for overall summary."
                print("❌ GlobalSummaryService: \(msg)")
                return Just(GlobalSummaryResult.errorResult(source: source, message: msg)).eraseToAnyPublisher()
            }

            return Future<GlobalSummaryResult, Never> { promise in
                handler(provider, title, prompt, .strictJSON) { result in
                    switch result {
                    case .success(let raw):
                        let parsed = self.parseAndDecodeResponse(raw: raw, source: source, referenceIds: referenceIds)
                        promise(.success(parsed))
                    case .failure(let error):
                        promise(.success(GlobalSummaryResult.errorResult(source: source, message: error.localizedDescription)))
                    }
                }
            }
            .eraseToAnyPublisher()
        }

        // Default: Use Gemini via SummaryService
        return summaryService
            .summarizeText("", customPrompt: prompt)
            .map { raw -> GlobalSummaryResult in
                self.parseAndDecodeResponse(raw: raw, source: source, referenceIds: referenceIds)
            }
            .replaceError(with: GlobalSummaryResult.errorResult(source: source, message: "LLM call failed"))
            .eraseToAnyPublisher()
    }
    
    private func parseAndDecodeResponse(raw: String, source: String, referenceIds: [String]) -> GlobalSummaryResult {
        // Clean the response: remove markdown code blocks if present
        var cleanedResponse = raw
        
        // Remove ```json at the start and ``` at the end if present
        if cleanedResponse.hasPrefix("```json") {
            cleanedResponse = String(cleanedResponse.dropFirst(7))
            if cleanedResponse.hasPrefix("\n") {
                cleanedResponse = String(cleanedResponse.dropFirst(1))
            }
        }
        // Also check for just ```
        else if cleanedResponse.hasPrefix("```") {
            cleanedResponse = String(cleanedResponse.dropFirst(3))
            if cleanedResponse.hasPrefix("\n") {
                cleanedResponse = String(cleanedResponse.dropFirst(1))
            }
        }
        
        // Remove trailing markdown code block
        if cleanedResponse.hasSuffix("```") {
            cleanedResponse = String(cleanedResponse.dropLast(3))
            if cleanedResponse.hasSuffix("\n") {
                cleanedResponse = String(cleanedResponse.dropLast(1))
            }
        }
        
        // Trim whitespace and newlines
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
        // Fix double quotes in strings (some models use smart quotes)
        cleanedResponse = cleanedResponse.replacingOccurrences(of: "\u{201C}", with: "\"") // Left double quote
        cleanedResponse = cleanedResponse.replacingOccurrences(of: "\u{201D}", with: "\"") // Right double quote
        cleanedResponse = cleanedResponse.replacingOccurrences(of: "\u{2018}", with: "'")  // Left single quote
        cleanedResponse = cleanedResponse.replacingOccurrences(of: "\u{2019}", with: "'")  // Right single quote

        // Detect upstream error strings before attempting to decode JSON
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

            let msg = "Failed to decode JSON: \(errorDetails). This usually means the model didn't follow the exact format. Try again."
            print("❌ GlobalSummaryService: \(msg)")
            return GlobalSummaryResult.errorResult(source: source, message: msg)
        }
    }
    
    // MARK: - Utilities
    private static func stripHTML(_ html: String) -> String {
        let noTags = html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        return noTags
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private static func firstNChars(_ text: String, _ n: Int) -> String {
        if text.count <= n { return text }
        return String(text.prefix(n))
    }
    
    // MARK: - MLX Per-Item Processing
    // MLX has limited context window, so we process items one at a time and aggregate results
    
    /// Process articles one-by-one for MLX and return aggregated GlobalSummaryResult
    private func processArticlesWithMLX(
        items: [(id: String, title: String, excerpt: String)]
    ) -> AnyPublisher<GlobalSummaryResult, Never> {
        let settings = settingsProvider()
        let modelID = settings.mlxModelID.trimmingCharacters(in: .whitespacesAndNewlines)
        let maxOutputTokens = max(1, settings.mlxMaxOutputTokens)
        
        guard !modelID.isEmpty else {
            return Just(GlobalSummaryResult.errorResult(source: "articles", message: "MLX model id is missing. Set it in Settings → Summary Provider."))
                .eraseToAnyPublisher()
        }
        
        return Future<GlobalSummaryResult, Never> { promise in
            Task {
                var summaries: [GlobalSummaryItem] = []
                
                print("🧠 MLX: Processing \(items.count) articles individually...")
                
                for (index, item) in items.enumerated() {
                    // Build a simple prompt for single article (limit excerpt to ~2000 chars for MLX)
                    let limitedExcerpt = String(item.excerpt.prefix(2000))
                    let singlePrompt = """
                    Summarize this article in 2-3 sentences. Be concise and focus on the main point.
                    
                    Title: \(item.title)
                    Content: \(limitedExcerpt)
                    
                    Provide your response as:
                    Subject: [short topic phrase, 5-8 words]
                    Summary: [2-3 sentence summary]
                    """
                    
                    do {
                        let raw = try await MLXLocalService.shared.generateText(
                            prompt: singlePrompt,
                            modelID: modelID,
                            maxOutputTokens: maxOutputTokens,
                            maxContextTokens: 4096
                        )
                        
                        // Parse the response
                        let (subject, summary) = self.parseMLXSingleResponse(raw: raw, fallbackTitle: item.title)
                        summaries.append(GlobalSummaryItem(subject: subject, summary: summary, referenceId: item.id))
                        print("✅ MLX: Processed article \(index + 1)/\(items.count): \(item.title.prefix(30))...")
                        
                    } catch {
                        print("❌ MLX: Failed article \(index + 1): \(error.localizedDescription)")
                        // Add error placeholder for this item
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
        let modelID = settings.mlxModelID.trimmingCharacters(in: .whitespacesAndNewlines)
        let maxOutputTokens = max(1, settings.mlxMaxOutputTokens)
        
        guard !modelID.isEmpty else {
            return Just(GlobalSummaryResult.errorResult(source: "reddit", message: "MLX model id is missing. Set it in Settings → Summary Provider."))
                .eraseToAnyPublisher()
        }
        
        return Future<GlobalSummaryResult, Never> { promise in
            Task {
                var summaries: [GlobalSummaryItem] = []
                
                print("🧠 MLX: Processing \(items.count) Reddit posts individually...")
                
                for (index, item) in items.enumerated() {
                    // Build a simple prompt for single post (limit content for MLX)
                    let limitedPost = String(item.postText.prefix(1500))
                    let limitedComments = item.topComments.prefix(5).map { String($0.prefix(300)) }.joined(separator: "\n")
                    
                    let singlePrompt = """
                    Summarize this Reddit post in 2-3 sentences. Include key insights from comments if relevant.
                    
                    Title: \(item.title)
                    Post: \(limitedPost)
                    Top Comments:
                    \(limitedComments)
                    
                    Provide your response as:
                    Subject: [short topic phrase, 5-8 words]
                    Summary: [2-3 sentence summary including comment insights]
                    """
                    
                    do {
                        let raw = try await MLXLocalService.shared.generateText(
                            prompt: singlePrompt,
                            modelID: modelID,
                            maxOutputTokens: maxOutputTokens,
                            maxContextTokens: 4096
                        )
                        
                        // Parse the response
                        let (subject, summary) = self.parseMLXSingleResponse(raw: raw, fallbackTitle: item.title)
                        let refId = index < postIds.count ? postIds[index] : nil
                        summaries.append(GlobalSummaryItem(subject: subject, summary: summary, referenceId: refId))
                        print("✅ MLX: Processed post \(index + 1)/\(items.count): \(item.title.prefix(30))...")
                        
                    } catch {
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

@MainActor
class AppState: ObservableObject {
    // MARK: - Published Properties
    @Published var subscriptions: [Subscription] = []
    @Published var feeds: [Feed] = []
    @Published var redditFeeds: [RedditFeed] = []
    @Published var selectedFeed: Feed?
    @Published var selectedRedditFeed: RedditFeed?
    
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
    
    // Scroll position tracking
    // Map of subscription URL to item ID.
    // Not @Published to avoid triggering list diffing while SwiftUI updates rows.
    var scrollPositions: [String: String] = [:]
    
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
    
    // Get saved scroll position for a subscription
    func getSavedScrollPosition(for subscriptionURL: String) -> String? {
        return scrollPositions[subscriptionURL]
    }
    
    // Function to clear selection and navigate back to previous subscription if available
    func navigateBack() {
        // Clear current selection
        self.selectedArticle = nil
        self.selectedRedditPost = nil
        self.selectedArticleId = nil
        self.selectedRedditPostId = nil
        
        // When backing out of a detailed view, if we don't have a specific subscription URL
        // but we do have a lastSelectedCategory, ensure we indicate we're going back to that category
        // rather than defaulting to favorites
        if self.activeSubscriptionURL == nil && self.lastSelectedCategory != .favorites {
            // Make sure we go back to the last selected category instead of favorites
            print("📱 AppState: Navigating back to \(self.lastSelectedCategory.rawValue) category")
        }
        
        // We don't need to do anything else here since ContentView will observe
        // these changes and update the navigation accordingly
    }
    
    @Published var isLoading: Bool = false
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
    @Published var mlxLastThroughput: String = "" // Last summary tok/s for on-device providers
    @Published var mlxLastQAThroughput: String = "" // Last Q&A tok/s (separate to avoid bleed)
    @Published var mlxStreamingText: String = ""
    @Published var readStateRevision: Int = 0
    @Published private(set) var unreadCountBySubscriptionKey: [String: Int] = [:]
    @Published private(set) var unreadAllArticles: Int = 0
    @Published private(set) var unreadAllReddit: Int = 0
    @Published var redditStatusMessages: [String: RedditStatusMessage] = [:] // Per-subreddit status alerts
    @Published var aggregatedRedditStatusMessage: RedditStatusMessage? = nil // Global Reddit status banner

    private struct PendingWebAIRequest {
        let title: String
        let provider: WebAIProvider
        let prompt: String
        let responseFormat: WebAIResponseFormat
        let onSuccess: (String) -> Void
        let onFailure: (String) -> Void
    }

    private var pendingWebAIRequests: [UUID: PendingWebAIRequest] = [:]
    
    // Today summary state
    @Published var isGeneratingTodaySummary: Bool = false
    @Published var todaySummaryResult: String?
    @Published var todaySummaryError: String?
    @Published var todaySummaryInfo: String?
    
    // Global summary UI state
    @Published var showGlobalSummary: Bool = false
    @Published var globalSummaryJSON: String = ""
    @Published var lastGlobalSummaryError: String? = nil
    @Published var hasCachedSummary: Bool = false  // Track if we have a summary to show

    // Retry context
    enum GlobalSummaryContext {
        case articles([Article])
        case reddit([RedditPost], Int)
        case subreddit(String, Int)
        case subredditHot(String, Int)
        case subredditSorted(String, RedditService.SortOption, Int)
        case todayArticles
        case todayReddit
    }
    var lastGlobalSummaryContext: GlobalSummaryContext?

    // Aggregate summary state
    @Published var isGeneratingAggregateSummary: Bool = false
    @Published var aggregateSummaryText: String?
    @Published var aggregateSummaryProviderName: String?
    @Published var aggregateSummaryError: String?
    private var aggregateSummarySourceFingerprint: String?

    // Global Summary Q&A state
    @Published var isWaitingForGlobalQA: Bool = false
    @Published var globalQAWaitProgress: String = ""

    // Store references to articles/posts being summarized for navigation
    private var globalSummaryArticles: [Article] = []
    private var globalSummaryPosts: [RedditPost] = []
    private var globalSummaryComments: [(RedditPost, [String])] = [] // Cached comments for Q&A
    // Global Q&A character limits (per item, not total count)
    // No limit on number of items - sends all articles/posts from the summary

    func redditPostForGlobalSummaryReference(_ referenceId: String) -> RedditPost? {
        if let post = globalSummaryPosts.first(where: { $0.id == referenceId }) {
            return post
        }

        for feed in redditFeeds {
            if let post = feed.posts.first(where: { $0.id == referenceId }) {
                return post
            }
        }

        return nil
    }

    func articleForGlobalSummaryReference(_ referenceId: String) -> Article? {
        if let article = globalSummaryArticles.first(where: { $0.id == referenceId }) {
            return article
        }

        for feed in feeds {
            if let article = feed.articles.first(where: { $0.id == referenceId }) {
                return article
            }
        }

        return nil
    }

    // MARK: - Services
    private let feedService: FeedService
    let redditService: RedditService

    // Changed from "private var" to "internal var" so we can call it in RedditDetailView
    // Or keep it private and expose a function. But simplest is to reference it directly:
    let summaryService: SummaryService

    // NEW: A single shared CommentSummaryService that uses the same summaryService
    let commentSummaryService: CommentSummaryService

    // NEW: Add QAService for article and reddit Q&A
    let qaService: QAService
    // NEW: GlobalSummaryService for global summarization
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
    private var redditFeedSortState: [String: RedditService.SortOption] = [:]
    private var redditFeedSortCache: [String: RedditFeed] = [:]
    private var isUnreadCacheRebuildScheduled = false

    // MARK: - Initialization
    init(feedService: FeedService? = nil,
         redditService: RedditService? = nil,
         summaryService: SummaryService? = nil,
         persistenceManager: PersistenceManager? = nil) {
        
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

        // 3. Initialize summaryService with the user's Gemini key
        let geminiKey = loadedSettings.geminiApiKey
        self.summaryService = summaryService ?? SummaryService(apiKey: geminiKey)

        // 3.5. Initialize Reddit OAuth Manager
        self.redditOAuthManager = RedditOAuthManager()

        // 4. Initialize the other services
        self.feedService = feedService ?? FeedService()
        self.redditService = redditService ?? RedditService(oauthManager: self.redditOAuthManager)

        // 5. Initialize the shared CommentSummaryService with the same summaryService
        self.commentSummaryService = CommentSummaryService(summaryService: self.summaryService)

        // 6. Initialize the QA service with the same summaryService
        self.qaService = QAService(summaryService: self.summaryService)
        // 6.5 Initialize GlobalSummaryService with shared services
        self.globalSummaryService = GlobalSummaryService(summaryService: self.summaryService, redditService: self.redditService)

        // 6.6 Set up Apple Cloud handler for global summaries
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
                onFailure: {
                    completion(.failure(NSError(
                        domain: "WebAI",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: $0]
                    )))
                }
            )
        }

        // 6.7 Wire warning and throughput reporters for global summaries
        self.globalSummaryService.warningReporter = { [weak self] message in
            DispatchQueue.main.async {
                self?.fallbackNotification = message
                self?.showFallbackNotification = true
            }
        }
        self.globalSummaryService.throughputReporter = { [weak self] throughputText in
            DispatchQueue.main.async {
                self?.mlxLastThroughput = throughputText
            }
        }

        // 7. Load data from storage (subscriptions, etc.)
        loadSavedData()

        // 7.5 Warm up MLX/AppleLocal model in the background if needed
        Task { [weak self] in await self?.warmUpMLXIfNeeded() }

        // 8. Setup refresh timer
        setupRefreshTimer()

        #if os(macOS)
        RSSSummarizeBridgeServer.shared.reconfigure(settings: loadedSettings)
        #endif

        // 9. Setup iCloud sync listener for read/favorite state changes
        setupCloudSyncListener()
    }

    // Manual cloud refresh (pull latest from iCloud and reapply)
    enum ManualCloudSyncState: Equatable {
        case idle
        case syncing
        case completed
    }

    @Published var manualCloudSyncState: ManualCloudSyncState = .idle
    @Published var manualCloudSyncStatusMessage: String?

    // MARK: - Data Loading
    private func loadSavedData() {
        subscriptions = persistenceManager.loadSubscriptions()
        scheduleUnreadCacheRebuild()
        refreshAllFeeds()
    }

    private func setupRefreshTimer() {
        Timer.publish(every: settings.refreshInterval, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.refreshAllFeeds()
            }
            .store(in: &cancellables)

        // Clear all caches every 10 minutes to prevent stale cache issues
        Timer.publish(every: 600, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                print("🔄 Auto-clearing caches (10-minute interval)")
                self?.clearAllCaches()
            }
            .store(in: &cancellables)
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

        // Fallback: Poll iCloud every 60 seconds in case notifications don't arrive
        Timer.publish(every: 60, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.pollCloudForChanges()
            }
            .store(in: &cancellables)
    }

    private func handleSnapshotChange(_ snapshot: CloudSyncManager.ReadStateSnapshot) {
        // Process the full snapshot - this handles late subscriber replay
        persistenceManager.handleRemoteReadArticlesChange(snapshot.readArticles)
        persistenceManager.handleRemoteFavoriteArticlesChange(snapshot.favoriteArticles)
        persistenceManager.handleRemoteReadRedditPostsChange(snapshot.readRedditPosts)
        persistenceManager.handleRemoteFavoriteRedditPostsChange(snapshot.favoriteRedditPosts)

        // Defer UI state updates to next runloop to avoid "Modifying state during view update" warning
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.updateArticleReadStatesFromCloud()
            self.updateArticleFavoriteStatesFromCloud()
            self.updateRedditPostReadStatesFromCloud()
            self.updateRedditPostFavoriteStatesFromCloud()
        }
    }

    private func pollCloudForChanges() {
        // Pull-only: read from cloud, merge into local, but do NOT write back
        // This avoids race conditions where stale reads overwrite other devices' changes
        persistenceManager.pullFromCloud()
        updateArticleReadStatesFromCloud()
        updateRedditPostReadStatesFromCloud()
    }

    private func handleRemoteCloudChange(_ change: CloudSyncManager.CloudSyncChange) {
        switch change {
        case .readArticles(let ids):
            persistenceManager.handleRemoteReadArticlesChange(ids)
            DispatchQueue.main.async { [weak self] in
                self?.updateArticleReadStatesFromCloud()
            }

        case .favoriteArticles(let ids):
            persistenceManager.handleRemoteFavoriteArticlesChange(ids)
            DispatchQueue.main.async { [weak self] in
                self?.updateArticleFavoriteStatesFromCloud()
            }

        case .readRedditPosts(let ids):
            persistenceManager.handleRemoteReadRedditPostsChange(ids)
            DispatchQueue.main.async { [weak self] in
                self?.updateRedditPostReadStatesFromCloud()
            }

        case .favoriteRedditPosts(let ids):
            persistenceManager.handleRemoteFavoriteRedditPostsChange(ids)
            DispatchQueue.main.async { [weak self] in
                self?.updateRedditPostFavoriteStatesFromCloud()
            }

        case .subscriptions(let subs):
            persistenceManager.handleRemoteSubscriptionsChange(subs)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.subscriptions = self.persistenceManager.loadSubscriptions()
                self.refreshAllFeeds()
            }
        }
    }

    private func updateArticleReadStatesFromCloud() {
        let totalArticles = feeds.flatMap { $0.articles }.count
        var changedCount = 0
        var sampleChanges: [(id: String, wasRead: Bool, nowRead: Bool)] = []

        for feedIndex in feeds.indices {
            for articleIndex in feeds[feedIndex].articles.indices {
                let article = feeds[feedIndex].articles[articleIndex]
                let id = article.id
                let wasRead = article.isRead
                let nowRead = persistenceManager.isArticleRead(article)
                if wasRead != nowRead {
                    changedCount += 1
                    if sampleChanges.count < 3 {
                        sampleChanges.append((id: String(id.prefix(50)), wasRead: wasRead, nowRead: nowRead))
                    }
                }
                feeds[feedIndex].articles[articleIndex].isRead = nowRead
            }
        }

        print("☁️ AppState: updateArticleReadStatesFromCloud - feeds=\(feeds.count), articles=\(totalArticles), changed=\(changedCount)")

        if changedCount > 0 {
            objectWillChange.send()
            readStateRevision &+= 1
            print("🧠 readStateRevision now \(readStateRevision) main=\(Thread.isMainThread) self=\(ObjectIdentifier(self))")

            // Force SwiftUI to detect the change by reassigning the array
            let updatedFeeds = feeds
            feeds = updatedFeeds
        }
        if !sampleChanges.isEmpty {
            for change in sampleChanges {
                print("   → '\(change.id)' wasRead=\(change.wasRead) → nowRead=\(change.nowRead)")
            }
        }
        if changedCount > 0 {
            scheduleUnreadCacheRebuild()
        }
    }

    private func updateArticleFavoriteStatesFromCloud() {
        for feedIndex in feeds.indices {
            for articleIndex in feeds[feedIndex].articles.indices {
                let id = feeds[feedIndex].articles[articleIndex].id
                feeds[feedIndex].articles[articleIndex].isFavorite = persistenceManager.isArticleFavorite(id)
            }
        }
    }

    /// Sync Reddit read states from persistence to in-memory array (no network call)
    /// Call this when sidebar appears to ensure badge counts are accurate
    func syncRedditReadStatesFromPersistence() {
        updateRedditPostReadStatesFromCloud()
    }

    /// Sync both RSS + Reddit read states from persistence to in-memory arrays.
    /// This is a local reconciliation pass (no network call).
    func syncAllReadStatesFromPersistence() {
        updateArticleReadStatesFromCloud()
        updateRedditPostReadStatesFromCloud()
        scheduleUnreadCacheRebuild()
    }

    private func subscriptionCacheKey(url: String, type: SubscriptionType) -> String {
        "\(type.rawValue)|\(Subscription.canonicalURL(url, type: type))"
    }

    private func rebuildUnreadCachesFromInMemoryFlags() {
        var unreadByKey: [String: Int] = [:]
        var totalArticles = 0
        var totalReddit = 0

        for feed in feeds {
            let unread = feed.articles.reduce(into: 0) { count, article in
                if !article.isRead {
                    count += 1
                }
            }
            totalArticles += unread
            let key = subscriptionCacheKey(url: feed.url, type: .rss)
            unreadByKey[key, default: 0] += unread
        }

        for feed in redditFeeds {
            let unread = feed.posts.reduce(into: 0) { count, post in
                if !post.isRead {
                    count += 1
                }
            }
            totalReddit += unread
            let key = subscriptionCacheKey(url: feed.subreddit, type: .reddit)
            unreadByKey[key, default: 0] += unread
        }

        unreadCountBySubscriptionKey = unreadByKey
        unreadAllArticles = totalArticles
        unreadAllReddit = totalReddit
    }

    private func scheduleUnreadCacheRebuild() {
        guard !isUnreadCacheRebuildScheduled else { return }
        isUnreadCacheRebuildScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isUnreadCacheRebuildScheduled = false
            self.rebuildUnreadCachesFromInMemoryFlags()
        }
    }

    func unreadCount(for subscription: Subscription) -> Int {
        unreadCountBySubscriptionKey[subscription.canonicalKey] ?? 0
    }

    func unreadAllArticlesCount() -> Int {
        unreadAllArticles
    }

    func unreadAllRedditCount() -> Int {
        unreadAllReddit
    }

    private func updateRedditPostReadStatesFromCloud() {
        var changedCount = 0
        var unreadBySubreddit: [String: Int] = [:]

        for feedIndex in redditFeeds.indices {
            let subreddit = redditFeeds[feedIndex].subreddit
            var unreadInFeed = 0

            for postIndex in redditFeeds[feedIndex].posts.indices {
                let post = redditFeeds[feedIndex].posts[postIndex]
                let wasRead = post.isRead
                let nowRead = persistenceManager.isRedditPostRead(post)
                if wasRead != nowRead {
                    changedCount += 1
                }
                redditFeeds[feedIndex].posts[postIndex].isRead = nowRead

                if !nowRead {
                    unreadInFeed += 1
                }
            }

            if unreadInFeed > 0 {
                unreadBySubreddit[subreddit] = unreadInFeed
            }
        }

        let totalPosts = redditFeeds.flatMap { $0.posts }.count
        let totalUnread = unreadBySubreddit.values.reduce(0, +)
        print("☁️ AppState: syncRedditReadStates - totalPosts=\(totalPosts), totalUnread=\(totalUnread), changed=\(changedCount)")
        print("📊 Unread by subreddit: \(unreadBySubreddit.isEmpty ? "[all read]" : "\(unreadBySubreddit)")")

        if changedCount > 0 {
            objectWillChange.send()
            readStateRevision &+= 1
            print("🧠 readStateRevision now \(readStateRevision) main=\(Thread.isMainThread) self=\(ObjectIdentifier(self)) [Reddit changed=\(changedCount)]")

            // Force SwiftUI to detect the change by reassigning the array
            let updatedFeeds = redditFeeds
            redditFeeds = updatedFeeds
        }
        if changedCount > 0 {
            scheduleUnreadCacheRebuild()
        }
    }

    private func updateRedditPostFavoriteStatesFromCloud() {
        for feedIndex in redditFeeds.indices {
            for postIndex in redditFeeds[feedIndex].posts.indices {
                let id = redditFeeds[feedIndex].posts[postIndex].id
                redditFeeds[feedIndex].posts[postIndex].isFavorite = persistenceManager.isRedditPostFavorite(id)
            }
        }
    }

    // Manual cloud refresh (pull latest from iCloud and reapply)
    func manualCloudRefresh() {
        if manualCloudSyncState == .syncing {
            return
        }

        manualCloudSyncState = .syncing
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
                self.persistenceManager.manualPullFromCloud()
                self.subscriptions = self.persistenceManager.loadSubscriptions()
                self.updateArticleReadStatesFromCloud()
                self.updateArticleFavoriteStatesFromCloud()
                self.updateRedditPostReadStatesFromCloud()
                self.updateRedditPostFavoriteStatesFromCloud()
                self.refreshAllFeeds()

                if index == finalIndex {
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

    // MARK: - Feed Management
    func refreshAllFeeds() {
        isLoading = true
        let group = DispatchGroup()

        // Refresh RSS feeds
        for subscription in subscriptions where subscription.type == .rss {
            group.enter()
                feedService.fetchFeed(url: subscription.url)
                    .receive(on: RunLoop.main)
                    .sink(receiveCompletion: { _ in
                    group.leave()
                }, receiveValue: { [weak self] feed in
                    // Apply read and favorite status from persistence
                    var processedFeed = feed
                    for i in 0..<processedFeed.articles.count {
                        let article = processedFeed.articles[i]
                        processedFeed.articles[i].isRead = self?.persistenceManager.isArticleRead(article) ?? false
                        processedFeed.articles[i].isFavorite = self?.persistenceManager.isArticleFavorite(article.id) ?? false
                    }
                    
                    // Defer to avoid modifying during view updates
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { [weak self] in
                        if let index = self?.feeds.firstIndex(where: { $0.url == subscription.url }) {
                            self?.feeds[index] = processedFeed
                        } else {
                            self?.feeds.append(processedFeed)
                        }
                    }
                })
                .store(in: &cancellables)
        }

        // Refresh Reddit feeds
        refreshRedditFeeds(in: group)

        group.notify(queue: .main) { [weak self] in
            guard let self else { return }
            self.isLoading = false
            self.backfillReadTokensForVisibleReadItems()
            self.scheduleUnreadCacheRebuild()
        }
    }

    private func backfillReadTokensForVisibleReadItems() {
        let readArticles = feeds.flatMap(\.articles).filter(\.isRead)
        let readPosts = redditFeeds.flatMap(\.posts).filter(\.isRead)
        guard !readArticles.isEmpty || !readPosts.isEmpty else { return }

        let repair = persistenceManager.backfillReadTokensIfNeeded(articles: readArticles, posts: readPosts)
        if repair.addedArticleTokens > 0 || repair.addedRedditTokens > 0 {
            print("🧩 AppState: Backfilled read tokens - articles +\(repair.addedArticleTokens), reddit +\(repair.addedRedditTokens)")
        }
    }
    
    private func updateRedditRateLimitStatus(for subreddit: String, using status: RedditRateLimitStatus?) {
        guard let status = status else {
            redditStatusMessages.removeValue(forKey: subreddit)
            aggregatedRedditStatusMessage = redditStatusMessages.values.sorted(by: { $0.capturedAt > $1.capturedAt }).first
            return
        }

        guard status.statusCode >= 400 else {
            redditStatusMessages.removeValue(forKey: subreddit)
            aggregatedRedditStatusMessage = redditStatusMessages.values.sorted(by: { $0.capturedAt > $1.capturedAt }).first
            return
        }

        var messageParts: [String] = []

        func appendIfUnique(_ text: String?) {
            guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return }
            if !messageParts.contains(where: { $0.caseInsensitiveCompare(text) == .orderedSame }) {
                messageParts.append(text)
            }
        }

        switch status.statusCode {
        case 401:
            appendIfUnique("Reddit authentication expired. Please reconnect.")
        case 403:
            appendIfUnique("Reddit denied access to this subreddit.")
        case 404:
            appendIfUnique("Subreddit not reachable right now.")
        default:
            break
        }

        if status.statusCode == 429 {
            appendIfUnique(status.message ?? "Reddit temporarily rate limited this subreddit.")

            if let remaining = status.remaining {
                appendIfUnique("Remaining quota: \(Int(remaining.rounded()))")
            }

            if let resetDate = status.approximateResetDate {
                let seconds = max(Int(resetDate.timeIntervalSinceNow.rounded()), 0)
                if seconds > 0 {
                    appendIfUnique("Resets in ~\(seconds)s")
                }
            }
        } else {
            appendIfUnique(status.message)

            if messageParts.isEmpty {
                let description = HTTPURLResponse.localizedString(forStatusCode: status.statusCode)
                if !description.isEmpty {
                    appendIfUnique(description.capitalized)
                }
            }
        }

        appendIfUnique("Code: \(status.statusCode)")

        let text = "r/\(subreddit): " + messageParts.joined(separator: " • ")
        let message = RedditStatusMessage(
            subreddit: subreddit,
            text: text,
            statusCode: status.statusCode,
            resetDate: status.approximateResetDate,
            remaining: status.remaining,
            capturedAt: status.capturedAt
        )
        redditStatusMessages[subreddit] = message

        aggregatedRedditStatusMessage = redditStatusMessages.values.sorted(by: { $0.capturedAt > $1.capturedAt }).first
    }

    private func redditFeedCacheKey(subreddit: String, sortOption: RedditService.SortOption) -> String {
        "\(subreddit.lowercased())|\(sortOption.rawValue)"
    }

    private func cacheRedditFeed(_ redditFeed: RedditFeed, sortOption: RedditService.SortOption) {
        redditFeedSortCache[redditFeedCacheKey(subreddit: redditFeed.subreddit, sortOption: sortOption)] = redditFeed
    }

    private func hydratedCachedRedditFeed(subreddit: String, sortOption: RedditService.SortOption) -> RedditFeed? {
        guard let cachedFeed = redditFeedSortCache[redditFeedCacheKey(subreddit: subreddit, sortOption: sortOption)] else {
            return nil
        }

        return hydrateRedditFeed(cachedFeed, sortOption: sortOption)
    }

    // Specific function to refresh just Reddit feeds
    func refreshRedditFeeds(specificSubreddit: String? = nil, in existingGroup: DispatchGroup? = nil) {
        let group = existingGroup ?? DispatchGroup()
        let requestedSortOption = redditSortOption
        
        if existingGroup == nil {
            isLoading = true
        }
        
        // Log the refresh operation
        if let specificSubreddit = specificSubreddit {
            print("📱 AppState: Refreshing specific Reddit feed: r/\(specificSubreddit) with sort option: \(requestedSortOption.rawValue)")
        } else {
            print("📱 AppState: Refreshing ALL Reddit feeds with sort option: \(requestedSortOption.rawValue)")
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
            if let cachedFeed = hydratedCachedRedditFeed(subreddit: subscription.url, sortOption: requestedSortOption) {
                print("📱 AppState: Showing cached \(requestedSortOption.rawValue) feed for r/\(subscription.url) while refreshing")
                updateVisibleRedditFeedIfNeeded(cachedFeed, sortOption: requestedSortOption)
            }

            group.enter()
            
            // Create a temporary feed object with loading state if needed
            // Defer the append to avoid modifying during view updates
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { [weak self] in
                guard let self = self else { return }
                if self.redditFeeds.firstIndex(where: { $0.subreddit == subscription.url }) == nil {
                    // Add a temporary placeholder feed to show loading state
                    let tempFeed = RedditFeed(subreddit: subscription.url, displayName: "Loading...", posts: [])
                    self.redditFeeds.append(tempFeed)
                    print("📱 AppState: Created temporary feed for r/\(subscription.url)")
                }
                if self.redditSortOption == requestedSortOption {
                    self.redditFeedSortState[subscription.url] = requestedSortOption
                }
            }
            
            redditService.fetchSubreddit(subreddit: subscription.url, sortOption: requestedSortOption)
                .receive(on: RunLoop.main)
                .sink(receiveCompletion: { completion in
                    group.leave()
                }, receiveValue: { [weak self] redditFeed in
                    guard let self = self else { return }
                    
                    let rateStatus = self.redditService.latestFeedRateLimitStatus(for: subscription.url)
                    self.updateRedditRateLimitStatus(for: subscription.url, using: rateStatus)

                    let processedFeed = self.hydrateRedditFeed(redditFeed, sortOption: requestedSortOption)
                    self.cacheRedditFeed(processedFeed, sortOption: requestedSortOption)

                    print("📱 AppState: Received feed for r/\(subscription.url) with \(processedFeed.posts.count) posts")

                    guard requestedSortOption == self.redditSortOption else {
                        print("📱 AppState: Cached stale \(requestedSortOption.rawValue) response for r/\(subscription.url); visible sort is now \(self.redditSortOption.rawValue)")
                        return
                    }

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
                            // Update the feed directly without replacing the entire array
                            self.redditFeeds[index] = processedFeed
                            print("📱 AppState: Feed array updated with new content, sort option: \(requestedSortOption.rawValue)")
                        }
                    } else {
                        print("📱 AppState: Adding new feed to collection")
                        self.redditFeeds.append(processedFeed)
                    }
                    self.redditFeedSortState[subscription.url] = requestedSortOption
                    
                    // Force UI update by re-publishing the current selected Reddit post if it's from this feed
                    if let selectedPost = self.selectedRedditPost, selectedPost.subreddit == subscription.url {
                        if let updatedPost = processedFeed.posts.first(where: { $0.id == selectedPost.id }) {
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
                self?.isLoading = false
                self?.scheduleUnreadCacheRebuild()
            }
        }
    }

    func ensureRedditFeedMatchesCurrentSort(for subreddit: String) {
        let desired = redditSortOption
        let current = redditFeedSortState[subreddit]
        guard current != desired else { return }
        guard !isLoading else {
            print("📱 AppState: Already loading, skipping ensure for r/\(subreddit)")
            return
        }

        let currentLabel = current?.rawValue ?? "unknown"
        print("📱 AppState: Sort mismatch for r/\(subreddit) (current: \(currentLabel), desired: \(desired.rawValue)). Refreshing feed.")
        refreshRedditFeeds(specificSubreddit: subreddit)
    }

    func ensureAllRedditFeedsMatchCurrentSort() {
        let desired = redditSortOption
        let mismatched = redditFeeds.filter { redditFeedSortState[$0.subreddit] != desired }
        guard !mismatched.isEmpty else { return }
        guard !isLoading else {
            print("📱 AppState: Already loading, skipping global ensure for Reddit feeds")
            return
        }

        print("📱 AppState: Refreshing \(mismatched.count) Reddit feeds to match sort option \(desired.rawValue)")
        refreshRedditFeeds()
    }

    func clearRedditStatusMessages() {
        redditStatusMessages.removeAll()
        aggregatedRedditStatusMessage = nil
    }

    // MARK: - Subscription Management
    func addSubscription(title: String, url: String, type: SubscriptionType) {
        let subscription = Subscription(title: title, url: url, type: type)
        subscriptions.append(subscription)
        persistenceManager.saveSubscriptions(subscriptions)
        scheduleUnreadCacheRebuild()

        // Fetch the new feed
        if type == .rss {
            feedService.fetchFeed(url: url)
                .receive(on: RunLoop.main)
                .sink(receiveCompletion: { _ in },
                      receiveValue: { [weak self] feed in
                    // Apply read and favorite status for new subscriptions too
                    var processedFeed = feed
                    for i in 0..<processedFeed.articles.count {
                        let article = processedFeed.articles[i]
                        processedFeed.articles[i].isRead = self?.persistenceManager.isArticleRead(article) ?? false
                        processedFeed.articles[i].isFavorite = self?.persistenceManager.isArticleFavorite(article.id) ?? false
                    }
                    self?.feeds.append(processedFeed)
                    self?.scheduleUnreadCacheRebuild()
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
                        let post = processedFeed.posts[i]
                        processedFeed.posts[i].isRead = self.persistenceManager.isRedditPostRead(post)
                        processedFeed.posts[i].isFavorite = self.persistenceManager.isRedditPostFavorite(post.id)
                    }
                    // Sort posts: stickied first, then by date for "New" sort
                    if self.redditSortOption == .new {
                        let stickied = processedFeed.posts.filter { $0.isStickied }
                        let nonStickied = processedFeed.posts.filter { !$0.isStickied }
                            .sorted { $0.publishDate > $1.publishDate }
                        processedFeed.posts = stickied + nonStickied
                    }
                    self.redditFeeds.append(processedFeed)
                    self.scheduleUnreadCacheRebuild()
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
        scheduleUnreadCacheRebuild()
    }

    // MARK: - Article Management
    func markArticleAsRead(_ article: Article) {
        if let feedIndex = feeds.firstIndex(where: { $0.url == article.feedURL }),
           let articleIndex = feeds[feedIndex].articles.firstIndex(where: { $0.id == article.id }) {
            feeds[feedIndex].articles[articleIndex].isRead = true
            persistenceManager.markArticleAsRead(feeds[feedIndex].articles[articleIndex])
            scheduleUnreadCacheRebuild()
            
            // Ensure the navigation state is consistent
            if selectedArticle?.id == article.id {
                // Use the consistent setter function
                setSelectedArticle(feeds[feedIndex].articles[articleIndex])
            }
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
        
        // Create a customized prompt for article summarization
        let articlePrompt = geminiArticleSummaryPrompt(for: article)

        summaryService.summarizeText(article.content, customPrompt: articlePrompt)
            .receive(on: RunLoop.main)
            .sink { [weak self] (summary: String) in
                guard let self = self else { return }
                
                // Defer to avoid modifying during view updates
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { [weak self] in
                    guard let self = self else { return }
                    if let feedIndex = self.feeds.firstIndex(where: { $0.url == article.feedURL }),
                       let articleIndex = self.feeds[feedIndex].articles.firstIndex(where: { $0.id == article.id }) {
                        
                        // First, create a mutable copy of the article to update
                        var articleToUpdate = self.feeds[feedIndex].articles[articleIndex]
                        
                        // Update the article with a markdown-artifact-free summary
                        let cleanedSummary = self.cleanMarkdownArtifactsForDisplay(summary)
                        articleToUpdate.summary = cleanedSummary
                        
                        // Update the article in the feeds array
                        self.feeds[feedIndex].articles[articleIndex] = articleToUpdate
                        
                        // If this is the currently selected article, update the selection
                        if self.selectedArticle?.id == article.id {
                            self.selectedArticle = articleToUpdate
                            print("📱 AppState: Updated article summary for article ID: \(article.id)")
                        }
                    }
                    self.isLoading = false
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Reddit Post Management
    func markRedditPostAsRead(_ post: RedditPost) {
        if let feedIndex = redditFeeds.firstIndex(where: { $0.subreddit == post.subreddit }),
           let postIndex = redditFeeds[feedIndex].posts.firstIndex(where: { $0.id == post.id }) {
            redditFeeds[feedIndex].posts[postIndex].isRead = true
            persistenceManager.markRedditPostAsRead(redditFeeds[feedIndex].posts[postIndex])
            scheduleUnreadCacheRebuild()
            
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
        
        // Extract all comment texts recursively
        let commentTexts = comments.flatMap { extractAllCommentTexts(from: $0) }
        let combinedComments = commentTexts.joined(separator: "\n\n")
        
        // Create a comprehensive prompt for Reddit post summarization
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
            .sink { [weak self] (summary: String) in
                guard let self = self else { return }
                
                // Defer to avoid modifying during view updates
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { [weak self] in
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
                    self.isLoading = false
                }
            }
            .store(in: &cancellables)
    }

    private func presentWebAIHandoff(prompt: String, title: String) {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            showWebAIStatus("Nothing to send to \(settings.selectedWebAIProvider.displayName) yet.")
            return
        }

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
    }

    func openWebAILoginSession(for provider: WebAIProvider) {
        let request = WebAIHandoffRequest(
            provider: provider,
            title: "\(provider.displayName) Login",
            prompt: "",
            responseFormat: .plainText,
            shouldAutoCapture: false,
            shouldStartMinimized: false
        )
        isWebAIHandoffMinimized = false
        activeWebAIHandoffRequest = request
    }

    func resetWebAISession(for provider: WebAIProvider) {
        WebAISessionManager.shared.resetSession(for: provider) { [weak self] message in
            DispatchQueue.main.async {
                self?.showWebAIStatus(message)
            }
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

        let resolvedProvider = provider ?? settings.selectedWebAIProvider
        let request = WebAIHandoffRequest(
            provider: resolvedProvider,
            title: title,
            prompt: trimmed,
            responseFormat: responseFormat,
            shouldAutoCapture: true,
            shouldStartMinimized: true
        )

        pendingWebAIRequests[request.id] = PendingWebAIRequest(
            title: title,
            provider: resolvedProvider,
            prompt: trimmed,
            responseFormat: responseFormat,
            onSuccess: onSuccess,
            onFailure: onFailure
        )
        if activeWebAIHandoffRequest == nil && !isWebAIBatchHandoffInProgress {
            isWebAIHandoffMinimized = request.shouldStartMinimized
        }
        activeWebAIHandoffRequest = request
        return request.id
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

    private func normalizedWebAIComparisonText(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private func webAIProbeMatchesPrompt(_ probe: String, prompt: String) -> Bool {
        probe.count >= 120 && prompt.contains(probe)
    }

    private func isWebAIPromptEchoResponse(_ response: String, prompt: String) -> Bool {
        let normalizedResponse = normalizedWebAIComparisonText(response)
        let normalizedPrompt = normalizedWebAIComparisonText(prompt)
        guard !normalizedResponse.isEmpty, !normalizedPrompt.isEmpty else { return false }

        if normalizedResponse == normalizedPrompt { return true }
        if normalizedResponse.count > 120, normalizedPrompt.contains(normalizedResponse) { return true }

        let responsePrefix = String(normalizedResponse.prefix(min(500, normalizedResponse.count)))
        if webAIProbeMatchesPrompt(responsePrefix, prompt: normalizedPrompt) { return true }

        let promptPrefix = String(normalizedPrompt.prefix(min(500, normalizedPrompt.count)))
        if promptPrefix.count >= 120, normalizedResponse.hasPrefix(promptPrefix) { return true }

        guard normalizedResponse.count >= 400 else { return false }

        let probeLength = min(260, normalizedResponse.count)
        let prefix = String(normalizedResponse.prefix(probeLength))
        let suffix = String(normalizedResponse.suffix(probeLength))
        let midOffset = max(0, (normalizedResponse.count - probeLength) / 2)
        let midStart = normalizedResponse.index(normalizedResponse.startIndex, offsetBy: midOffset)
        let midEnd = normalizedResponse.index(midStart, offsetBy: probeLength, limitedBy: normalizedResponse.endIndex) ?? normalizedResponse.endIndex
        let middle = String(normalizedResponse[midStart..<midEnd])

        let matchingProbeCount = [prefix, middle, suffix].filter {
            webAIProbeMatchesPrompt($0, prompt: normalizedPrompt)
        }.count
        return matchingProbeCount >= 2
    }

    func handleCapturedWebAIResponse(requestID: UUID, response: String) {
        guard let pending = pendingWebAIRequests.removeValue(forKey: requestID) else { return }

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

        guard !isWebAIPromptEchoResponse(cleaned, prompt: pending.prompt) else {
            let message = "\(pending.provider.displayName) captured the submitted prompt instead of the answer. Wait for the response to finish, then try again."
            showWebAIStatus(message)
            pending.onFailure(message)
            return
        }

        pending.onSuccess(cleaned)
    }

    func handleWebAIRequestFailure(requestID: UUID, message: String, dismissPanel: Bool = false) {
        guard let pending = pendingWebAIRequests.removeValue(forKey: requestID) else { return }

        if activeWebAIHandoffRequest?.id == requestID {
            isWebAIHandoffMinimized = false
        }

        if dismissPanel, activeWebAIHandoffRequest?.id == requestID {
            activeWebAIHandoffRequest = nil
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
        await MainActor.run {
            recordSummarizeThroughput(text: output, elapsed: elapsed)
        }
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
        taskName: String = "Apple PCC",
        isQA: Bool = false
    ) async throws -> String {
        let start = Date()
        let output = try await summaryService.generateContentWithPCCGateway(prompt: prompt, settings: settings)
        let elapsed = Date().timeIntervalSince(start)
        await recordPCCGatewayThroughput(text: output, elapsed: elapsed, isQA: isQA)
        print("✅ AppState: Apple PCC fm CLI succeeded for \(taskName)")
        return output
    }

    func performPCCGatewaySummaryPublic(
        prompt: String,
        taskName: String = "Apple PCC",
        completion: @escaping (String) -> Void
    ) {
        isLoading = true
        Task(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            do {
                let output = try await self.performPCCGatewayRequestAsync(prompt: prompt, taskName: taskName)
                await MainActor.run {
                    self.isLoading = false
                    completion(output)
                }
            } catch {
                await MainActor.run {
                    self.isLoading = false
                    completion("Apple PCC error: \(error.localizedDescription)")
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
        let htmlContent = article.content ?? ""
        return htmlContent
            .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
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

    private func normalizedCommentBodyForSummary(_ text: String, maxCharacters: Int = 280) -> String {
        normalizedSummarySourceText(
            text.replacingOccurrences(of: "\n", with: " "),
            maxCharacters: maxCharacters
        )
    }

    private func flattenedCommentBodiesForSummary(
        _ comments: [RedditCommentModel],
        depth: Int = 0
    ) -> [String] {
        var bodies: [String] = []

        for comment in comments {
            let body = normalizedCommentBodyForSummary(comment.body)
            if !body.isEmpty {
                bodies.append(body)
            }

            if depth < 8, !comment.replies.isEmpty {
                bodies.append(contentsOf: flattenedCommentBodiesForSummary(comment.replies, depth: depth + 1))
            }
        }

        return bodies
    }

    private func redditSummarySourceText(post: RedditPost, comments: [RedditCommentModel]) -> String {
        let commentTexts = Array(flattenedCommentBodiesForSummary(comments).prefix(18))
        if commentTexts.isEmpty {
            return normalizedSummarySourceText(post.content, maxCharacters: 6_000)
        }
        let mergedComments = commentTexts.joined(separator: "\n\n")

        return """
        Title: \(post.title)
        Post:
        \(normalizedSummarySourceText(post.content, maxCharacters: 3_000))

        Top comments:
        \(mergedComments)
        """
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
        "Provide a brief 3-4 sentence summary of this article. Include only the main point and most important conclusion. Keep it under 100 words. Output plain text only (no markdown symbols like #, *, _, or `):\n\n\(article.content)"
    }

    func redditPostSummaryPrompt(post: RedditPost, comments: [RedditCommentModel] = []) -> String {
        let sourceText = redditSummarySourceText(post: post, comments: comments)
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

    func redditQAPrompt(post: RedditPost, comments: [RedditCommentModel], question: String, preferCompleteAnswer: Bool = false) -> String {
        strictQAPrompt(
            sourceLabel: comments.isEmpty ? "Reddit post" : "Reddit post and comments",
            sourceText: redditSummarySourceText(post: post, comments: comments),
            question: question,
            preferCompleteAnswer: preferCompleteAnswer
        )
    }

    func commentSummaryPrompt(comments: [RedditCommentModel]) -> String {
        let combinedComments = Array(flattenedCommentBodiesForSummary(comments).prefix(24))
            .joined(separator: "\n\n")

        return strictSummaryPrompt(
            task: "Summarize the main themes in these comments. Combine duplicate opinions into a single point, mention the dominant mood, and do not quote or repeat the comments verbatim.",
            sourceLabel: "Comments",
            sourceText: combinedComments,
            wordLimit: 100
        )
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
        guard let result = decodeGlobalSummaryResult() else {
            showWebAIStatus("Generate a summary overview first, then send it to \(settings.selectedWebAIProvider.displayName).")
            return
        }

        presentWebAIHandoff(prompt: buildAggregatePrompt(from: result), title: "Global Summary Overview")
    }

    func requestWebCombinedGlobalSummary(force: Bool = true) {
        let sourceFingerprint = globalSummaryJSON
        let existingSummary = aggregateSummaryText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard force || existingSummary.isEmpty else { return }

        guard let result = decodeGlobalSummaryResult(), !result.summaries.isEmpty else {
            aggregateSummaryError = "No summary data available to combine."
            aggregateSummaryText = nil
            aggregateSummaryProviderName = nil
            aggregateSummarySourceFingerprint = nil
            isGeneratingAggregateSummary = false
            showWebAIStatus("Generate a summary overview first, then send it to \(settings.selectedWebAIProvider.displayName).")
            return
        }

        isGeneratingAggregateSummary = true
        aggregateSummaryError = nil
        aggregateSummaryText = nil
        aggregateSummaryProviderName = nil
        aggregateSummarySourceFingerprint = nil
        isWebAIHandoffMinimized = true
        showGlobalSummary = true

        performWebAIRequest(
            title: result.source == "reddit" ? "Combined Reddit Summary" : "Combined Article Summary",
            prompt: buildAggregatePrompt(from: result),
            onSuccess: { [weak self] summary in
                guard let self else { return }
                let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
                let lowercased = trimmed.lowercased()
                self.isGeneratingAggregateSummary = false

                if trimmed.isEmpty || lowercased.hasPrefix("error") || lowercased.contains("api key not configured") {
                    self.aggregateSummaryError = trimmed.isEmpty ? "Failed to generate combined summary." : trimmed
                    self.aggregateSummaryText = nil
                    self.aggregateSummaryProviderName = nil
                    self.aggregateSummarySourceFingerprint = nil
                } else {
                    self.aggregateSummaryText = self.formatLLMAnswer(trimmed)
                    self.aggregateSummaryProviderName = self.settings.selectedWebAIProvider.displayName
                    self.aggregateSummarySourceFingerprint = sourceFingerprint
                    self.aggregateSummaryError = nil
                    self.showGlobalSummary = true
                    self.hasCachedSummary = true
                }
            },
            onFailure: { [weak self] message in
                guard let self else { return }
                self.isGeneratingAggregateSummary = false
                self.aggregateSummaryError = message
                self.aggregateSummaryText = nil
                self.aggregateSummaryProviderName = nil
                self.aggregateSummarySourceFingerprint = nil
                self.showGlobalSummary = true
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
            if !globalSummaryComments.isEmpty {
                let usableContexts = globalSummaryComments.filter { !$0.1.isEmpty || !self.sanitizedSnippet(from: $0.0.content, limit: 800).isEmpty }
                guard !usableContexts.isEmpty else {
                    showWebAIStatus("Unable to load Reddit comments for this summary.")
                    return
                }
                let prompt = buildGlobalRedditQuestionPrompt(contexts: usableContexts, question: trimmed)
                presentWebAIHandoff(prompt: prompt, title: "Global Summary Q&A")
            } else {
                let topComments = topCommentsCount(for: lastGlobalSummaryContext) ?? 3
                fetchCommentsForGlobalSummary(posts: posts, topComments: topComments) { [weak self] contexts in
                    guard let self else { return }
                    self.globalSummaryComments = contexts
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
        guard lastGlobalSummaryContext != nil else {
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
            if !globalSummaryComments.isEmpty {
                let usableContexts = globalSummaryComments.filter { !$0.1.isEmpty || !self.sanitizedSnippet(from: $0.0.content, limit: 800).isEmpty }
                guard !usableContexts.isEmpty else {
                    completion("Unable to load Reddit comments for this summary. Please try again later.")
                    return
                }
                let prompt = buildGlobalRedditQuestionPrompt(contexts: usableContexts, question: trimmed)
                executeWebGlobalQAPrompt(prompt: prompt, completion: completion)
            } else {
                let topComments = topCommentsCount(for: lastGlobalSummaryContext) ?? 3
                fetchCommentsForGlobalSummary(posts: posts, topComments: topComments) { [weak self] contexts in
                    guard let self else { return }
                    self.globalSummaryComments = contexts
                    let usableContexts = contexts.filter { !$0.1.isEmpty || !self.sanitizedSnippet(from: $0.0.content, limit: 800).isEmpty }
                    guard !usableContexts.isEmpty else {
                        completion("Unable to load Reddit comments for this summary. Please try again later.")
                        return
                    }
                    let prompt = self.buildGlobalRedditQuestionPrompt(contexts: usableContexts, question: trimmed)
                    self.executeWebGlobalQAPrompt(prompt: prompt, completion: completion)
                }
            }
            return
        }

        completion("No summary data is available for Q&A at the moment. Please generate a summary first.")
    }

    private func executeWebGlobalQAPrompt(prompt: String, completion: @escaping (String) -> Void) {
        let deliver: (String) -> Void = { [weak self] rawAnswer in
            guard let self else {
                completion(rawAnswer)
                return
            }
            completion(self.cleanMarkdownArtifactsForDisplay(rawAnswer))
        }

        performWebAIRequest(
            title: "Global Summary Q&A",
            prompt: prompt,
            onSuccess: deliver,
            onFailure: { deliver($0) }
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
        let sourceText = cleanedArticleContent(article)
        performWebAIRequest(
            title: "Article Summary",
            prompt: articleSummaryPrompt(for: article),
            onSuccess: { [weak self] summary in
                guard let self else { return }
                let constrained = self.enforceArticleSummaryLength(
                    self.cleanMarkdownArtifactsForDisplay(summary),
                    sourceText: sourceText
                )
                self.updateArticleSummaryFromCloud(article, summary: constrained)
                self.isLoading = false
            },
            onFailure: { [weak self] _ in
                self?.isLoading = false
            }
        )
    }

    func requestWebSummary(for post: RedditPost, comments: [RedditCommentModel] = []) {
        isLoading = true
        performWebAIRequest(
            title: "Reddit Summary",
            prompt: redditPostSummaryPrompt(post: post, comments: comments),
            onSuccess: { [weak self] summary in
                self?.updateRedditPostSummaryFromCloud(
                    post,
                    summary: self?.cleanMarkdownArtifactsForDisplay(summary) ?? summary
                )
                self?.isLoading = false
            },
            onFailure: { [weak self] _ in
                self?.isLoading = false
            }
        )
    }

    func askQuestionAboutSelection(
        prompt: String,
        completion: @escaping (String) -> Void
    ) {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            completion("No selected text was provided.")
            return
        }

        let deliver: (String) -> Void = { [weak self] rawAnswer in
            guard let self else {
                completion(rawAnswer)
                return
            }
            completion(self.cleanMarkdownArtifactsForDisplay(rawAnswer))
        }

        switch settings.selectedSummaryProvider {
        case .appleLocal:
            performLocalWithGeminiFallback(prompt: trimmed, taskName: "Ask AI", completion: deliver)
        case .appleCloud:
            launchCloudRequest(for: trimmed, type: .globalSummaryQA, completion: deliver)
        case .applePCCGateway:
            Task(priority: .userInitiated) { [weak self] in
                guard let self else { return }
                do {
                    let answer = try await self.performPCCGatewayRequestAsync(
                        prompt: trimmed,
                        taskName: "Ask AI",
                        isQA: true
                    )
                    await MainActor.run { deliver(answer) }
                } catch {
                    await MainActor.run {
                        deliver("Apple PCC error: \(error.localizedDescription)")
                    }
                }
            }
        case .mlxLocal, .coreAIMLXLocal:
            performMLXLocalSummary(prompt: trimmed, completion: deliver)
        case .webAI:
            performExplicitWebAIQuestion(title: "Ask AI", prompt: trimmed, completion: deliver)
        case .summarizeDaemon:
            Task(priority: .userInitiated) { [weak self] in
                guard let self else { return }
                do {
                    let start = Date()
                    let answer = try await self.summaryService.generateContentWithSummarize(prompt: trimmed, settings: self.settings)
                    let elapsed = Date().timeIntervalSince(start)
                    await MainActor.run {
                        self.recordSummarizeThroughput(text: answer, elapsed: elapsed, isQA: true)
                        deliver(answer)
                    }
                } catch {
                    await MainActor.run {
                        deliver("Codex / Summarize error: \(error.localizedDescription)")
                    }
                }
            }
        case .gemini:
            summaryService.summarizeText("", customPrompt: trimmed)
                .receive(on: RunLoop.main)
                .sink { answer in
                    deliver(answer)
                }
                .store(in: &cancellables)
        }
    }

    func askWebQuestionAboutSelection(
        prompt: String,
        title: String = "Ask AI Web",
        completion: @escaping (String) -> Void
    ) {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            completion("No selected text was provided.")
            return
        }

        performExplicitWebAIQuestion(
            title: title,
            prompt: trimmed,
            completion: completion
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

    private func enforceArticleSummaryLength(_ summary: String, sourceText: String) -> String {
        let cleaned = cleanMarkdownArtifactsForDisplay(summary)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !cleaned.isEmpty else { return cleaned }

        let words = cleaned.split(whereSeparator: \.isWhitespace)
        let sourceWordCount = max(sourceText.split(whereSeparator: \.isWhitespace).count, 1)
        let maxWords = min(140, max(40, sourceWordCount / 4))

        guard words.count > maxWords else { return cleaned }

        return words.prefix(maxWords).joined(separator: " ")
    }
    
    // MARK: - Unified Summary Request Handler
    func requestSummary(for article: Article? = nil, redditPost: RedditPost? = nil, redditComments: [RedditCommentModel] = []) {
        if article != nil || redditPost != nil {
            isLoading = true
        }

        if settings.selectedSummaryProvider == .webAI {
            if let article = article {
                let sourceText = cleanedArticleContent(article)
                performWebAIRequest(
                    title: "Article Summary",
                    prompt: articleSummaryPrompt(for: article),
                    onSuccess: { [weak self] summary in
                        guard let self else { return }
                        let constrained = self.enforceArticleSummaryLength(
                            self.cleanMarkdownArtifactsForDisplay(summary),
                            sourceText: sourceText
                        )
                        self.updateArticleSummaryFromCloud(article, summary: constrained)
                        self.isLoading = false
                    },
                    onFailure: { [weak self] _ in
                        self?.isLoading = false
                    }
                )
            } else if let post = redditPost {
                performWebAIRequest(
                    title: "Reddit Summary",
                    prompt: redditPostSummaryPrompt(post: post, comments: redditComments),
                    onSuccess: { [weak self] summary in
                        self?.updateRedditPostSummaryFromCloud(
                            post,
                            summary: self?.cleanMarkdownArtifactsForDisplay(summary) ?? summary
                        )
                        self?.isLoading = false
                    },
                    onFailure: { [weak self] _ in
                        self?.isLoading = false
                    }
                )
            } else {
                isLoading = false
            }
            return
        }

        if settings.selectedSummaryProvider == .summarizeDaemon {
            let prompt: String
            let taskName: String
            if let article = article {
                prompt = articleSummaryPrompt(for: article)
                taskName = "Article Summary"
            } else if let post = redditPost {
                prompt = redditPostSummaryPrompt(post: post, comments: redditComments)
                taskName = "Reddit Summary"
            } else {
                isLoading = false
                return
            }

            performSummarizeSummaryPublic(prompt: prompt, taskName: taskName) { [weak self] summary in
                if let article = article {
                    let sourceText = self?.cleanedArticleContent(article) ?? ""
                    let constrained = self?.enforceArticleSummaryLength(summary, sourceText: sourceText) ?? summary
                    self?.updateArticleSummaryFromCloud(article, summary: constrained)
                } else if let post = redditPost {
                    self?.updateRedditPostSummaryFromCloud(post, summary: summary)
                }
            }
            return
        }

        if settings.selectedSummaryProvider == .applePCCGateway {
            let prompt: String
            let taskName: String
            if let article = article {
                prompt = articleSummaryPrompt(for: article)
                taskName = "Article Summary"
            } else if let post = redditPost {
                prompt = redditPostSummaryPrompt(post: post, comments: redditComments)
                taskName = "Reddit Summary"
            } else {
                isLoading = false
                return
            }

            performPCCGatewaySummaryPublic(prompt: prompt, taskName: taskName) { [weak self] summary in
                if let article = article {
                    let sourceText = self?.cleanedArticleContent(article) ?? ""
                    let constrained = self?.enforceArticleSummaryLength(summary, sourceText: sourceText) ?? summary
                    self?.updateArticleSummaryFromCloud(article, summary: constrained)
                } else if let post = redditPost {
                    self?.updateRedditPostSummaryFromCloud(post, summary: summary)
                }
            }
            return
        }

        // Only use Gemini if it's selected
        if settings.selectedSummaryProvider == .gemini {
            if let article = article {
                summarizeArticle(article)
            } else if let post = redditPost {
                summarizeRedditPost(post, comments: redditComments)
            }
        } else if settings.selectedSummaryProvider == .appleLocal {
            // Use on-device AI with Gemini fallback
            let prompt: String
            let taskName: String
            if let article = article {
                // Clean HTML for local processing
                let htmlContent = article.content ?? ""
                let cleanText = htmlContent
                    .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
                    .replacingOccurrences(of: "&nbsp;", with: " ")
                    .replacingOccurrences(of: "&quot;", with: "\"")
                    .replacingOccurrences(of: "&amp;", with: "&")
                    .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                prompt = "Provide a concise summary (4-6 sentences) of the following text. Return plain text only (no Markdown, no headings, no bullets):\n\n\(cleanText)"
                taskName = "Article Summary"
            } else if let post = redditPost {
                // Include comments so the summary covers the discussion, not just the post text
                let commentTexts = redditComments.flatMap { extractAllCommentTexts(from: $0) }
                let topComments = Array(commentTexts.prefix(20)).map { String($0.prefix(500)) }
                let commentsBlock = topComments.isEmpty ? "(no comments)" :
                    topComments.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
                prompt = """
                Summarize the following Reddit post and its top comments in up to 3 paragraphs. \
                First paragraph: cover the main post topic and content. \
                Remaining paragraphs: highlight key themes and viewpoints from the comments. \
                Return plain text only (no Markdown, no headings, no bullets):

                Title: \(post.title)

                Post:
                \(post.content)

                Top Comments:
                \(commentsBlock)
                """
                taskName = "Reddit Post Summary"
            } else {
                return
            }

            let t0 = Date()
            performLocalWithGeminiFallback(prompt: prompt, taskName: taskName, completion: { [weak self] summary in
                let elapsed = Date().timeIntervalSince(t0)
                Task { @MainActor [weak self] in self?.recordAppleLocalThroughput(text: summary, elapsed: elapsed) }
                if let article = article {
                    self?.updateArticleSummaryFromCloud(article, summary: summary)
                } else if let post = redditPost {
                    self?.updateRedditPostSummaryFromCloud(post, summary: summary)
                }
            })
        } else if settings.selectedSummaryProvider == .mlxLocal || settings.selectedSummaryProvider == .coreAIMLXLocal {
            // Use MLX Local model
            let prompt: String
            if let article = article {
                let htmlContent = article.content ?? ""
                let cleanText = htmlContent
                    .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
                    .replacingOccurrences(of: "&nbsp;", with: " ")
                    .replacingOccurrences(of: "&quot;", with: "\"")
                    .replacingOccurrences(of: "&amp;", with: "&")
                    .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                prompt = "Provide a concise summary (4-6 sentences) of the following text. Return plain text only:\n\n\(cleanText)"
            } else if let post = redditPost {
                // Include comments so MLX sees the discussion, not just the post text
                let commentTexts = redditComments.flatMap { extractAllCommentTexts(from: $0) }
                let topComments = Array(commentTexts.prefix(20)).map { String($0.prefix(500)) }
                let commentsBlock = topComments.isEmpty ? "(no comments)" :
                    topComments.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
                prompt = """
                Summarize the following Reddit post and its top comments in up to 3 paragraphs. \
                First paragraph: main post topic. \
                Remaining paragraphs: key themes from comments. \
                Return plain text only:

                Title: \(post.title)

                Post:
                \(post.content)

                Top Comments:
                \(commentsBlock)
                """
            } else {
                return
            }

            performMLXLocalSummary(prompt: prompt, completion: { [weak self] summary in
                if let article = article {
                    self?.updateArticleSummaryFromCloud(article, summary: summary)
                } else if let post = redditPost {
                    self?.updateRedditPostSummaryFromCloud(post, summary: summary)
                }
            })
        } else {
            // Apple Cloud
            launchCloudSummaryForContent(article: article, redditPost: redditPost)
        }
    }
    
    private func launchCloudSummaryForContent(article: Article? = nil, redditPost: RedditPost? = nil) {
        var content = ""
        if let article = article {
            // Strip HTML tags from article content for cleaner text
            let htmlContent = article.content ?? ""
            let cleanedContent = htmlContent
                .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
                .replacingOccurrences(of: "&nbsp;", with: " ")
                .replacingOccurrences(of: "&quot;", with: "\"")
                .replacingOccurrences(of: "&amp;", with: "&")
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            
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
        
        print("📱 AppState: Launching Apple Cloud request for \(settings.selectedSummaryProvider.rawValue)")
        print("📱 AppState: Content length: \(content.count) characters")
        launchCloudSummary(for: content)
    }
    
    func launchCloudSummary(for text: String) {
        launchCloudRequest(for: text, type: .summary, completion: nil)
    }
    
    func launchCloudRequest(for text: String, type: AppleIntelligenceRequestType, completion: ((String) -> Void)?) {
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

        let description = error.localizedDescription
        let lower = description.lowercased()
        if lower.contains("private-cloud-compute") || lower.contains("entitlement") {
            return "Apple Cloud requires the managed Private Cloud Compute entitlement (com.apple.developer.private-cloud-compute) on this app. \(description)"
        }

        return "Apple Cloud error: \(description)"
    }
    #endif
    
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
    
#if os(macOS)
    private func runShortcutViaCLI(name: String, input: String, type: AppleIntelligenceRequestType, completion: ((String) -> Void)?) {
        let cliPath = "/usr/bin/shortcuts"
        guard FileManager.default.isExecutableFile(atPath: cliPath) else {
            print("⚠️ AppState: Shortcuts CLI not found at \(cliPath)")
            fallbackToRegularURL(text: input, type: type)
            return
        }

        let tempDir = FileManager.default.temporaryDirectory
        let inputFile = tempDir.appendingPathComponent("shortcut_input_\(UUID().uuidString).txt")
        let outputFile = tempDir.appendingPathComponent("shortcut_output_\(UUID().uuidString).txt")

        do {
            try input.write(to: inputFile, atomically: true, encoding: .utf8)
        } catch {
            print("⚠️ AppState: Failed to write CLI input file - \(error.localizedDescription)")
            fallbackToRegularURL(text: input, type: type)
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: cliPath)
        process.arguments = [
            "run",
            name,
            "--input-path", inputFile.path,
            "--output-path", outputFile.path,
            "--output-type", "public.plain-text"
        ]

        let errorPipe = Pipe()
        process.standardError = errorPipe

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
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
                    print("📝 AppState: Shortcuts CLI output (first 200 chars): \(output.prefix(200))")
                    DispatchQueue.main.async {
                        self?.handleCloudResult(output, for: type, completion: completion)
                    }
                } else {
                    print("⚠️ AppState: Shortcuts CLI failed (status \(status)): \(stderr)")
                    DispatchQueue.main.async {
                        self?.fallbackToRegularURL(text: input, type: type)
                    }
                }
            } catch {
                print("⚠️ AppState: Shortcuts CLI threw error: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    self?.fallbackToRegularURL(text: input, type: type)
                }
            }
        }
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
        case .articleQA, .redditQA, .commentSummary, .globalSummaryQA:
            print("⚠️ AppState: Received \(type) result without a completion handler")
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
    }
    
    private var currentRequestType: AppleIntelligenceRequestType = .summary
    private var currentRequestCompletion: ((String) -> Void)?
    
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
        
        // Set waiting state based on request type
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
            }
        }
        
        // Check clipboard every 5 seconds, up to 2 minutes
        clipboardTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] timer in
            guard let self = self else {
                timer.invalidate()
                return
            }
            
            self.clipboardCheckCount += 1
            let elapsedTime = self.clipboardCheckCount * 5
            let totalTime = self.maxClipboardChecks * 5
            
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
                }
            }
            
            // If clipboard changed and contains meaningful content
            if currentClipboard != originalClipboard && !currentClipboard.isEmpty && currentClipboard.count > 10 {
                print("✅ Found \(type) response in clipboard after \(elapsedTime) seconds!")
                
                // Handle the response based on request type
                DispatchQueue.main.async {
                    // Clear waiting state
                    self.clearWaitingState(for: type)
                    
                    switch type {
                    case .summary:
                        if let article = self.selectedArticle {
                            self.updateArticleSummaryFromCloud(article, summary: currentClipboard)
                        } else if let post = self.selectedRedditPost {
                            self.updateRedditPostSummaryFromCloud(post, summary: currentClipboard)
                        }
                    case .articleQA, .redditQA, .commentSummary, .globalSummaryQA:
                        // Call the completion handler for Q&A and comment summary
                        self.currentRequestCompletion?(currentClipboard)
                    }
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
                    // Clear waiting state
                    self.clearWaitingState(for: type)
                    
                    let timeoutMessage = "Apple Intelligence processing took longer than expected. Please check your clipboard manually or try again."
                    
                    switch type {
                    case .summary:
                        if let article = self.selectedArticle {
                            self.updateArticleSummaryFromCloud(article, summary: timeoutMessage)
                        } else if let post = self.selectedRedditPost {
                            self.updateRedditPostSummaryFromCloud(post, summary: timeoutMessage)
                        }
                    case .articleQA, .redditQA, .commentSummary, .globalSummaryQA:
                        // Call the completion handler with timeout message
                        self.currentRequestCompletion?(timeoutMessage)
                    }
                }
                
                // Stop monitoring
                timer.invalidate()
                self.clipboardTimer = nil
            }
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
            redditService.fetchComments(for: post.id, in: post.subreddit, limit: 250, depth: 4)
                .map { comments -> (RedditPost, [RedditCommentModel]) in
                    let topLevel = comments
                        .filter { $0.indentationLevel == 0 }
                        .sorted(by: { $0.score > $1.score })
                    return (post, Array(topLevel.prefix(10)))
                }
                .replaceError(with: (post, []))
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
            .flatMap { [weak self] commentsByPost -> AnyPublisher<String, Never> in
                guard let self = self else {
                    return Just("Error: Unable to prepare summary.").eraseToAnyPublisher()
                }
                let prompt = self.buildTodaySummaryPrompt(
                    articles: todayArticles,
                    redditPosts: todayRedditPosts,
                    commentsByPost: commentsByPost
                )
                return self.todaySummaryPublisher(for: prompt)
            }
            .receive(on: DispatchQueue.main)
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
        todaySummaryInfo = nil
    }

    private var hasExistingAggregateSummary: Bool {
        guard let text = aggregateSummaryText?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return false
        }
        return !text.isEmpty
    }

    private func globalSummaryContextKey(_ context: GlobalSummaryContext?) -> String? {
        guard let context else { return nil }

        switch context {
        case .articles(let articles):
            return "articles:" + articles.map(\.id).joined(separator: "|")
        case .reddit(let posts, let topComments):
            return "reddit:\(topComments):" + posts.map(\.id).joined(separator: "|")
        case .subreddit(let name, let topComments):
            return "subreddit:\(name.lowercased()):\(topComments)"
        case .subredditHot(let name, let topComments):
            return "subredditHot:\(name.lowercased()):\(topComments)"
        case .subredditSorted(let name, let sortOption, let topComments):
            return "subredditSorted:\(name.lowercased()):\(sortOption.rawValue):\(topComments)"
        case .todayArticles:
            return "todayArticles"
        case .todayReddit:
            return "todayReddit"
        }
    }

    private func shouldPreserveAggregateSummary(for context: GlobalSummaryContext) -> Bool {
        hasExistingAggregateSummary && globalSummaryContextKey(lastGlobalSummaryContext) == globalSummaryContextKey(context)
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
                let excerpt = previewText(from: source, maxCharacters: Int.max)  // No limit for articles
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
                let postSnippet = previewText(from: post.content, maxCharacters: 2000)  // Increased to 2000 chars
                let snippet = postSnippet.isEmpty ? "No post text available." : postSnippet
                let comments = commentsLookup[post.id] ?? []
                let commentLines: [String]
                if comments.isEmpty {
                    commentLines = ["  Top Comments: none collected."]
                } else {
                    commentLines = ["  Top Comments:"] + comments.enumerated().map { index, comment in
                        let body = previewText(from: comment.body, maxCharacters: 1000)  // Increased to 1000 chars
                        let bodySnippet = body.isEmpty ? "(no text)" : body
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

        Output as JSON array:
        [{
          "subject": "...",
          "summary": "Comprehensive 3-5 sentence summary that merges RSS articles and Reddit consensus. Cite sources inline as [Source] or r/SubredditName."
        }, ...]
        """
    }
    
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
        // Convert ATX headings (## Title) into bold inline headings
        if let headingToBold = try? NSRegularExpression(pattern: "^(?:\\s{0,3})#{1,6}\\s+(.+)$", options: [.anchorsMatchLines]) {
            let range = NSRange(t.startIndex..., in: t)
            t = headingToBold.stringByReplacingMatches(in: t, options: [], range: range, withTemplate: "**$1**\n")
        }
        // Remove stray bullet markers
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
        // First try to clean markdown code blocks if present
        var cleanedText = text
        if cleanedText.contains("```json") {
            cleanedText = cleanedText.replacingOccurrences(of: "```json", with: "")
        }
        if cleanedText.contains("```") {
            cleanedText = cleanedText.replacingOccurrences(of: "```", with: "")
        }
        
        // Try to find JSON array
        guard let range = cleanedText.range(of: "\\[[\\s\\S]*\\]", options: .regularExpression) else {
            return nil
        }

        let jsonString = String(cleanedText[range])
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
            let providerName = selectedOverallLocalProviderName ?? settings.selectedSummaryProvider.displayName
            return Future<String, Never> { promise in
                DispatchQueue.main.async { [weak self] in
                    guard let self else {
                        promise(.success("Today Summary routing cancelled."))
                        return
                    }
                    self.presentLocalReroute(
                        providerName: providerName,
                        prompt: prompt,
                        taskName: "Today Summary",
                        appleRequestType: .summary,
                        completion: { result in
                            promise(.success(result))
                        },
                        onCancel: {
                            promise(.success("Today Summary routing cancelled."))
                        }
                    )
                }
            }
            .eraseToAnyPublisher()

        case .appleCloud:
            return Future<String, Never> { promise in
                self.launchCloudRequest(for: prompt, type: .commentSummary) { result in
                    promise(.success(result))
                }
            }.eraseToAnyPublisher()
        case .applePCCGateway:
            return Future<String, Never> { promise in
                Task(priority: .userInitiated) {
                    do {
                        let output = try await self.performPCCGatewayRequestAsync(prompt: prompt, taskName: "Today Summary")
                        promise(.success(output))
                    } catch {
                        promise(.success("Apple PCC error: \(error.localizedDescription)"))
                    }
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
            }.eraseToAnyPublisher()
        case .summarizeDaemon:
            return summaryService.summarizeWithSummarizePublisher(prompt: prompt, settings: settings)
        }
    }
    
    private func previewText(from html: String, maxCharacters: Int) -> String {
        // Strip HTML tags first
        let noTags = html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        // Decode HTML entities
        let decoded = noTags
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
        // Clean up extra whitespace
        let cleaned = decoded.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Truncate if needed
        if cleaned.count <= maxCharacters {
            return cleaned
        } else {
            let truncated = String(cleaned.prefix(maxCharacters))
            // Try to end at a word boundary
            if let lastSpace = truncated.lastIndex(of: " ") {
                return String(truncated[..<lastSpace]) + "..."
            }
            return truncated + "..."
        }
    }
    
    // MARK: - Cloud Summary Updates
    func updateArticleSummaryFromCloud(_ article: Article, summary: String) {
        let cleanedSummary = cleanMarkdownArtifactsForDisplay(summary)
        var updatedArticle: Article?

        if let feedIndex = feeds.firstIndex(where: { $0.url == article.feedURL }),
           let articleIndex = feeds[feedIndex].articles.firstIndex(where: { $0.id == article.id }) {
            
            // Create a mutable copy of the article to update
            var articleToUpdate = feeds[feedIndex].articles[articleIndex]
            
            // Update the article with a markdown-artifact-free cloud summary
            articleToUpdate.summary = cleanedSummary
            
            // Update the article in the feeds array
            feeds[feedIndex].articles[articleIndex] = articleToUpdate
            updatedArticle = articleToUpdate
        }

        // If this is the currently selected article, update the selection directly
        // so Web AI summaries paint the UI even when the feed-array lookup misses.
        if selectedArticle?.id == article.id {
            if let updatedArticle {
                selectedArticle = updatedArticle
            } else {
                var articleToUpdate = selectedArticle ?? article
                articleToUpdate.summary = cleanedSummary
                selectedArticle = articleToUpdate
            }
            isSummaryFromCloud = true
            print("📱 AppState: Updated article summary from cloud for article ID: \(article.id)")
        }
    }
    
    func updateRedditPostSummaryFromCloud(_ post: RedditPost, summary: String) {
        let cleanedSummary = cleanMarkdownArtifactsForDisplay(summary)
        var updatedPost: RedditPost?

        if let feedIndex = redditFeeds.firstIndex(where: { $0.subreddit == post.subreddit }),
           let postIndex = redditFeeds[feedIndex].posts.firstIndex(where: { $0.id == post.id }) {
            
            // Create a mutable copy of the post to update
            var postToUpdate = redditFeeds[feedIndex].posts[postIndex]
            
            // Update the post with a markdown-artifact-free cloud summary
            postToUpdate.summary = cleanedSummary
            
            // Update the post in the redditFeeds array
            redditFeeds[feedIndex].posts[postIndex] = postToUpdate
            updatedPost = postToUpdate
        }

        // If this is the currently selected post, update the selection directly
        // so Web AI summaries paint the UI even when the feed-array lookup misses.
        if selectedRedditPost?.id == post.id {
            if let updatedPost {
                selectedRedditPost = updatedPost
            } else {
                var postToUpdate = selectedRedditPost ?? post
                postToUpdate.summary = cleanedSummary
                selectedRedditPost = postToUpdate
            }
            isSummaryFromCloud = true
            print("📱 AppState: Updated Reddit post summary from cloud for post ID: \(post.id)")
        }
    }

    // MARK: - Global Summaries (Articles + Reddit)

    private func emptySummaryPlaceholder(for source: String) -> String {
        "{\"source\":\"\(source)\",\"summaries\":[],\"error\":null}"
    }

    private func errorSummaryJSON(for source: String, message: String) -> String {
        let escaped = message.replacingOccurrences(of: "\"", with: "\\\"")
        return "{\"source\":\"\(source)\",\"summaries\":[],\"error\":\"\(escaped)\"}"
    }

    private func handleSummaryResult(_ result: GlobalSummaryResult) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        if let data = try? encoder.encode(result),
           let json = String(data: data, encoding: .utf8) {
            self.globalSummaryJSON = json
            self.hasCachedSummary = true
            print("✅ AppState: Updated globalSummaryJSON with \(result.summaries.count) summaries (source: \(result.source))")
        } else {
            self.globalSummaryJSON = errorSummaryJSON(for: result.source, message: "Encoding failure")
            print("❌ AppState: Failed to encode result for source \(result.source)")
        }
        self.lastGlobalSummaryError = result.error
        self.isLoading = false
        self.showGlobalSummary = true

    }

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
        onRoute: @escaping @MainActor (LocalRerouteProvider) -> Void
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
                onRoute(provider)
            },
            cancelHandler: { [weak self] in
                self?.isLoading = false
                self?.lastGlobalSummaryError = "Overall Summary routing cancelled."
            }
        )
    }

    private func performArticlesSummary(
        articles: [Article],
        context: GlobalSummaryContext,
        emptyMessage: String,
        logMessage: String? = nil,
        providerOverride: AppSettings.SummaryProvider? = nil
    ) {
        let preserveExistingAggregateSummary = shouldPreserveAggregateSummary(for: context)
        resetAggregateSummaryState(preservingCurrentSummary: preserveExistingAggregateSummary)

        globalSummaryArticles = articles
        globalSummaryPosts = []
        globalSummaryComments = [] // Clear cached comments
        lastGlobalSummaryContext = context

        guard !articles.isEmpty else {
            print("❌ AppState.Global: \(emptyMessage)")
            lastGlobalSummaryError = emptyMessage
            globalSummaryJSON = errorSummaryJSON(for: "articles", message: emptyMessage)
            showGlobalSummary = true
            isLoading = false
            hasCachedSummary = false
            return
        }

        if let logMessage = logMessage {
            print(logMessage)
        }

        isLoading = true
        lastGlobalSummaryError = nil
        if !preserveExistingAggregateSummary {
            globalSummaryJSON = emptySummaryPlaceholder(for: "articles")
        }
        hasCachedSummary = true
        showGlobalSummary = true

        if providerOverride == nil, let providerName = selectedOverallLocalProviderName {
            presentOverallSummaryReroute(
                providerName: providerName,
                itemCount: articles.count,
                sourceName: "articles"
            ) { [weak self] provider in
                    self?.performArticlesSummary(
                        articles: articles,
                        context: context,
                        emptyMessage: emptyMessage,
                        logMessage: logMessage,
                        providerOverride: provider.summaryProvider
                    )
            }
            return
        }

        let effectiveProvider = providerOverride ?? settings.selectedSummaryProvider
        if effectiveProvider == .webAI {
            summarizeArticlesGloballyWithWebAI(articles)
            return
        }

        globalSummaryService
            .summarizeArticlesGlobally(articles: articles, providerOverride: providerOverride)
            .receive(on: RunLoop.main)
            .sink { [weak self] result in
                self?.handleSummaryResult(result)
            }
            .store(in: &cancellables)
    }

    private func performRedditSummary(
        posts: [RedditPost],
        topComments: Int,
        context: GlobalSummaryContext,
        emptyMessage: String,
        logMessage: String? = nil,
        providerOverride: AppSettings.SummaryProvider? = nil
    ) {
        let preserveExistingAggregateSummary = shouldPreserveAggregateSummary(for: context)
        resetAggregateSummaryState(preservingCurrentSummary: preserveExistingAggregateSummary)

        globalSummaryPosts = posts
        globalSummaryArticles = []
        globalSummaryComments = [] // Clear cached comments for new summary
        lastGlobalSummaryContext = context

        guard !posts.isEmpty else {
            print("❌ AppState.Global: \(emptyMessage)")
            lastGlobalSummaryError = emptyMessage
            globalSummaryJSON = errorSummaryJSON(for: "reddit", message: emptyMessage)
            showGlobalSummary = true
            isLoading = false
            hasCachedSummary = false
            return
        }

        if let logMessage = logMessage {
            print(logMessage)
        }

        isLoading = true
        lastGlobalSummaryError = nil
        if !preserveExistingAggregateSummary {
            globalSummaryJSON = emptySummaryPlaceholder(for: "reddit")
        }
        hasCachedSummary = true
        showGlobalSummary = true

        if providerOverride == nil, let providerName = selectedOverallLocalProviderName {
            presentOverallSummaryReroute(
                providerName: providerName,
                itemCount: posts.count,
                sourceName: "Reddit posts"
            ) { [weak self] provider in
                    self?.performRedditSummary(
                        posts: posts,
                        topComments: topComments,
                        context: context,
                        emptyMessage: emptyMessage,
                        logMessage: logMessage,
                        providerOverride: provider.summaryProvider
                    )
            }
            return
        }

        let effectiveProvider = providerOverride ?? settings.selectedSummaryProvider
        if effectiveProvider == .webAI {
            summarizeRedditPostsGloballyWithWebAI(posts, topComments: topComments)
            return
        }

        globalSummaryService
            .summarizeRedditGlobally(posts: posts, topComments: topComments, providerOverride: providerOverride)
            .receive(on: RunLoop.main)
            .sink { [weak self] result in
                self?.handleSummaryResult(result)
            }
            .store(in: &cancellables)
    }

    private func summarizeArticlesGloballyWithWebAI(_ articles: [Article]) {
        Task(priority: .userInitiated) { [weak self] in
            guard let self else { return }

            await MainActor.run {
                self.isWebAIHandoffMinimized = true
                self.isWebAIBatchHandoffInProgress = true
            }
            defer {
                Task { @MainActor [weak self] in
                    self?.isWebAIBatchHandoffInProgress = false
                    self?.isWebAIHandoffMinimized = false
                }
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
                    let cleaned = self.cleanMarkdownArtifactsForDisplay(constrained)

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
                self.handleSummaryResult(result)
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
            defer {
                Task { @MainActor [weak self] in
                    self?.isWebAIBatchHandoffInProgress = false
                    self?.isWebAIHandoffMinimized = false
                }
            }

            var summaries: [GlobalSummaryItem] = []
            var errorMessage: String?

            for (index, post) in posts.enumerated() {
                let comments = await self.fetchTopCommentsForWebGlobalSummary(post: post, topComments: topComments)

                do {
                    let rawSummary = try await self.performWebAIRequestAsync(
                        title: "Reddit Summary \(index + 1) of \(posts.count)",
                        prompt: self.redditPostSummaryPrompt(post: post, comments: comments)
                    )
                    let cleaned = self.cleanMarkdownArtifactsForDisplay(rawSummary)

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
                self.handleSummaryResult(result)
            }
        }
    }

    private func fetchTopCommentsForWebGlobalSummary(post: RedditPost, topComments: Int) async -> [RedditCommentModel] {
        await withCheckedContinuation { continuation in
            Task {
                let result = await self.redditService.fetchCommentsDetailed(
                    for: post.id,
                    in: post.subreddit,
                    limit: topComments,
                    depth: 0
                )
                if let error = result.errorDescription, !error.isEmpty {
                    print("⚠️ AppState.WebAI: Comment fetch error for \(post.id): \(error)")
                }
                let filtered = result.comments
                    .filter { $0.author.lowercased() != "automoderator" }
                    .sorted { $0.score > $1.score }
                continuation.resume(returning: Array(filtered.prefix(max(1, topComments))))
            }
        }
    }

    /// Collects all unread articles (ordered by publish date desc), builds title+excerpt (≤500 chars),
    /// validates collection, calls LLM via GlobalSummaryService and exposes pretty-printed JSON.
    func summarizeAllArticlesGlobally() {
        let articles = feeds
            .flatMap { $0.articles }
            .filter { !$0.isRead }
            .sorted(by: { $0.publishDate > $1.publishDate })

        performArticlesSummary(
            articles: articles,
            context: .articles(articles),
            emptyMessage: "No unread articles to summarize.",
            logMessage: "✅ AppState.Global: Collected \(articles.count) unread articles; generating title + ≤500-char excerpts."
        )
    }

    /// Collects all unread reddit posts (ordered by publish date desc), fetches up to `topComments`
    /// top-level comments (≤200 chars each) per post, validates, calls LLM and exposes JSON.
    func summarizeAllRedditGlobally(topComments: Int = 10) {
        let posts = redditFeeds
            .flatMap { $0.posts }
            .filter { !$0.isRead }
            .sorted(by: { $0.publishDate > $1.publishDate })

        performRedditSummary(
            posts: posts,
            topComments: topComments,
            context: .reddit(posts, topComments),
            emptyMessage: "No unread Reddit posts to summarize.",
            logMessage: "✅ AppState.Global: Collected \(posts.count) unread reddit posts; requesting top \(topComments) comments per post."
        )
    }

    // MARK: - Today-only Global Summaries

    /// Summarize only today's unread articles (by publishDate)
    func summarizeTodayArticlesGlobally() {
        let calendar = Calendar.current
        let articles = feeds
            .flatMap { $0.articles }
            .filter { calendar.isDateInToday($0.publishDate) && !$0.isRead }
            .sorted(by: { $0.publishDate > $1.publishDate })

        performArticlesSummary(
            articles: articles,
            context: .todayArticles,
            emptyMessage: "No unread articles from today to summarize.",
            logMessage: "✅ AppState.Global: Prepared \(articles.count) unread today articles."
        )
    }

    /// Summarize only today's unread reddit posts (by publishDate), with top N comments
    func summarizeTodayRedditGlobally(topComments: Int = 10) {
        let calendar = Calendar.current
        let posts = redditFeeds
            .flatMap { $0.posts }
            .filter { calendar.isDateInToday($0.publishDate) && !$0.isRead }
            .sorted(by: { $0.publishDate > $1.publishDate })

        performRedditSummary(
            posts: posts,
            topComments: topComments,
            context: .todayReddit,
            emptyMessage: "No unread Reddit posts from today to summarize.",
            logMessage: "✅ AppState.Global: Prepared \(posts.count) unread today reddit posts (top \(topComments) comments per post)."
        )
    }

    // MARK: - Feed-specific Global Summaries

    /// Summarize unread articles from a specific RSS feed
    func summarizeFeedArticlesGlobally(feedURL: String) {
        guard let feed = feeds.first(where: { $0.url == feedURL }) else {
            print("❌ AppState.Global: Feed not found for URL: \(feedURL)")
            lastGlobalSummaryError = "Feed not found."
            globalSummaryJSON = errorSummaryJSON(for: "articles", message: "Feed not found.")
            showGlobalSummary = true
            return
        }

        let articles = feed.articles
            .filter { !$0.isRead }
            .sorted(by: { $0.publishDate > $1.publishDate })

        performArticlesSummary(
            articles: articles,
            context: .articles(articles),
            emptyMessage: "No unread articles in this feed to summarize.",
            logMessage: "✅ AppState.Global: Prepared \(articles.count) unread articles from feed."
        )
    }

    /// Summarize unread posts from a specific subreddit
    func summarizeSubredditPostsGlobally(subreddit: String, topComments: Int = 10) {
        summarizeSubredditSortedPostsGlobally(
            subreddit: subreddit,
            sortOption: .new,
            includeReadPosts: false,
            topComments: topComments
        )
    }

    /// Summarize all visible posts from a specific subreddit (includes read items)
    func summarizeSubredditHotPostsGlobally(subreddit: String, topComments: Int = 10) {
        summarizeSubredditSortedPostsGlobally(
            subreddit: subreddit,
            sortOption: .hot,
            includeReadPosts: true,
            topComments: topComments
        )
    }

    func summarizeSubredditTopDayPostsGlobally(subreddit: String, topComments: Int = 10) {
        summarizeSubredditSortedPostsGlobally(
            subreddit: subreddit,
            sortOption: .topDay,
            includeReadPosts: true,
            topComments: topComments
        )
    }

    func summarizeSubredditTopWeekPostsGlobally(subreddit: String, topComments: Int = 10) {
        summarizeSubredditSortedPostsGlobally(
            subreddit: subreddit,
            sortOption: .topWeek,
            includeReadPosts: true,
            topComments: topComments
        )
    }

    private func hydrateRedditFeed(_ redditFeed: RedditFeed, sortOption: RedditService.SortOption) -> RedditFeed {
        var processedFeed = redditFeed
        for index in processedFeed.posts.indices {
            let post = processedFeed.posts[index]
            processedFeed.posts[index].isRead = persistenceManager.isRedditPostRead(post)
            processedFeed.posts[index].isFavorite = persistenceManager.isRedditPostFavorite(post.id)
        }

        if sortOption == .new {
            let stickied = processedFeed.posts.filter { $0.isStickied }
            let nonStickied = processedFeed.posts.filter { !$0.isStickied }
                .sorted { $0.publishDate > $1.publishDate }
            processedFeed.posts = stickied + nonStickied
        }

        return processedFeed
    }

    private func updateVisibleRedditFeedIfNeeded(_ redditFeed: RedditFeed, sortOption: RedditService.SortOption) {
        cacheRedditFeed(redditFeed, sortOption: sortOption)

        guard sortOption == redditSortOption else { return }

        if let index = redditFeeds.firstIndex(where: { $0.subreddit == redditFeed.subreddit }) {
            let existingFeed = redditFeeds[index]
            if redditFeed.posts.isEmpty && !existingFeed.posts.isEmpty {
                print("⚠️ AppState.Global: Refusing to replace \(existingFeed.posts.count) existing posts with empty \(sortOption.rawValue) feed for r/\(redditFeed.subreddit)")
            } else {
                redditFeeds[index] = redditFeed
            }
        } else {
            redditFeeds.append(redditFeed)
        }

        redditFeedSortState[redditFeed.subreddit] = sortOption
        scheduleUnreadCacheRebuild()
    }

    private func subredditSummaryContext(
        subreddit: String,
        sortOption: RedditService.SortOption,
        topComments: Int
    ) -> GlobalSummaryContext {
        if sortOption == .hot {
            return .subredditHot(subreddit, topComments)
        }
        if sortOption == .new {
            return .subreddit(subreddit, topComments)
        }
        return .subredditSorted(subreddit, sortOption, topComments)
    }

    private func subredditSummaryLabel(for sortOption: RedditService.SortOption) -> String {
        switch sortOption {
        case .hot:
            return "hot"
        case .new:
            return "new"
        case .topDay:
            return "top day"
        case .topWeek:
            return "top week"
        }
    }

    private func summarizeSubredditSortedPostsGlobally(
        subreddit: String,
        sortOption: RedditService.SortOption,
        includeReadPosts: Bool,
        topComments: Int = 10
    ) {
        let context = subredditSummaryContext(
            subreddit: subreddit,
            sortOption: sortOption,
            topComments: topComments
        )
        let preserveExistingAggregateSummary = shouldPreserveAggregateSummary(for: context)
        resetAggregateSummaryState(preservingCurrentSummary: preserveExistingAggregateSummary)

        globalSummaryPosts = []
        globalSummaryArticles = []
        globalSummaryComments = []
        lastGlobalSummaryContext = context
        isLoading = true
        lastGlobalSummaryError = nil
        if !preserveExistingAggregateSummary {
            globalSummaryJSON = emptySummaryPlaceholder(for: "reddit")
        }
        hasCachedSummary = true
        showGlobalSummary = true

        redditService.fetchSubreddit(subreddit: subreddit, sortOption: sortOption)
            .receive(on: RunLoop.main)
            .sink { [weak self] redditFeed in
                guard let self = self else { return }

                let processedFeed = self.hydrateRedditFeed(redditFeed, sortOption: sortOption)
                self.updateVisibleRedditFeedIfNeeded(processedFeed, sortOption: sortOption)

                let selectedPosts = includeReadPosts
                    ? processedFeed.posts
                    : processedFeed.posts.filter { !$0.isRead }
                let posts = Array(selectedPosts.prefix(50))
                let label = self.subredditSummaryLabel(for: sortOption)
                let emptyMessage = includeReadPosts
                    ? "No \(label) posts in this subreddit to summarize."
                    : "No unread \(label) posts in this subreddit to summarize."

                self.performRedditSummary(
                    posts: posts,
                    topComments: topComments,
                    context: context,
                    emptyMessage: emptyMessage,
                    logMessage: "✅ AppState.Global: Fetched \(posts.count) \(label) posts from r/\(subreddit) (top \(topComments) comments per post)."
                )
            }
            .store(in: &cancellables)
    }

    // MARK: - Retry and Aggregate Summary

    func retryLastGlobalSummary() {
        print("🔄 retryLastGlobalSummary called, context: \(String(describing: lastGlobalSummaryContext))")
        guard let context = lastGlobalSummaryContext else {
            print("❌ No context available for retry")
            return
        }

        lastGlobalSummaryError = nil

        switch context {
        case .articles(let articles):
            performArticlesSummary(
                articles: articles,
                context: .articles(articles),
                emptyMessage: "No articles available for summary.",
                logMessage: "🔄 AppState.Global: Retrying summary for \(articles.count) articles."
            )
        case .reddit(let posts, let topComments):
            performRedditSummary(
                posts: posts,
                topComments: topComments,
                context: .reddit(posts, topComments),
                emptyMessage: "No Reddit posts available for summary.",
                logMessage: "🔄 AppState.Global: Retrying summary for \(posts.count) Reddit posts (top \(topComments) comments per post)."
            )
        case .subreddit(let name, let topComments):
            summarizeSubredditPostsGlobally(subreddit: name, topComments: topComments)
        case .subredditHot(let name, let topComments):
            summarizeSubredditHotPostsGlobally(subreddit: name, topComments: topComments)
        case .subredditSorted(let name, let sortOption, let topComments):
            summarizeSubredditSortedPostsGlobally(
                subreddit: name,
                sortOption: sortOption,
                includeReadPosts: sortOption != .new,
                topComments: topComments
            )
        case .todayArticles:
            summarizeTodayArticlesGlobally()
        case .todayReddit:
            summarizeTodayRedditGlobally()
        }
    }

    private func decodeGlobalSummaryResult() -> GlobalSummaryResult? {
        guard !globalSummaryJSON.isEmpty,
              let data = globalSummaryJSON.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode(GlobalSummaryResult.self, from: data)
    }

    private func resetAggregateSummaryState(preservingCurrentSummary: Bool = false) {
        aggregateSummaryError = nil
        isGeneratingAggregateSummary = false

        if preservingCurrentSummary {
            logAggregateSummaryEvent("Preserving existing overall summary for same global summary context")
        } else {
            aggregateSummaryText = nil
            aggregateSummaryProviderName = nil
            aggregateSummarySourceFingerprint = nil
        }
    }

    private func buildAggregatePrompt(from result: GlobalSummaryResult) -> String {
        let sourceLabel = result.source == "reddit" ? "Reddit threads" : "articles"
        let isReddit = result.source == "reddit"
        let dataItems = result.summaries.enumerated().map { idx, item in
            "Item \(idx + 1): **\(item.subject)** — \(item.summary)"
        }.joined(separator: "\n")

        let redditInstruction = isReddit ? "\n        - When working with Reddit content, inform of all topics being discussed." : ""

        return """
        You have insight from multiple \(sourceLabel). Each entry includes its subject and summary (posts plus prevailing comment debate when available).

        DATA:
        \(dataItems)

        ---
        Task:
        - Identify 2–4 cross-cutting themes that link both the post topics and how discussion evolved in the comments (agreements vs disagreements, new angles, sentiment shifts).
        - For each theme, list which item numbers contribute and describe the shared perspective, highlighting consensus versus contention.
        - Conclude with a paragraph summarizing the overall mood and debate trajectory across the set.\(redditInstruction)

        Output format (plain text only, no Markdown symbols like #, *, _, or `):
        Theme 1: [Theme Name]
        Items X, Y: [Brief description capturing comment consensus/debate]

        Theme 2: [Theme Name]
        Items A, B: [Brief description capturing comment consensus/debate]

        Final Overall Summary: One paragraph summarizing collective insights and tone.
        """
    }

    private func launchAggregateSummary(from result: GlobalSummaryResult) {
        print("✅ Starting aggregate summary generation")
        isGeneratingAggregateSummary = true
        aggregateSummaryError = nil
        aggregateSummaryText = nil
        aggregateSummaryProviderName = nil

        let prompt = buildAggregatePrompt(from: result)
        if let providerName = selectedOverallLocalProviderName {
            presentLocalReroute(
                providerName: providerName,
                prompt: prompt,
                taskName: "Overall Summary",
                appleRequestType: .summary,
                completion: { [weak self] routedSummary in
                    guard let self else { return }
                    let trimmed = routedSummary.trimmingCharacters(in: .whitespacesAndNewlines)
                    let lowercased = trimmed.lowercased()
                    if trimmed.isEmpty || lowercased.hasPrefix("error") || lowercased.contains("api key not configured") || lowercased.contains("choose a cloud or remote provider") {
                        self.aggregateSummaryError = trimmed.isEmpty ? "Failed to generate combined summary." : trimmed
                        self.aggregateSummaryProviderName = nil
                    } else {
                        self.aggregateSummaryText = self.formatLLMAnswer(trimmed)
                        self.aggregateSummaryProviderName = "Rerouted"
                    }
                    self.isGeneratingAggregateSummary = false
                },
                onCancel: { [weak self] in
                    self?.isGeneratingAggregateSummary = false
                    self?.aggregateSummaryError = "Overall Summary routing cancelled."
                }
            )
            return
        }

        Task { [weak self] in
            guard let self = self else { return }

            do {
                let summary: String
                let providerName: String
                if self.settings.selectedSummaryProvider == .summarizeDaemon {
                    print("⚙️ Aggregate: Using Codex / Summarize for combined summary")
                    providerName = self.settings.selectedSummaryProvider.displayName
                    summary = try await self.performSummarizeRequestAsync(
                        prompt: prompt,
                        taskName: result.source == "reddit" ? "Combined Reddit Summary" : "Combined Article Summary"
                    )
                } else if self.settings.selectedSummaryProvider == .applePCCGateway {
                    print("☁️ Aggregate: Using Apple PCC fm CLI for combined summary")
                    providerName = self.settings.selectedSummaryProvider.displayName
                    summary = try await self.performPCCGatewayRequestAsync(
                        prompt: prompt,
                        taskName: result.source == "reddit" ? "Combined Reddit Summary" : "Combined Article Summary"
                    )
                } else if self.settings.selectedSummaryProvider == .webAI {
                    print("🌐 Aggregate: Using \(self.settings.selectedWebAIProvider.displayName) for combined summary")
                    providerName = self.settings.selectedWebAIProvider.displayName
                    await MainActor.run {
                        self.isWebAIHandoffMinimized = true
                    }
                    summary = try await self.performWebAIRequestAsync(
                        title: result.source == "reddit" ? "Combined Reddit Summary" : "Combined Article Summary",
                        prompt: prompt
                    )
                } else {
                    print("🧠 Aggregate: Using Gemini for combined summary")
                    providerName = AppSettings.SummaryProvider.gemini.displayName
                    summary = await withCheckedContinuation { continuation in
                        var cancellable: AnyCancellable?
                        cancellable = self.summaryService.summarizeText(prompt, customPrompt: nil)
                            .receive(on: RunLoop.main)
                            .sink { result in
                                continuation.resume(returning: result)
                                cancellable?.cancel()
                            }
                    }
                }

                let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
                let lowercased = trimmed.lowercased()
                
                await MainActor.run {
                    if trimmed.isEmpty || lowercased.hasPrefix("error") || lowercased.contains("api key not configured") {
                        self.aggregateSummaryError = trimmed.isEmpty ? "Failed to generate combined summary." : trimmed
                        self.aggregateSummaryProviderName = nil
                    } else {
                        self.aggregateSummaryText = self.formatLLMAnswer(trimmed)
                        self.aggregateSummaryProviderName = providerName
                    }
                    self.isGeneratingAggregateSummary = false
                }
            } catch {
                await MainActor.run {
                    self.aggregateSummaryError = error.localizedDescription
                    self.aggregateSummaryProviderName = nil
                    self.isGeneratingAggregateSummary = false
                }
            }
        }
    }

    private func logAggregateSummaryEvent(_ message: String) {
        let stack = Thread.callStackSymbols
            .dropFirst(2)
            .prefix(6)
            .joined(separator: "\n")
        print("🎇 OverallSummary: \(message)\n\(stack)")
    }

    func generateCombinedGlobalSummary(force: Bool = false) {
        let sourceFingerprint = globalSummaryJSON
        logAggregateSummaryEvent(
            "Generation requested; force=\(force), isGenerating=\(isGeneratingAggregateSummary), hasSummary=\(hasExistingAggregateSummary), sameFingerprint=\(aggregateSummarySourceFingerprint == sourceFingerprint)"
        )

        guard !isGeneratingAggregateSummary else {
            logAggregateSummaryEvent("Ignoring request because aggregate generation is already running")
            return
        }

        if !force, hasExistingAggregateSummary {
            logAggregateSummaryEvent("Ignoring non-forced request because an overall summary is already visible")
            return
        }

        if force {
            logAggregateSummaryEvent("Forced overall summary regeneration accepted")
        }

        guard let result = decodeGlobalSummaryResult() else {
            print("❌ No summary JSON available")
            aggregateSummaryError = "No summary data available"
            aggregateSummarySourceFingerprint = nil
            return
        }

        guard !result.summaries.isEmpty else {
            aggregateSummaryError = result.error ?? "No summary data available"
            aggregateSummarySourceFingerprint = nil
            return
        }

        aggregateSummaryText = nil
        aggregateSummaryError = nil
        aggregateSummarySourceFingerprint = nil
        launchAggregateSummary(from: result)
        aggregateSummarySourceFingerprint = sourceFingerprint
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
        normalized.mlxModelID = LiteRTLocalService.normalizedModelIdentifier(from: settings.mlxModelID)
        normalized.mlxMaxContextTokens = AppSettings.normalizedLiteRTContextTokens(settings.mlxMaxContextTokens)
        normalized.mlxMaxOutputTokens = AppSettings.normalizedLiteRTOutputTokens(
            settings.mlxMaxOutputTokens,
            contextTokens: AppSettings.effectiveLiteRTContextTokens(normalized.mlxMaxContextTokens)
        )
        normalized.coreAIMLXModelID = CoreAIMLXLocalService.normalizedModelIdentifier(from: settings.coreAIMLXModelID)
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

        // If provider changed, clear stale throughput so old badges don't bleed through
        if normalizedSettings.selectedSummaryProvider != settings.selectedSummaryProvider {
            mlxLastThroughput = ""
            mlxLastQAThroughput = ""
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
        Task(priority: .userInitiated) {
            do {
                let response = try await FMPCCGatewayClient().health()
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

        #if canImport(WebKit)
        group.enter()
        WKWebsiteDataStore.default().removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: Date(timeIntervalSince1970: 0)) {
            print("🗑️ AppState: Cleared WebKit website data")
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
                    self.scheduleUnreadCacheRebuild()
                    
                    // Load the feeds for new subscriptions
                    for subscription in uniqueSubscriptions {
                        if subscription.type == .rss {
                            self.feedService.fetchFeed(url: subscription.url)
                                .receive(on: RunLoop.main)
                                .sink(receiveCompletion: { _ in },
                                      receiveValue: { [weak self] feed in
                                    guard let self = self else { return }
                                    // Apply read and favorite status
                                    var processedFeed = feed
                                    for i in 0..<processedFeed.articles.count {
                                        let article = processedFeed.articles[i]
                                        processedFeed.articles[i].isRead = self.persistenceManager.isArticleRead(article)
                                        processedFeed.articles[i].isFavorite = self.persistenceManager.isArticleFavorite(article.id)
                                    }
                                    self.feeds.append(processedFeed)
                                    self.scheduleUnreadCacheRebuild()
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
                                        let post = processedFeed.posts[i]
                                        processedFeed.posts[i].isRead = self.persistenceManager.isRedditPostRead(post)
                                        processedFeed.posts[i].isFavorite = self.persistenceManager.isRedditPostFavorite(post.id)
                                    }
                                    // Sort posts: stickied first, then by date for "New" sort
                                    if self.redditSortOption == .new {
                                        let stickied = processedFeed.posts.filter { $0.isStickied }
                                        let nonStickied = processedFeed.posts.filter { !$0.isStickied }
                                            .sorted { $0.publishDate > $1.publishDate }
                                        processedFeed.posts = stickied + nonStickied
                                    }
                                    self.redditFeeds.append(processedFeed)
                                    self.scheduleUnreadCacheRebuild()
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
        var markedAny = false
        // Mark all unread RSS articles as read
        for feedIndex in 0..<feeds.count {
            for articleIndex in 0..<feeds[feedIndex].articles.count {
                if !feeds[feedIndex].articles[articleIndex].isRead {
                    feeds[feedIndex].articles[articleIndex].isRead = true
                    persistenceManager.markArticleAsRead(feeds[feedIndex].articles[articleIndex])
                    markedAny = true
                }
            }
        }
        
        // Mark all unread Reddit posts as read
        for feedIndex in 0..<redditFeeds.count {
            for postIndex in 0..<redditFeeds[feedIndex].posts.count {
                if !redditFeeds[feedIndex].posts[postIndex].isRead {
                    redditFeeds[feedIndex].posts[postIndex].isRead = true
                    persistenceManager.markRedditPostAsRead(redditFeeds[feedIndex].posts[postIndex])
                    markedAny = true
                }
            }
        }
        
        // Log action
        print("📱 AppState: Marked all unread items as read")
        if markedAny {
            scheduleUnreadCacheRebuild()
        }
    }

    func markAllArticlesAsRead(for feedURL: String) {
        guard let feedIndex = feeds.firstIndex(where: { $0.url == feedURL }) else { return }

        var markedCount = 0
        for articleIndex in 0..<feeds[feedIndex].articles.count {
            if !feeds[feedIndex].articles[articleIndex].isRead {
                feeds[feedIndex].articles[articleIndex].isRead = true
                persistenceManager.markArticleAsRead(feeds[feedIndex].articles[articleIndex])
                markedCount += 1
            }
        }

        if markedCount > 0 {
            print("📱 AppState: Marked \(markedCount) articles as read for feed \(feedURL)")

            // Force SwiftUI to detect the change by reassigning the array
            // This ensures the subscription list badge updates immediately
            let updatedFeeds = feeds
            feeds = updatedFeeds
            scheduleUnreadCacheRebuild()
        }
    }

    func markAllRedditPostsAsRead(for subreddit: String) {
        guard let feedIndex = redditFeeds.firstIndex(where: { $0.subreddit == subreddit }) else { return }

        var markedCount = 0
        for postIndex in 0..<redditFeeds[feedIndex].posts.count {
            if !redditFeeds[feedIndex].posts[postIndex].isRead {
                redditFeeds[feedIndex].posts[postIndex].isRead = true
                persistenceManager.markRedditPostAsRead(redditFeeds[feedIndex].posts[postIndex])
                markedCount += 1
            }
        }

        if markedCount > 0 {
            print("📱 AppState: Marked \(markedCount) Reddit posts as read for r/\(subreddit)")

            // Force SwiftUI to detect the change by reassigning the array
            // This ensures the subscription list badge updates immediately
            let updatedFeeds = redditFeeds
            redditFeeds = updatedFeeds
            scheduleUnreadCacheRebuild()
        }
    }

    // Navigate to the next subscription in the sidebar order.
    // Used after marking a subscription as fully read.
    func navigateToNextSubscription(after currentURL: String) {
        guard let currentIndex = subscriptions.firstIndex(where: { $0.url == currentURL }) else { return }
        let nextIndex = currentIndex + 1

        guard nextIndex < subscriptions.count else {
            print("📱 AppState: Already on last subscription, staying here")
            return
        }

        let nextURL = subscriptions[nextIndex].url
        print("📱 AppState: Navigating to next subscription: \(subscriptions[nextIndex].title)")

        // Small delay keeps the mark-all update and badge refresh smooth before navigation.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            withAnimation(.easeInOut(duration: 0.25)) {
                self.activeSubscriptionURL = nextURL
            }
        }
    }

    // MARK: - Local Model Fallback Helper
    private func isContextError(_ error: Error) -> Bool {
        let errorMessage = error.localizedDescription.lowercased()
        
        // Common context/length related errors from Apple Intelligence
        let contextKeywords = [
            "context", "token", "length", "limit", "exceeded",
            "too long", "too large", "maximum", "size",
            "input too large", "content too long", "text too long",
            "request too large", "payload too large", "truncated",
            "buffer", "capacity", "overflow", "quota"
        ]
        
        for keyword in contextKeywords {
            if errorMessage.contains(keyword) {
                return true
            }
        }
        
        // Check error codes that typically indicate context limits
        if let nsError = error as? NSError {
            // Common error codes for context/size limits
            let contextErrorCodes = [413, 422, 400, 431] // Request Entity Too Large, Unprocessable Entity, Bad Request, Request Header Fields Too Large
            if contextErrorCodes.contains(nsError.code) {
                return true
            }
        }
        
        return false
    }

    private let appStateAppleLocalMaxTokens = 4096

    private func isLocalProviderContextError(_ error: Error) -> Bool {
        LiteRTLocalService.isContextTooLargeError(error)
            || CoreAIMLXLocalService.isContextTooLargeError(error)
            || isContextError(error)
    }

    private func estimateTokens(for text: String) -> Int {
        max(1, Int(ceil(Double(text.count) / 4.0)))
    }

    private func estimatedTokensForLocalRouting(_ text: String) -> Int {
        estimateTokens(for: text)
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
                    let answer = try await self.performPCCGatewayRequestAsync(prompt: prompt, taskName: taskName, isQA: isQA)
                    await MainActor.run {
                        self.isLoading = false
                        completion(answer)
                    }
                } catch {
                    await MainActor.run {
                        self.isLoading = false
                        completion("Apple PCC error: \(error.localizedDescription)")
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

        if #available(iOS 18.2, macOS 15.2, *), LocalSummaryService.isAvailable() {
            print("📱 AppState: Trying local model for \(taskName)")
            LocalSummaryService.summarizeText(prompt) { [weak self] result in
                guard let self = self else { return }
                
                switch result {
                case .success(let response):
                    print("✅ AppState: Local model succeeded for \(taskName)")
                    completion(response)
                case .failure(let error):
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
                        onCancel: onCancel,
                        onRouteStart: onRouteStart
                    )
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
                error: NSError(domain: "AppleLocal.Unavailable", code: 1, userInfo: [NSLocalizedDescriptionKey: "Apple Local AI is not available on this device."]),
                completion: completion,
                onCancel: onCancel,
                onRouteStart: onRouteStart
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
            .sink { (answer: String) in
                self.isLoading = false
                print("✅ AppState: Gemini fallback succeeded for \(taskName)")
                completion(answer)
            }
            .store(in: &cancellables)
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
            let prompt = articleQAPrompt(article: article, question: question)
            Task(priority: .userInitiated) { [weak self] in
                guard let self else { return }
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
            return
        }

        if settings.selectedSummaryProvider == .applePCCGateway {
            isLoading = true
            let prompt = articleQAPrompt(article: article, question: question, preferCompleteAnswer: true)
            Task(priority: .userInitiated) { [weak self] in
                guard let self else { return }
                do {
                    let answer = try await self.performPCCGatewayRequestAsync(
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
                        cleanedCompletion("Apple PCC error: \(error.localizedDescription)")
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
            let rawContent = article.content ?? article.title
            let content = rawContent
                .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
                .replacingOccurrences(of: "&nbsp;", with: " ")
                .replacingOccurrences(of: "&quot;", with: "\"")
                .replacingOccurrences(of: "&amp;", with: "&")
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let fallbackPrompt = """
            Article Title: \(article.title)
            Article Content:
            \(content)

            Based solely on the information in the article above, please answer the following question:
            \(question)

            If the answer cannot be determined from the article, please state that the information is not available in the article.
            Respond in plain text only. Do not use Markdown symbols, headings, or code fences.
            For longer answers, use short paragraphs separated by a blank line.
            """
            let context = "Article Title: \(article.title)\nArticle Content:\n\(content)"
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
            if #available(iOS 18.2, macOS 15.2, *), LocalSummaryService.isAvailable() {
                let t0 = Date()
                LocalSummaryService.askQuestion(about: context, question: question) { [weak self] result in
                    guard let self = self else { return }
                    let elapsed = Date().timeIntervalSince(t0)
                    switch result {
                    case .success(let text):
                        Task { @MainActor [weak self] in self?.recordAppleLocalQAThroughput(text: text, elapsed: elapsed) }
                        cleanedCompletion(text)
                    case .failure(let error):
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
            } else {
                presentLocalReroute(
                    providerName: "Apple Local",
                    prompt: fallbackPrompt,
                    taskName: "Article Q&A",
                    appleRequestType: .articleQA,
                    isQA: true,
                    error: NSError(domain: "AppleLocal.Unavailable", code: 1, userInfo: [NSLocalizedDescriptionKey: "Apple Local AI is not available on this device."]),
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
            """

            print("📱 AppState: Using Apple Cloud for Article Q&A")
            launchCloudRequest(for: prompt, type: .articleQA, completion: cleanedCompletion)
            return
        } else if settings.selectedSummaryProvider == .mlxLocal || settings.selectedSummaryProvider == .coreAIMLXLocal {
            // Use MLX Local model for Q&A — use generateTextWithMetrics for accurate tok/s
            // Strip HTML first — raw HTML is 3-5× longer than clean text and inflates prefill time
            let rawContent = article.content ?? article.title
            let content = rawContent
                .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
                .replacingOccurrences(of: "&nbsp;", with: " ")
                .replacingOccurrences(of: "&quot;", with: "\"")
                .replacingOccurrences(of: "&amp;", with: "&")
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
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

            Task { [weak self] in
                guard let self else { return }
                await MainActor.run { self.mlxStreamingText = "" }
                do {
                    let metrics = try await self.summarizeWithMLXLocal(prompt: prompt)
                    await MainActor.run {
                        self.mlxStreamingText = ""
                        self.recordMLXQAThroughput(metrics: metrics)
                        cleanedCompletion(metrics.text)
                    }
                } catch {
                    if self.isLocalProviderContextError(error) {
                        await MainActor.run {
                            self.mlxStreamingText = ""
                            self.presentLocalReroute(
                                providerName: self.selectedLocalProviderName(),
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
                        cleanedCompletion("Error: \(error.localizedDescription)")
                    }
                }
            }
            return
        }

        // Original Gemini code
        isLoading = true

        let prompt = """
        Article Title: \(article.title)
        Article Content:
        \(article.content)
        
        Based solely on the information in the article above, please answer the following question:
        \(question)
        
        If the answer cannot be determined from the article, please state that the information is not available in the article.
        """
        
        summaryService.summarizeText("", customPrompt: prompt)
            .receive(on: RunLoop.main)
            .sink { (answer: String) in
                self.isLoading = false
                print("📱 AppState: Received answer to question")
                cleanedCompletion(answer)
            }
            .store(in: &cancellables)
    }
    
    func askQuestionAboutRedditPost(post: RedditPost, comments: [RedditCommentModel], question: String, completion: @escaping (String) -> Void) {
        print("📱 AppState: Processing question about Reddit post: \"\(question)\"")
        
        // Extract all comment text
        let commentTexts = comments.flatMap { extractAllCommentTexts(from: $0) }
        let combinedComments = commentTexts.joined(separator: "\n\n")

        let cleanedCompletion: (String) -> Void = { [weak self] answer in
            guard let self = self else {
                completion(answer)
                return
            }
            completion(self.cleanAndFormatQATextForDisplay(answer))
        }

        let deliver: (String) -> Void = { raw in
            cleanedCompletion(raw)
        }

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
            let prompt = redditQAPrompt(post: post, comments: comments, question: question)
            Task(priority: .userInitiated) { [weak self] in
                guard let self else { return }
                do {
                    let start = Date()
                    let answer = try await self.summaryService.generateContentWithSummarize(prompt: prompt, settings: self.settings)
                    let elapsed = Date().timeIntervalSince(start)
                    await MainActor.run {
                        self.recordSummarizeThroughput(text: answer, elapsed: elapsed, isQA: true)
                        deliver(answer)
                    }
                } catch {
                    await MainActor.run {
                        deliver("Codex / Summarize error: \(error.localizedDescription)")
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
                    let answer = try await self.performPCCGatewayRequestAsync(
                        prompt: prompt,
                        taskName: "Reddit Q&A",
                        isQA: true
                    )
                    await MainActor.run {
                        self.isLoading = false
                        deliver(answer)
                    }
                } catch {
                    await MainActor.run {
                        self.isLoading = false
                        deliver("Apple PCC error: \(error.localizedDescription)")
                    }
                }
            }
            return
        }

        // Check if we should use Apple Intelligence instead
        if settings.selectedSummaryProvider == .appleLocal {
            // Use LocalSummaryService.askQuestion directly (like article Q&A) to avoid
            // the summarizeText wrapper which prepends "Provide a summary..." and confuses Apple Intelligence
            let fallbackPrompt = """
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
            if estimateTokens(for: fallbackPrompt) > appStateAppleLocalMaxTokens {
                presentLocalReroute(
                    providerName: "Apple Local",
                    prompt: fallbackPrompt,
                    taskName: "Reddit Q&A",
                    appleRequestType: .redditQA,
                    isQA: true,
                    completion: deliver
                )
                return
            }
            if #available(iOS 18.2, macOS 15.2, *), LocalSummaryService.isAvailable() {
                let context = "Reddit Post Title: \(post.title)\nPost Content:\n\(post.content)\n\nComments:\n\(combinedComments)"
                let t0 = Date()
                LocalSummaryService.askQuestion(about: context, question: question) { [weak self] result in
                    guard let self = self else { return }
                    let elapsed = Date().timeIntervalSince(t0)
                    switch result {
                    case .success(let text):
                        Task { @MainActor [weak self] in self?.recordAppleLocalQAThroughput(text: text, elapsed: elapsed) }
                        deliver(text)
                    case .failure(let error):
                        self.presentLocalReroute(
                            providerName: "Apple Local",
                            prompt: fallbackPrompt,
                            taskName: "Reddit Q&A",
                            appleRequestType: .redditQA,
                            isQA: true,
                            error: error,
                            completion: deliver
                        )
                    }
                }
            } else {
                presentLocalReroute(
                    providerName: "Apple Local",
                    prompt: fallbackPrompt,
                    taskName: "Reddit Q&A",
                    appleRequestType: .redditQA,
                    isQA: true,
                    error: NSError(domain: "AppleLocal.Unavailable", code: 1, userInfo: [NSLocalizedDescriptionKey: "Apple Local AI is not available on this device."]),
                    completion: deliver
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

            Based solely on the information in the Reddit post and comments above, answer the following request. Produce ONLY a compact JSON array of paragraph strings (e.g., ["First paragraph.", "Second paragraph."]). Each paragraph must contain no more than 2–3 sentences. Do not include Markdown, headings, bullet points, or code fences. Do not add any commentary outside the JSON array.

            Request:
            \(question)

            If the answer cannot be determined from the post or comments, please return ["The information is not available in the provided content."].
            """

            print("📱 AppState: Using Apple Cloud for Reddit Q&A")
            launchCloudRequest(for: prompt, type: .redditQA, completion: deliver)
            return
        } else if settings.selectedSummaryProvider == .mlxLocal || settings.selectedSummaryProvider == .coreAIMLXLocal {
            // Use MLX Local model for Q&A — use generateTextWithMetrics for accurate tok/s
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

            Task { [weak self] in
                guard let self else { return }
                await MainActor.run { self.mlxStreamingText = "" }
                do {
                    let metrics = try await self.summarizeWithMLXLocal(prompt: prompt)
                    await MainActor.run {
                        self.mlxStreamingText = ""
                        self.recordMLXQAThroughput(metrics: metrics)
                        deliver(metrics.text)
                    }
                } catch {
                    if self.isLocalProviderContextError(error) {
                        await MainActor.run {
                            self.mlxStreamingText = ""
                            self.presentLocalReroute(
                                providerName: self.selectedLocalProviderName(),
                                prompt: prompt,
                                taskName: "Reddit Q&A",
                                appleRequestType: .redditQA,
                                isQA: true,
                                error: error,
                                completion: deliver
                            )
                        }
                        return
                    }
                    await MainActor.run {
                        self.mlxStreamingText = ""
                        deliver("Error: \(error.localizedDescription)")
                    }
                }
            }
            return
        }

        // Original Gemini code
        isLoading = true

        let prompt = """
        Reddit Post Title: \(post.title)
        Post Content:
        \(post.content)
        
        Comments:
        \(combinedComments)
        
        Based solely on the information in the Reddit post and comments above, answer the following request. Produce ONLY a compact JSON array of paragraph strings (e.g., ["First paragraph.", "Second paragraph."]). Each paragraph must contain no more than 2–3 sentences. Do not include Markdown, headings, bullet points, or code fences. Do not add any commentary outside the JSON array.

        Request:
        \(question)
        
        If the answer cannot be determined from the post or comments, please return ["The information is not available in the provided content."].
        """
        
        summaryService.summarizeText("", customPrompt: prompt)
            .receive(on: RunLoop.main)
            .sink { (answer: String) in
                self.isLoading = false
                print("📱 AppState: Received answer to Reddit question")
                deliver(answer)
            }
            .store(in: &cancellables)
    }
    
    // MARK: - Global Summary Q&A
    
    func askQuestionAboutGlobalSummary(question: String, completion: @escaping (String) -> Void) {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            completion("Please enter a question to ask about the summary overview.")
            return
        }
        guard lastGlobalSummaryContext != nil else {
            completion("Generate a summary overview first, then try asking a question.")
            return
        }
        
        if !globalSummaryArticles.isEmpty {
            let articles = globalSummaryArticles
            let prompt = buildGlobalArticlesQuestionPrompt(articles: articles, question: trimmed)
            executeGlobalQAPrompt(prompt: prompt, completion: completion)
            return
        }
        
        if !globalSummaryPosts.isEmpty {
            let posts = globalSummaryPosts
            
            // Use cached comments if available, otherwise fetch and cache
            if !globalSummaryComments.isEmpty {
                // Use cached comments
                let usableContexts = globalSummaryComments.filter { !$0.1.isEmpty || !self.sanitizedSnippet(from: $0.0.content, limit: 800).isEmpty }
                guard !usableContexts.isEmpty else {
                    completion("Unable to use cached Reddit comments. Please try regenerating the summary.")
                    return
                }
                let prompt = self.buildGlobalRedditQuestionPrompt(contexts: usableContexts, question: trimmed)
                self.executeGlobalQAPrompt(prompt: prompt, completion: completion)
            } else {
                // Fetch comments and cache them for future questions
                let topComments = topCommentsCount(for: lastGlobalSummaryContext) ?? 3
                fetchCommentsForGlobalSummary(posts: posts, topComments: topComments) { [weak self] contexts in
                    guard let self = self else { return }
                    
                    // Cache the comments for future Q&A
                    self.globalSummaryComments = contexts
                    
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
    
    private func executeGlobalQAPrompt(prompt: String, completion: @escaping (String) -> Void) {
        let deliver: (String) -> Void = { [weak self] rawAnswer in
            guard let self else {
                completion(rawAnswer)
                return
            }
            completion(self.cleanMarkdownArtifactsForDisplay(rawAnswer))
        }

        switch settings.selectedSummaryProvider {
        case .appleLocal:
            performLocalWithGeminiFallback(prompt: prompt, taskName: "Global Summary Q&A", completion: deliver)
        case .appleCloud:
            launchCloudRequest(for: prompt, type: .globalSummaryQA, completion: deliver)
        case .applePCCGateway:
            Task(priority: .userInitiated) {
                do {
                    let answer = try await self.performPCCGatewayRequestAsync(
                        prompt: prompt,
                        taskName: "Global Summary Q&A",
                        isQA: true
                    )
                    await MainActor.run {
                        deliver(answer)
                    }
                } catch {
                    await MainActor.run {
                        deliver("Apple PCC error: \(error.localizedDescription)")
                    }
                }
            }
        case .mlxLocal, .coreAIMLXLocal:
            performMLXLocalSummary(prompt: prompt, completion: deliver)
        case .webAI:
            performWebAIRequest(
                title: "Global Summary Q&A",
                prompt: prompt,
                onSuccess: deliver,
                onFailure: { deliver($0) }
            )
        case .summarizeDaemon:
            Task(priority: .userInitiated) { [weak self] in
                guard let self else { return }
                do {
                    let start = Date()
                    let answer = try await self.summaryService.generateContentWithSummarize(prompt: prompt, settings: self.settings)
                    let elapsed = Date().timeIntervalSince(start)
                    await MainActor.run {
                        self.recordSummarizeThroughput(text: answer, elapsed: elapsed, isQA: true)
                        deliver(answer)
                    }
                } catch {
                    await MainActor.run {
                        deliver("Codex / Summarize error: \(error.localizedDescription)")
                    }
                }
            }
        case .gemini:
            summaryService.summarizeText("", customPrompt: prompt)
                .receive(on: RunLoop.main)
                .sink { answer in
                    deliver(answer)
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
        - Return plain text only; do not use Markdown symbols like #, *, _, `, or code fences.
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
        - Return plain text only; do not use Markdown symbols like #, *, _, `, or code fences.
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
                    if let errorDesc = result.errorDescription {
                        print("⚠️ AppState.GlobalQA: Comment fetch error for \(post.id): \(errorDesc)")
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
    
    private func topCommentsCount(for context: GlobalSummaryContext?) -> Int? {
        guard let context = context else { return nil }
        switch context {
        case .reddit(_, let count), .subreddit(_, let count), .subredditHot(_, let count), .subredditSorted(_, _, let count):
            return count
        case .todayReddit:
            return 10 // Default for today's Reddit
        default:
            return nil
        }
    }

    func cleanMarkdownArtifactsForDisplay(_ input: String) -> String {
        var value = input
        value = value.replacingOccurrences(of: "\r\n", with: "\n")
        value = value.replacingOccurrences(of: "\r", with: "\n")
        value = value.replacingOccurrences(of: #"\\r\\n"#, with: "\n", options: .regularExpression)
        value = value.replacingOccurrences(of: #"\\n"#, with: "\n", options: .regularExpression)
        value = value.replacingOccurrences(of: #"\\r"#, with: "\n", options: .regularExpression)
        value = value.replacingOccurrences(of: #"(?m)^```[a-zA-Z0-9_-]*\s*$"#, with: "", options: .regularExpression)
        value = value.replacingOccurrences(of: "```", with: "")
        value = value.replacingOccurrences(of: "\\*\\*(.*?)\\*\\*", with: "$1", options: .regularExpression)
        value = value.replacingOccurrences(of: "\\*(.*?)\\*", with: "$1", options: .regularExpression)
        value = value.replacingOccurrences(of: "__(.*?)__", with: "$1", options: .regularExpression)
        value = value.replacingOccurrences(of: "_(.*?)_", with: "$1", options: .regularExpression)
        value = value.replacingOccurrences(of: "`([^`]*)`", with: "$1", options: .regularExpression)
        value = value.replacingOccurrences(of: "(?m)^\\s{0,3}#{1,6}\\s*", with: "", options: .regularExpression)
        value = value.replacingOccurrences(of: "(?m)(^\\s*[-•]?\\s*)#{1,6}\\s*", with: "$1", options: .regularExpression)
        value = value.replacingOccurrences(of: "(?m)^\\s*\\*\\s+", with: "- ", options: .regularExpression)
        value = value.replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func cleanAndFormatQATextForDisplay(_ input: String) -> String {
        var value = cleanMarkdownArtifactsForDisplay(input)
        guard !value.isEmpty else { return value }

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
    
    func formatLLMAnswer(_ text: String) -> String {
        var result = text
            // Normalize escaped line sequences that sometimes come back from the model
            .replacingOccurrences(of: #"\\r\\n"#, with: "\n", options: .regularExpression)
            .replacingOccurrences(of: #"\\n"#, with: "\n", options: .regularExpression)
            .replacingOccurrences(of: #"\\r"#, with: "\n", options: .regularExpression)
            // Normalize platform carriage returns
            .replacingOccurrences(of: #"\r\n|\r"#, with: "\n", options: .regularExpression)
            // Unescape markdown control characters before sanitizing to plain text
            .replacingOccurrences(of: #"\\([\\`*_~+\-\[\]()#!|>])"#, with: "$1", options: .regularExpression)

        // Remove markdown heading markers (e.g. ## Theme 1)
        result = result.replacingOccurrences(
            of: #"(?m)^[ \t]{0,3}#{1,6}[ \t]*"#,
            with: "",
            options: .regularExpression
        )

        // Remove fenced code blocks if they appear
        result = result
            .replacingOccurrences(of: #"(?m)^```[a-zA-Z0-9_-]*\s*$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "```", with: "")

        // Normalize bullet markers (•, –, —, *) into plain hyphen bullets
        result = result
            .replacingOccurrences(of: #"(?m)^[ \t]*[•–—]\s+"#, with: "- ", options: .regularExpression)
            .replacingOccurrences(of: #"(?m)^[ \t]*\*\s+"#, with: "- ", options: .regularExpression)

        // Strip markdown emphasis markers while keeping text content
        result = result
            .replacingOccurrences(of: #"\*\*([^*]+)\*\*"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"__([^_]+)__"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"`([^`]+)`"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"(?m)(?<!\*)\*([^*\n]+)\*(?!\*)"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"(?m)(?<!_)_([^_\n]+)_(?!_)"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"~~([^~]+)~~"#, with: "$1", options: .regularExpression)

        // Ensure list markers start on their own lines and have a blank line before the block
        result = result
            .replacingOccurrences(of: #"(?<!\n)(-\s)"#, with: "\n$1", options: .regularExpression)
            .replacingOccurrences(of: #"(?<!\n)(\d+\.\s)"#, with: "\n$1", options: .regularExpression)
            .replacingOccurrences(of: #"(?<!\n)([A-Z]\)\s)"#, with: "\n$1", options: .regularExpression)
            .replacingOccurrences(of: #"(?<!\n\n)(\n-\s)"#, with: "\n\n$1", options: .regularExpression)
            .replacingOccurrences(of: #"(?<!\n\n)(\n\d+\.\s)"#, with: "\n\n$1", options: .regularExpression)
            .replacingOccurrences(of: #"(?<!\n\n)(\n[A-Z]\)\s)"#, with: "\n\n$1", options: .regularExpression)

        // Insert a space if punctuation is jammed against the next token (e.g., "ecosystem.Enjoy")
        result = result.replacingOccurrences(of: #"([.!?])(?=[A-Za-z0-9\"“”'‘’`(])"#, with: "$1 ", options: .regularExpression)

        // Break sentences into separate paragraphs for readability
        result = result.replacingOccurrences(
            of: #"([.!?])\s+(?=[A-Za-z0-9\"“”'‘’`(])"#,
            with: "$1\n\n",
            options: .regularExpression
        )

        // Break colon-delimited sections (e.g., "Heading:Details") into their own paragraphs
        result = result
            .replacingOccurrences(
                of: #"(?<=:)\s*(?=[A-Za-z0-9\"“”'‘’`(])"#,
                with: "\n\n",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"(?<=:)(?=[A-Za-z0-9\"“”'‘’`(])"#,
                with: "\n\n",
                options: .regularExpression
            )

        // Collapse leftover indentation and excessive blank lines
        result = result
            .replacingOccurrences(of: #"\n[ \t]+"#, with: "\n", options: .regularExpression)
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return result.isEmpty ? text : result
    }
    
    // Helper function to extract all comment texts recursively
    func extractAllCommentTexts(from comment: RedditCommentModel) -> [String] {
        var texts = ["u/\(comment.author): \(comment.body)"]

        for reply in comment.replies {
            texts.append(contentsOf: extractAllCommentTexts(from: reply))
        }

        return texts
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

    private func selectedLocalProviderName() -> String {
        settings.selectedSummaryProvider == .coreAIMLXLocal ? "CoreAI MLX" : "LiteRT"
    }

    private func localPromptFits(_ prompt: String, outputTokens: Int? = nil) async -> Bool {
        switch settings.selectedSummaryProvider {
        case .mlxLocal:
            let maxOutputTokens = outputTokens ?? settings.mlxMaxOutputTokens
            let maxContextTokens = AppSettings.effectiveLiteRTContextTokens(settings.mlxMaxContextTokens)
            return await LiteRTLocalService.shared.promptFits(
                prompt,
                maxOutputTokens: AppSettings.normalizedLiteRTOutputTokens(maxOutputTokens, contextTokens: maxContextTokens),
                maxContextTokens: maxContextTokens
            )
        case .coreAIMLXLocal:
            let maxOutputTokens = outputTokens ?? settings.coreAIMLXMaxOutputTokens
            let maxContextTokens = AppSettings.effectiveCoreAIMLXContextTokens(settings.coreAIMLXMaxContextTokens)
            return await CoreAIMLXLocalService.shared.promptFits(
                prompt,
                maxOutputTokens: AppSettings.normalizedCoreAIMLXOutputTokens(maxOutputTokens, contextTokens: maxContextTokens),
                maxContextTokens: maxContextTokens
            )
        case .appleLocal:
            return estimateTokens(for: prompt) <= appStateAppleLocalMaxTokens
        default:
            return true
        }
    }

    // MARK: - MLX Local Summary
    private func performMLXLocalSummary(
        prompt: String,
        completion: @escaping (String) -> Void
    ) {
        print("🧠 AppState: Using \(settings.selectedSummaryProvider.displayName) for summary")
        isLoading = true

        Task {
            await MainActor.run { self.mlxStreamingText = "" }
            if await self.localPromptFits(prompt) == false {
                await MainActor.run {
                    self.presentLocalReroute(
                        providerName: self.selectedLocalProviderName(),
                        prompt: prompt,
                        taskName: "Summary",
                        completion: completion
                    )
                }
                return
            }

            do {
                let metrics = try await summarizeWithMLXLocal(prompt: prompt)

                await MainActor.run {
                    self.mlxStreamingText = ""
                    self.isLoading = false
                    self.recordMLXThroughput(metrics: metrics)
                    print("✅ AppState: \(self.settings.selectedSummaryProvider.displayName) succeeded")
                    completion(metrics.text)
                }
            } catch {
                if self.isLocalProviderContextError(error) {
                    await MainActor.run {
                        self.mlxStreamingText = ""
                        self.isLoading = false
                        self.presentLocalReroute(
                            providerName: self.selectedLocalProviderName(),
                            prompt: prompt,
                            taskName: "Summary",
                            error: error,
                            completion: completion
                        )
                    }
                    return
                }

                await MainActor.run {
                    self.mlxStreamingText = ""
                    self.isLoading = false
                    print("❌ AppState: \(self.settings.selectedSummaryProvider.displayName) failed: \(error.localizedDescription)")
                    completion("\(self.settings.selectedSummaryProvider.displayName) error: \(error.localizedDescription)")
                }
            }
        }
    }

    /// Core MLX Local summarization with validation — returns metrics
    private func summarizeWithMLXLocal(prompt: String) async throws -> MLXGenerationMetrics {
        let useCoreAIMLX = settings.selectedSummaryProvider == .coreAIMLXLocal
        let modelID = (useCoreAIMLX ? settings.coreAIMLXModelID : settings.mlxModelID)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !modelID.isEmpty else {
            throw NSError(
                domain: "SummaryService.MLXLocal",
                code: 0,
                userInfo: [NSLocalizedDescriptionKey: "\(settings.selectedSummaryProvider.displayName) model id is missing. Set it in Settings -> Summary Provider."]
            )
        }

        let isGemma4External = useCoreAIMLX ? await MLXLocalService.shared.isGemma4ExternalModel(modelID: modelID) : false
        let isGemma4 = useCoreAIMLX && (isGemma4ModelID(modelID) || isGemma4External)
        let configuredOutput = useCoreAIMLX ? settings.coreAIMLXMaxOutputTokens : settings.mlxMaxOutputTokens
        let configuredContext = useCoreAIMLX ? settings.coreAIMLXMaxContextTokens : settings.mlxMaxContextTokens
        let effectiveContext = useCoreAIMLX
            ? AppSettings.effectiveCoreAIMLXContextTokens(configuredContext)
            : AppSettings.effectiveLiteRTContextTokens(configuredContext)
        let maxOutputTokens = useCoreAIMLX
            ? (isGemma4 ? min(max(1, configuredOutput), 160) : AppSettings.normalizedCoreAIMLXOutputTokens(configuredOutput, contextTokens: effectiveContext))
            : AppSettings.normalizedLiteRTOutputTokens(configuredOutput, contextTokens: effectiveContext)
        let maxContextTokens = effectiveContext

        let summaryPrompt = isGemma4 ? adaptedPromptForGemma4Summary(prompt) : prompt
        let systemPrompt = isGemma4 ? gemma4SummarySystemPrompt() : nil

        if useCoreAIMLX {
            return try await CoreAIMLXLocalService.shared.generateTextWithMetrics(
                prompt: summaryPrompt,
                systemPrompt: systemPrompt,
                modelID: modelID,
                maxOutputTokens: maxOutputTokens,
                maxContextTokens: maxContextTokens,
                onToken: { [weak self] chunk in
                    Task { @MainActor [weak self] in self?.mlxStreamingText += chunk }
                }
            )
        }

        return try await LiteRTLocalService.shared.generateTextWithMetrics(
            prompt: summaryPrompt,
            systemPrompt: systemPrompt,
            modelID: modelID,
            maxOutputTokens: maxOutputTokens,
            maxContextTokens: maxContextTokens,
            onToken: { [weak self] chunk in
                Task { @MainActor [weak self] in self?.mlxStreamingText += chunk }
            }
        )
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
        if #available(macOS 15.2, *), LocalSummaryService.isAvailable() {
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

    // MARK: - Throughput Recording

    private func recordMLXThroughput(metrics: MLXGenerationMetrics) {
        guard metrics.tokenCount > 0 else { return }
        let tokPerSec = String(format: "%.1f", metrics.tokensPerSecond)
        let tokens = metrics.tokenCount
        mlxLastThroughput = "MLX · \(tokPerSec) tok/s · \(tokens) tokens"
    }

    private func recordMLXQAThroughput(metrics: MLXGenerationMetrics) {
        guard metrics.tokenCount > 0 else { return }
        let tokPerSec = String(format: "%.1f", metrics.tokensPerSecond)
        let tokens = metrics.tokenCount
        mlxLastQAThroughput = "MLX · \(tokPerSec) tok/s · \(tokens) tokens"
    }

    private func recordAppleLocalThroughput(text: String, elapsed: TimeInterval) {
        let wordCount = text.split(separator: " ").count
        guard wordCount > 0, elapsed > 0 else { return }
        // Approximate 0.75 words per token
        let approxTokens = max(1, Int(Double(wordCount) / 0.75))
        let tokPerSec = String(format: "%.1f", Double(approxTokens) / elapsed)
        mlxLastThroughput = "Apple · \(tokPerSec) tok/s · ~\(approxTokens) tokens"
    }

    private func recordAppleLocalQAThroughput(text: String, elapsed: TimeInterval) {
        let wordCount = text.split(separator: " ").count
        guard wordCount > 0, elapsed > 0 else { return }
        let approxTokens = max(1, Int(Double(wordCount) / 0.75))
        let tokPerSec = String(format: "%.1f", Double(approxTokens) / elapsed)
        mlxLastQAThroughput = "Apple · \(tokPerSec) tok/s · ~\(approxTokens) tokens"
    }

    @MainActor
    private func recordSummarizeThroughput(text: String, elapsed: TimeInterval, isQA: Bool = false) {
        let wordCount = text.split(separator: " ").count
        guard wordCount > 0, elapsed > 0 else { return }
        let approxTokens = max(1, Int(Double(wordCount) / 0.75))
        let tokPerSec = String(format: "%.1f", Double(approxTokens) / elapsed)
        let label = "Codex/Summarize · \(tokPerSec) tok/s · ~\(approxTokens) tokens"
        if isQA {
            mlxLastQAThroughput = label
        } else {
            mlxLastThroughput = label
        }
    }

    @MainActor
    private func recordPCCGatewayThroughput(text: String, elapsed: TimeInterval, isQA: Bool = false) {
        let wordCount = text.split(separator: " ").count
        guard wordCount > 0, elapsed > 0 else { return }
        let approxTokens = max(1, Int(Double(wordCount) / 0.75))
        let tokPerSec = String(format: "%.1f", Double(approxTokens) / elapsed)
        let label = "Apple PCC · \(tokPerSec) tok/s · ~\(approxTokens) tokens"
        if isQA {
            mlxLastQAThroughput = label
        } else {
            mlxLastThroughput = label
        }
    }

    func recordAppleLocalThroughputPublic(text: String, elapsed: TimeInterval) {
        recordAppleLocalThroughput(text: text, elapsed: elapsed)
    }

    // MARK: - Warm-up

    func warmUpMLXIfNeeded() async {
        let provider = settings.selectedSummaryProvider
        guard provider == .mlxLocal || provider == .coreAIMLXLocal else { return }
        let useCoreAIMLX = provider == .coreAIMLXLocal
        let modelID = (useCoreAIMLX ? settings.coreAIMLXModelID : settings.mlxModelID).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !modelID.isEmpty else { return }
        print("🔥 AppState: Warming up \(provider.displayName) model \(modelID)")
        do {
            if useCoreAIMLX {
                try await CoreAIMLXLocalService.shared.warmUpConfiguredModel(
                    modelID: modelID,
                    maxContextTokens: AppSettings.effectiveCoreAIMLXContextTokens(settings.coreAIMLXMaxContextTokens)
                )
                await CoreAIMLXLocalService.shared.clearTransientCache()
            } else {
                try await LiteRTLocalService.shared.warmUpConfiguredModel(
                    modelID: modelID,
                    maxContextTokens: AppSettings.effectiveLiteRTContextTokens(settings.mlxMaxContextTokens)
                )
                await LiteRTLocalService.shared.clearTransientCache()
            }
            print("✅ AppState: \(provider.displayName) warm-up complete")
        } catch {
            print("⚠️ AppState: \(provider.displayName) warm-up error (non-fatal): \(error.localizedDescription)")
        }
    }

    // MARK: - Deep Analysis (no Gemini fallback)

    /// Apple Local deep analysis — no Gemini fallback
    func performAppleLocalOnlyPublic(
        prompt: String,
        taskName: String,
        completion: @escaping (String) -> Void
    ) {
        print("📱 AppState: Apple Local only (no fallback) for \(taskName)")
        if #available(iOS 18.2, macOS 15.2, *), LocalSummaryService.isAvailable() {
            LocalSummaryService.summarizeText(prompt) { result in
                switch result {
                case .success(let text):
                    completion(text)
                case .failure(let error):
                    completion("Apple Local error: \(error.localizedDescription)")
                }
            }
        } else {
            completion("Apple Local is not available on this device.")
        }
    }

    /// MLX deep analysis — higher token cap (2048) for long-form output
    func performMLXLocalAnalysisPublic(
        prompt: String,
        completion: @escaping (String) -> Void
    ) {
        let modelID = settings.mlxModelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !modelID.isEmpty else {
            completion("MLX model ID not configured. Please set it in Settings.")
            return
        }
        let maxContextTokens = settings.mlxMaxContextTokens > 0 ? settings.mlxMaxContextTokens : 4096
        // Deep analysis gets 2048 output tokens instead of the normal summary cap
        let maxOutputTokens = 2048
        let maxPromptChars = (maxContextTokens - maxOutputTokens - 100) * 4
        let truncatedPrompt = prompt.count > maxPromptChars
            ? String(prompt.prefix(maxPromptChars)) + "\n\n[Content truncated.]"
            : prompt

        Task { [weak self] in
            guard let self else { return }
            await MainActor.run { self.mlxStreamingText = "" }
            do {
                let metrics = try await MLXLocalService.shared.generateTextWithMetrics(
                    prompt: truncatedPrompt,
                    modelID: modelID,
                    maxOutputTokens: maxOutputTokens,
                    maxContextTokens: maxContextTokens,
                    onToken: { [weak self] chunk in
                        Task { @MainActor [weak self] in self?.mlxStreamingText += chunk }
                    }
                )
                await MainActor.run {
                    self.mlxStreamingText = ""
                    self.recordMLXThroughput(metrics: metrics)
                    completion(metrics.text)
                }
            } catch {
                await MainActor.run {
                    self.mlxStreamingText = ""
                    completion("MLX analysis error: \(error.localizedDescription)")
                }
            }
        }
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
