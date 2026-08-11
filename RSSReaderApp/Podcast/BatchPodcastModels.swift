import Foundation

enum PodcastSpeaker: String, Codable, CaseIterable, Identifiable {
    case hostA
    case hostB

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .hostA: return "Host A"
        case .hostB: return "Host B"
        }
    }
}

struct PodcastTurn: Codable, Equatable, Identifiable {
    let id: UUID
    let speaker: PodcastSpeaker
    let text: String
    let sourceIDs: [String]

    init(
        id: UUID = UUID(),
        speaker: PodcastSpeaker,
        text: String,
        sourceIDs: [String] = []
    ) {
        self.id = id
        self.speaker = speaker
        self.text = text
        self.sourceIDs = sourceIDs
    }
}

struct PodcastEpisode: Codable, Equatable, Identifiable {
    static let currentSchemaVersion = 1
    static let maximumWords = 1_060

    let id: UUID
    let schemaVersion: Int
    let title: String
    let summary: String
    let sourceDigest: String
    let createdAt: Date
    let estimatedDuration: TimeInterval
    let turns: [PodcastTurn]

    var spokenText: String {
        turns.map(\.text).joined(separator: " ")
    }

    var spokenWordCount: Int {
        turns.reduce(0) { $0 + $1.text.split(whereSeparator: \.isWhitespace).count }
    }

    func withTurns(_ turns: [PodcastTurn], duration: TimeInterval? = nil) -> PodcastEpisode {
        PodcastEpisode(
            id: id,
            schemaVersion: schemaVersion,
            title: title,
            summary: summary,
            sourceDigest: sourceDigest,
            createdAt: createdAt,
            estimatedDuration: duration ?? estimatedDuration,
            turns: turns
        )
    }

    init(
        id: UUID = UUID(),
        schemaVersion: Int = PodcastEpisode.currentSchemaVersion,
        title: String,
        summary: String,
        sourceDigest: String,
        createdAt: Date = Date(),
        estimatedDuration: TimeInterval = 0,
        turns: [PodcastTurn]
    ) {
        self.id = id
        self.schemaVersion = schemaVersion
        self.title = title
        self.summary = summary
        self.sourceDigest = sourceDigest
        self.createdAt = createdAt
        self.estimatedDuration = estimatedDuration
        self.turns = turns
    }
}

enum BatchPodcastSourceKind: String, Codable {
    case article
    case redditPost
    case redditComment
}

struct BatchPodcastSource: Codable, Equatable, Hashable {
    let sourceID: String
    let kind: BatchPodcastSourceKind
    let title: String
    let permalink: String
    let text: String
    let parentSourceID: String?
    let ordinal: Int
}

/// Immutable evidence captured when the user opens Batch Podcast. Building it
/// only reads AppState's retained values and never performs network work.
struct BatchPodcastSnapshot {
    let posts: [RedditPost]
    let articles: [Article]
    let cachedComments: [(RedditPost, [String])]
    let summaryResult: GlobalSummaryResult
    let overallSummary: String?
}

struct BatchPodcastEvidenceChunk: Codable, Equatable, Identifiable {
    let id: String
    let text: String
    let sourceIDs: [String]
}

struct BatchPodcastContext: Codable {
    let title: String
    let sourceKind: String
    let sourceDigest: String
    let sources: [BatchPodcastSource]
    let evidenceChunks: [BatchPodcastEvidenceChunk]
    let perItemSummaries: [GlobalSummaryItem]
    let overallSummary: String?
    let isSummariesOnly: Bool

    var knownSourceIDs: Set<String> {
        Set(sources.map(\.sourceID))
    }
}

struct PodcastEvidenceClaim: Codable, Equatable {
    let text: String
    let sourceIDs: [String]
}

struct PodcastEvidenceReport: Codable, Equatable {
    let chunkID: String
    let sourceIDs: [String]
    let claims: [PodcastEvidenceClaim]
    let tensions: [String]
    let unknowns: [String]
}

struct PodcastOutlineBeat: Codable, Equatable {
    let title: String
    let talkingPoints: [String]
    let evidenceRefs: [String]
}

struct PodcastOutline: Codable, Equatable {
    let title: String
    let summary: String
    let beats: [PodcastOutlineBeat]
}

struct PodcastDraftTurn: Decodable, Equatable {
    let id: UUID
    let speaker: PodcastSpeaker
    let text: String
    let evidenceRefs: [String]

    init(
        id: UUID = UUID(),
        speaker: PodcastSpeaker,
        text: String,
        evidenceRefs: [String] = []
    ) {
        self.id = id
        self.speaker = speaker
        self.text = text
        self.evidenceRefs = evidenceRefs
    }

    private enum CodingKeys: String, CodingKey {
        case id, speaker, text, evidenceRefs, sourceIDs
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        if let decodedID = try? container.decode(UUID.self, forKey: .id) {
            id = decodedID
        } else if let stringID = try? container.decode(String.self, forKey: .id),
                  let decodedID = UUID(uuidString: stringID) {
            id = decodedID
        } else {
            id = UUID()
        }

        let rawSpeaker = (try? container.decode(String.self, forKey: .speaker)) ?? ""
        switch rawSpeaker.lowercased().filter({ $0.isLetter || $0.isNumber }) {
        case "hosta", "a", "host1", "1": speaker = .hostA
        case "hostb", "b", "host2", "2": speaker = .hostB
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .speaker,
                in: container,
                debugDescription: "Unknown podcast speaker."
            )
        }

        text = (try? container.decode(String.self, forKey: .text)) ?? ""
        if let refs = try? container.decode([String].self, forKey: .evidenceRefs) {
            evidenceRefs = refs
        } else if let ref = try? container.decode(String.self, forKey: .evidenceRefs) {
            evidenceRefs = [ref]
        } else if let sourceIDs = try? container.decode([String].self, forKey: .sourceIDs) {
            evidenceRefs = sourceIDs
        } else if let sourceID = try? container.decode(String.self, forKey: .sourceIDs) {
            evidenceRefs = [sourceID]
        } else {
            evidenceRefs = []
        }
    }
}

struct PodcastDraftEpisode: Decodable, Equatable {
    let id: UUID
    let schemaVersion: Int
    let title: String
    let summary: String
    let sourceDigest: String
    let createdAt: Date
    let estimatedDuration: TimeInterval
    let turns: [PodcastDraftTurn]

    private enum CodingKeys: String, CodingKey {
        case id, schemaVersion, title, summary, sourceDigest, createdAt, estimatedDuration, turns
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let decodedID = try? container.decode(UUID.self, forKey: .id) {
            id = decodedID
        } else if let stringID = try? container.decode(String.self, forKey: .id),
                  let decodedID = UUID(uuidString: stringID) {
            id = decodedID
        } else {
            id = UUID()
        }
        schemaVersion = (try? container.decode(Int.self, forKey: .schemaVersion)) ?? PodcastEpisode.currentSchemaVersion
        title = (try? container.decode(String.self, forKey: .title)) ?? "Batch Podcast"
        summary = (try? container.decode(String.self, forKey: .summary)) ?? ""
        sourceDigest = (try? container.decode(String.self, forKey: .sourceDigest)) ?? ""
        createdAt = (try? container.decode(Date.self, forKey: .createdAt)) ?? Date()
        estimatedDuration = (try? container.decode(Double.self, forKey: .estimatedDuration)) ?? 0
        turns = (try? container.decode([PodcastDraftTurn].self, forKey: .turns)) ?? []
    }
}

enum BatchPodcastProgress: Equatable {
    case analyzingChunk(current: Int, total: Int)
    case mergingEvidence
    case outlining
    case writingScript
    case repairingJSON
    case validating
    case ready

    var message: String {
        switch self {
        case let .analyzingChunk(current, total): return "Analyzing saved evidence \(current) of \(total)…"
        case .mergingEvidence: return "Merging the evidence…"
        case .outlining: return "Planning the conversation…"
        case .writingScript: return "Writing the podcast script…"
        case .repairingJSON: return "Repairing the structured script…"
        case .validating: return "Checking the grounded script…"
        case .ready: return "Podcast ready"
        }
    }
}

enum BatchPodcastError: LocalizedError, Equatable {
    case noBatchEvidence
    case summariesOnlyRequiresExplicitOptIn
    case invalidScript(String)
    case providerFailure(String)
    case digestMismatch
    case audioExportFailed(String)

    var errorDescription: String? {
        switch self {
        case .noBatchEvidence:
            return "There is no saved Batch Summary evidence to use for a podcast."
        case .summariesOnlyRequiresExplicitOptIn:
            return "This batch has no saved raw comments. Confirm the summaries-only fallback to continue."
        case let .invalidScript(message):
            return "The podcast script was not valid: \(message)"
        case let .providerFailure(message):
            return message
        case .digestMismatch:
            return "The batch changed while the podcast was being generated. Generate it again."
        case let .audioExportFailed(message):
            return "The podcast audio could not be exported: \(message)"
        }
    }
}

enum BatchPodcastJSONDecoder {
    static func decode<T: Decodable>(_ type: T.Type, from raw: String) -> T? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let cleaned = trimmed
            .replacingOccurrences(of: #"```(?:json|JSON)?\s*"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let candidates = [cleaned] + balancedFragments(in: cleaned)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var seen = Set<String>()

        for candidate in candidates where seen.insert(candidate).inserted {
            guard let data = candidate.data(using: .utf8) else { continue }
            if let value = try? decoder.decode(type, from: data) {
                return value
            }
            if let object = try? JSONSerialization.jsonObject(with: data),
               let nested = object as? [String: Any] {
                for key in ["episode", "podcast", "script", "result", "data"] {
                    guard let value = nested[key], JSONSerialization.isValidJSONObject(value),
                          let nestedData = try? JSONSerialization.data(withJSONObject: value),
                          let decoded = try? decoder.decode(type, from: nestedData) else { continue }
                    return decoded
                }
            }
        }
        return nil
    }

    private static func balancedFragments(in text: String) -> [String] {
        let characters = Array(text)
        var result: [String] = []

        for start in characters.indices where characters[start] == "{" || characters[start] == "[" {
            var stack: [Character] = []
            var quoted = false
            var escaped = false

            for index in start..<characters.endIndex {
                let character = characters[index]
                if quoted {
                    if escaped { escaped = false }
                    else if character == "\\" { escaped = true }
                    else if character == "\"" { quoted = false }
                    continue
                }
                if character == "\"" { quoted = true }
                else if character == "{" || character == "[" { stack.append(character) }
                else if character == "}" || character == "]" {
                    guard let opening = stack.last,
                          (opening == "{" && character == "}") || (opening == "[" && character == "]") else { break }
                    stack.removeLast()
                    if stack.isEmpty {
                        result.append(String(characters[start...index]))
                        break
                    }
                }
            }
        }
        return result
    }
}

enum PodcastSpokenTextCleaner {
    static func clean(_ text: String) -> String {
        var value = text
            .replacingOccurrences(of: #"\[SOURCE:\s*[^\]]+\]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\[([^\]]+)\]\((?:https?://|www\.)[^\)]*\)"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"https?://\S+|www\.\S+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?im)^\s*(?:intro|outro|sfx|music|sound effect|direction)\s*:\s*.*$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)\[(?:music|sfx|sound effect|pause|intro|outro|laughs?|stage direction)[^\]]*\]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?im)^\s*(?:#{1,6}\s*|[-*+]\s+|\d+[.)]\s+)"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)\b(?:reddit-post|reddit-comment|article|summary):[A-Za-z0-9._:-]+\b|\bevidence-\d+\b"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "__", with: "")
            .replacingOccurrences(of: "`", with: "")
            .replacingOccurrences(of: #"(?im)^\s*(?:host\s*a|host\s*b|hostA|hostB)\s*:\s*"#, with: "", options: .regularExpression)

        value = value
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value
    }

    static func trimToWordCount(_ text: String, maximumWords: Int) -> String {
        let words = text.split(whereSeparator: \.isWhitespace)
        guard words.count > maximumWords, maximumWords > 0 else { return text }
        var result = words.prefix(maximumWords).map(String.init).joined(separator: " ")
        if let last = result.last, !".!?".contains(last) { result.append(".") }
        return result
    }
}

enum PodcastEpisodeWordLimiter {
    static func limit(_ episode: PodcastEpisode, maximumWords: Int = PodcastEpisode.maximumWords) -> PodcastEpisode {
        guard episode.spokenWordCount > maximumWords else { return episode }
        var turns = episode.turns
        var overflow = episode.spokenWordCount - maximumWords

        for index in turns.indices.reversed() where overflow > 0 {
            let current = turns[index].text.split(whereSeparator: \.isWhitespace).count
            guard current > 1 else { continue }
            let target = max(1, current - overflow)
            let shortened = PodcastSpokenTextCleaner.trimToWordCount(turns[index].text, maximumWords: target)
            let removed = current - shortened.split(whereSeparator: \.isWhitespace).count
            turns[index] = PodcastTurn(
                id: turns[index].id,
                speaker: turns[index].speaker,
                text: shortened,
                sourceIDs: turns[index].sourceIDs
            )
            overflow -= removed
        }

        while overflow > 0, let last = turns.last {
            turns.removeLast()
            overflow -= last.text.split(whereSeparator: \.isWhitespace).count
        }
        return episode.withTurns(turns)
    }
}
