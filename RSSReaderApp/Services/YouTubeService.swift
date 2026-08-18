//
//  YouTubeService.swift
//  RSSReaderApp
//
//  Experimental, opt-in YouTube support. YouTube channels are persisted as
//  ordinary RSS subscriptions so existing persisted data stays compatible.
//

import Foundation

struct YouTubeChannelSearchResult: Identifiable, Equatable, Sendable {
    let channelID: String
    let title: String
    let handle: String?
    let thumbnailURL: URL?

    var id: String { channelID }
    var feedURL: String {
        "https://www.youtube.com/feeds/videos.xml?channel_id=\(channelID)"
    }
}

struct YouTubeTranscriptSegment: Codable, Equatable, Sendable {
    let start: TimeInterval
    let duration: TimeInterval
    let text: String

    var end: TimeInterval { start + duration }
}

struct YouTubeTranscript: Codable, Equatable, Sendable {
    let videoID: String
    let languageCode: String
    let isAutomaticallyGenerated: Bool
    let segments: [YouTubeTranscriptSegment]

    var text: String { segments.map(\.text).joined(separator: " ") }
}

struct YouTubeTranscriptChunk: Identifiable, Equatable, Sendable {
    let index: Int
    let start: TimeInterval
    let end: TimeInterval
    let text: String

    var id: Int { index }
    var timestampLabel: String {
        "[\(Self.format(start))–\(Self.format(end))]"
    }

    private static func format(_ value: TimeInterval) -> String {
        let seconds = max(0, Int(value.rounded(.down)))
        let hours = seconds / 3_600
        let minutes = (seconds % 3_600) / 60
        let remainder = seconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, remainder)
        }
        return String(format: "%d:%02d", minutes, remainder)
    }
}

enum YouTubeSupportError: LocalizedError, Equatable {
    case invalidSearch
    case searchUnavailable
    case invalidChannelFeed
    case channelUnavailable
    case videoUnavailable
    case captionsUnavailable
    case transcriptUnavailable
    case malformedResponse

    var errorDescription: String? {
        switch self {
        case .invalidSearch:
            return "Enter a YouTube channel name to search."
        case .searchUnavailable:
            return "YouTube channel search is temporarily unavailable. Try again later."
        case .invalidChannelFeed:
            return "This is not a valid YouTube channel feed."
        case .channelUnavailable:
            return "This YouTube channel is unavailable or has no public videos."
        case .videoUnavailable:
            return "This YouTube video is private, deleted, restricted, or unavailable."
        case .captionsUnavailable:
            return "This video has no usable public transcript, so it cannot currently be summarized or used for Q&A."
        case .transcriptUnavailable:
            return "The video transcript could not be retrieved. Try again later."
        case .malformedResponse:
            return "YouTube returned a response the app could not understand."
        }
    }
}

actor YouTubeService {
    static let shared = YouTubeService()

    private let session: URLSession
    private var memoryTranscripts: [String: YouTubeTranscript] = [:]

    init(session: URLSession = .shared) {
        self.session = session
    }

    func searchChannels(query rawQuery: String) async throws -> [YouTubeChannelSearchResult] {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { throw YouTubeSupportError.invalidSearch }

        var components = URLComponents(string: "https://www.youtube.com/results")!
        components.queryItems = [
            URLQueryItem(name: "search_query", value: query),
            // YouTube's channel-only search filter. Search still works if the
            // undocumented filter changes; the parser only accepts channels.
            URLQueryItem(name: "sp", value: "EgIQAg==")
        ]
        guard let url = components.url else { throw YouTubeSupportError.invalidSearch }

        var request = URLRequest(url: url)
        request.timeoutInterval = 25
        request.setValue(Self.browserUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw YouTubeSupportError.searchUnavailable
        }
        guard let html = String(data: data, encoding: .utf8),
              let json = Self.extractInitialData(from: html) else {
            throw YouTubeSupportError.searchUnavailable
        }

        return Array(Self.parseChannelSearchResults(json).prefix(25))
    }

    func fetchChannelFeed(urlString: String) async throws -> Feed {
        let subscription = Subscription(title: "YouTube", url: urlString, type: .rss)
        guard let url = URL(string: urlString), subscription.isYouTubeChannel else {
            throw YouTubeSupportError.invalidChannelFeed
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 25
        request.setValue(Self.browserUserAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw YouTubeSupportError.channelUnavailable
        }

        return try Self.parseChannelFeed(data, feedURL: urlString)
    }

    func transcript(videoID: String, preferredLanguageCodes: [String] = Locale.preferredLanguages) async throws -> YouTubeTranscript {
        let key = videoID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw YouTubeSupportError.videoUnavailable }

        if let cached = memoryTranscripts[key] { return cached }
        if let cached = Self.loadCachedTranscript(videoID: key) {
            memoryTranscripts[key] = cached
            return cached
        }

        guard let watchURL = URL(string: "https://www.youtube.com/watch?v=\(key)") else {
            throw YouTubeSupportError.videoUnavailable
        }
        var request = URLRequest(url: watchURL)
        request.timeoutInterval = 30
        request.setValue(Self.browserUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(preferredLanguageCodes.joined(separator: ","), forHTTPHeaderField: "Accept-Language")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let html = String(data: data, encoding: .utf8) else {
            throw YouTubeSupportError.videoUnavailable
        }

        var tracks = Self.captionTracks(from: html)
        if let apiKey = Self.extractInnertubeAPIKey(from: html),
           let refreshedTracks = try? await playerCaptionTracks(videoID: key, apiKey: apiKey),
           !refreshedTracks.isEmpty {
            // Caption URLs embedded in the watch page can require a short-lived
            // proof token and return an empty body. The public player response
            // supplies fresh URLs for the same caption tracks.
            tracks = refreshedTracks
        }
        guard !tracks.isEmpty else { throw YouTubeSupportError.captionsUnavailable }
        let track = Self.preferredTrack(from: tracks, preferredLanguageCodes: preferredLanguageCodes)

        guard let baseURL = URL(string: track.baseURL, relativeTo: URL(string: "https://www.youtube.com"))?.absoluteURL,
              let captionURLs = Self.captionRequestURLs(from: baseURL) else {
            throw YouTubeSupportError.transcriptUnavailable
        }

        var captionRequest = URLRequest(url: captionURLs.json3)
        captionRequest.timeoutInterval = 30
        captionRequest.setValue(Self.browserUserAgent, forHTTPHeaderField: "User-Agent")
        let (captionData, captionResponse) = try await session.data(for: captionRequest)
        guard let captionHTTP = captionResponse as? HTTPURLResponse,
              (200..<300).contains(captionHTTP.statusCode) else {
            throw YouTubeSupportError.transcriptUnavailable
        }

        var segments = Self.parseJSON3Transcript(captionData)
        if segments.isEmpty {
            // Some tracks ignore fmt=json3. Retry the base timed-text URL and
            // parse XML rather than treating a format mismatch as no captions.
            let (xmlData, _) = try await session.data(from: captionURLs.xml)
            segments = YouTubeTimedTextParser.parse(xmlData)
        }
        guard !segments.isEmpty else { throw YouTubeSupportError.transcriptUnavailable }

        let transcript = YouTubeTranscript(
            videoID: key,
            languageCode: track.languageCode,
            isAutomaticallyGenerated: track.kind == "asr",
            segments: segments
        )
        memoryTranscripts[key] = transcript
        Self.saveCachedTranscript(transcript)
        return transcript
    }

    private func playerCaptionTracks(videoID: String, apiKey: String) async throws -> [CaptionTrack] {
        var components = URLComponents(string: "https://www.youtube.com/youtubei/v1/player")
        components?.queryItems = [URLQueryItem(name: "key", value: apiKey)]
        guard let url = components?.url else { throw YouTubeSupportError.transcriptUnavailable }

        let body: [String: Any] = [
            "context": [
                "client": [
                    "clientName": "ANDROID",
                    "clientVersion": "20.10.38"
                ]
            ],
            "videoId": videoID
        ]
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.browserUserAgent, forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            throw YouTubeSupportError.transcriptUnavailable
        }
        return Self.captionTracks(fromPlayerResponse: data)
    }

    // MARK: - Pure parsing helpers (kept internal for focused unit tests)

    static func extractInitialData(from html: String) -> Any? {
        let markers = [
            "var ytInitialData =",
            "window[\"ytInitialData\"] =",
            "window['ytInitialData'] =",
            "ytInitialData ="
        ]
        for marker in markers {
            guard let markerRange = html.range(of: marker) else { continue }
            let remainder = html[markerRange.upperBound...]
            guard let first = remainder.firstIndex(where: { !$0.isWhitespace }) else { continue }

            if html[first] == "{" {
                if let object = balancedJSON(in: html, startingAt: first),
                   let data = object.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: data) {
                    return json
                }
            } else if html[first] == "'" || html[first] == "\"" {
                let quote = html[first]
                var cursor = html.index(after: first)
                var escaped = false
                while cursor < html.endIndex {
                    let character = html[cursor]
                    if escaped {
                        escaped = false
                    } else if character == "\\" {
                        escaped = true
                    } else if character == quote {
                        let encoded = String(html[html.index(after: first)..<cursor])
                        if let decoded = decodeJavaScriptString(encoded),
                           let data = decoded.data(using: .utf8),
                           let json = try? JSONSerialization.jsonObject(with: data) {
                            return json
                        }
                        break
                    }
                    cursor = html.index(after: cursor)
                }
            }
        }
        return nil
    }

    private static func decodeJavaScriptString(_ source: String) -> String? {
        var output = ""
        var index = source.startIndex
        while index < source.endIndex {
            let character = source[index]
            guard character == "\\" else {
                output.append(character)
                index = source.index(after: index)
                continue
            }

            let escapeIndex = source.index(after: index)
            guard escapeIndex < source.endIndex else { return nil }
            let escape = source[escapeIndex]
            if escape == "x" || escape == "u" {
                let count = escape == "x" ? 2 : 4
                var end = source.index(after: escapeIndex)
                for _ in 0..<count {
                    guard end < source.endIndex else { return nil }
                    end = source.index(after: end)
                }
                let digitsStart = source.index(after: escapeIndex)
                guard let value = UInt32(source[digitsStart..<end], radix: 16),
                      let scalar = UnicodeScalar(value) else { return nil }
                output.unicodeScalars.append(scalar)
                index = end
                continue
            }

            switch escape {
            case "n": output.append("\n")
            case "r": output.append("\r")
            case "t": output.append("\t")
            case "b": output.append("\u{8}")
            case "f": output.append("\u{c}")
            case "\\": output.append("\\")
            case "\"": output.append("\"")
            case "'": output.append("'")
            case "/": output.append("/")
            default: output.append(escape)
            }
            index = source.index(after: escapeIndex)
        }
        return output
    }

    static func parseChannelSearchResults(_ json: Any) -> [YouTubeChannelSearchResult] {
        var values: [YouTubeChannelSearchResult] = []
        var seen = Set<String>()

        func textValue(_ value: Any?) -> String? {
            guard let dictionary = value as? [String: Any] else { return nil }
            if let simple = dictionary["simpleText"] as? String { return simple }
            if let runs = dictionary["runs"] as? [[String: Any]] {
                let result = runs.compactMap { $0["text"] as? String }.joined()
                return result.isEmpty ? nil : result
            }
            return nil
        }

        func walk(_ value: Any) {
            if let dictionary = value as? [String: Any] {
                let renderer = (dictionary["channelRenderer"] as? [String: Any])
                    ?? (dictionary["compactChannelRenderer"] as? [String: Any])
                if let renderer,
                   let channelID = renderer["channelId"] as? String,
                   !channelID.isEmpty,
                   !seen.contains(channelID) {
                    let title = textValue(renderer["title"])
                        ?? textValue(renderer["displayName"])
                        ?? "YouTube Channel"
                    let handle = textValue(renderer["subscriberCountText"])
                        ?? textValue(renderer["videoCountText"])
                    let thumbnails = (renderer["thumbnail"] as? [String: Any])?["thumbnails"] as? [[String: Any]]
                    let thumbnail = thumbnails?.compactMap { item -> URL? in
                        guard var value = item["url"] as? String else { return nil }
                        if value.hasPrefix("//") { value = "https:" + value }
                        return URL(string: value)
                    }.last
                    seen.insert(channelID)
                    values.append(.init(channelID: channelID, title: title, handle: handle, thumbnailURL: thumbnail))
                }
                dictionary.values.forEach(walk)
            } else if let array = value as? [Any] {
                array.forEach(walk)
            }
        }

        walk(json)
        return values
    }

    static func parseJSON3Transcript(_ data: Data) -> [YouTubeTranscriptSegment] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let events = root["events"] as? [[String: Any]] else { return [] }

        return events.compactMap { event in
            guard let rawSegments = event["segs"] as? [[String: Any]] else { return nil }
            let text = normalizeTranscriptText(rawSegments.compactMap { $0["utf8"] as? String }.joined())
            guard !text.isEmpty else { return nil }
            let start = (event["tStartMs"] as? NSNumber)?.doubleValue ?? 0
            let duration = (event["dDurationMs"] as? NSNumber)?.doubleValue ?? 0
            return YouTubeTranscriptSegment(start: start / 1_000, duration: max(0, duration / 1_000), text: text)
        }
    }

    static func parseChannelFeed(_ data: Data, feedURL: String) throws -> Feed {
        try YouTubeAtomParser(data: data, feedURL: feedURL).parse()
    }

    struct CaptionTrack {
        let baseURL: String
        let languageCode: String
        let kind: String?
    }

    static func extractInnertubeAPIKey(from html: String) -> String? {
        let pattern = #""INNERTUBE_API_KEY"\s*:\s*"([A-Za-z0-9_-]+)""#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: html) else { return nil }
        return String(html[range])
    }

    static func captionTracks(fromPlayerResponse data: Data) -> [CaptionTrack] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let captions = root["captions"] as? [String: Any],
              let renderer = captions["playerCaptionsTracklistRenderer"] as? [String: Any],
              let array = renderer["captionTracks"] as? [[String: Any]] else { return [] }
        return parseCaptionTracks(array)
    }

    static func captionRequestURLs(from baseURL: URL) -> (json3: URL, xml: URL)? {
        guard var jsonComponents = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else { return nil }
        let nonFormatItems = (jsonComponents.queryItems ?? []).filter { $0.name != "fmt" }

        var xmlComponents = jsonComponents
        xmlComponents.queryItems = nonFormatItems

        jsonComponents.queryItems = nonFormatItems + [URLQueryItem(name: "fmt", value: "json3")]
        guard let jsonURL = jsonComponents.url, let xmlURL = xmlComponents.url else { return nil }
        return (jsonURL, xmlURL)
    }

    private static func captionTracks(from html: String) -> [CaptionTrack] {
        guard let marker = html.range(of: "\"captionTracks\":"),
              let bracket = html[marker.upperBound...].firstIndex(of: "["),
              let arrayText = balancedJSON(in: html, startingAt: bracket),
              let data = arrayText.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return parseCaptionTracks(array)
    }

    private static func parseCaptionTracks(_ array: [[String: Any]]) -> [CaptionTrack] {
        array.compactMap { item in
            guard let baseURL = item["baseUrl"] as? String,
                  let languageCode = item["languageCode"] as? String else { return nil }
            return CaptionTrack(baseURL: baseURL, languageCode: languageCode, kind: item["kind"] as? String)
        }
    }

    private static func preferredTrack(from tracks: [CaptionTrack], preferredLanguageCodes: [String]) -> CaptionTrack {
        let preferences = preferredLanguageCodes.map { $0.lowercased().split(separator: "-").first.map(String.init) ?? $0.lowercased() }
        for language in preferences {
            if let manual = tracks.first(where: { $0.kind != "asr" && $0.languageCode.lowercased().hasPrefix(language) }) { return manual }
            if let any = tracks.first(where: { $0.languageCode.lowercased().hasPrefix(language) }) { return any }
        }
        if let english = tracks.first(where: { $0.kind != "asr" && $0.languageCode.lowercased().hasPrefix("en") }) { return english }
        return tracks.first(where: { $0.kind != "asr" }) ?? tracks[0]
    }

    private static func balancedJSON(in source: String, startingAt start: String.Index) -> String? {
        let opening = source[start]
        guard opening == "{" || opening == "[" else { return nil }
        let closing: Character = opening == "{" ? "}" : "]"
        var depth = 0
        var isInsideString = false
        var escaped = false
        var index = start
        while index < source.endIndex {
            let character = source[index]
            if isInsideString {
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == "\"" { isInsideString = false }
            } else if character == "\"" {
                isInsideString = true
            } else if character == opening {
                depth += 1
            } else if character == closing {
                depth -= 1
                if depth == 0 { return String(source[start...index]) }
            }
            index = source.index(after: index)
        }
        return nil
    }

    fileprivate static func normalizeTranscriptText(_ raw: String) -> String {
        raw.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let browserUserAgent = "Mozilla/5.0 (iPad; CPU OS 26_0 like Mac OS X) AppleWebKit/605.1.15 Version/26.0 Mobile/15E148 Safari/604.1"

    private static func transcriptCacheURL(videoID: String) -> URL? {
        guard let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let directory = root.appendingPathComponent("YouTubeTranscripts", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(videoID.replacingOccurrences(of: "/", with: "_")).appendingPathExtension("json")
    }

    private static func loadCachedTranscript(videoID: String) -> YouTubeTranscript? {
        guard let url = transcriptCacheURL(videoID: videoID),
              let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
              let date = values.contentModificationDate,
              Date().timeIntervalSince(date) < 30 * 24 * 60 * 60,
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(YouTubeTranscript.self, from: data)
    }

    private static func saveCachedTranscript(_ transcript: YouTubeTranscript) {
        guard let url = transcriptCacheURL(videoID: transcript.videoID),
              let data = try? JSONEncoder().encode(transcript) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

enum YouTubeTranscriptProcessor {
    static func chunks(from transcript: YouTubeTranscript, targetCharacters: Int = 7_000) -> [YouTubeTranscriptChunk] {
        guard !transcript.segments.isEmpty else { return [] }
        let limit = max(1_000, targetCharacters)
        var chunks: [YouTubeTranscriptChunk] = []
        var active: [YouTubeTranscriptSegment] = []
        var characterCount = 0

        func emit() {
            guard let first = active.first, let last = active.last else { return }
            chunks.append(.init(index: chunks.count, start: first.start, end: last.end, text: active.map(\.text).joined(separator: " ")))
        }

        for segment in transcript.segments {
            if !active.isEmpty && characterCount + segment.text.count + 1 > limit {
                emit()
                let overlap = active.suffix(2)
                active = Array(overlap)
                characterCount = active.reduce(0) { $0 + $1.text.count + 1 }
            }
            active.append(segment)
            characterCount += segment.text.count + 1
        }
        emit()
        return chunks
    }

    static func relevantChunks(for question: String, in chunks: [YouTubeTranscriptChunk], limit: Int = 5) -> [YouTubeTranscriptChunk] {
        guard chunks.count > limit else { return chunks }
        let queryTerms = terms(in: question)
        guard !queryTerms.isEmpty else { return Array(chunks.prefix(limit)) }

        var scored: [(chunk: YouTubeTranscriptChunk, score: Int)] = chunks.map { chunk in
            let haystack = terms(in: chunk.text)
            let score = queryTerms.reduce(0) { $0 + (haystack.contains($1) ? 1 : 0) }
            return (chunk: chunk, score: score)
        }
        scored.sort { lhs, rhs in
            if lhs.score == rhs.score { return lhs.chunk.index < rhs.chunk.index }
            return lhs.score > rhs.score
        }

        var indexes = Set(scored.prefix(limit).map { $0.chunk.index })
        if let best = scored.first?.chunk.index {
            if best > 0 { indexes.insert(best - 1) }
            if best + 1 < chunks.count { indexes.insert(best + 1) }
        }
        return chunks.filter { indexes.contains($0.index) }.prefix(limit + 2).map { $0 }
    }

    static func evidenceText(_ chunks: [YouTubeTranscriptChunk]) -> String {
        chunks.map { "\($0.timestampLabel) \($0.text)" }.joined(separator: "\n\n")
    }

    private static func terms(in text: String) -> Set<String> {
        let stopWords: Set<String> = ["about", "after", "again", "also", "and", "are", "did", "does", "for", "from", "have", "how", "into", "that", "the", "their", "this", "video", "was", "were", "what", "when", "where", "which", "who", "why", "with", "would"]
        return Set(text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count > 2 && !stopWords.contains($0) })
    }
}

private final class YouTubeAtomParser: NSObject, XMLParserDelegate {
    private let data: Data
    private let feedURL: String
    private var currentElement = ""
    private var text = ""
    private var feedTitle = "YouTube"
    private var feedAuthor: String?
    private var entries: [Entry] = []
    private var entry: Entry?
    private var parserError: Error?

    private struct Entry {
        var videoID: String?
        var title: String?
        var published: String?
        var author: String?
        var description: String?
        var thumbnail: String?
    }

    init(data: Data, feedURL: String) {
        self.data = data
        self.feedURL = feedURL
    }

    func parse() throws -> Feed {
        let parser = XMLParser(data: data)
        parser.delegate = self
        guard parser.parse(), parserError == nil else {
            throw parserError ?? YouTubeSupportError.malformedResponse
        }
        var seenVideoIDs = Set<String>()
        let articles = entries.compactMap { entry -> Article? in
            guard let videoID = entry.videoID, seenVideoIDs.insert(videoID).inserted else { return nil }
            return makeArticle(entry)
        }
        guard !feedTitle.isEmpty else { throw YouTubeSupportError.channelUnavailable }
        return Feed(title: feedTitle, url: feedURL, description: "YouTube channel", imageURL: articles.first?.imageURL, articles: articles)
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String : String] = [:]) {
        currentElement = qName ?? elementName
        text = ""
        if currentElement == "entry" { entry = Entry() }
        if currentElement == "media:thumbnail", entry != nil { entry?.thumbnail = attributeDict["url"] }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let name = qName ?? elementName
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if entry != nil {
            switch name {
            case "yt:videoId": entry?.videoID = value
            case "title": entry?.title = value
            case "published": entry?.published = value
            case "name": entry?.author = value
            case "media:description": entry?.description = value
            case "entry":
                if let entry { entries.append(entry) }
                entry = nil
            default: break
            }
        } else {
            if name == "title", feedTitle == "YouTube", !value.isEmpty { feedTitle = value }
            if name == "name", feedAuthor == nil, !value.isEmpty { feedAuthor = value }
        }
        text = ""
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) { parserError = parseError }

    private func makeArticle(_ entry: Entry) -> Article? {
        guard let videoID = entry.videoID, !videoID.isEmpty,
              let url = URL(string: "https://www.youtube.com/watch?v=\(videoID)") else { return nil }
        let date = entry.published.flatMap { Self.dateFormatter.date(from: $0) ?? Self.fallbackDateFormatter.date(from: $0) } ?? Date()
        let content = entry.description ?? ""
        return Article(
            id: "youtube:\(videoID)",
            title: entry.title ?? "YouTube Video",
            content: content,
            previewText: Article.makePreviewText(from: content),
            url: url,
            publishDate: date,
            author: entry.author ?? feedAuthor,
            feedTitle: feedTitle,
            feedURL: feedURL,
            imageURL: entry.thumbnail.flatMap(URL.init(string:))
        )
    }

    private static let dateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let fallbackDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}

private final class YouTubeTimedTextParser: NSObject, XMLParserDelegate {
    private var segments: [YouTubeTranscriptSegment] = []
    private var start: TimeInterval = 0
    private var duration: TimeInterval = 0
    private var text = ""
    private var inText = false

    static func parse(_ data: Data) -> [YouTubeTranscriptSegment] {
        let delegate = YouTubeTimedTextParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        return parser.parse() ? delegate.segments : []
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String : String] = [:]) {
        guard elementName == "text" else { return }
        inText = true
        text = ""
        start = TimeInterval(attributeDict["start"] ?? "") ?? 0
        duration = TimeInterval(attributeDict["dur"] ?? "") ?? 0
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inText { text += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        guard elementName == "text" else { return }
        let value = YouTubeService.normalizeTranscriptText(text)
        if !value.isEmpty { segments.append(.init(start: start, duration: duration, text: value)) }
        inText = false
    }
}
