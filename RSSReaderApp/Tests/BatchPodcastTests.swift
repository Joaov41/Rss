import XCTest
@testable import RSSReaderApp

final class BatchPodcastTests: XCTestCase {
    func testRedditContextIncludesEverySavedCommentAndSummary() throws {
        let post = makePost(id: "post-1", title: "Saved post", content: "Post body", summary: "Saved post summary")
        let result = GlobalSummaryResult(
            source: "reddit",
            summaries: [GlobalSummaryItem(subject: "Saved post", summary: "Saved post summary", referenceId: "post-1")],
            error: nil
        )

        let context = try BatchPodcastContextBuilder.build(
            snapshot: BatchPodcastSnapshot(
                posts: [post],
                articles: [],
                cachedComments: [(post, ["First saved comment", "Second saved comment"])],
                summaryResult: result,
                overallSummary: "Saved overall summary"
            ),
            allowSummariesOnly: false,
            maximumCharacters: 10_000
        )

        XCTAssertTrue(context.sources.contains { $0.sourceID == "reddit-post:post-1" })
        XCTAssertEqual(context.sources.filter { $0.kind == .redditComment }.count, 2)
        XCTAssertTrue(context.evidenceChunks.contains { $0.text.contains("First saved comment") })
        XCTAssertTrue(context.evidenceChunks.contains { $0.text.contains("Second saved comment") })
        XCTAssertFalse(context.isSummariesOnly)
    }

    func testArticleContextUsesLoadedContentWithoutFetching() throws {
        let article = makeArticle(id: "article-1", content: "Loaded article body")
        let result = GlobalSummaryResult(
            source: "articles",
            summaries: [GlobalSummaryItem(subject: article.title, summary: "Saved article summary", referenceId: article.id)],
            error: nil
        )

        let context = try BatchPodcastContextBuilder.build(
            snapshot: BatchPodcastSnapshot(
                posts: [],
                articles: [article],
                cachedComments: [],
                summaryResult: result,
                overallSummary: nil
            ),
            allowSummariesOnly: false
        )

        XCTAssertTrue(context.evidenceChunks.contains { $0.text.contains("Loaded article body") })
        XCTAssertTrue(context.sources.contains { $0.sourceID == "article:article-1" })
    }

    func testSummariesOnlyRequiresExplicitOptInAndRetainsSavedSummaries() throws {
        let post = makePost(id: "post-2", title: "Summary-only post", content: "", summary: nil)
        let result = GlobalSummaryResult(
            source: "reddit",
            summaries: [GlobalSummaryItem(subject: post.title, summary: "Only the saved summary is available.", referenceId: post.id)],
            error: nil
        )
        let snapshot = BatchPodcastSnapshot(
            posts: [post],
            articles: [],
            cachedComments: [(post, [])],
            summaryResult: result,
            overallSummary: nil
        )

        XCTAssertThrowsError(try BatchPodcastContextBuilder.build(snapshot: snapshot, allowSummariesOnly: false)) { error in
            XCTAssertEqual(error as? BatchPodcastError, .summariesOnlyRequiresExplicitOptIn)
        }
        let context = try BatchPodcastContextBuilder.build(snapshot: snapshot, allowSummariesOnly: true)
        XCTAssertTrue(context.isSummariesOnly)
        XCTAssertTrue(context.evidenceChunks.contains { $0.text.contains("Only the saved summary") })
    }

    func testDigestChangesWhenSavedEvidenceChanges() throws {
        let post = makePost(id: "post-3", title: "Digest post", content: "Original body", summary: nil)
        let result = GlobalSummaryResult(source: "reddit", summaries: [], error: nil)
        let first = try BatchPodcastContextBuilder.build(
            posts: [post], articles: [], cachedComments: [(post, ["comment"])],
            summaryResult: result, overallSummary: "Overall one", allowSummariesOnly: false
        )
        let changedPost = makePost(id: "post-3", title: "Digest post", content: "Changed body", summary: nil)
        let second = try BatchPodcastContextBuilder.build(
            posts: [changedPost], articles: [], cachedComments: [(changedPost, ["comment"])],
            summaryResult: result, overallSummary: "Overall one", allowSummariesOnly: false
        )
        XCTAssertNotEqual(first.sourceDigest, second.sourceDigest)
    }

    func testJSONDecoderRepairShapesAndSpokenCleanup() throws {
        let raw = """
        ```json
        {"schemaVersion":1,"title":"Episode","summary":"Summary","sourceDigest":"digest","createdAt":"2026-08-04T00:00:00Z","turns":[{"id":"00000000-0000-0000-0000-000000000001","speaker":"A","text":"Host A: Read [a source](https://example.com) and evidence-1.","sourceIDs":["reddit-post:post-1","missing"]}]}
        ```
        """
        let draft = BatchPodcastJSONDecoder.decode(PodcastDraftEpisode.self, from: raw)
        XCTAssertEqual(draft?.turns.count, 1)
        XCTAssertEqual(draft?.turns.first?.speaker, .hostA)

        let spoken = PodcastSpokenTextCleaner.clean(draft?.turns.first?.text ?? "")
        XCTAssertFalse(spoken.contains("https://"))
        XCTAssertFalse(spoken.contains("evidence-1"))
        XCTAssertFalse(spoken.contains("reddit-post:"))
        XCTAssertFalse(spoken.hasPrefix("Host A:"))
    }

    func testMalformedScriptGetsOneRepairAndUnknownSourceRefsAreDropped() async throws {
        let post = makePost(id: "post-5", title: "Repair post", content: "Saved body", summary: nil)
        let context = try BatchPodcastContextBuilder.build(
            posts: [post], articles: [], cachedComments: [(post, ["Saved comment"])],
            summaryResult: GlobalSummaryResult(source: "reddit", summaries: [], error: nil),
            overallSummary: "Saved overall", allowSummariesOnly: false
        )
        let log = PromptLog()
        let service = BatchPodcastService { prompt, _ in
            log.append(prompt)
            if prompt.contains("Reduce only this saved") {
                return "{\"claims\":[\"A saved fact\"],\"tensions\":[],\"unknowns\":[]}"
            }
            if prompt.contains("Build a compact conversational outline") {
                return "{\"title\":\"Repair\",\"summary\":\"Saved\",\"beats\":[]}"
            }
            if prompt.contains("Write a natural two-host podcast script") {
                return "not JSON"
            }
            return """
            {"id":"00000000-0000-0000-0000-000000000003","schemaVersion":1,"sourceDigest":"\(context.sourceDigest)","turns":[{"speaker":"hostB","text":"A grounded point.","sourceIDs":["reddit-post:post-5","missing"]},{"speaker":"hostA","text":"An ungrounded point.","sourceIDs":["missing"]}]}
            """
        }

        let episode = try await service.generateEpisode(from: context)
        XCTAssertEqual(log.prompts.filter { $0.contains("Repair the attempted podcast JSON") }.count, 1)
        XCTAssertTrue(episode.turns.contains { $0.speaker == .hostB })
        XCTAssertTrue(episode.turns.allSatisfy { $0.sourceIDs.allSatisfy(context.knownSourceIDs.contains) })
        XCTAssertEqual(episode.turns.filter { $0.text == "An ungrounded point." }.count, 1)
        XCTAssertTrue(episode.turns.first { $0.text == "An ungrounded point." }?.sourceIDs.isEmpty == true)
    }

    func testUnknownSpeakerIsRejectedAndWordLimitIsAutomatic() throws {
        let invalid = #"{"schemaVersion":1,"title":"x","summary":"x","turns":[{"speaker":"Host C","text":"x"}]}"#
        XCTAssertNil(BatchPodcastJSONDecoder.decode(PodcastDraftEpisode.self, from: invalid))

        let longText = String(repeating: "word ", count: PodcastEpisode.maximumWords + 25)
        let episode = PodcastEpisode(title: "Long", summary: "", sourceDigest: "d", turns: [PodcastTurn(speaker: .hostA, text: longText)])
        XCTAssertLessThanOrEqual(PodcastEpisodeWordLimiter.limit(episode).spokenWordCount, PodcastEpisode.maximumWords)
    }

    func testEveryEvidenceChunkParticipatesInBoundedReduction() async throws {
        let post = makePost(id: "post-4", title: "Pipeline post", content: "Body", summary: nil)
        let result = GlobalSummaryResult(source: "reddit", summaries: [], error: nil)
        let context = try BatchPodcastContextBuilder.build(
            posts: [post], articles: [], cachedComments: [(post, ["Comment one", "Comment two"])],
            summaryResult: result, overallSummary: "Overall", allowSummariesOnly: false
        )
        let log = PromptLog()
        let service = BatchPodcastService { prompt, _ in
            log.append(prompt)
            if prompt.contains("Reduce only this saved") {
                return "{\"claims\":[\"Saved fact\"],\"tensions\":[],\"unknowns\":[]}"
            }
            if prompt.contains("Build a compact conversational outline") {
                return "{\"title\":\"Pipeline\",\"summary\":\"Saved summary\",\"beats\":[]}"
            }
            return """
            {"id":"00000000-0000-0000-0000-000000000002","schemaVersion":1,"title":"Pipeline","summary":"Saved summary","sourceDigest":"\(context.sourceDigest)","createdAt":"2026-08-04T00:00:00Z","turns":[{"speaker":"hostA","text":"The saved evidence gives us one grounded point.","evidenceRefs":["evidence-1"]},{"speaker":"hostB","text":"And we should keep the limits of that evidence clear.","evidenceRefs":["evidence-1"]}]}
            """
        }

        let episode = try await service.generateEpisode(from: context)
        XCTAssertEqual(episode.sourceDigest, context.sourceDigest)
        XCTAssertEqual(log.prompts.filter { $0.contains("Reduce only this saved") }.count, context.evidenceChunks.count)
        for chunk in context.evidenceChunks {
            XCTAssertTrue(log.prompts.contains { $0.contains(chunk.text) })
        }
    }

    func testCancelledGenerationStopsBeforeCompletingAllChunks() async throws {
        let post = makePost(id: "post-6", title: "Cancellation post", content: String(repeating: "body ", count: 40), summary: nil)
        let context = try BatchPodcastContextBuilder.build(
            posts: [post], articles: [], cachedComments: [(post, ["comment one", "comment two"])],
            summaryResult: GlobalSummaryResult(source: "reddit", summaries: [], error: nil),
            overallSummary: nil, allowSummariesOnly: false, maximumCharacters: 12
        )
        let service = BatchPodcastService { _, _ in
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 1_000_000_000)
            return "{}"
        }
        let task = Task { try await service.generateEpisode(from: context) }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Cancelled podcast generation unexpectedly completed")
        } catch is CancellationError {
            // Expected cancellation path.
        }
    }

    func testVoiceAssignmentAndChunking() {
        let episode = PodcastEpisode(
            title: "Voices",
            summary: "",
            sourceDigest: "d",
            turns: [
                PodcastTurn(speaker: .hostA, text: String(repeating: "A ", count: 120)),
                PodcastTurn(speaker: .hostB, text: "B turn.")
            ]
        )
        let chunks = MLXPodcastPlaybackPlan.chunks(for: episode)
        XCTAssertGreaterThan(chunks.count, 2)
        XCTAssertEqual(MLXPodcastPlaybackPlan.voice(for: .hostA, hostAVoice: .alba, hostBVoice: .marius), .alba)
        XCTAssertEqual(MLXPodcastPlaybackPlan.voice(for: .hostB, hostAVoice: .alba, hostBVoice: .marius), .marius)
        XCTAssertTrue(chunks.contains { $0.isSpeakerChange })
    }

    func testWAVWriterProducesOneContinuousPCMDataChunk() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rss-podcast-test-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try BatchPodcastWAVWriter(url: url)
        try writer.append(wavData: makeWAV(samples: [1, 2]))
        try writer.append(wavData: makeWAV(samples: [3, 4, 5]))
        try writer.finish()

        let data = try Data(contentsOf: url)
        XCTAssertEqual(String(bytes: data[0..<4], encoding: .ascii), "RIFF")
        XCTAssertEqual(String(bytes: data[8..<12], encoding: .ascii), "WAVE")
        XCTAssertEqual(readUInt32(data, offset: 40), 10)
    }

    private func makePost(id: String, title: String, content: String, summary: String?) -> RedditPost {
        RedditPost(
            id: id, title: title, content: content, url: URL(string: "https://reddit.example/\(id)"),
            publishDate: Date(timeIntervalSince1970: 1), author: "author", subreddit: "test",
            score: 1, commentCount: 2, summary: summary
        )
    }

    private func makeArticle(id: String, content: String) -> Article {
        Article(
            id: id, title: "Article \(id)", content: content, url: URL(string: "https://example.com/\(id)"),
            publishDate: Date(timeIntervalSince1970: 1), feedTitle: "Feed", feedURL: "https://example.com/feed"
        )
    }

    private func makeWAV(samples: [Int16]) -> Data {
        var data = Data()
        func appendASCII(_ value: String) { data.append(contentsOf: value.utf8) }
        func appendUInt32(_ value: UInt32) { data.append(contentsOf: [UInt8(value & 0xff), UInt8((value >> 8) & 0xff), UInt8((value >> 16) & 0xff), UInt8((value >> 24) & 0xff)]) }
        func appendUInt16(_ value: UInt16) { data.append(contentsOf: [UInt8(value & 0xff), UInt8((value >> 8) & 0xff)]) }
        let byteCount = UInt32(samples.count * 2)
        appendASCII("RIFF"); appendUInt32(36 + byteCount); appendASCII("WAVE")
        appendASCII("fmt "); appendUInt32(16); appendUInt16(1); appendUInt16(1); appendUInt32(24_000); appendUInt32(48_000); appendUInt16(2); appendUInt16(16)
        appendASCII("data"); appendUInt32(byteCount)
        for sample in samples { appendUInt16(UInt16(bitPattern: sample)) }
        return data
    }

    private func readUInt32(_ data: Data, offset: Int) -> UInt32 {
        UInt32(data[offset]) | (UInt32(data[offset + 1]) << 8) | (UInt32(data[offset + 2]) << 16) | (UInt32(data[offset + 3]) << 24)
    }
}

private final class PromptLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []

    var prompts: [String] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }

    func append(_ value: String) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }
}
