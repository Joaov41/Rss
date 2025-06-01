import Foundation
import Combine
import FeedKit
import SwiftUI // For UIImage
import SwiftSoup

// MARK: - String Extension for HTML Processing
extension String {
    func removingHTML() -> String {
        do {
            let doc = try SwiftSoup.parse(self)
            return try doc.text()
        } catch {
            // Simple fallback removal if SwiftSoup fails
            return self.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        }
    }
    
    func processHTMLContent() -> String {
        // Just clean up the HTML without inserting image markers
        do {
            let document = try SwiftSoup.parse(self)
            
            // Fix image URLs to ensure they're absolute
            let imgElements = try document.select("img")
            for img in imgElements {
                // Handle data-lazy-src which is common in WordPress sites
                if let dataSrc = try? img.attr("data-lazy-src"), !dataSrc.isEmpty {
                    try img.attr("src", dataSrc)
                }
                
                // Handle srcset
                if let srcset = try? img.attr("srcset"), !srcset.isEmpty {
                    // Get the highest resolution image from srcset
                    let srcsetParts = srcset.components(separatedBy: ",")
                    if let lastPart = srcsetParts.last {
                        let url = lastPart.components(separatedBy: " ").first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        if !url.isEmpty {
                            try img.attr("src", url)
                        }
                    }
                }
                
                // Add styling for responsiveness
                try img.attr("style", "max-width:100%;height:auto;display:block;margin:24px auto;")
            }
            
            // Return the cleaned HTML with proper image tags
            return try document.html()
            
        } catch {
            // If SwiftSoup fails, return the original content
            return self
        }
    }
    
    // Helper function to preserve HTML structure (headings, paragraphs, etc.)
    private func preserveHTMLStructure(_ document: SwiftSoup.Document) throws -> String {
        // Return the complete HTML
        return try document.html()
    }
    
    // Function to extract image URLs from HTML content using regex (fallback)
    func extractImageURLs() -> [URL] {
        var urls: [URL] = []
        
        // Look for common image patterns
        
        // 1. Standard <img> tags with src attributes
        let imgPattern = "<img[^>]*src=[\"']([^\"']+)[\"'][^>]*>"
        extractURLsWithPattern(imgPattern, from: self, into: &urls)
        
        // 2. Background images in style attributes
        let bgPattern = "background-image:\\s*url\\([\"']?([^\"')]+)[\"']?\\)"
        extractURLsWithPattern(bgPattern, from: self, into: &urls)
        
        // 3. Figure elements with data-src attributes (common in lazy-loading)
        let dataSrcPattern = "data-src=[\"']([^\"']+)[\"']"
        extractURLsWithPattern(dataSrcPattern, from: self, into: &urls)
        
        return urls
    }
    
    // Helper function to extract URLs with a given pattern
    private func extractURLsWithPattern(_ pattern: String, from string: String, into urls: inout [URL]) {
        do {
            let regex = try NSRegularExpression(pattern: pattern, options: .caseInsensitive)
            let nsString = string as NSString
            let results = regex.matches(in: string, options: [], range: NSRange(location: 0, length: nsString.length))
            
            for match in results {
                if match.numberOfRanges >= 2 {
                    let srcRange = match.range(at: 1)
                    let urlString = nsString.substring(with: srcRange)
                    
                    // Clean up URL string (remove quotes and spaces)
                    let cleanUrlString = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
                        .replacingOccurrences(of: "\"", with: "")
                        .replacingOccurrences(of: "'", with: "")
                    
                    if let url = URL(string: cleanUrlString), !urls.contains(url) {
                        urls.append(url)
                    }
                }
            }
        } catch {
            print("Error extracting URLs with pattern \(pattern): \(error)")
        }
    }
}

// MARK: - FeedService Class
class FeedService {
    private var cancellables = Set<AnyCancellable>()
    
    // MARK: - Feed Fetching
    func fetchFeed(url: String) -> AnyPublisher<Feed, Never> {
        guard let feedURL = URL(string: url) else {
            return Just(Feed(title: "Invalid URL", url: url, articles: []))
                .eraseToAnyPublisher()
        }
        
        return Future<Feed, Never> { promise in
            let parser = FeedParser(URL: feedURL)
            parser.parseAsync { result in
                switch result {
                case .success(let parsedFeed):
                    // Process feed items as before.
                    let partialFeed = self.processFeed(parsedFeed, url: url)
                    
                    // Check each article; if truncated, fetch full text.
                    self.fetchFullArticlesIfNeeded(for: partialFeed)
                        .sink { finalFeed in
                            promise(.success(finalFeed))
                        }
                        .store(in: &self.cancellables)
                    
                case .failure(let error):
                    print("Feed parsing error: \(error)")
                    promise(.success(Feed(title: "Error Loading Feed", url: url, articles: [])))
                }
            }
        }
        .eraseToAnyPublisher()
    }
    
    // MARK: - Feed Processing
    private func processFeed(_ parsedFeed: FeedKit.Feed, url: String) -> Feed {
        switch parsedFeed {
        case let .atom(feed):
            return processAtomFeed(feed, url: url)
        case let .rss(feed):
            return processRSSFeed(feed, url: url)
        case let .json(feed):
            return processJSONFeed(feed, url: url)
        }
    }
    
    // MARK: - RSS
    private func processRSSFeed(_ feed: RSSFeed, url: String) -> Feed {
        let articles = feed.items?.compactMap { item -> Article? in
            guard let rawTitle = item.title else { return nil }
            
            let htmlContent: String
            if let encoded = item.content?.contentEncoded, !encoded.isEmpty {
                htmlContent = encoded
            } else {
                htmlContent = item.description ?? ""
            }
            
            // Try to get standard image URLs first
            var articleImageURL: URL? = nil
            if let enclosureLink = item.enclosure?.attributes?.url, !enclosureLink.isEmpty {
                articleImageURL = URL(string: enclosureLink)
            } else if let mediaContents = item.media?.mediaContents,
                      let firstMedia = mediaContents.first,
                      let mediaURL = firstMedia.attributes?.url, !mediaURL.isEmpty {
                articleImageURL = URL(string: mediaURL)
            }

            // --- Fallback: Extract first <img> from content if no standard URL found ---
            if articleImageURL == nil, !htmlContent.isEmpty {
                articleImageURL = self.extractFirstImageURL(fromHTML: htmlContent)
            }
            // --- End Fallback ---
            
            // Fix date for specific sites like 9to5mac that might have formatting issues
            var publishDate = item.pubDate ?? Date()
            
            // Check if this is from 9to5mac or similar sites with date issues
            if let link = item.link, link.contains("9to5mac.com") {
                // Try to extract a more reliable date from the content or other fields
                if let dateString = item.dublinCore?.dcDate as? String {
                    // dcDate is a String, parse it
                    publishDate = self.parseDate(dateString) ?? publishDate
                } else if let date = item.dublinCore?.dcDate as? Date {
                    // dcDate is already a Date
                    publishDate = date
                }
            }
            
            var article = Article(
                id: item.guid?.value ?? UUID().uuidString,
                title: rawTitle.removingHTML(),
                content: htmlContent.processHTMLContent(),
                url: URL(string: item.link ?? ""),
                publishDate: publishDate,
                author: item.author,
                feedTitle: feed.title?.removingHTML() ?? "Unknown Feed",
                feedURL: url,
                imageURL: articleImageURL,
                isRead: false,
                isFavorite: false
            )
            
            // Try to extract domain for favicon.
            if let articleURL = URL(string: item.link ?? ""),
               let host = articleURL.host {
                article.domainIcon = host
            }
            
            return article
        } ?? []
        
        return Feed(
            title: feed.title?.removingHTML() ?? "Unknown Feed",
            url: url,
            description: feed.description?.removingHTML(),
            imageURL: URL(string: feed.image?.url ?? ""),
            articles: articles
        )
    }
    
    // MARK: - Atom
    private func processAtomFeed(_ feed: AtomFeed, url: String) -> Feed {
        let articles = feed.entries?.compactMap { entry -> Article? in
            guard let rawTitle = entry.title else { return nil }
            
            let articleURLString = entry.links?.first?.attributes?.href
            let htmlContent = entry.content?.value ?? entry.summary?.value ?? ""

            // --- Fallback: Extract first <img> from content --- 
            // (Atom doesn't have standard enclosure/media tags like RSS, so we rely on content parsing)
            let articleImageURL = self.extractFirstImageURL(fromHTML: htmlContent)
            // --- End Fallback ---
            
            var article = Article(
                id: entry.id ?? UUID().uuidString,
                title: rawTitle.removingHTML(),
                content: htmlContent.processHTMLContent(),
                url: URL(string: articleURLString ?? ""),
                publishDate: entry.published ?? entry.updated ?? Date(),
                author: entry.authors?.first?.name,
                feedTitle: feed.title?.removingHTML() ?? "Unknown Feed",
                feedURL: url,
                imageURL: articleImageURL, // Use extracted URL
                isRead: false,
                isFavorite: false
            )
            
            if let articleURLString = articleURLString,
               let articleURL = URL(string: articleURLString),
               let host = articleURL.host {
                article.domainIcon = host
            }
            
            return article
        } ?? []
        
        return Feed(
            title: feed.title?.removingHTML() ?? "Unknown Feed",
            url: url,
            description: feed.subtitle?.value?.removingHTML(),
            imageURL: URL(string: feed.logo ?? ""),
            articles: articles
        )
    }
    
    // MARK: - JSON
    private func processJSONFeed(_ feed: JSONFeed, url: String) -> Feed {
        let articles = feed.items?.compactMap { item -> Article? in
            guard let rawTitle = item.title else { return nil }
            
            let htmlContent = item.contentHtml ?? item.contentText ?? ""
            
            // Try standard image tag first
            var articleImageURL = URL(string: item.image ?? "")

            // --- Fallback: Extract first <img> from content if no standard URL found ---
            if articleImageURL == nil, !htmlContent.isEmpty {
                articleImageURL = self.extractFirstImageURL(fromHTML: htmlContent)
            }
            // --- End Fallback ---

            var article = Article(
                id: item.id ?? UUID().uuidString,
                title: rawTitle.removingHTML(),
                content: htmlContent.processHTMLContent(),
                url: URL(string: item.url ?? ""),
                publishDate: item.datePublished ?? Date(),
                author: item.author?.name,
                feedTitle: feed.title?.removingHTML() ?? "Unknown Feed",
                feedURL: url,
                imageURL: articleImageURL, // Use potentially extracted URL
                isRead: false,
                isFavorite: false
            )
            
            if let articleURLString = item.url,
               let articleURL = URL(string: articleURLString),
               let host = articleURL.host {
                article.domainIcon = host
            }
            
            return article
        } ?? []
        
        return Feed(
            title: feed.title?.removingHTML() ?? "Unknown Feed",
            url: url,
            description: feed.description?.removingHTML(),
            imageURL: URL(string: feed.icon ?? ""),
            articles: articles
        )
    }
    
    // MARK: - Secondary Fetch for Full Article Content
    
    /// Returns true if the content appears truncated.
    private func isTruncated(_ content: String) -> Bool {
        let lower = content.lowercased()
        
        // Check for common truncation markers
        let truncationMarkers = [
            "read more",
            "continue reading",
            "…more",
            "… more",
            "read full article",
            "[…]",
            "click to continue",
            "more...",
            "more…",
            "continue",
            "listen to a recap",  // 9to5Mac podcast reference
            "daily is available"  // 9to5Mac podcast reference
        ]
        
        for marker in truncationMarkers {
            if lower.contains(marker) {
                return true
            }
        }
        
        // Consider short content potentially truncated, but be smarter about it:
        // If content is short AND contains a link or ellipsis, it's likely truncated
        if content.count < 800 &&
           (lower.contains("http") ||
            lower.contains("…") ||
            lower.contains("...") ||
            lower.contains("click here")) {
            return true
        }
        
        // Very short content is almost certainly truncated
        if content.count < 300 {
            return true
        }
        
        return false
    }
    
    /// For each article in the feed that appears truncated, fetch the full content from the webpage.
    private func fetchFullArticlesIfNeeded(for feed: Feed) -> AnyPublisher<Feed, Never> {
        let articlePublishers = feed.articles.map { article -> AnyPublisher<Article, Never> in
            if isTruncated(article.content), let link = article.url {
                return fetchFullArticle(for: article, from: link)
            } else {
                return Just(article).eraseToAnyPublisher()
            }
        }
        
        return Publishers.MergeMany(articlePublishers)
            .collect()
            .map { updatedArticles -> Feed in
                // Sort articles by publishDate descending (most recent first)
                let sortedArticles = updatedArticles.sorted { $0.publishDate > $1.publishDate }
                // 🐞 DEBUG LOG: Print publishDate for each article after sorting
                print("🐞 Article publish dates after sorting:")
                for article in sortedArticles {
                    print(article.publishDate)
                }
                var finalFeed = feed
                finalFeed.articles = sortedArticles
                return finalFeed
            }
            .eraseToAnyPublisher()
    }
    
    /// Fetch the full article content by performing a secondary network request and scraping the webpage.
    private func fetchFullArticle(for article: Article, from url: URL) -> AnyPublisher<Article, Never> {
        return URLSession.shared.dataTaskPublisher(for: url)
            .map { $0.data }
            .catch { _ in Just(Data()) } // Fallback to empty data if network fails
            .map { data -> Article in
                guard let html = String(data: data, encoding: .utf8) else {
                    return article
                }
                
                do {
                    let doc = try SwiftSoup.parse(html)
                    
                    // Site-specific handling for known problematic sites
                    let host = url.host?.lowercased() ?? ""
                    
                    // Special handling for 9to5Mac
                    if host.contains("9to5mac.com") {
                        return self.handle9to5Mac(doc: doc, article: article)
                    }
                    
                    // Remove common "read more" elements and other distractions
                    try doc.select("a.more-link, .more-link, .read-more, .readmore, " +
                                  ".sharedaddy, .share-buttons, .social-share, " +
                                  ".comments, .article-comments, " +
                                  ".related-posts, .recommended, " +
                                  "script, style, iframe, .advertisement, .ad-container").remove()
                    
                    // Try multiple content selectors in order of specificity
                    let potentialContentSelectors = [
                        "article .entry-content",
                        "div.article-content",
                        "div.entry-content",
                        ".post-content",
                        "article",
                        ".content-area",
                        ".main-content",
                        "main",
                        ".article",
                        "#content"
                    ]
                    
                    var mainElement: Element? = nil
                    
                    // Find the first matching selector
                    for selector in potentialContentSelectors {
                        if let element = try doc.select(selector).first() {
                            mainElement = element
                            break
                        }
                    }
                    
                    // Fallback to body if no selector matched
                    mainElement = mainElement ?? doc.body()
                    
                    // Fix images to ensure they have proper src attributes
                    if let element = mainElement {
                        let imgElements = try element.select("img")
                        for img in imgElements {
                            // Handle data-lazy-src which is common in WordPress sites
                            if let dataSrc = try? img.attr("data-lazy-src"), !dataSrc.isEmpty {
                                try img.attr("src", dataSrc)
                            }
                            
                            // Handle data-src for lazy-loaded images
                            if let dataSrc = try? img.attr("data-src"), !dataSrc.isEmpty {
                                try img.attr("src", dataSrc)
                            }
                            
                            // Handle srcset
                            if let srcset = try? img.attr("srcset"), !srcset.isEmpty {
                                let srcsetParts = srcset.components(separatedBy: ",")
                                if let lastPart = srcsetParts.last {
                                    let url = lastPart.components(separatedBy: " ").first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                                    if !url.isEmpty {
                                        try img.attr("src", url)
                                    }
                                }
                            }
                            
                            // Add styling for responsiveness
                            try img.attr("style", "max-width:100%;height:auto;display:block;margin:24px auto;")
                        }
                    }
                    
                    // Get the cleaned HTML content
                    let contentHTML = try mainElement?.html() ?? ""
                    
                    // If we got empty content, fall back to the original article content
                    if contentHTML.isEmpty {
                        return article
                    }
                    
                    var updated = article
                    updated.content = contentHTML
                    return updated
                    
                } catch {
                    // If parsing fails, return the original article
                    print("Error parsing article HTML: \(error)")
                    return article
                }
            }
            .replaceError(with: article)
            .eraseToAnyPublisher()
    }
    
    /// Special handler for 9to5Mac articles which have a specific structure
    private func handle9to5Mac(doc: Document, article: Article) -> Article {
        do {
            // Remove sponsor blocks, newsletter forms, and other clutter
            try doc.select(".sponsor-block, .newsletter-block, .comments-link, .st-related-posts, script, style, form").remove()
            
            // 9to5Mac uses a specific content structure
            let contentSelectors = [
                ".post-content", // Main content area
                ".article-content", // Alternative content area
                "#primary" // Another possible content container
            ]
            
            var mainElement: Element? = nil
            for selector in contentSelectors {
                if let element = try doc.select(selector).first() {
                    mainElement = element
                    break
                }
            }
            
            guard let contentElement = mainElement else {
                return article
            }
            
            // Fix images to ensure they have proper src attributes
            let imgElements = try contentElement.select("img")
            for img in imgElements {
                // Handle data-lazy-src which is common in WordPress sites
                if let dataSrc = try? img.attr("data-lazy-src"), !dataSrc.isEmpty {
                    try img.attr("src", dataSrc)
                }
                
                // Handle data-src for lazy-loaded images
                if let dataSrc = try? img.attr("data-src"), !dataSrc.isEmpty {
                    try img.attr("src", dataSrc)
                }
                
                // Handle srcset
                if let srcset = try? img.attr("srcset"), !srcset.isEmpty {
                    let srcsetParts = srcset.components(separatedBy: ",")
                    if let firstPart = srcsetParts.first {
                        let url = firstPart.components(separatedBy: " ").first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        if !url.isEmpty {
                            try img.attr("src", url)
                        }
                    }
                }
                
                // Add styling for responsiveness
                try img.attr("style", "max-width:100%;height:auto;display:block;margin:24px auto;")
            }
            
            // Try to ensure featured image is included
            if let featuredImage = try doc.select(".featured-image img").first() {
                try contentElement.prepend(featuredImage.outerHtml())
            }
            
            // Get the HTML content with all images properly processed
            let contentHTML = try contentElement.html()
            
            // If the content is still too short, it probably failed
            if contentHTML.count < 100 {
                return article
            }
            
            // Create updated article with full content
            var updated = article
            updated.content = contentHTML
            return updated
            
        } catch {
            print("Error parsing 9to5Mac article: \(error)")
            return article
        }
    }
    
    // Helper method to parse a date string with multiple possible formats
    private func parseDate(_ dateString: String) -> Date? {
        let possibleFormats = [
            "yyyy-MM-dd'T'HH:mm:ssZ",
            "yyyy-MM-dd'T'HH:mm:ss'Z'",
            "yyyy-MM-dd'T'HH:mm:ssZZZZZ",
            "EEE, dd MMM yyyy HH:mm:ss Z",
            "yyyy-MM-dd'T'HH:mm:ss.SSSZ"
        ]
        
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        
        for format in possibleFormats {
            formatter.dateFormat = format
            if let date = formatter.date(from: dateString) {
                return date
            }
        }
        
        return nil
    }

    // MARK: - Helper Functions

    /// Helper function to extract the first image URL from HTML content using SwiftSoup.
    private func extractFirstImageURL(fromHTML html: String) -> URL? {
        guard !html.isEmpty else { return nil }
        do {
            let document = try SwiftSoup.parse(html)
            // Select the first <img> element
            if let imgElement = try document.select("img").first() {
                // Try getting "src", fallback to "data-lazy-src"
                var src = try imgElement.attr("src")
                if src.isEmpty {
                    src = try imgElement.attr("data-lazy-src")
                }
                // Basic check to avoid tiny spacer GIFs or trackers
                if !src.isEmpty, src.count > 10, !src.contains("spacer.gif"), !src.contains("pixel.gif") {
                    return URL(string: src)
                }
            }
        } catch {
            print("SwiftSoup error extracting image: \(error)")
        }
        return nil
    }
}

