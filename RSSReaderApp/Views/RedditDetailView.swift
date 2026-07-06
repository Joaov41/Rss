import SwiftUI
import Combine
import Kingfisher
#if os(iOS)
import AVFoundation
import UIKit

private func ensureBackgroundTTSReady() {
    let audioSession = AVAudioSession.sharedInstance()
    do {
        try audioSession.setCategory(
            .playback,
            mode: .spokenAudio,
            options: [.duckOthers, .allowBluetooth, .allowBluetoothA2DP]
        )
        try audioSession.setActive(true)
    } catch {
        print("🔊 [RedditDetailView] Failed to configure audio session: \(error)")
    }
}

#elseif os(macOS)
import AppKit
private func ensureBackgroundTTSReady() {}
#else
private func ensureBackgroundTTSReady() {}
#endif
import Foundation

// Enhanced swipe back extension is defined in ContentView.swift

// Import createWavData from SummaryService

// AppColors is defined in ContentView.swift

// Conditional modifier for enhanced swipe back


#if os(iOS)
// no-op: voice list UI removed to avoid compile issues
#endif
struct ConditionalEnhancedSwipeBack: ViewModifier {
    let isEnabled: Bool
    let appState: AppState
    
    func body(content: Content) -> some View {
        #if os(iOS)
        if isEnabled {
            content.enhancedSwipeBack {
                appState.navigateBack()
            }
        } else {
            content
        }
        #else
        content
        #endif
    }
}


struct RedditDetailView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.colorScheme) private var colorScheme
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif
    @State private var comments: [RedditCommentModel] = []
    @State private var displayedComments: [RedditCommentModel] = []
    @State private var isLoadingComments = false
    @State private var selectedCommentSort: RedditService.CommentSortOption = .best
    @State private var commentLoadStatusMessage: String? = nil
    @State private var showPostCommentSheet = false
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
    @State private var analyticsProviderOverride: AppSettings.SummaryProvider? = nil
    
    // Default max number of comments to show
    private let maxDisplayComments = 50
    private let redditTopAnchor = "redditDetailTopAnchor"
    private let iphoneDetailHorizontalInset: CGFloat = 16

    private var detailBackground: Color {
        colorScheme == .dark ? .black : AppColors.redditBackground(for: colorScheme)
    }

    private var shouldShowMaterialOverlay: Bool {
        colorScheme != .dark
    }

    private var postTitleFont: Font {
        #if os(iOS)
        return isCompactWidth ? .system(size: 28, weight: .bold) : .largeTitle.bold()
        #else
        return .largeTitle.bold()
        #endif
    }

    private var shouldShowExplicitWebAIControls: Bool {
        appState.settings.selectedSummaryProvider != .webAI
    }

    private var activeSummaryProviderName: String {
        appState.settings.selectedSummaryProvider == .webAI
            ? appState.settings.selectedWebAIProvider.displayName
            : appState.settings.selectedSummaryProvider.displayName
    }

    private var activeSummaryProviderIcon: String {
        switch appState.settings.selectedSummaryProvider {
        case .gemini:
            return "sparkles"
        case .appleLocal:
            return "cpu"
        case .appleCloud:
            return "cloud.fill"
        case .applePCCGateway:
            return "network"
        case .mlxLocal, .coreAIMLXLocal:
            return "memorychip"
        case .webAI:
            return "globe"
        case .summarizeDaemon:
            return "terminal"
        }
    }

    private var activeSummaryProviderBadge: some View {
        Label(activeSummaryProviderName, systemImage: activeSummaryProviderIcon)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .accessibilityLabel("Using \(activeSummaryProviderName)")
    }
    
    // Q&A states
    @State private var showQAInterface = false
    @State private var questionText = ""
    @State private var answerText = "Ask a question about this post or its comments..."
    @State private var isAskingSelectionAI = false
    @State private var selectionAskAIPrompt = ""
    @State private var selectionAskAIResponse = ""
    @State private var showSelectionAskAISheet = false

    private var qaAnswerUnavailable: Bool {
        answerText.isEmpty || answerText == "Ask a question about this post or its comments..."
    }
    
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
    #endif
    
    // Voice picker state (Mac only)
    #if os(iOS)
    // voice picker removed; using system default
    #elseif os(macOS)
    @State private var selectedMacVoiceID: String = (UserDefaults.standard.string(forKey: "LocalTTS.Mac.SelectedVoiceID") ?? (preferredMacVoiceIdentifier() ?? ""))
    #endif
    
    // This is a key optimization - adding an ID to the view itself
    // forces the view to refresh when the post ID changes
    private var postId: String {
        appState.selectedRedditPost?.id ?? UUID().uuidString
    }
    
    // Track the view's creation time to help with debugging
    private let viewCreationTime = Date()
    
    var body: some View {
        Group {
            if let post = appState.selectedRedditPost {
                ScrollViewReader { proxy in
                    postDetailView(for: post, proxy: proxy)
                }
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
                self.commentsSentToLLMCount = nil
                
                // Cancel previous requests
                cancellables.removeAll()
                
                // Load the new post's comments
                loadComments(for: post)
            }
        }
        .askAILoadingOverlay(isAskingSelectionAI)
        .sheet(isPresented: $showSelectionAskAISheet) {
            AskAIResponseSheet(
                question: selectionAskAIPrompt,
                answer: selectionAskAIResponse,
                onCopy: {
                    #if os(iOS)
                    UIPasteboard.general.string = selectionAskAIResponse
                    #elseif os(macOS)
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(selectionAskAIResponse, forType: .string)
                    #endif
                }
            )
            #if os(iOS)
            .presentationDetents([.medium, .large])
            .presentationCornerRadius(32)
            #endif
        }
    }

    #if os(iOS)
    private var isCompactWidth: Bool {
        UIDevice.current.userInterfaceIdiom == .phone || horizontalSizeClass == .compact
    }

    private func usesCompactDetailLayout(availableWidth: CGFloat) -> Bool {
        UIDevice.current.userInterfaceIdiom == .phone ||
            horizontalSizeClass == .compact ||
            availableWidth < 700
    }

    private func detailContentWidth(in geometry: GeometryProxy) -> CGFloat? {
        usesCompactDetailLayout(availableWidth: geometry.size.width)
            ? max(0, geometry.size.width - (iphoneDetailHorizontalInset * 2))
            : nil
    }

    private func detailTopPadding(in geometry: GeometryProxy) -> CGFloat {
        // Overlay bar is 60pt in ContentView; align content directly below it.
        return 60
    }
    #endif
    
    private func postDetailView(for post: RedditPost, proxy: ScrollViewProxy) -> some View {
        ZStack {
            // Keep detail background truly black in dark mode.
            detailBackground
                .ignoresSafeArea()
            
            // Material overlay for glass effect:
            // Remove on iPhone to eliminate any chance of scroll/touch interference.
            #if os(iOS)
            if UIDevice.current.userInterfaceIdiom == .phone || !shouldShowMaterialOverlay {
                EmptyView()
            } else {
                Color.clear
                    .background(.regularMaterial)
                    .ignoresSafeArea()
            }
            #else
            if shouldShowMaterialOverlay {
                Color.clear
                    .background(.regularMaterial)
                    .ignoresSafeArea()
            } else {
                EmptyView()
            }
            #endif
            
            GeometryReader { geometry in
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 16) {
                        Color.clear
                            .frame(height: 0)
                            .id(redditTopAnchor)
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
                        .font(postTitleFont)
                        .foregroundColor(.primary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(PlainButtonStyle())
                .frame(maxWidth: .infinity, alignment: .leading)
                
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
                
                if appState.isLoading && post.summary == nil {
                    VStack(spacing: 16) {
                        HStack {
                            Text("Summary")
                                .font(.headline)
                            activeSummaryProviderBadge
                            Spacer()
                            if shouldShowExplicitWebAIControls {
                                Button {
                                    appState.requestWebSummary(for: post, comments: comments)
                                } label: {
                                    Image(systemName: "globe")
                                        .font(.subheadline)
                                }
                                .buttonStyle(LiquidGlassButtonStyle())
                                .help("Generate Reddit summary with \(appState.settings.selectedWebAIProvider.displayName)")
                            }
                        }
                        let summaryStreamText = appState.mlxStreamingText
                        if (appState.settings.selectedSummaryProvider == .appleLocal || appState.settings.selectedSummaryProvider == .mlxLocal || appState.settings.selectedSummaryProvider == .coreAIMLXLocal) && !summaryStreamText.isEmpty {
                            ScrollView {
                                Text(summaryStreamText)
                                    .font(.body)
                                    .foregroundStyle(.primary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding()
                            }
                            .background(AppColors.systemGray6)
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
                            .background(AppColors.systemGray6)
                            .cornerRadius(10)
                        }
                    }
                    Divider()
                } else if appState.isWaitingForAppleIntelligence && post.summary == nil {
                    VStack(spacing: 16) {
                        HStack {
                            Text("Summary")
                                .font(.headline)
                            activeSummaryProviderBadge
                            Spacer()
                            if shouldShowExplicitWebAIControls {
                                Button {
                                    appState.requestWebSummary(for: post, comments: comments)
                                } label: {
                                    Image(systemName: "globe")
                                        .font(.subheadline)
                                }
                                .buttonStyle(LiquidGlassButtonStyle())
                                .help("Generate Reddit summary with \(appState.settings.selectedWebAIProvider.displayName)")
                            }
                        }
                        VStack(spacing: 8) {
                            ProgressView()
                            Text(appState.appleIntelligenceWaitProgress)
                                .foregroundColor(.secondary)
                                .font(.caption)
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(AppColors.systemGray6)
                        .cornerRadius(10)
                    }
                    Divider()
	                } else if let summary = post.summary, !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
	                    VStack(alignment: .leading, spacing: 8) {
	                        HStack {
	                            Text("Summary")
                                .font(.headline)
                            activeSummaryProviderBadge
                            Spacer()
                            if shouldShowExplicitWebAIControls {
                                Button {
                                    appState.requestWebSummary(for: post, comments: comments)
                                } label: {
                                    Image(systemName: "globe")
                                        .font(.subheadline)
                                }
                                .buttonStyle(LiquidGlassButtonStyle())
                                .help("Generate Reddit summary with \(appState.settings.selectedWebAIProvider.displayName)")
                            }
                        }
                        GlassySummary(
                            summary: summary,
                            onAskAISelection: handleAskAISelection(selectedText:context:),
                            onAskAIWebSelection: handleAskAIWebSelection(selectedText:context:)
                        )
                        // Throughput badge for on-device providers (summary)
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
                
                // Show loading indicator while summarizing
                if isLoadingComments && commentSummary == nil {
                    VStack(spacing: 16) {
                        HStack {
                            Text("Comment Summary")
                                .font(.headline)
                            activeSummaryProviderBadge
                            Spacer()
                        }
                        VStack(spacing: 8) {
                            ProgressView()
                            Text("Analyzing \(comments.count) comments...")
                                .foregroundColor(.secondary)
                                .font(.caption)
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(AppColors.systemGray6)
                        .cornerRadius(10)
                    }
                    Divider()
                } else if appState.isWaitingForCommentSummary && commentSummary == nil && !comments.isEmpty {
                    VStack(spacing: 16) {
                        HStack {
                            Text("Comment Summary")
                                .font(.headline)
                            activeSummaryProviderBadge
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
                        .background(AppColors.systemGray6)
                        .cornerRadius(10)
                    }
                    Divider()
                } else if let summary = commentSummary {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Comment Summary")
                                .font(.headline)
                            activeSummaryProviderBadge
                            Spacer()
                            Button(action: {
                                showCommentSummary.toggle()
                                print("📱 RedditDetailView: Comment summary visibility toggled to \(showCommentSummary)")
                            }) {
                                Image(systemName: showCommentSummary ? "chevron.up" : "chevron.down")
                            }
                        }
                        if showCommentSummary {
                            GlassyCommentSummary(
                                summary: summary,
                                onAskAISelection: handleAskAISelection(selectedText:context:),
                                onAskAIWebSelection: handleAskAIWebSelection(selectedText:context:)
                            )
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
                    commentsSectionHeader(for: post, availableWidth: geometry.size.width)
                    
                    if isLoadingComments && comments.isEmpty {
                        VStack(spacing: 16) {
                            ProgressView()
                            Text("Loading comments...")
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(20)
                    } else if comments.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            if let statusMessage = commentLoadStatusMessage {
                                HStack(alignment: .top, spacing: 8) {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .foregroundColor(.orange)
                                    Text(statusMessage)
                                        .font(.footnote)
                                        .foregroundColor(.primary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            } else {
                                Text("No comments available.")
                                    .foregroundColor(.secondary)
                                    .italic()
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(20)
                    } else {
                        // Display the toggled Q&A interface
                        if showQAInterface {
                            redditQASection(post: post)
                        }
                        
                        // Display limited comments with option to load more
                        CommentThreadView(comments: displayedComments, post: post) { parentCommentID, reply in
                            handleReplyPosted(to: parentCommentID, reply: reply, post: post)
                        }
                        
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
                #if os(iOS)
                .frame(
                    width: detailContentWidth(in: geometry),
                    alignment: .leading
                )
                #endif
                .padding(.horizontal)
                .padding(.bottom)
                .zIndex(1) // ensure ScrollView sits above any background layers for proper gesture hit-testing
                #if os(iOS)
                .padding(.top, usesCompactDetailLayout(availableWidth: geometry.size.width) ? 16 : detailTopPadding(in: geometry))
                #else
                .padding(.top, 180) // Add extra top padding to account for overlay navigation bar and safe area
                #endif
                // iPhone: use system edge swipe from ContentView overlay to avoid gesture conflicts here
                }
            }
        
        } // Close ZStack
        // Use this key view ID to ensure proper reconstruction when post changes
        .id("reddit-detail-\(post.id)")
        #if os(iOS)
        // On iPhone, use standard navigation bar
        .navigationBarHidden(UIDevice.current.userInterfaceIdiom != .phone)
        #endif
        // Fallback notification overlay (non-interactive so it doesn't block scroll/taps)
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
            .allowsHitTesting(false) // critical: don't intercept gestures
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
            }
        }
        // Add sheet for image popup (consistent with comment images)
        .sheet(isPresented: $showingImagePopup) {
            if let imageURL = selectedImageURL {
                ImagePopupView(imageURL: imageURL)
                    .onAppear {
                        print("Showing Reddit post image popup with URL: \(imageURL)")
                    }
            }
        }
        // Add floating loading indicator overlay for iPhone
        .overlay {
            #if os(iOS)
            if UIDevice.current.userInterfaceIdiom == .phone {
                ZStack {
                    // Show spinner for POST summary
                    if appState.isLoading && post.summary == nil {
                        VStack {
                            Spacer()
                            HStack(spacing: 12) {
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                Text("Summarizing post...")
                                    .foregroundColor(.white)
                                    .font(.subheadline)
                            }
                            .padding()
                            .background(.black.opacity(0.8))
                            .cornerRadius(10)
                            .padding(.bottom, 100) // Position above bottom bar
                        }
                    }
                    
                    // Show spinner for COMMENT summary
                    if isLoadingComments && commentSummary == nil {
                        VStack {
                            Spacer()
                            HStack(spacing: 12) {
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                Text("Analyzing comments...")
                                    .foregroundColor(.white)
                                    .font(.subheadline)
                            }
                            .padding()
                            .background(.black.opacity(0.8))
                            .cornerRadius(10)
                            .padding(.bottom, 100) // Position above bottom bar
                        }
                    }
                    
                    if isProcessingQuestion {
                        VStack {
                            Spacer()
                            HStack(spacing: 12) {
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                Text("Processing question...")
                                    .foregroundColor(.white)
                                    .font(.subheadline)
                            }
                            .padding()
                            .background(.black.opacity(0.8))
                            .cornerRadius(10)
                            .padding(.bottom, 100) // Position above bottom bar
                        }
                    }
                }
            }
            #endif
        }
#if os(iOS)
        .overlay(alignment: .bottomTrailing) {
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
        }
#endif
        // Add toolbar with buttons for non-phone layouts only.
        .toolbar {
            #if os(iOS)
            if UIDevice.current.userInterfaceIdiom != .phone {
                ToolbarItemGroup(placement: .bottomBar) {
                    HStack(spacing: 12) {
                        Button(action: {
                            withAnimation(.easeInOut) {
                                proxy.scrollTo(redditTopAnchor, anchor: .top)
                            }
                        }) {
                            Label("Scroll to Top", systemImage: "arrow.up.circle.fill")
                                .font(.subheadline)
                        }
                        .buttonStyle(LiquidGlassButtonStyle())

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
                            Image(systemName: showQAInterface ? "xmark.circle.fill" : "questionmark.circle.fill")
                                .font(.subheadline)
                        }
                        .accessibilityLabel(showQAInterface ? "Hide Q&A" : "Ask")
                        .buttonStyle(LiquidGlassButtonStyle())
                        
                        Spacer()
                        
                        Button(action: { 
                            // Only show if there are comments to summarize
                            if !comments.isEmpty {
                                // Clear any existing summary first
                                commentSummary = nil
                                summarizeComments(for: post)
                            }
                        }) {
                            Image(systemName: "text.quote")
                                .font(.subheadline)
                        }
                        .accessibilityLabel("Summarize")
                        .buttonStyle(LiquidGlassButtonStyle())
                        .disabled(comments.isEmpty)
                    }
                }
            }
            #else
            ToolbarItemGroup(placement: .primaryAction) {
                HStack(spacing: 12) {
                    Button(action: {
                        withAnimation(.easeInOut) {
                            proxy.scrollTo(redditTopAnchor, anchor: .top)
                        }
                    }) {
                        Label("Scroll to Top", systemImage: "arrow.up.circle.fill")
                            .font(.subheadline)
                    }
                    .buttonStyle(LiquidGlassButtonStyle())

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
                        Image(systemName: showQAInterface ? "xmark.circle.fill" : "questionmark.circle.fill")
                            .font(.subheadline)
                    }
                    .accessibilityLabel(showQAInterface ? "Hide Q&A" : "Ask")
                    .buttonStyle(LiquidGlassButtonStyle())
                    
                    Spacer()
                    
                    Button(action: { 
                        // Only show if there are comments to summarize
                        if !comments.isEmpty {
                            // Clear any existing summary first
                            commentSummary = nil
                            summarizeComments(for: post)
                        }
                    }) {
                        Image(systemName: "text.quote")
                            .font(.subheadline)
                    }
                    .accessibilityLabel("Summarize")
                    .buttonStyle(LiquidGlassButtonStyle())
                    .disabled(comments.isEmpty)
                }
            }
            #endif
        }
    }

    private var redditQAAccentColor: Color {
        Color.orange
    }

    private func redditQASection(post: RedditPost) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            redditQAHeader(post: post)
            redditQAPromptField(post: post)
            redditQAAnswerContent()
            if !qaAnswerUnavailable {
                redditQAUtilityButtons()
            }
            redditQAStatusIndicators()
        }
        .padding(24)
        .background(redditQACardBackground)
        .padding(.bottom, 16)
    }

    private func redditQAHeader(post: RedditPost) -> some View {
        HStack(alignment: .center, spacing: 16) {
            ZStack {
                Circle()
                    .fill(AppColors.redditCardBorder(for: colorScheme))
                    .shadow(color: redditQAAccentColor.opacity(0.36), radius: 12, x: 0, y: 0)

                Image(systemName: "sparkles")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: 58, height: 58)

            VStack(alignment: .leading, spacing: 4) {
                Text("Ask a question about these comments")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.primary)

                Text("Get quick answers based on the post and comment thread.")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            HStack(spacing: 8) {
                if shouldShowExplicitWebAIControls {
                    redditQAHeaderActionButton(
                        systemName: "globe",
                        accessibilityLabel: appState.settings.selectedWebAIProvider.displayName,
                        isDisabled: questionText.isEmpty || isProcessingQuestion
                    ) {
                        askWebQuestion(post: post)
                    }
                }

                redditQAHeaderActionButton(systemName: "xmark", accessibilityLabel: "Cancel") {
                    showQAInterface = false
                    questionText = ""
                    answerText = "Ask a question about this post or its comments..."
                    commentsSentToLLMCount = nil
                    print("📱 RedditDetailView: Q&A interface canceled by user")
                }
            }
        }
    }

    private func redditQAPromptField(post: RedditPost) -> some View {
        HStack(spacing: 12) {
            redditQAInputField(post: post)

            Button(action: {
                if !questionText.isEmpty {
                    askQuestion(post: post)
                }
            }) {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 46, height: 46)
                    .background(Circle().fill(redditQAAccentColor))
                    .shadow(color: redditQAAccentColor.opacity(0.45), radius: 10, x: 0, y: 0)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Ask")
            .disabled(questionText.isEmpty || isProcessingQuestion)
            .opacity(questionText.isEmpty || isProcessingQuestion ? 0.45 : 1)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(colorScheme == .dark ? Color.white.opacity(0.06) : Color.white.opacity(0.74))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(AppColors.redditCardBorder(for: colorScheme), lineWidth: 1.2)
        )
        .shadow(color: redditQAAccentColor.opacity(colorScheme == .dark ? 0.22 : 0.12), radius: 10, x: 0, y: 0)
    }

    private func redditQAInputField(post: RedditPost) -> some View {
        TextField("Type your question...", text: $questionText)
            .textFieldStyle(PlainTextFieldStyle())
            .font(.system(size: 16, weight: .regular))
            .foregroundStyle(.primary)
            .submitLabel(.send)
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

    private func redditQAHeaderActionButton(
        systemName: String,
        accessibilityLabel: String,
        isDisabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(isDisabled ? Color.secondary : redditQAAccentColor)
                .frame(width: 40, height: 34)
                .background(
                    Capsule(style: .continuous)
                        .fill(colorScheme == .dark ? Color.white.opacity(0.055) : Color.black.opacity(0.035))
                )
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(redditQAAccentColor.opacity(isDisabled ? 0.16 : 0.32), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.55 : 1)
    }

    @ViewBuilder
    private func redditQAAnswerContent() -> some View {
        if isProcessingQuestion {
            let qaStreamText = appState.mlxStreamingText
            if (appState.settings.selectedSummaryProvider == .appleLocal || appState.settings.selectedSummaryProvider == .mlxLocal || appState.settings.selectedSummaryProvider == .coreAIMLXLocal) && !qaStreamText.isEmpty {
                Text(qaStreamText)
                    .font(.body)
                    .foregroundColor(.primary)
                    .padding(.vertical, 16)
                    .padding(.horizontal, 20)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("Thinking...")
                        .font(.body)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 16)
                .padding(.horizontal, 20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else if !qaAnswerUnavailable {
            SelectableText(
                text: answerText,
                onAskAI: handleAskAISelection(selectedText:context:),
                onAskAIWeb: handleAskAIWebSelection(selectedText:context:),
                textIsPrecleaned: true
            )
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 16)
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func redditQAUtilityButtons() -> some View {
        HStack(spacing: 12) {
            Button {
                speakAnswerQA(answerText)
            } label: {
                Image(systemName: "speaker.wave.2")
                    .font(.subheadline)
            }
            .buttonStyle(LiquidGlassButtonStyle())
            .ttsActiveGlow(isSynthesizingSpeechQA, color: redditQAAccentColor)
            .help("Read aloud (Cloud)")
            .disabled(isSynthesizingSpeechQA || isSpeakingLocallyQA)

            Button {
                stopQASpeech()
            } label: {
                Image(systemName: "stop.fill")
                    .font(.subheadline)
            }
            .buttonStyle(LiquidGlassButtonStyle())
            .help("Stop speech")

            Button {
                speakAnswerLocallyQA(answerText)
            } label: {
                Image(systemName: "speaker.wave.2.circle")
                    .font(.subheadline)
            }
            .buttonStyle(LiquidGlassButtonStyle())
            .ttsActiveGlow(isSpeakingLocallyQA, color: .green)
            .help("Read aloud (Local)")
            .disabled(isSynthesizingSpeechQA)

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
        }
        .padding(.top, 5)
    }

    @ViewBuilder
    private func redditQAStatusIndicators() -> some View {
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

        if let count = commentsSentToLLMCount, !isProcessingQuestion, answerText != "Ask a question about this post or its comments..." {
            Text("Answer based on \(count) comments")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.top, 4)
        }

        let redditQAProvider = appState.settings.selectedSummaryProvider
        if (redditQAProvider == .mlxLocal || redditQAProvider == .coreAIMLXLocal || redditQAProvider == .appleLocal || redditQAProvider == .applePCCGateway || redditQAProvider == .summarizeDaemon),
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

    private var redditQACardBackground: some View {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
            .fill(colorScheme == .dark ? Color(red: 0.035, green: 0.035, blue: 0.04) : Color.orange.opacity(0.055))
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(AppColors.redditCardBorder(for: colorScheme), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.18 : 0.06), radius: 12, x: 0, y: 8)
    }

    @ViewBuilder
    private func commentsSectionHeader(for post: RedditPost, availableWidth: CGFloat) -> some View {
        #if os(iOS)
        if usesCompactDetailLayout(availableWidth: availableWidth) {
            compactCommentsSectionHeader(for: post)
        } else {
            regularCommentsSectionHeader(for: post)
        }
        #else
        regularCommentsSectionHeader(for: post)
        #endif
    }

    private var commentsHeaderTitle: some View {
        HStack(spacing: 8) {
            Text(isLoadingComments ? "Comments" : "\(comments.count) Comments")
                .font(.system(size: 20, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .fixedSize(horizontal: true, vertical: false)

            if isLoadingComments {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .layoutPriority(1)
    }

    private func regularCommentsSectionHeader(for post: RedditPost) -> some View {
        HStack(spacing: 10) {
            commentsHeaderTitle

            Spacer(minLength: 12)

            commentsHeaderActions(for: post)
        }
    }

    private func compactCommentsSectionHeader(for post: RedditPost) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                commentsHeaderTitle
                Spacer(minLength: 8)
            }

            HStack(spacing: 8) {
                compactCommentsHeaderActions(for: post)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .sheet(isPresented: $showPostCommentSheet) {
            postCommentSheet(for: post)
        }
    }

    private func compactCommentsHeaderActions(for post: RedditPost) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
                compactAddCommentButton
                if !comments.isEmpty {
                    compactCommentSortMenu(for: post)
                    compactAnalysisButton
                    if shouldShowExplicitWebAIControls {
                        compactWebActionsMenu(for: post)
                    }
                    compactSummarizeButton(for: post)
                    compactAskButton
                }
            }

            HStack(spacing: 6) {
                compactAddCommentButton
                if !comments.isEmpty {
                    compactCommentSortMenu(for: post)
                    compactSummarizeButton(for: post)
                    compactAskButton
                    compactOverflowMenu(for: post, includesSummary: false)
                }
            }

            HStack(spacing: 6) {
                compactAddCommentButton
                if !comments.isEmpty {
                    compactCommentSortMenu(for: post)
                    compactAskButton
                    compactOverflowMenu(for: post, includesSummary: true)
                }
            }
        }
    }

    private var compactAddCommentButton: some View {
        Button {
            showPostCommentSheet = true
        } label: {
            compactHeaderIcon(systemName: "square.and.pencil")
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Add comment")
        .disabled(isLoadingComments)
    }

    private func compactCommentSortMenu(for post: RedditPost) -> some View {
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
            compactHeaderControl(width: 82) {
                HStack(spacing: 4) {
                    Text(selectedCommentSort.displayName)
                        .font(.system(size: 16, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 12, weight: .bold))
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(isLoadingComments)
        .accessibilityLabel("Comment sort")
    }

    private var compactAnalysisButton: some View {
        Button {
            analyticsProviderOverride = nil
            isShowingAnalytics = true
        } label: {
            compactHeaderIcon(systemName: "chart.pie.fill")
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Deep Analysis")
    }

    private func compactWebActionsMenu(for post: RedditPost) -> some View {
        Menu {
            Button {
                requestWebCommentSummary(for: post)
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
            compactHeaderIcon(systemName: "globe")
        }
        .buttonStyle(.plain)
        .help("Send comment prompts to \(appState.settings.selectedWebAIProvider.displayName)")
    }

    private func compactSummarizeButton(for post: RedditPost) -> some View {
        Button(action: {
            print("📱 Summarize button pressed - clearing summary and calling summarizeComments")
            commentSummary = nil
            summarizeComments(for: post)
        }) {
            compactHeaderIcon(systemName: "text.redaction")
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Summarize")
        .disabled(isLoadingComments)
    }

    private var compactAskButton: some View {
        Button(action: {
            showQAInterface.toggle()
        }) {
            compactHeaderIcon(systemName: showQAInterface ? "xmark.circle" : "questionmark.circle")
        }
        .buttonStyle(.plain)
        .accessibilityLabel(showQAInterface ? "Hide Q&A" : "Ask")
        .disabled(isLoadingComments)
    }

    private func compactOverflowMenu(for post: RedditPost, includesSummary: Bool) -> some View {
        Menu {
            Button {
                analyticsProviderOverride = nil
                isShowingAnalytics = true
            } label: {
                Label("Deep Analysis", systemImage: "chart.pie.fill")
            }

            if shouldShowExplicitWebAIControls {
                Button {
                    requestWebCommentSummary(for: post)
                } label: {
                    Label("Web Summary", systemImage: "globe")
                }

                Button {
                    analyticsProviderOverride = .webAI
                    isShowingAnalytics = true
                } label: {
                    Label("Web Analysis", systemImage: "chart.pie.fill")
                }
            }

            if includesSummary {
                Button {
                    print("📱 Summarize button pressed - clearing summary and calling summarizeComments")
                    commentSummary = nil
                    summarizeComments(for: post)
                } label: {
                    Label("Summarize", systemImage: "text.redaction")
                }
                .disabled(isLoadingComments)
            }
        } label: {
            compactHeaderIcon(systemName: "ellipsis")
        }
        .buttonStyle(.plain)
        .accessibilityLabel("More comment actions")
    }

    private func compactHeaderIcon(systemName: String) -> some View {
        compactHeaderControl {
            Image(systemName: systemName)
                .font(.system(size: 19, weight: .semibold))
        }
    }

    private func compactHeaderControl<Content: View>(
        width: CGFloat = 42,
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .foregroundStyle(.primary)
            .frame(width: width, height: 42)
            .background {
                Capsule(style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay {
                        Capsule(style: .continuous)
                            .stroke(Color.white.opacity(colorScheme == .dark ? 0.42 : 0.28), lineWidth: 1)
                    }
            }
            .contentShape(Capsule(style: .continuous))
    }

    @ViewBuilder
    private func commentsHeaderActions(for post: RedditPost) -> some View {
        Button {
            showPostCommentSheet = true
        } label: {
            Image(systemName: "square.and.pencil")
                .font(.subheadline)
        }
        .accessibilityLabel("Add comment")
        .disabled(isLoadingComments)
        .buttonStyle(LiquidGlassButtonStyle())
        .sheet(isPresented: $showPostCommentSheet) {
            postCommentSheet(for: post)
        }

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
                        requestWebCommentSummary(for: post)
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

    private func postCommentSheet(for post: RedditPost) -> some View {
        RedditCommentReplySheet(post: post) { body in
            let postedComment = try await appState.redditService.commentOnPost(postID: post.id, body: body)
            let visibleComment = RedditCommentModel(
                id: postedComment.id,
                author: postedComment.author,
                body: postedComment.body,
                score: postedComment.score,
                createdUtc: postedComment.createdUtc,
                replies: postedComment.replies,
                indentationLevel: 0
            )
            await MainActor.run {
                handleTopLevelCommentPosted(visibleComment, post: post)
            }
        }
    }

    private func handleTopLevelCommentPosted(_ comment: RedditCommentModel, post: RedditPost) {
        guard post.id == appState.selectedRedditPost?.id else { return }

        appState.redditService.invalidateCommentCache(for: post.id, in: post.subreddit)

        guard !containsComment(withID: comment.id, in: comments) else { return }

        comments.insert(comment, at: 0)
        displayedComments.insert(comment, at: 0)
        if displayedComments.count > maxDisplayComments {
            displayedComments = Array(displayedComments.prefix(maxDisplayComments))
        }
        hasMoreCommentsToLoad = displayedComments.count < comments.count
        commentLoadStatusMessage = nil

        commentSummary = nil
        showCommentSummary = false
        commentsSentToLLMCount = nil
    }

    private func handleReplyPosted(to parentCommentID: String, reply: RedditCommentModel, post: RedditPost) {
        guard post.id == appState.selectedRedditPost?.id else { return }

        appState.redditService.invalidateCommentCache(for: post.id, in: post.subreddit)

        let fullUpdate = commentsByAppendingReply(reply, toParentID: parentCommentID, in: comments)
        if fullUpdate.didInsert {
            comments = fullUpdate.comments
        }

        let visibleUpdate = commentsByAppendingReply(reply, toParentID: parentCommentID, in: displayedComments)
        if visibleUpdate.didInsert {
            displayedComments = visibleUpdate.comments
        } else if fullUpdate.didInsert {
            displayedComments = Array(comments.prefix(maxDisplayComments))
            hasMoreCommentsToLoad = displayedComments.count < comments.count
        }

        commentSummary = nil
        showCommentSummary = false
        commentsSentToLLMCount = nil
    }

    private func commentsByAppendingReply(
        _ reply: RedditCommentModel,
        toParentID parentCommentID: String,
        in commentList: [RedditCommentModel]
    ) -> (comments: [RedditCommentModel], didInsert: Bool) {
        var didInsert = false

        let updatedComments = commentList.map { comment -> RedditCommentModel in
            if comment.id == parentCommentID {
                didInsert = true
                guard !containsComment(withID: reply.id, in: comment.replies) else {
                    return comment
                }

                return RedditCommentModel(
                    id: comment.id,
                    author: comment.author,
                    body: comment.body,
                    score: comment.score,
                    createdUtc: comment.createdUtc,
                    replies: comment.replies + [reply],
                    indentationLevel: comment.indentationLevel
                )
            }

            let nestedUpdate = commentsByAppendingReply(reply, toParentID: parentCommentID, in: comment.replies)
            if nestedUpdate.didInsert {
                didInsert = true
                return RedditCommentModel(
                    id: comment.id,
                    author: comment.author,
                    body: comment.body,
                    score: comment.score,
                    createdUtc: comment.createdUtc,
                    replies: nestedUpdate.comments,
                    indentationLevel: comment.indentationLevel
                )
            }

            return comment
        }

        return (updatedComments, didInsert)
    }

    private func containsComment(withID id: String, in commentList: [RedditCommentModel]) -> Bool {
        commentList.contains { comment in
            comment.id == id || containsComment(withID: id, in: comment.replies)
        }
    }
    
    private func loadComments(for post: RedditPost) {
        // Cancel any existing subscriptions
        cancellables.removeAll()
        
        // Set loading state
        isLoadingComments = true
        commentLoadStatusMessage = nil
        comments = []
        displayedComments = []
        hasMoreCommentsToLoad = false
        
        // Adding a small delay helps prevent navigation issues
        // by ensuring the view is fully stable before network calls
        print("📱 RedditDetailView: Preparing to load \(selectedCommentSort.displayName) comments for post ID: \(post.id) in r/\(post.subreddit)")

        // Use shared redditService from appState for proper OAuth token handling
        appState.redditService.fetchCommentsDetailed(for: post.id, in: post.subreddit, sortOption: selectedCommentSort)
            .receive(on: RunLoop.main)
            .sink { result in
                // Double-check that we're still looking at the same post
                guard post.id == appState.selectedRedditPost?.id else { 
                    print("⚠️ RedditDetailView: Discarding comments - post changed")
                    return
                }
                
                if let error = result.error {
                    if result.httpStatusCode == 429 {
                        commentLoadStatusMessage = "Reddit is rate limiting comment requests right now. Comments may be unavailable for a short time."
                    } else {
                        commentLoadStatusMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    }
                    print("⚠️ RedditDetailView: Comment fetch warning for \(post.id): \(commentLoadStatusMessage ?? error.localizedDescription)")
                    self.isLoadingComments = false
                    return
                }
                
                // Filter out AutoModerator comments
                self.comments = result.comments
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
                
                print("✅ RedditDetailView: Loaded \(self.comments.count) \(self.selectedCommentSort.displayName) comments for post ID: \(post.id)")
                self.commentLoadStatusMessage = nil
                self.isLoadingComments = false
            }
            .store(in: &cancellables)
    }

    private func selectCommentSort(_ sortOption: RedditService.CommentSortOption, for post: RedditPost) {
        guard sortOption != selectedCommentSort else { return }

        selectedCommentSort = sortOption
        commentSummary = nil
        showCommentSummary = false
        commentsSentToLLMCount = nil
        answerText = "Ask a question about this post or its comments..."
        questionText = ""

        loadComments(for: post)
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
    
    private func summarizeComments(for post: RedditPost) {
        guard !comments.isEmpty else { return }
        
        print("⚙️ RedditDetailView: Summarizing \(comments.count) comments for post ID: \(post.id)")
        let promptCommentCount = appState.flattenedCommentCountForSummary(comments: comments)
        
        // Ensure we're not already generating a summary
        if isProcessingQuestion {
            print("⚠️ RedditDetailView: Cannot summarize while processing a question")
            return
        }
        
        // Set loading state immediately to show progress indicator
        print("📱 Setting isLoadingComments = true")
        withAnimation {
            isLoadingComments = true
        }
        commentSummary = nil
        showCommentSummary = false
        
                // Check if we should use Apple Intelligence instead
        if appState.settings.selectedSummaryProvider == .appleLocal {
            // Use on-device AI for comment summary with Gemini fallback
            let prompt = appState.commentSummaryPrompt(comments: comments)
            
            // Set loading state
            isLoadingComments = true
            self.commentsSentToLLMCount = promptCommentCount
            
            appState.performLocalWithGeminiFallbackPublic(prompt: prompt, taskName: "Reddit Comment Summary") { summaryText in
                guard appState.selectedRedditPost?.id == post.id else {
                    print("⚠️ RedditDetailView: Post selection changed before Apple Local summary completed, discarding results")
                    self.isLoadingComments = false
                    return
                }
                let cleanedSummaryText = cleanAndFormatCommentSummaryForDisplay(summaryText)
                self.commentSummary = CommentSummary(
                    postId: post.id,
                    subreddit: post.subreddit,
                    summary: cleanedSummaryText,
                    commentCount: promptCommentCount,
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
            self.commentsSentToLLMCount = promptCommentCount
            
            appState.launchCloudRequest(for: prompt, type: .commentSummary) { summaryText in
                guard appState.selectedRedditPost?.id == post.id else {
                    print("⚠️ RedditDetailView: Post selection changed before Apple Cloud summary completed, discarding results")
                    self.isLoadingComments = false
                    return
                }
                let cleanedSummaryText = cleanAndFormatCommentSummaryForDisplay(summaryText)
                // Create summary with the result
                self.commentSummary = CommentSummary(
                    postId: post.id,
                    subreddit: post.subreddit,
                    summary: cleanedSummaryText,
                    commentCount: promptCommentCount,
                    topCommenters: [],
                    mainTopics: [],
                    sentiment: .neutral,
                    createdDate: Date()
                )
                self.showCommentSummary = true
                self.isLoadingComments = false
            }
            return
        } else if appState.settings.selectedSummaryProvider == .mlxLocal || appState.settings.selectedSummaryProvider == .coreAIMLXLocal {
            // Use MLX Local model for comment summary
            print("🧠 RedditDetailView: Using MLX Local for comment summary")
            let prompt = appState.commentSummaryPrompt(comments: comments)

            // Set loading state
            isLoadingComments = true
            self.commentsSentToLLMCount = promptCommentCount

            appState.performMLXLocalSummaryPublic(prompt: prompt) { summaryText in
                guard appState.selectedRedditPost?.id == post.id else {
                    print("⚠️ RedditDetailView: Post selection changed before MLX summary completed, discarding results")
                    self.isLoadingComments = false
                    return
                }
                let cleanedSummaryText = cleanAndFormatCommentSummaryForDisplay(summaryText)
                self.commentSummary = CommentSummary(
                    postId: post.id,
                    subreddit: post.subreddit,
                    summary: cleanedSummaryText,
                    commentCount: promptCommentCount,
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
            requestWebCommentSummary(for: post)
            return
        } else if appState.settings.selectedSummaryProvider == .applePCCGateway {
            print("☁️ RedditDetailView: Using Apple PCC Gateway for comment summary")
            let prompt = appState.commentSummaryPrompt(comments: comments)

            isLoadingComments = true
            self.commentsSentToLLMCount = promptCommentCount

            appState.performPCCGatewaySummaryPublic(prompt: prompt, taskName: "Reddit Comment Summary") { summaryText in
                guard appState.selectedRedditPost?.id == post.id else {
                    print("⚠️ RedditDetailView: Post selection changed before Apple PCC Gateway summary completed, discarding results")
                    self.isLoadingComments = false
                    return
                }
                let cleanedSummaryText = cleanAndFormatCommentSummaryForDisplay(summaryText)
                self.commentSummary = CommentSummary(
                    postId: post.id,
                    subreddit: post.subreddit,
                    summary: cleanedSummaryText,
                    commentCount: promptCommentCount,
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
            print("⚡ RedditDetailView: Using Codex / Summarize for comment summary")
            let prompt = appState.commentSummaryPrompt(comments: comments)

            isLoadingComments = true
            self.commentsSentToLLMCount = promptCommentCount

            appState.performSummarizeSummaryPublic(prompt: prompt, taskName: "Reddit Comment Summary") { summaryText in
                guard appState.selectedRedditPost?.id == post.id else {
                    print("⚠️ RedditDetailView: Post selection changed before Summarize summary completed, discarding results")
                    self.isLoadingComments = false
                    return
                }
                let cleanedSummaryText = cleanAndFormatCommentSummaryForDisplay(summaryText)
                self.commentSummary = CommentSummary(
                    postId: post.id,
                    subreddit: post.subreddit,
                    summary: cleanedSummaryText,
                    commentCount: promptCommentCount,
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
        // Keep Gemini capped to avoid overflowing its request size while local providers
        // use full input plus explicit reroute handling.
        let commentsToSummarize = self.comments
        let geminiCommentPromptLimit = 800
        let geminiPromptCommentCount = appState.flattenedCommentCountForSummary(
            comments: commentsToSummarize,
            maxComments: geminiCommentPromptLimit
        )
        let prompt = appState.commentSummaryPrompt(
            comments: commentsToSummarize,
            maxComments: geminiCommentPromptLimit
        )
        self.commentsSentToLLMCount = geminiPromptCommentCount
        
        appState.summaryService.summarizeText("", customPrompt: prompt)
            .receive(on: RunLoop.main)
            .sink { summaryText in
                // Make sure we're still on the same post
                guard appState.selectedRedditPost?.id == post.id else {
                    print("⚠️ RedditDetailView: Post selection changed before summary completed, discarding results")
                    return
                }
                
                // Create a new summary with the correct post ID and subreddit
                let updatedSummary = CommentSummary(
                    postId: post.id,
                    subreddit: post.subreddit,
                    summary: cleanAndFormatCommentSummaryForDisplay(summaryText),
                    commentCount: geminiPromptCommentCount,
                    topCommenters: [],
                    mainTopics: [],
                    sentiment: .neutral,
                    createdDate: Date()
                )
                
                // Update state with the new summary and show it
                self.commentSummary = updatedSummary
                self.showCommentSummary = true
                self.isLoadingComments = false
                print("✅ RedditDetailView: Comment summary generated for post ID: \(post.id)")
            }
            .store(in: &cancellables)
    }

    private func requestWebCommentSummary(for post: RedditPost) {
        guard !comments.isEmpty else { return }

        let commentsToSummarize = comments
        let prompt = appState.commentSummaryPrompt(comments: commentsToSummarize)
        let promptCommentCount = appState.flattenedCommentCountForSummary(comments: commentsToSummarize)

        isLoadingComments = true
        commentsSentToLLMCount = promptCommentCount
        commentSummary = nil
        showCommentSummary = false

        appState.performWebAIRequest(
            title: "Comment Summary",
            prompt: prompt,
            onSuccess: { summaryText in
                DispatchQueue.main.async {
                    guard appState.selectedRedditPost?.id == post.id else {
                        print("⚠️ RedditDetailView: Post selection changed before Web AI summary completed, discarding results")
                        self.isLoadingComments = false
                        return
                    }

                    let cleanedSummaryText = cleanAndFormatCommentSummaryForDisplay(summaryText)
                    self.commentSummary = CommentSummary(
                        postId: post.id,
                        subreddit: post.subreddit,
                        summary: cleanedSummaryText,
                        commentCount: promptCommentCount,
                        topCommenters: [],
                        mainTopics: [],
                        sentiment: .neutral,
                        createdDate: Date()
                    )
                    self.showCommentSummary = true
                    self.isLoadingComments = false
                }
            },
            onFailure: { _ in
                DispatchQueue.main.async {
                    self.isLoadingComments = false
                }
            }
        )
    }
    
    private func askQuestion(post: RedditPost) {
        guard !questionText.isEmpty && !comments.isEmpty else { return }

        print("📱 RedditDetailView: Asking question: \"\(questionText)\" about post \(post.id)")

        // Set loading state
        print("📱 Setting isProcessingQuestion = true")
        withAnimation {
            isProcessingQuestion = true
            answerText = "" // Clear text so progress indicator shows
        }
        let currentComments = self.comments
        self.commentsSentToLLMCount = currentComments.count

        // Use AppState's askQuestionAboutRedditPost which handles both Gemini and Apple Intelligence
        appState.askQuestionAboutRedditPost(post: post, comments: currentComments, question: questionText) { answer in
            // Insert paragraph breaks before bold headers before stripping markdown
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
            self.isProcessingQuestion = false
            // Update previous question for next time
            self.previousQuestionText = self.questionText
            print("📱 RedditDetailView: Got answer, updating UI")
        }
    }

    private func askWebQuestion(post: RedditPost) {
        guard !questionText.isEmpty && !comments.isEmpty else { return }

        print("📱 RedditDetailView: Asking WebAI question: \"\(questionText)\" about post \(post.id)")

        withAnimation {
            isProcessingQuestion = true
            answerText = ""
        }
        let currentComments = self.comments
        self.commentsSentToLLMCount = currentComments.count

        appState.askWebQuestionAboutRedditPost(post: post, comments: currentComments, question: questionText) { answer in
            self.answerText = formatAskAIResponseForDisplay(answer)
            self.isProcessingQuestion = false
            self.previousQuestionText = self.questionText
            print("📱 RedditDetailView: Got WebAI answer, updating UI")
        }
    }

    private func handleAskAISelection(selectedText: String, context: String) {
        runSelectionAskAI(selectedText: selectedText, context: context, useWebPath: false)
    }

    private func handleAskAIWebSelection(selectedText: String, context: String) {
        runSelectionAskAI(selectedText: selectedText, context: context, useWebPath: true)
    }

    private func runSelectionAskAI(selectedText: String, context: String, useWebPath: Bool) {
        guard !isAskingSelectionAI else { return }
        let sourceContext = appState.selectedRedditPost.map {
            appState.redditSelectionSourceContext(post: $0, comments: comments)
        }
        let prompt = buildAskAISelectionPrompt(
            selectedText: selectedText,
            extractedContext: context,
            sourceContext: sourceContext?.text ?? "",
            sourceLabel: sourceContext?.label ?? ""
        )
        guard !prompt.isEmpty else { return }

        selectionAskAIPrompt = prompt
        selectionAskAIResponse = ""
        isAskingSelectionAI = true

        let finish: (String) -> Void = { answer in
            DispatchQueue.main.async {
                self.selectionAskAIResponse = formatAskAIResponseForDisplay(answer)
                self.isAskingSelectionAI = false
                self.showSelectionAskAISheet = true
            }
        }

        if useWebPath {
            appState.askWebQuestionAboutSelection(prompt: prompt, completion: finish)
        } else {
            appState.askQuestionAboutSelection(prompt: prompt, completion: finish)
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
        localTTSTaskQA?.cancel()
        localTTSTaskQA = nil
        KokoroTTSService.shared.cancelPlayback()
        audioPlayerQA?.stop()
        audioPlayerQA = nil
        localSpeechSynthQA?.stopSpeaking(at: .immediate)
        #elseif os(macOS)
        audioPlayerQA?.stop()
        audioPlayerQA = nil
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
        ensureBackgroundTTSReady()
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
        // Toggle off if already speaking
        if isSpeakingLocallyQA {
            localTTSTaskQA?.cancel()
            localTTSTaskQA = nil
            KokoroTTSService.shared.cancelPlayback()
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
        localSpeechSynthQA?.stopSpeaking(at: .immediate)
        ensureBackgroundTTSReady()

        let localEngine = appState.summaryService.getLocalTTSEngine()
        if localEngine == .kokoro {
            guard KokoroTTSService.shared.isAvailable else {
                speechSynthesisErrorQA = "MLX TTS is not available. Add the MLXAudio package and model access."
                return
            }
            isSpeakingLocallyQA = true
            isSynthesizingSpeechQA = false
            speechSynthesisErrorQA = nil
            let allowCaching = appState.summaryService.isKokoroPrecacheEnabled()
            startKokoroPlayback(
                text: text,
                voice: appState.summaryService.getKokoroVoice(),
                speed: appState.summaryService.getKokoroSpeed(),
                allowCaching: allowCaching,
                precacheEnabled: allowCaching,
                setAudioPlayer: { [self] player in audioPlayerQA = player },
                soundDelegate: soundDelegateQA,
                taskStore: &localTTSTaskQA,
                onCompleted: {
                    self.isSpeakingLocallyQA = false
                    self.localTTSTaskQA = nil
                },
                onError: { message in
                    self.speechSynthesisErrorQA = message
                    self.isSpeakingLocallyQA = false
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
        let overrideQA = UserDefaults.standard.string(forKey: "LocalTTS.Mac.SelectedVoiceID") ?? selectedMacVoiceID
        if !overrideQA.isEmpty { _ = setMacSpeechVoice(synth, identifier: overrideQA) }
        else if let voiceID = preferredMacVoiceIdentifier() { _ = setMacSpeechVoice(synth, identifier: voiceID) }
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
}


// MARK: - Integrated Comment Analytics View Components (Moved from CommentAnalyticsView.swift)

// Using standard SwiftUI colors for now, can be adjusted later if needed.
fileprivate struct AnalyticsColors { // Make fileprivate to avoid polluting global scope
    static var background: Color {
        #if os(iOS)
        Color(uiColor: .systemBackground)
        #else
        AppColors.background
        #endif
    }

    static var systemGray5: Color {
        #if os(iOS)
        Color(uiColor: .systemGray5)
        #else
        Color(NSColor.systemGray)
        #endif
    }

    static var systemGray6: Color {
        #if os(iOS)
        Color(uiColor: .systemGray6)
        #else
        Color(NSColor.controlBackgroundColor)
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
        // Only show Gemini key error if Gemini is the selected provider
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
                if (effectiveSummaryProvider == .appleLocal || effectiveSummaryProvider == .mlxLocal || effectiveSummaryProvider == .coreAIMLXLocal) && !thematicStreamText.isEmpty {
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
                // Throughput badge for on-device providers
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
                // Apple providers and MLX Local don't need API keys
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

    private func isLocalAnalysisError(_ text: String) -> Bool {
        let lowercased = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return lowercased.hasPrefix("litert error:")
            || lowercased.hasPrefix("coreai mlx error:")
            || lowercased.hasPrefix("mlx local error:")
            || lowercased.hasPrefix("choose a cloud or remote provider")
            || lowercased.contains("model id is not configured")
    }

    private func prepareForRoutedThematicAnalysis() {
        thematicAnalysis = nil
        thematicAnalysisError = nil
        isThematicAnalysisLoading = true
        appState.mlxStreamingText = ""
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
        
        let prompt = appState.thematicAnalysisPrompt(comments: commentsToAnalyze)
        
        // Check if we should use Apple Intelligence instead
        if effectiveSummaryProvider == .appleLocal {
            // Use on-device AI only — no Gemini fallback
            let t0 = Date()
            appState.performAppleLocalOnlyPublic(
                prompt: prompt,
                taskName: "Reddit Thematic Analysis",
                appleRequestType: .commentSummary,
                completion: { analysisText in
                    let elapsed = Date().timeIntervalSince(t0)
                    Task { @MainActor in appState.recordAppleLocalThroughputPublic(text: analysisText, elapsed: elapsed) }
                    DispatchQueue.main.async {
                        self.thematicAnalysis = cleanMarkdownArtifactsForDisplay(analysisText)
                        self.thematicAnalysisError = nil
                        self.isThematicAnalysisLoading = false
                    }
                },
                onCancel: {
                    DispatchQueue.main.async {
                        self.thematicAnalysis = nil
                        self.thematicAnalysisError = "Local analysis was cancelled."
                        self.isThematicAnalysisLoading = false
                    }
                },
                onRouteStart: { _ in
                    DispatchQueue.main.async {
                        self.prepareForRoutedThematicAnalysis()
                    }
                },
                presentationScope: .deepAnalysis
            )
            return
        } else if effectiveSummaryProvider == .appleCloud {
            // Use Apple Cloud via Private Cloud Compute
            print("CommentAnalyticsViewIntegrated: Sending \(analyzedCommentCount) comments for thematic analysis using Apple Cloud.")

            appState.launchCloudRequest(for: prompt, type: .commentSummary) { analysisText in
                DispatchQueue.main.async {
                    self.thematicAnalysis = cleanMarkdownArtifactsForDisplay(analysisText)
                    self.thematicAnalysisError = nil
                    self.isThematicAnalysisLoading = false
                }
            }
            return
        } else if effectiveSummaryProvider == .mlxLocal || effectiveSummaryProvider == .coreAIMLXLocal {
            // Use MLX Local model for thematic analysis with higher token limit
            print("🧠 CommentAnalyticsViewIntegrated: Sending \(analyzedCommentCount) comments for thematic analysis using MLX Local.")

            appState.performMLXLocalAnalysisPublic(
                prompt: prompt,
                completion: { analysisText in
                    DispatchQueue.main.async {
                        let cleaned = cleanMarkdownArtifactsForDisplay(analysisText)
                        if self.isLocalAnalysisError(cleaned) {
                            self.thematicAnalysis = nil
                            self.thematicAnalysisError = cleaned
                        } else {
                            self.thematicAnalysis = cleaned
                            self.thematicAnalysisError = nil
                        }
                        self.isThematicAnalysisLoading = false
                    }
                },
                onCancel: {
                    DispatchQueue.main.async {
                        self.thematicAnalysis = nil
                        self.thematicAnalysisError = "Local analysis was cancelled."
                        self.isThematicAnalysisLoading = false
                    }
                },
                onRouteStart: { _ in
                    DispatchQueue.main.async {
                        self.prepareForRoutedThematicAnalysis()
                    }
                },
                presentationScope: .deepAnalysis
            )
            return
        } else if effectiveSummaryProvider == .webAI {
            print("🌐 CommentAnalyticsViewIntegrated: Sending \(analyzedCommentCount) comments for thematic analysis using Web AI.")
            appState.isWebAIHandoffMinimized = true
            appState.performWebAIRequest(
                title: "Reddit Thematic Analysis",
                prompt: prompt,
                onSuccess: { analysisText in
                    DispatchQueue.main.async {
                        self.thematicAnalysis = cleanMarkdownArtifactsForDisplay(analysisText)
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
        } else if effectiveSummaryProvider == .applePCCGateway {
            print("☁️ CommentAnalyticsViewIntegrated: Sending \(analyzedCommentCount) comments for thematic analysis using Apple PCC Gateway.")
            appState.performPCCGatewaySummaryPublic(prompt: prompt, taskName: "Reddit Thematic Analysis") { analysisText in
                DispatchQueue.main.async {
                    self.thematicAnalysis = cleanMarkdownArtifactsForDisplay(analysisText)
                    self.thematicAnalysisError = nil
                    self.isThematicAnalysisLoading = false
                }
            }
            return
        } else if effectiveSummaryProvider == .summarizeDaemon {
            print("⚡ CommentAnalyticsViewIntegrated: Sending \(analyzedCommentCount) comments for thematic analysis using Codex / Summarize.")
            appState.performSummarizeSummaryPublic(prompt: prompt, taskName: "Reddit Thematic Analysis") { analysisText in
                DispatchQueue.main.async {
                    self.thematicAnalysis = cleanMarkdownArtifactsForDisplay(analysisText)
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
                    self.thematicAnalysis = cleanMarkdownArtifactsForDisplay(summaryResult) // Or set to a more user-friendly message
                } else {
                    // Success case
                    self.thematicAnalysis = cleanMarkdownArtifactsForDisplay(summaryResult)
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

// Adaptive glass modifier for general use
struct AdaptiveGlassModifier: ViewModifier {
    let cornerRadius: CGFloat
    let tintColor: Color?
    
    init(cornerRadius: CGFloat = 12, tintColor: Color? = nil) {
        self.cornerRadius = cornerRadius
        self.tintColor = tintColor
    }
    
    func body(content: Content) -> some View {
        if #available(iOS 15.0, macOS 12.0, *) {
            content
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .stroke(tintColor?.opacity(0.3) ?? Color.white.opacity(0.2), lineWidth: 1)
                )
        } else {
            // Fallback for older OS versions
            content
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(tintColor ?? Color.gray.opacity(0.2))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .stroke(tintColor?.opacity(0.3) ?? Color.gray.opacity(0.3), lineWidth: 1)
                )
        }
    }
}

// Update GlassyCommentSummary with enhanced styling and TTS
struct GlassyCommentSummary: View {
    let summary: CommentSummary
    var onAskAISelection: ((String, String) -> Void)? = nil
    var onAskAIWebSelection: ((String, String) -> Void)? = nil
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
#endif

    private var displaySummaryText: String {
        cleanAndFormatCommentSummaryForDisplay(summary.summary)
    }
    
    var body: some View {
VStack(alignment: .leading, spacing: 14) {
            // Remove duplicate "Comment Summary" title since it's already shown in the main section
            HStack(spacing: 12) {
                Spacer()
                
                // Mac voice picker removed (avoids cross-scope state). TTS uses current system voice.
                
                // Cloud TTS button
                Button {
                    speakSummary()
                } label: {
                    Image(systemName: "speaker.wave.2")
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
                }
                .buttonStyle(LiquidGlassButtonStyle())
                .help("Stop speech")

                // Local TTS button
                Button {
                    speakSummaryLocally()
                } label: {
                    Image(systemName: "speaker.wave.2.circle")
                }
                .buttonStyle(LiquidGlassButtonStyle())
                .ttsActiveGlow(isSpeakingLocally, color: .green)
                .help("Read aloud (Local)")
                .disabled(isSynthesizingSpeech)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            
            Group {
                if onAskAISelection != nil || onAskAIWebSelection != nil {
                    SelectableText(
                        text: displaySummaryText,
                        onAskAI: onAskAISelection,
                        onAskAIWeb: onAskAIWebSelection,
                        textIsPrecleaned: true
                    )
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text(.init(displaySummaryText))
                        .font(.body)
                        .foregroundColor(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.vertical, 16)
            .padding(.horizontal, 20)
            
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
                UIPasteboard.general.string = displaySummaryText
                #elseif os(macOS)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(displaySummaryText, forType: .string)
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
        localTTSTask?.cancel()
        localTTSTask = nil
        KokoroTTSService.shared.cancelPlayback()
        audioPlayer?.stop()
        audioPlayer = nil
        localSpeechSynth?.stopSpeaking(at: .immediate)
        #elseif os(macOS)
        audioPlayer?.stop()
        audioPlayer = nil
        localSpeechSynth?.stopSpeaking()
        #endif
        nextAudioChunk = nil
        isSynthesizingSpeech = false
        isSpeakingLocally = false
    }

    private func playAudio(data: Data) {
        #if os(iOS)
        ensureBackgroundTTSReady()
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
        localTTSTask?.cancel()
        localTTSTask = nil
        KokoroTTSService.shared.cancelPlayback()
        audioPlayer?.stop()
        audioPlayer = nil
        localSpeechSynth?.stopSpeaking(at: .immediate)
        #elseif os(macOS)
        audioPlayer?.stop()
        audioPlayer = nil
        localSpeechSynth?.stopSpeaking()
        #endif
        nextAudioChunk = nil
        isSynthesizingSpeech = false
        isSpeakingLocally = false
    }

    private func speakSummaryLocally() {
        #if os(iOS)
        // Toggle off if already speaking
        if isSpeakingLocally {
            localTTSTask?.cancel()
            localTTSTask = nil
            KokoroTTSService.shared.cancelPlayback()
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
        localSpeechSynth?.stopSpeaking(at: .immediate)
        ensureBackgroundTTSReady()

        let localEngine = appState.summaryService.getLocalTTSEngine()
        if localEngine == .kokoro {
            guard KokoroTTSService.shared.isAvailable else {
                speechSynthesisError = "MLX TTS is not available. Add the MLXAudio package and model access."
                return
            }
            isSpeakingLocally = true
            isSynthesizingSpeech = false
            speechSynthesisError = nil
            let allowCaching = appState.summaryService.isKokoroPrecacheEnabled()
            startKokoroPlayback(
                text: summary.summary,
                voice: appState.summaryService.getKokoroVoice(),
                speed: appState.summaryService.getKokoroSpeed(),
                allowCaching: allowCaching,
                precacheEnabled: allowCaching,
                setAudioPlayer: { [self] player in audioPlayer = player },
                soundDelegate: soundDelegate,
                taskStore: &localTTSTask,
                onCompleted: {
                    self.isSpeakingLocally = false
                    self.localTTSTask = nil
                },
                onError: { message in
                    self.speechSynthesisError = message
                    self.isSpeakingLocally = false
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
        let override = UserDefaults.standard.string(forKey: "LocalTTS.Mac.SelectedVoiceID") ?? ""
        if !override.isEmpty { _ = setMacSpeechVoice(synth, identifier: override) }
        else if let voiceID = preferredMacVoiceIdentifier() { _ = setMacSpeechVoice(synth, identifier: voiceID) }
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
    var onAskAISelection: ((String, String) -> Void)? = nil
    var onAskAIWebSelection: ((String, String) -> Void)? = nil
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
#endif

    private var displaySummary: String {
        var value = summary
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return value }

        if !value.contains("\n\n") {
            let normalized = value
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let marked = normalized.replacingOccurrences(
                of: "([\\.\\!\\?])\\s+(?=[A-Z0-9])",
                with: "$1|||",
                options: .regularExpression
            )
            let sentences = marked
                .components(separatedBy: "|||")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            if sentences.count >= 2 {
                value = sentences.joined(separator: "\n\n")
            } else {
                value = normalized
            }
        }

        value = value.replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
        return value
    }
    
    var body: some View {
VStack(alignment: .leading) {
            HStack(spacing: 12) {
                Spacer()
                // Cloud TTS button
                Button {
                    speakSummary()
                } label: {
                    Image(systemName: "speaker.wave.2")
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
                }
                .buttonStyle(LiquidGlassButtonStyle())
                .help("Stop speech")

                // Local TTS button
                Button {
                    speakSummaryLocally()
                } label: {
                    Image(systemName: "speaker.wave.2.circle")
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
                        .padding(6)
                        .background(Color.gray.opacity(0.2))
                        .cornerRadius(8)
                }
                .buttonStyle(PlainButtonStyle())
                .help("Copy summary")
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            
            Group {
                if onAskAISelection != nil || onAskAIWebSelection != nil {
                    SelectableText(
                        text: displaySummary,
                        onAskAI: onAskAISelection,
                        onAskAIWeb: onAskAIWebSelection,
                        textIsPrecleaned: true
                    )
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text(.init(displaySummary))
                        .font(.body)
                        .foregroundColor(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.vertical, 16)
            .padding(.horizontal, 20)
            
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
        localSpeechSynth?.stopSpeaking()
        #endif
        nextAudioChunk = nil
        isSynthesizingSpeech = false
        isSpeakingLocally = false
    }

    private func playAudio(data: Data) {
        #if os(iOS)
        ensureBackgroundTTSReady()
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
        localTTSTask?.cancel()
        localTTSTask = nil
        KokoroTTSService.shared.cancelPlayback()
        audioPlayer?.stop()
        audioPlayer = nil
        localSpeechSynth?.stopSpeaking(at: .immediate)
        #elseif os(macOS)
        audioPlayer?.stop()
        audioPlayer = nil
        localSpeechSynth?.stopSpeaking()
        #endif
        nextAudioChunk = nil
        isSynthesizingSpeech = false
        isSpeakingLocally = false
    }

    private func speakSummaryLocally() {
        #if os(iOS)
        // Toggle off if already speaking
        if isSpeakingLocally {
            localTTSTask?.cancel()
            localTTSTask = nil
            KokoroTTSService.shared.cancelPlayback()
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
        localSpeechSynth?.stopSpeaking(at: .immediate)
        ensureBackgroundTTSReady()

        let localEngine = appState.summaryService.getLocalTTSEngine()
        if localEngine == .kokoro {
            guard KokoroTTSService.shared.isAvailable else {
                speechSynthesisError = "MLX TTS is not available. Add the MLXAudio package and model access."
                return
            }
            isSpeakingLocally = true
            isSynthesizingSpeech = false
            speechSynthesisError = nil
            let allowCaching = appState.summaryService.isKokoroPrecacheEnabled()
            startKokoroPlayback(
                text: summary,
                voice: appState.summaryService.getKokoroVoice(),
                speed: appState.summaryService.getKokoroSpeed(),
                allowCaching: allowCaching,
                precacheEnabled: allowCaching,
                setAudioPlayer: { [self] player in audioPlayer = player },
                soundDelegate: soundDelegate,
                taskStore: &localTTSTask,
                onCompleted: {
                    self.isSpeakingLocally = false
                    self.localTTSTask = nil
                },
                onError: { message in
                    self.speechSynthesisError = message
                    self.isSpeakingLocally = false
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
        if let override = UserDefaults.standard.string(forKey: "LocalTTS.Mac.SelectedVoiceID"), !override.isEmpty { _ = setMacSpeechVoice(synth, identifier: override) }
        else if let voiceID = preferredMacVoiceIdentifier() { _ = setMacSpeechVoice(synth, identifier: voiceID) }
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
                // Use animated image for GIFs
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
