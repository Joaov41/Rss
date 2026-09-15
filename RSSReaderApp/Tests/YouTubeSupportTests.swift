import XCTest
@testable import RSSReaderApp

final class YouTubeSupportTests: XCTestCase {
    func testChannelSearchParserExtractsAndDeduplicatesChannels() throws {
        let fixture: [String: Any] = [
            "contents": [
                ["channelRenderer": [
                    "channelId": "UC123",
                    "title": ["simpleText": "Example Creator"],
                    "subscriberCountText": ["simpleText": "1M subscribers"],
                    "thumbnail": ["thumbnails": [["url": "https://example.com/avatar.jpg"]]]
                ]],
                ["channelRenderer": [
                    "channelId": "UC123",
                    "title": ["simpleText": "Duplicate"]
                ]]
            ]
        ]

        let results = YouTubeService.parseChannelSearchResults(fixture)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.channelID, "UC123")
        XCTAssertEqual(results.first?.title, "Example Creator")
        XCTAssertEqual(results.first?.feedURL, "https://www.youtube.com/feeds/videos.xml?channel_id=UC123")
    }

    func testCurrentCompactChannelRendererIsSupported() throws {
        let fixture: [String: Any] = ["compactChannelRenderer": [
            "channelId": "UC456",
            "displayName": ["runs": [["text": "Compact Creator"]]],
            "subscriberCountText": ["runs": [["text": "@compact"]]],
            "thumbnail": ["thumbnails": [["url": "//yt3.example/avatar.jpg"]]]
        ]]
        let result = YouTubeService.parseChannelSearchResults(fixture).first
        XCTAssertEqual(result?.channelID, "UC456")
        XCTAssertEqual(result?.title, "Compact Creator")
        XCTAssertEqual(result?.thumbnailURL?.absoluteString, "https://yt3.example/avatar.jpg")
    }

    func testInitialDataExtractionHandlesBracesInsideStrings() throws {
        let html = #"<script>var ytInitialData = {"text":"a } brace","items":[1,2]};</script>"#
        let value = YouTubeService.extractInitialData(from: html) as? [String: Any]
        XCTAssertEqual(value?["text"] as? String, "a } brace")
    }

    func testInitialDataExtractionHandlesYouTubeHexEscapedWrapper() throws {
        let html = #"<script>var ytInitialData = '\x7b\x22value\x22\x3a\x22decoded\x22\x7d';</script>"#
        let value = YouTubeService.extractInitialData(from: html) as? [String: Any]
        XCTAssertEqual(value?["value"] as? String, "decoded")
    }

    func testJSON3TranscriptPreservesTimestampedSpeech() throws {
        let data = #"{"events":[{"tStartMs":1000,"dDurationMs":2500,"segs":[{"utf8":"Hello "},{"utf8":"world"}]},{"tStartMs":4000,"dDurationMs":1000,"segs":[{"utf8":"Next point"}]}]}"#.data(using: .utf8)!
        let segments = YouTubeService.parseJSON3Transcript(data)
        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0], .init(start: 1, duration: 2.5, text: "Hello world"))
        XCTAssertEqual(segments[1].text, "Next point")
    }

    func testInnertubeAPIKeyExtractionAllowsWhitespace() throws {
        let html = #"<script>{"INNERTUBE_API_KEY" : "test_key-123"}</script>"#
        XCTAssertEqual(YouTubeService.extractInnertubeAPIKey(from: html), "test_key-123")
    }

    func testAndroidPlayerCaptionTracksAreParsed() throws {
        let data = #"{"captions":{"playerCaptionsTracklistRenderer":{"captionTracks":[{"baseUrl":"https://www.youtube.com/api/timedtext?v=abc","languageCode":"en"},{"baseUrl":"https://www.youtube.com/api/timedtext?v=abc&kind=asr","languageCode":"en","kind":"asr"}]}}}"#.data(using: .utf8)!
        let tracks = YouTubeService.captionTracks(fromPlayerResponse: data)
        XCTAssertEqual(tracks.count, 2)
        XCTAssertEqual(tracks[0].languageCode, "en")
        XCTAssertNil(tracks[0].kind)
        XCTAssertEqual(tracks[1].kind, "asr")
    }

    func testSRV3CaptionURLIsNormalizedForBothParsers() throws {
        let source = URL(string: "https://www.youtube.com/api/timedtext?v=abc&signature=signed&fmt=srv3")!
        let urls = try XCTUnwrap(YouTubeService.captionRequestURLs(from: source))
        let jsonItems = URLComponents(url: urls.json3, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let xmlItems = URLComponents(url: urls.xml, resolvingAgainstBaseURL: false)?.queryItems ?? []

        XCTAssertEqual(jsonItems.first(where: { $0.name == "fmt" })?.value, "json3")
        XCTAssertFalse(xmlItems.contains(where: { $0.name == "fmt" }))
        XCTAssertEqual(xmlItems.first(where: { $0.name == "signature" })?.value, "signed")
    }

    func testYouTubeAtomFeedUsesStableIDsAndDeduplicatesVideos() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <feed xmlns:yt="http://www.youtube.com/xml/schemas/2015" xmlns:media="http://search.yahoo.com/mrss/">
          <title>Example Channel</title><author><name>Creator</name></author>
          <entry><yt:videoId>abc123</yt:videoId><title>Video One</title><published>2026-08-10T10:00:00+00:00</published><media:group><media:description>Spoken topic</media:description><media:thumbnail url="https://example.com/thumb.jpg"/></media:group></entry>
          <entry><yt:videoId>abc123</yt:videoId><title>Duplicate</title><published>2026-08-10T10:00:00+00:00</published></entry>
        </feed>
        """
        let feedURL = "https://www.youtube.com/feeds/videos.xml?channel_id=UC123"
        let feed = try YouTubeService.parseChannelFeed(Data(xml.utf8), feedURL: feedURL)
        XCTAssertEqual(feed.title, "Example Channel")
        XCTAssertEqual(feed.articles.count, 1)
        XCTAssertEqual(feed.articles.first?.id, "youtube:abc123")
        XCTAssertEqual(feed.articles.first?.url?.absoluteString, "https://www.youtube.com/watch?v=abc123")
    }

    func testLongTranscriptChunkingDoesNotDropSegments() throws {
        let segments = (0..<30).map {
            YouTubeTranscriptSegment(start: Double($0 * 10), duration: 5, text: "unique-segment-\($0) " + String(repeating: "detail ", count: 30))
        }
        let transcript = YouTubeTranscript(videoID: "video", languageCode: "en", isAutomaticallyGenerated: false, segments: segments)
        let chunks = YouTubeTranscriptProcessor.chunks(from: transcript, targetCharacters: 1_000)
        let combined = chunks.map(\.text).joined(separator: " ")

        XCTAssertGreaterThan(chunks.count, 1)
        for index in segments.indices {
            XCTAssertTrue(combined.contains("unique-segment-\(index)"))
        }
    }

    func testQARetrievalSelectsTranscriptSectionContainingQuestionTerms() throws {
        let chunks = [
            YouTubeTranscriptChunk(index: 0, start: 0, end: 30, text: "An introduction about cameras."),
            YouTubeTranscriptChunk(index: 1, start: 30, end: 60, text: "Battery endurance reached twenty hours in testing."),
            YouTubeTranscriptChunk(index: 2, start: 60, end: 90, text: "The conclusion discusses pricing.")
        ]
        let selected = YouTubeTranscriptProcessor.relevantChunks(for: "What did they say about battery endurance?", in: chunks, limit: 1)
        XCTAssertTrue(selected.contains(where: { $0.index == 1 }))
    }

    func testYouTubeURLsUseStableVideoIdentifiers() throws {
        let article = Article(
            id: "youtube:abc123",
            title: "Video",
            content: "",
            url: URL(string: "https://www.youtube.com/watch?v=abc123"),
            publishDate: Date(),
            feedTitle: "Channel",
            feedURL: "https://www.youtube.com/feeds/videos.xml?channel_id=UC123"
        )
        XCTAssertEqual(article.youtubeVideoID, "abc123")
        XCTAssertTrue(article.isYouTubeVideo)
    }
}

final class PodcastEpisodeSupportTests: XCTestCase {
    func testPodcastCatalogSearchBuildsARestrictedPodcastQuery() throws {
        let url = try PodcastDiscoveryService.searchURL(
            query: "Hard Fork",
            countryCode: "pt",
            limit: 200
        )
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in
            item.value.map { (item.name, $0) }
        })

        XCTAssertEqual(components.host, "itunes.apple.com")
        XCTAssertEqual(items["term"], "Hard Fork")
        XCTAssertEqual(items["media"], "podcast")
        XCTAssertEqual(items["entity"], "podcast")
        XCTAssertEqual(items["country"], "PT")
        XCTAssertEqual(items["limit"], "50")
    }

    func testPodcastCatalogParserRequiresAndDeduplicatesRSSFeeds() throws {
        let data = #"""
        {
          "resultCount": 4,
          "results": [
            {
              "collectionId": 123,
              "collectionName": "Example Show",
              "artistName": "Example Publisher",
              "feedUrl": "https://Feeds.Example.com/show.xml",
              "artworkUrl600": "https://example.com/art.jpg",
              "primaryGenreName": "Technology",
              "trackCount": 42
            },
            {
              "collectionId": 124,
              "collectionName": "Duplicate Show",
              "artistName": "Duplicate Publisher",
              "feedUrl": "https://feeds.example.com/show.xml#duplicate"
            },
            {
              "collectionName": "Missing Feed"
            },
            {
              "collectionName": "Unsupported Feed",
              "feedUrl": "ftp://example.com/show.xml"
            }
          ]
        }
        """#.data(using: .utf8)!

        let podcasts = try PodcastDiscoveryService.parseSearchResults(data)
        XCTAssertEqual(podcasts.count, 1)
        XCTAssertEqual(podcasts.first?.title, "Example Show")
        XCTAssertEqual(podcasts.first?.publisher, "Example Publisher")
        XCTAssertEqual(podcasts.first?.feedURL.absoluteString, "https://Feeds.Example.com/show.xml")
        XCTAssertEqual(podcasts.first?.episodeCount, 42)
    }

    func testPodcastTranscriptFeedParserMatchesTheAudioEnclosure() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <rss xmlns:podcast="https://podcastindex.org/namespace/1.0"><channel>
          <item>
            <title>Wrong episode</title>
            <enclosure url="https://cdn.example.com/wrong.mp3" type="audio/mpeg"/>
            <podcast:transcript url="https://example.com/wrong.vtt" type="text/vtt" language="en"/>
          </item>
          <item>
            <title>The real episode</title>
            <link>https://example.com/episodes/real</link>
            <enclosure url="https://cdn.example.com/real.mp3" type="audio/mpeg"/>
            <podcast:transcript url="/transcripts/real.vtt" type="text/vtt" language="en"/>
          </item>
        </channel></rss>
        """

        let references = PodcastTranscriptFeedParser.references(
            in: Data(xml.utf8),
            feedURL: URL(string: "https://example.com/feed.xml")!,
            episodeTitle: "The real episode",
            episodePageURL: URL(string: "https://example.com/episodes/real"),
            audioURL: URL(string: "https://cdn.example.com/real.mp3")!
        )

        XCTAssertEqual(references.count, 1)
        XCTAssertEqual(references.first?.url.absoluteString, "https://example.com/transcripts/real.vtt")
        XCTAssertEqual(references.first?.mimeType, "text/vtt")
    }

    func testWebVTTTranscriptPreservesCueTimingsAndText() throws {
        let vtt = """
        WEBVTT

        00:00:01.000 --> 00:00:04.500
        First spoken point.

        00:01:05.000 --> 00:01:09.000
        A <b>second</b> point.
        """
        let segments = try PodcastTranscriptDocumentParser.parse(
            data: Data(vtt.utf8),
            mimeType: "text/vtt",
            sourceURL: URL(string: "https://example.com/episode.vtt")!
        )

        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0], .init(start: 1, end: 4.5, text: "First spoken point."))
        XCTAssertEqual(segments[1], .init(start: 65, end: 69, text: "A second point."))
    }

    func testLongPodcastTranscriptChunkingDoesNotDropSections() throws {
        let segments = (0..<40).map {
            PodcastTranscriptSegment(
                start: Double($0 * 30),
                end: Double($0 * 30 + 25),
                text: "unique-podcast-section-\($0) " + String(repeating: "evidence ", count: 35)
            )
        }
        let transcript = PodcastEpisodeTranscript(
            episodeID: "episode",
            sourceURL: URL(string: "https://example.com/transcript.vtt")!,
            languageCode: "en",
            segments: segments
        )
        let chunks = PodcastTranscriptProcessor.chunks(from: transcript, targetCharacters: 1_000)
        let combined = chunks.map(\.text).joined(separator: " ")

        XCTAssertGreaterThan(chunks.count, 1)
        for index in segments.indices {
            XCTAssertTrue(combined.contains("unique-podcast-section-\(index)"))
        }
    }

    func testPodcastQARetrievalSelectsRelevantTranscriptEvidence() throws {
        let chunks = [
            PodcastTranscriptChunk(index: 0, start: 0, end: 30, text: "The hosts introduce the weekly show."),
            PodcastTranscriptChunk(index: 1, start: 30, end: 60, text: "Battery endurance reached twenty hours during testing."),
            PodcastTranscriptChunk(index: 2, start: 60, end: 90, text: "They close with a discussion of price.")
        ]
        let selected = PodcastTranscriptProcessor.relevantChunks(
            for: "What did they say about battery endurance?",
            in: chunks,
            limit: 1
        )
        XCTAssertTrue(selected.contains(where: { $0.index == 1 }))
    }

    func testArticleWithAudioEnclosureIsAPodcastEpisode() throws {
        let article = Article(
            id: "episode",
            title: "Episode",
            content: "Show notes",
            url: URL(string: "https://example.com/episode"),
            publishDate: Date(),
            feedTitle: "Example Podcast",
            feedURL: "https://example.com/feed.xml",
            podcastAudioURL: URL(string: "https://cdn.example.com/episode.mp3"),
            podcastAudioMIMEType: "audio/mpeg",
            podcastLanguageCode: "en-US"
        )
        XCTAssertTrue(article.isPodcastEpisode)
        XCTAssertEqual(article.podcastLanguageCode, "en-US")
    }

    func testGeneratedTranscriptStagesDescribeTheLongRunningFallback() throws {
        XCTAssertTrue(PodcastTranscriptPreparationStage.checkingPublisher.statusMessage.contains("publisher"))
        XCTAssertTrue(PodcastTranscriptPreparationStage.downloadingAudio.statusMessage.contains("downloading"))
        XCTAssertTrue(PodcastTranscriptPreparationStage.transcribingAudio(progress: 0.42).statusMessage.contains("42%"))
        XCTAssertGreaterThan(
            PodcastTranscriptPreparationStage.transcribingAudio(progress: 0.8).backgroundProgressFraction,
            PodcastTranscriptPreparationStage.transcribingAudio(progress: 0.2).backgroundProgressFraction
        )
        XCTAssertTrue(PodcastTranscriptPreparationStage.finalizingTranscript.statusMessage.contains("transcript"))
    }
}

final class GeminiBackgroundSessionLifecycleTests: XCTestCase {
    func testRootCompletionWaitsForDependentWork() {
        var lifecycle = GeminiBackgroundSessionLifecycle()

        XCTAssertFalse(lifecycle.recordRootCompletion(success: true, hasDependents: true))
        XCTAssertTrue(lifecycle.rootFinished)
        XCTAssertTrue(lifecycle.succeeded)
        XCTAssertTrue(lifecycle.recordDependentCompletion(success: true, hasRemainingDependents: false))
    }

    func testDependentCanFinishBeforeRoot() {
        var lifecycle = GeminiBackgroundSessionLifecycle()

        XCTAssertFalse(lifecycle.recordDependentCompletion(success: true, hasRemainingDependents: false))
        XCTAssertFalse(lifecycle.rootFinished)
        XCTAssertTrue(lifecycle.recordRootCompletion(success: true, hasDependents: false))
    }

    func testAnyOperationFailureMakesTheSessionFail() {
        var lifecycle = GeminiBackgroundSessionLifecycle()

        XCTAssertFalse(lifecycle.recordDependentCompletion(success: false, hasRemainingDependents: false))
        XCTAssertTrue(lifecycle.recordRootCompletion(success: true, hasDependents: false))
        XCTAssertFalse(lifecycle.succeeded)
    }
}
