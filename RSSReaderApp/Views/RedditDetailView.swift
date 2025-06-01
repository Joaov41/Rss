import SwiftUI
import Combine
import Kingfisher
#if os(iOS)
import AVFoundation
import UIKit
#elseif os(macOS)
import AppKit
#endif
import Foundation

// Import createWavData from SummaryService

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
    @State private var isProcessingQuestion = false
    @State private var previousQuestionText: String? = nil
    @State private var commentsSentToLLMCount: Int? = nil
    @State private var isShowingAnalytics = false // State for analytics sheet
    @State private var selectedImageURL: URL? = nil
    @State private var showingImagePopup = false
    
    // Default max number of comments to show
    private let maxDisplayComments = 50
    
    // Q&A states
    @State private var showQAInterface = false
    @State private var questionText = ""
    @State private var answerText = "Ask a question about this post or its comments..."
    
    // TTS state variables for Q&A
    @State private var isSynthesizingSpeechQA: Bool = false
    @State private var isSpeakingLocallyQA: Bool = false
    @State private var speechSynthesisErrorQA: String? = nil
    #if os(iOS)
    @State private var audioPlayerQA: AVAudioPlayer?
    @State private var localSpeechSynthQA: AVSpeechSynthesizer?
    @StateObject private var soundDelegateQA = SoundDelegate()
    #elseif os(macOS)
    @State private var audioPlayerQA: NSSound?
    @State private var localSpeechSynthQA: NSSpeechSynthesizer?
    @StateObject private var soundDelegateQA = SoundDelegate()
    #endif
    
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
                        commentsSentToLLMCount = nil
                        print("📱 RedditDetailView: View appeared, resetting comment summary and count")
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
                self.commentsSentToLLMCount = nil
                
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
                                selectedImageURL = mainImageURL
                                showingImagePopup = true
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
                                                selectedImageURL = url
                                                showingImagePopup = true
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
                            // Add Deep Analysis Button
                            Button {
                                isShowingAnalytics = true
                            } label: {
                                Label("Deep Analysis", systemImage: "chart.pie.fill")
                                    .font(.subheadline)
                            }
                            .buttonStyle(BorderedButtonStyle())
                            .tint(.purple) // Give it a distinct color
                            
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
                                        commentsSentToLLMCount = nil
                                        print("📱 RedditDetailView: Q&A interface canceled by user")
                                    }) {
                                        Text("Cancel")
                                    }
                                    
                                    Spacer()
                                }
                                
                                Text(.init(answerText))
                                    .padding()
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(Color.secondary.opacity(0.1))
                                    .cornerRadius(8)
                                    .foregroundColor(isProcessingQuestion ? .secondary : .primary)
                                
                                // Add action buttons here
                                HStack(spacing: 12) {
                                    // Cloud TTS button
                                    Button {
                                        speakAnswerQA(answerText)
                                    } label: {
                                        Image(systemName: "speaker.wave.2")
                                            .padding(6)
                                            .background(Color.blue.opacity(0.2))
                                            .cornerRadius(8)
                                    }
                                    .buttonStyle(PlainButtonStyle())
                                    .help("Read aloud (Cloud)")
                                    .disabled(isSynthesizingSpeechQA || isSpeakingLocallyQA || answerText.isEmpty || answerText == "Ask a question about this post or its comments...")
                                    
                                    // Local TTS button
                                    Button {
                                        speakAnswerLocallyQA(answerText)
                                    } label: {
                                        Image(systemName: "speaker.wave.2.circle")
                                            .padding(6)
                                            .background(Color.green.opacity(0.2))
                                            .cornerRadius(8)
                                    }
                                    .buttonStyle(PlainButtonStyle())
                                    .help("Read aloud (Local)")
                                    .disabled(isSynthesizingSpeechQA || answerText.isEmpty || answerText == "Ask a question about this post or its comments...")
                                    
                                    // Copy button
                                    Button(action: {
                                        #if os(iOS)
                                        UIPasteboard.general.string = answerText
                                        #elseif os(macOS)
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(answerText, forType: .string)
                                        #endif
                                    }) {
                                        Image(systemName: "doc.on.doc")
                                            .padding(6)
                                            .background(Color.gray.opacity(0.2))
                                            .cornerRadius(8)
                                    }
                                    .buttonStyle(PlainButtonStyle())
                                    .help("Copy answer")
                                    .disabled(answerText.isEmpty || answerText == "Ask a question about this post or its comments...")
                                }
                                .padding(.top, 5)
                                
                                // TTS status indicators
                                if isSynthesizingSpeechQA {
                                    HStack {
                                        ProgressView()
                                            .scaleEffect(0.7)
                                            .padding(.trailing, 5)
                                        Text("Reading answer...")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                    .padding(.top, 4)
                                } else if isSpeakingLocallyQA {
                                    HStack {
                                        ProgressView()
                                            .scaleEffect(0.7)
                                            .padding(.trailing, 5)
                                        Text("Reading with local TTS...")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                    .padding(.top, 4)
                                }
                                
                                if let error = speechSynthesisErrorQA {
                                    Text(error)
                                        .font(.caption)
                                        .foregroundColor(.red)
                                        .padding(.top, 4)
                                }
                                
                                // Display the comment count used for the answer
                                if let count = commentsSentToLLMCount, !isProcessingQuestion, answerText != "Ask a question about this post or its comments..." {
                                    Text("Answer based on \(count) comments")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                        .padding(.top, 4)
                                }
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
        // Add sheet modifier for Analytics View
        .sheet(isPresented: $isShowingAnalytics) {
            // Ensure comments are not empty before presenting
            if !comments.isEmpty {
                // Present the integrated view
                CommentAnalyticsViewIntegrated(comments: comments)
                    .environmentObject(appState) // Pass environment object
            }
        }
        // Add sheet for image popup
        .sheet(isPresented: $showingImagePopup) {
            if let imageURL = selectedImageURL {
                ImagePopupView(imageURL: imageURL)
                    .onAppear {
                        print("Showing Reddit post image popup with URL: \(imageURL)")
                    }
            }
        }
        // Add toolbar with buttons
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: {
                    // Ask AI button - toggle Q&A interface 
                    withAnimation { 
                        showQAInterface.toggle()
                    }
                    if !showQAInterface { // Reset count and state if Q&A closed
                        commentsSentToLLMCount = nil
                        questionText = ""
                        answerText = "Ask a question about this post or its comments..."
                        isProcessingQuestion = false // Ensure processing stops
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
        let commentsToSummarize = self.comments
        self.commentsSentToLLMCount = commentsToSummarize.count
        
        appState.commentSummaryService.summarizeComments(commentsToSummarize)
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
        let currentComments = self.comments
        self.commentsSentToLLMCount = currentComments.count
        
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
    
    // MARK: - TTS Methods for Q&A
    
    private func speakAnswerQA(_ text: String) {
        guard !text.isEmpty && text != "Ask a question about this post or its comments..." else {
            speechSynthesisErrorQA = "No answer available to read."
            return
        }
        
        // Stop any currently playing sounds before starting a new one
        #if os(iOS)
        audioPlayerQA?.stop()
        audioPlayerQA = nil
        // Also stop any local speech if playing
        localSpeechSynthQA?.stopSpeaking(at: .immediate)
        #elseif os(macOS)
        audioPlayerQA?.stop()
        audioPlayerQA = nil
        // Also stop any local speech if playing
        localSpeechSynthQA?.stopSpeaking()
        #endif
        
        isSynthesizingSpeechQA = true
        isSpeakingLocallyQA = false
        speechSynthesisErrorQA = nil
        
        Task {
            do {
                let audioData = try await appState.summaryService.synthesizeSpeech(text: text)
                
                DispatchQueue.main.async {
                    self.playAudioQA(data: audioData)
                }
            } catch {
                DispatchQueue.main.async {
                    self.speechSynthesisErrorQA = "Speech synthesis failed: \(error.localizedDescription)"
                    self.isSynthesizingSpeechQA = false
                }
            }
        }
    }
    
    private func playAudioQA(data: Data) {
        #if os(iOS)
        // Stop any existing playback
        audioPlayerQA?.stop()
        
        // Detect format and handle accordingly
        let audioData: Data
        if isMP3Data(data) {
            // OpenAI returns MP3 directly
            audioData = data
        } else {
            // Gemini returns PCM that needs WAV conversion
            audioData = createWavData(from: data, sampleRate: 24000, channels: 1, bitsPerSample: 16)
        }
        
        do {
            audioPlayerQA = try AVAudioPlayer(data: audioData)
            if let player = audioPlayerQA {
                player.delegate = soundDelegateQA
                if player.play() {
                    // isSynthesizingSpeechQA remains true until playback finishes or fails
                } else {
                    speechSynthesisErrorQA = "Failed to start audio playback."
                    isSynthesizingSpeechQA = false // Playback failed to start
                }
            }
        } catch {
            speechSynthesisErrorQA = "Failed to initialize audio player: \(error.localizedDescription)"
            isSynthesizingSpeechQA = false // Player initialization failed
        }
        #elseif os(macOS)
        // Stop any existing playback
        audioPlayerQA?.stop()
        
        // Detect format and handle accordingly
        let audioData: Data
        if isMP3Data(data) {
            // OpenAI returns MP3 directly
            audioData = data
        } else {
            // Gemini returns PCM that needs WAV conversion
            audioData = createWavData(from: data, sampleRate: 24000, channels: 1, bitsPerSample: 16)
        }
        
        audioPlayerQA = NSSound(data: audioData)
        if let player = audioPlayerQA {
            player.delegate = soundDelegateQA
            if player.play() {
                // isSynthesizingSpeechQA remains true until playback finishes or fails
            } else {
                speechSynthesisErrorQA = "Failed to start audio playback."
                isSynthesizingSpeechQA = false // Playback failed to start
            }
        } else {
            speechSynthesisErrorQA = "Failed to initialize audio player with data."
            isSynthesizingSpeechQA = false // Player initialization failed
        }
        #endif
    }
    
    private func speakAnswerLocallyQA(_ text: String) {
        #if os(iOS)
        // Toggle off if already speaking
        if isSpeakingLocallyQA {
            localSpeechSynthQA?.stopSpeaking(at: .immediate)
            isSpeakingLocallyQA = false
            return
        }
        
        guard !text.isEmpty && text != "Ask a question about this post or its comments..." else {
            speechSynthesisErrorQA = "No answer available to read."
            return
        }
        
        // Stop any other audio playing
        audioPlayerQA?.stop()
        
        // Initialize speech synthesizer
        if localSpeechSynthQA == nil {
            localSpeechSynthQA = AVSpeechSynthesizer()
            localSpeechSynthQA?.delegate = soundDelegateQA
        }
        
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.volume = 1.0
        utterance.voice = AVSpeechSynthesisVoice(identifier: "com.apple.voice.premium.en-US.Ava")
        
        isSpeakingLocallyQA = true
        isSynthesizingSpeechQA = false
        if let synth = localSpeechSynthQA {
            synth.speak(utterance)
        } else {
            isSpeakingLocallyQA = false
            speechSynthesisErrorQA = "Failed to initialize speech synthesizer."
        }
        #elseif os(macOS)
        // Toggle off if already speaking
        if isSpeakingLocallyQA {
            localSpeechSynthQA?.stopSpeaking()
            isSpeakingLocallyQA = false
            return
        }
        
        guard !text.isEmpty && text != "Ask a question about this post or its comments..." else {
            speechSynthesisErrorQA = "No answer available to read."
            return
        }
        
        // Stop all other audio
        audioPlayerQA?.stop()
        
        let synth = NSSpeechSynthesizer()
        synth.delegate = soundDelegateQA
        
        isSpeakingLocallyQA = true
        isSynthesizingSpeechQA = false
        if !synth.startSpeaking(text) {
            isSpeakingLocallyQA = false
            speechSynthesisErrorQA = "Failed to start local speech synthesis."
        } else {
            localSpeechSynthQA = synth
        }
        #endif
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


// MARK: - Integrated Comment Analytics View Components (Moved from CommentAnalyticsView.swift)

// Using standard SwiftUI colors for now, can be adjusted later if needed.
fileprivate struct AnalyticsColors { // Make fileprivate to avoid polluting global scope
    static var background: Color { Color(uiColor: .systemBackground) }
    static var systemGray5: Color { Color(uiColor: .systemGray5) }
    static var systemGray6: Color { Color(uiColor: .systemGray6) }
    static var neutralGray: Color { .gray }
}

fileprivate struct PieSlice: View { // Make fileprivate
    var startAngle: Angle
    var endAngle: Angle
    var color: Color
    
    var body: some View {
        GeometryReader { geometry in
            Path { path in
                let center = CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2)
                let radius = min(geometry.size.width, geometry.size.height) / 2
                
                path.move(to: center)
                path.addArc(center: center, radius: radius, startAngle: startAngle, endAngle: endAngle, clockwise: false)
                path.closeSubpath()
            }
            .fill(color)
        }
    }
}

fileprivate struct SentimentPieChartView: View { // Make fileprivate
    let positive: Double
    let neutral: Double
    let negative: Double
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Pie slices
                PieSlice(startAngle: .degrees(0), endAngle: .degrees(positive * 3.6), color: .green)
                PieSlice(startAngle: .degrees(positive * 3.6), endAngle: .degrees((positive + neutral) * 3.6), color: AnalyticsColors.neutralGray)
                PieSlice(startAngle: .degrees((positive + neutral) * 3.6), endAngle: .degrees(360), color: .red)
                
                // Optional: Center hole for donut chart
                Circle()
                    .fill(AnalyticsColors.background)
                    .frame(width: geometry.size.width * 0.5, height: geometry.size.height * 0.5)
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

// MARK: - Integrated Comment Analytics View

struct CommentAnalyticsViewIntegrated: View {
    let comments: [RedditCommentModel]
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) var dismiss
    
    @State private var analytics: CommentAnalytics?
    @State private var thematicAnalysis: String? = nil
    @State private var isThematicAnalysisLoading = false
    @State private var thematicAnalysisError: String? = nil
    @State private var isLoading = true
    @State private var analyzedCommentCount: Int = 0
    @State private var analysisCancellable: AnyCancellable? // To hold the Combine subscription
    
    // Use RedditService directly
    private let redditService = RedditService()
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    
                    if isLoading {
                        VStack {
                            ProgressView()
                                .padding()
                            Text("Analyzing comments...")
                        }
                        .frame(maxWidth: .infinity, minHeight: 300)
                    } else if let analytics = analytics {
                        // Display comment count sent to LLM for analysis at the top
                        if analyzedCommentCount > 0 {
                            Text("Analysis based on \(analyzedCommentCount) comments")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .padding(.horizontal)
                                .padding(.top, 4)
                        }
                        
                        sentimentAnalysisSection(analytics: analytics)
                        overallStatsSection(analytics: analytics)
                        keyInsightsSection(analytics: analytics)
                        thematicAnalysisSection()
                        commentSummariesSection(analytics: analytics)
                    } else {
                        Text("No data available or analysis failed.")
                            .frame(maxWidth: .infinity)
                            .padding()
                    }
                }
                .padding(.vertical)
            }
            .navigationTitle("Deep Comment Analysis")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .onAppear {
                Task {
                    await generateAnalytics()
                }
            }
        }
    }
    
    // MARK: - Subviews for Sections
    
    @ViewBuilder
    private func sentimentAnalysisSection(analytics: CommentAnalytics) -> some View {
        VStack(alignment: .leading, spacing: 15) {
            Text("Sentiment Analysis")
                .font(.title2)
                .fontWeight(.bold)
                .padding(.horizontal)
            
            HStack(alignment: .top, spacing: 15) {
                VStack(alignment: .leading, spacing: 15) {
                    sentimentStatRow(label: "Positive", count: analytics.sentimentCounts.positive, percentage: analytics.sentimentPercentages.positive, color: .green)
                    sentimentStatRow(label: "Neutral", count: analytics.sentimentCounts.neutral, percentage: analytics.sentimentPercentages.neutral, color: .gray)
                    sentimentStatRow(label: "Negative", count: analytics.sentimentCounts.negative, percentage: analytics.sentimentPercentages.negative, color: .red)
                }
                .frame(minWidth: 150)
                .padding()
                .background(Color.secondary.opacity(0.1))
                .cornerRadius(10)
                
                VStack {
                    SentimentPieChartView(
                        positive: analytics.sentimentPercentages.positive,
                        neutral: analytics.sentimentPercentages.neutral,
                        negative: analytics.sentimentPercentages.negative
                    )
                    .frame(height: 150)
                    
                    HStack(spacing: 12) {
                        legendItem(color: .green, label: "Positive")
                        legendItem(color: .gray, label: "Neutral")
                        legendItem(color: .red, label: "Negative")
                    }
                    .padding(.top, 5)
                }
                .padding()
                .background(Color.secondary.opacity(0.1))
                .cornerRadius(10)
            }
            .padding(.horizontal)
        }
    }
    
    @ViewBuilder
    private func overallStatsSection(analytics: CommentAnalytics) -> some View {
        VStack(alignment: .leading, spacing: 15) {
            Text("Overall Comment Stats")
                .font(.title2)
                .fontWeight(.bold)
                .padding(.horizontal)
            
            VStack(alignment: .leading, spacing: 10) {
                bulletPoint("Sentiment is \(analytics.getSentimentMajority()): \(String(format: "%.0f", analytics.sentimentPercentages.positive))% positive, \(String(format: "%.0f", analytics.sentimentPercentages.neutral))% neutral, \(String(format: "%.0f", analytics.sentimentPercentages.negative))% negative.")
                bulletPoint("Average comment length is \(analytics.averageCommentLength) characters.")
                bulletPoint("\(analytics.uniqueAuthorsCount) unique authors contributed.")
                
                if let mostActive = analytics.mostActiveAuthor {
                    bulletPoint("Most active author ('\(mostActive.name)') contributed \(mostActive.count) comments.")
                }
                
                bulletPoint("Most common comment length is \(analytics.getMostCommonLengthDescription()).")
            }
            .padding()
            .background(Color.secondary.opacity(0.1))
            .cornerRadius(10)
            .padding(.horizontal)
        }
    }
    
    @ViewBuilder
    private func keyInsightsSection(analytics: CommentAnalytics) -> some View {
        VStack(alignment: .leading, spacing: 15) {
            Text("Key Insights")
                .font(.title2)
                .fontWeight(.bold)
                .padding(.horizontal)
            
            VStack(alignment: .leading, spacing: 10) {
                bulletPoint("Analyzed \(analytics.totalComments) comments (including replies).")
                
                if !analytics.highlyVotedComments.isEmpty {
                    bulletPoint("Highest voted comment has \(analytics.highlyVotedComments.first?.score ?? 0) upvotes.")
                } else if analytics.totalComments > 0 {
                     bulletPoint("No highly upvoted comments found in the top results.")
                 } else {
                     bulletPoint("No comments to analyze for upvotes.")
                 }
                
                if !analytics.commentTopics.isEmpty {
                    let topicsText = analytics.commentTopics.prefix(3).joined(separator: ", ")
                    bulletPoint("Potential common topics: \(topicsText).")
                } else if analytics.totalComments > 0 {
                     bulletPoint("Could not identify distinct common topics.")
                 } else {
                     bulletPoint("No comments to analyze for topics.")
                 }
            }
            .padding()
            .background(Color.secondary.opacity(0.1))
            .cornerRadius(10)
            .padding(.horizontal)
        }
    }
    
    @ViewBuilder
    private func thematicAnalysisSection() -> some View {
        let apiKey = appState.settings.geminiApiKey // Get API key
        VStack(alignment: .leading, spacing: 15) {
            Text("Thematic Analysis (AI)")
                .font(.title2)
                .fontWeight(.bold)
                .padding(.horizontal)
            Text("Based on analysis of \(analyzedCommentCount) comments.")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.horizontal)
            
            if isThematicAnalysisLoading {
                VStack {
                    ProgressView()
                        .padding(.bottom, 5)
                    Text("Generating thematic analysis with AI...")
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(Color.secondary.opacity(0.1))
                .cornerRadius(10)
                .padding(.horizontal)
            } else if let thematicAnalysisError = thematicAnalysisError {
                Text("Error generating thematic analysis: \(thematicAnalysisError)")
                    .foregroundColor(.red)
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.1))
                    .cornerRadius(10)
                    .padding(.horizontal)
            } else if let thematicAnalysis = thematicAnalysis, !thematicAnalysis.isEmpty {
                Text(.init(thematicAnalysis))
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.1))
                    .cornerRadius(10)
                    .padding(.horizontal)
                    .textSelection(.enabled)
            } else {
                Text(apiKey.isEmpty ? "Thematic analysis requires a Gemini API key in Settings." : "No thematic analysis available or comments were empty.")
                    .foregroundColor(.secondary)
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.1))
                    .cornerRadius(10)
                    .padding(.horizontal)
            }
        }
    }
    
    @ViewBuilder
    private func commentSummariesSection(analytics: CommentAnalytics) -> some View {
        VStack(alignment: .leading, spacing: 15) {
            Text("Comment Examples by Sentiment")
                .font(.title2)
                .fontWeight(.bold)
                .padding(.horizontal)
            
            if analytics.sentimentCounts.positive > 0 {
                commentSection(title: "Top Positive Comments", comments: redditService.getTopCommentsBySentiment(comments: comments, type: .positive)) // Use redditService
            }
            
            if analytics.sentimentCounts.neutral > 0 {
                commentSection(title: "Notable Neutral Comments", comments: redditService.getTopCommentsBySentiment(comments: comments, type: .neutral)) // Use redditService
            }
            
            if analytics.sentimentCounts.negative > 0 {
                commentSection(title: "Top Negative Comments", comments: redditService.getTopCommentsBySentiment(comments: comments, type: .negative)) // Use redditService
            }
            
            if analytics.totalComments > 0 && analytics.sentimentCounts.positive == 0 && analytics.sentimentCounts.neutral == 0 && analytics.sentimentCounts.negative == 0 {
                 Text("Could not categorize comments by sentiment.")
                     .foregroundColor(.secondary)
                     .padding()
                     .frame(maxWidth: .infinity, alignment: .leading)
                     .background(Color.secondary.opacity(0.1))
                     .cornerRadius(10)
                     .padding(.horizontal)
             } else if analytics.totalComments == 0 {
                 Text("No comments to display examples for.")
                     .foregroundColor(.secondary)
                     .padding()
                     .frame(maxWidth: .infinity, alignment: .leading)
                     .background(Color.secondary.opacity(0.1))
                     .cornerRadius(10)
                     .padding(.horizontal)
             }
        }
    }
    
    // MARK: - Helper Views
    
    private func sentimentStatRow(label: String, count: Int, percentage: Double, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.headline)
            
            Text("\(count)")
                .font(.title)
                .fontWeight(.semibold)
                .foregroundColor(color)
            
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle()
                        .foregroundColor(Color.secondary.opacity(0.2))
                        .frame(height: 8)
                        .cornerRadius(4)
                    
                    Rectangle()
                        .foregroundColor(color)
                        .frame(width: max(0, min(geo.size.width, CGFloat(percentage / 100.0) * geo.size.width)), height: 8)
                        .cornerRadius(4)
                        .animation(.linear, value: percentage)
                }
            }
            .frame(height: 8)
        }
    }
    
    private func legendItem(color: Color, label: String) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 10, height: 10)
            
            Text(label)
                .font(.caption)
        }
    }
    
    private func bulletPoint(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("•")
                .fontWeight(.bold)
            
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
    
    private func commentSection(title: String, comments: [RedditCommentModel]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
                .padding(.horizontal)
            
            if comments.isEmpty {
                Text("No comments found for this category.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal)
            } else {
                ForEach(comments, id: \.id) { comment in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(comment.body.prefix(200))
                            .lineLimit(3)
                            .font(.footnote)
                        
                        HStack {
                            Text("u/\(comment.author)")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            
                            Spacer()
                            
                            Text("\(comment.score) upvotes")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(10)
                    .background(Color.secondary.opacity(0.1))
                    .cornerRadius(8)
                    .padding(.horizontal)
                }
            }
        }
    }
    
    // MARK: - Data Generation Functions
    
    private func generateAnalytics() async {
        isLoading = true
        
        // Perform potentially long analysis in background task
        let generatedAnalytics = redditService.generateCommentAnalytics(from: comments)
        
        // Update UI on main thread
        DispatchQueue.main.async {
            self.analytics = generatedAnalytics
            self.isLoading = false // Set loading to false AFTER analysis is done and state is updated
            
            let apiKey = self.appState.settings.geminiApiKey // Get API key
            if !apiKey.isEmpty && generatedAnalytics.totalComments > 0 {
                // Call the non-async version
                self.generateThematicAnalysis(commentsToAnalyze: self.redditService.flattenComments(self.comments))
            } else {
                self.isThematicAnalysisLoading = false
                if apiKey.isEmpty {
                    self.thematicAnalysisError = "Gemini API key not set in Settings."
                } else {
                    self.thematicAnalysis = "No comments available for thematic analysis."
                }
            }
        }
    }
    
    // Modified to use Combine .sink instead of async/await
    private func generateThematicAnalysis(commentsToAnalyze: [RedditCommentModel]) {
        guard !isThematicAnalysisLoading else { return }
        
        isThematicAnalysisLoading = true
        thematicAnalysisError = nil
        thematicAnalysis = nil
        
        DispatchQueue.main.async {
            self.analyzedCommentCount = commentsToAnalyze.count
        }
        
        let formattedCommentsString = formatCommentsForAnalysis(comments: commentsToAnalyze)
        
        let prompt = """
        You are analyzing comments from a Reddit post.

        Here are the comments (formatted as '- author (score): text'):
        \(formattedCommentsString)

        ---
        Task: Briefly summarize the top 2-3 main themes and points discussed in the comments above. For each theme, provide a one-sentence description and, if possible, a short quote as an example. Keep the overall summary concise (5-8 sentences total).

        Format your response in plain Markdown. Do NOT include any HTML tags.

        Example Structure:

        - **Theme 1:** One-sentence summary. Example: "[Short quote]"
        - **Theme 2:** One-sentence summary. Example: "[Short quote]"

        Final Overall Summary: One or two sentences summarizing the general tone and main takeaways.
        """
        
        // Use SummaryService from AppState with Combine .sink
        print("CommentAnalyticsViewIntegrated: Sending \(analyzedCommentCount) comments for thematic analysis.")
        analysisCancellable = appState.summaryService.summarizeText(prompt)
            .receive(on: DispatchQueue.main) // Ensure updates happen on the main thread
            .sink { summaryResult in
                // Check if the result indicates an error message returned by the service itself
                if summaryResult.starts(with: "Error:") || summaryResult == "API key not configured. Please add your Gemini API key in Settings." || summaryResult == "Invalid API URL" {
                    self.thematicAnalysisError = summaryResult
                    self.thematicAnalysis = nil
                } else if summaryResult == "No summary available" {
                    self.thematicAnalysisError = nil
                    self.thematicAnalysis = summaryResult // Or set to a more user-friendly message
                } else {
                    // Success case
                    self.thematicAnalysis = summaryResult
                    self.thematicAnalysisError = nil
                }
                self.isThematicAnalysisLoading = false
            }
    }
    
    // Function to recursively format comments for the analysis prompt
    private func formatCommentsForAnalysis(comments: [RedditCommentModel], depth: Int = 0) -> String {
        var formattedString = ""
        let indent = String(repeating: "  ", count: depth)
        
        for comment in comments {
            let scoreText = " (\(comment.score) points)"
            let authorText = comment.author.isEmpty ? "[deleted]" : comment.author
            let bodyText = comment.body.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
            formattedString += "\(indent)- \(authorText)\(scoreText): \(bodyText)\n"
            if !comment.replies.isEmpty {
                formattedString += formatCommentsForAnalysis(comments: comment.replies, depth: depth + 1)
            }
        }
        return formattedString
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

// Update GlassyCommentSummary with enhanced styling and TTS
struct GlassyCommentSummary: View {
    let summary: CommentSummary
    @EnvironmentObject var appState: AppState
    
    // TTS state variables
    @State private var isSynthesizingSpeech: Bool = false
    @State private var isSpeakingLocally: Bool = false
    @State private var speechSynthesisError: String? = nil
    #if os(iOS)
    @State private var audioPlayer: AVAudioPlayer?
    @State private var localSpeechSynth: AVSpeechSynthesizer?
    @StateObject private var soundDelegate = SoundDelegate()
    #elseif os(macOS)
    @State private var audioPlayer: NSSound?
    @State private var localSpeechSynth: NSSpeechSynthesizer?
    @StateObject private var soundDelegate = SoundDelegate()
    #endif
    
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Text("Comment Summary")
                    .font(.headline)
                
                Spacer()
                
                // Cloud TTS button
                Button {
                    speakSummary()
                } label: {
                    Image(systemName: "speaker.wave.2")
                        .padding(6)
                        .background(Color.blue.opacity(0.2))
                        .cornerRadius(8)
                }
                .buttonStyle(PlainButtonStyle())
                .help("Read aloud (Cloud)")
                .disabled(isSynthesizingSpeech || isSpeakingLocally)
                
                // Local TTS button
                Button {
                    speakSummaryLocally()
                } label: {
                    Image(systemName: "speaker.wave.2.circle")
                        .padding(6)
                        .background(Color.green.opacity(0.2))
                        .cornerRadius(8)
                }
                .buttonStyle(PlainButtonStyle())
                .help("Read aloud (Local)")
                .disabled(isSynthesizingSpeech)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            
            // Use Text with Markdown initialization
            Text(.init(summary.summary))
                .font(.body)
                .padding(.vertical, 16)
                .padding(.horizontal, 20)
                .frame(maxWidth: .infinity, alignment: .leading)
            
            // TTS status indicators
            if isSynthesizingSpeech {
                HStack {
                    ProgressView()
                        .scaleEffect(0.7)
                        .padding(.trailing, 5)
                    Text("Reading summary...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 20)
            } else if isSpeakingLocally {
                HStack {
                    ProgressView()
                        .scaleEffect(0.7)
                        .padding(.trailing, 5)
                    Text("Reading with local TTS...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 20)
            }
            
            if let error = speechSynthesisError {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
                    .padding(.horizontal, 20)
            }
            
            // Add Copy button here
            Button(action: {
                #if os(iOS)
                UIPasteboard.general.string = summary.summary
                #elseif os(macOS)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(summary.summary, forType: .string)
                #endif
            }) {
                Label("Copy Summary", systemImage: "doc.on.doc")
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.secondary.opacity(0.2))
                    .foregroundColor(.primary)
                    .cornerRadius(6)
            }
            .disabled(summary.summary.isEmpty)
            .padding(.top, 5)
            .padding(.horizontal, 20)
            
            // Stats section
            VStack(alignment: .leading, spacing: 10) {
                // Add comment count indicator first
                Text("Summary based on \(summary.commentCount) comments")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
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
        .onAppear {
            // Set up sound delegate callbacks
            #if os(iOS)
            soundDelegate.onPlaybackFinished = {
                DispatchQueue.main.async {
                    self.isSynthesizingSpeech = false
                }
            }
            soundDelegate.onSpeechFinished = {
                DispatchQueue.main.async {
                    self.isSpeakingLocally = false
                }
            }
            #elseif os(macOS)
            soundDelegate.onPlaybackFinished = {
                DispatchQueue.main.async {
                    self.isSynthesizingSpeech = false
                }
            }
            soundDelegate.onSpeechFinished = {
                DispatchQueue.main.async {
                    self.isSpeakingLocally = false
                }
            }
            #endif
            
        }
    }
    
    private func sentimentColor(_ sentiment: CommentSummary.CommentSentiment) -> Color {
        switch sentiment {
        case .positive: return .green
        case .negative: return .red
        case .mixed: return .orange
        case .neutral: return .gray
        }
    }
    
    // MARK: - TTS Methods
    
    private func speakSummary() {
        guard !summary.summary.isEmpty else {
            speechSynthesisError = "No summary available to read."
            return
        }
        
        // Stop any currently playing sounds before starting a new one
        #if os(iOS)
        audioPlayer?.stop()
        audioPlayer = nil
        // Also stop any local speech if playing
        localSpeechSynth?.stopSpeaking(at: .immediate)
        #elseif os(macOS)
        audioPlayer?.stop()
        audioPlayer = nil
        // Also stop any local speech if playing
        localSpeechSynth?.stopSpeaking()
        #endif
        
        isSynthesizingSpeech = true
        isSpeakingLocally = false
        speechSynthesisError = nil
        
        Task {
            await appState.summaryService.synthesizeSpeechFastStart(
                text: summary.summary,
                onFirstChunk: { audioData in
                    DispatchQueue.main.async {
                        self.playAudio(data: audioData)
                        print("🔊 RedditDetailView: Started immediate playback")
                    }
                },
                onComplete: { _ in
                    DispatchQueue.main.async {
                        print("🔊 RedditDetailView: Complete audio ready for cache")
                    }
                },
                onError: { error in
                    DispatchQueue.main.async {
                        self.speechSynthesisError = "Speech synthesis failed: \(error.localizedDescription)"
                        self.isSynthesizingSpeech = false
                    }
                }
            )
        }
    }
    
    private func playAudio(data: Data) {
        #if os(iOS)
        // Stop any existing playback
        audioPlayer?.stop()
        
        // Detect format and handle accordingly
        let audioData: Data
        if isMP3Data(data) {
            // OpenAI returns MP3 directly
            audioData = data
        } else {
            // Gemini returns PCM that needs WAV conversion
            audioData = createWavData(from: data, sampleRate: 24000, channels: 1, bitsPerSample: 16)
        }
        
        do {
            audioPlayer = try AVAudioPlayer(data: audioData)
            if let player = audioPlayer {
                player.delegate = soundDelegate
                if player.play() {
                    // isSynthesizingSpeech remains true until playback finishes or fails
                } else {
                    speechSynthesisError = "Failed to start audio playback."
                    isSynthesizingSpeech = false // Playback failed to start
                }
            }
        } catch {
            speechSynthesisError = "Failed to initialize audio player: \(error.localizedDescription)"
            isSynthesizingSpeech = false // Player initialization failed
        }
        #elseif os(macOS)
        // Stop any existing playback
        audioPlayer?.stop()
        
        // Detect format and handle accordingly
        let audioData: Data
        if isMP3Data(data) {
            // OpenAI returns MP3 directly
            audioData = data
        } else {
            // Gemini returns PCM that needs WAV conversion
            audioData = createWavData(from: data, sampleRate: 24000, channels: 1, bitsPerSample: 16)
        }
        
        audioPlayer = NSSound(data: audioData)
        if let player = audioPlayer {
            player.delegate = soundDelegate
            if player.play() {
                // isSynthesizingSpeech remains true until playback finishes or fails
            } else {
                speechSynthesisError = "Failed to start audio playback."
                isSynthesizingSpeech = false // Playback failed to start
            }
        } else {
            speechSynthesisError = "Failed to initialize audio player with data."
            isSynthesizingSpeech = false // Player initialization failed
        }
        #endif
    }
    
    private func speakSummaryLocally() {
        #if os(iOS)
        // Toggle off if already speaking
        if isSpeakingLocally {
            localSpeechSynth?.stopSpeaking(at: .immediate)
            isSpeakingLocally = false
            return
        }
        
        guard !summary.summary.isEmpty else {
            speechSynthesisError = "No summary available to read."
            return
        }
        
        // Stop any other audio playing
        audioPlayer?.stop()
        
        // Initialize speech synthesizer
        if localSpeechSynth == nil {
            localSpeechSynth = AVSpeechSynthesizer()
            localSpeechSynth?.delegate = soundDelegate
        }
        
        let utterance = AVSpeechUtterance(string: summary.summary)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.volume = 1.0
        utterance.voice = AVSpeechSynthesisVoice(identifier: "com.apple.voice.premium.en-US.Ava")
        
        isSpeakingLocally = true
        isSynthesizingSpeech = false
        if let synth = localSpeechSynth {
            synth.speak(utterance)
        } else {
            isSpeakingLocally = false
            speechSynthesisError = "Failed to initialize speech synthesizer."
        }
        #elseif os(macOS)
        // Toggle off if already speaking
        if isSpeakingLocally {
            localSpeechSynth?.stopSpeaking()
            isSpeakingLocally = false
            return
        }
        
        guard !summary.summary.isEmpty else {
            speechSynthesisError = "No summary available to read."
            return
        }
        
        // Stop all other audio
        audioPlayer?.stop()
        
        let synth = NSSpeechSynthesizer()
        synth.delegate = soundDelegate
        
        isSpeakingLocally = true
        isSynthesizingSpeech = false
        if !synth.startSpeaking(summary.summary) {
            isSpeakingLocally = false
            speechSynthesisError = "Failed to start local speech synthesis."
        } else {
            localSpeechSynth = synth
        }
        #endif
    }
}

// Add this new component below GlassyCommentSummary
struct GlassySummary: View {
    let summary: String
    @EnvironmentObject var appState: AppState
    
    // TTS state variables
    @State private var isSynthesizingSpeech: Bool = false
    @State private var isSpeakingLocally: Bool = false
    @State private var speechSynthesisError: String? = nil
    #if os(iOS)
    @State private var audioPlayer: AVAudioPlayer?
    @State private var localSpeechSynth: AVSpeechSynthesizer?
    @StateObject private var soundDelegate = SoundDelegate()
    #elseif os(macOS)
    @State private var audioPlayer: NSSound?
    @State private var localSpeechSynth: NSSpeechSynthesizer?
    @StateObject private var soundDelegate = SoundDelegate()
    #endif
    
    var body: some View {
        VStack(alignment: .leading) {
            HStack(spacing: 12) {
                Spacer()
                // Cloud TTS button
                Button {
                    speakSummary()
                } label: {
                    Image(systemName: "speaker.wave.2")
                        .padding(6)
                        .background(Color.blue.opacity(0.2))
                        .cornerRadius(8)
                }
                .buttonStyle(PlainButtonStyle())
                .help("Read aloud (Cloud)")
                .disabled(isSynthesizingSpeech || isSpeakingLocally)
                
                // Local TTS button
                Button {
                    speakSummaryLocally()
                } label: {
                    Image(systemName: "speaker.wave.2.circle")
                        .padding(6)
                        .background(Color.green.opacity(0.2))
                        .cornerRadius(8)
                }
                .buttonStyle(PlainButtonStyle())
                .help("Read aloud (Local)")
                .disabled(isSynthesizingSpeech)
                
                // Copy button
                Button {
                    copyToClipboard(summary)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .padding(6)
                        .background(Color.gray.opacity(0.2))
                        .cornerRadius(8)
                }
                .buttonStyle(PlainButtonStyle())
                .help("Copy summary")
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            
            Text(.init(summary))
                .font(.body)
                .padding(.vertical, 16)
                .padding(.horizontal, 20)
                .frame(maxWidth: .infinity, alignment: .leading)
            
            // TTS status indicators
            if isSynthesizingSpeech {
                HStack {
                    ProgressView()
                        .scaleEffect(0.7)
                        .padding(.trailing, 5)
                    Text("Reading summary...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
            } else if isSpeakingLocally {
                HStack {
                    ProgressView()
                        .scaleEffect(0.7)
                        .padding(.trailing, 5)
                    Text("Reading with local TTS...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
            }
            
            if let error = speechSynthesisError {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 16)
            }
        }
        .modifier(GlassyBackgroundModifier())
        .onAppear {
            // Set up sound delegate callbacks
            #if os(iOS)
            soundDelegate.onPlaybackFinished = {
                DispatchQueue.main.async {
                    self.isSynthesizingSpeech = false
                }
            }
            soundDelegate.onSpeechFinished = {
                DispatchQueue.main.async {
                    self.isSpeakingLocally = false
                }
            }
            #elseif os(macOS)
            soundDelegate.onPlaybackFinished = {
                DispatchQueue.main.async {
                    self.isSynthesizingSpeech = false
                }
            }
            soundDelegate.onSpeechFinished = {
                DispatchQueue.main.async {
                    self.isSpeakingLocally = false
                }
            }
            #endif
        }
    }
    
    // MARK: - TTS Methods
    
    private func speakSummary() {
        guard !summary.isEmpty else {
            speechSynthesisError = "No summary available to read."
            return
        }
        
        // Stop any currently playing sounds before starting a new one
        #if os(iOS)
        audioPlayer?.stop()
        audioPlayer = nil
        // Also stop any local speech if playing
        localSpeechSynth?.stopSpeaking(at: .immediate)
        #elseif os(macOS)
        audioPlayer?.stop()
        audioPlayer = nil
        // Also stop any local speech if playing
        localSpeechSynth?.stopSpeaking()
        #endif
        
        isSynthesizingSpeech = true
        isSpeakingLocally = false
        speechSynthesisError = nil
        
        Task {
            await appState.summaryService.synthesizeSpeechFastStart(
                text: summary,
                onFirstChunk: { audioData in
                    DispatchQueue.main.async {
                        self.playAudio(data: audioData)
                        print("🔊 GlassySummary: Started immediate playback")
                    }
                },
                onComplete: { _ in
                    DispatchQueue.main.async {
                        print("🔊 GlassySummary: Complete audio ready for cache")
                    }
                },
                onError: { error in
                    DispatchQueue.main.async {
                        self.speechSynthesisError = "Speech synthesis failed: \(error.localizedDescription)"
                        self.isSynthesizingSpeech = false
                    }
                }
            )
        }
    }
    
    private func playAudio(data: Data) {
        #if os(iOS)
        // Stop any existing playback
        audioPlayer?.stop()
        
        // Detect format and handle accordingly
        let audioData: Data
        if isMP3Data(data) {
            // OpenAI returns MP3 directly
            audioData = data
        } else {
            // Gemini returns PCM that needs WAV conversion
            audioData = createWavData(from: data, sampleRate: 24000, channels: 1, bitsPerSample: 16)
        }
        
        do {
            audioPlayer = try AVAudioPlayer(data: audioData)
            if let player = audioPlayer {
                player.delegate = soundDelegate
                if player.play() {
                    // isSynthesizingSpeech remains true until playback finishes or fails
                } else {
                    speechSynthesisError = "Failed to start audio playback."
                    isSynthesizingSpeech = false // Playback failed to start
                }
            }
        } catch {
            speechSynthesisError = "Failed to initialize audio player: \(error.localizedDescription)"
            isSynthesizingSpeech = false // Player initialization failed
        }
        #elseif os(macOS)
        // Stop any existing playback
        audioPlayer?.stop()
        
        // Detect format and handle accordingly
        let audioData: Data
        if isMP3Data(data) {
            // OpenAI returns MP3 directly
            audioData = data
        } else {
            // Gemini returns PCM that needs WAV conversion
            audioData = createWavData(from: data, sampleRate: 24000, channels: 1, bitsPerSample: 16)
        }
        
        audioPlayer = NSSound(data: audioData)
        if let player = audioPlayer {
            player.delegate = soundDelegate
            if player.play() {
                // isSynthesizingSpeech remains true until playback finishes or fails
            } else {
                speechSynthesisError = "Failed to start audio playback."
                isSynthesizingSpeech = false // Playback failed to start
            }
        } else {
            speechSynthesisError = "Failed to initialize audio player with data."
            isSynthesizingSpeech = false // Player initialization failed
        }
        #endif
    }
    
    private func speakSummaryLocally() {
        #if os(iOS)
        // Toggle off if already speaking
        if isSpeakingLocally {
            localSpeechSynth?.stopSpeaking(at: .immediate)
            isSpeakingLocally = false
            return
        }
        
        guard !summary.isEmpty else {
            speechSynthesisError = "No summary available to read."
            return
        }
        
        // Stop any other audio playing
        audioPlayer?.stop()
        
        // Initialize speech synthesizer
        if localSpeechSynth == nil {
            localSpeechSynth = AVSpeechSynthesizer()
            localSpeechSynth?.delegate = soundDelegate
        }
        
        let utterance = AVSpeechUtterance(string: summary)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.volume = 1.0
        utterance.voice = AVSpeechSynthesisVoice(identifier: "com.apple.voice.premium.en-US.Ava")
        
        isSpeakingLocally = true
        isSynthesizingSpeech = false
        if let synth = localSpeechSynth {
            synth.speak(utterance)
        } else {
            isSpeakingLocally = false
            speechSynthesisError = "Failed to initialize speech synthesizer."
        }
        #elseif os(macOS)
        // Toggle off if already speaking
        if isSpeakingLocally {
            localSpeechSynth?.stopSpeaking()
            isSpeakingLocally = false
            return
        }
        
        guard !summary.isEmpty else {
            speechSynthesisError = "No summary available to read."
            return
        }
        
        // Stop all other audio
        audioPlayer?.stop()
        
        let synth = NSSpeechSynthesizer()
        synth.delegate = soundDelegate
        
        isSpeakingLocally = true
        isSynthesizingSpeech = false
        if !synth.startSpeaking(summary) {
            isSpeakingLocally = false
            speechSynthesisError = "Failed to start local speech synthesis."
        } else {
            localSpeechSynth = synth
        }
        #endif
    }
    
    private func copyToClipboard(_ text: String) {
        #if os(iOS)
        UIPasteboard.general.string = text
        #elseif os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
}
