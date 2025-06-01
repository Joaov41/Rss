import Foundation
import Combine

class RedditService {
    private let baseURL = "https://www.reddit.com"
    private var session: URLSession
    private var linkId: String?
    private let maxRetryCount = 3
    private let backoffFactor = 1.5
    
    // Add a cache for Reddit comments
    private var commentCache: [String: [RedditCommentModel]] = [:]
    private let maxCacheSize = 10 // Cache at most 10 posts worth of comments
    
    init() {
        let config = URLSessionConfiguration.default
        config.requestCachePolicy = .reloadRevalidatingCacheData
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        self.session = URLSession(configuration: config)
    }
    
    // MARK: - Sort Options
    enum SortOption: String {
        case hot = "hot"
        case new = "new"
    }
    
    // MARK: - Subreddit Fetching
    func fetchSubreddit(subreddit: String, sortOption: SortOption = .hot) -> AnyPublisher<RedditFeed, Never> {
        // Set limit based on sort option
        let limit: Int
        switch sortOption {
        case .hot:
            limit = 80
        case .new:
            limit = 150
        }
        let urlString = "\(baseURL)/r/\(subreddit)/\(sortOption.rawValue)/.json?limit=\(limit)"
        
        guard let url = URL(string: urlString) else {
            print("❌ RedditService: Invalid URL for subreddit: \(subreddit)")
            return Just(RedditFeed(subreddit: subreddit, displayName: "Invalid Subreddit", posts: []))
                .eraseToAnyPublisher()
        }
        
        var request = URLRequest(url: url)
        request.addValue("application/json", forHTTPHeaderField: "Accept")
        request.addValue("RSS Reader App/1.0", forHTTPHeaderField: "User-Agent")
        
        return session.dataTaskPublisher(for: request)
            .map { $0.data }
            .decode(type: RedditListing.self, decoder: JSONDecoder())
            .map { listing -> RedditFeed in
                print("📱 RedditService: Decoded Reddit data for r/\(subreddit), found \(listing.data.children.count) posts")
                
                let posts = listing.data.children.compactMap { child -> RedditPost? in
                    guard let data = child.data else { return nil }
                    
                    return RedditPost(
                        id: data.id,
                        title: data.title,
                        content: data.selftext ?? "",
                        url: URL(string: data.url ?? ""),
                        publishDate: Date(timeIntervalSince1970: TimeInterval(data.created_utc ?? 0)),
                        author: data.author ?? "Unknown",
                        subreddit: subreddit,
                        score: data.score ?? 0,
                        commentCount: data.num_comments ?? 0,
                        isRead: false,
                        isFavorite: false,
                        thumbnail: data.thumbnail
                    )
                }
                
                print("📱 RedditService: Created \(posts.count) RedditPost objects with sort: \(sortOption.rawValue)")
                
                return RedditFeed(
                    subreddit: subreddit,
                    displayName: "r/\(subreddit)",
                    description: listing.data.children.first?.data?.subreddit_description,
                    iconURL: nil,
                    posts: posts
                )
            }
            .catch { error -> AnyPublisher<RedditFeed, Never> in
                print("❌ RedditService: Error fetching r/\(subreddit): \(error.localizedDescription)")
                return Just(RedditFeed(
                    subreddit: subreddit, 
                    displayName: "Error Loading Subreddit", 
                    posts: []
                )).eraseToAnyPublisher()
            }
            .eraseToAnyPublisher()
    }
    
    // MARK: - Comments Fetching
    func fetchComments(for postId: String, in subreddit: String, limit: Int = 1000, depth: Int = 10) -> AnyPublisher<[RedditCommentModel], Never> {
        // Check cache first
        let cacheKey = "\(subreddit)_\(postId)"
        if let cachedComments = commentCache[cacheKey] {
            print("📱 RedditService: Using cached comments for post ID: \(postId) in r/\(subreddit)")
            return Just(cachedComments).eraseToAnyPublisher()
        }
        
        var components = URLComponents(string: "\(baseURL)/r/\(subreddit)/comments/\(postId)/.json")!
        components.queryItems = [
            URLQueryItem(name: "limit", value: "\(limit)"),
            URLQueryItem(name: "depth", value: "\(depth)"),
            URLQueryItem(name: "threaded", value: "false")
        ]
        
        guard let url = components.url else {
            print("⚠️ RedditService: Invalid URL")
            return Just([]).eraseToAnyPublisher()
        }
        
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        
        print("🌐 RedditService: Fetching comments from: \(url)")
        
        return session.dataTaskPublisher(for: request)
            .map(\.data)
            .tryMap { data -> [RedditCommentModel] in
                guard let json = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
                      json.count > 1,
                      let postData = json[0] as? [String: Any],
                      let postDataChildren = (postData["data"] as? [String: Any])?["children"] as? [[String: Any]],
                      let firstPost = postDataChildren.first?["data"] as? [String: Any],
                      let postId = firstPost["id"] as? String else {
                    print("⚠️ RedditService: Failed to parse JSON response")
                    throw URLError(.cannotParseResponse)
                }
                
                self.linkId = "t3_\(postId)"
                
                let dataDict = json[1]["data"] as? [String: Any]
                let commentsArray = dataDict?["children"] as? [[String: Any]] ?? []
                
                print("📝 RedditService: Found \(commentsArray.count) top-level comments")
                
                // This is potentially expensive, so we use performance optimized version
                let comments = try self.parseCommentsEfficiently(commentsArray)
                
                print("✅ RedditService: Parsed and processed \(comments.count) comments total")
                return comments
            }
            .handleEvents(receiveOutput: { comments in
                print("📊 RedditService: Returning \(comments.count) comments")
                
                // Add to cache
                self.addToCache(comments, for: cacheKey)
            })
            .replaceError(with: [])
            .eraseToAnyPublisher()
    }
    
    // Optimized version that avoids recursion for better performance
    private func parseCommentsEfficiently(_ commentsArray: [[String: Any]]) throws -> [RedditCommentModel] {
        var result = [RedditCommentModel]()
        
        // Use a queue instead of recursion to avoid stack overflows with deep comment trees
        var queue = [(commentDict: [String: Any], depth: Int)]()
        
        // Initialize queue with top-level comments
        for commentDict in commentsArray {
            queue.append((commentDict, 0))
        }
        
        // Process comments breadth-first
        while !queue.isEmpty {
            let (commentDict, depth) = queue.removeFirst()
            
            guard let kind = commentDict["kind"] as? String else { continue }
            
            if kind == "t1" {
                guard let commentData = commentDict["data"] as? [String: Any],
                      let id = commentData["id"] as? String,
                      let author = commentData["author"] as? String,
                      let body = commentData["body"] as? String,
                      let score = commentData["score"] as? Int,
                      let createdUtc = commentData["created_utc"] as? Double else {
                    continue
                }
                
                // Process replies and add to queue if they exist
                var replies: [RedditCommentModel] = []
                if let repliesDict = commentData["replies"] as? [String: Any],
                   let repliesData = repliesDict["data"] as? [String: Any],
                   let children = repliesData["children"] as? [[String: Any]] {
                    
                    // Don't process replies if we're too deep to improve performance
                    if depth < 15 {
                        for childDict in children {
                            queue.append((childDict, depth + 1))
                        }
                    } else {
                        print("⚠️ RedditService: Hit max depth limit, truncating nested comments")
                    }
                }
                
                // Create comment model - without replies initially, we'll add those later
                let comment = RedditCommentModel(
                    id: id,
                    author: author,
                    body: body,
                    score: score,
                    createdUtc: createdUtc,
                    replies: replies, 
                    indentationLevel: depth
                )
                
                result.append(comment)
                
            } else if kind == "more" {
                // For performance reasons, we'll skip processing "more" comments
                // unless they're explicitly needed (which isn't the case for summarization)
                // This avoids expensive API calls and processing
                
                if let moreData = commentDict["data"] as? [String: Any],
                   let count = moreData["count"] as? Int {
                    print("⚠️ RedditService: Skipping \(count) 'more' comments for performance")
                }
            }
        }
        
        return result
    }
    
    private func parseAllComments(_ commentsArray: [[String: Any]], depth: Int = 0) throws -> [RedditCommentModel] {
        var result = [RedditCommentModel]()
        var moreQueue = [(comments: [[String: Any]], depth: Int)]()
        moreQueue.append((commentsArray, depth))
        
        while !moreQueue.isEmpty {
            let current = moreQueue.removeFirst()
            let comments = current.comments
            let currentDepth = current.depth
            
            for commentDict in comments {
                guard let kind = commentDict["kind"] as? String else { continue }
                
                if kind == "t1" {
                    guard let commentData = commentDict["data"] as? [String: Any],
                          let id = commentData["id"] as? String,
                          let author = commentData["author"] as? String,
                          let body = commentData["body"] as? String,
                          let score = commentData["score"] as? Int,
                          let createdUtc = commentData["created_utc"] as? Double else {
                        continue
                    }
                    
                    var replies: [RedditCommentModel] = []
                    if let repliesDict = commentData["replies"] as? [String: Any],
                       let repliesData = repliesDict["data"] as? [String: Any],
                       let children = repliesData["children"] as? [[String: Any]] {
                        replies = (try? parseAllComments(children, depth: currentDepth + 1)) ?? []
                    }
                    
                    let comment = RedditCommentModel(
                        id: id,
                        author: author,
                        body: body,
                        score: score,
                        createdUtc: createdUtc,
                        replies: replies,
                        indentationLevel: currentDepth
                    )
                    result.append(comment)
                    
                } else if kind == "more" {
                    if let moreData = commentDict["data"] as? [String: Any],
                       let children = moreData["children"] as? [String],
                       !children.isEmpty {
                        
                        // Handle rate limiting with exponential backoff
                        var retryCount = 0
                        var moreComments: [RedditCommentModel] = []
                        
                        repeat {
                            do {
                                moreComments = try fetchMoreChildrenSync(children: children)
                                break
                            } catch {
                                retryCount += 1
                                if retryCount >= maxRetryCount { break }
                                let delay = pow(backoffFactor, Double(retryCount))
                                Thread.sleep(forTimeInterval: delay)
                            }
                        } while retryCount < maxRetryCount
                        
                        result.append(contentsOf: moreComments)
                    }
                }
            }
        }
        
        return result
    }
    
    private func fetchMoreChildrenSync(children: [String]) throws -> [RedditCommentModel] {
        guard let linkId = self.linkId else {
            print("❌ No link_id available for fetchMoreChildren")
            throw URLError(.badURL)
        }
        
        var components = URLComponents(string: "\(baseURL)/api/morechildren")!
        components.queryItems = [
            URLQueryItem(name: "api_type", value: "json"),
            URLQueryItem(name: "link_id", value: linkId),
            URLQueryItem(name: "children", value: children.joined(separator: ",")),
            URLQueryItem(name: "sort", value: "confidence"),
            URLQueryItem(name: "limit_children", value: "false"),
            URLQueryItem(name: "depth", value: "10")
        ]
        
        guard let url = components.url else {
            throw URLError(.badURL)
        }
        
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        
        let semaphore = DispatchSemaphore(value: 0)
        var result: [RedditCommentModel] = []
        var requestError: Error?
        
        let task = session.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            
            if let error = error {
                requestError = error
                return
            }
            
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                requestError = URLError(.badServerResponse)
                return
            }
            
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let jsonData = json["json"] as? [String: Any],
                  let data = jsonData["data"] as? [String: Any],
                  let things = data["things"] as? [[String: Any]] else {
                return
            }
            
            do {
                result = try self.parseAllComments(things)
            } catch {
                requestError = error
            }
        }
        
        task.resume()
        semaphore.wait()
        
        if let error = requestError {
            throw error
        }
        
        return result
    }
    
    // Helper method to add comments to cache
    private func addToCache(_ comments: [RedditCommentModel], for key: String) {
        commentCache[key] = comments
        
        // If cache exceeds max size, remove oldest entries
        if commentCache.count > maxCacheSize {
            // Simple approach: just remove a random entry
            // For production, implement a proper LRU cache
            let keysToRemove = commentCache.keys.sorted().prefix(commentCache.count - maxCacheSize)
            for key in keysToRemove {
                commentCache.removeValue(forKey: key)
                print("📱 RedditService: Removed cached comments for key: \(key)")
            }
        }
    }
    
    // Method to clear cache if needed
    func clearCache() {
        commentCache.removeAll()
        print("📱 RedditService: Cleared comment cache")
    }
    
    // MARK: - Comment Analytics Generation (Moved from AnalyticsService)
    
    func generateCommentAnalytics(from comments: [RedditCommentModel]) -> CommentAnalytics {
        // Tracking variables
        var positiveCount = 0
        var neutralCount = 0
        var negativeCount = 0
        var totalLength = 0
        var authorCounts: [String: Int] = [:]
        var lengthDistribution = [
            "0-50": 0,
            "51-100": 0,
            "101-200": 0,
            "201-500": 0,
            "500+": 0
        ]
        
        // Flatten all comments for analysis (including replies)
        let allFlattenedComments = flattenComments(comments)
        
        // Process all flattened comments
        for comment in allFlattenedComments {
            // Analyze sentiment
            let sentiment = analyzeSentiment(text: comment.body) // Use 'body' from RedditCommentModel
            switch sentiment {
            case .positive: positiveCount += 1
            case .neutral: neutralCount += 1
            case .negative: negativeCount += 1
            }
            
            // Track comment length
            let length = comment.body.count
            totalLength += length
            
            // Update length distribution
            if length <= 50 {
                lengthDistribution["0-50"]! += 1
            } else if length <= 100 {
                lengthDistribution["51-100"]! += 1
            } else if length <= 200 {
                lengthDistribution["101-200"]! += 1
            } else if length <= 500 {
                lengthDistribution["201-500"]! += 1
            } else {
                lengthDistribution["500+"]! += 1
            }
            
            // Track author
            authorCounts[comment.author, default: 0] += 1 // Use 'author' from RedditCommentModel
        }
        
        // Calculate total comments
        let totalComments = allFlattenedComments.count
        
        // Find most active author
        let mostActiveAuthor = authorCounts.max(by: { $0.value < $1.value })
        
        // Calculate average comment length
        let averageLength = totalComments > 0 ? totalLength / totalComments : 0
        
        // Identify highly voted comments (top 5)
        let highlyVoted = allFlattenedComments.sorted(by: { $0.score > $1.score }).prefix(5) // Use 'score' from RedditCommentModel
        
        // Extract common topics
        let commonTopics = extractTopics(from: allFlattenedComments)
        
        return CommentAnalytics(
            totalComments: totalComments,
            sentimentCounts: (positiveCount, neutralCount, negativeCount),
            averageCommentLength: averageLength,
            uniqueAuthorsCount: authorCounts.count,
            mostActiveAuthor: mostActiveAuthor.map { ($0.key, $0.value) },
            commentLengthDistribution: lengthDistribution,
            highlyVotedComments: Array(highlyVoted),
            commentTopics: commonTopics
        )
    }
    
    // MARK: - Analytics Helper Functions (Moved from AnalyticsService)
    
    /// Recursively flattens a list of comments and their replies.
    func flattenComments(_ comments: [RedditCommentModel]) -> [RedditCommentModel] { // Removed 'private'
        var flattened: [RedditCommentModel] = []
        for comment in comments {
            flattened.append(comment)
            flattened.append(contentsOf: flattenComments(comment.replies)) // Recursively flatten replies
        }
        return flattened
    }
    
    /// Analyzes the sentiment of a given text based on keywords.
    private func analyzeSentiment(text: String) -> SentimentType {
        let lowercasedText = text.lowercased()
        
        // Simple keyword-based sentiment analysis (can be expanded)
        let positiveWords = Set(["good", "great", "excellent", "awesome", "amazing", "love", "best", "perfect", "nice", "happy", "thanks", "thank", "appreciated", "helpful", "useful", "interesting", "exciting", "glad", "recommend"])
        let negativeWords = Set(["bad", "terrible", "awful", "horrible", "hate", "worst", "poor", "disappointing", "sad", "angry", "useless", "boring", "wrong", "sucks", "confused", "difficult", "frustrating", "issue", "problem", "error", "fail"])
        
        var positiveScore = 0
        var negativeScore = 0
        
        let words = lowercasedText.components(separatedBy: .whitespacesAndNewlines)
        for word in words {
            let cleanedWord = word.trimmingCharacters(in: .punctuationCharacters)
            if positiveWords.contains(cleanedWord) {
                positiveScore += 1
            } else if negativeWords.contains(cleanedWord) {
                negativeScore += 1
            }
        }
        
        // Determine sentiment based on scores
        if positiveScore > negativeScore {
            return .positive
        } else if negativeScore > positiveScore {
            return .negative
        } else {
            // Consider it neutral if scores are equal or both zero
            return .neutral
        }
    }
    
    /// Extracts potential topics from comments by finding frequent words (excluding common stop words).
    private func extractTopics(from comments: [RedditCommentModel]) -> [String] {
        let allText = comments.map { $0.body }.joined(separator: " ") // Use 'body'
        
        // Common English stop words + some Reddit/internet slang
        let stopWords = Set([
            "the", "be", "to", "of", "and", "a", "in", "that", "have", "i", "it", "for", "not", "on", "with", "he", "as", "you", "do", "at",
            "this", "but", "his", "by", "from", "they", "we", "say", "her", "she", "or", "an", "will", "my", "one", "all", "would", "there", "their",
            "what", "so", "up", "out", "if", "about", "who", "get", "which", "go", "me", "when", "make", "can", "like", "time", "no", "just",
            "him", "know", "take", "people", "into", "year", "your", "good", "some", "could", "them", "see", "other", "than", "then", "now",
            "look", "only", "come", "its", "over", "think", "also", "back", "after", "use", "two", "how", "our", "work", "first", "well", "way",
            "even", "new", "want", "because", "any", "these", "give", "day", "most", "us", "is", "are", "was", "were", "am", "has", "had",
            "reddit", "post", "comment", "thread", "subreddit", "op", "lol", "lmao", "imo", "imho", "tldr", "edit", "link", "image", "http", "https"
        ])
        
        // Extract words, lowercase, remove punctuation, filter stop words and short words
        let words = allText.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .map { $0.trimmingCharacters(in: .punctuationCharacters) }
            .filter { !$0.isEmpty && $0.count > 3 && !stopWords.contains($0) }
        
        // Count word frequencies
        var wordCounts: [String: Int] = [:]
        for word in words {
            wordCounts[word, default: 0] += 1
        }
        
        // Return top 5 most frequent words as topics
        let sortedTopics = wordCounts.sorted { $0.value > $1.value }
        return Array(sortedTopics.prefix(5).map { $0.key })
    }
    
    /// Helper to get top comments by sentiment (used by the View)
    func getTopCommentsBySentiment(comments: [RedditCommentModel], type: SentimentType, count: Int = 3) -> [RedditCommentModel] {
        let allComments = flattenComments(comments)
        
        return allComments
            .filter { analyzeSentiment(text: $0.body) == type }
            .sorted(by: { $0.score > $1.score }) // Sort by score
            .prefix(count) // Take top 'count'
            .map { $0 } // Convert slice back to array
    }
}

// MARK: - Reddit JSON Models
struct RedditListing: Decodable {
    let kind: String
    let data: RedditListingData
}

struct RedditListingData: Decodable {
    let children: [RedditChild]
    let after: String?
    let before: String?
}

struct RedditChild: Decodable {
    let kind: String
    let data: RedditChildData?
}

struct RedditChildData: Decodable {
    let id: String
    let title: String
    let author: String?
    let created_utc: Double?
    let num_comments: Int?
    let score: Int?
    let selftext: String?
    let url: String?
    let subreddit: String?
    let subreddit_description: String?
    let thumbnail: String?
}
