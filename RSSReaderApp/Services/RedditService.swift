import Foundation
import Combine

struct RedditCommentFetchResult {
    let comments: [RedditCommentModel]
    let error: Error?
    let httpStatusCode: Int?
    let wasCacheHit: Bool
    let rateLimitRemaining: Double?
    let rateLimitReset: Double?
    let retryAfter: Double?
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

enum RedditServiceError: LocalizedError {
    case invalidResponse
    case httpError(statusCode: Int, bodyPreview: String, rateLimitReset: Double?, retryAfter: Double?)
    case parsingFailed(reason: String)
    case authenticationRequired
    case apiError(message: String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Invalid response from Reddit."
        case .httpError(let statusCode, let bodyPreview, _, _):
            return Self.userFacingHTTPMessage(statusCode: statusCode, bodyPreview: bodyPreview)
        case .parsingFailed(let reason):
            return "Failed to parse Reddit comments: \(reason)"
        case .authenticationRequired:
            return "Sign in to Reddit in Settings before using this action."
        case .apiError(let message):
            return message
        }
    }

    private static func userFacingHTTPMessage(statusCode: Int, bodyPreview: String) -> String {
        let trimmedBody = bodyPreview.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercasedBody = trimmedBody.lowercased()
        let looksLikeHTML = lowercasedBody.contains("<html") ||
            lowercasedBody.contains("<body") ||
            lowercasedBody.contains("<!doctype") ||
            lowercasedBody.contains("class=theme-") ||
            lowercasedBody.contains("<style>")

        if looksLikeHTML {
            switch statusCode {
            case 401:
                return "Reddit rejected the session. Sign in again in Settings."
            case 403:
                return "Reddit blocked this request. Sign in again in Settings, then refresh."
            case 429:
                return "Reddit is rate limiting requests right now. Please try again in a moment."
            default:
                return "HTTP \(statusCode) from Reddit."
            }
        }

        guard !trimmedBody.isEmpty else {
            return "HTTP \(statusCode) from Reddit."
        }

        return "HTTP \(statusCode) from Reddit: \(trimmedBody)"
    }

    var statusCode: Int? {
        if case let .httpError(statusCode, _, _, _) = self {
            return statusCode
        }
        return nil
    }

    var rateLimitReset: Double? {
        if case let .httpError(_, _, reset, _) = self {
            return reset
        }
        return nil
    }

    var retryAfter: Double? {
        if case let .httpError(_, _, _, retryAfter) = self {
            return retryAfter
        }
        return nil
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

    // Rate limiting properties
    private var lastRequestTime = Date.distantPast
    private let minRequestInterval: TimeInterval = 0.1 // 100ms between requests
    private let rateLimitLock = NSLock()

    // OAuth support
    private let persistenceManager = PersistenceManager.shared
    private var oauthManager: RedditOAuthManager?

    private static let commentSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.isDiscretionary = false
        config.waitsForConnectivity = true
        config.timeoutIntervalForRequest = 45
        config.timeoutIntervalForResource = 180
        config.httpMaximumConnectionsPerHost = 2
        config.networkServiceType = .responsiveData
        #if os(iOS)
        config.allowsCellularAccess = true
        if #available(iOS 15.0, *) {
            config.allowsExpensiveNetworkAccess = true
            config.allowsConstrainedNetworkAccess = true
            config.shouldUseExtendedBackgroundIdleMode = true
        }
        #endif
        return URLSession(configuration: config)
    }()

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
        addAuthHeaders(to: &request) // Use OAuth headers if available

        return session.dataTaskPublisher(for: request)
            .tryMap { output -> (RedditListing, Int) in
                guard let httpResponse = output.response as? HTTPURLResponse else {
                    throw RedditServiceError.invalidResponse
                }
                
                let statusCode = httpResponse.statusCode
                let rateInfo = self.extractRateLimitInfo(from: httpResponse)
                guard (200...299).contains(statusCode) else {
                    let snippet = String(data: output.data.prefix(200), encoding: .utf8) ?? "<non-UTF8 body>"
                    throw RedditServiceError.httpError(
                        statusCode: statusCode,
                        bodyPreview: snippet,
                        rateLimitReset: rateInfo.reset,
                        retryAfter: rateInfo.retryAfter
                    )
                }
                
                let listing = try JSONDecoder().decode(RedditListing.self, from: output.data)
                return (listing, statusCode)
            }
            .map { payload -> RedditFeed in
                let (listing, statusCode) = payload
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
                    posts: posts,
                    lastFetchStatusCode: statusCode,
                    fetchStatusMessage: nil
                )
            }
            .catch { error -> AnyPublisher<RedditFeed, Never> in
                let statusCode: Int?
                var message: String?
                var cooldownDate: Date? = nil
                
                if let serviceError = error as? RedditServiceError {
                    statusCode = serviceError.statusCode
                    if serviceError.statusCode == 429 {
                        if let cooldown = (serviceError.retryAfter ?? serviceError.rateLimitReset), cooldown > 0 {
                            let cooldownMessage = self.buildCooldownMessage(seconds: cooldown)
                            message = cooldownMessage
                            cooldownDate = Date().addingTimeInterval(cooldown)
                            print("⚠️ RedditService: Rate limited for approximately \(self.formatCooldownDuration(cooldown)) (r/\(subreddit))")
                        } else {
                            message = "Reddit is rate limiting requests right now. Please try again in a moment."
                            print("⚠️ RedditService: Rate limited while fetching r/\(subreddit)")
                        }
                    } else {
                        message = serviceError.errorDescription
                    }
                    print("❌ RedditService: Error fetching r/\(subreddit): \(message ?? serviceError.localizedDescription)")
                } else if let urlError = error as? URLError {
                    statusCode = nil
                    message = urlError.localizedDescription
                    print("❌ RedditService: Network error fetching r/\(subreddit): \(message ?? "")")
                } else {
                    statusCode = nil
                    message = error.localizedDescription
                    print("❌ RedditService: Unexpected error fetching r/\(subreddit): \(message ?? "")")
                }
                
                return Just(RedditFeed(
                    subreddit: subreddit, 
                    displayName: "Error Loading Subreddit", 
                    posts: [],
                    lastFetchStatusCode: statusCode,
                    fetchStatusMessage: message,
                    rateLimitCooldownUntil: cooldownDate
                )).eraseToAnyPublisher()
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

    func fetchComments(for postId: String, in subreddit: String, limit: Int = 1000, depth: Int = 10, sortOption: CommentSortOption = .best) -> AnyPublisher<[RedditCommentModel], Never> {
        fetchCommentsDetailed(for: postId, in: subreddit, limit: limit, depth: depth, sortOption: sortOption)
            .map { $0.comments }
            .eraseToAnyPublisher()
    }

    @MainActor
    func voteComment(commentID: String, direction: RedditVoteDirection) async throws {
        let normalizedID = normalizedRedditThingID(prefix: "t1_", rawID: commentID)
        _ = try await performAuthenticatedRedditPost(
            path: "/api/vote",
            queryItems: [
                URLQueryItem(name: "id", value: normalizedID),
                URLQueryItem(name: "dir", value: "\(direction.rawValue)")
            ]
        )
    }

    @MainActor
    func replyToComment(commentID: String, body: String) async throws -> RedditCommentModel {
        let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedBody.isEmpty else {
            throw RedditServiceError.apiError(message: "Reply text cannot be empty.")
        }

        let normalizedID = normalizedRedditThingID(prefix: "t1_", rawID: commentID)
        let data = try await performAuthenticatedRedditPost(
            path: "/api/comment",
            queryItems: [
                URLQueryItem(name: "api_type", value: "json"),
                URLQueryItem(name: "thing_id", value: normalizedID),
                URLQueryItem(name: "text", value: trimmedBody)
            ]
        )
        try validateRedditJSONResponse(data)
        return submittedComment(from: data, fallbackBody: trimmedBody)
    }

    @MainActor
    func commentOnPost(postID: String, body: String) async throws -> RedditCommentModel {
        let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedBody.isEmpty else {
            throw RedditServiceError.apiError(message: "Comment text cannot be empty.")
        }

        let normalizedID = normalizedRedditThingID(prefix: "t3_", rawID: postID)
        let data = try await performAuthenticatedRedditPost(
            path: "/api/comment",
            queryItems: [
                URLQueryItem(name: "api_type", value: "json"),
                URLQueryItem(name: "thing_id", value: normalizedID),
                URLQueryItem(name: "text", value: trimmedBody)
            ]
        )
        try validateRedditJSONResponse(data)
        return submittedComment(from: data, fallbackBody: trimmedBody)
    }

    private func submittedComment(from data: Data, fallbackBody: String) -> RedditCommentModel {
        let fallbackAuthor = persistenceManager.loadSettings().redditUsername
        let fallbackID = "local_\(UUID().uuidString)"
        let fallbackCreatedUtc = Date().timeIntervalSince1970

        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let json = object["json"] as? [String: Any],
              let dataObject = json["data"] as? [String: Any],
              let things = dataObject["things"] as? [[String: Any]],
              let firstThing = things.first,
              let commentData = firstThing["data"] as? [String: Any] else {
            return RedditCommentModel(
                id: fallbackID,
                author: fallbackAuthor.isEmpty ? "me" : fallbackAuthor,
                body: fallbackBody,
                score: 1,
                createdUtc: fallbackCreatedUtc,
                replies: [],
                indentationLevel: 0
            )
        }

        let rawName = commentData["name"] as? String
        let rawID = commentData["id"] as? String
        let id = rawID ?? rawName?.replacingOccurrences(of: "t1_", with: "") ?? fallbackID
        let author = (commentData["author"] as? String) ?? (fallbackAuthor.isEmpty ? "me" : fallbackAuthor)
        let body = (commentData["body"] as? String) ?? fallbackBody
        let score = (commentData["score"] as? Int) ?? (commentData["score"] as? NSNumber)?.intValue ?? 1
        let createdUtc = (commentData["created_utc"] as? Double)
            ?? (commentData["created_utc"] as? NSNumber)?.doubleValue
            ?? fallbackCreatedUtc

        return RedditCommentModel(
            id: id,
            author: author,
            body: body,
            score: score,
            createdUtc: createdUtc,
            replies: [],
            indentationLevel: 0
        )
    }

    private func normalizedRedditThingID(prefix: String, rawID: String) -> String {
        rawID.hasPrefix(prefix) ? rawID : "\(prefix)\(rawID)"
    }

    private func performAuthenticatedRedditPost(path: String, queryItems: [URLQueryItem], retryingAfterRefresh: Bool = false) async throws -> Data {
        guard isAuthenticated else {
            throw RedditServiceError.authenticationRequired
        }

        await ensureValidTokenIfNeeded()
        await waitForRateLimit()

        var components = URLComponents()
        components.scheme = "https"
        components.host = "oauth.reddit.com"
        components.path = path

        guard let url = components.url else {
            throw RedditServiceError.invalidResponse
        }

        var bodyComponents = URLComponents()
        bodyComponents.queryItems = queryItems

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = bodyComponents.query?.data(using: .utf8)
        addAuthHeaders(to: &request)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw RedditServiceError.invalidResponse
        }

        if httpResponse.statusCode == 401, !retryingAfterRefresh, await handleAuthErrorAndRefresh() {
            return try await performAuthenticatedRedditPost(path: path, queryItems: queryItems, retryingAfterRefresh: true)
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let snippet = String(data: data.prefix(300), encoding: .utf8) ?? "<non-UTF8 body>"

            if httpResponse.statusCode == 403, path == "/api/comment" {
                let authHeader = httpResponse.value(forHTTPHeaderField: "WWW-Authenticate") ?? ""
                let lowercasedAuthFailure = "\(authHeader) \(snippet)".lowercased()
                if lowercasedAuthFailure.contains("insufficient_scope") || lowercasedAuthFailure.contains("scope") {
                    throw RedditServiceError.apiError(message: "Reconnect Reddit in Settings to grant reply permission.")
                }

                throw RedditServiceError.apiError(message: "Reddit rejected the comment (403). Try reconnecting Reddit in Settings, then submit again.")
            }

            let rateInfo = extractRateLimitInfo(from: httpResponse)
            throw RedditServiceError.httpError(
                statusCode: httpResponse.statusCode,
                bodyPreview: snippet,
                rateLimitReset: rateInfo.reset,
                retryAfter: rateInfo.retryAfter
            )
        }

        return data
    }

    private func validateRedditJSONResponse(_ data: Data) throws {
        guard !data.isEmpty else { return }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        if let json = object["json"] as? [String: Any],
           let errors = json["errors"] as? [[Any]],
           let firstError = errors.first {
            let message = firstError.compactMap { value -> String? in
                guard let string = value as? String, !string.isEmpty else { return nil }
                return string
            }.joined(separator: ": ")

            if !message.isEmpty {
                throw RedditServiceError.apiError(message: message)
            }
        }
    }

    func fetchCommentsDetailed(for postId: String, in subreddit: String, limit: Int = 1000, depth: Int = 10, sortOption: CommentSortOption = .best) -> AnyPublisher<RedditCommentFetchResult, Never> {
        let cacheKey = "\(subreddit)_\(postId)_\(sortOption.rawValue)"
        if let cachedComments = commentCache[cacheKey] {
            print("📱 RedditService: Using cached \(sortOption.displayName) comments for post ID: \(postId) in r/\(subreddit) (cache hit)")
            return Just(RedditCommentFetchResult(
                comments: cachedComments,
                error: nil,
                httpStatusCode: nil,
                wasCacheHit: true,
                rateLimitRemaining: nil,
                rateLimitReset: nil,
                retryAfter: nil
            )).eraseToAnyPublisher()
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
                    error: RedditServiceError.invalidResponse,
                    httpStatusCode: nil,
                    wasCacheHit: false,
                    rateLimitRemaining: nil,
                    rateLimitReset: nil,
                    retryAfter: nil
                )).eraseToAnyPublisher()
            }
            return self.performCommentsFetch(for: postId, in: subreddit, limit: limit, depth: depth, sortOption: sortOption, cacheKey: cacheKey)
        }
        .eraseToAnyPublisher()
    }

    func invalidateCommentCache(for postId: String, in subreddit: String) {
        let normalizedPrefix = "\(subreddit)_\(postId)_".lowercased()
        let keysToRemove = commentCache.keys.filter { $0.lowercased().hasPrefix(normalizedPrefix) }
        keysToRemove.forEach { key in
            commentCache.removeValue(forKey: key)
        }

        if !keysToRemove.isEmpty {
            print("📱 RedditService: Invalidated \(keysToRemove.count) cached comment set(s) for post ID: \(postId) in r/\(subreddit)")
        }
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
            print("⚠️ RedditService: Invalid URL")
            return Just(RedditCommentFetchResult(
                comments: [],
                error: RedditServiceError.invalidResponse,
                httpStatusCode: nil,
                wasCacheHit: false,
                rateLimitRemaining: nil,
                rateLimitReset: nil,
                retryAfter: nil
            )).eraseToAnyPublisher()
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 45
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        addAuthHeaders(to: &request)

        print("🌐 RedditService: Fetching comments (background) from: \(url)")

        return RedditService.commentSession.dataTaskPublisher(for: request)
            .tryMap { data, response -> (Data, HTTPURLResponse) in
                guard let httpResponse = response as? HTTPURLResponse else {
                    throw RedditServiceError.invalidResponse
                }
                return (data, httpResponse)
            }
            .map { payload -> RedditCommentFetchResult in
                let (data, httpResponse) = payload
                let statusCode = httpResponse.statusCode
                let rateInfo = self.extractRateLimitInfo(from: httpResponse)

                if !(200...299).contains(statusCode) {
                    let snippet = String(data: data.prefix(200), encoding: .utf8) ?? "<non-UTF8 body>"
                    let error = RedditServiceError.httpError(
                        statusCode: statusCode,
                        bodyPreview: snippet,
                        rateLimitReset: rateInfo.reset,
                        retryAfter: rateInfo.retryAfter
                    )
                    print("❌ RedditService: HTTP \(statusCode) while fetching Reddit comments: \(snippet)")
                    return RedditCommentFetchResult(
                        comments: [],
                        error: error,
                        httpStatusCode: statusCode,
                        wasCacheHit: false,
                        rateLimitRemaining: rateInfo.remaining,
                        rateLimitReset: rateInfo.reset,
                        retryAfter: rateInfo.retryAfter
                    )
                }

                do {
                    let comments = try self.decodeCommentsResponse(data: data, depth: depth)
                    print("📊 RedditService: Returning \(comments.count) comments (status: \(statusCode))")
                    self.addToCache(comments, for: cacheKey)
                    return RedditCommentFetchResult(
                        comments: comments,
                        error: nil,
                        httpStatusCode: statusCode,
                        wasCacheHit: false,
                        rateLimitRemaining: rateInfo.remaining,
                        rateLimitReset: rateInfo.reset,
                        retryAfter: rateInfo.retryAfter
                    )
                } catch {
                    print("❌ RedditService: Failed to decode comments: \(error.localizedDescription)")
                    return RedditCommentFetchResult(
                        comments: [],
                        error: error,
                        httpStatusCode: statusCode,
                        wasCacheHit: false,
                        rateLimitRemaining: rateInfo.remaining,
                        rateLimitReset: rateInfo.reset,
                        retryAfter: rateInfo.retryAfter
                    )
                }
            }
            .catch { error -> AnyPublisher<RedditCommentFetchResult, Never> in
                let statusCode: Int?
                if let serviceError = error as? RedditServiceError {
                    statusCode = serviceError.statusCode
                    print("❌ RedditService: Error fetching comments: \(serviceError.errorDescription ?? serviceError.localizedDescription)")
                } else if let urlError = error as? URLError {
                    statusCode = nil
                    print("❌ RedditService: Network error fetching comments: \(urlError.localizedDescription)")
                } else {
                    statusCode = nil
                    print("❌ RedditService: Unexpected error fetching comments: \(error.localizedDescription)")
                }

                return Just(RedditCommentFetchResult(
                    comments: [],
                    error: error,
                    httpStatusCode: statusCode,
                    wasCacheHit: false,
                    rateLimitRemaining: nil,
                    rateLimitReset: nil,
                    retryAfter: nil
                )).eraseToAnyPublisher()
            }
            .eraseToAnyPublisher()
    }

    private func decodeCommentsResponse(data: Data, depth: Int) throws -> [RedditCommentModel] {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              json.count > 1,
              let postData = json[0] as? [String: Any],
              let postDataChildren = (postData["data"] as? [String: Any])?["children"] as? [[String: Any]],
              let firstPost = postDataChildren.first?["data"] as? [String: Any],
              let postId = firstPost["id"] as? String else {
            print("⚠️ RedditService: Failed to parse JSON response")
            throw RedditServiceError.parsingFailed(reason: "Unexpected JSON structure")
        }

        linkId = "t3_\(postId)"

        let dataDict = json[1]["data"] as? [String: Any]
        let commentsArray = dataDict?["children"] as? [[String: Any]] ?? []

        print("📝 RedditService: Found \(commentsArray.count) top-level comments")

        do {
            let comments = try parseCommentsEfficiently(commentsArray, maxDepth: depth)
            print("✅ RedditService: Parsed and processed \(comments.count) comments total")
            return comments
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            print("❌ RedditService: Failed to parse comments efficiently: \(message)")
            throw RedditServiceError.parsingFailed(reason: message)
        }
    }
    
    private func extractRateLimitInfo(from response: HTTPURLResponse) -> (remaining: Double?, reset: Double?, retryAfter: Double?) {
        let remaining = response.value(forHTTPHeaderField: "X-Ratelimit-Remaining").flatMap { Double($0) }
        let reset = response.value(forHTTPHeaderField: "X-Ratelimit-Reset").flatMap { Double($0) }
        
        var retryAfter: Double? = nil
        if let header = response.value(forHTTPHeaderField: "Retry-After") {
            if let seconds = Double(header) {
                retryAfter = seconds
            } else {
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.timeZone = TimeZone(secondsFromGMT: 0)
                formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss zzz"
                if let date = formatter.date(from: header) {
                    retryAfter = max(0, date.timeIntervalSinceNow)
                }
            }
        }
        
        return (remaining, reset, retryAfter)
    }
    
    private func formatCooldownDuration(_ seconds: Double) -> String {
        let clampedSeconds = max(0, Int(ceil(seconds)))
        let hours = clampedSeconds / 3600
        let minutes = (clampedSeconds % 3600) / 60
        let secs = clampedSeconds % 60
        
        var components: [String] = []
        if hours > 0 { components.append("\(hours)h") }
        if minutes > 0 { components.append("\(minutes)m") }
        if secs > 0 || components.isEmpty { components.append("\(secs)s") }
        return components.joined(separator: " ")
    }
    
    private func buildCooldownMessage(seconds: Double) -> String {
        let duration = formatCooldownDuration(seconds)
        let readyDate = Date().addingTimeInterval(seconds)
        let timeString = DateFormatter.localizedString(from: readyDate, dateStyle: .none, timeStyle: .short)
        return "Reddit is rate limiting requests. Next refresh available in \(duration) (~\(timeString))."
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
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        addAuthHeaders(to: &request) // Use OAuth headers if available
        
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
