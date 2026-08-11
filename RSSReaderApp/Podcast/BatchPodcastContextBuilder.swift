import CryptoKit
import Foundation

enum BatchPodcastContextBuilder {
    static let maximumChunkCharacters = 24_000

    private struct CanonicalSource: Encodable {
        let id: String
        let kind: String
        let title: String
        let permalink: String
        let text: String
        let parent: String?
        let ordinal: Int
    }

    static func build(
        snapshot: BatchPodcastSnapshot,
        allowSummariesOnly: Bool,
        maximumCharacters: Int = maximumChunkCharacters
    ) throws -> BatchPodcastContext {
        try build(
            posts: snapshot.posts,
            articles: snapshot.articles,
            cachedComments: snapshot.cachedComments,
            summaryResult: snapshot.summaryResult,
            overallSummary: snapshot.overallSummary,
            allowSummariesOnly: allowSummariesOnly,
            maximumCharacters: maximumCharacters
        )
    }

    static func build(
        posts: [RedditPost],
        articles: [Article],
        cachedComments: [(RedditPost, [String])],
        summaryResult: GlobalSummaryResult,
        overallSummary: String?,
        allowSummariesOnly: Bool,
        maximumCharacters: Int = maximumChunkCharacters
    ) throws -> BatchPodcastContext {
        let isReddit = summaryResult.source.lowercased() == "reddit"
        let summaries = summaryResult.summaries
        var sources: [BatchPodcastSource] = []
        var chunks: [BatchPodcastEvidenceChunk] = []

        let summaryByReference = summaries.reduce(into: [String: GlobalSummaryItem]()) { result, item in
            guard let reference = item.referenceId?.trimmingCharacters(in: .whitespacesAndNewlines), !reference.isEmpty else { return }
            if result[reference] == nil { result[reference] = item }
        }

        if isReddit {
            var postsByID: [String: RedditPost] = [:]
            for post in posts { postsByID[post.id] = post }
            for (post, _) in cachedComments where postsByID[post.id] == nil {
                postsByID[post.id] = post
            }
            let orderedPosts = postsByID.values.sorted { lhs, rhs in
                let leftIndex = summaries.firstIndex { $0.referenceId == lhs.id } ?? Int.max
                let rightIndex = summaries.firstIndex { $0.referenceId == rhs.id } ?? Int.max
                return leftIndex == rightIndex ? lhs.id < rhs.id : leftIndex < rightIndex
            }

            for post in orderedPosts {
                let postSourceID = "reddit-post:\(post.id)"
                let summary = summaryByReference[post.id]?.summary ?? post.summary ?? ""
                let postText = post.content.trimmingCharacters(in: .whitespacesAndNewlines)
                let combined = [
                    "Post title: \(post.title)",
                    postText.isEmpty ? nil : "Post text: \(postText)",
                    summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : "Saved summary: \(summary)"
                ].compactMap { $0 }.joined(separator: "\n")

                sources.append(
                    BatchPodcastSource(
                        sourceID: postSourceID,
                        kind: .redditPost,
                        title: post.title,
                        permalink: post.url?.absoluteString ?? "",
                        text: combined,
                        parentSourceID: nil,
                        ordinal: sources.count
                    )
                )
                chunks.append(contentsOf: split(
                    text: combined,
                    sourceIDs: [postSourceID],
                    prefix: "post-\(post.id)",
                    maximumCharacters: maximumCharacters
                ))
            }

            var commentsByPostID: [String: [String]] = [:]
            for (post, comments) in cachedComments { commentsByPostID[post.id] = comments }
            for post in orderedPosts {
                guard let savedComments = commentsByPostID[post.id] else { continue }
                for (index, comment) in savedComments.enumerated() {
                    let commentText = comment.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !commentText.isEmpty else { continue }
                    let sourceID = "reddit-comment:\(post.id):\(index)"
                    let parentID = "reddit-post:\(post.id)"
                    sources.append(
                        BatchPodcastSource(
                            sourceID: sourceID,
                            kind: .redditComment,
                            title: post.title,
                            permalink: post.url?.absoluteString ?? "",
                            text: commentText,
                            parentSourceID: parentID,
                            ordinal: index
                        )
                    )
                    chunks.append(contentsOf: split(
                        text: "Post: \(post.title)\nSaved comment \(index + 1): \(commentText)",
                        sourceIDs: [parentID, sourceID],
                        prefix: "comment-\(post.id)-\(index + 1)",
                        maximumCharacters: maximumCharacters
                    ))
                }
            }
        } else {
            for article in articles {
                let summary = summaryByReference[article.id]?.summary ?? article.summary ?? ""
                let content = article.content.trimmingCharacters(in: .whitespacesAndNewlines)
                let combined = [
                    "Article title: \(article.title)",
                    content.isEmpty ? nil : "Article text: \(content)",
                    summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : "Saved summary: \(summary)"
                ].compactMap { $0 }.joined(separator: "\n")
                let sourceID = "article:\(article.id)"
                sources.append(
                    BatchPodcastSource(
                        sourceID: sourceID,
                        kind: .article,
                        title: article.title,
                        permalink: article.url?.absoluteString ?? article.feedURL,
                        text: combined,
                        parentSourceID: nil,
                        ordinal: sources.count
                    )
                )
                chunks.append(contentsOf: split(
                    text: combined,
                    sourceIDs: [sourceID],
                    prefix: "article-\(article.id)",
                    maximumCharacters: maximumCharacters
                ))
            }
        }

        let referencedIDs = Set(sources.map(\.sourceID))
        for (index, item) in summaries.enumerated() {
            let matchingID = item.referenceId.flatMap { reference in
                let candidate = isReddit ? "reddit-post:\(reference)" : "article:\(reference)"
                return referencedIDs.contains(candidate) ? candidate : nil
            }
            guard matchingID == nil else { continue }
            let sourceID = "summary:\(item.referenceId ?? String(index + 1))"
            sources.append(
                BatchPodcastSource(
                    sourceID: sourceID,
                    kind: isReddit ? .redditPost : .article,
                    title: item.subject,
                    permalink: "",
                    text: item.summary,
                    parentSourceID: nil,
                    ordinal: sources.count
                )
            )
            chunks.append(contentsOf: split(
                text: "Saved summary for \(item.subject): \(item.summary)",
                sourceIDs: [sourceID],
                prefix: "summary-\(index + 1)",
                maximumCharacters: maximumCharacters
            ))
        }

        let rawCommentCount = sources.reduce(into: 0) { count, source in
            if source.kind == .redditComment { count += 1 }
        }
        let hasArticleText = sources.contains {
            $0.kind == .article && $0.text.range(of: "Article text:", options: .caseInsensitive) != nil
        }
        let summariesOnly = isReddit ? rawCommentCount == 0 : !hasArticleText

        if summariesOnly && !allowSummariesOnly {
            throw BatchPodcastError.summariesOnlyRequiresExplicitOptIn
        }

        if chunks.isEmpty {
            let fallbackIDs = sources.map(\.sourceID)
            let fallbackText = overallSummary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !fallbackText.isEmpty {
                chunks = split(
                    text: "Saved overall summary:\n\(fallbackText)",
                    sourceIDs: fallbackIDs,
                    prefix: "overall-summary",
                    maximumCharacters: maximumCharacters
                )
            }
        }

        guard !sources.isEmpty, !chunks.isEmpty else {
            throw BatchPodcastError.noBatchEvidence
        }

        let title = isReddit ? "Reddit Batch Podcast" : "Article Batch Podcast"
        return BatchPodcastContext(
            title: title,
            sourceKind: isReddit ? "reddit" : "articles",
            sourceDigest: digest(sources: sources, summaries: summaries, overallSummary: overallSummary),
            sources: sources,
            evidenceChunks: chunks,
            perItemSummaries: summaries,
            overallSummary: overallSummary?.trimmingCharacters(in: .whitespacesAndNewlines),
            isSummariesOnly: summariesOnly
        )
    }

    static func digest(
        sources: [BatchPodcastSource],
        summaries: [GlobalSummaryItem],
        overallSummary: String?
    ) -> String {
        let canonicalSources = sources
            .sorted { $0.sourceID < $1.sourceID }
            .map {
                CanonicalSource(
                    id: $0.sourceID,
                    kind: $0.kind.rawValue,
                    title: $0.title,
                    permalink: $0.permalink,
                    text: $0.text,
                    parent: $0.parentSourceID,
                    ordinal: $0.ordinal
                )
            }
        let payload: [String: AnyEncodable] = [
            "sources": AnyEncodable(canonicalSources),
            "summaries": AnyEncodable(
                summaries.sorted {
                    ($0.referenceId ?? "", $0.subject, $0.summary) < ($1.referenceId ?? "", $1.subject, $1.summary)
                }
            ),
            "overall": AnyEncodable(overallSummary ?? "")
        ]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(payload)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func split(
        text: String,
        sourceIDs: [String],
        prefix: String,
        maximumCharacters: Int
    ) -> [BatchPodcastEvidenceChunk] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let limit = max(1, maximumCharacters)
        var result: [BatchPodcastEvidenceChunk] = []
        var remaining = trimmed
        var index = 1
        while !remaining.isEmpty {
            let length = min(limit, remaining.count)
            let end = remaining.index(remaining.startIndex, offsetBy: length)
            var part = String(remaining[..<end])
            if end < remaining.endIndex,
               let breakIndex = part.lastIndex(where: { $0 == "\n" || $0 == "." || $0 == "!" || $0 == "?" }),
               breakIndex > part.startIndex {
                let candidateEnd = part.index(after: breakIndex)
                part = String(part[..<candidateEnd])
            }
            part = part.trimmingCharacters(in: .whitespacesAndNewlines)
            if !part.isEmpty {
                result.append(
                    BatchPodcastEvidenceChunk(
                        id: "\(prefix)-\(index)",
                        text: part,
                        sourceIDs: Array(Set(sourceIDs)).sorted()
                    )
                )
                index += 1
            }
            let consumed = part.count
            if consumed == 0 { break }
            remaining = String(remaining.dropFirst(consumed)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return result
    }
}

private struct AnyEncodable: Encodable {
    private let encodeValue: (Encoder) throws -> Void

    init<T: Encodable>(_ value: T) {
        encodeValue = value.encode(to:)
    }

    func encode(to encoder: Encoder) throws {
        try encodeValue(encoder)
    }
}
