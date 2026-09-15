//
//  PodcastEpisodeService.swift
//  RSSReaderApp
//
//  Publisher-transcript retrieval and playback for real podcast episodes.
//  This is intentionally separate from the generated Batch Podcast feature.
//

import Foundation
import CryptoKit

#if canImport(FoundationXML)
import FoundationXML
#endif

#if os(iOS)
import AVFoundation
import Combine
import MediaPlayer
import Speech
#endif

struct PodcastTranscriptReference: Equatable, Sendable {
    let url: URL
    let mimeType: String?
    let languageCode: String?
    let relationship: String?
}

struct PodcastTranscriptSegment: Codable, Equatable, Sendable {
    let start: TimeInterval?
    let end: TimeInterval?
    let text: String
}

struct PodcastEpisodeTranscript: Codable, Equatable, Sendable {
    let episodeID: String
    let sourceURL: URL
    let languageCode: String?
    let segments: [PodcastTranscriptSegment]

    var text: String { segments.map(\.text).joined(separator: " ") }
}

enum PodcastTranscriptAvailability: Equatable, Sendable {
    case checking
    case publisherAvailable
    case generatedAvailable
    case generationRequired
    case checkUnavailable

    static func readyState(
        for transcript: PodcastEpisodeTranscript,
        audioURL: URL
    ) -> PodcastTranscriptAvailability {
        transcript.sourceURL == audioURL ? .generatedAvailable : .publisherAvailable
    }
}

enum PodcastShowNotesFormatter {
    static func plainText(from html: String) -> String {
        let source = html.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else { return "" }

        // Preserve useful block boundaries while SwiftSoup removes tags and
        // decodes entities. A private-use marker survives whitespace cleanup.
        let breakMarker = "\u{E000}"
        var marked = source
            .replacingOccurrences(
                of: "(?i)<br\\s*/?>",
                with: breakMarker,
                options: .regularExpression
            )
            .replacingOccurrences(
                of: "(?i)</(?:p|div|section|article|h[1-6]|blockquote|pre|ul|ol)>",
                with: breakMarker + breakMarker,
                options: .regularExpression
            )
            .replacingOccurrences(
                of: "(?i)<li(?:\\s[^>]*)?>",
                with: "<li>• ",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: "(?i)</li>",
                with: breakMarker,
                options: .regularExpression
            )

        marked = marked.removingHTML()
        return marked
            .replacingOccurrences(of: breakMarker, with: "\n")
            .replacingOccurrences(of: "[\\t ]*\\n[\\t ]*", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
            .replacingOccurrences(of: "[\\t ]{2,}", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct PodcastTranscriptChunk: Identifiable, Equatable, Sendable {
    let index: Int
    let start: TimeInterval?
    let end: TimeInterval?
    let text: String

    var id: Int { index }

    var citationLabel: String {
        guard let start else { return "[Transcript section \(index + 1)]" }
        if let end, end > start {
            return "[\(Self.format(start))–\(Self.format(end))]"
        }
        return "[\(Self.format(start))]"
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

enum PodcastEpisodeSupportError: LocalizedError, Equatable {
    case invalidEpisode
    case feedUnavailable
    case transcriptNotPublished
    case transcriptUnavailable
    case unsupportedTranscript
    case emptyTranscript
    case speechPermissionDenied
    case speechTranscriptionUnavailable
    case speechLanguageUnsupported
    case speechModelUnavailable
    case audioUnavailable
    case generatedTranscriptEmpty

    var errorDescription: String? {
        switch self {
        case .invalidEpisode:
            return "This item does not contain a playable podcast episode."
        case .feedUnavailable:
            return "The podcast feed could not be loaded to find its transcript."
        case .transcriptNotPublished:
            return "The publisher has not attached a transcript to this episode, so its spoken audio cannot yet be summarized or used for Q&A."
        case .transcriptUnavailable:
            return "The episode transcript could not be downloaded. Try again later."
        case .unsupportedTranscript:
            return "The publisher's transcript uses a format this version cannot read."
        case .emptyTranscript:
            return "The publisher's transcript did not contain readable text."
        case .speechPermissionDenied:
            return "Speech recognition permission is required to create a transcript for this episode."
        case .speechTranscriptionUnavailable:
            return "On-device podcast transcription is not available on this device."
        case .speechLanguageUnsupported:
            return "On-device transcription does not support this podcast's language yet."
        case .speechModelUnavailable:
            return "The on-device speech model could not be prepared. Check your connection and available storage, then try again."
        case .audioUnavailable:
            return "The episode audio could not be downloaded for transcription. Try again later."
        case .generatedTranscriptEmpty:
            return "The app could not detect enough speech in this episode to create a transcript."
        }
    }
}

enum PodcastTranscriptPreparationStage: Equatable, Sendable {
    case checkingPublisher
    case requestingSpeechPermission
    case preparingSpeechModel(String)
    case downloadingAudio
    case transcribingAudio(progress: Double)
    case finalizingTranscript

    var statusMessage: String {
        switch self {
        case .checkingPublisher:
            return "Checking for the publisher's episode transcript…"
        case .requestingSpeechPermission:
            return "Preparing private on-device transcription…"
        case .preparingSpeechModel(let language):
            return "Preparing the on-device \(language) speech model…"
        case .downloadingAudio:
            return "Temporarily downloading the episode audio for transcription…"
        case .transcribingAudio(let progress):
            let percentage = Int((max(0, min(progress, 1)) * 100).rounded())
            return "Creating a private on-device transcript… \(percentage)%"
        case .finalizingTranscript:
            return "Saving the generated episode transcript…"
        }
    }

    /// Reserves the first 72% of the enclosing background task for finding or
    /// creating the transcript. Summary and Q&A work use the remaining range.
    var backgroundProgressFraction: Double {
        switch self {
        case .checkingPublisher:
            return 0.03
        case .requestingSpeechPermission:
            return 0.08
        case .preparingSpeechModel:
            return 0.12
        case .downloadingAudio:
            return 0.18
        case .transcribingAudio(let progress):
            return 0.25 + (0.45 * max(0, min(progress, 1)))
        case .finalizingTranscript:
            return 0.72
        }
    }
}

actor PodcastEpisodeTranscriptService {
    static let shared = PodcastEpisodeTranscriptService()

    private let session: URLSession
    private var memoryCache: [String: PodcastEpisodeTranscript] = [:]

    init(session: URLSession = .shared) {
        self.session = session
        Self.removePreviouslyStoredTranscripts()
    }

    func cachedTranscript(for article: Article) -> PodcastEpisodeTranscript? {
        memoryCache[article.id]
    }

    func clearCachedTranscripts() {
        memoryCache.removeAll()
    }

    func discardTranscript(for episodeID: String) {
        memoryCache[episodeID] = nil
    }

    func availability(for article: Article) async throws -> PodcastTranscriptAvailability {
        guard let audioURL = article.podcastAudioURL,
              let feedURL = URL(string: article.feedURL) else {
            return .checkUnavailable
        }

        if let cached = cachedTranscript(for: article) {
            return .readyState(for: cached, audioURL: audioURL)
        }

        do {
            let transcript = try await publisherTranscript(
                for: article,
                audioURL: audioURL,
                feedURL: feedURL
            )
            memoryCache[article.id] = transcript
            return .publisherAvailable
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as PodcastEpisodeSupportError {
            switch error {
            case .transcriptNotPublished, .transcriptUnavailable, .unsupportedTranscript, .emptyTranscript:
                return .generationRequired
            default:
                return .checkUnavailable
            }
        } catch {
            return .checkUnavailable
        }
    }

    func transcript(
        for article: Article,
        onProgress: (@Sendable (PodcastTranscriptPreparationStage) async -> Void)? = nil
    ) async throws -> PodcastEpisodeTranscript {
        guard let audioURL = article.podcastAudioURL,
              let feedURL = URL(string: article.feedURL) else {
            throw PodcastEpisodeSupportError.invalidEpisode
        }

        if let cached = cachedTranscript(for: article) { return cached }

        await onProgress?(.checkingPublisher)
        let transcript: PodcastEpisodeTranscript
        do {
            transcript = try await publisherTranscript(
                for: article,
                audioURL: audioURL,
                feedURL: feedURL
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            transcript = try await generatedTranscript(
                for: article,
                audioURL: audioURL,
                onProgress: onProgress
            )
        }

        memoryCache[article.id] = transcript
        return transcript
    }

    private func publisherTranscript(
        for article: Article,
        audioURL: URL,
        feedURL: URL
    ) async throws -> PodcastEpisodeTranscript {
        try Task.checkCancellation()

        var feedRequest = URLRequest(url: feedURL)
        feedRequest.timeoutInterval = 30
        feedRequest.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        let (feedData, feedResponse) = try await session.data(for: feedRequest)
        guard let feedHTTP = feedResponse as? HTTPURLResponse,
              (200..<300).contains(feedHTTP.statusCode) else {
            throw PodcastEpisodeSupportError.feedUnavailable
        }

        let references = PodcastTranscriptFeedParser.references(
            in: feedData,
            feedURL: feedURL,
            episodeTitle: article.title,
            episodePageURL: article.url,
            audioURL: audioURL
        )
        guard !references.isEmpty else {
            throw PodcastEpisodeSupportError.transcriptNotPublished
        }

        var lastError: Error = PodcastEpisodeSupportError.transcriptUnavailable
        for reference in Self.preferredReferences(references) {
            do {
                var request = URLRequest(url: reference.url)
                request.timeoutInterval = 45
                request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse,
                      (200..<300).contains(http.statusCode) else {
                    throw PodcastEpisodeSupportError.transcriptUnavailable
                }
                let responseType = http.value(forHTTPHeaderField: "Content-Type")?
                    .components(separatedBy: ";")
                    .first
                let segments = try PodcastTranscriptDocumentParser.parse(
                    data: data,
                    mimeType: reference.mimeType ?? responseType,
                    sourceURL: reference.url
                )
                guard !segments.isEmpty else { throw PodcastEpisodeSupportError.emptyTranscript }

                let transcript = PodcastEpisodeTranscript(
                    episodeID: article.id,
                    sourceURL: reference.url,
                    languageCode: reference.languageCode,
                    segments: segments
                )
                return transcript
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    #if os(iOS)
    private func generatedTranscript(
        for article: Article,
        audioURL: URL,
        onProgress: (@Sendable (PodcastTranscriptPreparationStage) async -> Void)?
    ) async throws -> PodcastEpisodeTranscript {
        guard SpeechTranscriber.isAvailable else {
            throw PodcastEpisodeSupportError.speechTranscriptionUnavailable
        }

        await onProgress?(.requestingSpeechPermission)
        let authorization = await Self.requestSpeechAuthorization()
        guard authorization == .authorized else {
            throw PodcastEpisodeSupportError.speechPermissionDenied
        }

        guard let locale = await Self.supportedTranscriptionLocale(for: article) else {
            throw PodcastEpisodeSupportError.speechLanguageUnsupported
        }
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)

        await onProgress?(.preparingSpeechModel(locale.localizedString(forIdentifier: locale.identifier) ?? locale.identifier))
        do {
            if let installation = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await installation.downloadAndInstall()
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw PodcastEpisodeSupportError.speechModelUnavailable
        }

        await onProgress?(.downloadingAudio)
        let localAudioURL = try await downloadAudioFile(from: audioURL, episodeID: article.id)
        defer { try? FileManager.default.removeItem(at: localAudioURL) }
        try Task.checkCancellation()

        let audioFile: AVAudioFile
        do {
            audioFile = try AVAudioFile(forReading: localAudioURL)
        } catch {
            throw PodcastEpisodeSupportError.audioUnavailable
        }

        let sampleRate = audioFile.processingFormat.sampleRate
        let audioDuration = sampleRate > 0 ? Double(audioFile.length) / sampleRate : nil
        await onProgress?(.transcribingAudio(progress: 0))
        // Keep long-running transcription work at utility priority and retain
        // the model while the app is actively using it. This avoids competing
        // with playback/navigation while preventing needless model churn.
        let analyzer = SpeechAnalyzer(
            modules: [transcriber],
            options: SpeechAnalyzer.Options(
                priority: .utility,
                modelRetention: .whileInUse
            )
        )
        async let segmentsFuture: [PodcastTranscriptSegment] = Self.collectSegments(
            from: transcriber,
            audioDuration: audioDuration
        ) { progress in
            await onProgress?(.transcribingAudio(progress: progress))
        }

        do {
            if let lastSample = try await analyzer.analyzeSequence(from: audioFile) {
                try Task.checkCancellation()
                try await analyzer.finalizeAndFinish(through: lastSample)
            } else {
                await analyzer.cancelAndFinishNow()
            }
        } catch is CancellationError {
            await analyzer.cancelAndFinishNow()
            throw CancellationError()
        } catch {
            await analyzer.cancelAndFinishNow()
            throw PodcastEpisodeSupportError.speechTranscriptionUnavailable
        }

        let segments = try await segmentsFuture
        guard !segments.isEmpty else {
            throw PodcastEpisodeSupportError.generatedTranscriptEmpty
        }

        await onProgress?(.finalizingTranscript)
        return PodcastEpisodeTranscript(
            episodeID: article.id,
            sourceURL: audioURL,
            languageCode: locale.identifier,
            segments: segments
        )
    }

    private func downloadAudioFile(from audioURL: URL, episodeID: String) async throws -> URL {
        var request = URLRequest(url: audioURL)
        request.timeoutInterval = 120
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")

        let temporaryURL: URL
        let response: URLResponse
        do {
            (temporaryURL, response) = try await session.download(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw PodcastEpisodeSupportError.audioUnavailable
        }
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            throw PodcastEpisodeSupportError.audioUnavailable
        }

        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            throw PodcastEpisodeSupportError.audioUnavailable
        }
        let directory = caches.appendingPathComponent("PodcastTranscriptionAudio", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let digest = SHA256.hash(data: Data(episodeID.utf8)).map { String(format: "%02x", $0) }.joined()
            let fileExtension = Self.audioFileExtension(
                sourceURL: audioURL,
                mimeType: http.value(forHTTPHeaderField: "Content-Type")
            )
            let destination = directory.appendingPathComponent("\(digest).\(fileExtension)")
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: temporaryURL, to: destination)
            return destination
        } catch {
            throw PodcastEpisodeSupportError.audioUnavailable
        }
    }

    private static func requestSpeechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        let current = SFSpeechRecognizer.authorizationStatus()
        guard current == .notDetermined else { return current }
        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }

    private static func supportedTranscriptionLocale(for article: Article) async -> Locale? {
        var identifiers: [String] = []
        if let language = article.podcastLanguageCode?.trimmingCharacters(in: .whitespacesAndNewlines),
           !language.isEmpty {
            identifiers.append(language)
        }
        identifiers.append(contentsOf: Locale.preferredLanguages)
        identifiers.append(Locale.current.identifier)

        var seen = Set<String>()
        for identifier in identifiers where seen.insert(identifier.lowercased()).inserted {
            if let locale = await SpeechTranscriber.supportedLocale(
                equivalentTo: Locale(identifier: identifier)
            ) {
                return locale
            }
        }
        return nil
    }

    private static func collectSegments(
        from transcriber: SpeechTranscriber,
        audioDuration: TimeInterval?,
        onProgress: (@Sendable (Double) async -> Void)? = nil
    ) async throws -> [PodcastTranscriptSegment] {
        var segments: [PodcastTranscriptSegment] = []
        var lastPublishedPercentage = -1
        var lastPublishedAt = Date.distantPast
        for try await result in transcriber.results {
            try Task.checkCancellation()

            let end = finiteSeconds(CMTimeRangeGetEnd(result.range))
            if let end, let audioDuration, audioDuration > 0 {
                let progress = max(0, min(end / audioDuration, 1))
                let percentage = Int((progress * 100).rounded())
                let now = Date()
                if percentage != lastPublishedPercentage,
                   now.timeIntervalSince(lastPublishedAt) >= 0.2 {
                    lastPublishedPercentage = percentage
                    lastPublishedAt = now
                    await onProgress?(progress)
                }
            }

            let text = String(result.text.characters)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, result.isFinal else { continue }

            let start = finiteSeconds(result.range.start)
            segments.append(.init(start: start, end: end, text: text))
        }
        if lastPublishedPercentage != 100 {
            await onProgress?(1)
        }
        return segments
    }

    private static func finiteSeconds(_ time: CMTime) -> TimeInterval? {
        let value = CMTimeGetSeconds(time)
        return value.isFinite && value >= 0 ? value : nil
    }

    private static func audioFileExtension(sourceURL: URL, mimeType: String?) -> String {
        let sourceExtension = sourceURL.pathExtension.lowercased()
        if !sourceExtension.isEmpty { return sourceExtension }

        let normalizedType = mimeType?.lowercased().components(separatedBy: ";").first ?? ""
        if normalizedType.contains("mpeg") { return "mp3" }
        if normalizedType.contains("mp4") || normalizedType.contains("m4a") { return "m4a" }
        if normalizedType.contains("wav") { return "wav" }
        if normalizedType.contains("flac") { return "flac" }
        if normalizedType.contains("ogg") || normalizedType.contains("opus") { return "ogg" }
        return "audio"
    }
    #else
    private func generatedTranscript(
        for article: Article,
        audioURL: URL,
        onProgress: (@Sendable (PodcastTranscriptPreparationStage) async -> Void)?
    ) async throws -> PodcastEpisodeTranscript {
        throw PodcastEpisodeSupportError.speechTranscriptionUnavailable
    }
    #endif

    private static func preferredReferences(_ references: [PodcastTranscriptReference]) -> [PodcastTranscriptReference] {
        let preferredLanguages = Locale.preferredLanguages.map {
            Locale(identifier: $0).language.languageCode?.identifier.lowercased() ?? $0.lowercased()
        }
        return references.sorted { lhs, rhs in
            score(lhs, preferredLanguages: preferredLanguages) > score(rhs, preferredLanguages: preferredLanguages)
        }
    }

    private static func score(_ reference: PodcastTranscriptReference, preferredLanguages: [String]) -> Int {
        var value = 0
        let type = reference.mimeType?.lowercased() ?? ""
        let ext = reference.url.pathExtension.lowercased()
        if type.contains("vtt") || ext == "vtt" { value += 40 }
        else if type.contains("srt") || ext == "srt" { value += 35 }
        else if type.contains("json") || ext == "json" { value += 30 }
        else if type.contains("text") || type.contains("html") || ["txt", "html", "htm"].contains(ext) { value += 25 }

        if let language = reference.languageCode?.lowercased() {
            if let index = preferredLanguages.firstIndex(where: { language.hasPrefix($0) || $0.hasPrefix(language) }) {
                value += max(1, 20 - index)
            }
        }
        if reference.relationship?.lowercased() == "captions" { value -= 1 }
        return value
    }

    private static let userAgent = "RSSReaderApp/1.0 (Podcast transcript reader)"

    private static func removePreviouslyStoredTranscripts() {
        let fileManager = FileManager.default
        let roots = [
            fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first,
            fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        ].compactMap { $0 }

        for root in roots {
            let directory = root.appendingPathComponent("PodcastTranscripts", isDirectory: true)
            try? fileManager.removeItem(at: directory)
        }
    }
}

enum PodcastTranscriptProcessor {
    static func chunks(from transcript: PodcastEpisodeTranscript, targetCharacters: Int = 7_000) -> [PodcastTranscriptChunk] {
        let limit = max(1_000, targetCharacters)
        let normalizedSegments = transcript.segments.flatMap { segment -> [PodcastTranscriptSegment] in
            split(segment.text, limit: limit).map {
                PodcastTranscriptSegment(start: segment.start, end: segment.end, text: $0)
            }
        }
        guard !normalizedSegments.isEmpty else { return [] }

        var chunks: [PodcastTranscriptChunk] = []
        var active: [PodcastTranscriptSegment] = []
        var characterCount = 0

        func emit() {
            guard !active.isEmpty else { return }
            chunks.append(.init(
                index: chunks.count,
                start: active.compactMap(\.start).first,
                end: active.compactMap(\.end).last,
                text: active.map(\.text).joined(separator: " ")
            ))
        }

        for segment in normalizedSegments {
            if !active.isEmpty && characterCount + segment.text.count + 1 > limit {
                emit()
                active = Array(active.suffix(1))
                characterCount = active.reduce(0) { $0 + $1.text.count + 1 }
            }
            active.append(segment)
            characterCount += segment.text.count + 1
        }
        emit()
        return chunks
    }

    static func relevantChunks(for question: String, in chunks: [PodcastTranscriptChunk], limit: Int = 6) -> [PodcastTranscriptChunk] {
        guard chunks.count > limit else { return chunks }
        let queryTerms = terms(in: question)
        guard !queryTerms.isEmpty else { return Array(chunks.prefix(limit)) }

        let scored = chunks.map { chunk -> (PodcastTranscriptChunk, Int) in
            let words = terms(in: chunk.text)
            let score = queryTerms.reduce(0) { $0 + (words.contains($1) ? 1 : 0) }
            return (chunk, score)
        }.sorted {
            if $0.1 == $1.1 { return $0.0.index < $1.0.index }
            return $0.1 > $1.1
        }

        var indexes = Set(scored.prefix(limit).map { $0.0.index })
        if let best = scored.first?.0.index {
            if best > 0 { indexes.insert(best - 1) }
            if best + 1 < chunks.count { indexes.insert(best + 1) }
        }
        return chunks.filter { indexes.contains($0.index) }.prefix(limit + 2).map { $0 }
    }

    static func evidenceText(_ chunks: [PodcastTranscriptChunk]) -> String {
        chunks.map { "\($0.citationLabel) \($0.text)" }.joined(separator: "\n\n")
    }

    private static func split(_ text: String, limit: Int) -> [String] {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.count > limit else { return cleaned.isEmpty ? [] : [cleaned] }
        var result: [String] = []
        var current = ""
        for word in cleaned.split(whereSeparator: { $0.isWhitespace }) {
            if !current.isEmpty && current.count + word.count + 1 > limit {
                result.append(current)
                current = ""
            }
            if !current.isEmpty { current.append(" ") }
            current.append(contentsOf: word)
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    private static func terms(in text: String) -> Set<String> {
        let stopWords: Set<String> = ["about", "after", "again", "also", "and", "are", "did", "does", "episode", "for", "from", "have", "how", "into", "podcast", "that", "the", "their", "this", "was", "were", "what", "when", "where", "which", "who", "why", "with", "would"]
        return Set(text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count > 2 && !stopWords.contains($0) })
    }
}

enum PodcastTranscriptDocumentParser {
    static func parse(data: Data, mimeType: String?, sourceURL: URL) throws -> [PodcastTranscriptSegment] {
        let type = mimeType?.lowercased() ?? ""
        let ext = sourceURL.pathExtension.lowercased()

        if type.contains("json") || ext == "json" {
            let segments = parseJSON(data)
            guard !segments.isEmpty else { throw PodcastEpisodeSupportError.emptyTranscript }
            return segments
        }

        guard let rawText = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .utf16) else {
            throw PodcastEpisodeSupportError.unsupportedTranscript
        }

        if type.contains("vtt") || type.contains("srt") || ext == "vtt" || ext == "srt" || rawText.contains("-->") {
            let segments = parseTimedText(rawText)
            guard !segments.isEmpty else { throw PodcastEpisodeSupportError.emptyTranscript }
            return segments
        }

        let cleaned = cleanText(rawText, treatingAsHTML: type.contains("html") || ["html", "htm"].contains(ext))
        guard !cleaned.isEmpty else { throw PodcastEpisodeSupportError.emptyTranscript }
        return cleaned
            .components(separatedBy: "\n\n")
            .map { cleanText($0, treatingAsHTML: false) }
            .filter { !$0.isEmpty }
            .map { .init(start: nil, end: nil, text: $0) }
    }

    private static func parseTimedText(_ rawText: String) -> [PodcastTranscriptSegment] {
        let lines = rawText.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var result: [PodcastTranscriptSegment] = []
        var start: TimeInterval?
        var end: TimeInterval?
        var cueLines: [String] = []

        func emit() {
            let text = cleanText(cueLines.joined(separator: " "), treatingAsHTML: true)
            if !text.isEmpty { result.append(.init(start: start, end: end, text: text)) }
            start = nil
            end = nil
            cueLines.removeAll(keepingCapacity: true)
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if let range = trimmed.range(of: "-->") {
                emit()
                start = parseTimestamp(String(trimmed[..<range.lowerBound]))
                let right = trimmed[range.upperBound...].trimmingCharacters(in: .whitespaces)
                end = parseTimestamp(String(right.split(separator: " ").first ?? ""))
            } else if trimmed.isEmpty {
                if start != nil { emit() }
            } else if start != nil {
                cueLines.append(trimmed)
            }
        }
        emit()
        return result
    }

    private static func parseTimestamp(_ rawValue: String) -> TimeInterval? {
        let components = rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")
            .split(separator: ":")
            .compactMap { Double($0) }
        if components.count == 3 { return components[0] * 3_600 + components[1] * 60 + components[2] }
        if components.count == 2 { return components[0] * 60 + components[1] }
        return components.first
    }

    private static func parseJSON(_ data: Data) -> [PodcastTranscriptSegment] {
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return [] }
        var result: [PodcastTranscriptSegment] = []

        func number(_ value: Any?) -> TimeInterval? {
            if let number = value as? NSNumber { return number.doubleValue }
            if let string = value as? String { return TimeInterval(string) }
            return nil
        }

        func visit(_ value: Any) {
            if let dictionary = value as? [String: Any] {
                let text = (dictionary["text"] as? String)
                    ?? (dictionary["body"] as? String)
                    ?? (dictionary["content"] as? String)
                if let text {
                    let start = number(dictionary["start"] ?? dictionary["startTime"] ?? dictionary["time"])
                    let explicitEnd = number(dictionary["end"] ?? dictionary["endTime"])
                    let duration = number(dictionary["duration"])
                    let cleaned = cleanText(text, treatingAsHTML: false)
                    if !cleaned.isEmpty {
                        result.append(.init(start: start, end: explicitEnd ?? start.map { $0 + (duration ?? 0) }, text: cleaned))
                    }
                }
                for (key, nested) in dictionary where !["text", "body", "content"].contains(key) {
                    visit(nested)
                }
            } else if let array = value as? [Any] {
                array.forEach(visit)
            }
        }

        visit(object)
        return result
    }

    private static func cleanText(_ rawText: String, treatingAsHTML: Bool) -> String {
        var text = rawText
        if treatingAsHTML {
            text = text.replacingOccurrences(of: "(?is)<(script|style)[^>]*>.*?</\\1>", with: " ", options: .regularExpression)
            text = text.replacingOccurrences(of: "(?i)<br\\s*/?>|</p>|</div>|</li>", with: "\n", options: .regularExpression)
            text = text.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        }
        let entities: [String: String] = [
            "&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">",
            "&quot;": "\"", "&#39;": "'", "&apos;": "'"
        ]
        for (entity, replacement) in entities {
            text = text.replacingOccurrences(of: entity, with: replacement, options: .caseInsensitive)
        }
        text = text.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "\\n[ \\t]+", with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

final class PodcastTranscriptFeedParser: NSObject, XMLParserDelegate {
    private struct FeedItem {
        var title = ""
        var link = ""
        var audioURLs: [String] = []
        var transcriptReferences: [PodcastTranscriptReference] = []
    }

    private let feedURL: URL
    private let episodeTitle: String
    private let episodePageURL: URL?
    private let audioURL: URL
    private var currentElement = ""
    private var currentText = ""
    private var item: FeedItem?
    private var items: [FeedItem] = []

    private init(feedURL: URL, episodeTitle: String, episodePageURL: URL?, audioURL: URL) {
        self.feedURL = feedURL
        self.episodeTitle = episodeTitle
        self.episodePageURL = episodePageURL
        self.audioURL = audioURL
    }

    static func references(in data: Data, feedURL: URL, episodeTitle: String, episodePageURL: URL?, audioURL: URL) -> [PodcastTranscriptReference] {
        let delegate = PodcastTranscriptFeedParser(
            feedURL: feedURL,
            episodeTitle: episodeTitle,
            episodePageURL: episodePageURL,
            audioURL: audioURL
        )
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = false
        parser.delegate = delegate
        guard parser.parse() else { return [] }
        return delegate.bestMatchingReferences()
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let name = (qName ?? elementName).lowercased()
        currentElement = name
        currentText = ""

        if name == "item" || name == "entry" {
            item = FeedItem()
        } else if name.hasSuffix(":transcript") || name == "transcript" {
            guard item != nil,
                  let rawURL = attributeDict["url"] ?? attributeDict["href"],
                  let url = resolve(rawURL) else { return }
            item?.transcriptReferences.append(.init(
                url: url,
                mimeType: attributeDict["type"],
                languageCode: attributeDict["language"] ?? attributeDict["lang"],
                relationship: attributeDict["rel"]
            ))
        } else if name == "enclosure",
                  let rawURL = attributeDict["url"] {
            item?.audioURLs.append(resolve(rawURL)?.absoluteString ?? rawURL)
        } else if name == "link",
                  let href = attributeDict["href"] {
            if attributeDict["rel"]?.lowercased() == "enclosure" {
                item?.audioURLs.append(resolve(href)?.absoluteString ?? href)
            } else if item?.link.isEmpty == true {
                item?.link = resolve(href)?.absoluteString ?? href
            }
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let name = (qName ?? elementName).lowercased()
        let value = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        if name == "title", item != nil, item?.title.isEmpty == true {
            item?.title = value
        } else if name == "link", item != nil, item?.link.isEmpty == true, !value.isEmpty {
            item?.link = resolve(value)?.absoluteString ?? value
        } else if name == "item" || name == "entry" {
            if let item { items.append(item) }
            item = nil
        }
        currentText = ""
    }

    private func bestMatchingReferences() -> [PodcastTranscriptReference] {
        if let audioMatch = items.first(where: { candidate in
            candidate.audioURLs.contains { canonical($0) == canonical(audioURL.absoluteString) }
        }), !audioMatch.transcriptReferences.isEmpty {
            return audioMatch.transcriptReferences
        }

        if let episodePageURL,
           let pageMatch = items.first(where: { canonical($0.link) == canonical(episodePageURL.absoluteString) }),
           !pageMatch.transcriptReferences.isEmpty {
            return pageMatch.transcriptReferences
        }

        let normalizedTitle = normalizeTitle(episodeTitle)
        if let titleMatch = items.first(where: { normalizeTitle($0.title) == normalizedTitle }),
           !titleMatch.transcriptReferences.isEmpty {
            return titleMatch.transcriptReferences
        }
        return []
    }

    private func resolve(_ rawValue: String) -> URL? {
        if let absolute = URL(string: rawValue), absolute.scheme != nil { return absolute }
        return URL(string: rawValue, relativeTo: feedURL)?.absoluteURL
    }

    private func canonical(_ rawValue: String) -> String {
        guard var components = URLComponents(string: rawValue) else { return rawValue.lowercased() }
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        components.fragment = nil
        return components.string ?? rawValue.lowercased()
    }

    private func normalizeTitle(_ value: String) -> String {
        value.lowercased()
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "[^a-z0-9]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

#if os(iOS)
@MainActor
final class PodcastEpisodePlayerController: ObservableObject {
    @Published private(set) var activeEpisodeID: String?
    @Published private(set) var activeEpisodeTitle = "Podcast Episode"
    @Published private(set) var activeShowTitle = ""
    @Published private(set) var activeArtworkURL: URL?
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var playbackRate: Float = 1
    @Published private(set) var errorMessage: String?

    private var player: AVPlayer?
    private var timeObserver: Any?
    private var statusObservation: NSKeyValueObservation?
    private var interruptionObserver: NSObjectProtocol?

    init() {
        configureRemoteCommands()
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor in self?.handleInterruption(notification) }
        }
    }

    deinit {
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        if let interruptionObserver { NotificationCenter.default.removeObserver(interruptionObserver) }
    }

    func prepare(_ article: Article) {
        guard let audioURL = article.podcastAudioURL else {
            errorMessage = PodcastEpisodeSupportError.invalidEpisode.localizedDescription
            return
        }
        guard activeEpisodeID != article.id else { return }

        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        timeObserver = nil
        statusObservation = nil

        activeEpisodeTitle = article.title
        activeShowTitle = article.feedTitle
        activeArtworkURL = article.imageURL
        activeEpisodeID = article.id
        currentTime = 0
        duration = article.podcastDuration ?? 0
        isPlaying = false
        errorMessage = nil

        let item = AVPlayerItem(url: audioURL)
        let newPlayer = AVPlayer(playerItem: item)
        player = newPlayer
        statusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            Task { @MainActor in
                guard let self else { return }
                switch item.status {
                case .readyToPlay:
                    self.refreshDuration(from: item)
                    self.updateNowPlayingInfo()
                case .failed:
                    self.errorMessage = item.error?.localizedDescription ?? "This podcast episode could not be played."
                    self.isPlaying = false
                default:
                    break
                }
            }
        }
        timeObserver = newPlayer.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            Task { @MainActor in
                guard let self else { return }
                let seconds = time.seconds
                if seconds.isFinite { self.currentTime = max(0, seconds) }
                self.isPlaying = self.player?.timeControlStatus == .playing
                self.refreshDuration(from: item)
                self.updateNowPlayingInfo()
            }
        }
        updateNowPlayingInfo()
    }

    func togglePlayback() {
        isPlaying ? pause() : play()
    }

    func play() {
        guard let player else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            // AirPlay output is already supported by the playback category.
            // `.allowAirPlay` is only valid for `.playAndRecord` and causes
            // AVAudioSession to reject this configuration with OSStatus -50.
            try session.setCategory(.playback, mode: .spokenAudio, options: [])
            try session.setActive(true)
            player.playImmediately(atRate: playbackRate)
            isPlaying = true
            errorMessage = nil
            updateNowPlayingInfo()
        } catch {
            errorMessage = "Audio could not start: \(error.localizedDescription)"
        }
    }

    func pause() {
        player?.pause()
        isPlaying = false
        updateNowPlayingInfo()
    }

    func stop() {
        player?.pause()
        if let timeObserver {
            player?.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
        statusObservation = nil
        player = nil
        activeEpisodeID = nil
        activeEpisodeTitle = "Podcast Episode"
        activeShowTitle = ""
        activeArtworkURL = nil
        isPlaying = false
        currentTime = 0
        duration = 0
        errorMessage = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    func seek(to seconds: TimeInterval) {
        guard let player else { return }
        let upperBound = duration > 0 ? duration : max(0, seconds)
        let target = min(max(0, seconds), upperBound)
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = target
        updateNowPlayingInfo()
    }

    func skip(by seconds: TimeInterval) {
        seek(to: currentTime + seconds)
    }

    func setPlaybackRate(_ rate: Float) {
        playbackRate = min(max(rate, 0.5), 2)
        if isPlaying { player?.rate = playbackRate }
        updateNowPlayingInfo()
    }

    private func refreshDuration(from item: AVPlayerItem) {
        let seconds = item.duration.seconds
        if seconds.isFinite, seconds > 0 { duration = seconds }
    }

    private func configureRemoteCommands() {
        let commands = MPRemoteCommandCenter.shared()
        commands.playCommand.isEnabled = true
        commands.pauseCommand.isEnabled = true
        commands.stopCommand.isEnabled = true
        commands.skipForwardCommand.isEnabled = true
        commands.skipBackwardCommand.isEnabled = true
        commands.changePlaybackPositionCommand.isEnabled = true
        commands.skipForwardCommand.preferredIntervals = [15]
        commands.skipBackwardCommand.preferredIntervals = [15]

        commands.playCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            Task { @MainActor in self.play() }
            return .success
        }
        commands.pauseCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            Task { @MainActor in self.pause() }
            return .success
        }
        commands.stopCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            Task { @MainActor in self.stop() }
            return .success
        }
        commands.skipForwardCommand.addTarget { [weak self] event in
            guard let self else { return .commandFailed }
            let interval = (event as? MPSkipIntervalCommandEvent)?.interval ?? 15
            Task { @MainActor in self.skip(by: interval) }
            return .success
        }
        commands.skipBackwardCommand.addTarget { [weak self] event in
            guard let self else { return .commandFailed }
            let interval = (event as? MPSkipIntervalCommandEvent)?.interval ?? 15
            Task { @MainActor in self.skip(by: -interval) }
            return .success
        }
        commands.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let self,
                  let positionEvent = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            Task { @MainActor in self.seek(to: positionEvent.positionTime) }
            return .success
        }
    }

    private func updateNowPlayingInfo() {
        guard activeEpisodeID != nil else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: activeEpisodeTitle,
            MPMediaItemPropertyAlbumTitle: activeShowTitle,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? playbackRate : 0
        ]
        if duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func handleInterruption(_ notification: Notification) {
        guard let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: rawType) else { return }
        if type == .began {
            isPlaying = false
        } else if let rawOptions = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt,
                  AVAudioSession.InterruptionOptions(rawValue: rawOptions).contains(.shouldResume) {
            play()
        }
    }
}
#endif
