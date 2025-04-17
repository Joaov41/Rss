import SwiftUI
import Kingfisher

// Represents a link with text and URL
struct LinkInfo: Identifiable {
    let id = UUID()
    let text: String
    let url: URL
}

struct CommentView: View {
    let comment: RedditCommentModel
    @State private var isCollapsed = false
    
    // Limit depth rendering for better performance
    private var shouldLimitReplies: Bool {
        return comment.indentationLevel >= 8 || comment.replies.count > 50
    }
    
    private var visibleReplies: [RedditCommentModel] {
        if shouldLimitReplies && !isCollapsed {
            // If we're limiting replies, only show the first few
            return Array(comment.replies.prefix(5))
        }
        return comment.replies
    }
    
    /// Extracts non-image links from comment text
    private func extractNonImageLinks(from text: String) -> [LinkInfo] {
        var links = [LinkInfo]()
        
        // Match markdown links [text](url)
        let markdownPattern = "\\[([^\\]]+)\\]\\(([^\\)]+)\\)"
        if let regex = try? NSRegularExpression(pattern: markdownPattern) {
            let range = NSRange(text.startIndex..., in: text)
            let matches = regex.matches(in: text, options: [], range: range)
            
            for match in matches {
                if match.numberOfRanges >= 3,
                   let textRange = Range(match.range(at: 1), in: text),
                   let urlRange = Range(match.range(at: 2), in: text),
                   let url = URL(string: String(text[urlRange])) {
                    
                    // Skip image URLs
                    let urlString = url.absoluteString.lowercased()
                    if urlString.hasSuffix(".jpg") || urlString.hasSuffix(".jpeg") ||
                       urlString.hasSuffix(".png") || urlString.hasSuffix(".gif") ||
                       urlString.hasSuffix(".webp") {
                        continue
                    }
                    
                    let linkText = String(text[textRange])
                    links.append(LinkInfo(text: linkText, url: url))
                }
            }
        }
        
        // Match plain URLs
        let urlPattern = "(?i)(https?://[^\\s]+)(?![^\\(\\)]*\\))(?![!\\[])"
        if let regex = try? NSRegularExpression(pattern: urlPattern) {
            let range = NSRange(text.startIndex..., in: text)
            let matches = regex.matches(in: text, options: [], range: range)
            
            for match in matches {
                if let urlRange = Range(match.range, in: text),
                   let url = URL(string: String(text[urlRange])) {
                    
                    // Skip image URLs
                    let urlString = url.absoluteString.lowercased()
                    if urlString.hasSuffix(".jpg") || urlString.hasSuffix(".jpeg") ||
                       urlString.hasSuffix(".png") || urlString.hasSuffix(".gif") ||
                       urlString.hasSuffix(".webp") {
                        continue
                    }
                    
                    // Check if this URL is already included in a markdown link
                    if !links.contains(where: { $0.url == url }) {
                        links.append(LinkInfo(text: "", url: url))
                    }
                }
            }
        }
        
        return links
    }
    
    /// Formats a comment body text by enhancing URLs and images for markdown rendering
    private func formatCommentBody(_ body: String) -> AttributedString {
        // Convert comment to markdown for proper rendering
        let markdownContent = body
            // Make image URLs display as markdown images
            .replacingOccurrences(of: "(?i)(https?://[^\\s]+\\.(?:jpg|jpeg|png|gif|webp))(?![^\\(\\)]*\\))", 
                                  with: "![]($1)", 
                                  options: .regularExpression)
            // Make links more readable by wrapping them in markdown link syntax
            .replacingOccurrences(of: "(?i)(https?://[^\\s]+)(?![^\\(\\)]*\\))(?![!\\[])", 
                                  with: "[$1]($1)", 
                                  options: .regularExpression)
        
        do {
            return try AttributedString(markdown: markdownContent)
        } catch {
            return AttributedString(body)
        }
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(action: {
                isCollapsed.toggle()
            }) {
                HStack {
                    Text("u/\(comment.author)")
                        .fontWeight(.semibold)
                    
                    Text("• \(comment.score) points")
                        .foregroundColor(.secondary)
                    
                    Text("• \(comment.createdDate, style: .relative)")
                        .foregroundColor(.secondary)
                    
                    Spacer()
                    
                    if !comment.replies.isEmpty {
                        Text("(\(comment.replies.count))")
                            .foregroundColor(.secondary)
                            .font(.caption)
                    }
                    
                    Image(systemName: isCollapsed ? "chevron.down" : "chevron.up")
                        .foregroundColor(.secondary)
                }
            }
            .buttonStyle(PlainButtonStyle())
            
            if !isCollapsed {
                VStack(alignment: .leading, spacing: 8) {
                    // Display the comment body with markdown support
                    Text(formatCommentBody(comment.body))
                        .padding(.vertical, 4)
                        .textSelection(.enabled)
                    
                    // Display images if they exist in the comment
                    if !comment.imageURLs.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(spacing: 12) {
                                ForEach(comment.imageURLs.prefix(5), id: \.absoluteString) { url in
                                    Button(action: {
                                        #if os(macOS)
                                        NSWorkspace.shared.open(url)
                                        #else
                                        UIApplication.shared.open(url)
                                        #endif
                                    }) {
                                        KFImage(url)
                                            .placeholder {
                                                Rectangle()
                                                    .fill(Color.gray.opacity(0.1))
                                                    .frame(width: 120, height: 120)
                                                    .cornerRadius(8)
                                                    .overlay(
                                                        ProgressView()
                                                    )
                                            }
                                            .fade(duration: 0.25)
                                            .resizable()
                                            .aspectRatio(contentMode: .fill)
                                            .frame(width: 120, height: 120)
                                            .cornerRadius(8)
                                            .clipped()
                                    }
                                    .buttonStyle(PlainButtonStyle())
                                }
                            }
                            .padding(.vertical, 8)
                        }
                        .frame(height: 140)
                    }
                    
                    // Display non-image links if they exist (limited to first few for performance)
                    let nonImageLinks = extractNonImageLinks(from: comment.body).prefix(3)
                    if !nonImageLinks.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(nonImageLinks), id: \.id) { link in
                                Link(destination: link.url) {
                                    HStack {
                                        Image(systemName: "link")
                                            .foregroundColor(.blue)
                                        Text(link.text.isEmpty ? link.url.absoluteString : link.text)
                                            .foregroundColor(.blue)
                                            .underline()
                                            .lineLimit(1)
                                    }
                                }
                                .padding(.leading, 4)
                            }
                        }
                    }
                }
                
                // Display replies with an option to show more if needed
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(visibleReplies) { reply in
                        CommentView(comment: reply)
                    }
                    
                    if shouldLimitReplies && comment.replies.count > 5 {
                        Button(action: {
                            // Toggle collapsed state to show all replies
                            isCollapsed.toggle()
                        }) {
                            HStack {
                                Text("Show \(comment.replies.count - 5) more replies...")
                                Image(systemName: "chevron.down")
                            }
                            .foregroundColor(.blue)
                            .padding(.vertical, 4)
                            .padding(.leading, 16)
                        }
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .padding(.leading, min(CGFloat(comment.indentationLevel) * 12, 60)) // Cap indentation for deep nesting
    }
}

struct CommentThreadView: View {
    let comments: [RedditCommentModel]
    
    var body: some View {
        LazyVStack(alignment: .leading, spacing: 8) {
            ForEach(comments) { comment in
                CommentView(comment: comment)
                Divider()
            }
        }
    }
}

struct CommentSummaryView: View {
    let summary: CommentSummary
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Comment Summary")
                .font(.headline)
            
            Text(summary.summary)
                .padding()
                .background(Color.secondary.opacity(0.1))
                .cornerRadius(8)
            
            HStack {
                Text("Sentiment: ")
                    .fontWeight(.semibold)
                
                Text(summary.sentiment.rawValue.capitalized)
                    .foregroundColor(sentimentColor(summary.sentiment))
            }
            
            if !summary.topCommenters.isEmpty {
                VStack(alignment: .leading) {
                    Text("Top Commenters:")
                        .fontWeight(.semibold)
                    
                    ForEach(summary.topCommenters, id: \.self) { commenter in
                        Text("• u/\(commenter)")
                    }
                }
            }
            
            if !summary.mainTopics.isEmpty {
                VStack(alignment: .leading) {
                    Text("Main Topics:")
                        .fontWeight(.semibold)
                    
                    Text(summary.mainTopics.joined(separator: ", "))
                }
            }
            
            Text("Based on \(summary.commentCount) comments")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding()
        .background(Color.secondary.opacity(0.05))
        .cornerRadius(12)
    }
    
    private func sentimentColor(_ sentiment: CommentSummary.CommentSentiment) -> Color {
        switch sentiment {
        case .positive:
            return .green
        case .negative:
            return .red
        case .mixed:
            return .orange
        case .neutral:
            return .gray
        }
    }
}
