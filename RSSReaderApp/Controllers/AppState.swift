import Foundation
import Combine
import SwiftUI

// Define OPMLService directly in this file
private class OPMLService {
    enum OPMLParsingError: Error {
        case invalidXML
        case unexpectedFormat
        case emptyDocument
        case fileReadError
        case securityScopedResourceAccessDenied
    }
    
    // Improved parsing with better file handling
    func loadOPMLFromFile(at url: URL) -> AnyPublisher<[Subscription], Error> {
        return Future<[Subscription], Error> { promise in
            // Start accessing security-scoped resource
            let didStartAccessing = url.startAccessingSecurityScopedResource()
            
            defer {
                // Make sure to release the security-scoped resource when finished
                if didStartAccessing {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            
            do {
                // Read file contents with more robust error handling
                guard let xmlString = try? String(contentsOf: url, encoding: .utf8) else {
                    // Try alternative encodings if UTF-8 fails
                    guard let xmlString = try? String(contentsOf: url, encoding: .isoLatin1) else {
                        throw OPMLParsingError.fileReadError
                    }
                    
                    // Process with the alternative encoding
                    let subscriptions = try self.parseOPMLString(xmlString)
                    if subscriptions.isEmpty {
                        throw OPMLParsingError.emptyDocument
                    }
                    promise(.success(subscriptions))
                    return
                }
                
                // Parse using the UTF-8 encoding
                let subscriptions = try self.parseOPMLString(xmlString)
                if subscriptions.isEmpty {
                    throw OPMLParsingError.emptyDocument
                }
                promise(.success(subscriptions))
            } catch {
                if let opmlError = error as? OPMLParsingError {
                    promise(.failure(opmlError))
                } else {
                    promise(.failure(OPMLParsingError.fileReadError))
                }
            }
        }.eraseToAnyPublisher()
    }
    
    // Separate parsing logic for better organization
    private func parseOPMLString(_ xmlString: String) throws -> [Subscription] {
        var subscriptions: [Subscription] = []
        
        // Handle different formats - sometimes OPML files might not have line breaks between outline elements
        // First try line-by-line parsing
        let lines = xmlString.components(separatedBy: .newlines)
        for line in lines {
            if line.contains("<outline") && line.contains("xmlUrl=") {
                if let subscription = extractSubscription(from: line) {
                    subscriptions.append(subscription)
                }
            }
        }
        
        // If line-by-line parsing didn't find anything, try more comprehensive parsing
        if subscriptions.isEmpty {
            // Fallback parsing - extract all outline elements with xmlUrl regardless of line breaks
            let pattern = "<outline[^>]*xmlUrl=\"([^\"]*)\"[^>]*text=\"([^\"]*)\"[^>]*"
            do {
                let regex = try NSRegularExpression(pattern: pattern, options: [])
                let nsString = xmlString as NSString
                let matches = regex.matches(in: xmlString, options: [], range: NSRange(location: 0, length: nsString.length))
                
                for match in matches {
                    if match.numberOfRanges >= 3 {
                        let urlRange = match.range(at: 1)
                        let titleRange = match.range(at: 2)
                        
                        let url = nsString.substring(with: urlRange)
                        let title = nsString.substring(with: titleRange)
                        
                        // Check if this might be a Reddit feed
                        if url.contains("reddit.com") {
                            if let subredditMatch = url.range(of: "r/([^/]+)", options: .regularExpression) {
                                let subredditName = String(url[subredditMatch])
                                    .replacingOccurrences(of: "r/", with: "")
                                let subscription = Subscription(title: title, url: subredditName, type: .reddit)
                                subscriptions.append(subscription)
                                continue
                            }
                        }
                        
                        // Regular RSS feed
                        let subscription = Subscription(title: title, url: url, type: .rss)
                        subscriptions.append(subscription)
                    }
                }
            } catch {
                throw OPMLParsingError.invalidXML
            }
        }
        
        return subscriptions
    }
    
    // Helper method to extract subscription information from a line
    private func extractSubscription(from line: String) -> Subscription? {
        // Extract title
        var title = ""
        if let titleRange = line.range(of: "title=\"([^\"]*)\"", options: .regularExpression) {
            title = String(line[titleRange])
                .replacingOccurrences(of: "title=\"", with: "")
                .replacingOccurrences(of: "\"", with: "")
        } else if let textRange = line.range(of: "text=\"([^\"]*)\"", options: .regularExpression) {
            title = String(line[textRange])
                .replacingOccurrences(of: "text=\"", with: "")
                .replacingOccurrences(of: "\"", with: "")
        } else {
            return nil // No title, skip
        }
        
        // Extract XML URL
        guard let xmlUrlRange = line.range(of: "xmlUrl=\"([^\"]*)\"", options: .regularExpression) else {
            return nil
        }
        
        let xmlUrl = String(line[xmlUrlRange])
            .replacingOccurrences(of: "xmlUrl=\"", with: "")
            .replacingOccurrences(of: "\"", with: "")
        
        // Check if this might be a Reddit feed
        if xmlUrl.contains("reddit.com") {
            // Try to extract subreddit name from URL
            if let subredditMatch = xmlUrl.range(of: "r/([^/]+)", options: .regularExpression) {
                let subredditName = String(xmlUrl[subredditMatch])
                    .replacingOccurrences(of: "r/", with: "")
                return Subscription(title: title, url: subredditName, type: .reddit)
            }
        }
        
        // Regular RSS feed
        return Subscription(title: title, url: xmlUrl, type: .rss)
    }
}

// Define QAService directly in this file
class QAService {
    private var summaryService: SummaryService
    
    init(summaryService: SummaryService? = nil) {
        self.summaryService = summaryService ?? SummaryService()
    }
    
    func updateSummaryService(_ newSummaryService: SummaryService) {
        self.summaryService = newSummaryService
    }
    
    // For article Q&A
    func answerQuestionAboutArticle(article: Article, question: String) -> AnyPublisher<String, Never> {
        let prompt = """
        Article Title: \(article.title)
        Article Content:
        \(article.content)
        
        Based solely on the information in the article above, please answer the following question:
        \(question)
        
        If the answer cannot be determined from the article, please state that the information is not available in the article.
        """
        
        return summaryService.summarizeText("", customPrompt: prompt)
            .eraseToAnyPublisher()
    }
    
    // For Reddit post Q&A
    func answerQuestionAboutRedditPost(post: RedditPost, comments: [RedditCommentModel], question: String) -> AnyPublisher<String, Never> {
        // Extract all comment text
        let commentTexts = comments.flatMap { extractAllCommentTexts(from: $0) }
        let combinedComments = commentTexts.joined(separator: "\n\n")
        
        let prompt = """
        Reddit Post Title: \(post.title)
        Post Content:
        \(post.content)
        
        Comments:
        \(combinedComments)
        
        Based solely on the information in the Reddit post and comments above, please answer the following question:
        \(question)
        
        If the answer cannot be determined from the post or comments, please state that the information is not available.
        """
        
        return summaryService.summarizeText("", customPrompt: prompt)
            .eraseToAnyPublisher()
    }
    
    // Helper function to extract all comment texts recursively
    func extractAllCommentTexts(from comment: RedditCommentModel) -> [String] {
        var texts = ["u/\(comment.author): \(comment.body)"]

        for reply in comment.replies {
            texts.append(contentsOf: extractAllCommentTexts(from: reply))
        }

        return texts
    }
}

class AppState: ObservableObject {
    // MARK: - Published Properties
    @Published var subscriptions: [Subscription] = []
    @Published var feeds: [Feed] = []
    @Published var redditFeeds: [RedditFeed] = []
    @Published var selectedFeed: Feed?
    @Published var selectedRedditFeed: RedditFeed?
    
    // Navigation state properties
    @Published var selectedArticle: Article?
    @Published var selectedRedditPost: RedditPost?
    
    // Navigation selection identifiers - these are used by NavigationLink's tag/selection
    // They must be updated in sync with the selectedArticle and selectedRedditPost
    @Published var selectedArticleId: String?
    @Published var selectedRedditPostId: String?
    
    // Track currently active subscription for back navigation
    @Published var activeSubscriptionURL: String?
    @Published var lastSelectedCategory: FeedCategory = .today
    
    // Scroll position tracking
    @Published var scrollPositions: [String: String] = [:] // Map of subscription URL to item ID
    
    // Function to fully set article selection
    func setSelectedArticle(_ article: Article?) {
        self.selectedArticle = article
        self.selectedArticleId = article?.id
    }
    
    // Function to fully set reddit post selection
    func setSelectedRedditPost(_ post: RedditPost?) {
        self.selectedRedditPost = post
        self.selectedRedditPostId = post?.id
    }
    
    // Function to remember current subscription before navigating to article/post
    func rememberCurrentSubscription(url: String?) {
        self.activeSubscriptionURL = url
    }
    
    // Save scroll position for a subscription
    func saveScrollPosition(for subscriptionURL: String, itemID: String) {
        scrollPositions[subscriptionURL] = itemID
    }
    
    // Get saved scroll position for a subscription
    func getSavedScrollPosition(for subscriptionURL: String) -> String? {
        return scrollPositions[subscriptionURL]
    }
    
    // Function to clear selection and navigate back to previous subscription if available
    func navigateBack() {
        // Clear current selection
        self.selectedArticle = nil
        self.selectedRedditPost = nil
        self.selectedArticleId = nil
        self.selectedRedditPostId = nil
        
        // When backing out of a detailed view, if we don't have a specific subscription URL
        // but we do have a lastSelectedCategory, ensure we indicate we're going back to that category
        // rather than defaulting to favorites
        if self.activeSubscriptionURL == nil && self.lastSelectedCategory != .favorites {
            // Make sure we go back to the last selected category instead of favorites
            print("📱 AppState: Navigating back to \(self.lastSelectedCategory.rawValue) category")
        }
        
        // We don't need to do anything else here since ContentView will observe
        // these changes and update the navigation accordingly
    }
    
    @Published var isLoading: Bool = false
    @Published var settings: AppSettings = AppSettings()
    @Published var redditSortOption: RedditService.SortOption = .hot

    // MARK: - Services
    private let feedService: FeedService
    private let redditService: RedditService
    
    // Changed from "private var" to "internal var" so we can call it in RedditDetailView
    // Or keep it private and expose a function. But simplest is to reference it directly:
    let summaryService: SummaryService
    
    // NEW: A single shared CommentSummaryService that uses the same summaryService
    let commentSummaryService: CommentSummaryService
    
    // NEW: Add QAService for article and reddit Q&A
    let qaService: QAService
    
    private let persistenceManager: PersistenceManager
    
    // OPML Service for importing subscriptions
    private let opmlService: OPMLService = OPMLService()
    
    // No longer using FaviconService to avoid module issues

    // MARK: - Cancellables
    var cancellables = Set<AnyCancellable>()

    // MARK: - Initialization
    init(feedService: FeedService? = nil,
         redditService: RedditService? = nil,
         summaryService: SummaryService? = nil,
         persistenceManager: PersistenceManager? = nil) {
        
        // 1. Initialize persistenceManager
        self.persistenceManager = persistenceManager ?? PersistenceManager()
        
        // 2. Load settings from storage
        let loadedSettings = self.persistenceManager.loadSettings()
        self.settings = loadedSettings
        
        // 3. Initialize summaryService with the user's Gemini key
        let geminiKey = loadedSettings.geminiApiKey
        self.summaryService = summaryService ?? SummaryService(apiKey: geminiKey)
        
        // 4. Initialize the other services
        self.feedService = feedService ?? FeedService()
        self.redditService = redditService ?? RedditService()
        
        // 5. Initialize the shared CommentSummaryService with the same summaryService
        self.commentSummaryService = CommentSummaryService(summaryService: self.summaryService)
        
        // 6. Initialize the QA service with the same summaryService
        self.qaService = QAService(summaryService: self.summaryService)
        
        // 7. Load data from storage (subscriptions, etc.)
        loadSavedData()
        
        // 8. Setup refresh timer
        setupRefreshTimer()
    }

    // MARK: - Data Loading
    private func loadSavedData() {
        subscriptions = persistenceManager.loadSubscriptions()
        refreshAllFeeds()
    }

    private func setupRefreshTimer() {
        Timer.publish(every: settings.refreshInterval, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.refreshAllFeeds()
            }
            .store(in: &cancellables)
    }

    // MARK: - Feed Management
    func refreshAllFeeds() {
        isLoading = true
        let group = DispatchGroup()

        // Refresh RSS feeds
        for subscription in subscriptions where subscription.type == .rss {
            group.enter()
                feedService.fetchFeed(url: subscription.url)
                    .receive(on: RunLoop.main)
                    .sink(receiveCompletion: { _ in
                    group.leave()
                }, receiveValue: { [weak self] feed in
                    // Apply read and favorite status from persistence
                    var processedFeed = feed
                    for i in 0..<processedFeed.articles.count {
                        let id = processedFeed.articles[i].id
                        processedFeed.articles[i].isRead = self?.persistenceManager.isArticleRead(id) ?? false
                        processedFeed.articles[i].isFavorite = self?.persistenceManager.isArticleFavorite(id) ?? false
                    }
                    
                    if let index = self?.feeds.firstIndex(where: { $0.url == subscription.url }) {
                        self?.feeds[index] = processedFeed
                    } else {
                        self?.feeds.append(processedFeed)
                    }
                })
                .store(in: &cancellables)
        }

        // Refresh Reddit feeds
        refreshRedditFeeds(in: group)

        group.notify(queue: .main) { [weak self] in
            self?.isLoading = false
        }
    }
    
    // Specific function to refresh just Reddit feeds
    func refreshRedditFeeds(specificSubreddit: String? = nil, in existingGroup: DispatchGroup? = nil) {
        let group = existingGroup ?? DispatchGroup()
        
        if existingGroup == nil {
            isLoading = true
        }
        
        // Log the refresh operation
        if let specificSubreddit = specificSubreddit {
            print("📱 AppState: Refreshing specific Reddit feed: r/\(specificSubreddit) with sort option: \(redditSortOption.rawValue)")
        } else {
            print("📱 AppState: Refreshing ALL Reddit feeds with sort option: \(redditSortOption.rawValue)")
        }
        
        // Filter subscriptions if a specific subreddit is requested
        let redditSubscriptions: [Subscription]
        if let specificSubreddit = specificSubreddit {
            redditSubscriptions = subscriptions.filter { $0.type == .reddit && $0.url == specificSubreddit }
        } else {
            redditSubscriptions = subscriptions.filter { $0.type == .reddit }
        }
        
        print("📱 AppState: Found \(redditSubscriptions.count) Reddit subscriptions to refresh")
        
        // Refresh Reddit feeds
        for subscription in redditSubscriptions {
            group.enter()
            
            // Create a temporary feed object with loading state if needed
            if redditFeeds.firstIndex(where: { $0.subreddit == subscription.url }) == nil {
                // Add a temporary placeholder feed to show loading state
                let tempFeed = RedditFeed(subreddit: subscription.url, displayName: "Loading...", posts: [])
                self.redditFeeds.append(tempFeed)
                print("📱 AppState: Created temporary feed for r/\(subscription.url)")
            }
            
            redditService.fetchSubreddit(subreddit: subscription.url, sortOption: redditSortOption)
                .receive(on: RunLoop.main)
                .sink(receiveCompletion: { completion in
                    group.leave()
                }, receiveValue: { [weak self] redditFeed in
                    guard let self = self else { return }
                    
                    // Apply read and favorite status from persistence
                    var processedFeed = redditFeed
                    for i in 0..<processedFeed.posts.count {
                        let id = processedFeed.posts[i].id
                        processedFeed.posts[i].isRead = self.persistenceManager.isRedditPostRead(id) ?? false
                        processedFeed.posts[i].isFavorite = self.persistenceManager.isRedditPostFavorite(id) ?? false
                    }
                    
                    print("📱 AppState: Received feed for r/\(subscription.url) with \(processedFeed.posts.count) posts")
                    
                    // For Reddit feeds, we need to clear and recreate the feed to ensure proper sorting
                    if let index = self.redditFeeds.firstIndex(where: { $0.subreddit == subscription.url }) {
                        print("📱 AppState: Updating existing feed at index \(index)")
                        // Create a new array with the updated feed to trigger UI refresh
                        var updatedFeeds = self.redditFeeds
                        updatedFeeds[index] = processedFeed
                        self.redditFeeds = updatedFeeds // This should trigger UI refresh
                        print("📱 AppState: Feed array updated with new content, sort option: \(self.redditSortOption.rawValue)")
                    } else {
                        print("📱 AppState: Adding new feed to collection")
                        self.redditFeeds.append(processedFeed)
                    }
                    
                    // Force UI update by re-publishing the current selected Reddit post if it's from this feed
                    if let selectedPost = self.selectedRedditPost, selectedPost.subreddit == subscription.url {
                        if let updatedPost = processedFeed.posts.first(where: { $0.id == selectedPost.id }) {
                            print("📱 AppState: Re-publishing selected post")
                            self.selectedRedditPost = updatedPost
                        } else {
                            print("⚠️ AppState: Selected post no longer exists in the updated feed")
                        }
                    }
                })
                .store(in: &cancellables)
        }
        
        if existingGroup == nil {
            group.notify(queue: .main) { [weak self] in
                self?.isLoading = false
            }
        }
    }

    // MARK: - Subscription Management
    func addSubscription(title: String, url: String, type: SubscriptionType) {
        let subscription = Subscription(title: title, url: url, type: type)
        subscriptions.append(subscription)
        persistenceManager.saveSubscriptions(subscriptions)

        // Fetch the new feed
        if type == .rss {
            feedService.fetchFeed(url: url)
                .receive(on: RunLoop.main)
                .sink(receiveCompletion: { _ in },
                      receiveValue: { [weak self] feed in
                    // Apply read and favorite status for new subscriptions too
                    var processedFeed = feed
                    for i in 0..<processedFeed.articles.count {
                        let id = processedFeed.articles[i].id
                        processedFeed.articles[i].isRead = self?.persistenceManager.isArticleRead(id) ?? false
                        processedFeed.articles[i].isFavorite = self?.persistenceManager.isArticleFavorite(id) ?? false
                    }
                    self?.feeds.append(processedFeed)
                })
                .store(in: &cancellables)
        } else {
            redditService.fetchSubreddit(subreddit: url, sortOption: redditSortOption)
                .receive(on: RunLoop.main)
                .sink(receiveCompletion: { _ in },
                      receiveValue: { [weak self] redditFeed in
                    guard let self = self else { return }
                    
                    // Apply read and favorite status for new Reddit subscriptions too
                    var processedFeed = redditFeed
                    for i in 0..<processedFeed.posts.count {
                        let id = processedFeed.posts[i].id
                        processedFeed.posts[i].isRead = self.persistenceManager.isRedditPostRead(id) ?? false
                        processedFeed.posts[i].isFavorite = self.persistenceManager.isRedditPostFavorite(id) ?? false
                    }
                    self.redditFeeds.append(processedFeed)
                })
                .store(in: &cancellables)
        }
    }

    func removeSubscription(at indexSet: IndexSet) {
        let subscriptionsToRemove = indexSet.map { subscriptions[$0] }

        for subscription in subscriptionsToRemove {
            if subscription.type == .rss {
                feeds.removeAll { $0.url == subscription.url }
            } else {
                redditFeeds.removeAll { $0.subreddit == subscription.url }
            }
        }

        subscriptions.remove(atOffsets: indexSet)
        persistenceManager.saveSubscriptions(subscriptions)
    }

    // MARK: - Article Management
    func markArticleAsRead(_ article: Article) {
        if let feedIndex = feeds.firstIndex(where: { $0.url == article.feedURL }),
           let articleIndex = feeds[feedIndex].articles.firstIndex(where: { $0.id == article.id }) {
            feeds[feedIndex].articles[articleIndex].isRead = true
            persistenceManager.markArticleAsRead(article.id)
            
            // Ensure the navigation state is consistent
            if selectedArticle?.id == article.id {
                // Use the consistent setter function
                setSelectedArticle(feeds[feedIndex].articles[articleIndex])
            }
        }
    }

    func toggleArticleFavorite(_ article: Article) {
        if let feedIndex = feeds.firstIndex(where: { $0.url == article.feedURL }),
           let articleIndex = feeds[feedIndex].articles.firstIndex(where: { $0.id == article.id }) {
            let isFavorite = !feeds[feedIndex].articles[articleIndex].isFavorite
            feeds[feedIndex].articles[articleIndex].isFavorite = isFavorite

            if isFavorite {
                persistenceManager.addFavoriteArticle(article.id)
            } else {
                persistenceManager.removeFavoriteArticle(article.id)
            }
            
            // Ensure the navigation state is consistent if this is the currently selected article
            if selectedArticle?.id == article.id {
                setSelectedArticle(feeds[feedIndex].articles[articleIndex])
            }
        }
    }

    func summarizeArticle(_ article: Article) {
        isLoading = true
        
        // Create a customized prompt for article summarization
        let articlePrompt = "Summarize the following article, highlighting the key points, main arguments, and important conclusions. Focus on providing a concise overview that captures the essential information:\n\n\(article.content)"

        summaryService.summarizeText(article.content, customPrompt: articlePrompt)
            .receive(on: RunLoop.main)
            .sink { [weak self] summary in
                guard let self = self else { return }
                
                if let feedIndex = self.feeds.firstIndex(where: { $0.url == article.feedURL }),
                   let articleIndex = self.feeds[feedIndex].articles.firstIndex(where: { $0.id == article.id }) {
                    
                    // First, create a mutable copy of the article to update
                    var articleToUpdate = self.feeds[feedIndex].articles[articleIndex]
                    
                    // Update the article with the summary
                    articleToUpdate.summary = summary
                    
                    // Update the article in the feeds array
                    self.feeds[feedIndex].articles[articleIndex] = articleToUpdate
                    
                    // If this is the currently selected article, update the selection
                    if self.selectedArticle?.id == article.id {
                        self.selectedArticle = articleToUpdate
                        print("📱 AppState: Updated article summary for article ID: \(article.id)")
                    }
                }
                self.isLoading = false
            }
            .store(in: &cancellables)
    }

    // MARK: - Reddit Post Management
    func markRedditPostAsRead(_ post: RedditPost) {
        if let feedIndex = redditFeeds.firstIndex(where: { $0.subreddit == post.subreddit }),
           let postIndex = redditFeeds[feedIndex].posts.firstIndex(where: { $0.id == post.id }) {
            redditFeeds[feedIndex].posts[postIndex].isRead = true
            persistenceManager.markRedditPostAsRead(post.id)
            
            // Ensure the navigation state is consistent
            if selectedRedditPost?.id == post.id {
                // Use the consistent setter function
                setSelectedRedditPost(redditFeeds[feedIndex].posts[postIndex])
            }
        }
    }

    func toggleRedditPostFavorite(_ post: RedditPost) {
        if let feedIndex = redditFeeds.firstIndex(where: { $0.subreddit == post.subreddit }),
           let postIndex = redditFeeds[feedIndex].posts.firstIndex(where: { $0.id == post.id }) {
            let isFavorite = !redditFeeds[feedIndex].posts[postIndex].isFavorite
            redditFeeds[feedIndex].posts[postIndex].isFavorite = isFavorite

            if isFavorite {
                persistenceManager.addFavoriteRedditPost(post.id)
            } else {
                persistenceManager.removeFavoriteRedditPost(post.id)
            }
            
            // Ensure the navigation state is consistent if this is the currently selected post
            if selectedRedditPost?.id == post.id {
                setSelectedRedditPost(redditFeeds[feedIndex].posts[postIndex])
            }
        }
    }

    func summarizeRedditPost(_ post: RedditPost) {
        isLoading = true
        
        // Create a customized prompt for Reddit post summarization
        let redditPostPrompt = "Summarize the following Reddit post, highlighting the main question or discussion topic, key points made by the author, and any important context provided. Focus on creating a concise and informative summary that captures the essence of the post:\n\n\(post.content)"

        summaryService.summarizeText(post.content, customPrompt: redditPostPrompt)
            .receive(on: RunLoop.main)
            .sink { [weak self] summary in
                guard let self = self else { return }
                
                if let feedIndex = self.redditFeeds.firstIndex(where: { $0.subreddit == post.subreddit }),
                   let postIndex = self.redditFeeds[feedIndex].posts.firstIndex(where: { $0.id == post.id }) {
                    
                    // First, create a mutable copy of the post to update
                    var postToUpdate = self.redditFeeds[feedIndex].posts[postIndex]
                    
                    // Update the post with the summary
                    postToUpdate.summary = summary
                    
                    // Update the post in the redditFeeds array
                    self.redditFeeds[feedIndex].posts[postIndex] = postToUpdate

                    // If this is the currently selected post, update the selection
                    if self.selectedRedditPost?.id == post.id {
                        self.selectedRedditPost = postToUpdate
                        print("📱 AppState: Updated Reddit post summary for post ID: \(post.id)")
                    }
                }
                self.isLoading = false
            }
            .store(in: &cancellables)
    }

    // MARK: - Settings Management
    func updateSettings(_ newSettings: AppSettings) {
        // If API key changed, update all services that use it
        if newSettings.geminiApiKey != settings.geminiApiKey {
            summaryService.updateApiKey(newSettings.geminiApiKey)
            commentSummaryService.updateSummaryService(summaryService)
            qaService.updateSummaryService(summaryService)
        }
        
        // Update the stored settings
        settings = newSettings
        persistenceManager.saveSettings(newSettings)
        
        // If refresh interval changed, restart timer
        if settings.refreshInterval != newSettings.refreshInterval {
            cancellables.removeAll()
            setupRefreshTimer()
        }
    }
    
    // MARK: - OPML Import
    func importOPMLFromURL(_ url: URL, completion: @escaping (Result<Int, Error>) -> Void) {
        // Start loading indicator
        self.isLoading = true
        
        opmlService.loadOPMLFromFile(at: url)
            .receive(on: RunLoop.main)
            .sink(receiveCompletion: { [weak self] result in
                guard let self = self else { return }
                self.isLoading = false
                
                // Handle errors
                if case .failure(let error) = result {
                    print("OPML import error: \(error)")
                    completion(.failure(error))
                }
            }, receiveValue: { [weak self] newSubscriptions in
                guard let self = self else { return }
                
                // Filter out subscriptions that already exist
                let existingURLs = Set(self.subscriptions.map { $0.url })
                let uniqueSubscriptions = newSubscriptions.filter { !existingURLs.contains($0.url) }
                
                // Add new subscriptions
                if !uniqueSubscriptions.isEmpty {
                    self.subscriptions.append(contentsOf: uniqueSubscriptions)
                    self.persistenceManager.saveSubscriptions(self.subscriptions)
                    
                    // Load the feeds for new subscriptions
                    for subscription in uniqueSubscriptions {
                        if subscription.type == .rss {
                            self.feedService.fetchFeed(url: subscription.url)
                                .receive(on: RunLoop.main)
                                .sink(receiveCompletion: { _ in },
                                      receiveValue: { [weak self] feed in
                                    guard let self = self else { return }
                                    // Apply read and favorite status
                                    var processedFeed = feed
                                    for i in 0..<processedFeed.articles.count {
                                        let id = processedFeed.articles[i].id
                                        processedFeed.articles[i].isRead = self.persistenceManager.isArticleRead(id)
                                        processedFeed.articles[i].isFavorite = self.persistenceManager.isArticleFavorite(id)
                                    }
                                    self.feeds.append(processedFeed)
                                })
                                .store(in: &self.cancellables)
                        } else if subscription.type == .reddit {
                            self.redditService.fetchSubreddit(subreddit: subscription.url, sortOption: self.redditSortOption)
                                .receive(on: RunLoop.main)
                                .sink(receiveCompletion: { _ in },
                                      receiveValue: { [weak self] redditFeed in
                                    guard let self = self else { return }
                                    // Apply read and favorite status
                                    var processedFeed = redditFeed
                                    for i in 0..<processedFeed.posts.count {
                                        let id = processedFeed.posts[i].id
                                        processedFeed.posts[i].isRead = self.persistenceManager.isRedditPostRead(id) ?? false
                                        processedFeed.posts[i].isFavorite = self.persistenceManager.isRedditPostFavorite(id) ?? false
                                    }
                                    self.redditFeeds.append(processedFeed)
                                })
                                .store(in: &self.cancellables)
                        }
                    }
                }
                
                // Return the count of new subscriptions
                completion(.success(uniqueSubscriptions.count))
            })
            .store(in: &cancellables)
    }
    
    // MARK: - Mark All as Read
    func markAllUnreadAsRead() {
        // Mark all unread RSS articles as read
        for feedIndex in 0..<feeds.count {
            for articleIndex in 0..<feeds[feedIndex].articles.count {
                if !feeds[feedIndex].articles[articleIndex].isRead {
                    feeds[feedIndex].articles[articleIndex].isRead = true
                    persistenceManager.markArticleAsRead(feeds[feedIndex].articles[articleIndex].id)
                }
            }
        }
        
        // Mark all unread Reddit posts as read
        for feedIndex in 0..<redditFeeds.count {
            for postIndex in 0..<redditFeeds[feedIndex].posts.count {
                if !redditFeeds[feedIndex].posts[postIndex].isRead {
                    redditFeeds[feedIndex].posts[postIndex].isRead = true
                    persistenceManager.markRedditPostAsRead(redditFeeds[feedIndex].posts[postIndex].id)
                }
            }
        }
        
        // Log action
        print("📱 AppState: Marked all unread items as read")
    }

    // MARK: - Q&A Functionality
    func askQuestionAboutArticle(article: Article, question: String, completion: @escaping (String) -> Void) {
        print("📱 AppState: Processing question about article: \"\(question)\"")
        isLoading = true
        
        let prompt = """
        Article Title: \(article.title)
        Article Content:
        \(article.content)
        
        Based solely on the information in the article above, please answer the following question:
        \(question)
        
        If the answer cannot be determined from the article, please state that the information is not available in the article.
        """
        
        summaryService.summarizeText("", customPrompt: prompt)
            .receive(on: RunLoop.main)
            .sink { answer in
                self.isLoading = false
                print("📱 AppState: Received answer to question")
                completion(answer)
            }
            .store(in: &cancellables)
    }
    
    func askQuestionAboutRedditPost(post: RedditPost, comments: [RedditCommentModel], question: String, completion: @escaping (String) -> Void) {
        print("📱 AppState: Processing question about Reddit post: \"\(question)\"")
        isLoading = true
        
        // Extract all comment text
        let commentTexts = comments.flatMap { extractAllCommentTexts(from: $0) }
        let combinedComments = commentTexts.joined(separator: "\n\n")
        
        let prompt = """
        Reddit Post Title: \(post.title)
        Post Content:
        \(post.content)
        
        Comments:
        \(combinedComments)
        
        Based solely on the information in the Reddit post and comments above, please answer the following question:
        \(question)
        
        If the answer cannot be determined from the post or comments, please state that the information is not available.
        """
        
        summaryService.summarizeText("", customPrompt: prompt)
            .receive(on: RunLoop.main)
            .sink { answer in
                self.isLoading = false
                print("📱 AppState: Received answer to Reddit question")
                completion(answer)
            }
            .store(in: &cancellables)
    }
    
    // Helper function to extract all comment texts recursively
    func extractAllCommentTexts(from comment: RedditCommentModel) -> [String] {
        var texts = ["u/\(comment.author): \(comment.body)"]

        for reply in comment.replies {
            texts.append(contentsOf: extractAllCommentTexts(from: reply))
        }

        return texts
    }
}
