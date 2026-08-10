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
