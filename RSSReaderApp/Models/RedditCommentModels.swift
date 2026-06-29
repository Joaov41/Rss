import Foundation

struct RedditCommentModel: Identifiable {
    let id: String
    let author: String
    let body: String
    let score: Int
    let createdUtc: TimeInterval
    let replies: [RedditCommentModel]
    let indentationLevel: Int
    
    var createdDate: Date {
        Date(timeIntervalSince1970: createdUtc)
    }
    
    // MARK: - Extract Images & Links
    
    /// Extracts all image URLs from the comment text.
    var imageURLs: [URL] {
        var urls = [URL]()
        
        print("🔍 Analyzing comment body for images: \(String(body.prefix(200)))")
        
        // Helper function to decode HTML entities
        func decodeHTMLEntities(_ text: String) -> String {
            return text
                .replacingOccurrences(of: "&amp;", with: "&")
                .replacingOccurrences(of: "&lt;", with: "<")
                .replacingOccurrences(of: "&gt;", with: ">")
                .replacingOccurrences(of: "&quot;", with: "\"")
                .replacingOccurrences(of: "&#39;", with: "'")
                .replacingOccurrences(of: "&nbsp;", with: " ")
        }
        
        // Helper function to normalize malformed URLs to direct GIF URLs
        func normalizeURL(_ urlString: String) -> String? {
            let decoded = decodeHTMLEntities(urlString)
            
            // Handle giphy shorthand: giphy|xyz -> https://media.giphy.com/media/xyz/giphy.gif
            if decoded.hasPrefix("giphy|") {
                let gifId = String(decoded.dropFirst(6)) // Remove "giphy|"
                return "https://media.giphy.com/media/\(gifId)/giphy.gif"
            }
            
            // Handle gfycat shorthand: gfycat|xyz -> https://giant.gfycat.com/xyz.gif
            if decoded.hasPrefix("gfycat|") {
                let gifId = String(decoded.dropFirst(7)) // Remove "gfycat|"
                return "https://giant.gfycat.com/\(gifId).gif"
            }
            
            // Handle imgur shorthand: imgur|xyz -> https://i.imgur.com/xyz.gif
            if decoded.hasPrefix("imgur|") {
                let gifId = String(decoded.dropFirst(6)) // Remove "imgur|"
                return "https://i.imgur.com/\(gifId).gif"
            }
            
            // If it's already a proper URL, return as-is
            if decoded.hasPrefix("http://") || decoded.hasPrefix("https://") {
                return decoded
            }
            
            return nil
        }
        
        // Pattern 1: Markdown links [text](url) that contain proper HTTP image URLs
        let markdownImageRegex = "(?i)\\[([^\\]]+)\\]\\((https?://[^\\)]+)\\)"
        if let regex = try? NSRegularExpression(pattern: markdownImageRegex) {
            let range = NSRange(body.startIndex..., in: body)
            let matches = regex.matches(in: body, options: [], range: range)
            
            for match in matches {
                if match.numberOfRanges >= 3,
                   let urlRange = Range(match.range(at: 2), in: body) {
                    let urlString = decodeHTMLEntities(String(body[urlRange]))
                    
                    // Check if this URL is an image URL
                    let lowerURL = urlString.lowercased()
                    if lowerURL.hasSuffix(".jpg") || lowerURL.hasSuffix(".jpeg") || 
                       lowerURL.hasSuffix(".png") || lowerURL.hasSuffix(".gif") || 
                       lowerURL.hasSuffix(".webp") ||
                       lowerURL.contains("i.redd.it") || lowerURL.contains("v.redd.it") || 
                       lowerURL.contains("preview.redd.it") ||
                       lowerURL.contains("giphy.com") || lowerURL.contains("gfycat.com") || 
                       lowerURL.contains("imgur.com") {
                        
                        if let url = URL(string: urlString) {
                            urls.append(url)
                            print("📸 Found markdown image URL: \(urlString)")
                        }
                    }
                }
            }
        }
        
        // Pattern 1.5: Markdown links [text](malformed_url) that contain malformed image URLs
        let malformedMarkdownRegex = "(?i)\\[([^\\]]+)\\]\\(([^\\)]+)\\)"
        if let regex = try? NSRegularExpression(pattern: malformedMarkdownRegex) {
            let range = NSRange(body.startIndex..., in: body)
            let matches = regex.matches(in: body, options: [], range: range)
            
            for match in matches {
                if match.numberOfRanges >= 3,
                   let urlRange = Range(match.range(at: 2), in: body) {
                    let originalURL = String(body[urlRange])
                    
                    // Skip if this is already a proper HTTP URL (handled by Pattern 1)
                    if originalURL.lowercased().hasPrefix("http://") || originalURL.lowercased().hasPrefix("https://") {
                        continue
                    }
                    
                    // Try to normalize malformed URLs
                    if let normalizedURL = normalizeURL(originalURL),
                       let url = URL(string: normalizedURL) {
                        urls.append(url)
                        print("📸 Found malformed markdown image URL: \(originalURL) -> \(normalizedURL)")
                    }
                }
            }
        }
        
        // Pattern 2: Direct image file extensions (plain URLs)
        let imageRegex = "(?i)(https?://[^\\s\\)]+\\.(?:jpg|jpeg|png|gif|webp)(?:\\?[^\\s\\)]+)?)"
        if let regex = try? NSRegularExpression(pattern: imageRegex) {
            let range = NSRange(body.startIndex..., in: body)
            let matches = regex.matches(in: body, options: [], range: range)
            
            for match in matches {
                if let r = Range(match.range, in: body) {
                    let urlString = decodeHTMLEntities(String(body[r]))
                    if let url = URL(string: urlString), !urls.contains(url) {
                        urls.append(url)
                        print("📸 Found direct image URL: \(urlString)")
                    }
                }
            }
        }
        
        // Pattern 3: Reddit image/video hosting sites (plain URLs)
        let redditImageRegex = "(?i)(https?://(?:i\\.redd\\.it|v\\.redd\\.it|preview\\.redd\\.it)/[^\\s\\)]+)"
        if let regex = try? NSRegularExpression(pattern: redditImageRegex) {
            let range = NSRange(body.startIndex..., in: body)
            let matches = regex.matches(in: body, options: [], range: range)
            
            for match in matches {
                if let r = Range(match.range, in: body) {
                    let urlString = decodeHTMLEntities(String(body[r]))
                    if let url = URL(string: urlString), !urls.contains(url) {
                        urls.append(url)
                        print("📸 Found Reddit image URL: \(urlString)")
                    }
                }
            }
        }
        
        // Pattern 4: GIF hosting sites (plain URLs)
        let gifHostingRegex = "(?i)(https?://(?:giphy\\.com|gfycat\\.com|imgur\\.com)/[^\\s\\)]+)"
        if let regex = try? NSRegularExpression(pattern: gifHostingRegex) {
            let range = NSRange(body.startIndex..., in: body)
            let matches = regex.matches(in: body, options: [], range: range)
            
            for match in matches {
                if let r = Range(match.range, in: body) {
                    let urlString = decodeHTMLEntities(String(body[r]))
                    if let url = URL(string: urlString), !urls.contains(url) {
                        urls.append(url)
                        print("📸 Found GIF hosting URL: \(urlString)")
                    }
                }
            }
        }
        
        print("🎯 Total image URLs found: \(urls.count)")
        return urls
    }
    
    /// Extracts URLs from the comment that are not image links.
    var nonImageLinks: [URL] {
        let linkRegex = "(?i)(https?://[^\\s]+)"
        guard let regex = try? NSRegularExpression(pattern: linkRegex) else { return [] }
        let range = NSRange(body.startIndex..., in: body)
        let matches = regex.matches(in: body, options: [], range: range)
        
        var results = [URL]()
        for match in matches {
            if let r = Range(match.range, in: body) {
                let urlString = String(body[r])
                // Determine the file extension by ignoring any query parameters.
                let lower = urlString.lowercased()
                let extensionCandidate = lower.split(separator: "?").first ?? Substring(lower)
                
                // Skip direct image file extensions
                if extensionCandidate.hasSuffix(".jpg")
                    || extensionCandidate.hasSuffix(".jpeg")
                    || extensionCandidate.hasSuffix(".png")
                    || extensionCandidate.hasSuffix(".gif")
                    || extensionCandidate.hasSuffix(".webp") {
                    continue
                }
                
                // Skip Reddit image/video hosting sites
                if lower.contains("i.redd.it")
                    || lower.contains("v.redd.it")
                    || lower.contains("preview.redd.it") {
                    continue
                }
                
                // Skip GIF hosting sites
                if lower.contains("giphy.com")
                    || lower.contains("gfycat.com")
                    || lower.contains("imgur.com") {
                    continue
                }
                
                if let url = URL(string: urlString) {
                    results.append(url)
                }
            }
        }
        return results
    }
    
    /// Generates a cleaned version of the comment text for a preview.
    var cleanedBody: String {
        var text = body
        // Replace image URLs (including optional query parameters) with a placeholder.
        text = text.replacingOccurrences(
            of: "(?i)https?://[^\\s]+\\.(?:jpg|jpeg|png|gif|webp)(\\?[^\\s]+)?",
            with: "[IMAGE]",
            options: .regularExpression
        )
        // Replace other URLs with a placeholder.
        text = text.replacingOccurrences(
            of: "(?i)https?://[^\\s]+",
            with: "[LINK]",
            options: .regularExpression
        )
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    // MARK: - Initialization
    
    init(id: String,
         author: String,
         body: String,
         score: Int,
         createdUtc: TimeInterval,
         replies: [RedditCommentModel] = [],
         indentationLevel: Int = 0) {
        self.id = id
        self.author = author
        self.body = body
        self.score = score
        self.createdUtc = createdUtc
        self.replies = replies
        self.indentationLevel = indentationLevel
    }
    
    // MARK: - Parsing from JSON
    
    static func parseComments(from json: [String: Any],
                              indentationLevel: Int = 0) -> [RedditCommentModel] {
        guard let data = json["data"] as? [String: Any],
              let children = data["children"] as? [[String: Any]] else {
            return []
        }
        
        var comments: [RedditCommentModel] = []
        for child in children {
            guard let kind = child["kind"] as? String, kind == "t1",
                  let data = child["data"] as? [String: Any],
                  let id = data["id"] as? String,
                  let author = data["author"] as? String,
                  let body = data["body"] as? String,
                  let score = data["score"] as? Int,
                  let createdUtc = data["created_utc"] as? TimeInterval else {
                continue
            }
            
            var repliesArray: [RedditCommentModel] = []
            if let repliesJson = data["replies"] as? [String: Any], !repliesJson.isEmpty {
                repliesArray = parseComments(from: repliesJson, indentationLevel: indentationLevel + 1)
            }
            
            let comment = RedditCommentModel(
                id: id,
                author: author,
                body: body,
                score: score,
                createdUtc: createdUtc,
                replies: repliesArray,
                indentationLevel: indentationLevel
            )
            comments.append(comment)
        }
        return comments
    }
}
