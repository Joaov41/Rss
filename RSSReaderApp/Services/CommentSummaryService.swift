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
        
        // Extract all comment text - but limit the total amount to avoid performance issues
        var commentTexts = comments.flatMap { extractAllCommentTexts(from: $0) }
        
        // Limit the number of comments to process if there are too many
        let maxComments = 800 // Adjust this based on empirical performance testing
        if commentTexts.count > maxComments {
            print("⚠️ CommentSummaryService: Limiting from \(commentTexts.count) to \(maxComments) comments for summarization")
            commentTexts = Array(commentTexts.prefix(maxComments))
        }
        
        // Combine all comments into a single text for summarization
        let combinedText = commentTexts.joined(separator: "\n\n")
        
        // Get unique commenters - working with the original list so we have complete data
        var commenters = Set<String>()
        // Limit to a reasonable number to avoid performance issues
        for comment in comments.prefix(1000) {
            commenters.insert(comment.author)
        }
        let topCommenters = Array(commenters).prefix(5).map { $0 }
        
        print("📱 CommentSummaryService: Preparing to summarize \(commentTexts.count) comments with \(commenters.count) unique commenters")
        
        // Create a customized prompt for Reddit comments instead of using the generic article prompt
        let redditCommentsPrompt = """
        You are analyzing comments from a Reddit post.

        Here are the comments:
        \(combinedText)

        ---
        Task: Briefly summarize the top 2-3 main themes and points discussed in the comments above. For each theme, provide a one-sentence description and, if possible, a short quote as an example. Keep the overall summary concise (5-8 sentences total).

        Format your response in plain text. Do NOT include Markdown symbols (such as #, *, _, or `) and do NOT include any HTML tags.

        Example Structure:

        Theme 1: One-sentence summary. Example: "[Short quote]"
        Theme 2: One-sentence summary. Example: "[Short quote]"

        Final Overall Summary: One or two sentences summarizing the general tone and main takeaways.
        """
        
        return summaryService.summarizeText(combinedText, customPrompt: redditCommentsPrompt)
            .map { summaryText -> CommentSummary in
                let cleanedSummary = self.cleanMarkdownArtifactsForDisplay(summaryText)
                // Analyze sentiment (simplified version)
                let sentiment = self.analyzeSentiment(in: combinedText)
                
                // Extract main topics (simplified version)
                let mainTopics = self.extractMainTopics(from: cleanedSummary)
                
                print("✅ CommentSummaryService: Summary generated successfully")
                return CommentSummary(
                    postId: comments.first?.id ?? "",
                    subreddit: "",
                    summary: cleanedSummary,
                    commentCount: commentTexts.count,
                    topCommenters: Array(topCommenters),
                    mainTopics: mainTopics,
                    sentiment: sentiment,
                    createdDate: Date()
                )
            }
            .eraseToAnyPublisher()
    }

    private func cleanMarkdownArtifactsForDisplay(_ input: String) -> String {
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
    
    // Helper function to extract all comment texts recursively
    private func extractAllCommentTexts(from comment: RedditCommentModel) -> [String] {
        var texts = [comment.body]
        
        // Limit recursion depth for very nested comment threads
        if comment.indentationLevel < 10 {
            for reply in comment.replies {
                texts.append(contentsOf: extractAllCommentTexts(from: reply))
            }
        } else {
            // For deeply nested comments, just include the direct text without replies
            print("⚠️ CommentSummaryService: Limiting recursion depth for deeply nested comment")
        }
        
        return texts
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
