import SwiftUI
import Combine
import Kingfisher

struct RedditDetailView: View {
    @EnvironmentObject var appState: AppState
    @State private var comments: [RedditCommentModel] = []
    @State private var displayedComments: [RedditCommentModel] = []
    @State private var isLoadingComments = false
    @State private var commentSummary: CommentSummary?
    @State private var showCommentSummary = false
    @State private var cancellables = Set<AnyCancellable>()
    @State private var showMoreCommentsButton = false
    @State private var hasMoreCommentsToLoad = false
    
    // Default max number of comments to show
    private let maxDisplayComments = 50
    
    // Q&A states
    @State private var showQAInterface = false
    @State private var questionText = ""
    @State private var answerText = "Ask a question about this post or its comments..."
    @State private var isProcessingQuestion = false
    @State private var previousQuestionText: String? = nil
    
    // This is a key optimization - adding an ID to the view itself
    // forces the view to refresh when the post ID changes
    private var postId: String {
        appState.selectedRedditPost?.id ?? UUID().uuidString
    }
    
    // Track the view's creation time to help with debugging
    private let viewCreationTime = Date()
    
    var body: some View {
        // Directly use the post in our new navigation system
        Group {
            if let post = appState.selectedRedditPost {
                postDetailView(for: post)
                    .onAppear {
                        // Load comments when view appears
                        loadComments(for: post)
                        // Reset summary state to avoid doubles
                        commentSummary = nil
                        showCommentSummary = false
                    }
                    .onDisappear {
                        // Clean up when view disappears
                        cancellables.removeAll()
                        print("📱 RedditDetailView: View disappeared, canceling all requests")
                    }
            } else {
                Text("No post selected")
                    .font(.title)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onChange(of: appState.selectedRedditPost?.id) { newPostId in
            // Reload comments when selectedRedditPost changes
            if let newPostId = newPostId, let post = appState.selectedRedditPost {
                print("📱 RedditDetailView: Post selection changed to ID: \(newPostId)")
                
                // Reset all state
                self.comments = []
                self.commentSummary = nil
                self.showCommentSummary = false
                self.showQAInterface = false
                self.questionText = ""
                self.answerText = "Ask a question about this post or its comments..."
                
                // Cancel previous requests
                cancellables.removeAll()
                
                // Load the new post's comments
                loadComments(for: post)
            }
        }
    }
    
    private func postDetailView(for post: RedditPost) -> some View {
        ZStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                Button(action: {
                    if let url = post.url {
                        #if os(macOS)
                        NSWorkspace.shared.open(url)
                        #else
                        UIApplication.shared.open(url)
                        #endif
                    } else {
                        // Construct Reddit URL if direct URL is not available
                        let redditURL = URL(string: "https://www.reddit.com/r/\(post.subreddit)/comments/\(post.id)")!
                        #if os(macOS)
                        NSWorkspace.shared.open(redditURL)
                        #else
                        UIApplication.shared.open(redditURL)
                        #endif
                    }
                }) {
                    Text(post.title)
                        .font(.largeTitle)
                        .fontWeight(.bold)
                        .foregroundColor(.primary)
                        .multilineTextAlignment(.leading)
                }
                .buttonStyle(PlainButtonStyle())
                
                HStack {
                    Text("r/\(post.subreddit)")
                        .font(.subheadline)
                    Spacer()
                    Text(post.publishDate, style: .date)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                
                Text("Posted by u/\(post.author)")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                
                HStack {
                    Label("\(post.score)", systemImage: "arrow.up")
                    Label("\(post.commentCount) comments", systemImage: "bubble.right")
                }
                .font(.subheadline)
                .foregroundColor(.secondary)
                
                Divider()
                
                if let summary = post.summary {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Summary")
                            .font(.headline)
                        GlassySummary(summary: summary)
                    }
                    Divider()
                }
                
                if !post.content.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        // Display post content as formatted text
                        Text(formatRedditContent(post.content))
                            .font(.body)
                            .multilineTextAlignment(.leading)
                        
                        // Show the main image if available
                        if let mainImageURL = post.bestImageURL {
                            Button(action: {
                                #if os(macOS)
                                NSWorkspace.shared.open(mainImageURL)
                                #else
                                UIApplication.shared.open(mainImageURL)
                                #endif
                            }) {
                                KFImage(mainImageURL)
                                    .placeholder {
                                        VStack {
                                            ProgressView()
                                            Text("Loading image...")
                                                .foregroundColor(.secondary)
                                                .font(.caption)
                                        }
                                        .frame(height: 200)
                                        .frame(maxWidth: .infinity)
                                        .background(Color.gray.opacity(0.1))
                                        .cornerRadius(8)
                                    }
                                    .onFailure { error in
                                        print("Image loading error: \(error.localizedDescription)")
                                    }
                                    .fade(duration: 0.25)
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .cornerRadius(8)
                                    .shadow(color: Color.black.opacity(0.2), radius: 4, x: 0, y: 2)
                                    .frame(maxHeight: 400)
                            }
                            .buttonStyle(PlainButtonStyle())
                        }
                        
                        // Show additional images in a gallery if there are multiple
                        if post.allImageURLs.count > 1 {
                            VStack(alignment: .leading) {
                                Text("More Images:")
                                    .font(.headline)
                                    .padding(.top, 8)
                                
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 16) {
                                        ForEach(post.allImageURLs, id: \.absoluteString) { url in
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
                                                            .frame(width: 140, height: 140)
                                                            .cornerRadius(8)
                                                            .overlay(
                                                                ProgressView()
                                                            )
                                                    }
                                                    .onFailure { _ in
                                                        Rectangle()
                                                            .fill(Color.gray.opacity(0.3))
                                                            .frame(width: 140, height: 140)
                                                            .cornerRadius(8)
                                                            .overlay(
                                                                Image(systemName: "photo")
                                                                    .foregroundColor(.secondary)
                                                            )
                                                    }
                                                    .fade(duration: 0.25)
                                                    .resizable()
                                                    .aspectRatio(contentMode: .fill)
                                                    .frame(width: 140, height: 140)
                                                    .cornerRadius(8)
                                                    .clipped()
                                                    .shadow(color: Color.black.opacity(0.2), radius: 2, x: 0, y: 1)
                                            }
                                            .buttonStyle(PlainButtonStyle())
                                        }
                                    }
                                    .padding(.vertical, 8)
                                }
                            }
                        }
                    }
                    Divider()
                }
                
                if let url = post.url {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Source:")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                        
                        Link(url.absoluteString, destination: url)
                            .font(.subheadline)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .padding(.bottom, 8)
                    Divider()
                }
                
                if let summary = commentSummary {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Comment Summary")
                                .font(.headline)
                            Spacer()
                            Button(action: { 
                                showCommentSummary.toggle()
                                print("📱 RedditDetailView: Comment summary visibility toggled to \(showCommentSummary)")
                            }) {
                                Image(systemName: showCommentSummary ? "chevron.up" : "chevron.down")
                            }
                        }
                        if showCommentSummary {
                            GlassyCommentSummary(summary: summary)
                        }
                    }
                    Divider()
                }
                
                // Display comments section
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Comments")
                            .font(.headline)
                        
                        if isLoadingComments {
                            ProgressView()
                                .padding(.leading, 8)
                        } else {
                            Text("(\(comments.count))")
                                .foregroundColor(.secondary)
                                .font(.subheadline)
                        }
                        
                        Spacer()
                        
                        if !comments.isEmpty {
                            Button(action: {
                                // Clear any existing summary first
                                commentSummary = nil
                                summarizeComments(for: post)
                            }) {
                                Label("Summarize", systemImage: "text.redaction")
                                    .font(.subheadline)
                            }
                            .disabled(isLoadingComments)
                            .buttonStyle(BorderedButtonStyle())
                            
                            Button(action: {
                                showQAInterface.toggle()
                            }) {
                                Label(showQAInterface ? "Hide Q&A" : "Ask", systemImage: showQAInterface ? "xmark.circle" : "questionmark.circle")
                                    .font(.subheadline)
                            }
                            .disabled(isLoadingComments)
                            .buttonStyle(BorderedButtonStyle())
                        }
                    }
                    
                    if isLoadingComments && comments.isEmpty {
                        VStack(spacing: 16) {
                            ProgressView()
                            Text("Loading comments...")
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(20)
                    } else if comments.isEmpty {
                        Text("No comments available.")
                            .foregroundColor(.secondary)
                            .italic()
                            .padding(20)
                    } else {
                        // Display the toggled Q&A interface
                        if showQAInterface {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Ask a question about this post:")
                                    .font(.headline)
                                
                                TextField("Type your question...", text: $questionText)
                                    .textFieldStyle(RoundedBorderTextFieldStyle())
                                    .disabled(isProcessingQuestion)
                                    .onSubmit {
                                        if !questionText.isEmpty && !isProcessingQuestion {
                                            askQuestion(post: post)
                                        }
                                    }
                                    .onAppear {
                                        print("📱 RedditDetailView: Q&A interface appeared")
                                    }
                                
                                HStack {
                                    Button(action: {
                                        if !questionText.isEmpty {
                                            askQuestion(post: post)
                                        }
                                    }) {
                                        Text("Ask")
                                            .fontWeight(.semibold)
                                            .padding(.horizontal, 12)
                                            .padding(.vertical, 8)
                                            .background(Color.blue)
                                            .foregroundColor(.white)
                                            .cornerRadius(8)
                                            .frame(minWidth: 80)
                                    }
                                    .disabled(questionText.isEmpty || isProcessingQuestion)
                                    
                                    Button(action: {
                                        showQAInterface = false
                                        questionText = ""
                                        answerText = "Ask a question about this post or its comments..."
                                        print("📱 RedditDetailView: Q&A interface canceled by user")
                                    }) {
                                        Text("Cancel")
                                    }
                                    
                                    Spacer()
                                }
                                
                                Text(answerText)
                                    .padding()
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(Color.secondary.opacity(0.1))
                                    .cornerRadius(8)
                            }
                            .padding()
                            .background(Color.blue.opacity(0.1))
                            .cornerRadius(12)
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(Color.blue.opacity(0.3), lineWidth: 1)
                            )
                            .padding(.bottom, 16)
                        }
                        
                        // Display limited comments with option to load more
                        CommentThreadView(comments: displayedComments)
                        
                        if hasMoreCommentsToLoad {
                            Button(action: {
                                loadMoreComments()
                            }) {
                                HStack {
                                    Text("Load more comments")
                                    Image(systemName: "arrow.down.circle")
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.secondary.opacity(0.1))
                            .cornerRadius(8)
                            .padding(.vertical, 8)
                        }
                    }
                }
            }
            .padding()
        }
        
        // Remove the separate overlay for comment summarization button
        // which may be getting hidden or positioned off-screen
        } // Close ZStack
        // Use this key view ID to ensure proper reconstruction when post changes
        .id("reddit-detail-\(post.id)")
        // Add toolbar with buttons
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: { 
                    // Ask AI button - toggle Q&A interface 
                    withAnimation { 
                        showQAInterface.toggle()
                    }
                    print("📱 RedditDetailView: Ask AI button \(showQAInterface ? "enabled" : "disabled")")
                }) {
                    HStack {
                        Image(systemName: showQAInterface ? "xmark.circle.fill" : "questionmark.circle.fill")
                        Text(showQAInterface ? "Hide Q&A" : "Ask AI")
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.blue)
                    .foregroundColor(.white)
                    .cornerRadius(8)
                }
            }
            
            ToolbarItem(placement: .primaryAction) {
                Button(action: { 
                    // Only show if there are comments to summarize
                    if !comments.isEmpty {
                        // Clear any existing summary first
                        commentSummary = nil
                        summarizeComments(for: post)
                    }
                }) {
                    HStack {
                        Image(systemName: "text.quote")
                        Text("Summarize")
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(!comments.isEmpty ? Color.orange : Color.gray)
                    .foregroundColor(.white)
                    .cornerRadius(8)
                }
                .disabled(comments.isEmpty)
            }
        }
    }
    
    private func loadComments(for post: RedditPost) {
        // Cancel any existing subscriptions
        cancellables.removeAll()
        
        // Set loading state
        isLoadingComments = true
        comments = []
        displayedComments = []
        hasMoreCommentsToLoad = false
        
        // Adding a small delay helps prevent navigation issues
        // by ensuring the view is fully stable before network calls
        print("📱 RedditDetailView: Preparing to load comments for post ID: \(post.id) in r/\(post.subreddit)")
        
        let redditService = RedditService()
        redditService.fetchComments(for: post.id, in: post.subreddit)
            .receive(on: RunLoop.main)
            .sink { loadedComments in
                // Double-check that we're still looking at the same post
                guard post.id == appState.selectedRedditPost?.id else { 
                    print("⚠️ RedditDetailView: Discarding comments - post changed")
                    return
                }
                
                // Filter out AutoModerator comments
                self.comments = loadedComments
                    .filter { $0.author.lowercased() != "automoderator" }
                
                // Set displayed comments (limited number)
                if self.comments.count > self.maxDisplayComments {
                    self.displayedComments = Array(self.comments.prefix(self.maxDisplayComments))
                    self.hasMoreCommentsToLoad = true
                    print("📱 RedditDetailView: Limiting displayed comments to \(self.displayedComments.count) of \(self.comments.count) total")
                } else {
                    self.displayedComments = self.comments
                    self.hasMoreCommentsToLoad = false
                }
                
                print("✅ RedditDetailView: Loaded \(self.comments.count) comments for post ID: \(post.id)")
                self.isLoadingComments = false
            }
            .store(in: &cancellables)
    }
    
    private func loadMoreComments() {
        // Determine how many more comments to load
        let currentCount = displayedComments.count
        let nextBatchSize = min(maxDisplayComments, comments.count - currentCount)
        
        if nextBatchSize > 0 {
            let endIndex = min(currentCount + nextBatchSize, comments.count)
            let additionalComments = Array(comments[currentCount..<endIndex])
            displayedComments.append(contentsOf: additionalComments)
            
            // Check if we have more comments to load
            hasMoreCommentsToLoad = displayedComments.count < comments.count
            
            print("📱 RedditDetailView: Loaded \(additionalComments.count) more comments, now showing \(displayedComments.count) of \(comments.count)")
        }
    }
    
    private func summarizeComments(for post: RedditPost) {
        guard !comments.isEmpty else { return }
        
        print("⚙️ RedditDetailView: Summarizing \(comments.count) comments for post ID: \(post.id)")
        
        // Ensure we're not already generating a summary
        if isProcessingQuestion {
            print("⚠️ RedditDetailView: Cannot summarize while processing a question")
            return
        }
        
        // Set a state flag to indicate we're generating a summary
        isLoadingComments = true
        
        // Use appState's commentSummaryService that already has the API key configured
        appState.commentSummaryService.summarizeComments(comments)
            .receive(on: RunLoop.main)
            .sink { summary in
                // Make sure we're still on the same post
                guard appState.selectedRedditPost?.id == post.id else {
                    print("⚠️ RedditDetailView: Post selection changed before summary completed, discarding results")
                    return
                }
                
                // Create a new summary with the correct post ID and subreddit
                let updatedSummary = CommentSummary(
                    postId: post.id,
                    subreddit: post.subreddit,
                    summary: summary.summary,
                    commentCount: summary.commentCount,
                    topCommenters: summary.topCommenters,
                    mainTopics: summary.mainTopics,
                    sentiment: summary.sentiment,
                    createdDate: summary.createdDate
                )
                
                // Update state with the new summary and show it
                self.commentSummary = updatedSummary
                self.showCommentSummary = true
                self.isLoadingComments = false
                print("✅ RedditDetailView: Comment summary generated for post ID: \(post.id)")
            }
            .store(in: &cancellables)
    }
    
    private func askQuestion(post: RedditPost) {
        guard !questionText.isEmpty && !comments.isEmpty else { return }

        print("📱 RedditDetailView: Asking question: \"\(questionText)\" about post \(post.id)")

        // Set loading state
        isProcessingQuestion = true
        answerText = "Thinking..."

        // Compose the prompt to include the previous question if it exists
        let previousQ = previousQuestionText
        let commentTexts = comments.flatMap { appState.extractAllCommentTexts(from: $0) }
        let combinedComments = commentTexts.joined(separator: "\n\n")
        let prompt: String
        if let prev = previousQ, !prev.isEmpty {
            prompt = """
            Reddit Post Title: \(post.title)
            Post Content:
            \(post.content)

            Comments:
            \(combinedComments)

            Previous Question:
            \(prev)

            Current Question:
            \(questionText)

            Please answer the current question based on the post and comments above. If the answer cannot be determined from the post or comments, please state that the information is not available.
            """
        } else {
            prompt = """
            Reddit Post Title: \(post.title)
            Post Content:
            \(post.content)

            Comments:
            \(combinedComments)

            Please answer the following question:
            \(questionText)

            If the answer cannot be determined from the post or comments, please state that the information is not available.
            """
        }

        // Call the LLM directly with the custom prompt
        appState.summaryService.summarizeText("", customPrompt: prompt)
            .receive(on: RunLoop.main)
            .sink { answer in
                self.answerText = answer
                self.isProcessingQuestion = false
                // Update previous question for next time
                self.previousQuestionText = self.questionText
                print("📱 RedditDetailView: Got answer, updating UI")
            }
            .store(in: &cancellables)
    }
    
    private func sentimentColor(_ sentiment: CommentSummary.CommentSentiment) -> Color {
        switch sentiment {
        case .positive: return .green
        case .negative: return .red
        case .mixed: return .orange
        case .neutral: return .gray
        }
    }
    
    /// Formats Reddit content by cleaning up and enhancing links/images
    private func formatRedditContent(_ content: String) -> AttributedString {
        // Convert content to markdown to enable proper rendering
        // Use Reddit's standard markdown syntax
        let markdownContent = content
            // Ensure links are on their own line for better rendering
            .replacingOccurrences(of: "([^\\n])\\s*(https?://[^\\s]+)", 
                                 with: "$1\n\n$2", 
                                 options: .regularExpression)
            // Make image URLs display as markdown images
            .replacingOccurrences(of: "(?i)(https?://[^\\s]+\\.(?:jpg|jpeg|png|gif|webp))(?![^\\(\\)]*\\))", 
                                 with: "![]($1)", 
                                 options: .regularExpression)
            // Make links more readable
            .replacingOccurrences(of: "(?i)(https?://[^\\s]+)(?![^\\(\\)]*\\))(?![!\\[])", 
                                 with: "[$1]($1)", 
                                 options: .regularExpression)
        
        do {
            return try AttributedString(markdown: markdownContent)
        } catch {
            return AttributedString(content)
        }
    }
}

// Compatibility modifier for glassy backgrounds
struct GlassyBackgroundModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    
    func body(content: Content) -> some View {
        if #available(iOS 15.0, macOS 12.0, *) {
            content
                .foregroundColor(.white)  // Ensure text is always white for better legibility
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .strokeBorder(Color.white.opacity(0.3), lineWidth: 1)
                )
                .shadow(color: Color.black.opacity(0.2), radius: 6, x: 0, y: 3)
        } else {
            // Fallback for older OS versions
            content
                .foregroundColor(.white)  // Ensure text is always white for better legibility
                .background(
                    ZStack {
                        RoundedRectangle(cornerRadius: 16)
                            .fill(Color.black.opacity(0.6)) // Darker background for contrast
                        RoundedRectangle(cornerRadius: 16)
                            .strokeBorder(Color.white.opacity(0.3), lineWidth: 1)
                    }
                )
                .shadow(color: Color.black.opacity(0.2), radius: 6, x: 0, y: 3)
        }
    }
}

// Update GlassyCommentSummary with enhanced styling
struct GlassyCommentSummary: View {
    let summary: CommentSummary
    
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Use Text with Markdown initialization
            Text(.init(summary.summary))
                .font(.body)
                .padding(.vertical, 16)
                .padding(.horizontal, 20)
                .frame(maxWidth: .infinity, alignment: .leading)
            
            // Stats section
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Sentiment: ")
                        .fontWeight(.semibold)
                    Text(summary.sentiment.rawValue.capitalized)
                        .foregroundColor(sentimentColor(summary.sentiment))
                        .fontWeight(.bold)
                }
                if !summary.topCommenters.isEmpty {
                    Text("Top commenters: \(summary.topCommenters.joined(separator: ", "))")
                        .font(.subheadline)
                }
                if !summary.mainTopics.isEmpty {
                    Text("Main topics: \(summary.mainTopics.joined(separator: ", "))")
                        .font(.subheadline)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        }
        .modifier(GlassyBackgroundModifier())
    }
    
    private func sentimentColor(_ sentiment: CommentSummary.CommentSentiment) -> Color {
        switch sentiment {
        case .positive: return .green
        case .negative: return .red
        case .mixed: return .orange
        case .neutral: return .gray
        }
    }
}

// Add this new component below GlassyCommentSummary
struct GlassySummary: View {
    let summary: String
    
    var body: some View {
        Text(.init(summary))
            .font(.body)
            .padding(.vertical, 16)
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .modifier(GlassyBackgroundModifier())
    }
}
