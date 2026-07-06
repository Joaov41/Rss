import Foundation
import Combine

class CommentSummaryService {
    private var summaryService: SummaryService
    
    init(summaryService: SummaryService? = nil) {
        self.summaryService = summaryService ?? SummaryService()
    }
    
    func updateSummaryService(_ newSummaryService: SummaryService) {
        self.summaryService = newSummaryService
    }
    
    func summarizeComments(_ comments: [RedditCommentModel]) -> AnyPublisher<CommentSummary, Never> {
        print("📱 CommentSummaryService: Starting summarization of \(comments.count) comments")

        #if os(iOS)
        // Start background task to ensure completion even when locked
        let backgroundHandle = GeminiBackgroundTaskManager.shared.beginLongRunningTask(
            identifier: GeminiBackgroundTaskManager.shared.taskIdentifier(for: .processing),
            title: "Summarizing Comments"
        )
        backgroundHandle.reportProgress(fractionCompleted: 0.1)
        #endif

        // Gemini has a large context window, but this safety cap prevents request overflow.
        var commentTexts = comments.flatMap { extractAllCommentTexts(from: $0) }
        let maxComments = 800
        if commentTexts.count > maxComments {
            print("⚠️ CommentSummaryService: Limiting from \(commentTexts.count) to \(maxComments) comments for Gemini summarization")
            commentTexts = Array(commentTexts.prefix(maxComments))
        }

        // Combine all comments into a single text for summarization
        let combinedText = commentTexts.joined(separator: "\n\n")

        // Get unique commenters across the full loaded thread.
        let commenters = Set(comments.flatMap { extractAllCommentAuthors(from: $0) })
        let topCommenters = Array(commenters).prefix(5).map { $0 }

        print("📱 CommentSummaryService: Preparing to summarize \(commentTexts.count) comments with \(commenters.count) unique commenters")

        #if os(iOS)
        backgroundHandle.reportProgress(fractionCompleted: 0.2)
        #endif

        // Create a customized prompt for Reddit comments instead of using the generic article prompt
        let redditCommentsPrompt = """
        You are analyzing comments from a Reddit post.

        Here are the comments:
        \(combinedText)

        ---
        Task: Briefly summarize ALL the main themes and points discussed in the comments above. For each theme, provide a one-sentence description and, if possible, a short quote as an example. Keep the overall summary concise (5-8 sentences total).
        Return plain text only. Do not use Markdown symbols, headings, bullet markers, or HTML tags.
        """

        return summaryService.summarizeText(
            combinedText,
            customPrompt: redditCommentsPrompt,
            existingBackgroundTaskHandle:
                {
                    #if os(iOS)
                    backgroundHandle
                    #else
                    nil
                    #endif
                }()
        )
            .handleEvents(
                receiveOutput: { _ in
                    #if os(iOS)
                    backgroundHandle.reportProgress(fractionCompleted: 0.9)
                    #endif
                },
                receiveCompletion: { _ in
                    #if os(iOS)
                    backgroundHandle.finish(success: true)
                    print("✅ CommentSummaryService: Background task completed (works when locked)")
                    #endif
                },
                receiveCancel: {
                    #if os(iOS)
                    backgroundHandle.finish(success: false)
                    #endif
                }
            )
            .map { summaryText -> CommentSummary in
                let cleanedSummaryText = cleanAndFormatCommentSummaryForDisplay(summaryText)

                // Analyze sentiment (simplified version)
                let sentiment = self.analyzeSentiment(in: combinedText)

                // Extract main topics (simplified version)
                let mainTopics = self.extractMainTopics(from: cleanedSummaryText)

                print("✅ CommentSummaryService: Summary generated successfully")
                return CommentSummary(
                    postId: comments.first?.id ?? "",
                    subreddit: "",
                    summary: cleanedSummaryText,
                    commentCount: commentTexts.count,
                    topCommenters: Array(topCommenters),
                    mainTopics: mainTopics,
                    sentiment: sentiment,
                    createdDate: Date()
                )
            }
            .eraseToAnyPublisher()
    }
    
    // Helper function to extract all comment texts recursively
    private func extractAllCommentTexts(from comment: RedditCommentModel) -> [String] {
        var texts = [comment.body]
        
        for reply in comment.replies {
            texts.append(contentsOf: extractAllCommentTexts(from: reply))
        }
        
        return texts
    }

    private func extractAllCommentAuthors(from comment: RedditCommentModel) -> [String] {
        var authors: [String] = []
        if !comment.author.isEmpty {
            authors.append(comment.author)
        }

        for reply in comment.replies {
            authors.append(contentsOf: extractAllCommentAuthors(from: reply))
        }

        return authors
    }
    
    // Simple sentiment analysis
    private func analyzeSentiment(in text: String) -> CommentSummary.CommentSentiment {
        let lowercasedText = text.lowercased()
        
        let positiveWords = ["good", "great", "excellent", "amazing", "love", "best", "helpful", "thanks", "appreciate"]
        let negativeWords = ["bad", "terrible", "awful", "hate", "worst", "useless", "disappointing", "problem", "issue"]
        
        var positiveCount = 0
        var negativeCount = 0
        
        for word in positiveWords {
            positiveCount += lowercasedText.components(separatedBy: word).count - 1
        }
        
        for word in negativeWords {
            negativeCount += lowercasedText.components(separatedBy: word).count - 1
        }
        
        if positiveCount > negativeCount * 2 {
            return .positive
        } else if negativeCount > positiveCount * 2 {
            return .negative
        } else if positiveCount > 0 && negativeCount > 0 {
            return .mixed
        } else {
            return .neutral
        }
    }
    
    // Simple topic extraction
    private func extractMainTopics(from text: String) -> [String] {
        let words = text.components(separatedBy: .whitespacesAndNewlines)
            .map { $0.lowercased().trimmingCharacters(in: .punctuationCharacters) }
            .filter { $0.count > 4 } // Only consider words with more than 4 characters
        
        let stopWords = ["about", "above", "after", "again", "against", "their", "would", "could", "should", "which", "there", "these", "those", "where", "while", "because"]
        
        let filteredWords = words.filter { !stopWords.contains($0) }
        
        // Count word frequencies
        var wordCounts: [String: Int] = [:]
        for word in filteredWords {
            wordCounts[word, default: 0] += 1
        }
        
        // Sort by frequency and take top 5
        let sortedWords = wordCounts.sorted { $0.value > $1.value }
        let topWords = sortedWords.prefix(5).map { $0.key }
        
        return topWords
    }
}
