import Foundation

struct RedditCommentLink: Identifiable, Hashable {
    let id: String
    let text: String
    let url: URL
}

struct RedditCommentModel: Identifiable {
    let id: String
    let author: String
    let body: String
    let score: Int
    let createdUtc: TimeInterval
    let replies: [RedditCommentModel]
    let indentationLevel: Int
    let bodyBlocks: [AttributedString]
    let imageURLs: [URL]
    let displayLinks: [RedditCommentLink]

    var createdDate: Date {
        Date(timeIntervalSince1970: createdUtc)
    }

    // MARK: - Extract Images & Links

    private static func decodeHTMLEntities(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&nbsp;", with: " ")
    }

    private static func normalizeImageURL(_ urlString: String) -> String? {
        let decoded = decodeHTMLEntities(urlString)

        if decoded.hasPrefix("giphy|") {
            let gifId = String(decoded.dropFirst(6))
            return "https://media.giphy.com/media/\(gifId)/giphy.gif"
        }

        if decoded.hasPrefix("gfycat|") {
            let gifId = String(decoded.dropFirst(7))
            return "https://giant.gfycat.com/\(gifId).gif"
        }

        if decoded.hasPrefix("imgur|") {
            let gifId = String(decoded.dropFirst(6))
            return "https://i.imgur.com/\(gifId).gif"
        }

        if decoded.hasPrefix("http://") || decoded.hasPrefix("https://") {
            return decoded
        }

        return nil
    }

    private static func isImageURLString(_ urlString: String) -> Bool {
        let lowerURL = urlString.lowercased()
        return lowerURL.hasSuffix(".jpg")
            || lowerURL.hasSuffix(".jpeg")
            || lowerURL.hasSuffix(".png")
            || lowerURL.hasSuffix(".gif")
            || lowerURL.hasSuffix(".webp")
            || lowerURL.contains("i.redd.it")
            || lowerURL.contains("v.redd.it")
            || lowerURL.contains("preview.redd.it")
            || lowerURL.contains("giphy.com")
            || lowerURL.contains("gfycat.com")
            || lowerURL.contains("imgur.com")
    }

    private static func extractImageURLs(from body: String) -> [URL] {
        var urls = [URL]()

        let markdownImageRegex = "(?i)\\[([^\\]]+)\\]\\((https?://[^\\)]+)\\)"
        if let regex = try? NSRegularExpression(pattern: markdownImageRegex) {
            let range = NSRange(body.startIndex..., in: body)
            let matches = regex.matches(in: body, options: [], range: range)

            for match in matches {
                if match.numberOfRanges >= 3,
                   let urlRange = Range(match.range(at: 2), in: body) {
                    let urlString = decodeHTMLEntities(String(body[urlRange]))
                    if isImageURLString(urlString),
                       let url = URL(string: urlString),
                       !urls.contains(url) {
                        urls.append(url)
                    }
                }
            }
        }

        let malformedMarkdownRegex = "(?i)\\[([^\\]]+)\\]\\(([^\\)]+)\\)"
        if let regex = try? NSRegularExpression(pattern: malformedMarkdownRegex) {
            let range = NSRange(body.startIndex..., in: body)
            let matches = regex.matches(in: body, options: [], range: range)

            for match in matches {
                if match.numberOfRanges >= 3,
                   let urlRange = Range(match.range(at: 2), in: body) {
                    let originalURL = String(body[urlRange])

                    if originalURL.lowercased().hasPrefix("http://") || originalURL.lowercased().hasPrefix("https://") {
                        continue
                    }

                    if let normalizedURL = normalizeImageURL(originalURL),
                       let url = URL(string: normalizedURL),
                       !urls.contains(url) {
                        urls.append(url)
                    }
                }
            }
        }

        let imageRegex = "(?i)(https?://[^\\s\\)]+\\.(?:jpg|jpeg|png|gif|webp)(?:\\?[^\\s\\)]+)?)"
        if let regex = try? NSRegularExpression(pattern: imageRegex) {
            let range = NSRange(body.startIndex..., in: body)
            let matches = regex.matches(in: body, options: [], range: range)

            for match in matches {
                if let r = Range(match.range, in: body) {
                    let urlString = decodeHTMLEntities(String(body[r]))
                    if let url = URL(string: urlString), !urls.contains(url) {
                        urls.append(url)
                    }
                }
            }
        }

        let redditImageRegex = "(?i)(https?://(?:i\\.redd\\.it|v\\.redd\\.it|preview\\.redd\\.it)/[^\\s\\)]+)"
        if let regex = try? NSRegularExpression(pattern: redditImageRegex) {
            let range = NSRange(body.startIndex..., in: body)
            let matches = regex.matches(in: body, options: [], range: range)

            for match in matches {
                if let r = Range(match.range, in: body) {
                    let urlString = decodeHTMLEntities(String(body[r]))
                    if let url = URL(string: urlString), !urls.contains(url) {
                        urls.append(url)
                    }
                }
            }
        }

        let gifHostingRegex = "(?i)(https?://(?:giphy\\.com|gfycat\\.com|imgur\\.com)/[^\\s\\)]+)"
        if let regex = try? NSRegularExpression(pattern: gifHostingRegex) {
            let range = NSRange(body.startIndex..., in: body)
            let matches = regex.matches(in: body, options: [], range: range)

            for match in matches {
                if let r = Range(match.range, in: body) {
                    let urlString = decodeHTMLEntities(String(body[r]))
                    if let url = URL(string: urlString), !urls.contains(url) {
                        urls.append(url)
                    }
                }
            }
        }

        return urls
    }

    private static func extractDisplayLinks(from body: String, excludingImageURLs imageURLs: [URL]) -> [RedditCommentLink] {
        var links = [RedditCommentLink]()

        let markdownPattern = "\\[([^\\]]+)\\]\\(([^\\)]+)\\)"
        if let regex = try? NSRegularExpression(pattern: markdownPattern) {
            let range = NSRange(body.startIndex..., in: body)
            let matches = regex.matches(in: body, options: [], range: range)

            for match in matches {
                if match.numberOfRanges >= 3,
                   let textRange = Range(match.range(at: 1), in: body),
                   let urlRange = Range(match.range(at: 2), in: body) {
                    let urlString = decodeHTMLEntities(String(body[urlRange]))
                    guard let url = URL(string: urlString) else { continue }

                    let linkText = String(body[textRange])
                    if imageURLs.contains(url) || isImageURLString(url.absoluteString) {
                        continue
                    }

                    links.append(RedditCommentLink(
                        id: "\(links.count)-\(url.absoluteString)-\(linkText)",
                        text: linkText,
                        url: url
                    ))
                }
            }
        }

        let urlPattern = "(?i)(https?://[^\\s]+)(?![^\\(\\)]*\\))(?![!\\[])"
        if let regex = try? NSRegularExpression(pattern: urlPattern) {
            let range = NSRange(body.startIndex..., in: body)
            let matches = regex.matches(in: body, options: [], range: range)

            for match in matches {
                if let urlRange = Range(match.range, in: body) {
                    let urlString = decodeHTMLEntities(String(body[urlRange]))
                    guard let url = URL(string: urlString) else { continue }

                    if imageURLs.contains(url) || isImageURLString(url.absoluteString) {
                        continue
                    }

                    if !links.contains(where: { $0.url == url }) {
                        links.append(RedditCommentLink(
                            id: "\(links.count)-\(url.absoluteString)",
                            text: "",
                            url: url
                        ))
                    }
                }
            }
        }

        return links
    }

    private static func formatBodyBlocks(from body: String) -> [AttributedString] {
        let markdownContent = body
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "(?i)\\[[^\\]]+\\]\\((https?://[^\\)]*\\.(?:jpg|jpeg|png|gif|webp)(?:\\?[^\\)]*)?)\\)",
                                  with: "",
                                  options: .regularExpression)
            .replacingOccurrences(of: "(?i)\\[[^\\]]+\\]\\((https?://(?:i\\.redd\\.it|v\\.redd\\.it|preview\\.redd\\.it)/[^\\)]+)\\)",
                                  with: "",
                                  options: .regularExpression)
            .replacingOccurrences(of: "(?i)\\[[^\\]]+\\]\\((https?://(?:giphy\\.com|gfycat\\.com|imgur\\.com)/[^\\)]+)\\)",
                                  with: "",
                                  options: .regularExpression)
            .replacingOccurrences(of: "(?i)(https?://[^\\s]+\\.(?:jpg|jpeg|png|gif|webp))(?![^\\(\\)]*\\))",
                                  with: "",
                                  options: .regularExpression)
            .replacingOccurrences(of: "(?i)(https?://(?:i\\.redd\\.it|v\\.redd\\.it|preview\\.redd\\.it)/[^\\s]+)(?![^\\(\\)]*\\))",
                                  with: "",
                                  options: .regularExpression)
            .replacingOccurrences(of: "(?i)(https?://(?:giphy\\.com|gfycat\\.com|imgur\\.com)/[^\\s]+)(?![^\\(\\)]*\\))",
                                  with: "",
                                  options: .regularExpression)
            .replacingOccurrences(of: "(?i)\\?[^\\s]*(?:width|format|auto|s)=[^\\s]*",
                                  with: "",
                                  options: .regularExpression)
            .replacingOccurrences(of: "[ \\t]{2,}", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "[ \\t]*\\n[ \\t]*\\n[ \\t]*", with: "\n\n", options: .regularExpression)
            .replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
            .replacingOccurrences(of: "(?i)(https?://[^\\s]+)(?![^\\(\\)]*\\))(?![!\\[])",
                                  with: "[$1]($1)",
                                  options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let blocks = markdownContent
            .components(separatedBy: CharacterSet.newlines)
            .reduce(into: [String]()) { partialResult, line in
                let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)

                if trimmedLine.isEmpty {
                    if partialResult.last != "" {
                        partialResult.append("")
                    }
                } else if partialResult.last == nil || partialResult.last == "" {
                    partialResult.append(trimmedLine)
                } else {
                    partialResult[partialResult.count - 1] += "\n" + trimmedLine
                }
            }
            .filter { !$0.isEmpty }

        return blocks.map { block in
            (try? AttributedString(markdown: block)) ?? AttributedString(block)
        }
    }

    /// Extracts URLs from the comment that are not image links.
    var nonImageLinks: [URL] {
        displayLinks.map(\.url)
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
        let preparedBodyBlocks = Self.formatBodyBlocks(from: body)
        let preparedImageURLs = Self.extractImageURLs(from: body)
        let preparedDisplayLinks = Self.extractDisplayLinks(from: body, excludingImageURLs: preparedImageURLs)

        self.id = id
        self.author = author
        self.body = body
        self.score = score
        self.createdUtc = createdUtc
        self.replies = replies
        self.indentationLevel = indentationLevel
        self.bodyBlocks = preparedBodyBlocks
        self.imageURLs = preparedImageURLs
        self.displayLinks = preparedDisplayLinks
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
