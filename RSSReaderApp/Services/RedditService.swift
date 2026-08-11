import Foundation
import Combine

struct RedditRateLimitStatus: Equatable {
    enum Endpoint: String {
        case feed
        case comments
    }

    let statusCode: Int
    let message: String?
    let remaining: Double?
    let resetInterval: TimeInterval?
    let used: Double?
    let subreddit: String?
    let endpoint: Endpoint
    let capturedAt: Date

    var isRateLimited: Bool {
        statusCode == 429
    }

    var approximateResetDate: Date? {
        guard let resetInterval else { return nil }
        return Date().addingTimeInterval(resetInterval)
    }
}

struct RedditCommentFetchResult {
    let comments: [RedditCommentModel]
    let rateLimit: RedditRateLimitStatus?
    let fromCache: Bool
    let errorDescription: String?

    var error: NSError? {
        guard let errorDescription, !errorDescription.isEmpty else { return nil }
        return NSError(
            domain: "RedditService",
            code: rateLimit?.statusCode ?? 0,
            userInfo: [NSLocalizedDescriptionKey: errorDescription]
        )
    }
}

private struct RedditUserAboutResponse: Decodable {
    let data: RedditUserAboutData
}

private struct RedditUserAboutData: Decodable {
    let iconImg: String?

    enum CodingKeys: String, CodingKey {
        case iconImg = "icon_img"
    }
}

enum RedditServiceError: Error, LocalizedError {
    case httpStatus(code: Int, subreddit: String, status: RedditRateLimitStatus?)
    case decoding(subreddit: String, underlying: Error)
    case transport(Error)
    case authenticationRequired
    case apiError(message: String)

    var errorDescription: String? {
        switch self {
        case .httpStatus(let code, let subreddit, _):
            return subreddit.isEmpty ? "HTTP \(code)" : "HTTP \(code) for r/\(subreddit)"
        case .decoding(_, let underlying):
            return "Decoding error: \(underlying.localizedDescription)"
        case .transport(let error):
            return error.localizedDescription
        case .authenticationRequired:
            return "Sign in to Reddit before using this action."
        case .apiError(let message):
            return message
        }
    }
}

enum RedditVoteDirection: Int {
    case down = -1
    case none = 0
    case up = 1
}

class RedditService {
    // Use different base URLs depending on authentication status
    private let publicBaseURL = "https://www.reddit.com"
    private let oauthBaseURL = "https://oauth.reddit.com"

    private var session: URLSession
    private var linkId: String?
    private let maxRetryCount = 3
    private let backoffFactor = 1.5

    // Add a cache for Reddit comments
    private var commentCache: [String: [RedditCommentModel]] = [:]
    private let maxCacheSize = 100 // Increased cache size to reduce API calls
    private var userAvatarCache: [String: URL] = [:]
    private var userAvatarMissingCache = Set<String>()

    // Rate limit tracking
    private var feedRateLimitStatus: [String: RedditRateLimitStatus] = [:]
    private var commentRateLimitStatus: [String: RedditRateLimitStatus] = [:]
    private let rateLimitQueue = DispatchQueue(label: "RedditService.RateLimitQueue", attributes: .concurrent)

    // Rate limiting properties
    private var lastRequestTime = Date.distantPast
    private let minRequestInterval: TimeInterval = 0.1 // 100ms between requests
    private let rateLimitLock = NSLock()

    // OAuth support
    private let persistenceManager = PersistenceManager.shared
    private var oauthManager: RedditOAuthManager?

    // Computed property to select the appropriate base URL
    private var baseURL: String {
        return isAuthenticated ? oauthBaseURL : publicBaseURL
    }

    // Check if user is authenticated
    private var isAuthenticated: Bool {
        let settings = persistenceManager.loadSettings()
        return !settings.redditAccessToken.isEmpty
    }

    init(oauthManager: RedditOAuthManager? = nil) {
        self.oauthManager = oauthManager

        let config = URLSessionConfiguration.default
        config.requestCachePolicy = .reloadRevalidatingCacheData
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        self.session = URLSession(configuration: config)
    }

    private static func cleanedAvatarURL(from iconImg: String?) -> URL? {
        guard var iconImg = iconImg?.trimmingCharacters(in: .whitespacesAndNewlines),
              !iconImg.isEmpty else {
            return nil
        }

        iconImg = iconImg
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")

        return URL(string: iconImg)
    }

    // MARK: - Rate Limiting

    /// Ensures we don't exceed rate limits by waiting between requests
    private func waitForRateLimit() async {
        rateLimitLock.lock()
        defer { rateLimitLock.unlock() }

        let timeSinceLastRequest = Date().timeIntervalSince(lastRequestTime)
        if timeSinceLastRequest < minRequestInterval {
            let waitTime = minRequestInterval - timeSinceLastRequest
            try? await Task.sleep(nanoseconds: UInt64(waitTime * 1_000_000_000))
        }
        lastRequestTime = Date()
    }

    private func captureRateLimit(from response: HTTPURLResponse,
                                  data: Data?,
                                  subreddit: String?,
                                  endpoint: RedditRateLimitStatus.Endpoint) -> RedditRateLimitStatus? {
        var headers: [String: Any] = [:]
        for (key, value) in response.allHeaderFields {
            if let keyString = key as? String {
                headers[keyString.lowercased()] = value
            }
        }

        let remaining = parseHeaderDouble(headers["x-ratelimit-remaining"])
        let used = parseHeaderDouble(headers["x-ratelimit-used"])
        let resetInterval = parseHeaderDouble(headers["x-ratelimit-reset"])

        var message: String? = nil
        if response.statusCode == 429 {
            if let data = data,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let jsonMessage = json["message"] as? String {
                message = jsonMessage
            } else if let data = data,
                      let body = String(data: data, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                      !body.isEmpty {
                message = body
            } else {
                message = HTTPURLResponse.localizedString(forStatusCode: response.statusCode)
            }
        }

        // If no rate-limit headers are present and status is success, avoid storing noise.
        if remaining == nil && used == nil && resetInterval == nil && response.statusCode < 400 {
            return nil
        }

        let status = RedditRateLimitStatus(
            statusCode: response.statusCode,
            message: message,
            remaining: remaining,
            resetInterval: resetInterval,
            used: used,
            subreddit: subreddit,
            endpoint: endpoint,
            capturedAt: Date()
        )
        storeRateLimit(status)
        return status
    }

    private func parseHeaderDouble(_ value: Any?) -> Double? {
        if let string = value as? String {
            return Double(string)
        }
        if let number = value as? NSNumber {
            return number.doubleValue
        }
        return nil
    }

    private func storeRateLimit(_ status: RedditRateLimitStatus) {
        rateLimitQueue.async(flags: .barrier) {
            switch status.endpoint {
            case .feed:
                if let subreddit = status.subreddit {
                    self.feedRateLimitStatus[subreddit] = status
                }
            case .comments:
                let key = status.subreddit ?? "*"
                self.commentRateLimitStatus[key] = status
            }
        }
    }

    func latestFeedRateLimitStatus(for subreddit: String) -> RedditRateLimitStatus? {
        rateLimitQueue.sync {
            feedRateLimitStatus[subreddit]
        }
    }

    func latestCommentRateLimitStatus(for subreddit: String? = nil) -> RedditRateLimitStatus? {
        rateLimitQueue.sync {
            if let subreddit = subreddit, let status = commentRateLimitStatus[subreddit] {
                return status
            }
            return commentRateLimitStatus[subreddit ?? "*"]
        }
    }

    func clearFeedRateLimitStatus(for subreddit: String) {
        rateLimitQueue.async(flags: .barrier) {
            self.feedRateLimitStatus.removeValue(forKey: subreddit)
        }
    }

    func suggestedDelay(after status: RedditRateLimitStatus?, baseline: TimeInterval = 0.7) -> TimeInterval {
        guard let status else { return baseline }
        if status.isRateLimited {
            return max(status.resetInterval ?? baseline, baseline)
        }
        if let remaining = status.remaining,
           remaining <= 1,
           let reset = status.resetInterval {
            return max(reset, baseline)
        }
        if let remaining = status.remaining,
           remaining > 1,
           let reset = status.resetInterval {
            let interval = reset / max(remaining, 1)
            return max(interval, baseline)
        }
        if let reset = status.resetInterval {
            return max(reset * 0.25, baseline)
        }
        return baseline
    }

    enum CommentSortOption: String, CaseIterable, Identifiable {
        case best = "confidence"
        case top = "top"
        case new = "new"
        case controversial = "controversial"
        case old = "old"

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .best:
                return "Best"
            case .top:
                return "Top"
            case .new:
                return "New"
            case .controversial:
                return "Controversial"
            case .old:
                return "Old"
            }
        }
    }

    // MARK: - OAuth Headers

    /// Adds authentication headers to the request if user is logged in
    private func addAuthHeaders(to request: inout URLRequest) {
        // Always add a user agent
        request.addValue("RSS Reader App/1.0", forHTTPHeaderField: "User-Agent")

        guard isAuthenticated else { return }

        let settings = persistenceManager.loadSettings()
        request.addValue("Bearer \(settings.redditAccessToken)", forHTTPHeaderField: "Authorization")
    }

    // MARK: - Automatic Token Refresh

    /// Ensures the OAuth token is valid before making requests.
    /// Automatically refreshes the token if it's expired or expiring soon.
    private func ensureValidTokenIfNeeded() async {
        guard let oauthManager = oauthManager else { return }
        do {
            try await oauthManager.ensureValidToken()
        } catch {
            print("⚠️ RedditService: Failed to refresh token: \(error.localizedDescription)")
        }
    }

    /// Refreshes token and retries on 401 errors. Returns true if refresh succeeded.
    private func handleAuthErrorAndRefresh() async -> Bool {
        guard let oauthManager = oauthManager else { return false }
        do {
            _ = try await oauthManager.refreshAccessTokenAsync()
            print("🔐 RedditService: Refreshed token after 401 error")
            return true
        } catch {
            print("❌ RedditService: Failed to refresh token after 401: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Sort Options
    enum SortOption: String, CaseIterable, Identifiable {
        case hot = "hot"
        case new = "new"
        case topDay = "top_day"
        case topWeek = "top_week"

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .hot:
                return "Hot"
            case .new:
                return "New"
            case .topDay:
                return "Top Day"
            case .topWeek:
                return "Top Week"
            }
        }

        var redditPathComponent: String {
            switch self {
            case .hot:
                return "hot"
            case .new:
                return "new"
            case .topDay, .topWeek:
                return "top"
            }
        }

        var timeRangeQueryValue: String? {
            switch self {
            case .hot, .new:
                return nil
            case .topDay:
                return "day"
            case .topWeek:
                return "week"
            }
        }
    }
    
    // MARK: - Subreddit Fetching
    func fetchSubreddit(subreddit: String, sortOption: SortOption = .hot) -> AnyPublisher<RedditFeed, Never> {
        // Set limit based on sort option
        let limit: Int
        switch sortOption {
        case .hot, .new, .topDay, .topWeek:
            limit = 50
        }

        // Proactive token refresh before making the request
        return Future<Void, Never> { [weak self] promise in
            Task {
                await self?.ensureValidTokenIfNeeded()
                promise(.success(()))
            }
        }
        .flatMap { [weak self] _ -> AnyPublisher<RedditFeed, Never> in
            guard let self = self else {
                return Just(RedditFeed(subreddit: subreddit, displayName: "Error", posts: [])).eraseToAnyPublisher()
            }
            return self.performSubredditFetch(subreddit: subreddit, sortOption: sortOption, limit: limit)
        }
        .eraseToAnyPublisher()
    }

    /// Internal method that performs the actual subreddit fetch
    private func performSubredditFetch(subreddit: String, sortOption: SortOption, limit: Int) -> AnyPublisher<RedditFeed, Never> {
        var urlComponents = URLComponents(string: "\(baseURL)/r/\(subreddit)/\(sortOption.redditPathComponent)/.json")
        var queryItems = [URLQueryItem(name: "limit", value: "\(limit)")]
        if let timeRange = sortOption.timeRangeQueryValue {
            queryItems.append(URLQueryItem(name: "t", value: timeRange))
        }
        urlComponents?.queryItems = queryItems

        guard let url = urlComponents?.url else {
            print("❌ RedditService: Invalid URL for subreddit: \(subreddit)")
            return Just(RedditFeed(subreddit: subreddit, displayName: "Invalid Subreddit", posts: []))
                .eraseToAnyPublisher()
        }

        var request = URLRequest(url: url)
        request.addValue("application/json", forHTTPHeaderField: "Accept")
        addAuthHeaders(to: &request)

        return session.dataTaskPublisher(for: request)
            .tryMap { output -> RedditFeed in
                guard let response = output.response as? HTTPURLResponse else {
                    throw RedditServiceError.transport(URLError(.badServerResponse))
                }

                let rateStatus = self.captureRateLimit(
                    from: response,
                    data: output.data,
                    subreddit: subreddit,
                    endpoint: .feed
                )

                if rateStatus == nil {
                    self.clearFeedRateLimitStatus(for: subreddit)
                }

                guard (200...299).contains(response.statusCode) else {
                    throw RedditServiceError.httpStatus(code: response.statusCode,
                                                       subreddit: subreddit,
                                                       status: rateStatus)
                }

                let listing = try JSONDecoder().decode(RedditListing.self, from: output.data)

                print("📱 RedditService: Decoded Reddit data for r/\(subreddit), found \(listing.data.children.count) posts")

                let posts = listing.data.children.compactMap { child -> RedditPost? in
                    guard let data = child.data else { return nil }

                    // Add debugging for URL construction
                    let postURL: URL? = data.url.flatMap { urlString in
                        let url = URL(string: urlString)
                        if url == nil {
                            print("⚠️ Failed to construct URL from string: '\(urlString)'")
                        }
                        return url
                    }

                    if let url = postURL {
                        print("📱 RedditService: Constructed URL for post '\(data.title.prefix(30))...': \(url.absoluteString)")
                    }

                                    return RedditPost(
                                        id: data.id,
                                        title: data.title,
                                        content: data.selftext ?? "",
                                        url: postURL,
                                        publishDate: Date(timeIntervalSince1970: TimeInterval(data.created_utc ?? 0)),
                                        author: data.author ?? "Unknown",
                                        subreddit: subreddit,
                                        score: data.score ?? 0,
                                        commentCount: data.num_comments ?? 0,
                                        isRead: false,
                                        isFavorite: false,
                                        isStickied: data.stickied ?? false,
                                        thumbnail: data.thumbnail,
                                        preview: data.preview,
                                        media_metadata: data.media_metadata,
                                        gallery_data: data.gallery_data
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
                if case let RedditServiceError.httpStatus(code, _, status) = error {
                    if code == 429 {
                        let reason = status?.message ?? "Too many requests."
                        print("⚠️ RedditService: Rate limited for r/\(subreddit): \(reason)")
                    } else {
                        print("❌ RedditService: HTTP \(code) fetching r/\(subreddit)")
                    }
                } else {
                    print("❌ RedditService: Error fetching r/\(subreddit): \(error.localizedDescription)")
                }

                let fallbackFeed = RedditFeed(
                    subreddit: subreddit,
                    displayName: "Error Loading Subreddit",
                    posts: []
                )
                return Just(fallbackFeed).eraseToAnyPublisher()
            }
            .eraseToAnyPublisher()
    }
    
    // MARK: - Comments Fetching
    func fetchUserAvatarURL(author: String) async -> URL? {
        let normalizedAuthor = author.trimmingCharacters(in: .whitespacesAndNewlines)
        let cacheKey = normalizedAuthor.lowercased()

        guard !normalizedAuthor.isEmpty,
              normalizedAuthor != "[deleted]",
              normalizedAuthor.lowercased() != "automoderator" else {
            return nil
        }

        if let cachedURL = userAvatarCache[cacheKey] {
            return cachedURL
        }

        if userAvatarMissingCache.contains(cacheKey) {
            return nil
        }

        await ensureValidTokenIfNeeded()
        await waitForRateLimit()

        var components = URLComponents()
        components.scheme = "https"
        components.host = isAuthenticated ? "oauth.reddit.com" : "www.reddit.com"
        components.path = "/user/\(normalizedAuthor)/about" + (isAuthenticated ? "" : ".json")

        guard let url = components.url else {
            userAvatarMissingCache.insert(cacheKey)
            return nil
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        addAuthHeaders(to: &request)

        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                userAvatarMissingCache.insert(cacheKey)
                return nil
            }

            let payload = try JSONDecoder().decode(RedditUserAboutResponse.self, from: data)
            guard let iconURL = Self.cleanedAvatarURL(from: payload.data.iconImg) else {
                userAvatarMissingCache.insert(cacheKey)
                return nil
            }

            userAvatarCache[cacheKey] = iconURL
            return iconURL
        } catch {
            print("⚠️ RedditService: Failed to fetch avatar for u/\(normalizedAuthor): \(error.localizedDescription)")
            userAvatarMissingCache.insert(cacheKey)
            return nil
        }
    }

    func fetchCommentsDetailed(for postId: String,
                               in subreddit: String,
                               limit: Int = 1000,
                               depth: Int = 10,
                               sortOption: CommentSortOption = .best) -> AnyPublisher<RedditCommentFetchResult, Never> {
        let cacheKey = "\(subreddit)_\(postId)_\(sortOption.rawValue)"
        if let cachedComments = commentCache[cacheKey] {
            print("📱 RedditService: Using cached \(sortOption.displayName) comments for post ID: \(postId) in r/\(subreddit)")
            let cachedResult = RedditCommentFetchResult(
                comments: cachedComments,
                rateLimit: nil,
                fromCache: true,
                errorDescription: nil
            )
            return Just(cachedResult).eraseToAnyPublisher()
        }

        // Proactive token refresh before making the request
        return Future<Void, Never> { [weak self] promise in
            Task {
                await self?.ensureValidTokenIfNeeded()
                promise(.success(()))
            }
        }
        .flatMap { [weak self] _ -> AnyPublisher<RedditCommentFetchResult, Never> in
            guard let self = self else {
                return Just(RedditCommentFetchResult(
                    comments: [],
                    rateLimit: nil,
                    fromCache: false,
                    errorDescription: "Service unavailable"
                )).eraseToAnyPublisher()
            }
            return self.performCommentsFetch(for: postId, in: subreddit, limit: limit, depth: depth, sortOption: sortOption, cacheKey: cacheKey)
        }
        .eraseToAnyPublisher()
    }

    /// Internal method that performs the actual comments fetch
    private func performCommentsFetch(for postId: String, in subreddit: String, limit: Int, depth: Int, sortOption: CommentSortOption, cacheKey: String) -> AnyPublisher<RedditCommentFetchResult, Never> {
        var components = URLComponents(string: "\(baseURL)/r/\(subreddit)/comments/\(postId)/.json")!
        components.queryItems = [
            URLQueryItem(name: "limit", value: "\(limit)"),
            URLQueryItem(name: "depth", value: "\(depth)"),
            URLQueryItem(name: "threaded", value: "false"),
            URLQueryItem(name: "sort", value: sortOption.rawValue)
        ]

        guard let url = components.url else {
            print("⚠️ RedditService: Invalid URL for comments request")
            let result = RedditCommentFetchResult(
                comments: [],
                rateLimit: nil,
                fromCache: false,
                errorDescription: "Invalid URL"
            )
            return Just(result).eraseToAnyPublisher()
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        addAuthHeaders(to: &request)

        print("🌐 RedditService: Fetching comments from: \(url)")

        return session.dataTaskPublisher(for: request)
            .tryMap { output -> RedditCommentFetchResult in
                guard let response = output.response as? HTTPURLResponse else {
                    throw RedditServiceError.transport(URLError(.badServerResponse))
                }

                let rateStatus = self.captureRateLimit(
                    from: response,
                    data: output.data,
                    subreddit: subreddit,
                    endpoint: .comments
                )

                if rateStatus == nil {
                    self.rateLimitQueue.async(flags: .barrier) {
                        let key = subreddit.isEmpty ? "*" : subreddit
                        self.commentRateLimitStatus.removeValue(forKey: key)
                    }
                }

                if response.statusCode == 429 {
                    let reason = rateStatus?.message ?? "Too many requests."
                    print("⚠️ RedditService: Rate limited when loading comments for post ID: \(postId) in r/\(subreddit) – \(reason)")
                    return RedditCommentFetchResult(
                        comments: [],
                        rateLimit: rateStatus,
                        fromCache: false,
                        errorDescription: reason
                    )
                }

                guard (200...299).contains(response.statusCode) else {
                    throw RedditServiceError.httpStatus(code: response.statusCode,
                                                       subreddit: subreddit,
                                                       status: rateStatus)
                }

                guard let json = try JSONSerialization.jsonObject(with: output.data) as? [[String: Any]],
                      json.count > 1,
                      let postData = json[0] as? [String: Any],
                      let postDataChildren = (postData["data"] as? [String: Any])?["children"] as? [[String: Any]],
                      let firstPost = postDataChildren.first?["data"] as? [String: Any],
                      let parsedPostId = firstPost["id"] as? String else {
                    print("⚠️ RedditService: Failed to parse JSON response for comments")
                    throw RedditServiceError.decoding(subreddit: subreddit, underlying: URLError(.cannotParseResponse))
                }

                self.linkId = "t3_\(parsedPostId)"

                let dataDict = json[1]["data"] as? [String: Any]
                let commentsArray = dataDict?["children"] as? [[String: Any]] ?? []

                print("📝 RedditService: Found \(commentsArray.count) top-level comments for post ID: \(parsedPostId)")

                let comments = try self.parseCommentsEfficiently(commentsArray, maxDepth: depth)

                print("✅ RedditService: Parsed and processed \(comments.count) comments total for post ID: \(parsedPostId)")

                self.addToCache(comments, for: cacheKey)
                print("📊 RedditService: Returning \(comments.count) comments for post ID: \(parsedPostId)")

                return RedditCommentFetchResult(
                    comments: comments,
                    rateLimit: rateStatus,
                    fromCache: false,
                    errorDescription: nil
                )
            }
            .catch { error -> Just<RedditCommentFetchResult> in
                var status: RedditRateLimitStatus? = nil
                var description = error.localizedDescription

                if let serviceError = error as? RedditServiceError {
                    switch serviceError {
                    case .httpStatus(let code, _, let capturedStatus):
                        status = capturedStatus
                        description = "HTTP \(code)"
                        print("❌ RedditService: HTTP \(code) while loading comments for post ID: \(postId) in r/\(subreddit)")
                    case .decoding(_, let underlying):
                        description = "Decoding error: \(underlying.localizedDescription)"
                        print("❌ RedditService: Decoding comments failed for post ID: \(postId) in r/\(subreddit) – \(description)")
                    case .transport(let underlying):
                        description = underlying.localizedDescription
                        print("❌ RedditService: Transport error loading comments for post ID: \(postId) in r/\(subreddit) – \(description)")
                    case .authenticationRequired:
                        description = serviceError.localizedDescription
                    case .apiError(let message):
                        description = message
                    }
                } else {
                    print("❌ RedditService: Unexpected error loading comments for post ID: \(postId) in r/\(subreddit) – \(description)")
                }

                let fallback = RedditCommentFetchResult(
                    comments: [],
                    rateLimit: status,
                    fromCache: false,
                    errorDescription: description
                )
                return Just(fallback)
            }
            .eraseToAnyPublisher()
    }

    func fetchCommentsDetailed(for postId: String,
                               in subreddit: String,
                               limit: Int = 1000,
                               depth: Int = 10,
                               sortOption: CommentSortOption = .best) async -> RedditCommentFetchResult {
        await withCheckedContinuation { continuation in
            var cancellable: AnyCancellable?
            let publisher = fetchCommentsDetailed(for: postId, in: subreddit, limit: limit, depth: depth, sortOption: sortOption)
            cancellable = publisher.sink { result in
                continuation.resume(returning: result)
                cancellable?.cancel()
            }
        }
    }

    func fetchComments(for postId: String, in subreddit: String, limit: Int = 1000, depth: Int = 10, sortOption: CommentSortOption = .best) -> AnyPublisher<[RedditCommentModel], Never> {
        fetchCommentsDetailed(for: postId, in: subreddit, limit: limit, depth: depth, sortOption: sortOption)
            .map(\.comments)
            .eraseToAnyPublisher()
    }

    @MainActor
    func voteComment(commentID: String, direction: RedditVoteDirection) async throws {
        let fullname = normalizedRedditThingID(prefix: "t1", rawID: commentID)
        _ = try await performAuthenticatedRedditPost(
            path: "/api/vote",
            queryItems: [
                URLQueryItem(name: "id", value: fullname),
                URLQueryItem(name: "dir", value: "\(direction.rawValue)")
            ]
        )
    }

    @MainActor
    func replyToComment(commentID: String, body: String) async throws {
        let fullname = normalizedRedditThingID(prefix: "t1", rawID: commentID)
        let data = try await performAuthenticatedRedditPost(
            path: "/api/comment",
            queryItems: [
                URLQueryItem(name: "api_type", value: "json"),
                URLQueryItem(name: "thing_id", value: fullname),
                URLQueryItem(name: "text", value: body)
            ]
        )
        try validateRedditJSONResponse(data)
    }

    private func normalizedRedditThingID(prefix: String, rawID: String) -> String {
        rawID.hasPrefix("\(prefix)_") ? rawID : "\(prefix)_\(rawID)"
    }

    private func performAuthenticatedRedditPost(path: String,
                                                queryItems: [URLQueryItem],
                                                retryingAfterRefresh: Bool = false) async throws -> Data {
        guard isAuthenticated else {
            throw RedditServiceError.authenticationRequired
        }

        await ensureValidTokenIfNeeded()
        await waitForRateLimit()

        var components = URLComponents()
        components.scheme = "https"
        components.host = "oauth.reddit.com"
        components.path = path
        components.queryItems = queryItems

        guard let body = components.percentEncodedQuery?.data(using: .utf8) else {
            throw RedditServiceError.apiError(message: "Unable to encode Reddit request.")
        }

        var request = URLRequest(url: URL(string: "https://oauth.reddit.com\(path)")!)
        request.httpMethod = "POST"
        request.httpBody = body
        request.timeoutInterval = 30
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        addAuthHeaders(to: &request)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw RedditServiceError.transport(URLError(.badServerResponse))
        }

        if httpResponse.statusCode == 401 && !retryingAfterRefresh {
            if await handleAuthErrorAndRefresh() {
                return try await performAuthenticatedRedditPost(path: path, queryItems: queryItems, retryingAfterRefresh: true)
            }
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let bodyText = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if httpResponse.statusCode == 403 && path == "/api/comment" {
                throw RedditServiceError.apiError(message: "Reconnect Reddit in Settings to grant reply permission.")
            }
            throw RedditServiceError.apiError(message: bodyText?.isEmpty == false ? bodyText! : "Reddit returned HTTP \(httpResponse.statusCode).")
        }

        return data
    }

    private func validateRedditJSONResponse(_ data: Data) throws {
        guard !data.isEmpty else { return }

        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let json = object["json"] as? [String: Any] else {
            return
        }

        guard let errors = json["errors"] as? [[Any]], !errors.isEmpty else {
            return
        }

        let messages = errors.compactMap { error -> String? in
            if error.count >= 2, let message = error[1] as? String {
                return message
            }
            return nil
        }

        throw RedditServiceError.apiError(message: messages.isEmpty ? "Reddit rejected the request." : messages.joined(separator: "\n"))
    }
    
    // Optimized version that avoids recursion for better performance
    private func parseCommentsEfficiently(_ commentsArray: [[String: Any]], maxDepth: Int = 10) throws -> [RedditCommentModel] {
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
                    if depth < maxDepth {
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
        userAvatarCache.removeAll()
        userAvatarMissingCache.removeAll()
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
    let stickied: Bool?
    
    // Fields for gallery post processing
    let preview: Preview?
    let media_metadata: [String: MediaMetadata]?
    let gallery_data: GalleryData?
}
