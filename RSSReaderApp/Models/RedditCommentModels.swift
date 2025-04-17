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
        // Updated regex to include optional query parameters after the image extension.
        let imageRegex = "(?i)(https?://[^\\s]+\\.(?:jpg|jpeg|png|gif|webp)(\\?[^\\s]+)?)"
        guard let regex = try? NSRegularExpression(pattern: imageRegex) else { return [] }
        let range = NSRange(body.startIndex..., in: body)
        let matches = regex.matches(in: body, options: [], range: range)
        
        return matches.compactMap { match in
            if let r = Range(match.range, in: body) {
                let urlString = String(body[r])
                    .replacingOccurrences(of: "&amp;", with: "&")
                return URL(string: urlString)
            }
            return nil
        }
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
                
                if extensionCandidate.hasSuffix(".jpg")
                    || extensionCandidate.hasSuffix(".jpeg")
                    || extensionCandidate.hasSuffix(".png")
                    || extensionCandidate.hasSuffix(".gif")
                    || extensionCandidate.hasSuffix(".webp") {
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
