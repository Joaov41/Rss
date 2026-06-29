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

#if os(iOS)
private typealias KokoroAudioPlayer = AVAudioPlayer
#elseif os(macOS)
private typealias KokoroAudioPlayer = NSSound
#endif

// Enhanced swipe back extension is defined in ContentView.swift

// Import createWavData from SummaryService

// AppColors is defined in ContentView.swift

// Conditional modifier for enhanced swipe back


#if os(iOS)
// no-op: voice list UI removed to avoid compile issues
#endif

#if os(iOS)
struct ConditionalEnhancedSwipeBack: ViewModifier {
    let isEnabled: Bool
    let appState: AppState
    
    func body(content: Content) -> some View {
        if isEnabled {
            content.enhancedSwipeBack {
                appState.navigateBack()
            }
        } else {
            content
        }
    }
}
#endif

struct RedditDetailView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.colorScheme) private var colorScheme
    @State private var comments: [RedditCommentModel] = []
    @State private var displayedComments: [RedditCommentModel] = []
    @State private var isLoadingComments = false
    @State private var selectedCommentSort: RedditService.CommentSortOption = .best
    @State private var commentSummary: CommentSummary?
    @State private var showCommentSummary = false
    @State private var cancellables = Set<AnyCancellable>()
    @State private var showMoreCommentsButton = false
    @State private var hasMoreCommentsToLoad = false
    @State private var commentBanner: RedditStatusMessage? = nil
    @State private var commentLoadError: String? = nil
    @State private var commentLoadTask: Task<Void, Never>? = nil
    @State private var isProcessingQuestion = false
    @State private var previousQuestionText: String? = nil
    @State private var commentsSentToLLMCount: Int? = nil
    @State private var isShowingAnalytics = false // State for analytics sheet
    @State private var analyticsProviderOverride: AppSettings.SummaryProvider? = nil
    @State private var selectedImageURL: URL? = nil
    @State private var showingImagePopup = false
    
    #if os(iOS)
    private let toolbarPlacement: ToolbarItemPlacement = .bottomBar
    #endif
    
    // Default max number of comments to show
    private let maxDisplayComments = 50
    private let redditTopAnchor = "redditDetailTopAnchor"

    private var shouldShowExplicitWebAIControls: Bool {
        appState.settings.selectedSummaryProvider != .webAI
    }
    
    // Q&A states
    @State private var showQAInterface = false
    @State private var questionText = ""
    @State private var answerText = "Ask a question about this post or its comments..."
    @State private var answerParagraphs: [String]? = nil
    @State private var showSelectionAskAIResponse = false
    @State private var isSelectionAskAIInFlight = false
    @State private var selectionAskAIResponse: String?
    @State private var selectionAskAIError: String?
    @State private var selectionAskAITask: Task<Void, Never>?
    
    // TTS state variables for Q&A
    @State private var isSynthesizingSpeechQA: Bool = false
    @State private var isSpeakingLocallyQA: Bool = false
    @State private var speechSynthesisErrorQA: String? = nil
    @State private var ttsCanceledQA: Bool = false
    #if os(iOS)
    @State private var audioPlayerQA: AVAudioPlayer?
    @State private var localSpeechSynthQA: AVSpeechSynthesizer?
    @StateObject private var soundDelegateQA = SoundDelegate()
    @State private var nextAudioChunkQA: Data? = nil
    @State private var localTTSTaskQA: Task<Void, Never>? = nil
    #elseif os(macOS)
    @State private var audioPlayerQA: NSSound?
    @State private var localSpeechSynthQA: NSSpeechSynthesizer?
    @StateObject private var soundDelegateQA = SoundDelegate()
    @State private var nextAudioChunkQA: Data? = nil
    @State private var localTTSTaskQA: Task<Void, Never>? = nil
    #endif

    // TTS state variables for Post Summary
    @State private var isSynthesizingSpeechSummary: Bool = false
    @State private var isSpeakingLocallySummary: Bool = false
    @State private var speechSynthesisErrorSummary: String? = nil
    @State private var ttsCanceledSummary: Bool = false
    #if os(iOS)
    @State private var audioPlayerSummary: AVAudioPlayer?
    @State private var localSpeechSynthSummary: AVSpeechSynthesizer?
    @StateObject private var soundDelegateSummary = SoundDelegate()
    @State private var nextAudioChunkSummary: Data? = nil
    @State private var localTTSTaskSummary: Task<Void, Never>? = nil
    #elseif os(macOS)
    @State private var audioPlayerSummary: NSSound?
    @State private var localSpeechSynthSummary: NSSpeechSynthesizer?
    @StateObject private var soundDelegateSummary = SoundDelegate()
    @State private var nextAudioChunkSummary: Data? = nil
    @State private var localTTSTaskSummary: Task<Void, Never>? = nil
    #endif

    // Voice picker state removed for macOS shortcut-driven TTS
    
    // This is a key optimization - adding an ID to the view itself
    // forces the view to refresh when the post ID changes
    private var postId: String {
        appState.selectedRedditPost?.id ?? UUID().uuidString
    }
    
    // Track the view's creation time to help with debugging
    private let viewCreationTime = Date()

    private var formattedAnswerText: Text {
        Text(verbatim: answerText)
    }

    
    var body: some View {
        ScrollViewReader { proxy in
            Group {
                if let post = appState.selectedRedditPost {
                    postDetailView(for: post, proxy: proxy)
                        .onAppear {
                            // Load comments when view appears
                            loadComments(for: post)
                            answerParagraphs = nil
                            commentsSentToLLMCount = nil
                            print("📱 RedditDetailView: View appeared")
                        }
                        .onDisappear {
                            // Clean up when view disappears
                            cancellables.removeAll()
                            commentLoadTask?.cancel()
                            print("📱 RedditDetailView: View disappeared, canceling all requests")
                        }
                } else {
                    // Empty view when no post is selected - this allows ContentView to handle navigation
                    EmptyView()
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
                    self.answerParagraphs = nil
                    self.commentsSentToLLMCount = nil
                    
                    // Cancel previous requests
                    cancellables.removeAll()
                    commentLoadTask?.cancel()
                    
                    // Load the new post's comments
                    loadComments(for: post)
                    
                    // Scroll back to the top when switching posts
                    withAnimation(.easeInOut) {
                        proxy.scrollTo(redditTopAnchor, anchor: .top)
                    }
                }
            }
        }
        .sheet(isPresented: $showSelectionAskAIResponse) {
            AskAIResponseSheet(
                isLoading: isSelectionAskAIInFlight,
                response: selectionAskAIResponse,
                errorMessage: selectionAskAIError,
                onClose: { showSelectionAskAIResponse = false },
                onCopy: copySelectionAskAIResponse
            )
        }
        .confirmationDialog(
            "Local request is too large",
            isPresented: Binding(
                get: { appState.pendingLocalReroute?.presentationScope == .deepAnalysis },
                set: {
                    if !$0, appState.pendingLocalReroute?.presentationScope == .deepAnalysis {
                        appState.dismissPendingLocalReroute()
                    }
                }
            ),
            titleVisibility: .visible,
            presenting: appState.pendingLocalReroute
        ) { _ in
            ForEach(LocalRerouteProvider.allCases) { provider in
                Button(provider.displayName) {
                    appState.reroutePendingLocalRequest(to: provider)
                }
            }
            Button("Cancel", role: .cancel) {
                appState.dismissPendingLocalReroute()
            }
        } message: { request in
            Text(request.message)
        }
    }
    
    private func postDetailView(for post: RedditPost, proxy: ScrollViewProxy) -> some View {
        let visiblePostSummary = post.summary
        return ZStack {
            // Reddit gets a true black base in dark mode.
            if colorScheme == .dark {
                Color.black
                    .ignoresSafeArea()
            } else {
                AppColors.redditBackground(for: colorScheme)
                    .ignoresSafeArea()
            }
            
            // Material overlay for glass effect
            if colorScheme == .dark {
                Color.black
                    .ignoresSafeArea()
            } else {
                Color.clear
                    .background(.regularMaterial)
                    .ignoresSafeArea()
            }
            
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Color.clear
                        .frame(height: 0)
                        .id(redditTopAnchor)
                    Button {
                        openPostLink(post)
                    } label: {
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
                
                if appState.isLoading && visiblePostSummary == nil {
                    VStack(spacing: 16) {
                        HStack {
                            Text("Summary")
                                .font(.headline)
                            Spacer()
                        }
                        let summaryStreamText = appState.mlxStreamingText
                        if (appState.settings.selectedSummaryProvider == .mlxLocal || appState.settings.selectedSummaryProvider == .coreAIMLXLocal) && !summaryStreamText.isEmpty {
                            ScrollView {
                                Text(summaryStreamText)
                                    .font(.body)
                                    .foregroundStyle(.primary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding()
                            }
                            .background(colorScheme == .dark ? Color.black : AppColors.systemGray6)
                            .cornerRadius(10)
                        } else {
                            VStack(spacing: 8) {
                                ProgressView()
                                Text("Summarizing post...")
                                    .foregroundColor(.secondary)
                                    .font(.caption)
                            }
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(colorScheme == .dark ? Color.black : AppColors.systemGray6)
                            .cornerRadius(10)
                        }
                    }
                    Divider()
                } else if appState.isWaitingForAppleIntelligence && visiblePostSummary == nil {
                    VStack(spacing: 16) {
                        HStack {
                            Text("Summary")
                                .font(.headline)
                            Spacer()
                        }
                        VStack(spacing: 8) {
                            ProgressView()
                            Text(appState.appleIntelligenceWaitProgress)
                                .foregroundColor(.secondary)
                                .font(.caption)
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(colorScheme == .dark ? Color.black : AppColors.systemGray6)
                        .cornerRadius(10)
                    }
                    Divider()
                } else if let summary = visiblePostSummary,
                          !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Summary")
                                .font(.headline)
                            Spacer()
                            
                            // TTS Controls with LiquidGlassButtonStyle
                            HStack(spacing: 12) {
                                // Cloud TTS button
                                Button {
                                    speakPostSummary(summary)
                                } label: {
                                    Image(systemName: "speaker.wave.2")
                                        .font(.subheadline)
                                }
                                .buttonStyle(LiquidGlassButtonStyle())
                                .ttsActiveGlow(isSynthesizingSpeechSummary, color: .blue)
                                .help("Read aloud (Cloud)")
                                .disabled(isSynthesizingSpeechSummary || isSpeakingLocallySummary || summary.isEmpty)
                                
                                // Stop speech
                                Button {
                                    stopPostSummarySpeech()
                                } label: {
                                    Image(systemName: "stop.fill")
                                        .font(.subheadline)
                                }
                                .buttonStyle(LiquidGlassButtonStyle())
                                .help("Stop speech")
                                
                                // Local TTS button
                                Button {
                                    speakPostSummaryLocally(summary)
                                } label: {
                                    Image(systemName: "speaker.wave.2.circle")
                                        .font(.subheadline)
                                }
                                .buttonStyle(LiquidGlassButtonStyle())
                                .ttsActiveGlow(isSpeakingLocallySummary, color: .green)
                                .help("Read aloud (Local)")
                                .disabled(isSynthesizingSpeechSummary || summary.isEmpty)
                            }
                        }
                        
                        // Directly render markdown content
                        if colorScheme == .dark {
                            SelectableText(.init(summary))
                                .font(.body)
                                .onAskAI { selection in
                                    askAIFromRedditSelection(selection, post: post, action: .standard)
                                }
                                .onAskAIWeb { selection in
                                    askAIFromRedditSelection(selection, post: post, action: .web)
                                }
                                .padding()
                                .background(Color.black)
                                .cornerRadius(10)
                        } else {
                            SelectableText(.init(summary))
                                .font(.body)
                                .onAskAI { selection in
                                    askAIFromRedditSelection(selection, post: post, action: .standard)
                                }
                                .onAskAIWeb { selection in
                                    askAIFromRedditSelection(selection, post: post, action: .web)
                                }
                                .padding()
                                .background(.regularMaterial)
                                .cornerRadius(10)
                        }
                        
                        // TTS status indicators
                        if isSynthesizingSpeechSummary {
                            HStack {
                                ProgressView()
                                    .scaleEffect(0.7)
                                    .padding(.trailing, 5)
                                Text("Reading summary...")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        } else if isSpeakingLocallySummary {
                            HStack {
                                ProgressView()
                                    .scaleEffect(0.7)
                                    .padding(.trailing, 5)
                                Text("Reading with local TTS...")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        
                        if let error = speechSynthesisErrorSummary {
                            Text(error)
                                .font(.caption)
                                .foregroundColor(.red)
                        }

                        // Throughput badge for on-device providers (post summary)
                        let _redditSummaryProvider = appState.settings.selectedSummaryProvider
                        if (_redditSummaryProvider == .mlxLocal || _redditSummaryProvider == .coreAIMLXLocal || _redditSummaryProvider == .appleLocal || _redditSummaryProvider == .applePCCGateway || _redditSummaryProvider == .summarizeDaemon),
                           !appState.mlxLastThroughput.isEmpty {
                            HStack(spacing: 4) {
                                Image(systemName: "cpu").font(.caption2)
                                Text(appState.mlxLastThroughput).font(.caption2).monospacedDigit()
                            }
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
                        }
                    }
                    Divider()
                }

                // Display post content if available
                if !post.content.isEmpty {
                    redditBodyView(for: post.content)
                    .padding(.bottom, 8)
                }
                
                // Show the main image if available (outside content check)
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
                // Filter out the main image to avoid showing it twice
                let additionalImages = post.allImageURLs.filter { $0 != post.bestImageURL }
                if !additionalImages.isEmpty {
                    VStack(alignment: .leading) {
                        Text("More Images:")
                            .font(.headline)
                            .padding(.top, 8)
                        
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 16) {
                                ForEach(additionalImages, id: \.absoluteString) { url in
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
                    Divider()
                }
                
                // Only show Source section if no image is being displayed
                                if let url = post.url {
                                    let hasDisplayedImage = post.bestImageURL != nil
                                    
                                    // Show source section only when no image is displayed
                                    if !hasDisplayedImage {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text("Source:")
                                                .font(.subheadline)
                                                .fontWeight(.semibold)
                                            
                                            // Show the URL as a link, not as an image
                                            Link(url.absoluteString, destination: url)
                                                .font(.subheadline)
                                                .lineLimit(1)
                                                .truncationMode(.middle)
                                        }
                                        .padding(.bottom, 8)
                                        .onAppear {
                                            print("🔍 Source section evaluation for '\(post.title.prefix(30))...'")
                                            print("  - post.url: \(url.absoluteString)")
                                            print("  - post.bestImageURL: \(post.bestImageURL?.absoluteString ?? "nil")")
                                            print("  - hasDisplayedImage: \(hasDisplayedImage)")
                                            print("✅ Showing Source section for '\(post.title.prefix(30))...'")
                                        }
                                        Divider()
                                    }
                                }
                
                if isLoadingComments && commentSummary == nil && !comments.isEmpty {
                    VStack(spacing: 16) {
                        HStack {
                            Text("Comment Summary")
                                .font(.headline)
                            Spacer()
                        }
                        VStack(spacing: 8) {
                            ProgressView()
                            Text("Summarizing \(comments.count) comments...")
                                .foregroundColor(.secondary)
                                .font(.caption)
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(colorScheme == .dark ? Color.black : AppColors.systemGray6)
                        .cornerRadius(10)
                    }
                    Divider()
                } else if appState.isWaitingForCommentSummary && commentSummary == nil && !comments.isEmpty {
                    VStack(spacing: 16) {
                        HStack {
                            Text("Comment Summary")
                                .font(.headline)
                            Spacer()
                        }
                        VStack(spacing: 8) {
                            ProgressView()
                            Text(appState.commentSummaryWaitProgress)
                                .foregroundColor(.secondary)
                                .font(.caption)
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(colorScheme == .dark ? Color.black : AppColors.systemGray6)
                        .cornerRadius(10)
                    }
                    Divider()
                } else if let summary = commentSummary {
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
                            // Directly render markdown content
                            if colorScheme == .dark {
                                SelectableText(.init(summary.summary))
                                    .font(.body)
                                    .onAskAI { selection in
                                        askAIFromRedditSelection(selection, post: post, action: .standard)
                                    }
                                    .onAskAIWeb { selection in
                                        askAIFromRedditSelection(selection, post: post, action: .web)
                                    }
                                    .padding()
                                    .background(Color.black)
                                    .cornerRadius(10)
                            } else {
                                SelectableText(.init(summary.summary))
                                    .font(.body)
                                    .onAskAI { selection in
                                        askAIFromRedditSelection(selection, post: post, action: .standard)
                                    }
                                    .onAskAIWeb { selection in
                                        askAIFromRedditSelection(selection, post: post, action: .web)
                                    }
                                    .padding()
                                    .background(.regularMaterial)
                                    .cornerRadius(10)
                            }
                        }
                        // Throughput badge for on-device providers (comment summary)
                        let _redditCommentSummaryProvider = appState.settings.selectedSummaryProvider
                        if (_redditCommentSummaryProvider == .mlxLocal || _redditCommentSummaryProvider == .coreAIMLXLocal || _redditCommentSummaryProvider == .appleLocal || _redditCommentSummaryProvider == .applePCCGateway || _redditCommentSummaryProvider == .summarizeDaemon),
                           !appState.mlxLastThroughput.isEmpty {
                            HStack(spacing: 4) {
                                Image(systemName: "cpu").font(.caption2)
                                Text(appState.mlxLastThroughput).font(.caption2).monospacedDigit()
                            }
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
                        }
                    }
                    Divider()
                }

                // Display comments section
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text(isLoadingComments ? "Comments" : "\(comments.count) Comments")
                            .font(.system(size: 20, weight: .semibold))
                        
                        if isLoadingComments {
                            ProgressView()
                                .padding(.leading, 8)
                        }
                        
                        Spacer()
                        
                        if !comments.isEmpty {
                            Menu {
                                ForEach(RedditService.CommentSortOption.allCases) { sortOption in
                                    Button {
                                        selectCommentSort(sortOption, for: post)
                                    } label: {
                                        Label(
                                            sortOption.displayName,
                                            systemImage: sortOption == selectedCommentSort ? "checkmark" : "arrow.up.arrow.down"
                                        )
                                    }
                                    .disabled(sortOption == selectedCommentSort)
                                }
                            } label: {
                                HStack(spacing: 4) {
                                    Text(selectedCommentSort.displayName)
                                    Image(systemName: "chevron.down")
                                        .font(.caption.weight(.semibold))
                                }
                            }
                            .font(.subheadline.weight(.medium))
                            .foregroundColor(.secondary)
                            .padding(.trailing, 4)
                            .disabled(isLoadingComments)
                            .accessibilityLabel("Comment sort")

                            // Add Deep Analysis Button
                            Button {
                                analyticsProviderOverride = nil
                                isShowingAnalytics = true
                            } label: {
                                Image(systemName: "chart.pie.fill")
                                    .font(.subheadline)
                            }
                            .accessibilityLabel("Deep Analysis")
                            .buttonStyle(LiquidGlassButtonStyle())

                            if shouldShowExplicitWebAIControls {
                                Menu {
                                    Button {
                                        summarizeComments(for: post, forceWebAI: true)
                                    } label: {
                                        Label("Comment Summary", systemImage: "text.redaction")
                                    }

                                    Button {
                                        analyticsProviderOverride = .webAI
                                        isShowingAnalytics = true
                                    } label: {
                                        Label("Deep Analysis", systemImage: "chart.pie.fill")
                                    }
                                } label: {
                                    Image(systemName: "globe")
                                        .font(.subheadline)
                                }
                                .buttonStyle(LiquidGlassButtonStyle())
                                .help("Send comment prompts to \(appState.settings.selectedWebAIProvider.displayName)")
                            }
                            
                            Button(action: {
                                print("📱 Summarize button pressed - clearing summary and calling summarizeComments")
                                commentSummary = nil
                                summarizeComments(for: post)
                            }) {
                                Image(systemName: "text.redaction")
                                    .font(.subheadline)
                            }
                            .accessibilityLabel("Summarize")
                            .disabled(isLoadingComments)
                            .buttonStyle(LiquidGlassButtonStyle())
                            
                            Button(action: {
                                showQAInterface.toggle()
                            }) {
                                Image(systemName: showQAInterface ? "xmark.circle" : "questionmark.circle")
                                    .font(.subheadline)
                            }
                            .accessibilityLabel(showQAInterface ? "Hide Q&A" : "Ask")
                            .disabled(isLoadingComments)
                            .buttonStyle(LiquidGlassButtonStyle())
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
                    } else if let banner = commentBanner, comments.isEmpty {
                        RedditRateLimitBanner(status: banner)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                    } else if let errorMessage = commentLoadError, comments.isEmpty {
                        Text(errorMessage)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
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
                                
                                if #available(iOS 26.0, *) {
                                    TextField("Type your question...", text: $questionText)
                                        .textFieldStyle(LiquidGlassTextFieldStyle())
                                        .disabled(isProcessingQuestion)
                                        .onSubmit {
                                            if !questionText.isEmpty && !isProcessingQuestion {
                                                askQuestion(post: post)
                                            }
                                        }
                                        .onAppear {
                                            print("📱 RedditDetailView: Q&A interface appeared")
                                        }
                                } else {
                                    TextField("Type your question...", text: $questionText)
                                        .textFieldStyle(AdaptiveLiquidGlassTextFieldStyle(cornerRadius: 12, tintColor: .blue.opacity(0.3)))
                                        .disabled(isProcessingQuestion)
                                        .onSubmit {
                                            if !questionText.isEmpty && !isProcessingQuestion {
                                                askQuestion(post: post)
                                            }
                                        }
                                        .onAppear {
                                            print("📱 RedditDetailView: Q&A interface appeared")
                                        }
                                }
                                
                                HStack {
                                    Button(action: {
                                        if !questionText.isEmpty {
                                            askQuestion(post: post)
                                        }
                                    }) {
                                        Image(systemName: "questionmark.circle")
                                            .font(.subheadline)
                                    }
                                    .accessibilityLabel("Ask")
                                    .buttonStyle(LiquidGlassButtonStyle())
                                    .disabled(questionText.isEmpty || isProcessingQuestion)

                                    if shouldShowExplicitWebAIControls {
                                        Button(action: {
                                            askWebQuestion(post: post)
                                        }) {
                                            Image(systemName: "globe")
                                                .font(.subheadline)
                                        }
                                        .accessibilityLabel(appState.settings.selectedWebAIProvider.displayName)
                                        .buttonStyle(LiquidGlassButtonStyle())
                                        .disabled(questionText.isEmpty || isProcessingQuestion)
                                    }
                                    
                                    Button(action: {
                                        showQAInterface = false
                                        questionText = ""
                                        answerText = "Ask a question about this post or its comments..."
                                        answerParagraphs = nil
                                        commentsSentToLLMCount = nil
                                        print("📱 RedditDetailView: Q&A interface canceled by user")
                                    }) {
                                        Image(systemName: "xmark.circle")
                                            .font(.subheadline)
                                    }
                                    .accessibilityLabel("Cancel")
                                    .buttonStyle(LiquidGlassButtonStyle())
                                    
                                    Spacer()
                                }
                                
                                let qaStreamText = appState.mlxStreamingText
                                if isProcessingQuestion && (appState.settings.selectedSummaryProvider == .mlxLocal || appState.settings.selectedSummaryProvider == .coreAIMLXLocal) && !qaStreamText.isEmpty {
                                    Text(qaStreamText)
                                        .font(.body)
                                        .foregroundColor(.primary)
                                        .padding(.vertical, 16)
                                        .padding(.horizontal, 20)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                } else if let paragraphs = answerParagraphs, !paragraphs.isEmpty {
                                    SelectableText(paragraphs.joined(separator: "\n\n"))
                                        .font(.body)
                                        .foregroundColor(.primary)
                                        .onAskAI { selection in
                                            askAIFromRedditSelection(selection, post: post, action: .standard)
                                        }
                                        .onAskAIWeb { selection in
                                            askAIFromRedditSelection(selection, post: post, action: .web)
                                        }
                                        .padding(.vertical, 16)
                                        .padding(.horizontal, 20)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                } else {
                                    // Fallback to markdown rendering if JSON decoding fails
                                    SelectableText(answerText)
                                        .font(.body)
                                        .foregroundColor(.primary)
                                        .onAskAI { selection in
                                            askAIFromRedditSelection(selection, post: post, action: .standard)
                                        }
                                        .onAskAIWeb { selection in
                                            askAIFromRedditSelection(selection, post: post, action: .web)
                                        }
                                        .padding(.vertical, 16)
                                        .padding(.horizontal, 20)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                HStack(spacing: 12) {
                                    // Cloud TTS button
                                    Button {
                                        speakAnswerQA(answerText)
                                    } label: {
                                        Image(systemName: "speaker.wave.2")
                                            .font(.subheadline)
                                    }
                                    .buttonStyle(LiquidGlassButtonStyle())
                                    .ttsActiveGlow(isSynthesizingSpeechQA, color: .blue)
                                    .help("Read aloud (Cloud)")
                                    .disabled(isSynthesizingSpeechQA || isSpeakingLocallyQA || answerText.isEmpty || answerText == "Ask a question about this post or its comments...")
                                    
                                    // Stop speech
                                    Button {
                                        stopQASpeech()
                                    } label: {
                                        Image(systemName: "stop.fill")
                                            .font(.subheadline)
                                    }
                                    .buttonStyle(LiquidGlassButtonStyle())
                                    .help("Stop speech")
                                    
                                    // Local TTS button
                                    Button {
                                        speakAnswerLocallyQA(answerText)
                                    } label: {
                                        Image(systemName: "speaker.wave.2.circle")
                                            .font(.subheadline)
                                    }
                                    .buttonStyle(LiquidGlassButtonStyle())
                                    .ttsActiveGlow(isSpeakingLocallyQA, color: .green)
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
                                            .font(.subheadline)
                                    }
                                    .buttonStyle(LiquidGlassButtonStyle())
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
                                } else if appState.isWaitingForRedditQA {
                                    HStack {
                                        ProgressView()
                                            .scaleEffect(0.7)
                                            .padding(.trailing, 5)
                                        Text(appState.redditQAWaitProgress)
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

                                // Throughput badge for on-device providers (Q&A only)
                                let _redditQAProvider = appState.settings.selectedSummaryProvider
                                if (_redditQAProvider == .mlxLocal || _redditQAProvider == .coreAIMLXLocal || _redditQAProvider == .appleLocal || _redditQAProvider == .applePCCGateway || _redditQAProvider == .summarizeDaemon),
                                   !appState.mlxLastQAThroughput.isEmpty,
                                   !isProcessingQuestion,
                                   answerText != "Ask a question about this post or its comments..." {
                                    HStack(spacing: 4) {
                                        Image(systemName: "cpu").font(.caption2)
                                        Text(appState.mlxLastQAThroughput).font(.caption2).monospacedDigit()
                                    }
                                    .foregroundStyle(.secondary)
                                    .padding(.top, 4)
                                }
                            }
                            .padding()
                            .modifier(AdaptiveGlassModifier(cornerRadius: 12, tintColor: .blue.opacity(0.1)))
                            .padding(.bottom, 16)
                        }
                        
                        // Display limited comments with option to load more
                        CommentThreadView(comments: displayedComments, post: post)
                        
                        if hasMoreCommentsToLoad {
                            Button {
                                print("🔵 Load more comments button tapped")
                                loadMoreComments()
                            } label: {
                                HStack {
                                    Image(systemName: "arrow.down.circle.fill")
                                        .font(.system(size: 20))
                                    Text("Load more comments")
                                        .font(.system(size: 16, weight: .medium))
                                }
                                .foregroundColor(.white)
                                .padding(.horizontal, 20)
                                .padding(.vertical, 12)
                                .background(Color.blue)
                                .cornerRadius(25)
                            }
                            .buttonStyle(PlainButtonStyle()) // Use plain style to avoid interference
                            .padding(.vertical, 16)
                            .onAppear {
                                print("📱 Load more comments button appeared, hasMoreCommentsToLoad: \(hasMoreCommentsToLoad)")
                            }
                        }
                    }
                }
                .padding(14)
                .background {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(.ultraThinMaterial)
                        .overlay(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(
                                    colorScheme == .dark
                                        ? Color(red: 0.045, green: 0.047, blue: 0.075).opacity(0.86)
                                        : Color.white.opacity(0.82)
                                )
                        )
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(
                            colorScheme == .dark ? Color.white.opacity(0.12) : Color.black.opacity(0.08),
                            lineWidth: 1
                        )
                )
                .overlay(alignment: .top) {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.white.opacity(colorScheme == .dark ? 0.08 : 0.45), lineWidth: 1)
                        .blendMode(.screen)
                }
                .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.34 : 0.1), radius: 24, x: 0, y: 12)
            }
            .padding()
            #if os(iOS)
            // Add top padding for navigation overlay - balanced for iPhone and iPad
            .padding(.top, UIDevice.current.userInterfaceIdiom == .phone ? 120 : 180)
            #endif
            // No extra top padding needed on macOS since there's no overlay navigation
            #if os(iOS)
            // Apply enhanced swipe back only for iPad
            .modifier(ConditionalEnhancedSwipeBack(isEnabled: UIDevice.current.userInterfaceIdiom != .phone, appState: appState))
            #else
            .enhancedSwipeBack {
                appState.navigateBack()
            }
            #endif
        }
        
        .overlay(alignment: .bottomTrailing) {
            #if os(iOS)
            if UIDevice.current.userInterfaceIdiom != .phone {
                Button(action: {
                    withAnimation(.easeInOut) {
                        proxy.scrollTo(redditTopAnchor, anchor: .top)
                    }
                }) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2.weight(.semibold))
                }
                .buttonStyle(LiquidGlassButtonStyle())
                .padding(.trailing, 24)
                .padding(.bottom, 24)
            }
            #else
            Button(action: {
                withAnimation(.easeInOut) {
                    proxy.scrollTo(redditTopAnchor, anchor: .top)
                }
            }) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2.weight(.semibold))
            }
            .buttonStyle(LiquidGlassButtonStyle())
            .padding(.trailing, 24)
            .padding(.bottom, 24)
            #endif
        }
        
        
        // Use this key view ID to ensure proper reconstruction when post changes
        .id("reddit-detail-\(post.id)")
        #if os(iOS)
        // On iPhone, use standard navigation bar
        .navigationBarHidden(UIDevice.current.userInterfaceIdiom != .phone)
        #endif
        // Fallback notification overlay
        .overlay(
            VStack {
                if appState.showFallbackNotification {
                    HStack {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .foregroundColor(.orange)
                            .font(.caption)
                        Text(appState.fallbackNotification)
                            .font(.caption)
                            .foregroundColor(.primary)
                            .multilineTextAlignment(.leading)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial)
                    .cornerRadius(8)
                    .shadow(color: .black.opacity(0.1), radius: 4, x: 0, y: 2)
                    .padding(.horizontal, 16)
                    .padding(.top, 80) // Account for navigation
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .animation(.spring(response: 0.6, dampingFraction: 0.8), value: appState.showFallbackNotification)
                }
                Spacer()
            }
        )
        // Add sheet for Analytics View
        .sheet(isPresented: $isShowingAnalytics, onDismiss: {
            analyticsProviderOverride = nil
        }) {
            // Ensure comments are not empty before presenting
            if !comments.isEmpty {
                // Present the integrated view
                CommentAnalyticsViewIntegrated(
                    comments: comments,
                    providerOverride: analyticsProviderOverride
                )
                    .id(analyticsProviderOverride?.rawValue ?? "settings")
                    .environmentObject(appState) // Pass environment object
                    #if os(iOS)
                    .presentationDetents([.large])
                    .presentationCornerRadius(40) // Balanced radius to prevent clipping
                    .presentationBackground(.ultraThinMaterial) // Ultra translucent background
                    .presentationBackgroundInteraction(.enabled)
                    #endif
            } else {
                // Provide a fallback view to satisfy the ViewBuilder type checker
                EmptyView()
            }
        }
        // Add sheet for image popup (consistent with comment images)
        #if os(iOS)
        .fullScreenCover(isPresented: $showingImagePopup) {
            if let imageURL = selectedImageURL {
                ImagePopupView(imageURL: imageURL)
                    .onAppear {
                        print("Showing Reddit post image popup with URL: \(imageURL)")
                    }
            } else {
                EmptyView()
            }
        }
        #else
        .sheet(isPresented: $showingImagePopup) {
            if let imageURL = selectedImageURL {
                let screen = NSScreen.main?.visibleFrame ?? NSScreen.main?.frame ?? .zero
                let preferredWidth = max(min(screen.width * 0.55, 820), 460)
                let preferredHeight = max(min(screen.height * 0.65, 820), 420)
                ImagePopupView(imageURL: imageURL)
                    .frame(width: preferredWidth, height: preferredHeight)
                    .background(Color.black.opacity(0.9))
                    .cornerRadius(20)
                    .onAppear {
                        print("Showing Reddit post image popup with URL: \(imageURL)")
                    }
            } else {
                // Provide a fallback view to satisfy the ViewBuilder type checker
                EmptyView()
            }
        }
        #endif
    }
    }

    private func openPostLink(_ post: RedditPost) {
        if let directURL = post.url {
            #if os(macOS)
            NSWorkspace.shared.open(directURL)
            #else
            UIApplication.shared.open(directURL)
            #endif
            return
        }
        
        guard let fallbackURL = URL(string: "https://www.reddit.com/r/\(post.subreddit)/comments/\(post.id)") else {
            return
        }
        
        #if os(macOS)
        NSWorkspace.shared.open(fallbackURL)
        #else
        UIApplication.shared.open(fallbackURL)
        #endif
    }
    
    private func loadComments(for post: RedditPost) {
        cancellables.removeAll()
        commentLoadTask?.cancel()

        isLoadingComments = true
        commentBanner = nil
        commentLoadError = nil
        comments = []
        displayedComments = []
        hasMoreCommentsToLoad = false

        print("📱 RedditDetailView: Preparing to load \(selectedCommentSort.displayName) comments for post ID: \(post.id) in r/\(post.subreddit)")

        commentLoadTask = Task(priority: .userInitiated) {
            let result = await appState.redditService.fetchCommentsDetailed(for: post.id, in: post.subreddit, limit: 1000, depth: 10, sortOption: selectedCommentSort)
            if Task.isCancelled { return }
            await MainActor.run {
                applyCommentResult(result, for: post)
            }
        }
    }

    @MainActor
    private func applyCommentResult(_ result: RedditCommentFetchResult, for post: RedditPost) {
        guard post.id == appState.selectedRedditPost?.id else {
            print("⚠️ RedditDetailView: Skipping comment update – post changed mid-flight")
            return
        }

        commentBanner = nil
        commentLoadError = nil

        if let status = result.rateLimit, status.isRateLimited {
            commentBanner = buildRateLimitMessage(for: post, status: status)
            print("⚠️ RedditDetailView: Rate limited while loading comments – statusCode=\(status.statusCode)")
        } else if let error = result.errorDescription, !error.isEmpty, result.comments.isEmpty {
            commentLoadError = error
            print("❌ RedditDetailView: Comment load error – \(error)")
        }

        let filtered = result.comments.filter { $0.author.lowercased() != "automoderator" }
        comments = filtered

        if filtered.count > maxDisplayComments {
            displayedComments = Array(filtered.prefix(maxDisplayComments))
            hasMoreCommentsToLoad = true
            print("📱 RedditDetailView: Limiting displayed comments to \(displayedComments.count) of \(filtered.count) total")
        } else {
            displayedComments = filtered
            hasMoreCommentsToLoad = false
        }

        isLoadingComments = false
        print("✅ RedditDetailView: Loaded \(filtered.count) comments for post ID: \(post.id)")
        commentLoadTask = nil
    }

    private func selectCommentSort(_ sortOption: RedditService.CommentSortOption, for post: RedditPost) {
        guard sortOption != selectedCommentSort else { return }

        selectedCommentSort = sortOption
        commentSummary = nil
        commentsSentToLLMCount = nil
        answerText = "Ask a question about this post or its comments..."
        answerParagraphs = nil

        loadComments(for: post)
    }

    private func buildRateLimitMessage(for post: RedditPost, status: RedditRateLimitStatus) -> RedditStatusMessage {
        var parts: [String] = []
        if let rawMessage = status.message?.trimmingCharacters(in: .whitespacesAndNewlines), !rawMessage.isEmpty {
            parts.append(rawMessage)
        } else {
            parts.append("Reddit temporarily rate limited this thread.")
        }

        if let remaining = status.remaining {
            parts.append("Remaining quota: \(Int(remaining.rounded()))")
        }

        if let resetDate = status.approximateResetDate {
            let seconds = max(Int(resetDate.timeIntervalSinceNow.rounded()), 0)
            if seconds > 0 {
                parts.append("Resets in ~\(seconds)s")
            }
        }

        let text = "r/\(post.subreddit): " + parts.joined(separator: " • ")
        return RedditStatusMessage(
            subreddit: post.subreddit,
            text: text,
            statusCode: status.statusCode,
            resetDate: status.approximateResetDate,
            remaining: status.remaining,
            capturedAt: status.capturedAt
        )
    }
    
    private func loadMoreComments() {
        print("📱 RedditDetailView: loadMoreComments() called")
        
        // Determine how many more comments to load
        let currentCount = displayedComments.count
        let totalComments = comments.count
        let remainingComments = totalComments - currentCount
        let nextBatchSize = min(maxDisplayComments, remainingComments)
        
        print("📱 RedditDetailView: Current: \(currentCount), Total: \(totalComments), Remaining: \(remainingComments), NextBatch: \(nextBatchSize)")
        
        // Validate that we have comments to load
        guard totalComments > 0 else {
            print("❌ RedditDetailView: No comments available to load")
            hasMoreCommentsToLoad = false
            return
        }
        
        guard currentCount < totalComments else {
            print("❌ RedditDetailView: Already showing all comments (\(currentCount) of \(totalComments))")
            hasMoreCommentsToLoad = false
            return
        }
        
        if nextBatchSize > 0 {
            let endIndex = min(currentCount + nextBatchSize, totalComments)
            let additionalComments = Array(comments[currentCount..<endIndex])
            
            // Update state on main thread
            DispatchQueue.main.async {
                self.displayedComments.append(contentsOf: additionalComments)
                
                // Check if we have more comments to load
                self.hasMoreCommentsToLoad = self.displayedComments.count < self.comments.count
                
                print("✅ RedditDetailView: Loaded \(additionalComments.count) more comments, now showing \(self.displayedComments.count) of \(self.comments.count)")
                print("📱 RedditDetailView: hasMoreCommentsToLoad = \(self.hasMoreCommentsToLoad)")
            }
        } else {
            print("⚠️ RedditDetailView: nextBatchSize is 0, no more comments to load")
            DispatchQueue.main.async {
                self.hasMoreCommentsToLoad = false
            }
        }
    }
    
    private func summarizeComments(for post: RedditPost, forceWebAI: Bool = false) {
        guard !comments.isEmpty else { return }
        
        print("⚙️ RedditDetailView: Summarizing \(comments.count) comments for post ID: \(post.id)")
        
        // Ensure we're not already generating a summary
        if isProcessingQuestion {
            print("⚠️ RedditDetailView: Cannot summarize while processing a question")
            return
        }
        
                // Check if we should use Apple Intelligence instead
        if forceWebAI {
            let prompt = appState.commentSummaryPrompt(comments: comments)

            isLoadingComments = true
            self.commentsSentToLLMCount = comments.count

            appState.performWebAIRequest(
                title: "Comment Summary",
                prompt: prompt,
                onSuccess: { summaryText in
                    guard shouldAcceptCommentSummaryResult(for: post) else {
                        print("⚠️ RedditDetailView: Post selection changed before explicit Web AI summary completed, discarding results")
                        self.isLoadingComments = false
                        return
                    }
                    self.commentSummary = CommentSummary(
                        postId: post.id,
                        subreddit: post.subreddit,
                        summary: appState.cleanMarkdownArtifactsForDisplay(summaryText),
                        commentCount: comments.count,
                        topCommenters: [],
                        mainTopics: [],
                        sentiment: .neutral,
                        createdDate: Date()
                    )
                    self.showCommentSummary = true
                    self.isLoadingComments = false
                },
                onFailure: { _ in
                    self.isLoadingComments = false
                }
            )
            return
        } else if appState.settings.selectedSummaryProvider == .appleLocal {
            // Use on-device AI for comment summary with Gemini fallback
            let prompt = appState.commentSummaryPrompt(comments: comments)
            
            // Set loading state
            isLoadingComments = true
            self.commentsSentToLLMCount = comments.count
            
            appState.performLocalWithGeminiFallbackPublic(prompt: prompt, taskName: "Reddit Comment Summary") { summaryText in
                guard shouldAcceptCommentSummaryResult(for: post) else {
                    print("⚠️ RedditDetailView: Post selection changed before Apple Local summary completed, discarding results")
                    self.isLoadingComments = false
                    return
                }
                self.commentSummary = CommentSummary(
                    postId: post.id,
                    subreddit: post.subreddit,
                    summary: appState.cleanMarkdownArtifactsForDisplay(summaryText),
                    commentCount: comments.count,
                    topCommenters: [],
                    mainTopics: [],
                    sentiment: .neutral,
                    createdDate: Date()
                )
                self.showCommentSummary = true
                self.isLoadingComments = false
            }
            return
        } else if appState.settings.selectedSummaryProvider == .appleCloud {
            // Use Apple Cloud via Private Cloud Compute
            print("📱 RedditDetailView: Using Apple Cloud for comment summary")
            
            let prompt = appState.commentSummaryPrompt(comments: comments)
            
            // Set loading state
            isLoadingComments = true
            self.commentsSentToLLMCount = comments.count
            
            appState.launchCloudRequest(for: prompt, type: .commentSummary) { summaryText in
                guard shouldAcceptCommentSummaryResult(for: post) else {
                    print("⚠️ RedditDetailView: Post selection changed before Apple Cloud summary completed, discarding results")
                    self.isLoadingComments = false
                    return
                }
                // Create summary with the result
                self.commentSummary = CommentSummary(
                    postId: post.id,
                    subreddit: post.subreddit,
                    summary: appState.cleanMarkdownArtifactsForDisplay(summaryText),
                    commentCount: comments.count,
                    topCommenters: [],
                    mainTopics: [],
                    sentiment: .neutral,
                    createdDate: Date()
                )
                self.showCommentSummary = true
                self.isLoadingComments = false
            }
            return
        } else if appState.settings.selectedSummaryProvider == .webAI {
            let prompt = appState.commentSummaryPrompt(comments: comments)

            isLoadingComments = true
            self.commentsSentToLLMCount = comments.count

            appState.performWebAIRequest(
                title: "Comment Summary",
                prompt: prompt,
                onSuccess: { summaryText in
                    guard shouldAcceptCommentSummaryResult(for: post) else {
                        print("⚠️ RedditDetailView: Post selection changed before Web AI summary completed, discarding results")
                        self.isLoadingComments = false
                        return
                    }
                    self.commentSummary = CommentSummary(
                        postId: post.id,
                        subreddit: post.subreddit,
                        summary: appState.cleanMarkdownArtifactsForDisplay(summaryText),
                        commentCount: comments.count,
                        topCommenters: [],
                        mainTopics: [],
                        sentiment: .neutral,
                        createdDate: Date()
                    )
                    self.showCommentSummary = true
                    self.isLoadingComments = false
                },
                onFailure: { _ in
                    self.isLoadingComments = false
                }
            )
            return
        } else if appState.settings.selectedSummaryProvider == .applePCCGateway {
            let prompt = appState.commentSummaryPrompt(comments: comments)

            isLoadingComments = true
            self.commentsSentToLLMCount = comments.count

            appState.performPCCGatewaySummaryPublic(prompt: prompt, taskName: "Reddit Comment Summary") { summaryText in
                guard shouldAcceptCommentSummaryResult(for: post) else {
                    print("⚠️ RedditDetailView: Post selection changed before Apple PCC summary completed, discarding results")
                    self.isLoadingComments = false
                    return
                }
                self.commentSummary = CommentSummary(
                    postId: post.id,
                    subreddit: post.subreddit,
                    summary: appState.cleanMarkdownArtifactsForDisplay(summaryText),
                    commentCount: comments.count,
                    topCommenters: [],
                    mainTopics: [],
                    sentiment: .neutral,
                    createdDate: Date()
                )
                self.showCommentSummary = true
                self.isLoadingComments = false
            }
            return
        } else if appState.settings.selectedSummaryProvider == .summarizeDaemon {
            let prompt = appState.commentSummaryPrompt(comments: comments)

            isLoadingComments = true
            self.commentsSentToLLMCount = comments.count

            appState.performSummarizeSummaryPublic(prompt: prompt, taskName: "Reddit Comment Summary") { summaryText in
                guard shouldAcceptCommentSummaryResult(for: post) else {
                    print("⚠️ RedditDetailView: Post selection changed before Summarize summary completed, discarding results")
                    self.isLoadingComments = false
                    return
                }
                self.commentSummary = CommentSummary(
                    postId: post.id,
                    subreddit: post.subreddit,
                    summary: appState.cleanMarkdownArtifactsForDisplay(summaryText),
                    commentCount: comments.count,
                    topCommenters: [],
                    mainTopics: [],
                    sentiment: .neutral,
                    createdDate: Date()
                )
                self.showCommentSummary = true
                self.isLoadingComments = false
            }
            return
        }
        
        // Original Gemini code
        // Set a state flag to indicate we're generating a summary
        isLoadingComments = true
        
        // Use appState's commentSummaryService that already has the API key configured
        let commentsToSummarize = self.comments
        self.commentsSentToLLMCount = commentsToSummarize.count
        
        appState.commentSummaryService.summarizeComments(commentsToSummarize)
            .receive(on: RunLoop.main)
            .sink { summary in
                // Make sure we're still on the same post
                guard shouldAcceptCommentSummaryResult(for: post) else {
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

    private func summarizePost(post: RedditPost, proxy: ScrollViewProxy) {
        let currentComments = comments
        appState.requestSummary(for: nil, redditPost: post, redditComments: currentComments)
    }

    private func shouldAcceptCommentSummaryResult(for post: RedditPost) -> Bool {
        guard let selectedPostID = appState.selectedRedditPost?.id else {
            return false
        }
        return selectedPostID == post.id
    }

    private func askQuestion(post: RedditPost) {
        guard !questionText.isEmpty && !comments.isEmpty else { return }

        print("📱 RedditDetailView: Asking question: \"\(questionText)\" about post \(post.id)")

        // Set loading state
        isProcessingQuestion = true
        answerParagraphs = nil
        answerText = "Thinking..."
        let currentComments = self.comments
        self.commentsSentToLLMCount = currentComments.count

        // Local models (Apple Local, MLX) work better with plain questions.
        // JSON format instructions confuse Apple Intelligence and produce garbled output.
        let provider = appState.settings.selectedSummaryProvider
        let questionToSend: String
        if provider == .appleLocal || provider == .mlxLocal || provider == .coreAIMLXLocal || provider == .applePCCGateway || provider == .summarizeDaemon {
            questionToSend = questionText
        } else {
            questionToSend = """
\(questionText)

FORMAT: Return ONLY a compact JSON array of paragraph strings.
No Markdown, no headings, no bullet points, no code fences, no prose outside JSON.
Example: ["First paragraph.", "Second paragraph."].
Each item ≤ 2–3 sentences.
"""
        }

        // Use AppState's askQuestionAboutRedditPost which handles both Gemini and Apple Intelligence
        appState.askQuestionAboutRedditPost(post: post, comments: currentComments, question: questionToSend) { answer in
            if let paragraphs = decodeParagraphArray(from: answer), !paragraphs.isEmpty {
                self.answerParagraphs = paragraphs
                self.answerText = paragraphs.joined(separator: "\n\n")
            } else {
                self.answerParagraphs = nil
                // Insert paragraph breaks before bold section headers (e.g. **General Positive:**)
                // that MLX outputs inline without newlines, and at sentence boundaries if still one block
                var processed = answer
                // Insert \n\n before bold headers (**Capital...) that follow non-whitespace text
                // Catches `:`, `.`, `)` etc. even with no space before **
                processed = processed.replacingOccurrences(
                    of: #"(\S)[ \t]*(\*\*[A-Z])"#, with: "$1\n\n$2", options: .regularExpression)
                if !processed.contains("\n\n") && processed.count > 300 {
                    // Fallback: split at sentence boundaries (lowercase + . ! ? + optional spaces + Capital)
                    // Catches both zero-space (discussions.Suggestions) and spaced (text. Next) forms
                    processed = processed.replacingOccurrences(
                        of: #"([a-z][.!?])[ \t]*([A-Z])"#, with: "$1\n\n$2", options: .regularExpression)
                }
                self.answerText = formatAskAIResponseForDisplay(processed)
            }
            self.isProcessingQuestion = false
            // Update previous question for next time
            self.previousQuestionText = self.questionText
            print("📱 RedditDetailView: Got answer, updating UI")
        }
    }

    private func askWebQuestion(post: RedditPost) {
        guard !questionText.isEmpty && !comments.isEmpty else { return }

        print("📱 RedditDetailView: Asking WebAI question: \"\(questionText)\" about post \(post.id)")

        isProcessingQuestion = true
        answerParagraphs = nil
        answerText = "Thinking..."
        let currentComments = self.comments
        self.commentsSentToLLMCount = currentComments.count

        appState.askWebQuestionAboutRedditPost(post: post, comments: currentComments, question: questionText) { answer in
            self.answerText = formatAskAIResponseForDisplay(answer)
            self.isProcessingQuestion = false
            self.previousQuestionText = self.questionText
            print("📱 RedditDetailView: Got WebAI answer, updating UI")
        }
    }

    private func askAIFromRedditSelection(_ selection: String, post: RedditPost, action: AskAISelectionAction) {
        let trimmed = selection.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        selectionAskAITask?.cancel()
        isSelectionAskAIInFlight = true
        selectionAskAIResponse = nil
        selectionAskAIError = nil
        showSelectionAskAIResponse = true

        let prompt = appState.redditQAPrompt(
            post: post,
            comments: comments,
            question: "What is said about \(trimmed)?"
        )

        selectionAskAITask = Task {
            let answer = await withCheckedContinuation { continuation in
                switch action {
                case .standard:
                    appState.askQuestionAboutSelection(prompt: prompt) { response in
                        continuation.resume(returning: response)
                    }
                case .web:
                    appState.askWebQuestionAboutSelection(prompt: prompt, title: "Reddit Ask AI Web") { response in
                        continuation.resume(returning: response)
                    }
                }
            }

            await MainActor.run {
                self.selectionAskAIResponse = formatAskAIResponseForDisplay(answer)
                self.isSelectionAskAIInFlight = false
            }
        }
    }

    private func copySelectionAskAIResponse() {
        guard let selectionAskAIResponse, !selectionAskAIResponse.isEmpty else { return }
        #if os(iOS)
        UIPasteboard.general.string = selectionAskAIResponse
        #elseif os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(selectionAskAIResponse, forType: .string)
        #endif
    }

    
   private func decodeParagraphArray(from text: String) -> [String]? {
       var payload = text.trimmingCharacters(in: .whitespacesAndNewlines)

       if payload.hasPrefix("```json") {
           payload = String(payload.dropFirst(7))
       } else if payload.hasPrefix("```") {
           payload = String(payload.dropFirst(3))
       }

       if payload.hasSuffix("```") {
           payload = String(payload.dropLast(3)).trimmingCharacters(in: .whitespacesAndNewlines)
       }

       guard let data = payload.data(using: .utf8) else { return nil }
       do {
           let raw = try JSONSerialization.jsonObject(with: data, options: [])
           guard let array = raw as? [Any] else { return nil }
           let paragraphs = array.compactMap { element -> String? in
               guard let paragraph = element as? String else { return nil }
               let trimmed = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
               return trimmed.isEmpty ? nil : trimmed
           }
           return paragraphs.isEmpty ? nil : paragraphs
       } catch {
           print("⚠️ RedditDetailView: Failed to decode paragraph array - \(error.localizedDescription)")
           return nil
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
    
    // MARK: - TTS Methods for Q&A
    
    private func stopQASpeech() {
        ttsCanceledQA = true
        #if os(iOS)
        audioPlayerQA?.stop()
        audioPlayerQA = nil
        localSpeechSynthQA?.stopSpeaking(at: .immediate)
        #elseif os(macOS)
        audioPlayerQA?.stop()
        audioPlayerQA = nil
        ShortcutsTTS.shared.stopSpeaking()
        localSpeechSynthQA?.stopSpeaking()
        #endif
        nextAudioChunkQA = nil
        isSynthesizingSpeechQA = false
        isSpeakingLocallyQA = false
    }

    private func speakAnswerQA(_ text: String) {
        ttsCanceledQA = false
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
            await appState.summaryService.synthesizeSpeechFastStartSplit(
                text: text,
                onFirstChunk: { data in
                    DispatchQueue.main.async {
                        if !self.ttsCanceledQA { self.playAudioQA(data: data) }
                    }
                },
                onRemainingReady: { data in
                    DispatchQueue.main.async {
                        if self.ttsCanceledQA { return }
                        if let player = self.audioPlayerQA, player.isPlaying {
                            self.nextAudioChunkQA = data
                        } else {
                            self.playAudioQA(data: data)
                        }
                    }
                },
                onComplete: {
                    // handled by delegate chain
                },
                onError: { error in
                    DispatchQueue.main.async {
                        self.speechSynthesisErrorQA = "Speech synthesis failed: \(error.localizedDescription)"
                        self.isSynthesizingSpeechQA = false
                        self.nextAudioChunkQA = nil
                    }
                }
            )
        }
    }
    
    private func playAudioQA(data: Data) {
        #if os(iOS)
        // Stop any existing playback
        audioPlayerQA?.stop()
        
        // Detect format and handle accordingly
        let audioData: Data
        if isMP3Data(data) || isAACData(data) {
            // OpenAI returns MP3 or AAC directly - both are supported by AVAudioPlayer
            audioData = data
        } else {
            // Gemini returns PCM that needs WAV conversion
            audioData = createWavData(from: data, sampleRate: 24000, channels: 1, bitsPerSample: 16)
        }
        
        do {
            audioPlayerQA = try AVAudioPlayer(data: audioData)
            if let player = audioPlayerQA {
                player.prepareToPlay()
                player.delegate = soundDelegateQA
                // Chain the queued remaining chunk if present
                soundDelegateQA.onPlaybackFinished = { [self] in
                    DispatchQueue.main.async {
                        if let next = self.nextAudioChunkQA {
                            self.nextAudioChunkQA = nil
                            self.playAudioQA(data: next)
                        } else {
                            self.isSynthesizingSpeechQA = false
                        }
                    }
                }
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
        if isMP3Data(data) || isAACData(data) {
            // OpenAI returns MP3 or AAC directly - both are supported by AVAudioPlayer
            audioData = data
        } else {
            // Gemini returns PCM that needs WAV conversion
            audioData = createWavData(from: data, sampleRate: 24000, channels: 1, bitsPerSample: 16)
        }
        
        audioPlayerQA = NSSound(data: audioData)
        if let player = audioPlayerQA {
            player.delegate = soundDelegateQA
            soundDelegateQA.onPlaybackFinished = { [self] in
                DispatchQueue.main.async {
                    if let next = self.nextAudioChunkQA {
                        self.nextAudioChunkQA = nil
                        self.playAudioQA(data: next)
                    } else {
                        self.isSynthesizingSpeechQA = false
                    }
                }
            }
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
        // Check if Kokoro engine is selected
        let settingsQA = PersistenceManager.shared.loadSettings()
        if settingsQA.localTTSEngine == .kokoro {
            guard KokoroTTSService.shared.isAvailable else {
                isSpeakingLocallyQA = false
                speechSynthesisErrorQA = "MLX TTS is not available. Add the MLXAudio package and model access."
                return
            }
            if isSpeakingLocallyQA {
                localTTSTaskQA?.cancel()
                localTTSTaskQA = nil
                audioPlayerQA?.stop()
                localSpeechSynthQA?.stopSpeaking(at: .immediate)
                isSpeakingLocallyQA = false
                return
            }
            guard !text.isEmpty && text != "Ask a question about this post or its comments..." else {
                speechSynthesisErrorQA = "No answer available to read."
                return
            }
            audioPlayerQA?.stop()
            isSpeakingLocallyQA = true
            isSynthesizingSpeechQA = false
            startKokoroPlaybackRedditQA(
                text: text,
                voice: settingsQA.kokoroVoice,
                speed: settingsQA.kokoroSpeed,
                setAudioPlayer: { player in audioPlayerQA = player },
                soundDelegate: soundDelegateQA,
                taskStore: &localTTSTaskQA,
                onCompleted: {
                    isSpeakingLocallyQA = false
                    localTTSTaskQA = nil
                },
                onError: { message in
                    speechSynthesisErrorQA = message
                    isSpeakingLocallyQA = false
                }
            )
            return
        }

        // Check if running on Mac as iPad app - use Shortcuts instead
        if ProcessInfo.processInfo.isiOSAppOnMac {
            // Toggle off if already speaking (can't really stop shortcuts)
            if isSpeakingLocallyQA {
                ShortcutsTTS.shared.stopSpeaking()
                isSpeakingLocallyQA = false
                return
            }

            guard !text.isEmpty && text != "Ask a question about this post or its comments..." else {
                speechSynthesisErrorQA = "No answer available to read."
                return
            }

            // Stop any other audio playing
            audioPlayerQA?.stop()
            
            // Start speaking via Shortcuts
            isSpeakingLocallyQA = true
            isSynthesizingSpeechQA = false
            
            let success = ShortcutsTTS.shared.speakText(text) {
                // Completion handler - called when speech ends (estimated)
                DispatchQueue.main.async {
                    self.isSpeakingLocallyQA = false
                }
            }
            
            if !success {
                isSpeakingLocallyQA = false
                speechSynthesisErrorQA = "Failed to start Shortcuts TTS"
            }
            
            return
        }
        
        // Original iOS code for real devices
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
        utterance.rate = 0.52  // Slightly slower for clarity
        utterance.pitchMultiplier = 1.0
        utterance.volume = 1.0
        utterance.preUtteranceDelay = 0.0
        utterance.postUtteranceDelay = 0.0

        // Use saved voice from settings (same as articles)
        if let savedVoiceID = UserDefaults.standard.string(forKey: "LocalTTS.iOSOnMac.SelectedVoiceID"),
           !savedVoiceID.isEmpty,
           let savedVoice = AVSpeechSynthesisVoice(identifier: savedVoiceID) {
            // Only skip com.apple.voice on Mac (they don't work there)
            if ProcessInfo.processInfo.isiOSAppOnMac && savedVoice.identifier.contains("com.apple.voice") {
                print("🔊 [Reddit Q&A] Skipping com.apple.voice on Mac")
            } else {
                utterance.voice = savedVoice
                let qualityStr = savedVoice.quality == .premium ? "PREMIUM" : 
                                savedVoice.quality == .enhanced ? "Enhanced" : "Default"
                print("🔊 [Reddit Q&A] Using saved voice: \(savedVoice.name) [\(qualityStr)]")
            }
        }
        
        // If no saved voice, find the best available
        if utterance.voice == nil {
            let currentLang = AVSpeechSynthesisVoice.currentLanguageCode()
            let allVoices = AVSpeechSynthesisVoice.speechVoices()
            
            // Filter for current language (and exclude com.apple.voice on Mac)
            let availableVoices: [AVSpeechSynthesisVoice]
            if ProcessInfo.processInfo.isiOSAppOnMac {
                availableVoices = allVoices.filter { 
                    $0.language == currentLang && !$0.identifier.contains("com.apple.voice")
                }
            } else {
                availableVoices = allVoices.filter { $0.language == currentLang }
            }
            
            // Simple priority: Premium > Enhanced > Default
            let premiumVoices = availableVoices.filter { $0.quality == .premium }
            let enhancedVoices = availableVoices.filter { $0.quality == .enhanced }
            
            if let premium = premiumVoices.first {
                utterance.voice = premium
                print("🔊 [Reddit Q&A] Using PREMIUM voice: \(premium.name)")
            } else if let enhanced = enhancedVoices.first {
                utterance.voice = enhanced
                print("🔊 [Reddit Q&A] Using Enhanced voice: \(enhanced.name)")
            } else {
                utterance.voice = AVSpeechSynthesisVoice(language: currentLang)
                if let v = utterance.voice {
                    print("🔊 [Reddit Q&A] Using default voice: \(v.name)")
                }
            }
        }
        
        isSpeakingLocallyQA = true
        isSynthesizingSpeechQA = false
        if let synth = localSpeechSynthQA {
            DispatchQueue.main.async { synth.speak(utterance) }
        } else {
            isSpeakingLocallyQA = false
            speechSynthesisErrorQA = "Failed to initialize speech synthesizer."
        }
        #elseif os(macOS)
        // Check if Kokoro engine is selected
        let settingsQA = PersistenceManager.shared.loadSettings()
        if settingsQA.localTTSEngine == .kokoro {
            guard KokoroTTSService.shared.isAvailable else {
                isSpeakingLocallyQA = false
                speechSynthesisErrorQA = "MLX TTS is not available. Add the MLXAudio package and model access."
                return
            }
            if isSpeakingLocallyQA {
                localTTSTaskQA?.cancel()
                localTTSTaskQA = nil
                audioPlayerQA?.stop()
                isSpeakingLocallyQA = false
                return
            }
            guard !text.isEmpty && text != "Ask a question about this post or its comments..." else {
                speechSynthesisErrorQA = "No answer available to read."
                return
            }
            audioPlayerQA?.stop()
            isSpeakingLocallyQA = true
            isSynthesizingSpeechQA = false
            startKokoroPlaybackRedditQA(
                text: text,
                voice: settingsQA.kokoroVoice,
                speed: settingsQA.kokoroSpeed,
                setAudioPlayer: { player in audioPlayerQA = player },
                soundDelegate: soundDelegateQA,
                taskStore: &localTTSTaskQA,
                onCompleted: {
                    isSpeakingLocallyQA = false
                    localTTSTaskQA = nil
                },
                onError: { message in
                    speechSynthesisErrorQA = message
                    isSpeakingLocallyQA = false
                }
            )
            return
        }

        // Toggle off if already speaking (CLI shortcut cannot truly stop mid-stream)
        if isSpeakingLocallyQA {
            ShortcutsTTS.shared.stopSpeaking()
            isSpeakingLocallyQA = false
            return
        }

        guard !text.isEmpty && text != "Ask a question about this post or its comments..." else {
            speechSynthesisErrorQA = "No answer available to read."
            return
        }

        // Stop all other audio
        audioPlayerQA?.stop()

        isSpeakingLocallyQA = true
        isSynthesizingSpeechQA = false

        let success = ShortcutsTTS.shared.speakText(text) {
            DispatchQueue.main.async {
                self.isSpeakingLocallyQA = false
            }
        }

        if !success {
            isSpeakingLocallyQA = false
            speechSynthesisErrorQA = "Failed to start Shortcuts TTS on macOS."
        }
        #endif
    }

    @ViewBuilder
    private func redditBodyView(for content: String) -> some View {
        let blocks = redditBodyDisplayBlocks(from: content)

        if blocks.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    Text(block)
                        .font(.body)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    /// Formats Reddit post bodies conservatively: preserve valid markdown, add paragraph
    /// breaks to dense text when needed, and only auto-link truly raw URLs.
    private func formatRedditContent(_ content: String) -> AttributedString {
        let markdownContent = buildFormattedRedditMarkdown(from: content)

        do {
            return try AttributedString(markdown: markdownContent)
        } catch {
            return AttributedString(makePlainTextRedditFallback(from: markdownContent))
        }
    }

    private func buildFormattedRedditMarkdown(from content: String) -> String {
        let prepared = prepareRedditMarkdown(from: content)
        return restoreProtectedSegments(
            in: prepared.markdown,
            protectedSegments: prepared.protectedSegments,
            excludingKinds: [.markdownImageLink, .imageURL]
        )
    }

    private func redditBodyDisplayBlocks(from content: String) -> [AttributedString] {
        let prepared = prepareRedditMarkdown(from: content)
        let markdownBlocks = splitRedditMarkdownBlocks(prepared.markdown)

        return markdownBlocks.compactMap { block in
            let restoredBlock = restoreProtectedSegments(
                in: block,
                protectedSegments: prepared.protectedSegments,
                excludingKinds: [.markdownImageLink, .imageURL]
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)

            guard !restoredBlock.isEmpty else { return nil }

            do {
                return try AttributedString(markdown: restoredBlock)
            } catch {
                return AttributedString(makePlainTextRedditFallback(from: restoredBlock))
            }
        }
    }

    private func prepareRedditMarkdown(from content: String) -> PreparedRedditMarkdown {
        var normalized = content
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !normalized.isEmpty else {
            return PreparedRedditMarkdown(markdown: normalized, protectedSegments: [])
        }

        normalized = normalized.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)

        var protectedSegments: [RedditProtectedSegment] = []
        normalized = protectMatches(in: normalized, pattern: "(?s)```.*?```", kind: .codeBlock, protectedSegments: &protectedSegments)
        normalized = protectMatches(in: normalized, pattern: "`[^`]+`", kind: .codeSpan, protectedSegments: &protectedSegments)
        normalized = protectMatches(in: normalized, pattern: "!\\[[^\\]]*\\]\\([^\\s]+\\)", kind: .markdownImageLink, protectedSegments: &protectedSegments)
        normalized = protectMatches(in: normalized, pattern: "\\[[^\\]]+\\]\\([^\\s]+\\)", kind: .markdownLink, protectedSegments: &protectedSegments)
        normalized = protectMatches(
            in: normalized,
            pattern: "(?i)https?://[^\\s]+",
            kind: .imageURL,
            protectedSegments: &protectedSegments,
            shouldProtect: { self.isLikelyImageURL($0) }
        )

        normalized = fixMissingSentenceSpacing(in: normalized)

        if shouldSynthesizeParagraphs(in: normalized) {
            normalized = synthesizeParagraphs(in: normalized)
        }

        normalized = autoLinkRawURLs(in: normalized)
        normalized = restoreProtectedSegments(in: normalized, protectedSegments: protectedSegments)
        normalized = normalized.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        return PreparedRedditMarkdown(
            markdown: normalized.trimmingCharacters(in: .whitespacesAndNewlines),
            protectedSegments: protectedSegments
        )
    }

    private func protectMatches(
        in text: String,
        pattern: String,
        kind: RedditProtectedSegmentKind,
        protectedSegments: inout [RedditProtectedSegment],
        shouldProtect: ((String) -> Bool)? = nil
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return text
        }

        let matches = regex.matches(in: text, options: [], range: NSRange(text.startIndex..., in: text))
        var updated = text

        for match in matches.reversed() {
            guard let range = Range(match.range, in: updated) else { continue }
            let original = String(updated[range])

            if let shouldProtect, !shouldProtect(original) {
                continue
            }

            let token = "<<<REDDIT_\(kind.rawValue.uppercased())_\(protectedSegments.count)>>>"
            protectedSegments.append(RedditProtectedSegment(token: token, original: original, kind: kind))
            updated.replaceSubrange(range, with: token)
        }

        return updated
    }

    private func restoreProtectedSegments(
        in text: String,
        protectedSegments: [RedditProtectedSegment],
        excludingKinds: Set<RedditProtectedSegmentKind> = []
    ) -> String {
        var restored = text

        for segment in protectedSegments {
            if excludingKinds.contains(segment.kind) {
                restored = restored.replacingOccurrences(of: segment.token, with: "")
                continue
            }

            restored = restored.replacingOccurrences(of: segment.token, with: segment.original)
        }

        return restored
    }

    private func splitRedditMarkdownBlocks(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        guard let regex = try? NSRegularExpression(pattern: #"\n\s*\n+"#, options: []) else {
            return [text]
        }

        let range = NSRange(text.startIndex..., in: text)
        var blocks: [String] = []
        var lastIndex = text.startIndex

        regex.enumerateMatches(in: text, options: [], range: range) { match, _, _ in
            guard let match, let matchRange = Range(match.range, in: text) else { return }

            let block = String(text[lastIndex..<matchRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !block.isEmpty {
                blocks.append(block)
            }

            lastIndex = matchRange.upperBound
        }

        let tail = String(text[lastIndex...]).trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty {
            blocks.append(tail)
        }

        return blocks
    }

    private func isLikelyImageURL(_ value: String) -> Bool {
        let lowercased = value.lowercased()
        if lowercased.range(of: #"(?i)\.(jpg|jpeg|png|gif|webp)(\?[^[:space:]]*)?$"#, options: .regularExpression) != nil {
            return true
        }

        return lowercased.contains("i.redd.it")
            || lowercased.contains("preview.redd.it")
            || lowercased.contains("external-preview.redd.it")
            || lowercased.contains("v.redd.it")
            || lowercased.contains("imgur.com")
            || lowercased.contains("giphy.com")
            || lowercased.contains("gfycat.com")
    }

    private enum RedditProtectedSegmentKind: String, Hashable {
        case codeBlock
        case codeSpan
        case markdownImageLink
        case markdownLink
        case imageURL
    }

    private struct RedditProtectedSegment {
        let token: String
        let original: String
        let kind: RedditProtectedSegmentKind
    }

    private struct PreparedRedditMarkdown {
        let markdown: String
        let protectedSegments: [RedditProtectedSegment]
    }

    private func containsStructuredMarkdown(_ text: String) -> Bool {
        text.range(of: #"(?m)^\s{0,3}(?:[-*+]\s+|\d+\.\s+|>\s+|#{1,6}\s+)"#, options: .regularExpression) != nil
    }

    private func fixMissingSentenceSpacing(in text: String) -> String {
        text.replacingOccurrences(
            of: #"([.!?]["”'’\)]?)(?=[A-Z0-9])"#,
            with: "$1 ",
            options: .regularExpression
        )
    }

    private func shouldSynthesizeParagraphs(in text: String) -> Bool {
        if text.contains("\n\n") || containsStructuredMarkdown(text) {
            return false
        }

        let collapsed = text
            .replacingOccurrences(of: "(?<!\n)\n(?!\n)", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard collapsed.count >= 180 else { return false }

        let sentenceMarkers = collapsed.replacingOccurrences(
            of: #"([a-z0-9][.!?]["”'’\)]?)\s+(?=[A-Z0-9])"#,
            with: "$1|||",
            options: .regularExpression
        )
        let sentenceCount = sentenceMarkers
            .components(separatedBy: "|||")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .count

        return sentenceCount >= 3
    }

    private func synthesizeParagraphs(in text: String) -> String {
        let normalized = text
            .replacingOccurrences(of: "(?<!\n)\n(?!\n)", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let sentenceMarkers = normalized.replacingOccurrences(
            of: #"([a-z0-9][.!?]["”'’\)]?)\s+(?=[A-Z0-9])"#,
            with: "$1|||",
            options: .regularExpression
        )
        let sentences = sentenceMarkers
            .components(separatedBy: "|||")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard sentences.count >= 3 else {
            return normalized
        }

        var paragraphs: [String] = []
        var index = 0

        while index < sentences.count {
            let end = min(index + 2, sentences.count)
            paragraphs.append(sentences[index..<end].joined(separator: " "))
            index = end
        }

        return paragraphs.joined(separator: "\n\n")
    }

    private func autoLinkRawURLs(in text: String) -> String {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return text
        }

        let nsText = text as NSString
        let matches = detector.matches(in: text, options: [], range: NSRange(location: 0, length: nsText.length))
        var updated = text

        for match in matches.reversed() {
            guard let url = match.url,
                  let range = Range(match.range, in: updated) else { continue }

            let original = String(updated[range])
            if isLikelyImageURL(original) || original.hasPrefix("<<<REDDIT_") {
                continue
            }

            updated.replaceSubrange(range, with: "[\(original)](\(url.absoluteString))")
        }

        return updated
    }

    private func makePlainTextRedditFallback(from markdownContent: String) -> String {
        var cleaned = markdownContent
            .replacingOccurrences(of: #"!\[([^\]]*)\]\(([^)]+)\)"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"\[([^\]]+)\]\(([^)]+)\)"#, with: "$1", options: .regularExpression)

        cleaned = cleanMarkdownArtifactsForDisplay(cleaned)
        cleaned = cleaned.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func cleanMarkdownArtifactsForDisplay(_ input: String) -> String {
        var value = input
        value = value.replacingOccurrences(of: "\r\n", with: "\n")
        value = value.replacingOccurrences(of: "\r", with: "\n")
        value = value.replacingOccurrences(
            of: #"(?s)```[a-zA-Z0-9_-]*\s*(.*?)\s*```"#,
            with: "$1",
            options: .regularExpression
        )
        value = value.replacingOccurrences(of: "```", with: "")
        value = value.replacingOccurrences(of: "\\*\\*(.*?)\\*\\*", with: "$1", options: .regularExpression)
        value = value.replacingOccurrences(of: "\\*(.*?)\\*", with: "$1", options: .regularExpression)
        value = value.replacingOccurrences(of: "__(.*?)__", with: "$1", options: .regularExpression)
        value = value.replacingOccurrences(of: "_(.*?)_", with: "$1", options: .regularExpression)
        value = value.replacingOccurrences(of: "`([^`]*)`", with: "$1", options: .regularExpression)
        value = value.replacingOccurrences(of: #"(?m)^\s{0,3}#{1,6}\s*"#, with: "", options: .regularExpression)
        value = value.replacingOccurrences(of: #"(?m)(^\s*[-•]?\s*)#{1,6}\s*"#, with: "$1", options: .regularExpression)
        value = value.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    // MARK: - Post Summary TTS Functions
    
    private func speakPostSummary(_ text: String) {
        ttsCanceledSummary = false
        guard !text.isEmpty else {
            speechSynthesisErrorSummary = "No summary available to read."
            return
        }
        
        // Stop any currently playing sounds before starting a new one
        #if os(iOS)
        audioPlayerSummary?.stop()
        audioPlayerSummary = nil
        localSpeechSynthSummary?.stopSpeaking(at: .immediate)
        #elseif os(macOS)
        audioPlayerSummary?.stop()
        audioPlayerSummary = nil
        localSpeechSynthSummary?.stopSpeaking()
        #endif
        
        isSynthesizingSpeechSummary = true
        isSpeakingLocallySummary = false
        speechSynthesisErrorSummary = nil
        
        Task {
            await appState.summaryService.synthesizeSpeechFastStartSplit(
                text: text,
                onFirstChunk: { data in
                    DispatchQueue.main.async {
                        if !self.ttsCanceledSummary { self.playAudioSummary(data: data) }
                    }
                },
                onRemainingReady: { data in
                    DispatchQueue.main.async {
                        if self.ttsCanceledSummary { return }
                        #if os(iOS)
                        if let player = self.audioPlayerSummary, player.isPlaying {
                            self.nextAudioChunkSummary = data
                        } else {
                            self.playAudioSummary(data: data)
                        }
                        #elseif os(macOS)
                        if let player = self.audioPlayerSummary, player.isPlaying {
                            self.nextAudioChunkSummary = data
                        } else {
                            self.playAudioSummary(data: data)
                        }
                        #endif
                    }
                },
                onComplete: {
                    // handled by delegate chain
                },
                onError: { error in
                    DispatchQueue.main.async {
                        self.speechSynthesisErrorSummary = "Speech synthesis failed: \(error.localizedDescription)"
                        self.isSynthesizingSpeechSummary = false
                        self.nextAudioChunkSummary = nil
                    }
                }
            )
        }
    }
    
    private func stopPostSummarySpeech() {
        ttsCanceledSummary = true
        #if os(iOS)
        audioPlayerSummary?.stop()
        audioPlayerSummary = nil
        localSpeechSynthSummary?.stopSpeaking(at: .immediate)
        #elseif os(macOS)
        audioPlayerSummary?.stop()
        audioPlayerSummary = nil
        ShortcutsTTS.shared.stopSpeaking()
        localSpeechSynthSummary?.stopSpeaking()
        #endif
        nextAudioChunkSummary = nil
        isSynthesizingSpeechSummary = false
        isSpeakingLocallySummary = false
    }
    
    private func playAudioSummary(data: Data) {
        #if os(iOS)
        audioPlayerSummary?.stop()
        
        let audioData: Data
        if isMP3Data(data) || isAACData(data) {
            audioData = data
        } else {
            audioData = createWavData(from: data, sampleRate: 24000, channels: 1, bitsPerSample: 16)
        }
        
        do {
            audioPlayerSummary = try AVAudioPlayer(data: audioData)
            if let player = audioPlayerSummary {
                player.prepareToPlay()
                player.delegate = soundDelegateSummary
                soundDelegateSummary.onPlaybackFinished = { [self] in
                    DispatchQueue.main.async {
                        if let next = self.nextAudioChunkSummary {
                            self.nextAudioChunkSummary = nil
                            self.playAudioSummary(data: next)
                        } else {
                            self.isSynthesizingSpeechSummary = false
                        }
                    }
                }
                if !player.play() {
                    speechSynthesisErrorSummary = "Failed to start audio playback."
                    isSynthesizingSpeechSummary = false
                }
            }
        } catch {
            speechSynthesisErrorSummary = "Failed to initialize audio player: \(error.localizedDescription)"
            isSynthesizingSpeechSummary = false
        }
        #elseif os(macOS)
        audioPlayerSummary?.stop()
        
        let audioData: Data
        if isMP3Data(data) || isAACData(data) {
            audioData = data
        } else {
            audioData = createWavData(from: data, sampleRate: 24000, channels: 1, bitsPerSample: 16)
        }
        
        audioPlayerSummary = NSSound(data: audioData)
        if let player = audioPlayerSummary {
            player.delegate = soundDelegateSummary
            soundDelegateSummary.onPlaybackFinished = { [self] in
                DispatchQueue.main.async {
                    if let next = self.nextAudioChunkSummary {
                        self.nextAudioChunkSummary = nil
                        self.playAudioSummary(data: next)
                    } else {
                        self.isSynthesizingSpeechSummary = false
                    }
                }
            }
            if !player.play() {
                speechSynthesisErrorSummary = "Failed to start audio playback."
                isSynthesizingSpeechSummary = false
            }
        } else {
            speechSynthesisErrorSummary = "Failed to initialize audio player with data."
            isSynthesizingSpeechSummary = false
        }
        #endif
    }
    
    private func speakPostSummaryLocally(_ text: String) {
        #if os(iOS)
        // Check if Kokoro engine is selected
        let settingsSummary = PersistenceManager.shared.loadSettings()
        if settingsSummary.localTTSEngine == .kokoro {
            guard KokoroTTSService.shared.isAvailable else {
                isSpeakingLocallySummary = false
                speechSynthesisErrorSummary = "MLX TTS is not available. Add the MLXAudio package and model access."
                return
            }
            if isSpeakingLocallySummary {
                localTTSTaskSummary?.cancel()
                localTTSTaskSummary = nil
                audioPlayerSummary?.stop()
                localSpeechSynthSummary?.stopSpeaking(at: .immediate)
                isSpeakingLocallySummary = false
                return
            }
            guard !text.isEmpty else {
                speechSynthesisErrorSummary = "No summary available to read."
                return
            }
            audioPlayerSummary?.stop()
            isSpeakingLocallySummary = true
            isSynthesizingSpeechSummary = false
            startKokoroPlaybackRedditSummary(
                text: text,
                voice: settingsSummary.kokoroVoice,
                speed: settingsSummary.kokoroSpeed,
                setAudioPlayer: { player in audioPlayerSummary = player },
                soundDelegate: soundDelegateSummary,
                taskStore: &localTTSTaskSummary,
                onCompleted: {
                    isSpeakingLocallySummary = false
                    localTTSTaskSummary = nil
                },
                onError: { message in
                    speechSynthesisErrorSummary = message
                    isSpeakingLocallySummary = false
                }
            )
            return
        }

        // Check if running on Mac as iPad app - use Shortcuts instead
        if ProcessInfo.processInfo.isiOSAppOnMac {
            if isSpeakingLocallySummary {
                ShortcutsTTS.shared.stopSpeaking()
                isSpeakingLocallySummary = false
                return
            }

            guard !text.isEmpty else {
                speechSynthesisErrorSummary = "No summary available to read."
                return
            }

            audioPlayerSummary?.stop()

            isSpeakingLocallySummary = true
            isSynthesizingSpeechSummary = false
            
            let success = ShortcutsTTS.shared.speakText(text) {
                DispatchQueue.main.async {
                    self.isSpeakingLocallySummary = false
                }
            }
            
            if !success {
                isSpeakingLocallySummary = false
                speechSynthesisErrorSummary = "Failed to start Shortcuts TTS"
            }
            
            return
        }
        
        // Original iOS code for real devices
        if isSpeakingLocallySummary {
            localSpeechSynthSummary?.stopSpeaking(at: .immediate)
            isSpeakingLocallySummary = false
            return
        }
        
        guard !text.isEmpty else {
            speechSynthesisErrorSummary = "No summary available to read."
            return
        }
        
        audioPlayerSummary?.stop()
        
        if localSpeechSynthSummary == nil {
            localSpeechSynthSummary = AVSpeechSynthesizer()
            localSpeechSynthSummary?.delegate = soundDelegateSummary
        }
        
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = 0.52
        utterance.pitchMultiplier = 1.0
        utterance.volume = 1.0
        utterance.preUtteranceDelay = 0.0
        utterance.postUtteranceDelay = 0.0

        if let savedVoiceID = UserDefaults.standard.string(forKey: "LocalTTS.iOSOnMac.SelectedVoiceID"),
           !savedVoiceID.isEmpty,
           let savedVoice = AVSpeechSynthesisVoice(identifier: savedVoiceID) {
            if ProcessInfo.processInfo.isiOSAppOnMac && savedVoice.identifier.contains("com.apple.voice") {
                print("🔊 [Post Summary] Skipping com.apple.voice on Mac")
            } else {
                utterance.voice = savedVoice
            }
        }
        
        if utterance.voice == nil {
            let currentLang = AVSpeechSynthesisVoice.currentLanguageCode()
            let allVoices = AVSpeechSynthesisVoice.speechVoices()
            
            let availableVoices: [AVSpeechSynthesisVoice]
            if ProcessInfo.processInfo.isiOSAppOnMac {
                availableVoices = allVoices.filter { 
                    $0.language == currentLang && !$0.identifier.contains("com.apple.voice")
                }
            } else {
                availableVoices = allVoices.filter { $0.language == currentLang }
            }
            
            let premiumVoices = availableVoices.filter { $0.quality == .premium }
            let enhancedVoices = availableVoices.filter { $0.quality == .enhanced }
            
            if let premium = premiumVoices.first {
                utterance.voice = premium
            } else if let enhanced = enhancedVoices.first {
                utterance.voice = enhanced
            } else {
                utterance.voice = AVSpeechSynthesisVoice(language: currentLang)
            }
        }
        
        isSpeakingLocallySummary = true
        isSynthesizingSpeechSummary = false
        if let synth = localSpeechSynthSummary {
            DispatchQueue.main.async { synth.speak(utterance) }
        } else {
            isSpeakingLocallySummary = false
            speechSynthesisErrorSummary = "Failed to initialize speech synthesizer."
        }
        #elseif os(macOS)
        // Check if Kokoro engine is selected
        let settingsSummary = PersistenceManager.shared.loadSettings()
        if settingsSummary.localTTSEngine == .kokoro {
            guard KokoroTTSService.shared.isAvailable else {
                isSpeakingLocallySummary = false
                speechSynthesisErrorSummary = "MLX TTS is not available. Add the MLXAudio package and model access."
                return
            }
            if isSpeakingLocallySummary {
                localTTSTaskSummary?.cancel()
                localTTSTaskSummary = nil
                audioPlayerSummary?.stop()
                isSpeakingLocallySummary = false
                return
            }
            guard !text.isEmpty else {
                speechSynthesisErrorSummary = "No summary available to read."
                return
            }
            audioPlayerSummary?.stop()
            isSpeakingLocallySummary = true
            isSynthesizingSpeechSummary = false
            startKokoroPlaybackRedditQA(
                text: text,
                voice: settingsSummary.kokoroVoice,
                speed: settingsSummary.kokoroSpeed,
                setAudioPlayer: { player in audioPlayerSummary = player },
                soundDelegate: soundDelegateSummary,
                taskStore: &localTTSTaskSummary,
                onCompleted: {
                    isSpeakingLocallySummary = false
                    localTTSTaskSummary = nil
                },
                onError: { message in
                    speechSynthesisErrorSummary = message
                    isSpeakingLocallySummary = false
                }
            )
            return
        }

        if isSpeakingLocallySummary {
            ShortcutsTTS.shared.stopSpeaking()
            isSpeakingLocallySummary = false
            return
        }

        guard !text.isEmpty else {
            speechSynthesisErrorSummary = "No summary available to read."
            return
        }

        audioPlayerSummary?.stop()

        isSpeakingLocallySummary = true
        isSynthesizingSpeechSummary = false

        let success = ShortcutsTTS.shared.speakText(text) {
            DispatchQueue.main.async {
                self.isSpeakingLocallySummary = false
            }
        }

        if !success {
            isSpeakingLocallySummary = false
            speechSynthesisErrorSummary = "Failed to start Shortcuts TTS on macOS."
        }
        #endif
    }

    private func startKokoroPlaybackRedditQA(
        text: String,
        voice: String,
        speed: Double,
        setAudioPlayer: @escaping (KokoroAudioPlayer?) -> Void,
        soundDelegate: SoundDelegate,
        taskStore: inout Task<Void, Never>?,
        onCompleted: @escaping () -> Void,
        onError: @escaping (String) -> Void
    ) {
        _ = soundDelegate
        taskStore?.cancel()
        taskStore = Task {
            defer {
                if !PersistenceManager.shared.loadSettings().kokoroPrecacheEnabled {
                    KokoroTTSService.shared.unloadIfAllowed()
                }
                Task { @MainActor in onCompleted() }
            }
            do {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }

                func makeKokoroChunks(from input: String) -> [String] {
                    let firstSize = min(240, input.count)
                    let firstChunk = String(input.prefix(firstSize))
                    let remaining = String(input.dropFirst(firstSize)).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !remaining.isEmpty else { return [firstChunk] }
                    var chunks: [String] = [firstChunk]
                    let sentences = remaining.components(separatedBy: CharacterSet(charactersIn: ".!?"))
                    var current = ""
                    let maxChunkSize = 420
                    for sentence in sentences {
                        let trimmedSentence = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
                        if trimmedSentence.isEmpty { continue }
                        let sentenceWithPunctuation = trimmedSentence + "."
                        if current.count + sentenceWithPunctuation.count <= maxChunkSize {
                            current += (current.isEmpty ? "" : " ") + sentenceWithPunctuation
                        } else {
                            if !current.isEmpty { chunks.append(current) }
                            current = sentenceWithPunctuation
                        }
                    }
                    if !current.isEmpty { chunks.append(current) }
                    return chunks
                }

                let chunks = makeKokoroChunks(from: trimmed)
                guard let firstChunk = chunks.first else { return }

                func playChunk(_ data: Data) async throws -> TimeInterval {
                    try await MainActor.run {
                        #if os(iOS)
                        do {
                            let player = try AVAudioPlayer(data: data)
                            player.delegate = nil
                            player.prepareToPlay()
                            setAudioPlayer(player)
                            if player.play() == false {
                                onError("Failed to start audio playback.")
                                throw NSError(domain: "KokoroPlayback", code: -1)
                            }
                            return player.duration
                        } catch {
                            onError("Failed to initialize audio player: \(error.localizedDescription)")
                            throw error
                        }
                        #elseif os(macOS)
                        guard let player = NSSound(data: data) else {
                            onError("Failed to initialize audio player.")
                            throw NSError(domain: "KokoroPlayback", code: -1)
                        }
                        setAudioPlayer(player)
                        if player.play() == false {
                            onError("Failed to start audio playback.")
                            throw NSError(domain: "KokoroPlayback", code: -1)
                        }
                        return player.duration
                        #endif
                    }
                }

                enum KokoroPlaybackError: Error { case timeout }

                func synthesizeWithTimeout(_ text: String) async throws -> Data {
                    try await withThrowingTaskGroup(of: Data.self) { group in
                        group.addTask {
                            try await KokoroTTSService.shared.synthesize(text: text, voice: voice, speed: Float(speed))
                        }
                        group.addTask {
                            try await Task.sleep(nanoseconds: 20_000_000_000)
                            throw KokoroPlaybackError.timeout
                        }
                        let result = try await group.next()!
                        group.cancelAll()
                        return result
                    }
                }

                let firstData = try await synthesizeWithTimeout(firstChunk)
                if Task.isCancelled { return }
                var currentDuration = try await playChunk(firstData)
                if chunks.count == 1 { return }

                var nextIndex = 1
                var nextTask: Task<Data, Error>? = Task { try await synthesizeWithTimeout(chunks[nextIndex]) }
                defer { nextTask?.cancel() }

                while nextIndex < chunks.count {
                    try await Task.sleep(nanoseconds: UInt64(currentDuration * 1_000_000_000))
                    if Task.isCancelled { return }
                    guard let task = nextTask else { return }
                    let data = try await task.value
                    nextIndex += 1
                    if nextIndex < chunks.count {
                        nextTask = Task { try await synthesizeWithTimeout(chunks[nextIndex]) }
                    } else { nextTask = nil }
                    currentDuration = try await playChunk(data)
                }
            } catch {
                if Task.isCancelled { return }
                await MainActor.run {
                    let message: String
                    if let kokoroError = error as? KokoroTTSServiceError, kokoroError == .notAvailable {
                        message = "MLX TTS is not available. Add the MLXAudio package and model access."
                    } else if String(describing: error).contains("timeout") {
                        message = "Kokoro is still loading models. Please wait a moment and try again."
                    } else {
                        message = "Kokoro TTS failed: \(error.localizedDescription)"
                    }
                    onError(message)
                }
            }
        }
    }

    private func startKokoroPlaybackRedditSummary(
        text: String,
        voice: String,
        speed: Double,
        setAudioPlayer: @escaping (KokoroAudioPlayer?) -> Void,
        soundDelegate: SoundDelegate,
        taskStore: inout Task<Void, Never>?,
        onCompleted: @escaping () -> Void,
        onError: @escaping (String) -> Void
    ) {
        _ = soundDelegate
        taskStore?.cancel()
        taskStore = Task {
            defer {
                if !PersistenceManager.shared.loadSettings().kokoroPrecacheEnabled {
                    KokoroTTSService.shared.unloadIfAllowed()
                }
                Task { @MainActor in onCompleted() }
            }
            do {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }

                func makeKokoroChunks(from input: String) -> [String] {
                    let firstSize = min(240, input.count)
                    let firstChunk = String(input.prefix(firstSize))
                    let remaining = String(input.dropFirst(firstSize)).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !remaining.isEmpty else { return [firstChunk] }
                    var chunks: [String] = [firstChunk]
                    let sentences = remaining.components(separatedBy: CharacterSet(charactersIn: ".!?"))
                    var current = ""
                    let maxChunkSize = 420
                    for sentence in sentences {
                        let trimmedSentence = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
                        if trimmedSentence.isEmpty { continue }
                        let sentenceWithPunctuation = trimmedSentence + "."
                        if current.count + sentenceWithPunctuation.count <= maxChunkSize {
                            current += (current.isEmpty ? "" : " ") + sentenceWithPunctuation
                        } else {
                            if !current.isEmpty { chunks.append(current) }
                            current = sentenceWithPunctuation
                        }
                    }
                    if !current.isEmpty { chunks.append(current) }
                    return chunks
                }

                let chunks = makeKokoroChunks(from: trimmed)
                guard let firstChunk = chunks.first else { return }

                func playChunk(_ data: Data) async throws -> TimeInterval {
                    try await MainActor.run {
                        #if os(iOS)
                        do {
                            let player = try AVAudioPlayer(data: data)
                            player.delegate = nil
                            player.prepareToPlay()
                            setAudioPlayer(player)
                            if player.play() == false {
                                onError("Failed to start audio playback.")
                                throw NSError(domain: "KokoroPlayback", code: -1)
                            }
                            return player.duration
                        } catch {
                            onError("Failed to initialize audio player: \(error.localizedDescription)")
                            throw error
                        }
                        #elseif os(macOS)
                        guard let player = NSSound(data: data) else {
                            onError("Failed to initialize audio player.")
                            throw NSError(domain: "KokoroPlayback", code: -1)
                        }
                        setAudioPlayer(player)
                        if player.play() == false {
                            onError("Failed to start audio playback.")
                            throw NSError(domain: "KokoroPlayback", code: -1)
                        }
                        return player.duration
                        #endif
                    }
                }

                enum KokoroPlaybackError: Error { case timeout }

                func synthesizeWithTimeout(_ text: String) async throws -> Data {
                    try await withThrowingTaskGroup(of: Data.self) { group in
                        group.addTask {
                            try await KokoroTTSService.shared.synthesize(text: text, voice: voice, speed: Float(speed))
                        }
                        group.addTask {
                            try await Task.sleep(nanoseconds: 20_000_000_000)
                            throw KokoroPlaybackError.timeout
                        }
                        let result = try await group.next()!
                        group.cancelAll()
                        return result
                    }
                }

                let firstData = try await synthesizeWithTimeout(firstChunk)
                if Task.isCancelled { return }
                var currentDuration = try await playChunk(firstData)
                if chunks.count == 1 { return }

                var nextIndex = 1
                var nextTask: Task<Data, Error>? = Task { try await synthesizeWithTimeout(chunks[nextIndex]) }
                defer { nextTask?.cancel() }

                while nextIndex < chunks.count {
                    try await Task.sleep(nanoseconds: UInt64(currentDuration * 1_000_000_000))
                    if Task.isCancelled { return }
                    guard let task = nextTask else { return }
                    let data = try await task.value
                    nextIndex += 1
                    if nextIndex < chunks.count {
                        nextTask = Task { try await synthesizeWithTimeout(chunks[nextIndex]) }
                    } else { nextTask = nil }
                    currentDuration = try await playChunk(data)
                }
            } catch {
                if Task.isCancelled { return }
                await MainActor.run {
                    let message: String
                    if let kokoroError = error as? KokoroTTSServiceError, kokoroError == .notAvailable {
                        message = "MLX TTS is not available. Add the MLXAudio package and model access."
                    } else if String(describing: error).contains("timeout") {
                        message = "Kokoro is still loading models. Please wait a moment and try again."
                    } else {
                        message = "Kokoro TTS failed: \(error.localizedDescription)"
                    }
                    onError(message)
                }
            }
        }
    }
}


// MARK: - Integrated Comment Analytics View Components (Moved from CommentAnalyticsView.swift)

// Using standard SwiftUI colors for now, can be adjusted later if needed.
fileprivate struct AnalyticsColors { // Make fileprivate to avoid polluting global scope
    static var background: Color {
        #if os(iOS)
        return Color(UIColor.systemBackground)
        #else
        return Color(NSColor.windowBackgroundColor)
        #endif
    }
    static var systemGray5: Color {
        #if os(iOS)
        return Color(UIColor.systemGray5)
        #else
        return Color(NSColor.systemGray)
        #endif
    }
    static var systemGray6: Color {
        #if os(iOS)
        return Color(UIColor.systemGray6)
        #else
        return Color(NSColor.systemGray)
        #endif
    }
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
    var providerOverride: AppSettings.SummaryProvider? = nil
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) var dismiss
    
    @State private var analytics: CommentAnalytics?
    @State private var thematicAnalysis: String? = nil
    @State private var isThematicAnalysisLoading = false
    @State private var thematicAnalysisError: String? = nil
    @State private var isLoading = true
    @State private var analyzedCommentCount: Int = 0
    @State private var analysisCancellable: AnyCancellable? // To hold the Combine subscription

    // Use shared redditService from appState for consistent OAuth handling
    private var redditService: RedditService { appState.redditService }

    private var effectiveSummaryProvider: AppSettings.SummaryProvider {
        providerOverride ?? appState.settings.selectedSummaryProvider
    }

    var body: some View {
        VStack(spacing: 0) {
            // Custom navigation header
            HStack {
                Text("Comment Analysis")
                    .font(.title2)
                    .fontWeight(.bold)
                    .foregroundColor(.primary)
                
                Spacer()
                
                Button("Done") {
                    dismiss()
                }
                .buttonStyle(LiquidGlassButtonStyle())
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .modifier(AdaptiveGlassModifier(cornerRadius: 0))
            
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if isLoading {
                        VStack {
                                ProgressView()
                                    .padding()
                                Text("Analyzing comments...")
                                    .foregroundColor(.primary)
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
                                .foregroundColor(.primary)
                                .frame(maxWidth: .infinity)
                            .padding()
                    }
                }
                .padding(.vertical, 24)
                .padding(.horizontal, 20)
            }
        }
        .background(.ultraThinMaterial)
        .modifier(AdaptiveGlassModifier(cornerRadius: 40))
        .onAppear {
            Task {
                await generateAnalytics()
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
                .padding(20)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 30, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 30, style: .continuous)
                        .stroke(Color.white.opacity(0.2), lineWidth: 1)
                )
                
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
                .padding(20)
                .modifier(AdaptiveGlassModifier(cornerRadius: 20))
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
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
            .padding(20)
            .modifier(AdaptiveGlassModifier(cornerRadius: 20))
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
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
            .padding(20)
            .modifier(AdaptiveGlassModifier(cornerRadius: 20))
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .padding(.horizontal)
        }
    }
    
    @ViewBuilder
    private func thematicAnalysisSection() -> some View {
        let needsGeminiKey = effectiveSummaryProvider == .gemini && appState.settings.geminiApiKey.isEmpty
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
                let thematicStreamText = appState.mlxStreamingText
                if (effectiveSummaryProvider == .mlxLocal || effectiveSummaryProvider == .coreAIMLXLocal) && !thematicStreamText.isEmpty {
                    ScrollView {
                        Text(thematicStreamText)
                            .font(.body)
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                    }
                    .modifier(AdaptiveGlassModifier(cornerRadius: 16))
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .padding(.horizontal)
                } else {
                    VStack {
                        ProgressView()
                            .padding(.bottom, 5)
                        Text("Generating thematic analysis with AI...")
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(16)
                    .modifier(AdaptiveGlassModifier(cornerRadius: 16))
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .padding(.horizontal)
                }
            } else if let thematicAnalysisError = thematicAnalysisError {
                Text("Error generating thematic analysis: \(thematicAnalysisError)")
                    .foregroundColor(.red)
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .modifier(AdaptiveGlassModifier(cornerRadius: 24))
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .padding(.horizontal)
            } else if let thematicAnalysis = thematicAnalysis, !thematicAnalysis.isEmpty {
                GlassySummary(summary: thematicAnalysis)
                    .padding(.horizontal)
                // Throughput badge for on-device providers (deep analysis)
                let _deepAnalysisProvider = effectiveSummaryProvider
                if (_deepAnalysisProvider == .mlxLocal || _deepAnalysisProvider == .coreAIMLXLocal || _deepAnalysisProvider == .appleLocal || _deepAnalysisProvider == .applePCCGateway || _deepAnalysisProvider == .summarizeDaemon),
                   !appState.mlxLastThroughput.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "cpu").font(.caption2)
                        Text(appState.mlxLastThroughput).font(.caption2).monospacedDigit()
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
                }
            } else {
                Text(needsGeminiKey ? "Thematic analysis requires a Gemini API key in Settings." : "No thematic analysis available or comments were empty.")
                    .foregroundColor(.secondary)
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .modifier(AdaptiveGlassModifier(cornerRadius: 24))
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
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
                     .modifier(AdaptiveGlassModifier(cornerRadius: 16))
                     .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                     .padding(.horizontal)
             } else if analytics.totalComments == 0 {
                 Text("No comments to display examples for.")
                     .foregroundColor(.secondary)
                     .padding()
                     .frame(maxWidth: .infinity, alignment: .leading)
                     .modifier(AdaptiveGlassModifier(cornerRadius: 16))
                     .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
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
                        .cornerRadius(6)
                    
                    Rectangle()
                        .foregroundColor(color)
                        .frame(width: max(0, min(geo.size.width, CGFloat(percentage / 100.0) * geo.size.width)), height: 8)
                        .cornerRadius(6)
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
                    .modifier(AdaptiveGlassModifier(cornerRadius: 12))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
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
            
            // Check if we can proceed with thematic analysis based on selected provider
            let canProceed: Bool
            let errorMessage: String?
            
            switch self.effectiveSummaryProvider {
            case .appleLocal, .appleCloud, .applePCCGateway, .mlxLocal, .coreAIMLXLocal, .webAI, .summarizeDaemon:
                // These providers do not need API keys for this flow.
                canProceed = true
                errorMessage = nil
            case .gemini:
                canProceed = !self.appState.settings.geminiApiKey.isEmpty
                errorMessage = canProceed ? nil : "Gemini API key not set in Settings."
            }
            
            if canProceed && generatedAnalytics.totalComments > 0 {
                // Call the non-async version
                self.generateThematicAnalysis(commentsToAnalyze: self.redditService.flattenComments(self.comments))
            } else {
                self.isThematicAnalysisLoading = false
                if let error = errorMessage {
                    self.thematicAnalysisError = error
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
        Summarize the following Reddit discussion thread, highlighting key opinions, consensus views, and any significant disagreements. Focus on the main topics being discussed. Output plain text only (no markdown symbols like #, *, _, or `):

        \(formattedCommentsString)
        """
        
        // Check if we should use Apple Intelligence instead
        if effectiveSummaryProvider == .appleLocal {
            // Use on-device AI only — no Gemini fallback for deep analysis
            let t0 = Date()
            appState.performAppleLocalOnlyPublic(prompt: prompt, taskName: "Reddit Thematic Analysis") { analysisText in
                let elapsed = Date().timeIntervalSince(t0)
                Task { @MainActor in appState.recordAppleLocalThroughputPublic(text: analysisText, elapsed: elapsed) }
                DispatchQueue.main.async {
                    self.thematicAnalysis = self.appState.cleanMarkdownArtifactsForDisplay(analysisText)
                    self.thematicAnalysisError = nil
                    self.isThematicAnalysisLoading = false
                }
            }
            return
        } else if effectiveSummaryProvider == .appleCloud {
            // Use Apple Cloud via Private Cloud Compute
            print("CommentAnalyticsViewIntegrated: Sending \(analyzedCommentCount) comments for thematic analysis using Apple Cloud.")

            appState.launchCloudRequest(for: prompt, type: .commentSummary) { analysisText in
                DispatchQueue.main.async {
                    self.thematicAnalysis = self.appState.cleanMarkdownArtifactsForDisplay(analysisText)
                    self.thematicAnalysisError = nil
                    self.isThematicAnalysisLoading = false
                }
            }
            return
        } else if effectiveSummaryProvider == .applePCCGateway {
            print("☁️ CommentAnalyticsViewIntegrated: Sending \(analyzedCommentCount) comments for thematic analysis using Apple PCC fm CLI.")
            appState.performPCCGatewaySummaryPublic(prompt: prompt, taskName: "Reddit Thematic Analysis") { analysisText in
                DispatchQueue.main.async {
                    self.thematicAnalysis = self.appState.cleanMarkdownArtifactsForDisplay(analysisText)
                    self.thematicAnalysisError = nil
                    self.isThematicAnalysisLoading = false
                }
            }
            return
        } else if effectiveSummaryProvider == .mlxLocal || effectiveSummaryProvider == .coreAIMLXLocal {
            // Use MLX Local model for thematic analysis with higher token limit (2048)
            print("🧠 CommentAnalyticsViewIntegrated: Sending \(analyzedCommentCount) comments for thematic analysis using MLX Local.")

            appState.performMLXLocalAnalysisPublic(prompt: prompt) { analysisText in
                DispatchQueue.main.async {
                    self.thematicAnalysis = self.appState.cleanMarkdownArtifactsForDisplay(analysisText)
                    self.thematicAnalysisError = nil
                    self.isThematicAnalysisLoading = false
                }
            }
            return
        } else if effectiveSummaryProvider == .webAI {
            print("🌐 CommentAnalyticsViewIntegrated: Sending \(analyzedCommentCount) comments for thematic analysis using Web AI.")
            appState.performWebAIRequest(
                title: "Reddit Thematic Analysis",
                prompt: prompt,
                onSuccess: { analysisText in
                    DispatchQueue.main.async {
                        self.thematicAnalysis = self.appState.cleanMarkdownArtifactsForDisplay(analysisText)
                        self.thematicAnalysisError = nil
                        self.isThematicAnalysisLoading = false
                    }
                },
                onFailure: { message in
                    DispatchQueue.main.async {
                        self.thematicAnalysis = nil
                        self.thematicAnalysisError = message
                        self.isThematicAnalysisLoading = false
                    }
                }
            )
            return
        } else if effectiveSummaryProvider == .summarizeDaemon {
            print("⚙️ CommentAnalyticsViewIntegrated: Sending \(analyzedCommentCount) comments for thematic analysis using Codex / Summarize.")
            appState.performSummarizeSummaryPublic(prompt: prompt, taskName: "Reddit Thematic Analysis") { analysisText in
                DispatchQueue.main.async {
                    self.thematicAnalysis = self.appState.cleanMarkdownArtifactsForDisplay(analysisText)
                    self.thematicAnalysisError = nil
                    self.isThematicAnalysisLoading = false
                }
            }
            return
        }

        // Use SummaryService from AppState with Combine .sink
        print("CommentAnalyticsViewIntegrated: Sending \(analyzedCommentCount) comments for thematic analysis.")
        analysisCancellable = appState.summaryService.summarizeText("", customPrompt: prompt)
            .receive(on: DispatchQueue.main) // Ensure updates happen on the main thread
            .sink { summaryResult in
                // Check if the result indicates an error message returned by the service itself
                if summaryResult.starts(with: "Error:") || summaryResult == "API key not configured. Please add your Gemini API key in Settings." || summaryResult == "Invalid API URL" {
                    self.thematicAnalysisError = summaryResult
                    self.thematicAnalysis = nil
                } else if summaryResult == "No summary available" {
                    self.thematicAnalysisError = nil
                    self.thematicAnalysis = self.appState.cleanMarkdownArtifactsForDisplay(summaryResult)
                } else {
                    // Success case
                    self.thematicAnalysis = self.appState.cleanMarkdownArtifactsForDisplay(summaryResult)
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
                .background(AppColors.systemGray6, in: RoundedRectangle(cornerRadius: 16))
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
    var onAskAI: ((String) -> Void)? = nil
    var onAskAIWeb: ((String) -> Void)? = nil
    @EnvironmentObject var appState: AppState
    // TTS state variables
    @State private var isSynthesizingSpeech: Bool = false
    @State private var isSpeakingLocally: Bool = false
    @State private var speechSynthesisError: String? = nil
    @State private var ttsCanceled: Bool = false
#if os(iOS)
    @State private var audioPlayer: AVAudioPlayer?
    @State private var localSpeechSynth: AVSpeechSynthesizer?
    @StateObject private var soundDelegate = SoundDelegate()
    @State private var nextAudioChunk: Data? = nil
    @State private var localTTSTask: Task<Void, Never>? = nil
#elseif os(macOS)
    @State private var audioPlayer: NSSound?
    @State private var localSpeechSynth: NSSpeechSynthesizer?
    @StateObject private var soundDelegate = SoundDelegate()
    @State private var nextAudioChunk: Data? = nil
    @State private var localTTSTask: Task<Void, Never>? = nil
#endif
    
    var body: some View {
VStack(alignment: .leading, spacing: 14) {
            // Remove duplicate "Comment Summary" title since it's already shown in the main section
            HStack(spacing: 12) {
                Spacer()
                
                // Cloud TTS button
                Button {
                    speakSummary()
                } label: {
                    Image(systemName: "speaker.wave.2")
                        .font(.subheadline)
                }
                .buttonStyle(LiquidGlassButtonStyle())
                .ttsActiveGlow(isSynthesizingSpeech, color: .blue)
                .help("Read aloud (Cloud)")
                .disabled(isSynthesizingSpeech || isSpeakingLocally)
                
                // Stop speech
                Button {
                    stopRedditSummarySpeech()
                } label: {
                    Image(systemName: "stop.fill")
                        .font(.subheadline)
                }
                .buttonStyle(LiquidGlassButtonStyle())
                .help("Stop speech")
                
                // Local TTS button
                Button {
                    speakSummaryLocally()
                } label: {
                    Image(systemName: "speaker.wave.2.circle")
                        .font(.subheadline)
                }
                .buttonStyle(LiquidGlassButtonStyle())
                .ttsActiveGlow(isSpeakingLocally, color: .green)
                .help("Read aloud (Local)")
                .disabled(isSynthesizingSpeech)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            
            SelectableText(.init(summary.summary))
                .font(.body)
                .foregroundColor(.primary)
                .onAskAI(onAskAI)
                .onAskAIWeb(onAskAIWeb)
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
            }
            .buttonStyle(LiquidGlassButtonStyle())
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
                    if let next = self.nextAudioChunk {
                        self.nextAudioChunk = nil
                        self.playAudio(data: next)
                    } else {
                        self.isSynthesizingSpeech = false
                    }
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
                    if let next = self.nextAudioChunk {
                        self.nextAudioChunk = nil
                        self.playAudio(data: next)
                    } else {
                        self.isSynthesizingSpeech = false
                    }
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
        ttsCanceled = false
        ttsCanceled = false
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
            await appState.summaryService.synthesizeSpeechFastStartSplit(
                text: summary.summary,
                onFirstChunk: { data in
                    DispatchQueue.main.async {
                        if !self.ttsCanceled { self.playAudio(data: data) }
                    }
                },
                onRemainingReady: { data in
                    DispatchQueue.main.async {
                        if self.ttsCanceled { return }
                        if let player = self.audioPlayer, player.isPlaying {
                            self.nextAudioChunk = data
                        } else {
                            self.playAudio(data: data)
                        }
                    }
                },
                onComplete: {},
                onError: { error in
                    DispatchQueue.main.async {
                        self.speechSynthesisError = "Speech synthesis failed: \(error.localizedDescription)"
                        self.isSynthesizingSpeech = false
                        self.nextAudioChunk = nil
                    }
                }
            )
        }
    }
    
    private func stopRedditCommentSummarySpeech() {
        ttsCanceled = true
        #if os(iOS)
        audioPlayer?.stop()
        audioPlayer = nil
        localSpeechSynth?.stopSpeaking(at: .immediate)
        #elseif os(macOS)
        audioPlayer?.stop()
        audioPlayer = nil
        ShortcutsTTS.shared.stopSpeaking()
        localSpeechSynth?.stopSpeaking()
        #endif
        nextAudioChunk = nil
        isSynthesizingSpeech = false
        isSpeakingLocally = false
    }

    private func playAudio(data: Data) {
        #if os(iOS)
        // Stop any existing playback
        audioPlayer?.stop()
        
        // Detect format and handle accordingly
        let audioData: Data
        if isMP3Data(data) || isAACData(data) {
            // OpenAI returns MP3 or AAC directly - both are supported by AVAudioPlayer
            audioData = data
        } else {
            // Gemini returns PCM that needs WAV conversion
            audioData = createWavData(from: data, sampleRate: 24000, channels: 1, bitsPerSample: 16)
        }
        
        do {
            audioPlayer = try AVAudioPlayer(data: audioData)
            if let player = audioPlayer {
                player.prepareToPlay()
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
        if isMP3Data(data) || isAACData(data) {
            // OpenAI returns MP3 or AAC directly - both are supported by AVAudioPlayer
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
    
    private func stopRedditSummarySpeech() {
        ttsCanceled = true
        #if os(iOS)
        audioPlayer?.stop()
        audioPlayer = nil
        localSpeechSynth?.stopSpeaking(at: .immediate)
        #elseif os(macOS)
        audioPlayer?.stop()
        audioPlayer = nil
        ShortcutsTTS.shared.stopSpeaking()
        localSpeechSynth?.stopSpeaking()
        #endif
        nextAudioChunk = nil
        isSynthesizingSpeech = false
        isSpeakingLocally = false
    }

    private func speakSummaryLocally() {
        #if os(iOS)
        // Check if Kokoro engine is selected
        let settingsLocal = PersistenceManager.shared.loadSettings()
        if settingsLocal.localTTSEngine == .kokoro {
            guard KokoroTTSService.shared.isAvailable else {
                isSpeakingLocally = false
                speechSynthesisError = "MLX TTS is not available. Add the MLXAudio package and model access."
                return
            }
            if isSpeakingLocally {
                localTTSTask?.cancel()
                localTTSTask = nil
                audioPlayer?.stop()
                localSpeechSynth?.stopSpeaking(at: .immediate)
                isSpeakingLocally = false
                return
            }
            guard !summary.summary.isEmpty else {
                speechSynthesisError = "No summary available to read."
                return
            }
            audioPlayer?.stop()
            isSpeakingLocally = true
            isSynthesizingSpeech = false
            startKokoroPlaybackGlassy(
                text: summary.summary,
                voice: settingsLocal.kokoroVoice,
                speed: settingsLocal.kokoroSpeed,
                setAudioPlayer: { player in audioPlayer = player },
                soundDelegate: soundDelegate,
                taskStore: &localTTSTask,
                onCompleted: {
                    isSpeakingLocally = false
                    localTTSTask = nil
                },
                onError: { message in
                    speechSynthesisError = message
                    isSpeakingLocally = false
                }
            )
            return
        }

        // Check if running on Mac as iPad app - use Shortcuts instead
        if ProcessInfo.processInfo.isiOSAppOnMac {
            // Toggle off if already speaking (can't really stop shortcuts)
            if isSpeakingLocally {
                ShortcutsTTS.shared.stopSpeaking()
                isSpeakingLocally = false
                return
            }

            guard !summary.summary.isEmpty else {
                speechSynthesisError = "No summary available to read."
                return
            }

            // Stop any other audio playing
            audioPlayer?.stop()
            
            // Start speaking via Shortcuts
            isSpeakingLocally = true
            isSynthesizingSpeech = false
            
            let success = ShortcutsTTS.shared.speakText(summary.summary) {
                // Completion handler - called when speech ends (estimated)
                DispatchQueue.main.async {
                    self.isSpeakingLocally = false
                }
            }
            
            if !success {
                isSpeakingLocally = false
                speechSynthesisError = "Failed to start Shortcuts TTS"
            }
            
            return
        }
        
        // Original iOS code for real devices
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
        utterance.rate = 0.52  // Slightly slower for clarity
        utterance.pitchMultiplier = 1.0
        utterance.volume = 1.0
        utterance.preUtteranceDelay = 0.0
        utterance.postUtteranceDelay = 0.0

        // Use saved voice from settings (same as articles)
        if let savedVoiceID = UserDefaults.standard.string(forKey: "LocalTTS.iOSOnMac.SelectedVoiceID"),
           !savedVoiceID.isEmpty,
           let savedVoice = AVSpeechSynthesisVoice(identifier: savedVoiceID) {
            // Only skip com.apple.voice on Mac (they don't work there)
            if ProcessInfo.processInfo.isiOSAppOnMac && savedVoice.identifier.contains("com.apple.voice") {
                print("🔊 [Reddit Summary] Skipping com.apple.voice on Mac")
            } else {
                utterance.voice = savedVoice
                let qualityStr = savedVoice.quality == .premium ? "PREMIUM" : 
                                savedVoice.quality == .enhanced ? "Enhanced" : "Default"
                print("🔊 [Reddit Summary] Using saved voice: \(savedVoice.name) [\(qualityStr)]")
            }
        }
        
        // If no saved voice, find the best available
        if utterance.voice == nil {
            let currentLang = AVSpeechSynthesisVoice.currentLanguageCode()
            let allVoices = AVSpeechSynthesisVoice.speechVoices()
            
            // Filter for current language (and exclude com.apple.voice on Mac)
            let availableVoices: [AVSpeechSynthesisVoice]
            if ProcessInfo.processInfo.isiOSAppOnMac {
                availableVoices = allVoices.filter { 
                    $0.language == currentLang && !$0.identifier.contains("com.apple.voice")
                }
            } else {
                availableVoices = allVoices.filter { $0.language == currentLang }
            }
            
            // Simple priority: Premium > Enhanced > Default
            let premiumVoices = availableVoices.filter { $0.quality == .premium }
            let enhancedVoices = availableVoices.filter { $0.quality == .enhanced }
            
            if let premium = premiumVoices.first {
                utterance.voice = premium
                print("🔊 [Reddit Summary] Using PREMIUM voice: \(premium.name)")
            } else if let enhanced = enhancedVoices.first {
                utterance.voice = enhanced
                print("🔊 [Reddit Summary] Using Enhanced voice: \(enhanced.name)")
            } else {
                utterance.voice = AVSpeechSynthesisVoice(language: currentLang)
                if let v = utterance.voice {
                    print("🔊 [Reddit Summary] Using default voice: \(v.name)")
                }
            }
        }
        
        isSpeakingLocally = true
        isSynthesizingSpeech = false
        if let synth = localSpeechSynth {
            DispatchQueue.main.async { synth.speak(utterance) }
        } else {
            isSpeakingLocally = false
            speechSynthesisError = "Failed to initialize speech synthesizer."
        }
        #elseif os(macOS)
        // Check if Kokoro engine is selected
        let settingsLocal = PersistenceManager.shared.loadSettings()
        if settingsLocal.localTTSEngine == .kokoro {
            guard KokoroTTSService.shared.isAvailable else {
                isSpeakingLocally = false
                speechSynthesisError = "MLX TTS is not available. Add the MLXAudio package and model access."
                return
            }
            if isSpeakingLocally {
                localTTSTask?.cancel()
                localTTSTask = nil
                audioPlayer?.stop()
                isSpeakingLocally = false
                return
            }
            guard !summary.summary.isEmpty else {
                speechSynthesisError = "No summary available to read."
                return
            }
            audioPlayer?.stop()
            isSpeakingLocally = true
            isSynthesizingSpeech = false
            startKokoroPlaybackGlassy(
                text: summary.summary,
                voice: settingsLocal.kokoroVoice,
                speed: settingsLocal.kokoroSpeed,
                setAudioPlayer: { player in audioPlayer = player },
                soundDelegate: soundDelegate,
                taskStore: &localTTSTask,
                onCompleted: {
                    isSpeakingLocally = false
                    localTTSTask = nil
                },
                onError: { message in
                    speechSynthesisError = message
                    isSpeakingLocally = false
                }
            )
            return
        }

        // Toggle off if already speaking (CLI shortcut cannot truly stop mid-stream)
        if isSpeakingLocally {
            ShortcutsTTS.shared.stopSpeaking()
            isSpeakingLocally = false
            return
        }

        guard !summary.summary.isEmpty else {
            speechSynthesisError = "No summary available to read."
            return
        }

        // Stop all other audio
        audioPlayer?.stop()

        isSpeakingLocally = true
        isSynthesizingSpeech = false

        let success = ShortcutsTTS.shared.speakText(summary.summary) {
            DispatchQueue.main.async {
                self.isSpeakingLocally = false
            }
        }

        if !success {
            isSpeakingLocally = false
            speechSynthesisError = "Failed to start Shortcuts TTS on macOS."
        }
        #endif
    }

    private func startKokoroPlaybackGlassy(
        text: String,
        voice: String,
        speed: Double,
        setAudioPlayer: @escaping (KokoroAudioPlayer?) -> Void,
        soundDelegate: SoundDelegate,
        taskStore: inout Task<Void, Never>?,
        onCompleted: @escaping () -> Void,
        onError: @escaping (String) -> Void
    ) {
        _ = soundDelegate
        taskStore?.cancel()
        taskStore = Task {
            defer {
                if !PersistenceManager.shared.loadSettings().kokoroPrecacheEnabled {
                    KokoroTTSService.shared.unloadIfAllowed()
                }
                Task { @MainActor in
                    onCompleted()
                }
            }
            do {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }

                func makeKokoroChunks(from input: String) -> [String] {
                    let firstSize = min(240, input.count)
                    let firstChunk = String(input.prefix(firstSize))
                    let remaining = String(input.dropFirst(firstSize)).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !remaining.isEmpty else { return [firstChunk] }

                    var chunks: [String] = [firstChunk]
                    let sentences = remaining.components(separatedBy: CharacterSet(charactersIn: ".!?"))
                    var current = ""
                    let maxChunkSize = 420
                    for sentence in sentences {
                        let trimmedSentence = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
                        if trimmedSentence.isEmpty { continue }
                        let sentenceWithPunctuation = trimmedSentence + "."
                        if current.count + sentenceWithPunctuation.count <= maxChunkSize {
                            current += (current.isEmpty ? "" : " ") + sentenceWithPunctuation
                        } else {
                            if !current.isEmpty { chunks.append(current) }
                            current = sentenceWithPunctuation
                        }
                    }
                    if !current.isEmpty { chunks.append(current) }
                    return chunks
                }

                let chunks = makeKokoroChunks(from: trimmed)
                guard let firstChunk = chunks.first else { return }

                func playChunk(_ data: Data) async throws -> TimeInterval {
                    try await MainActor.run {
                        #if os(iOS)
                        do {
                            let player = try AVAudioPlayer(data: data)
                            player.delegate = nil
                            player.prepareToPlay()
                            setAudioPlayer(player)
                            if player.play() == false {
                                onError("Failed to start audio playback.")
                                throw NSError(domain: "KokoroPlayback", code: -1)
                            }
                            return player.duration
                        } catch {
                            onError("Failed to initialize audio player: \(error.localizedDescription)")
                            throw error
                        }
                        #elseif os(macOS)
                        guard let player = NSSound(data: data) else {
                            onError("Failed to initialize audio player.")
                            throw NSError(domain: "KokoroPlayback", code: -1)
                        }
                        setAudioPlayer(player)
                        if player.play() == false {
                            onError("Failed to start audio playback.")
                            throw NSError(domain: "KokoroPlayback", code: -1)
                        }
                        return player.duration
                        #endif
                    }
                }

                enum KokoroPlaybackError: Error { case timeout }

                func synthesizeWithTimeout(_ text: String) async throws -> Data {
                    try await withThrowingTaskGroup(of: Data.self) { group in
                        group.addTask {
                            try await KokoroTTSService.shared.synthesize(
                                text: text,
                                voice: voice,
                                speed: Float(speed)
                            )
                        }
                        group.addTask {
                            try await Task.sleep(nanoseconds: 20_000_000_000)
                            throw KokoroPlaybackError.timeout
                        }
                        let result = try await group.next()!
                        group.cancelAll()
                        return result
                    }
                }

                let firstData = try await synthesizeWithTimeout(firstChunk)
                if Task.isCancelled { return }
                var currentDuration = try await playChunk(firstData)

                if chunks.count == 1 { return }

                var nextIndex = 1
                var nextTask: Task<Data, Error>? = Task {
                    try await synthesizeWithTimeout(chunks[nextIndex])
                }
                defer { nextTask?.cancel() }

                while nextIndex < chunks.count {
                    try await Task.sleep(nanoseconds: UInt64(currentDuration * 1_000_000_000))
                    if Task.isCancelled { return }

                    guard let task = nextTask else { return }
                    let data = try await task.value
                    nextIndex += 1

                    if nextIndex < chunks.count {
                        nextTask = Task {
                            try await synthesizeWithTimeout(chunks[nextIndex])
                        }
                    } else {
                        nextTask = nil
                    }

                    currentDuration = try await playChunk(data)
                }
            } catch {
                if Task.isCancelled { return }
                await MainActor.run {
                    let message: String
                    if let kokoroError = error as? KokoroTTSServiceError, kokoroError == .notAvailable {
                        message = "MLX TTS is not available. Add the MLXAudio package and model access."
                    } else if String(describing: error).contains("timeout") {
                        message = "Kokoro is still loading models. Please wait a moment and try again."
                    } else {
                        message = "Kokoro TTS failed: \(error.localizedDescription)"
                    }
                    onError(message)
                }
            }
        }
    }
}

// Add this new component below GlassyCommentSummary
struct GlassySummary: View {
    let summary: String
    var onAskAI: ((String) -> Void)? = nil
    var onAskAIWeb: ((String) -> Void)? = nil
    @EnvironmentObject var appState: AppState

    // TTS state variables
    @State private var isSynthesizingSpeech: Bool = false
    @State private var isSpeakingLocally: Bool = false
    @State private var speechSynthesisError: String? = nil
    @State private var ttsCanceled: Bool = false
#if os(iOS)
    @State private var audioPlayer: AVAudioPlayer?
    @State private var localSpeechSynth: AVSpeechSynthesizer?
    @StateObject private var soundDelegate = SoundDelegate()
    @State private var nextAudioChunk: Data? = nil
    @State private var localTTSTask: Task<Void, Never>? = nil
#elseif os(macOS)
    @State private var audioPlayer: NSSound?
    @State private var localSpeechSynth: NSSpeechSynthesizer?
    @StateObject private var soundDelegate = SoundDelegate()
    @State private var nextAudioChunk: Data? = nil
    @State private var localTTSTask: Task<Void, Never>? = nil
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
                        .font(.subheadline)
                }
                .buttonStyle(LiquidGlassButtonStyle())
                .ttsActiveGlow(isSynthesizingSpeech, color: .blue)
                .help("Read aloud (Cloud)")
                .disabled(isSynthesizingSpeech || isSpeakingLocally)
                
                // Stop speech
                Button {
                    stopRedditSummarySpeech()
                } label: {
                    Image(systemName: "stop.fill")
                        .font(.subheadline)
                }
                .buttonStyle(LiquidGlassButtonStyle())
                .help("Stop speech")
                
                // Local TTS button
                Button {
                    speakSummaryLocally()
                } label: {
                    Image(systemName: "speaker.wave.2.circle")
                        .font(.subheadline)
                }
                .buttonStyle(LiquidGlassButtonStyle())
                .ttsActiveGlow(isSpeakingLocally, color: .green)
                .help("Read aloud (Local)")
                .disabled(isSynthesizingSpeech)
                
                // Copy button
                Button {
                    copyToClipboard(summary)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.subheadline)
                }
                .buttonStyle(LiquidGlassButtonStyle())
                .help("Copy summary")
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            
            SelectableText(.init(summary))
                .font(.body)
                .foregroundColor(.primary)
                .onAskAI(onAskAI)
                .onAskAIWeb(onAskAIWeb)
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
                    if let next = self.nextAudioChunk {
                        self.nextAudioChunk = nil
                        self.playAudio(data: next)
                    } else {
                        self.isSynthesizingSpeech = false
                    }
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
                    if let next = self.nextAudioChunk {
                        self.nextAudioChunk = nil
                        self.playAudio(data: next)
                    } else {
                        self.isSynthesizingSpeech = false
                    }
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
        ttsCanceled = false
        ttsCanceled = false
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
            await appState.summaryService.synthesizeSpeechFastStartSplit(
                text: summary,
                onFirstChunk: { data in
                    DispatchQueue.main.async {
                        if !self.ttsCanceled { self.playAudio(data: data) }
                    }
                },
                onRemainingReady: { data in
                    DispatchQueue.main.async {
                        if self.ttsCanceled { return }
                        if let player = self.audioPlayer, player.isPlaying {
                            self.nextAudioChunk = data
                        } else {
                            self.playAudio(data: data)
                        }
                    }
                },
                onComplete: {
                    // handled by delegate chain
                },
                onError: { error in
                    DispatchQueue.main.async {
                        self.speechSynthesisError = "Speech synthesis failed: \(error.localizedDescription)"
                        self.isSynthesizingSpeech = false
                        self.nextAudioChunk = nil
                    }
                }
            )
        }
    }
    
    private func stopRedditCommentSummarySpeech() {
        ttsCanceled = true
        #if os(iOS)
        audioPlayer?.stop()
        audioPlayer = nil
        localSpeechSynth?.stopSpeaking(at: .immediate)
        #elseif os(macOS)
        audioPlayer?.stop()
        audioPlayer = nil
        ShortcutsTTS.shared.stopSpeaking()
        localSpeechSynth?.stopSpeaking()
        #endif
        nextAudioChunk = nil
        isSynthesizingSpeech = false
        isSpeakingLocally = false
    }

    private func playAudio(data: Data) {
        #if os(iOS)
        // Stop any existing playback
        audioPlayer?.stop()
        
        // Detect format and handle accordingly
        let audioData: Data
        if isMP3Data(data) || isAACData(data) {
            // OpenAI returns MP3 or AAC directly - both are supported by AVAudioPlayer
            audioData = data
        } else {
            // Gemini returns PCM that needs WAV conversion
            audioData = createWavData(from: data, sampleRate: 24000, channels: 1, bitsPerSample: 16)
        }
        
        do {
            audioPlayer = try AVAudioPlayer(data: audioData)
            if let player = audioPlayer {
                player.prepareToPlay()
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
        if isMP3Data(data) || isAACData(data) {
            // OpenAI returns MP3 or AAC directly - both are supported by AVAudioPlayer
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
    
    private func stopRedditSummarySpeech() {
        ttsCanceled = true
        #if os(iOS)
        audioPlayer?.stop()
        audioPlayer = nil
        localSpeechSynth?.stopSpeaking(at: .immediate)
        #elseif os(macOS)
        audioPlayer?.stop()
        audioPlayer = nil
        ShortcutsTTS.shared.stopSpeaking()
        localSpeechSynth?.stopSpeaking()
        #endif
        nextAudioChunk = nil
        isSynthesizingSpeech = false
        isSpeakingLocally = false
    }

    private func speakSummaryLocally() {
        #if os(iOS)
        // Check if Kokoro engine is selected
        let settingsLocal = PersistenceManager.shared.loadSettings()
        if settingsLocal.localTTSEngine == .kokoro {
            guard KokoroTTSService.shared.isAvailable else {
                isSpeakingLocally = false
                speechSynthesisError = "MLX TTS is not available. Add the MLXAudio package and model access."
                return
            }
            if isSpeakingLocally {
                localTTSTask?.cancel()
                localTTSTask = nil
                audioPlayer?.stop()
                localSpeechSynth?.stopSpeaking(at: .immediate)
                isSpeakingLocally = false
                return
            }
            guard !summary.isEmpty else {
                speechSynthesisError = "No summary available to read."
                return
            }
            audioPlayer?.stop()
            isSpeakingLocally = true
            isSynthesizingSpeech = false
            startKokoroPlaybackGlassy(
                text: summary,
                voice: settingsLocal.kokoroVoice,
                speed: settingsLocal.kokoroSpeed,
                setAudioPlayer: { player in audioPlayer = player },
                soundDelegate: soundDelegate,
                taskStore: &localTTSTask,
                onCompleted: {
                    isSpeakingLocally = false
                    localTTSTask = nil
                },
                onError: { message in
                    speechSynthesisError = message
                    isSpeakingLocally = false
                }
            )
            return
        }

        // Check if running on Mac as iPad app - use Shortcuts instead
        if ProcessInfo.processInfo.isiOSAppOnMac {
            // Toggle off if already speaking (can't really stop shortcuts)
            if isSpeakingLocally {
                ShortcutsTTS.shared.stopSpeaking()
                isSpeakingLocally = false
                return
            }

            guard !summary.isEmpty else {
                speechSynthesisError = "No summary available to read."
                return
            }

            // Stop any other audio playing
            audioPlayer?.stop()
            
            // Start speaking via Shortcuts
            isSpeakingLocally = true
            isSynthesizingSpeech = false
            
            let success = ShortcutsTTS.shared.speakText(summary) {
                // Completion handler - called when speech ends (estimated)
                DispatchQueue.main.async {
                    self.isSpeakingLocally = false
                }
            }
            
            if !success {
                isSpeakingLocally = false
                speechSynthesisError = "Failed to start Shortcuts TTS"
            }
            
            return
        }
        
        // Original iOS code for real devices
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
        utterance.rate = 0.52  // Slightly slower for clarity
        utterance.pitchMultiplier = 1.0
        utterance.volume = 1.0
        utterance.preUtteranceDelay = 0.0
        utterance.postUtteranceDelay = 0.0

        // Use saved voice from settings (same as articles)
        if let savedVoiceID = UserDefaults.standard.string(forKey: "LocalTTS.iOSOnMac.SelectedVoiceID"),
           !savedVoiceID.isEmpty,
           let savedVoice = AVSpeechSynthesisVoice(identifier: savedVoiceID) {
            // Only skip com.apple.voice on Mac (they don't work there)
            if ProcessInfo.processInfo.isiOSAppOnMac && savedVoice.identifier.contains("com.apple.voice") {
                print("🔊 [Comment Summary] Skipping com.apple.voice on Mac")
            } else {
                utterance.voice = savedVoice
                let qualityStr = savedVoice.quality == .premium ? "PREMIUM" : 
                                savedVoice.quality == .enhanced ? "Enhanced" : "Default"
                print("🔊 [Comment Summary] Using saved voice: \(savedVoice.name) [\(qualityStr)]")
            }
        }
        
        // If no saved voice, find the best available
        if utterance.voice == nil {
            let currentLang = AVSpeechSynthesisVoice.currentLanguageCode()
            let allVoices = AVSpeechSynthesisVoice.speechVoices()
            
            // Filter for current language (and exclude com.apple.voice on Mac)
            let availableVoices: [AVSpeechSynthesisVoice]
            if ProcessInfo.processInfo.isiOSAppOnMac {
                availableVoices = allVoices.filter { 
                    $0.language == currentLang && !$0.identifier.contains("com.apple.voice")
                }
            } else {
                availableVoices = allVoices.filter { $0.language == currentLang }
            }
            
            // Simple priority: Premium > Enhanced > Default
            let premiumVoices = availableVoices.filter { $0.quality == .premium }
            let enhancedVoices = availableVoices.filter { $0.quality == .enhanced }
            
            if let premium = premiumVoices.first {
                utterance.voice = premium
                print("🔊 [Comment Summary] Using PREMIUM voice: \(premium.name)")
            } else if let enhanced = enhancedVoices.first {
                utterance.voice = enhanced
                print("🔊 [Comment Summary] Using Enhanced voice: \(enhanced.name)")
            } else {
                utterance.voice = AVSpeechSynthesisVoice(language: currentLang)
                if let v = utterance.voice {
                    print("🔊 [Comment Summary] Using default voice: \(v.name)")
                }
            }
        }
        if let v = utterance.voice {
            print("🔊 [LocalTTS] Selected: \(v.name) (\(v.identifier)) quality=\(v.quality.rawValue)")
        }
        
        isSpeakingLocally = true
        isSynthesizingSpeech = false
        if let synth = localSpeechSynth {
            DispatchQueue.main.async { synth.speak(utterance) }
        } else {
            isSpeakingLocally = false
            speechSynthesisError = "Failed to initialize speech synthesizer."
        }
        #elseif os(macOS)
        // Check if Kokoro engine is selected
        let settingsLocal = PersistenceManager.shared.loadSettings()
        if settingsLocal.localTTSEngine == .kokoro {
            guard KokoroTTSService.shared.isAvailable else {
                isSpeakingLocally = false
                speechSynthesisError = "MLX TTS is not available. Add the MLXAudio package and model access."
                return
            }
            if isSpeakingLocally {
                localTTSTask?.cancel()
                localTTSTask = nil
                audioPlayer?.stop()
                isSpeakingLocally = false
                return
            }
            guard !summary.isEmpty else {
                speechSynthesisError = "No summary available to read."
                return
            }
            audioPlayer?.stop()
            isSpeakingLocally = true
            isSynthesizingSpeech = false
            startKokoroPlaybackGlassy(
                text: summary,
                voice: settingsLocal.kokoroVoice,
                speed: settingsLocal.kokoroSpeed,
                setAudioPlayer: { player in audioPlayer = player },
                soundDelegate: soundDelegate,
                taskStore: &localTTSTask,
                onCompleted: {
                    isSpeakingLocally = false
                    localTTSTask = nil
                },
                onError: { message in
                    speechSynthesisError = message
                    isSpeakingLocally = false
                }
            )
            return
        }

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

        isSpeakingLocally = true
        isSynthesizingSpeech = false

        let success = ShortcutsTTS.shared.speakText(summary) {
            DispatchQueue.main.async {
                self.isSpeakingLocally = false
            }
        }

        if !success {
            isSpeakingLocally = false
            speechSynthesisError = "Failed to start Shortcuts TTS on macOS."
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

    private func startKokoroPlaybackGlassy(
        text: String,
        voice: String,
        speed: Double,
        setAudioPlayer: @escaping (KokoroAudioPlayer?) -> Void,
        soundDelegate: SoundDelegate,
        taskStore: inout Task<Void, Never>?,
        onCompleted: @escaping () -> Void,
        onError: @escaping (String) -> Void
    ) {
        _ = soundDelegate
        taskStore?.cancel()
        taskStore = Task {
            defer {
                if !PersistenceManager.shared.loadSettings().kokoroPrecacheEnabled {
                    KokoroTTSService.shared.unloadIfAllowed()
                }
                Task { @MainActor in
                    onCompleted()
                }
            }
            do {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }

                func makeKokoroChunks(from input: String) -> [String] {
                    let firstSize = min(240, input.count)
                    let firstChunk = String(input.prefix(firstSize))
                    let remaining = String(input.dropFirst(firstSize)).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !remaining.isEmpty else { return [firstChunk] }

                    var chunks: [String] = [firstChunk]
                    let sentences = remaining.components(separatedBy: CharacterSet(charactersIn: ".!?"))
                    var current = ""
                    let maxChunkSize = 420
                    for sentence in sentences {
                        let trimmedSentence = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
                        if trimmedSentence.isEmpty { continue }
                        let sentenceWithPunctuation = trimmedSentence + "."
                        if current.count + sentenceWithPunctuation.count <= maxChunkSize {
                            current += (current.isEmpty ? "" : " ") + sentenceWithPunctuation
                        } else {
                            if !current.isEmpty { chunks.append(current) }
                            current = sentenceWithPunctuation
                        }
                    }
                    if !current.isEmpty { chunks.append(current) }
                    return chunks
                }

                let chunks = makeKokoroChunks(from: trimmed)
                guard let firstChunk = chunks.first else { return }

                func playChunk(_ data: Data) async throws -> TimeInterval {
                    try await MainActor.run {
                        #if os(iOS)
                        do {
                            let player = try AVAudioPlayer(data: data)
                            player.delegate = nil
                            player.prepareToPlay()
                            setAudioPlayer(player)
                            if player.play() == false {
                                onError("Failed to start audio playback.")
                                throw NSError(domain: "KokoroPlayback", code: -1)
                            }
                            return player.duration
                        } catch {
                            onError("Failed to initialize audio player: \(error.localizedDescription)")
                            throw error
                        }
                        #elseif os(macOS)
                        guard let player = NSSound(data: data) else {
                            onError("Failed to initialize audio player.")
                            throw NSError(domain: "KokoroPlayback", code: -1)
                        }
                        setAudioPlayer(player)
                        if player.play() == false {
                            onError("Failed to start audio playback.")
                            throw NSError(domain: "KokoroPlayback", code: -1)
                        }
                        return player.duration
                        #endif
                    }
                }

                enum KokoroPlaybackError: Error { case timeout }

                func synthesizeWithTimeout(_ text: String) async throws -> Data {
                    try await withThrowingTaskGroup(of: Data.self) { group in
                        group.addTask {
                            try await KokoroTTSService.shared.synthesize(
                                text: text,
                                voice: voice,
                                speed: Float(speed)
                            )
                        }
                        group.addTask {
                            try await Task.sleep(nanoseconds: 20_000_000_000)
                            throw KokoroPlaybackError.timeout
                        }
                        let result = try await group.next()!
                        group.cancelAll()
                        return result
                    }
                }

                let firstData = try await synthesizeWithTimeout(firstChunk)
                if Task.isCancelled { return }
                var currentDuration = try await playChunk(firstData)

                if chunks.count == 1 { return }

                var nextIndex = 1
                var nextTask: Task<Data, Error>? = Task {
                    try await synthesizeWithTimeout(chunks[nextIndex])
                }
                defer { nextTask?.cancel() }

                while nextIndex < chunks.count {
                    try await Task.sleep(nanoseconds: UInt64(currentDuration * 1_000_000_000))
                    if Task.isCancelled { return }

                    guard let task = nextTask else { return }
                    let data = try await task.value
                    nextIndex += 1

                    if nextIndex < chunks.count {
                        nextTask = Task {
                            try await synthesizeWithTimeout(chunks[nextIndex])
                        }
                    } else {
                        nextTask = nil
                    }

                    currentDuration = try await playChunk(data)
                }
            } catch {
                if Task.isCancelled { return }
                await MainActor.run {
                    let message: String
                    if let kokoroError = error as? KokoroTTSServiceError, kokoroError == .notAvailable {
                        message = "MLX TTS is not available. Add the MLXAudio package and model access."
                    } else if String(describing: error).contains("timeout") {
                        message = "Kokoro is still loading models. Please wait a moment and try again."
                    } else {
                        message = "Kokoro TTS failed: \(error.localizedDescription)"
                    }
                    onError(message)
                }
            }
        }
    }
}

// Clickable post image component
struct ClickablePostImage: View {
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
    
    var body: some View {
        Group {
            if isGIF {
                // Use animated image for GIFs (iOS only); fallback to static on macOS
                #if os(iOS)
                KFAnimatedImage(url)
                    .placeholder {
                        Rectangle()
                            .fill(Color.gray.opacity(0.1))
                            .frame(maxWidth: .infinity, maxHeight: 200)
                            .cornerRadius(8)
                            .overlay(
                                VStack {
                                    ProgressView()
                                    Text("Loading GIF...")
                                        .font(.caption)
                                        .foregroundColor(.gray)
                                }
                            )
                    }
                    .fade(duration: 0.25)
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: 300)
                    .cornerRadius(8)
                    .clipped()
                    .onAppear {
                        print("🎬 Loading animated GIF in post: \(url.absoluteString)")
                    }
                #else
                KFImage(url)
                    .placeholder {
                        Rectangle()
                            .fill(Color.gray.opacity(0.1))
                            .frame(maxWidth: .infinity, maxHeight: 200)
                            .cornerRadius(8)
                            .overlay(
                                VStack {
                                    ProgressView()
                                    Text("Loading image...")
                                        .font(.caption)
                                        .foregroundColor(.gray)
                                }
                            )
                    }
                    .fade(duration: 0.25)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: 300)
                    .cornerRadius(8)
                    .clipped()
                #endif
            } else {
                // Use regular image for non-GIFs
                KFImage(url)
                    .placeholder {
                        Rectangle()
                            .fill(Color.gray.opacity(0.1))
                            .frame(maxWidth: .infinity, maxHeight: 200)
                            .cornerRadius(8)
                            .overlay(
                                ProgressView()
                            )
                    }
                    .fade(duration: 0.25)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: 300)
                    .cornerRadius(8)
                    .clipped()
            }
        }
        .onTapGesture {
            showFullScreen = true
        }
        .sheet(isPresented: $showFullScreen) {
            ImagePopupView(imageURL: url)
        }
    }
}
