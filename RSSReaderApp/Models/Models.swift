//
//  Models.swift
//  RSSReader


import Foundation

// MARK: - App Settings

struct AppSettings: Codable {
    var refreshInterval: TimeInterval = 300 // 5 minutes
    var showUnreadOnly: Bool = false
    var markReadOnScroll: Bool = true
    var geminiApiKey: String = ""
    var openaiApiKey: String = ""
    var defaultFeedView: FeedViewType = .list
    var selectedTTSProvider: String = "OpenAI" // Default to OpenAI for Cloud TTS
    var selectedGeminiVoice: String = "Puck" // Default voice
    var selectedOpenAIVoice: String = "alloy" // Default voice
    var selectedSummaryProvider: SummaryProvider = .appleCloud // Default to Apple Cloud
    var selectedWebAIProvider: WebAIProvider = .chatgpt
    var summarizeDaemonToken: String = ""
    var summarizeBridgeSecret: String = ""
    var summarizeDaemonHost: String = "127.0.0.1"
    var summarizeDaemonPort: Int = 8787
    var summarizeDaemonModel: String = AppSettings.defaultSummarizeDaemonModel
    var summarizeBridgeHost: String = "127.0.0.1"
    var summarizeBridgePort: Int = AppSettings.defaultSummarizeBridgePort
    var pccGatewayHost: String = AppSettings.defaultPCCGatewayHost
    var pccGatewayPort: Int = AppSettings.defaultPCCGatewayPort
    var pccGatewayToken: String = ""
    var pccGatewayModel: String = AppSettings.defaultPCCGatewayModel
    var localTTSEngine: LocalTTSEngine = .system
    var kokoroVoice: String = KokoroVoice.defaultVoice.rawValue
    var kokoroSpeed: Double = 1.0
    var kokoroPrecacheEnabled: Bool = false
    /// Experimental YouTube integration is opt-in so existing installations
    /// retain their exact RSS/Reddit UI and refresh behavior by default.
    var youtubeSupportEnabled: Bool = false

    // Reddit OAuth fields
    var redditClientId: String = ""
    var redditAccessToken: String = ""
    var redditRefreshToken: String = ""
    var redditTokenExpiry: Date? = nil
    var redditUsername: String = ""
    var redditGrantedScopes: String = ""

    enum FeedViewType: String, Codable {
        case list, compact, magazine
    }
    
    enum SummaryProvider: String, Codable, CaseIterable {
        case gemini = "Gemini"
        case appleLocal = "Apple Local"
        case appleCloud = "Apple Cloud"
        case applePCCGateway = "Apple PCC Gateway"
        case mlxLocal = "MLX Local"
        case coreAIMLXLocal = "CoreAI MLX Local"
        case webAI = "Web AI"
        case summarizeDaemon = "Codex / Summarize"

        var displayName: String {
            switch self {
            case .mlxLocal:
                return "LiteRT Local"
            case .coreAIMLXLocal:
                return "CoreAI MLX Local"
            default:
                return self.rawValue
            }
        }
    }

    // LiteRT Local settings. The setting key keeps the old MLX name for migration.
    var mlxModelID: String = LiteRTLocalService.defaultModelRepo
    var mlxMaxOutputTokens: Int = 256
    var mlxMaxContextTokens: Int = 0

    // CoreAI MLX Local settings.
    var coreAIMLXModelID: String = CoreAIMLXLocalService.defaultModelRepo
    var coreAIMLXMaxOutputTokens: Int = 256
    var coreAIMLXMaxContextTokens: Int = 0

    static let defaultSummarizeDaemonModel = "gpt-fast"
    static let defaultSummarizeBridgePort = 8790
    static let defaultPCCGatewayPort = 1977
    static let defaultPCCGatewayModel = "pcc"
    #if os(macOS)
    static let defaultPCCGatewayHost = "127.0.0.1"
    #else
    static let defaultPCCGatewayHost = ""
    #endif

    static func normalizedSummarizeDaemonModel(_ rawValue: String) -> String {
        let model = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else { return defaultSummarizeDaemonModel }

        switch model.lowercased() {
        case "cli/codex/gpt-fast", "cli/codex/gpt-5.5", "cli/codex/gpt-5-5", "gpt-5.5", "gpt-5-5":
            return defaultSummarizeDaemonModel
        default:
            return model
        }
    }

    static func sanitizedSummarizeSecret(_ rawValue: String) -> String {
        var value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.lowercased().hasPrefix("bearer ") {
            value = String(value.dropFirst(7)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return value
    }

    static func sanitizedSummarizeHost(_ rawValue: String, fallback: String = "127.0.0.1") -> String {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? fallback : value
    }

    static func sanitizedSummarizePort(_ rawValue: Int, fallback: Int) -> Int {
        (1...65_535).contains(rawValue) ? rawValue : fallback
    }

    static func normalizedPCCGatewayModel(_ rawValue: String) -> String {
        let model = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return model.isEmpty ? defaultPCCGatewayModel : model
    }

    static func normalizedLiteRTContextTokens(_ rawValue: Int) -> Int {
        guard rawValue > 0 else { return 0 }
        return min(max(LiteRTLocalService.defaultContextTokens, rawValue), LiteRTLocalService.maxContextTokens)
    }

    static func normalizedCoreAIMLXContextTokens(_ rawValue: Int) -> Int {
        guard rawValue > 0 else { return 0 }
        return min(max(CoreAIMLXLocalService.defaultContextTokens, rawValue), CoreAIMLXLocalService.maxContextTokens)
    }

    static func effectiveLiteRTContextTokens(_ rawValue: Int) -> Int {
        let normalized = normalizedLiteRTContextTokens(rawValue)
        return normalized > 0 ? normalized : LiteRTLocalService.defaultContextTokens
    }

    static func effectiveCoreAIMLXContextTokens(_ rawValue: Int) -> Int {
        let normalized = normalizedCoreAIMLXContextTokens(rawValue)
        return normalized > 0 ? normalized : CoreAIMLXLocalService.defaultContextTokens
    }

    static func normalizedLiteRTOutputTokens(_ rawValue: Int, contextTokens: Int) -> Int {
        normalizedLocalOutputTokens(rawValue, contextTokens: contextTokens, hardCap: 4096)
    }

    static func normalizedCoreAIMLXOutputTokens(_ rawValue: Int, contextTokens: Int) -> Int {
        normalizedLocalOutputTokens(rawValue, contextTokens: contextTokens, hardCap: 512)
    }

    private static func normalizedLocalOutputTokens(_ rawValue: Int, contextTokens: Int, hardCap: Int) -> Int {
        let reservedInputBudget = max(256, contextTokens / 4)
        let maxAllowed = max(64, min(hardCap, contextTokens - reservedInputBudget))
        let bounded = min(max(64, rawValue), hardCap)
        return bounded <= maxAllowed ? bounded : min(256, maxAllowed)
    }

    enum CodingKeys: String, CodingKey {
        case refreshInterval
        case showUnreadOnly
        case markReadOnScroll
        case geminiApiKey
        case openaiApiKey
        case defaultFeedView
        case selectedTTSProvider
        case selectedGeminiVoice
        case selectedOpenAIVoice
        case selectedSummaryProvider
        case selectedWebAIProvider
        case summarizeDaemonToken
        case summarizeBridgeSecret
        case summarizeDaemonHost
        case summarizeDaemonPort
        case summarizeDaemonModel
        case summarizeBridgeHost
        case summarizeBridgePort
        case pccGatewayHost
        case pccGatewayPort
        case pccGatewayToken
        case pccGatewayModel
        case localTTSEngine
        case kokoroVoice
        case kokoroSpeed
        case kokoroPrecacheEnabled
        case youtubeSupportEnabled
        case redditClientId
        case redditAccessToken
        case redditRefreshToken
        case redditTokenExpiry
        case redditUsername
        case redditGrantedScopes
        case mlxModelID
        case mlxMaxOutputTokens
        case mlxMaxContextTokens
        case coreAIMLXModelID
        case coreAIMLXMaxOutputTokens
        case coreAIMLXMaxContextTokens
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        refreshInterval = try container.decodeIfPresent(TimeInterval.self, forKey: .refreshInterval) ?? 300
        showUnreadOnly = try container.decodeIfPresent(Bool.self, forKey: .showUnreadOnly) ?? false
        markReadOnScroll = try container.decodeIfPresent(Bool.self, forKey: .markReadOnScroll) ?? true
        geminiApiKey = try container.decodeIfPresent(String.self, forKey: .geminiApiKey) ?? ""
        openaiApiKey = try container.decodeIfPresent(String.self, forKey: .openaiApiKey) ?? ""
        defaultFeedView = try container.decodeIfPresent(FeedViewType.self, forKey: .defaultFeedView) ?? .list
        selectedTTSProvider = try container.decodeIfPresent(String.self, forKey: .selectedTTSProvider) ?? "OpenAI"
        selectedGeminiVoice = try container.decodeIfPresent(String.self, forKey: .selectedGeminiVoice) ?? "Puck"
        selectedOpenAIVoice = try container.decodeIfPresent(String.self, forKey: .selectedOpenAIVoice) ?? "alloy"
        selectedSummaryProvider = try container.decodeIfPresent(SummaryProvider.self, forKey: .selectedSummaryProvider) ?? .appleCloud
        selectedWebAIProvider = try container.decodeIfPresent(WebAIProvider.self, forKey: .selectedWebAIProvider) ?? .chatgpt
        summarizeDaemonToken = AppSettings.sanitizedSummarizeSecret(try container.decodeIfPresent(String.self, forKey: .summarizeDaemonToken) ?? "")
        summarizeBridgeSecret = AppSettings.sanitizedSummarizeSecret(try container.decodeIfPresent(String.self, forKey: .summarizeBridgeSecret) ?? "")
        summarizeDaemonHost = AppSettings.sanitizedSummarizeHost(try container.decodeIfPresent(String.self, forKey: .summarizeDaemonHost) ?? "127.0.0.1")
        summarizeDaemonPort = AppSettings.sanitizedSummarizePort(try container.decodeIfPresent(Int.self, forKey: .summarizeDaemonPort) ?? 8787, fallback: 8787)
        summarizeDaemonModel = AppSettings.normalizedSummarizeDaemonModel(try container.decodeIfPresent(String.self, forKey: .summarizeDaemonModel) ?? AppSettings.defaultSummarizeDaemonModel)
        summarizeBridgeHost = AppSettings.sanitizedSummarizeHost(try container.decodeIfPresent(String.self, forKey: .summarizeBridgeHost) ?? "127.0.0.1")
        summarizeBridgePort = AppSettings.sanitizedSummarizePort(try container.decodeIfPresent(Int.self, forKey: .summarizeBridgePort) ?? AppSettings.defaultSummarizeBridgePort, fallback: AppSettings.defaultSummarizeBridgePort)
        pccGatewayHost = AppSettings.sanitizedSummarizeHost(try container.decodeIfPresent(String.self, forKey: .pccGatewayHost) ?? AppSettings.defaultPCCGatewayHost, fallback: AppSettings.defaultPCCGatewayHost)
        pccGatewayPort = AppSettings.sanitizedSummarizePort(try container.decodeIfPresent(Int.self, forKey: .pccGatewayPort) ?? AppSettings.defaultPCCGatewayPort, fallback: AppSettings.defaultPCCGatewayPort)
        pccGatewayToken = AppSettings.sanitizedSummarizeSecret(try container.decodeIfPresent(String.self, forKey: .pccGatewayToken) ?? "")
        pccGatewayModel = AppSettings.normalizedPCCGatewayModel(try container.decodeIfPresent(String.self, forKey: .pccGatewayModel) ?? AppSettings.defaultPCCGatewayModel)
        localTTSEngine = try container.decodeIfPresent(LocalTTSEngine.self, forKey: .localTTSEngine) ?? .system
        kokoroVoice = try container.decodeIfPresent(String.self, forKey: .kokoroVoice) ?? KokoroVoice.defaultVoice.rawValue
        kokoroSpeed = try container.decodeIfPresent(Double.self, forKey: .kokoroSpeed) ?? 1.0
        kokoroPrecacheEnabled = try container.decodeIfPresent(Bool.self, forKey: .kokoroPrecacheEnabled) ?? false
        youtubeSupportEnabled = try container.decodeIfPresent(Bool.self, forKey: .youtubeSupportEnabled) ?? false
        redditClientId = try container.decodeIfPresent(String.self, forKey: .redditClientId) ?? ""
        redditAccessToken = try container.decodeIfPresent(String.self, forKey: .redditAccessToken) ?? ""
        redditRefreshToken = try container.decodeIfPresent(String.self, forKey: .redditRefreshToken) ?? ""
        redditTokenExpiry = try container.decodeIfPresent(Date.self, forKey: .redditTokenExpiry)
        redditUsername = try container.decodeIfPresent(String.self, forKey: .redditUsername) ?? ""
        redditGrantedScopes = try container.decodeIfPresent(String.self, forKey: .redditGrantedScopes) ?? ""
        mlxModelID = LiteRTLocalService.normalizedModelID(try container.decodeIfPresent(String.self, forKey: .mlxModelID) ?? LiteRTLocalService.defaultModelRepo)
        mlxMaxContextTokens = AppSettings.normalizedLiteRTContextTokens(try container.decodeIfPresent(Int.self, forKey: .mlxMaxContextTokens) ?? 0)
        mlxMaxOutputTokens = AppSettings.normalizedLiteRTOutputTokens(
            try container.decodeIfPresent(Int.self, forKey: .mlxMaxOutputTokens) ?? 256,
            contextTokens: AppSettings.effectiveLiteRTContextTokens(mlxMaxContextTokens)
        )
        coreAIMLXModelID = CoreAIMLXLocalService.normalizedModelID(try container.decodeIfPresent(String.self, forKey: .coreAIMLXModelID) ?? CoreAIMLXLocalService.defaultModelRepo)
        coreAIMLXMaxContextTokens = AppSettings.normalizedCoreAIMLXContextTokens(try container.decodeIfPresent(Int.self, forKey: .coreAIMLXMaxContextTokens) ?? 0)
        coreAIMLXMaxOutputTokens = AppSettings.normalizedCoreAIMLXOutputTokens(
            try container.decodeIfPresent(Int.self, forKey: .coreAIMLXMaxOutputTokens) ?? 256,
            contextTokens: AppSettings.effectiveCoreAIMLXContextTokens(coreAIMLXMaxContextTokens)
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(refreshInterval, forKey: .refreshInterval)
        try container.encode(showUnreadOnly, forKey: .showUnreadOnly)
        try container.encode(markReadOnScroll, forKey: .markReadOnScroll)
        try container.encode(geminiApiKey, forKey: .geminiApiKey)
        try container.encode(openaiApiKey, forKey: .openaiApiKey)
        try container.encode(defaultFeedView, forKey: .defaultFeedView)
        try container.encode(selectedTTSProvider, forKey: .selectedTTSProvider)
        try container.encode(selectedGeminiVoice, forKey: .selectedGeminiVoice)
        try container.encode(selectedOpenAIVoice, forKey: .selectedOpenAIVoice)
        try container.encode(selectedSummaryProvider, forKey: .selectedSummaryProvider)
        try container.encode(selectedWebAIProvider, forKey: .selectedWebAIProvider)
        try container.encode(summarizeDaemonHost, forKey: .summarizeDaemonHost)
        try container.encode(summarizeDaemonPort, forKey: .summarizeDaemonPort)
        try container.encode(summarizeDaemonModel, forKey: .summarizeDaemonModel)
        try container.encode(summarizeBridgeHost, forKey: .summarizeBridgeHost)
        try container.encode(summarizeBridgePort, forKey: .summarizeBridgePort)
        try container.encode(pccGatewayHost, forKey: .pccGatewayHost)
        try container.encode(pccGatewayPort, forKey: .pccGatewayPort)
        try container.encode(pccGatewayModel, forKey: .pccGatewayModel)
        try container.encode(localTTSEngine, forKey: .localTTSEngine)
        try container.encode(kokoroVoice, forKey: .kokoroVoice)
        try container.encode(kokoroSpeed, forKey: .kokoroSpeed)
        try container.encode(kokoroPrecacheEnabled, forKey: .kokoroPrecacheEnabled)
        try container.encode(youtubeSupportEnabled, forKey: .youtubeSupportEnabled)
        try container.encode(redditClientId, forKey: .redditClientId)
        try container.encode(redditAccessToken, forKey: .redditAccessToken)
        try container.encode(redditRefreshToken, forKey: .redditRefreshToken)
        try container.encodeIfPresent(redditTokenExpiry, forKey: .redditTokenExpiry)
        try container.encode(redditUsername, forKey: .redditUsername)
        try container.encode(redditGrantedScopes, forKey: .redditGrantedScopes)
        try container.encode(mlxModelID, forKey: .mlxModelID)
        try container.encode(mlxMaxOutputTokens, forKey: .mlxMaxOutputTokens)
        try container.encode(mlxMaxContextTokens, forKey: .mlxMaxContextTokens)
        try container.encode(coreAIMLXModelID, forKey: .coreAIMLXModelID)
        try container.encode(coreAIMLXMaxOutputTokens, forKey: .coreAIMLXMaxOutputTokens)
        try container.encode(coreAIMLXMaxContextTokens, forKey: .coreAIMLXMaxContextTokens)
    }
}

enum WebAIProvider: String, Codable, CaseIterable, Identifiable {
    case chatgpt
    case gemini

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .chatgpt:
            return "ChatGPT"
        case .gemini:
            return "Gemini"
        }
    }

    var url: URL {
        switch self {
        case .chatgpt:
            return URL(string: "https://chatgpt.com")!
        case .gemini:
            return URL(string: "https://gemini.google.com/app")!
        }
    }
}

enum LocalRerouteProvider: String, CaseIterable, Identifiable {
    case gemini
    case applePCCGateway
    case summarizeDaemon
    case appleCloud
    case webAI

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .gemini: return "Gemini"
        case .applePCCGateway: return "Apple PCC Gateway"
        case .summarizeDaemon: return "Codex / Summarize"
        case .appleCloud: return "Apple Cloud"
        case .webAI: return "Web AI"
        }
    }

    var summaryProvider: AppSettings.SummaryProvider {
        switch self {
        case .gemini: return .gemini
        case .applePCCGateway: return .applePCCGateway
        case .summarizeDaemon: return .summarizeDaemon
        case .appleCloud: return .appleCloud
        case .webAI: return .webAI
        }
    }
}

enum WebAIResponseFormat: String, Equatable {
    case plainText
    case strictJSON
}

struct WebAIHandoffRequest: Identifiable, Equatable {
    let id = UUID()
    let provider: WebAIProvider
    let title: String
    let prompt: String
    let responseFormat: WebAIResponseFormat
    let shouldAutoCapture: Bool
    let shouldStartMinimized: Bool
}

// MARK: - Comment Summary

struct CommentSummary: Identifiable, Codable {
    let id = UUID()
    let postId: String
    let subreddit: String
    let summary: String
    let commentCount: Int
    let topCommenters: [String]
    let mainTopics: [String]
    let sentiment: CommentSentiment
    let createdDate: Date

    enum CommentSentiment: String, Codable {
        case positive, negative, neutral, mixed
    }
}

// MARK: - Feed Category

enum FeedCategory: String, CaseIterable, Identifiable {
    case all = "All"
    case unread = "Unread"
    case favorites = "Favorites"
    case today = "Today"
    case reddit = "Reddit"
    
    var id: String { self.rawValue }
    
    var systemImageName: String {
        switch self {
        case .all: return "list.bullet"
        case .unread: return "envelope"
        case .favorites: return "star.fill"
        case .today: return "calendar"
        case .reddit: return "circle.fill"
        }
    }
}

// MARK: - Subscription

enum SubscriptionType: String, Codable {
    case rss, reddit
}

struct Subscription: Identifiable, Codable, Equatable {
    let id: UUID
    let title: String
    let url: String
    let type: SubscriptionType

    init(id: UUID = UUID(), title: String, url: String, type: SubscriptionType) {
        self.id = id
        self.title = title
        self.url = url
        self.type = type
    }

    static func == (lhs: Subscription, rhs: Subscription) -> Bool {
        // Treat subscriptions with the same URL and type as identical across devices
        return lhs.url == rhs.url && lhs.type == rhs.type
    }
}

extension Subscription {
    static func canonicalURL(_ url: String, type: SubscriptionType) -> String {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }

        switch type {
        case .reddit:
            if let parsed = URL(string: trimmed),
               let host = parsed.host?.lowercased(),
               host.contains("reddit.com") {
                let components = parsed.pathComponents
                if let rIndex = components.firstIndex(where: { $0.lowercased() == "r" }),
                   components.count > rIndex + 1 {
                    return components[rIndex + 1].lowercased()
                }
            }

            var value = trimmed
            let lower = value.lowercased()
            if lower.hasPrefix("/r/") {
                value = String(value.dropFirst(3))
            } else if lower.hasPrefix("r/") {
                value = String(value.dropFirst(2))
            }
            value = value.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return value.lowercased()

        case .rss:
            guard var components = URLComponents(string: trimmed) else {
                return trimmed
            }

            components.fragment = nil
            components.scheme = components.scheme?.lowercased()
            components.host = components.host?.lowercased()

            return components.string ?? trimmed
        }
    }

    var canonicalKey: String {
        "\(type.rawValue)|\(Subscription.canonicalURL(url, type: type))"
    }

    /// YouTube channels remain encoded as ordinary RSS subscriptions. This is
    /// deliberately computed from the canonical Atom URL so older app builds
    /// can still decode the subscription array.
    var isYouTubeChannel: Bool {
        guard type == .rss,
              let components = URLComponents(string: url),
              let host = components.host?.lowercased(),
              host == "youtube.com" || host == "www.youtube.com",
              components.path == "/feeds/videos.xml" else {
            return false
        }

        return youtubeChannelID != nil
    }

    var youtubeChannelID: String? {
        guard type == .rss,
              let components = URLComponents(string: url),
              let host = components.host?.lowercased(),
              host == "youtube.com" || host == "www.youtube.com",
              components.path == "/feeds/videos.xml" else {
            return nil
        }

        return components.queryItems?
            .first(where: { $0.name == "channel_id" })?
            .value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
    }
}

// MARK: - Feed

struct Feed: Identifiable {
    let id = UUID()
    let title: String
    let url: String
    let description: String?
    let imageURL: URL?
    var articles: [Article]
    
    init(title: String, url: String, description: String? = nil, imageURL: URL? = nil, articles: [Article] = []) {
        self.title = title
        self.url = url
        self.description = description
        self.imageURL = imageURL
        self.articles = articles
    }
}

// MARK: - Article

struct Article: Identifiable {
    let id: String
    let title: String
    var content: String
    var previewText: String
    let url: URL?
    let publishDate: Date
    let author: String?
    let feedTitle: String
    let feedURL: String
    let imageURL: URL?
    var isRead: Bool
    var isFavorite: Bool
    var summary: String?
    var faviconURL: URL?
    var domainIcon: String?
    
    init(id: String,
         title: String,
         content: String,
         previewText: String? = nil,
         url: URL?,
         publishDate: Date,
         author: String? = nil,
         feedTitle: String,
         feedURL: String,
         imageURL: URL? = nil,
         isRead: Bool = false,
         isFavorite: Bool = false,
         summary: String? = nil) {
        self.id = id
        self.title = title
        self.content = content
        self.previewText = previewText ?? Self.makePreviewText(from: content)
        self.url = url
        self.publishDate = publishDate
        self.author = author
        self.feedTitle = feedTitle
        self.feedURL = feedURL
        self.imageURL = imageURL
        self.isRead = isRead
        self.isFavorite = isFavorite
        self.summary = summary
    }

    static func makePreviewText(from content: String) -> String {
        var cleaned = content
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&[^;]+;", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if cleaned.count > 140 {
            cleaned = String(cleaned.prefix(140)) + "..."
        }

        return cleaned
    }
}

extension Article {
    var youtubeVideoID: String? {
        if id.hasPrefix("youtube:") {
            let value = String(id.dropFirst("youtube:".count))
            return value.isEmpty ? nil : value
        }

        guard let url,
              let host = url.host?.lowercased() else {
            return nil
        }

        if host == "youtu.be" {
            return url.pathComponents.dropFirst().first?.nilIfEmpty
        }

        guard host == "youtube.com" || host == "www.youtube.com" || host == "m.youtube.com" else {
            return nil
        }

        if url.path == "/watch" {
            return URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?
                .first(where: { $0.name == "v" })?
                .value?
                .nilIfEmpty
        }

        let components = url.pathComponents.filter { $0 != "/" }
        if let marker = components.firstIndex(where: { ["shorts", "live", "embed"].contains($0.lowercased()) }),
           components.indices.contains(marker + 1) {
            return components[marker + 1].nilIfEmpty
        }

        return nil
    }

    var isYouTubeVideo: Bool { youtubeVideoID != nil }
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

// MARK: - Reddit Feed

struct RedditFeed: Identifiable {
    let id = UUID()
    let subreddit: String
    let displayName: String
    let description: String?
    let iconURL: URL?
    var posts: [RedditPost]
    var lastFetchStatusCode: Int?
    var fetchStatusMessage: String?
    var rateLimitCooldownUntil: Date?
    
    init(subreddit: String,
         displayName: String,
         description: String? = nil,
         iconURL: URL? = nil,
         posts: [RedditPost] = [],
         lastFetchStatusCode: Int? = nil,
         fetchStatusMessage: String? = nil,
         rateLimitCooldownUntil: Date? = nil) {
        self.subreddit = subreddit
        self.displayName = displayName
        self.description = description
        self.iconURL = iconURL
        self.posts = posts
        self.lastFetchStatusCode = lastFetchStatusCode
        self.fetchStatusMessage = fetchStatusMessage
        self.rateLimitCooldownUntil = rateLimitCooldownUntil
    }
}

// MARK: - Additional Reddit Structures

// For preview images
struct Preview: Codable {
    let images: [PreviewImage]
    let enabled: Bool?
}

struct PreviewImage: Codable {
    let source: PreviewSource
    let resolutions: [PreviewSource]
}

struct PreviewSource: Codable {
    let url: String
    let width: Int
    let height: Int
}

// For gallery and multi-image posts
struct MediaMetadata: Codable {
    let status: String
    let e: String
    let m: String?
    let p: [MediaImage]?
    let s: MediaImage?
    let id: String
}

struct MediaImage: Codable {
    let u: String?
    let x: Int?
    let y: Int?
}

struct GalleryData: Codable {
    let items: [GalleryItem]
}

struct GalleryItem: Codable {
    let media_id: String
    let id: Int
}

// MARK: - Reddit Post

struct RedditPost: Identifiable {
    let id: String
    let title: String
    var content: String
    let url: URL?
    let resolvedImageURL: URL?
    let publishDate: Date
    let author: String
    let subreddit: String
    let score: Int
    let commentCount: Int
    var isRead: Bool
    var isFavorite: Bool
    var isStickied: Bool
    var summary: String?
    let thumbnail: String?
    
    // Fields for improved image handling
    let preview: Preview?
    let media_metadata: [String: MediaMetadata]?
    let gallery_data: GalleryData?
    
    init(id: String,
         title: String,
         content: String,
         url: URL?,
         resolvedImageURL: URL? = nil,
         publishDate: Date,
         author: String,
         subreddit: String,
         score: Int,
         commentCount: Int,
         isRead: Bool = false,
         isFavorite: Bool = false,
         isStickied: Bool = false,
         summary: String? = nil,
         thumbnail: String? = nil,
         preview: Preview? = nil,
         media_metadata: [String: MediaMetadata]? = nil,
         gallery_data: GalleryData? = nil) {
        self.id = id
        self.title = title
        self.content = content
        self.url = url
        self.resolvedImageURL = resolvedImageURL ?? resolveBestRedditImageURL(
            content: content,
            url: url,
            thumbnail: thumbnail,
            preview: preview,
            mediaMetadata: media_metadata,
            galleryData: gallery_data
        )
        self.publishDate = publishDate
        self.author = author
        self.subreddit = subreddit
        self.score = score
        self.commentCount = commentCount
        self.isRead = isRead
        self.isFavorite = isFavorite
        self.isStickied = isStickied
        self.summary = summary
        self.thumbnail = thumbnail
        self.preview = preview
        self.media_metadata = media_metadata
        self.gallery_data = gallery_data
    }
}

// MARK: - Fallback Regex for Inline Image in Post Content

/// Searches the given text for a `.jpg/.jpeg/.png/.gif/.webp` link (with optional query parameters)
private func parseFirstImageURL(in text: String) -> URL? {
    let pattern = #"(?i)(https?://\S+\.(?:jpg|jpeg|png|gif|webp)(\?\S+)?)"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else {
        return nil
    }
    let range = NSRange(text.startIndex..., in: text)
    if let match = regex.firstMatch(in: text, options: [], range: range),
       let matchRange = Range(match.range, in: text) {
        let urlString = String(text[matchRange])
            .replacingOccurrences(of: "&amp;", with: "&")
        return URL(string: urlString)
    }
    return nil
}

private func decodedRedditMediaURL(from value: String?) -> URL? {
    guard let value, !value.isEmpty else { return nil }
    let decoded = value
        .replacingOccurrences(of: "&amp;", with: "&")
        .replacingOccurrences(of: "amp;", with: "")
    return URL(string: decoded)
}

private func decodedThumbnailURL(from thumbnail: String?) -> URL? {
    guard let thumbnail,
          !thumbnail.isEmpty,
          thumbnail != "self",
          thumbnail != "default",
          thumbnail != "nsfw",
          thumbnail != "spoiler" else {
        return nil
    }

    let decoded = thumbnail
        .replacingOccurrences(of: "&amp;", with: "&")
        .replacingOccurrences(of: "&lt;", with: "<")
        .replacingOccurrences(of: "&gt;", with: ">")
        .replacingOccurrences(of: "&quot;", with: "\"")
        .replacingOccurrences(of: "&#39;", with: "'")
        .replacingOccurrences(of: "&nbsp;", with: " ")

    return URL(string: decoded)
}

private func resolveBestRedditImageURL(
    content: String,
    url: URL?,
    thumbnail: String?,
    preview: Preview?,
    mediaMetadata: [String: MediaMetadata]?,
    galleryData: GalleryData?
) -> URL? {
    if let gallery = galleryData, let mediaMetadata {
        for item in gallery.items {
            guard let mediaItem = mediaMetadata[item.media_id], mediaItem.status == "valid" else {
                continue
            }

            if let fullURL = decodedRedditMediaURL(from: mediaItem.s?.u) {
                return fullURL
            }

            if let bestResolution = mediaItem.p?.first(where: {
                guard let width = $0.x, let height = $0.y else { return false }
                return width > 320 && height > 240
            }), let resolutionURL = decodedRedditMediaURL(from: bestResolution.u) {
                return resolutionURL
            }
        }
    }

    if let postURL = url, postURL.absoluteString.contains("v.redd.it"),
       let thumbURL = decodedThumbnailURL(from: thumbnail) {
        return thumbURL
    }

    if let postURL = url {
        let urlString = postURL.absoluteString.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercasedURL = urlString.lowercased()
        let pathExtension = postURL.pathExtension.lowercased()
        let validExtensions = ["jpg", "jpeg", "png", "gif", "webp"]
        let isKnownImageHost =
            urlString.contains("i.redd.it") ||
            urlString.contains("i.imgur.com") ||
            urlString.contains("gfycat.com") ||
            urlString.contains("cdn.discordapp.com") ||
            urlString.contains("media.discordapp.net")

        if isKnownImageHost || validExtensions.contains(pathExtension) {
            return postURL
        }

        if validExtensions.contains(where: { lowercasedURL.hasSuffix(".\($0)") }) {
            return postURL
        }

        if urlString.contains("imgur.com/"),
           !urlString.contains("i.imgur.com"),
           !urlString.contains("/gallery/"),
           !urlString.contains("/a/"),
           let imgurID = urlString.split(separator: "/").last {
            return URL(string: "https://i.imgur.com/\(imgurID).jpg")
        }
    }

    if let preview, let firstImage = preview.images.first {
        if let sourceURL = decodedRedditMediaURL(from: firstImage.source.url) {
            return sourceURL
        }

        if let bestResolution = firstImage.resolutions.last(where: { $0.width > 320 && $0.height > 240 }),
           let resolutionURL = decodedRedditMediaURL(from: bestResolution.url) {
            return resolutionURL
        }
    }

    if let urlString = url?.absoluteString,
       urlString.contains("reddit.com/media"),
       let components = URLComponents(string: urlString),
       let actualItem = components.queryItems?.first(where: { $0.name == "url" }),
       let decodedURLString = actualItem.value?.removingPercentEncoding,
       let actualURL = URL(string: decodedURLString) {
        return actualURL
    }

    if let inlineURL = parseFirstImageURL(in: content) {
        return inlineURL
    }

    return decodedThumbnailURL(from: thumbnail)
}

// MARK: - RedditPost Computed Properties

extension RedditPost {
    /// Returns the best available image URL using multiple sources.
    var bestImageURL: URL? {
        resolvedImageURL
    }

    var allImageURLs: [URL] {
        var urls = [URL]()
        if let resolvedImageURL {
            urls.append(resolvedImageURL)
        }
        // 1) From preview - try to get highest resolution versions.
        if let preview = preview, let firstImage = preview.images.first {
            // Add source (full resolution) first
            let sourceURLString = firstImage.source.url.replacingOccurrences(of: "&amp;", with: "&")
            if let url = URL(string: sourceURLString) {
                urls.append(url)
            }
            // Add high resolution alternatives (skip low-res versions)
            for resolution in firstImage.resolutions.reversed() {
                let resURLString = resolution.url.replacingOccurrences(of: "&amp;", with: "&")
                if let url = URL(string: resURLString), 
                   !urls.contains(url),
                   resolution.width > 320 { // Only include resolutions wider than 320px
                    urls.append(url)
                }
            }
        }
        // 2) From gallery (gallery_data + media_metadata).
        if let gallery = gallery_data, let media = media_metadata {
            for item in gallery.items {
                if let mediaItem = media[item.media_id],
                   mediaItem.status == "valid",
                   let urlString = mediaItem.s?.u?.replacingOccurrences(of: "&amp;", with: "&"),
                   let url = URL(string: urlString),
                   !urls.contains(url) { // Avoid duplicates
                    urls.append(url)
                }
            }
        }
        // 3) Direct URL if it points to an image.
        if let urlString = url?.absoluteString.lowercased(),
           (urlString.hasSuffix(".jpg") ||
            urlString.hasSuffix(".jpeg") ||
            urlString.hasSuffix(".png") ||
            urlString.hasSuffix(".gif") ||
            urlString.hasSuffix(".webp")),
           let validUrl = url,
           !urls.contains(validUrl) {
            urls.append(validUrl)
        }
        // 3.5) If the direct URL is a reddit.com/media link, extract the image.
        if let urlString = url?.absoluteString,
           urlString.contains("reddit.com/media"),
           let components = URLComponents(string: urlString),
           let queryItems = components.queryItems,
           let actualItem = queryItems.first(where: { $0.name == "url" }),
           let encodedUrlString = actualItem.value,
           let decodedUrlString = encodedUrlString.removingPercentEncoding,
           let actualUrl = URL(string: decodedUrlString),
           !urls.contains(actualUrl) {
            urls.append(actualUrl)
        }
        // 4) Parse the post's content for inline images BEFORE thumbnails.
        if let inlineImageURL = parseFirstImageURL(in: content),
           !urls.contains(inlineImageURL) {
            urls.append(inlineImageURL)
        }
        // 5) AVOID thumbnails in gallery - they are low quality and look terrible
        // Only include if we have no other images AND they're not Reddit's low-quality thumbnails
        if urls.isEmpty {
            if let thumb = thumbnail,
               !thumb.isEmpty,
               thumb != "self",
               thumb != "default",
               thumb != "nsfw",
               thumb != "spoiler",
               !thumb.contains("NSFW_") {
                
                let decodedThumb = thumb
                    .replacingOccurrences(of: "&amp;", with: "&")
                    .replacingOccurrences(of: "&lt;", with: "<")
                    .replacingOccurrences(of: "&gt;", with: ">")
                    .replacingOccurrences(of: "&quot;", with: "\"")
                    .replacingOccurrences(of: "&#39;", with: "'")
                    .replacingOccurrences(of: "&nbsp;", with: " ")
                
                // Skip Reddit's own low-quality thumbnails even in gallery
                if decodedThumb.contains("redd.it") && 
                   (decodedThumb.contains("://a.thumbs.redditmedia.com") || 
                    decodedThumb.contains("://b.thumbs.redditmedia.com") ||
                    decodedThumb.contains("external-preview.redd.it")) {
                } else if let thumbURL = URL(string: decodedThumb) {
                    urls.append(thumbURL)
                }
            }
        }
        return urls
    }
    
    /// Returns a cleaned preview text by stripping HTML tags and replacing image/link URLs.
    var cleanPreviewText: String {
        var cleaned = content
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "(?i)https?://[^\\s]+\\.(?:jpg|jpeg|png|gif|webp)(\\?[^\\s]+)?",
                                  with: "[IMAGE]",
                                  options: .regularExpression)
            .replacingOccurrences(of: "(?i)https?://[^\\s]+",
                                  with: "[LINK]",
                                  options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.count > 140 {
            cleaned = String(cleaned.prefix(140)) + "..."
        }
        return cleaned
    }
}

// MARK: - RedditCommentModel
// (Assume RedditCommentModel is defined in a separate file)

import SwiftUI // Add import for Color

// MARK: - Comment Analytics Models

enum SentimentType {
    case positive
    case neutral
    case negative

    var color: Color {
        switch self {
        case .positive: return .green
        case .neutral: return .gray // Using standard gray
        case .negative: return .red
        }
    }

    var description: String {
        switch self {
        case .positive: return "Positive"
        case .neutral: return "Neutral"
        case .negative: return "Negative"
        }
    }
}

struct CommentAnalytics {
    let totalComments: Int
    let sentimentCounts: (positive: Int, neutral: Int, negative: Int)
    let averageCommentLength: Int
    let uniqueAuthorsCount: Int
    let mostActiveAuthor: (name: String, count: Int)?
    let commentLengthDistribution: [String: Int] // e.g. "0-50": 5, "51-100": 10
    let highlyVotedComments: [RedditCommentModel] // Use the app's existing comment model
    let commentTopics: [String]

    var sentimentPercentages: (positive: Double, neutral: Double, negative: Double) {
        let total = Double(totalComments)
        guard total > 0 else { return (0, 0, 0) }

        return (
            positive: Double(sentimentCounts.positive) / total * 100.0,
            neutral: Double(sentimentCounts.neutral) / total * 100.0,
            negative: Double(sentimentCounts.negative) / total * 100.0
        )
    }

    // Helper function to determine the majority sentiment
    func getSentimentMajority() -> String {
        let percentages = self.sentimentPercentages
        if percentages.positive > percentages.neutral && percentages.positive > percentages.negative {
            return "mostly positive"
        } else if percentages.negative > percentages.neutral && percentages.negative > percentages.positive {
            return "mostly negative"
        } else if sentimentCounts.positive == 0 && sentimentCounts.neutral == 0 && sentimentCounts.negative == 0 {
             return "unavailable" // Handle case with no comments
        } else {
            return "mostly neutral"
        }
    }

    // Helper function to describe the most common comment length
     func getMostCommonLengthDescription() -> String {
         if let mostCommon = commentLengthDistribution.max(by: { $0.value < $1.value })?.key, mostCommon != "unknown", !commentLengthDistribution.values.filter({ $0 > 0 }).isEmpty {
             return "in the \(mostCommon) character range"
         } else if commentLengthDistribution.values.allSatisfy({ $0 == 0 }) {
             return "unavailable (no comments analyzed)"
         } else {
             return "of varying lengths"
         }
     }
}
