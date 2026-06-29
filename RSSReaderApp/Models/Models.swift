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

    // Reddit OAuth fields
    var redditClientId: String = ""
    var redditAccessToken: String = ""
    var redditRefreshToken: String = ""
    var redditTokenExpiry: Date? = nil
    var redditUsername: String = ""

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
            case .applePCCGateway:
                #if os(macOS)
                return "Apple PCC (fm CLI)"
                #else
                return self.rawValue
                #endif
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
    static let defaultPCCGatewayHost = "127.0.0.1"
    static let defaultPCCGatewayPort = 1977
    static let defaultPCCGatewayModel = "pcc"

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
        case redditClientId
        case redditAccessToken
        case redditRefreshToken
        case redditTokenExpiry
        case redditUsername
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
        redditClientId = try container.decodeIfPresent(String.self, forKey: .redditClientId) ?? ""
        redditAccessToken = try container.decodeIfPresent(String.self, forKey: .redditAccessToken) ?? ""
        redditRefreshToken = try container.decodeIfPresent(String.self, forKey: .redditRefreshToken) ?? ""
        redditTokenExpiry = try container.decodeIfPresent(Date.self, forKey: .redditTokenExpiry)
        redditUsername = try container.decodeIfPresent(String.self, forKey: .redditUsername) ?? ""
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
        case .applePCCGateway:
            #if os(macOS)
            return "Apple PCC (fm CLI)"
            #else
            return "Apple PCC Gateway"
            #endif
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

// MARK: - RedditPost Computed Properties

extension RedditPost {
    /// Returns the best available image URL using multiple sources.
    var bestImageURL: URL? {
        print("🔍 DEBUG: Finding best image URL for post '\(title.prefix(50))...'")
        print("  - post.url: \(url?.absoluteString ?? "nil")")
        print("  - has preview: \(preview != nil)")
        print("  - has gallery_data: \(gallery_data != nil)")
        print("  - has media_metadata: \(media_metadata != nil)")
        print("  - has thumbnail: \(thumbnail ?? "nil")")
        
        // 1) PRIORITY: Gallery posts with media_metadata (keep galleries working as they are)
        if let gallery = gallery_data, let media = media_metadata {
            print("  - Processing gallery with \(gallery.items.count) items")
            print("  - Media metadata keys: \(Array(media.keys))")
            
            for (index, item) in gallery.items.enumerated() {
                print("    - Gallery item \(index): media_id=\(item.media_id)")
                
                if let mediaItem = media[item.media_id] {
                    print("      - Found media item, status=\(mediaItem.status), type=\(mediaItem.e)")
                    print("      - Has full-res (s): \(mediaItem.s != nil)")
                    print("      - Has resolutions (p): \(mediaItem.p?.count ?? 0) versions")
                    
                    if mediaItem.status == "valid" {
                        // Try full resolution first
                        if let fullURLString = mediaItem.s?.u?.replacingOccurrences(of: "&amp;", with: "&"),
                           let fullURL = URL(string: fullURLString) {
                            print("✅ Using media_metadata full URL: \(fullURL)")
                            return fullURL
                        }
                        // Try high-res versions only (skip thumbnails)
                        if let resolutions = mediaItem.p {
                            print("        - Available resolutions: \(resolutions.map { "\($0.x ?? 0)x\($0.y ?? 0)" })")
                            let highResVersions = resolutions.filter { 
                                guard let width = $0.x, let height = $0.y else { return false }
                                return width > 320 && height > 240
                            }
                            print("        - High-res versions: \(highResVersions.count)")
                            if let firstHighRes = highResVersions.first,
                               let resURLString = firstHighRes.u?.replacingOccurrences(of: "&amp;", with: "&"),
                               let resURL = URL(string: resURLString) {
                                print("✅ Using media_metadata high-res URL (\(firstHighRes.x ?? 0)x\(firstHighRes.y ?? 0)): \(resURL)")
                                return resURL
                            }
                        }
                    } else {
                        print("      - Skipping invalid media item")
                    }
                } else {
                    print("      - No media item found for ID: \(item.media_id)")
                }
            }
            print("  - No valid images found in gallery metadata")
        } else {
            if gallery_data == nil { print("  - No gallery_data") }
            if media_metadata == nil { print("  - No media_metadata") }
        }
        
        // 2) For video posts (v.redd.it), use thumbnail directly (preview is often broken)
        if let postURL = url, postURL.absoluteString.contains("v.redd.it") {
            print("  - This is a video post (v.redd.it), using thumbnail instead of preview...")
            if let thumb = thumbnail,
               !thumb.isEmpty,
               thumb != "self",
               thumb != "default",
               thumb != "nsfw",
               thumb != "spoiler" {
                let decodedThumb = thumb
                    .replacingOccurrences(of: "&amp;", with: "&")
                if let thumbURL = URL(string: decodedThumb) {
                    print("✅ Using video thumbnail (preview often broken for videos): \(thumbURL)")
                    return thumbURL
                }
            }
        }
        
        // 3) Check if the post's url directly points to an image (including i.redd.it)
                print("  - Checking if URL is direct image...")
                if let postURL = url {
                    let urlString = postURL.absoluteString.trimmingCharacters(in: .whitespacesAndNewlines)
                    print("    - Original URL: \(urlString)")
                    
                    // Test the URL detection logic
                    testImageURLDetection(postURL)
                    
                    // Use pathExtension for more reliable extension detection (handles query params)
                    let pathExtension = postURL.pathExtension.lowercased()
                    print("    - Path extension: '\(pathExtension)'")
                    
                    // Check for common image hosting domains that don't always use extensions
                    let lowercasedURL = urlString.lowercased()
                    let isRedditImage = urlString.contains("i.redd.it")
                    let isImgurDirect = urlString.contains("i.imgur.com")
                    let isGfycatImage = urlString.contains("gfycat.com")
                    let isDiscordImage = urlString.contains("cdn.discordapp.com") || urlString.contains("media.discordapp.net")
                    
                    // Handle Imgur URLs that need transformation (imgur.com/XXXXX -> i.imgur.com/XXXXX.jpg)
                    if urlString.contains("imgur.com/") && !urlString.contains("i.imgur.com") && 
                       !urlString.contains("/gallery/") && !urlString.contains("/a/") {
                        // Extract the image ID and convert to direct image URL
                        if let imgurID = urlString.split(separator: "/").last {
                            let directImageURL = "https://i.imgur.com/\(imgurID).jpg"
                            if let transformedURL = URL(string: directImageURL) {
                                print("✅ Transformed Imgur URL to direct image: \(transformedURL)")
                                return transformedURL
                            }
                        }
                    }
                    
                    print("    - Image host checks: i.redd.it=\(isRedditImage), i.imgur=\(isImgurDirect), gfycat=\(isGfycatImage), discord=\(isDiscordImage)")
                    
                    // If it's from a known image host, use it even without extension
                    if isRedditImage || isImgurDirect || isGfycatImage || isDiscordImage {
                        print("✅ Using URL from known image host: \(postURL)")
                        return postURL
                    }
                    
                    // Also check with suffix method as fallback
                    let hasSuffixJPG = lowercasedURL.hasSuffix(".jpg")
                    let hasSuffixJPEG = lowercasedURL.hasSuffix(".jpeg")
                    let hasSuffixPNG = lowercasedURL.hasSuffix(".png")
                    let hasSuffixGIF = lowercasedURL.hasSuffix(".gif")
                    let hasSuffixWEBP = lowercasedURL.hasSuffix(".webp")
                    
                    print("    - Suffix checks: jpg=\(hasSuffixJPG), jpeg=\(hasSuffixJPEG), png=\(hasSuffixPNG), gif=\(hasSuffixGIF), webp=\(hasSuffixWEBP)")
                    
                    // Check using pathExtension first (more reliable)
                    let validExtensions = ["jpg", "jpeg", "png", "gif", "webp"]
                    let isPathExtensionValid = validExtensions.contains(pathExtension)
                    print("    - Is pathExtension '\(pathExtension)' in validExtensions: \(isPathExtensionValid)")
                    
                    if isPathExtensionValid {
                        print("✅ Using direct post url (via pathExtension): \(postURL)")
                        return postURL
                    }
                    
                    // Fallback to suffix check (for edge cases)
                    let hasValidSuffix = hasSuffixJPG || hasSuffixJPEG || hasSuffixPNG || hasSuffixGIF || hasSuffixWEBP
                    print("    - Has valid suffix: \(hasValidSuffix)")
                    
                    if hasValidSuffix {
                        print("✅ Using direct post url (via suffix): \(postURL)")
                        return postURL
                    }
                    
                    print("    - Not detected as image URL")
                }
        
        // 4) Preview images (skip for videos as they're often broken)
        if let preview = preview, let firstImage = preview.images.first {
            // Try to get the source (full resolution) first
            let sourceURLString = firstImage.source.url
                .replacingOccurrences(of: "&amp;", with: "&")
                .replacingOccurrences(of: "amp;", with: "") // Sometimes double-encoded
            
            if let url = URL(string: sourceURLString) {
                print("✅ Using preview source URL (full res): \(url)")
                return url
            }
            
            // If source fails, try the highest resolution available
            let highResolutions = firstImage.resolutions.filter { $0.width > 320 && $0.height > 240 }
            if let bestResolution = highResolutions.last {
                let resURLString = bestResolution.url
                    .replacingOccurrences(of: "&amp;", with: "&")
                    .replacingOccurrences(of: "amp;", with: "") // Sometimes double-encoded
                
                if let url = URL(string: resURLString) {
                    print("✅ Using preview high-res URL (\(bestResolution.width)x\(bestResolution.height)): \(url)")
                    return url
                }
            }
        }
        
        // 5) Special handling for gallery URLs as fallback
        print("  - Checking for gallery URL fallback...")
        if let urlString = url?.absoluteString,
           urlString.contains("reddit.com/gallery/") {
            print("    - This is a gallery URL, but metadata extraction failed")
            print("    - Gallery URL: \(urlString)")
            // For now, we'll return nil and show just the source link
            // TODO: Implement gallery API fallback if needed
        }
        
        // 6) If the post's url is a reddit.com/media link, extract the actual image URL from the query parameter.
        print("  - Checking for reddit.com/media link...")
        if let urlString = url?.absoluteString,
           urlString.contains("reddit.com/media") {
            print("    - Found reddit.com/media link, extracting actual URL...")
            if let components = URLComponents(string: urlString),
               let queryItems = components.queryItems,
               let actualItem = queryItems.first(where: { $0.name == "url" }),
               let encodedUrlString = actualItem.value,
               let decodedUrlString = encodedUrlString.removingPercentEncoding,
               let actualUrl = URL(string: decodedUrlString) {
                print("✅ Using extracted media URL: \(actualUrl)")
                return actualUrl
            }
        }
        // 7) Parse the post's content for an inline image link BEFORE using thumbnail
        print("  - Checking post content for inline images...")
        if let inlineURL = parseFirstImageURL(in: content) {
            print("✅ Using inline content URL: \(inlineURL)")
            return inlineURL
        }
        // 8) Last resort: Use thumbnail if available (better than nothing)
        print("  - Checking thumbnail as last resort...")
        if let thumb = thumbnail,
           !thumb.isEmpty,
           thumb != "self",
           thumb != "default",
           thumb != "nsfw",
           thumb != "spoiler" {
            
            let decodedThumb = thumb
                .replacingOccurrences(of: "&amp;", with: "&")
                .replacingOccurrences(of: "&lt;", with: "<")
                .replacingOccurrences(of: "&gt;", with: ">")
                .replacingOccurrences(of: "&quot;", with: "\"")
                .replacingOccurrences(of: "&#39;", with: "'")
                .replacingOccurrences(of: "&nbsp;", with: " ")
            
            if let thumbURL = URL(string: decodedThumb) {
                // Even low-quality thumbnails are better than no image at all
                print("✅ Using thumbnail as last resort: \(thumbURL)")
                return thumbURL
            } else {
                print("  - Failed to parse thumbnail URL: \(thumb)")
            }
        }
        print("❌ No high-quality image found for post '\(title.prefix(30))...' (id: \(id))")
                print("   This is normal for text posts or posts with only low-quality thumbnails")
                return nil
            }
            
            /// Test function to verify image URL detection logic
            func testImageURLDetection(_ testURL: URL) {
                print("🔍 Testing image URL detection for: \(testURL.absoluteString)")
                
                // Use pathExtension for more reliable extension detection (handles query params)
                let pathExtension = testURL.pathExtension.lowercased()
                print("  - Path extension: '\(pathExtension)'")
                
                // Also check with suffix method as fallback
                let lowercasedURL = testURL.absoluteString.lowercased()
                let hasSuffixJPG = lowercasedURL.hasSuffix(".jpg")
                let hasSuffixJPEG = lowercasedURL.hasSuffix(".jpeg")
                let hasSuffixPNG = lowercasedURL.hasSuffix(".png")
                let hasSuffixGIF = lowercasedURL.hasSuffix(".gif")
                let hasSuffixWEBP = lowercasedURL.hasSuffix(".webp")
                
                print("  - Suffix checks: jpg=\(hasSuffixJPG), jpeg=\(hasSuffixJPEG), png=\(hasSuffixPNG), gif=\(hasSuffixGIF), webp=\(hasSuffixWEBP)")
                
                // Check using pathExtension first (more reliable)
                let validExtensions = ["jpg", "jpeg", "png", "gif", "webp"]
                let isPathExtensionValid = validExtensions.contains(pathExtension)
                print("  - Is pathExtension '\(pathExtension)' in validExtensions: \(isPathExtensionValid)")
                
                // Fallback to suffix check (for edge cases)
                let hasValidSuffix = hasSuffixJPG || hasSuffixJPEG || hasSuffixPNG || hasSuffixGIF || hasSuffixWEBP
                print("  - Has valid suffix: \(hasValidSuffix)")
                
                if isPathExtensionValid || hasValidSuffix {
                    print("✅ Test URL would be detected as image URL")
                } else {
                    print("❌ Test URL would NOT be detected as image URL")
                }
            }
            
            /// Aggregates all potential image URLs, prioritizing higher resolution versions.
            var allImageURLs: [URL] {
        var urls = [URL]()
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
                    print("Skipping low-quality Reddit thumbnail from gallery: \(decodedThumb)")
                } else if let thumbURL = URL(string: decodedThumb) {
                    urls.append(thumbURL)
                    print("WARNING: Including thumbnail in gallery (may be low quality)")
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
