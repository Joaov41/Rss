import SwiftUI
import Kingfisher

// Make URL conform to Identifiable for sheet presentation
extension URL: Identifiable {
    public var id: String { self.absoluteString }
}

// Clickable image component with its own sheet state
struct ClickableCommentImage: View {
    let url: URL
    @State private var showFullScreen = false
    
    var body: some View {
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
            .onTapGesture {
                showFullScreen = true
            }
            .sheet(isPresented: $showFullScreen) {
                ImagePopupView(imageURL: url)
            }
    }
}

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
                        .onAppear {
                            if comment.body.lowercased().contains(".jpg") || 
                               comment.body.lowercased().contains(".png") || 
                               comment.body.lowercased().contains(".gif") {
                                print("🔵 Comment contains image extensions. Body preview: \(String(comment.body.prefix(200)))")
                                print("🔵 Image URLs found: \(comment.imageURLs)")
                            }
                        }
                    
                    // Display images if they exist in the comment
                    let imageURLs = comment.imageURLs
                    if !imageURLs.isEmpty {
                        Text("Found \(imageURLs.count) images in this comment")
                            .foregroundColor(.green)
                            .font(.caption)
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(spacing: 12) {
                                ForEach(comment.imageURLs.prefix(5), id: \.absoluteString) { url in
                                    ClickableCommentImage(url: url)
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

// Image popup view for displaying images in fullscreen
struct ImagePopupView: View {
    let imageURL: URL
    @Environment(\.presentationMode) var presentationMode
    @State private var scale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    @State private var isImageLoaded = false
    
    var body: some View {
        ZStack {
            Color.black
                .edgesIgnoringSafeArea(.all)
            
            GeometryReader { geometry in
                VStack {
                    // Header
                    HStack {
                        Button("Close") {
                            presentationMode.wrappedValue.dismiss()
                        }
                        .foregroundColor(.white)
                        .padding()
                        
                        Spacer()
                        
                        Button(action: {
                            #if os(iOS)
                            UIApplication.shared.open(imageURL)
                            #else
                            NSWorkspace.shared.open(imageURL)
                            #endif
                        }) {
                            Image(systemName: "safari")
                                .foregroundColor(.white)
                        }
                        .padding()
                    }
                    
                    // Scrollable image with zoom
                    ScrollView([.horizontal, .vertical], showsIndicators: false) {
                        KFImage(imageURL)
                            .resizable()
                            .placeholder {
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                    .scaleEffect(1.5)
                            }
                            .aspectRatio(contentMode: .fit)
                            .frame(width: geometry.size.width, height: geometry.size.height)
                            .scaleEffect(scale)
                            .offset(offset)
                            .gesture(
                                MagnificationGesture()
                                    .onChanged { value in
                                        let delta = value / lastScale
                                        lastScale = value
                                        scale = min(max(scale * delta, 1), 4)
                                    }
                                    .onEnded { _ in
                                        lastScale = 1.0
                                        withAnimation(.spring()) {
                                            if scale < 1 {
                                                scale = 1
                                                offset = .zero
                                            }
                                        }
                                    }
                            )
                            .simultaneousGesture(
                                DragGesture()
                                    .onChanged { value in
                                        offset = CGSize(
                                            width: lastOffset.width + value.translation.width,
                                            height: lastOffset.height + value.translation.height
                                        )
                                    }
                                    .onEnded { _ in
                                        lastOffset = offset
                                    }
                            )
                            .onTapGesture(count: 2) {
                                withAnimation(.spring()) {
                                    if scale > 1 {
                                        scale = 1
                                        offset = .zero
                                        lastOffset = .zero
                                    } else {
                                        scale = 2
                                    }
                                }
                            }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }
}
