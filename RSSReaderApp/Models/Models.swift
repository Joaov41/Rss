//
//  Models.swift
//  RSSReader


import Foundation

// MARK: - App Settings

struct AppSettings: Codable {
    var refreshInterval: TimeInterval = 900 // 15 minutes
    var showUnreadOnly: Bool = false
    var markReadOnScroll: Bool = true
    var geminiApiKey: String = ""
    var defaultFeedView: FeedViewType = .list

    enum FeedViewType: String, Codable {
        case list, compact, magazine
    }
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

struct Subscription: Identifiable, Codable {
    let id = UUID()
    let title: String
    let url: String
    let type: SubscriptionType
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
    
    init(subreddit: String,
         displayName: String,
         description: String? = nil,
         iconURL: URL? = nil,
         posts: [RedditPost] = []) {
        self.subreddit = subreddit
        self.displayName = displayName
        self.description = description
        self.iconURL = iconURL
        self.posts = posts
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
        // 1) Use preview (usually for single-image posts).
        if let preview = preview, let firstImage = preview.images.first {
            let sourceURLString = firstImage.source.url.replacingOccurrences(of: "&amp;", with: "&")
            if let url = URL(string: sourceURLString) {
                print("Using preview URL: \(url)")
                return url
            }
        }
        // 2) For gallery posts, loop through gallery_data items and use media_metadata.
        if let gallery = gallery_data, let media = media_metadata {
            for item in gallery.items {
                if let mediaItem = media[item.media_id],
                   mediaItem.status == "valid" {
                    if let fullURLString = mediaItem.s?.u?.replacingOccurrences(of: "&amp;", with: "&"),
                       let fullURL = URL(string: fullURLString) {
                        print("Using media_metadata full URL: \(fullURL)")
                        return fullURL
                    } else if let resolutions = mediaItem.p, let firstRes = resolutions.first,
                              let resURLString = firstRes.u?.replacingOccurrences(of: "&amp;", with: "&"),
                              let resURL = URL(string: resURLString) {
                        print("Using media_metadata resolution URL: \(resURL)")
                        return resURL
                    }
                }
            }
        }
        // 3) Check if the post's url directly points to an image.
        if let urlString = url?.absoluteString.lowercased(),
           (urlString.hasSuffix(".jpg") ||
            urlString.hasSuffix(".jpeg") ||
            urlString.hasSuffix(".png") ||
            urlString.hasSuffix(".gif") ||
            urlString.hasSuffix(".webp")),
           let validUrl = url {
            print("Using direct post url: \(validUrl)")
            return validUrl
        }
        // 3.5) If the post's url is a reddit.com/media link, extract the actual image URL from the query parameter.
        if let urlString = url?.absoluteString,
           urlString.contains("reddit.com/media") {
            if let components = URLComponents(string: urlString),
               let queryItems = components.queryItems,
               let actualItem = queryItems.first(where: { $0.name == "url" }),
               let encodedUrlString = actualItem.value,
               let decodedUrlString = encodedUrlString.removingPercentEncoding,
               let actualUrl = URL(string: decodedUrlString) {
                print("Using extracted media URL: \(actualUrl)")
                return actualUrl
            }
        }
        // 4) Fallback to thumbnail if it is valid.
        if let thumb = thumbnail,
           !thumb.isEmpty,
           thumb != "self",
           thumb != "default",
           thumb != "nsfw",
           let thumbURL = URL(string: thumb) {
            print("Using thumbnail URL: \(thumbURL)")
            return thumbURL
        }
        // 5) As a final fallback, parse the post's content for an inline image link.
        if let inlineURL = parseFirstImageURL(in: content) {
            print("Using inline content URL: \(inlineURL)")
            return inlineURL
        }
        print("No image found for post \(id)")
        return nil
    }
    
    /// Aggregates all potential image URLs.
    var allImageURLs: [URL] {
        var urls = [URL]()
        // 1) From preview.
        if let preview = preview, let firstImage = preview.images.first {
            let sourceURLString = firstImage.source.url.replacingOccurrences(of: "&amp;", with: "&")
            if let url = URL(string: sourceURLString) {
                urls.append(url)
            }
        }
        // 2) From gallery (gallery_data + media_metadata).
        if let gallery = gallery_data, let media = media_metadata {
            for item in gallery.items {
                if let mediaItem = media[item.media_id],
                   mediaItem.status == "valid",
                   let urlString = mediaItem.s?.u?.replacingOccurrences(of: "&amp;", with: "&"),
                   let url = URL(string: urlString) {
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
        // 4) Add thumbnail as a final fallback.
        if let thumb = thumbnail,
           !thumb.isEmpty,
           thumb != "self",
           thumb != "default",
           thumb != "nsfw",
           let thumbURL = URL(string: thumb),
           !urls.contains(thumbURL) {
            urls.append(thumbURL)
        }
        // 5) If still no images found, parse the post's content for inline images.
        if let inlineImageURL = parseFirstImageURL(in: content),
           !urls.contains(inlineImageURL) {
            urls.append(inlineImageURL)
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
