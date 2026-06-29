import SwiftUI
import Kingfisher
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

// Make URL conform to Identifiable for sheet presentation
extension URL: Identifiable {
    public var id: String { self.absoluteString }
}

// Clickable image component with its own sheet state
struct ClickableCommentImage: View {
    let url: URL
    @State private var showFullScreen = false
    
    // Check if URL is a GIF
    private var isGIF: Bool {
        let urlString = url.absoluteString.lowercased()
        return urlString.contains(".gif") || 
               urlString.contains("giphy.com") || 
               urlString.contains("gfycat.com") || 
               urlString.contains("imgur.com") ||
               urlString.contains("v.redd.it") ||
               urlString.contains("media.giphy.com") ||
               urlString.contains("giant.gfycat.com") ||
               urlString.contains("i.imgur.com")
    }
    
    private var isRunningIOSOnMac: Bool {
        #if os(iOS)
        return ProcessInfo.processInfo.isiOSAppOnMac
        #else
        return false
        #endif
    }
    
    var body: some View {
        Group {
            if isRunningIOSOnMac {
                // Use simple AsyncImage on Mac to avoid Kingfisher Metal crashes
                AsyncImage(url: url) { image in
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } placeholder: {
                    Rectangle()
                        .fill(Color.gray.opacity(0.1))
                        .overlay(ProgressView())
                }
                .frame(width: 120, height: 120)
                .cornerRadius(8)
                .clipped()
            } else if isGIF {
                // Use animated image for GIFs (iOS only); fallback to static on macOS
                #if os(iOS)
                KFAnimatedImage(url)
                    .placeholder {
                        Rectangle()
                            .fill(Color.gray.opacity(0.1))
                            .frame(width: 120, height: 120)
                            .cornerRadius(8)
                            .overlay(
                                VStack {
                                    ProgressView()
                                    Text("GIF")
                                        .font(.caption2)
                                        .foregroundColor(.gray)
                                }
                            )
                    }
                    .fade(duration: 0.25)
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 120, height: 120)
                    .cornerRadius(8)
                    .clipped()
                    .onAppear {
                        print("🎬 Loading animated GIF: \(url.absoluteString)")
                    }
                #else
                KFImage(url)
                    .placeholder {
                        Rectangle()
                            .fill(Color.gray.opacity(0.1))
                            .frame(width: 120, height: 120)
                            .cornerRadius(8)
                            .overlay(
                                VStack {
                                    ProgressView()
                                    Text("GIF")
                                        .font(.caption2)
                                        .foregroundColor(.gray)
                                }
                            )
                    }
                    .fade(duration: 0.25)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 120, height: 120)
                    .cornerRadius(8)
                    .clipped()
                #endif
            } else {
                // Use regular image for non-GIFs
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
        }
        .onTapGesture {
            showFullScreen = true
        }
        #if os(iOS)
        .fullScreenCover(isPresented: $showFullScreen) {
            ImagePopupView(imageURL: url)
        }
        #else
        .sheet(isPresented: $showFullScreen) {
            // macOS: Present as a medium overlay centred on screen
            let screen = NSScreen.main?.visibleFrame ?? NSScreen.main?.frame ?? .zero
            let preferredWidth = max(min(screen.width * 0.55, 820), 460)
            let preferredHeight = max(min(screen.height * 0.65, 820), 420)
            ImagePopupView(imageURL: url)
                .frame(width: preferredWidth, height: preferredHeight)
                .background(Color.black.opacity(0.9))
                .cornerRadius(20)
        }
        #endif
    }
}

// Represents a link with text and URL
struct LinkInfo: Identifiable {
    let id = UUID()
    let text: String
    let url: URL
}

struct CommentView: View {
    @EnvironmentObject private var appState: AppState
    let comment: RedditCommentModel
    let post: RedditPost
    @State private var isCollapsed = false
    @State private var avatarURL: URL?
    @State private var avatarLookupCompleted = false
    @State private var voteDirection: RedditVoteDirection = .none
    @State private var isSubmittingVote = false
    @State private var showReplySheet = false
    @State private var actionErrorMessage: String?
    @Environment(\.openURL) private var openURL
    
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

    private var commentURL: URL {
        URL(string: "https://www.reddit.com/r/\(post.subreddit)/comments/\(post.id)/-/\(comment.id)/?context=3")!
    }

    private var displayedScore: Int {
        comment.score + voteDirection.rawValue
    }
    
    /// Extracts non-image links from comment text, excluding already detected image URLs
    private func extractNonImageLinks(from text: String, excludingImageURLs imageURLs: [URL] = []) -> [LinkInfo] {
        var links = [LinkInfo]()
        
        print("🔗 extractNonImageLinks analyzing text: \(String(text.prefix(200)))")
        print("🔗 Excluding \(imageURLs.count) detected image URLs: \(imageURLs.map { $0.absoluteString })")
        
        // Match markdown links [text](url)
        let markdownPattern = "\\[([^\\]]+)\\]\\(([^\\)]+)\\)"
        if let regex = try? NSRegularExpression(pattern: markdownPattern) {
            let range = NSRange(text.startIndex..., in: text)
            let matches = regex.matches(in: text, options: [], range: range)
            
            print("🔗 Found \(matches.count) markdown links")
            
            for match in matches {
                if match.numberOfRanges >= 3,
                   let textRange = Range(match.range(at: 1), in: text),
                   let urlRange = Range(match.range(at: 2), in: text),
                   let url = URL(string: String(text[urlRange])) {
                    
                    let linkText = String(text[textRange])
                    let urlString = url.absoluteString.lowercased()
                    
                    print("🔗 Checking markdown link: [\(linkText)](\(url.absoluteString))")
                    
                    // Skip URLs that are already detected as images
                    if imageURLs.contains(url) {
                        print("🚫 Skipping already detected image URL: \(url.absoluteString)")
                        continue
                    }
                    
                    // Skip image URLs (both direct extensions and Reddit image URLs)
                    if urlString.hasSuffix(".jpg") || urlString.hasSuffix(".jpeg") ||
                       urlString.hasSuffix(".png") || urlString.hasSuffix(".gif") ||
                       urlString.hasSuffix(".webp") ||
                       urlString.contains("preview.redd.it") ||
                       urlString.contains("i.redd.it") ||
                       urlString.contains("v.redd.it") ||
                       urlString.contains("giphy.com") ||
                       urlString.contains("gfycat.com") ||
                       urlString.contains("imgur.com") {
                        print("🚫 Skipping image URL by pattern: \(url.absoluteString)")
                        continue
                    }
                    
                    print("✅ Adding non-image link: [\(linkText)](\(url.absoluteString))")
                    links.append(LinkInfo(text: linkText, url: url))
                }
            }
        }
        
        // Match plain URLs
        let urlPattern = "(?i)(https?://[^\\s]+)(?![^\\(\\)]*\\))(?![!\\[])"
        if let regex = try? NSRegularExpression(pattern: urlPattern) {
            let range = NSRange(text.startIndex..., in: text)
            let matches = regex.matches(in: text, options: [], range: range)
            
            print("🔗 Found \(matches.count) plain URLs")
            
            for match in matches {
                if let urlRange = Range(match.range, in: text),
                   let url = URL(string: String(text[urlRange])) {
                    
                    let urlString = url.absoluteString.lowercased()
                    print("🔗 Checking plain URL: \(url.absoluteString)")
                    
                    // Skip URLs that are already detected as images
                    if imageURLs.contains(url) {
                        print("🚫 Skipping already detected plain image URL: \(url.absoluteString)")
                        continue
                    }
                    
                    // Skip image URLs (both direct extensions and Reddit image URLs)
                    if urlString.hasSuffix(".jpg") || urlString.hasSuffix(".jpeg") ||
                       urlString.hasSuffix(".png") || urlString.hasSuffix(".gif") ||
                       urlString.hasSuffix(".webp") ||
                       urlString.contains("preview.redd.it") ||
                       urlString.contains("i.redd.it") ||
                       urlString.contains("v.redd.it") ||
                       urlString.contains("giphy.com") ||
                       urlString.contains("gfycat.com") ||
                       urlString.contains("imgur.com") {
                        print("🚫 Skipping plain image URL by pattern: \(url.absoluteString)")
                        continue
                    }
                    
                    // Check if this URL is already included in a markdown link
                    if !links.contains(where: { $0.url == url }) {
                        print("✅ Adding plain URL: \(url.absoluteString)")
                        links.append(LinkInfo(text: "", url: url))
                    } else {
                        print("⚠️ URL already exists as markdown link: \(url.absoluteString)")
                    }
                }
            }
        }
        
        print("🎯 extractNonImageLinks returning \(links.count) links")
        return links
    }
    
    /// Formats a comment body text into paragraph blocks for markdown rendering.
    private func formatCommentBodyBlocks(_ body: String) -> [AttributedString] {
        print("🧹 formatCommentBody input: \(String(body.prefix(200)))")
        
        // Convert comment to markdown for proper rendering
        let markdownContent = body
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            // Remove markdown links containing image URLs [text](image_url)
            .replacingOccurrences(of: "(?i)\\[[^\\]]+\\]\\((https?://[^\\)]*\\.(?:jpg|jpeg|png|gif|webp)(?:\\?[^\\)]*)?)\\)", 
                                  with: "", 
                                  options: .regularExpression)
            // Remove markdown links containing Reddit image URLs [text](reddit_image_url)
            .replacingOccurrences(of: "(?i)\\[[^\\]]+\\]\\((https?://(?:i\\.redd\\.it|v\\.redd\\.it|preview\\.redd\\.it)/[^\\)]+)\\)", 
                                  with: "", 
                                  options: .regularExpression)
            // Remove markdown links containing GIF hosting URLs [text](gif_hosting_url)
            .replacingOccurrences(of: "(?i)\\[[^\\]]+\\]\\((https?://(?:giphy\\.com|gfycat\\.com|imgur\\.com)/[^\\)]+)\\)", 
                                  with: "", 
                                  options: .regularExpression)
            // Remove plain image URLs that are not in markdown links
            .replacingOccurrences(of: "(?i)(https?://[^\\s]+\\.(?:jpg|jpeg|png|gif|webp))(?![^\\(\\)]*\\))", 
                                  with: "", 
                                  options: .regularExpression)
            // Remove plain Reddit image URLs that are not in markdown links
            .replacingOccurrences(of: "(?i)(https?://(?:i\\.redd\\.it|v\\.redd\\.it|preview\\.redd\\.it)/[^\\s]+)(?![^\\(\\)]*\\))", 
                                  with: "", 
                                  options: .regularExpression)
            // Remove plain GIF hosting URLs that are not in markdown links
            .replacingOccurrences(of: "(?i)(https?://(?:giphy\\.com|gfycat\\.com|imgur\\.com)/[^\\s]+)(?![^\\(\\)]*\\))", 
                                  with: "", 
                                  options: .regularExpression)
            // Remove orphaned Reddit image URL parameters (like ?width=2048&format=png&auto=webp&s=...)
            .replacingOccurrences(of: "(?i)\\?[^\\s]*(?:width|format|auto|s)=[^\\s]*", 
                                  with: "", 
                                  options: .regularExpression)
            // Preserve paragraph breaks while cleaning up excess inline whitespace.
            .replacingOccurrences(of: "[ \\t]{2,}", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "[ \\t]*\\n[ \\t]*\\n[ \\t]*", with: "\n\n", options: .regularExpression)
            .replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
            // Make remaining links more readable by wrapping them in markdown link syntax
            .replacingOccurrences(of: "(?i)(https?://[^\\s]+)(?![^\\(\\)]*\\))(?![!\\[])", 
                                  with: "[$1]($1)", 
                                  options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        
        print("🧹 formatCommentBody output: \(String(markdownContent.prefix(200)))")

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

        if blocks.isEmpty {
            return []
        }

        return blocks.map { block in
            do {
                return try AttributedString(markdown: block)
            } catch {
                print("⚠️ formatCommentBody markdown parsing failed for block: \(error)")
                return AttributedString(block)
            }
        }
    }

    @Environment(\.colorScheme) private var colorScheme

    private var depth: Int {
        min(max(comment.indentationLevel, 0), 6)
    }

    private var leadingIndent: CGFloat {
        min(CGFloat(depth) * 26, 84)
    }

    private var accentColor: Color {
        Color(red: 0.53, green: 0.25, blue: 1.0)
    }

    private var cardFill: Color {
        colorScheme == .dark
            ? Color(red: 0.055, green: 0.06, blue: 0.085)
            : Color.white.opacity(0.92)
    }

    private var cardBorder: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.08)
            : Color.black.opacity(0.08)
    }

    private var metadataColor: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.58)
            : Color.black.opacity(0.52)
    }

    private var replyRailColor: Color {
        accentColor.opacity(colorScheme == .dark ? 0.85 : 0.6)
    }

    private var avatarGradient: LinearGradient {
        let palette: [[Color]] = [
            [Color(red: 0.12, green: 0.72, blue: 0.78), Color(red: 0.08, green: 0.38, blue: 0.58)],
            [Color(red: 0.47, green: 0.28, blue: 0.92), Color(red: 0.26, green: 0.18, blue: 0.58)],
            [Color(red: 0.18, green: 0.72, blue: 0.36), Color(red: 0.08, green: 0.38, blue: 0.24)],
            [Color(red: 0.94, green: 0.38, blue: 0.18), Color(red: 0.55, green: 0.16, blue: 0.1)]
        ]
        let checksum = comment.author.unicodeScalars.reduce(0) { $0 + Int($1.value) }
        let colors = palette[checksum % palette.count]
        return LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    private var commentHeader: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.18)) {
                isCollapsed.toggle()
            }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text("u/\(comment.author)")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.primary)
                    .lineLimit(1)

                Text("•")
                    .font(.caption)
                    .foregroundColor(metadataColor)

                Text("\(displayedScore) \(displayedScore == 1 ? "point" : "points")")
                    .font(.system(size: 14))
                    .foregroundColor(metadataColor)
                    .lineLimit(1)

                Text("•")
                    .font(.caption)
                    .foregroundColor(metadataColor)

                Text(comment.createdDate, style: .relative)
                    .font(.system(size: 14))
                    .foregroundColor(metadataColor)
                    .lineLimit(1)

                Spacer(minLength: 8)

                if !comment.replies.isEmpty {
                    Text("\(comment.replies.count)")
                        .font(.caption)
                        .foregroundColor(metadataColor)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Capsule()
                                .fill(metadataColor.opacity(0.12))
                        )
                }

                Image(systemName: isCollapsed ? "chevron.down" : "chevron.up")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(metadataColor)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isCollapsed ? "Expand comment" : "Collapse comment")
    }

    private var avatarView: some View {
        ZStack {
            if let avatarURL {
                KFImage(avatarURL)
                    .placeholder {
                        fallbackAvatar
                    }
                    .cancelOnDisappear(true)
                    .fade(duration: 0.2)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 44, height: 44)
                    .clipShape(Circle())
            } else {
                fallbackAvatar
            }

            Circle()
                .stroke(Color.white.opacity(colorScheme == .dark ? 0.18 : 0.7), lineWidth: 1)
        }
        .frame(width: 44, height: 44)
        .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.28 : 0.12), radius: 6, x: 0, y: 3)
        .task(id: comment.author) {
            await loadAvatarIfNeeded()
        }
        .accessibilityHidden(true)
    }

    private var fallbackAvatar: some View {
        ZStack {
            Circle()
                .fill(avatarGradient)

            Image("RedditLogo")
                .resizable()
                .scaledToFit()
                .foregroundColor(.white)
                .frame(width: 24, height: 24)
        }
        .frame(width: 44, height: 44)
    }

    @MainActor
    private func loadAvatarIfNeeded() async {
        guard !avatarLookupCompleted else { return }
        avatarLookupCompleted = true
        avatarURL = await appState.redditService.fetchUserAvatarURL(author: comment.author)
    }

    @ViewBuilder
    private var commentBodyContent: some View {
        let bodyBlocks = formatCommentBodyBlocks(comment.body)
        if !bodyBlocks.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(bodyBlocks.enumerated()), id: \.offset) { _, block in
                    Text(block)
                        .font(.system(size: 16))
                        .lineSpacing(3)
                        .foregroundColor(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .textSelection(.enabled)
            .onAppear {
                if comment.body.lowercased().contains(".jpg") ||
                   comment.body.lowercased().contains(".png") ||
                   comment.body.lowercased().contains(".gif") {
                    print("🔵 Comment contains image extensions. Body preview: \(String(comment.body.prefix(200)))")
                    print("🔵 Image URLs found: \(comment.imageURLs)")
                }
            }
        }
    }

    @ViewBuilder
    private var commentImages: some View {
        let imageURLs = comment.imageURLs
        if !imageURLs.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("\(imageURLs.count) \(imageURLs.count == 1 ? "image" : "images")")
                    .font(.caption)
                    .foregroundColor(metadataColor)

                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 12) {
                        ForEach(comment.imageURLs.prefix(5), id: \.absoluteString) { url in
                            ClickableCommentImage(url: url)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(height: 136)
            }
        }
    }

    @ViewBuilder
    private var commentLinks: some View {
        let nonImageLinks = extractNonImageLinks(from: comment.body, excludingImageURLs: comment.imageURLs).prefix(3)
        if !nonImageLinks.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(nonImageLinks), id: \.id) { link in
                    Link(destination: link.url) {
                        HStack(spacing: 6) {
                            Image(systemName: "link")
                                .font(.caption)
                            Text(link.text.isEmpty ? link.url.absoluteString : link.text)
                                .font(.caption)
                                .lineLimit(1)
                        }
                        .foregroundColor(.blue)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            Capsule()
                                .fill(Color.blue.opacity(colorScheme == .dark ? 0.16 : 0.1))
                        )
                    }
                }
            }
        }
    }

    private var commentActionRow: some View {
        HStack(spacing: 12) {
            Button {
                Task {
                    await submitVote(.up)
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 16, weight: .bold))
                    Text("\(displayedScore)")
                        .font(.system(size: 14, weight: .semibold))
                }
            }
            .buttonStyle(.plain)
            .foregroundColor(voteDirection == .up ? accentColor : metadataColor)
            .disabled(isSubmittingVote)

            Button {
                Task {
                    await submitVote(.down)
                }
            } label: {
                Image(systemName: "arrow.down")
                    .font(.system(size: 16, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundColor(voteDirection == .down ? accentColor : metadataColor)
            .disabled(isSubmittingVote)

            Button {
                showReplySheet = true
            } label: {
                Label("Reply", systemImage: "bubble")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.plain)
            .foregroundColor(metadataColor)

            ShareLink(item: commentURL) {
                Label("Share", systemImage: "square.and.arrow.up")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.plain)
            .foregroundColor(metadataColor)

            Menu {
                Button {
                    openURL(commentURL)
                } label: {
                    Label("Open Comment", systemImage: "safari")
                }

                Button {
                    copyCommentLink()
                } label: {
                    Label("Copy Link", systemImage: "doc.on.doc")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 16, weight: .semibold))
            }
            .menuStyle(.borderlessButton)
            .foregroundColor(metadataColor)
        }
        .font(.system(size: 14, weight: .medium))
        .lineLimit(1)
        .minimumScaleFactor(0.75)
        .padding(.top, 2)
        .sheet(isPresented: $showReplySheet) {
            RedditCommentReplySheet(comment: comment) { body in
                try await appState.redditService.replyToComment(commentID: comment.id, body: body)
            }
        }
    }

    @MainActor
    private func submitVote(_ direction: RedditVoteDirection) async {
        guard !isSubmittingVote else { return }
        isSubmittingVote = true

        let previousDirection = voteDirection
        let newDirection: RedditVoteDirection = previousDirection == direction ? .none : direction
        voteDirection = newDirection

        do {
            try await appState.redditService.voteComment(commentID: comment.id, direction: newDirection)
        } catch {
            voteDirection = previousDirection
            actionErrorMessage = error.localizedDescription
        }

        isSubmittingVote = false
    }

    private func copyCommentLink() {
        #if os(iOS)
        UIPasteboard.general.string = commentURL.absoluteString
        #elseif os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(commentURL.absoluteString, forType: .string)
        #endif
    }

    private var commentCard: some View {
        HStack(alignment: .top, spacing: 12) {
            avatarView

            VStack(alignment: .leading, spacing: 10) {
                commentHeader

                if !isCollapsed {
                    commentBodyContent
                    commentImages
                    commentLinks
                    commentActionRow
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(cardFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(cardBorder, lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.2 : 0.06), radius: 10, x: 0, y: 5)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                if depth > 0 {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(replyRailColor)
                        .frame(width: 3)
                        .padding(.vertical, 10)
                }

                commentCard
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.leading, leadingIndent)

            if !isCollapsed {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(visibleReplies) { reply in
                        CommentView(comment: reply, post: post)
                    }

                    if shouldLimitReplies && comment.replies.count > 5 {
                        Button(action: {
                            isCollapsed.toggle()
                        }) {
                            HStack(spacing: 6) {
                                Text("Show \(comment.replies.count - 5) more replies")
                                Image(systemName: "chevron.down")
                            }
                            .font(.caption.weight(.semibold))
                            .foregroundColor(accentColor)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(
                                Capsule()
                                    .fill(accentColor.opacity(0.12))
                            )
                        }
                        .buttonStyle(.plain)
                        .padding(.leading, leadingIndent + 44)
                    }
                }
            }
        }
        .padding(.vertical, 2)
        .alert("Comment Action Failed", isPresented: Binding(
            get: { actionErrorMessage != nil },
            set: { isPresented in
                if !isPresented {
                    actionErrorMessage = nil
                }
            }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(actionErrorMessage ?? "")
        }
    }
}

private struct RedditCommentReplySheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    let comment: RedditCommentModel
    let onSubmit: (String) async throws -> Void
    @State private var replyText = ""
    @State private var isSubmitting = false
    @State private var errorMessage: String?

    private var trimmedReply: String {
        replyText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSubmit: Bool {
        !trimmedReply.isEmpty && !isSubmitting
    }

    private var lavender: Color {
        Color(red: 0.79, green: 0.61, blue: 1.0)
    }

    private var panelBackground: LinearGradient {
        LinearGradient(
            colors: [
                Color(red: 0.055, green: 0.058, blue: 0.095),
                Color(red: 0.025, green: 0.026, blue: 0.047)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    var body: some View {
        Group {
            if colorScheme == .dark {
                darkReplyView
            } else {
                lightReplyView
            }
        }
    }

    private var darkReplyView: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(lavender)
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .background(
                    Capsule()
                        .fill(Color.white.opacity(0.09))
                        .overlay(Capsule().stroke(Color.white.opacity(0.06), lineWidth: 1))
                )
                .buttonStyle(.plain)

                Spacer()

                Text("Reply")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(.white.opacity(0.9))

                Spacer()

                Button {
                    Task {
                        await submitReply()
                    }
                } label: {
                    if isSubmitting {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 72)
                    } else {
                        Text("Submit")
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .frame(width: 72)
                    }
                }
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(canSubmit ? lavender : .white.opacity(0.28))
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .background(
                    Capsule()
                        .fill(Color.white.opacity(canSubmit ? 0.10 : 0.05))
                        .overlay(Capsule().stroke(Color.white.opacity(0.06), lineWidth: 1))
                )
                .buttonStyle(.plain)
                .disabled(!canSubmit)
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 22)

            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "arrowshape.turn.up.left.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(lavender)

                    Text("Replying to u/\(comment.author)")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(.white.opacity(0.84))
                        .lineLimit(1)
                }

                HStack(alignment: .top, spacing: 10) {
                    Capsule()
                        .fill(lavender.opacity(0.72))
                        .frame(width: 4)

                    Text(comment.body)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white.opacity(0.68))
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 18)

            Divider()
                .overlay(Color.white.opacity(0.08))

            ZStack(alignment: .topLeading) {
                if replyText.isEmpty {
                    Text("Write your reply...")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundColor(.white.opacity(0.72))
                        .padding(.horizontal, 25)
                        .padding(.vertical, 30)
                }

                TextEditor(text: $replyText)
                    .font(.system(size: 17))
                    .foregroundColor(.white.opacity(0.92))
                    .scrollContentBackground(.hidden)
                    .background(Color.clear)
                    .tint(lavender)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 22)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.red.opacity(0.92))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(Capsule().fill(Color.red.opacity(0.12)))
                    .padding(.horizontal, 24)
                    .padding(.bottom, 18)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minWidth: 700, minHeight: 560)
        .background(
            panelBackground
                .overlay(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.035),
                            Color(red: 0.35, green: 0.18, blue: 0.75).opacity(0.08),
                            Color.clear
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(Color.white.opacity(0.06), lineWidth: 1)
        )
        .presentationBackground(.clear)
    }

    private var lightReplyView: some View {
        NavigationView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Replying to u/\(comment.author)")
                    .font(.headline)

                Text(comment.body)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .lineLimit(4)
                    .padding(.bottom, 6)

                TextEditor(text: $replyText)
                    .frame(minHeight: 220)
                    .padding(8)
                    .background(Color.secondary.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundColor(.red)
                }
            }
            .padding()
            .navigationTitle("Reply")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Submit") {
                        Task {
                            await submitReply()
                        }
                    }
                    .disabled(!canSubmit)
                }
            }
        }
        .frame(minWidth: 560, minHeight: 420)
    }

    @MainActor
    private func submitReply() async {
        guard canSubmit else { return }
        isSubmitting = true
        errorMessage = nil

        do {
            try await onSubmit(trimmedReply)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }

        isSubmitting = false
    }
}

struct CommentThreadView: View {
    let comments: [RedditCommentModel]
    let post: RedditPost
    
    var body: some View {
        LazyVStack(alignment: .leading, spacing: 10) {
            ForEach(comments) { comment in
                CommentView(comment: comment, post: post)
            }
        }
        .padding(.vertical, 4)
    }
}

struct CommentSummaryView: View {
    let summary: CommentSummary
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Comment Summary")
                .font(.headline)
            
            Text(.init(summary.summary))
                .padding()
                .modifier(CommentGlassModifier(cornerRadius: 8))
            
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
        .modifier(CommentGlassModifier(cornerRadius: 12, isSubtle: true))
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
    @State private var zoomScale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0
    let minZoom: CGFloat = 0.5
    let maxZoom: CGFloat = 5.0
    
    // Check if URL is a GIF
    private var isGIF: Bool {
        let urlString = imageURL.absoluteString.lowercased()
        return urlString.contains(".gif") || 
               urlString.contains("giphy.com") || 
               urlString.contains("gfycat.com") || 
               urlString.contains("imgur.com") ||
               urlString.contains("v.redd.it") ||
               urlString.contains("media.giphy.com") ||
               urlString.contains("giant.gfycat.com") ||
               urlString.contains("i.imgur.com")
    }
    
    var body: some View {
        ZStack {
            Color.black
                .opacity(0.9)
                .ignoresSafeArea()

            GeometryReader { geometry in
                let size = geometry.size
                let maxDisplayWidth = min(size.width * 0.95, 960)
                let maxDisplayHeight = min(size.height * 0.95, 960)

                ScrollView([.horizontal, .vertical], showsIndicators: false) {
                    VStack {
                        Spacer(minLength: 0)
                        Group {
                            if isGIF {
                                // Use animated image for GIFs
                                KFAnimatedImage(imageURL)
                                    .placeholder {
                                        VStack {
                                            ProgressView()
                                                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                            Text("Loading GIF...")
                                                .foregroundColor(.white)
                                                .padding(.top)
                                        }
                                    }
                                    .cancelOnDisappear(true)
                                    .scaledToFit()
                                    .scaleEffect(zoomScale)
                            } else {
                                // Use regular image for non-GIFs
                                KFImage(imageURL)
                                    .resizable()
                                    .placeholder {
                                        ProgressView()
                                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                    }
                                    .cancelOnDisappear(true)
                                    .scaledToFit()
                                    .scaleEffect(zoomScale)
                            }
                        }
                        .frame(maxWidth: maxDisplayWidth, maxHeight: maxDisplayHeight)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .shadow(color: .black.opacity(0.4), radius: 20)
                        Spacer(minLength: 0)
                    }
                    .frame(minWidth: size.width, minHeight: size.height)
                    .padding()
                }
                .frame(width: size.width, height: size.height)
                .gesture(
                    MagnificationGesture()
                        .onChanged { value in
                            let newScale = lastScale * value
                            zoomScale = min(max(newScale, minZoom), maxZoom)
                        }
                        .onEnded { _ in
                            lastScale = zoomScale
                        }
                )
                .overlay(alignment: .topTrailing) {
                    Button(action: {
                        presentationMode.wrappedValue.dismiss()
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title)
                            .foregroundColor(.white)
                            .shadow(radius: 4)
                    }
                    .padding(.top, max(geometry.safeAreaInsets.top, 16))
                    .padding(.trailing, 16)
                }
                .onAppear {
                    zoomScale = 1.0
                    lastScale = 1.0
                }
            }
        }
    }
}

// Comment glass modifier for consistent glass effects with iOS 26 beta features
struct CommentGlassModifier: ViewModifier {
    let cornerRadius: CGFloat
    let isSubtle: Bool
    
    init(cornerRadius: CGFloat = 12, isSubtle: Bool = false) {
        self.cornerRadius = cornerRadius
        self.isSubtle = isSubtle
    }
    
    func body(content: Content) -> some View {
        if #available(iOS 15.0, macOS 12.0, *) {
            // Use material effects available in iOS 15+
            if isSubtle {
                content
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
                    .shadow(color: Color.black.opacity(0.1), radius: 2, x: 0, y: 1)
            } else {
                content
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
                    .shadow(color: Color.black.opacity(0.1), radius: 2, x: 0, y: 1)
            }
        } else {
            content
                .background(
                    Color.secondary.opacity(isSubtle ? 0.05 : 0.1)
                )
                .cornerRadius(cornerRadius)
        }
    }
}
