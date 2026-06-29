# Apple Intelligence Implementation Guide

## Overview

This guide details the implementation of Apple Intelligence (both local and cloud models) in a SwiftUI RSS Reader app. The implementation provides a robust system with automatic fallback mechanisms, comprehensive error handling, and support for multiple AI providers.

## Table of Contents

1. [Architecture Overview](#architecture-overview)
2. [Local Model Implementation](#local-model-implementation)
3. [Cloud Model Implementation](#cloud-model-implementation)
4. [Provider Selection System](#provider-selection-system)
5. [Fallback Mechanism](#fallback-mechanism)
6. [Clipboard Monitoring System](#clipboard-monitoring-system)
7. [UI Integration](#ui-integration)
8. [Code Examples](#code-examples)
9. [Error Handling](#error-handling)
10. [Best Practices](#best-practices)

## Architecture Overview

The system implements three AI providers:
- **Apple Local** (iOS 18.2+): On-device Apple Intelligence using `LanguageModelSession`
- **Apple Cloud**: Cloud-based Apple Intelligence via Shortcuts app with x-callback-url
- **Gemini**: Google's Gemini API as fallback/alternative

### Core Components

```swift
// Provider Selection Enum
enum SummaryProvider: String, CaseIterable {
    case gemini = "Gemini"
    case appleLocal = "Apple Local"
    case appleCloud = "Apple Cloud"
    
    var displayName: String {
        switch self {
        case .gemini: return "Gemini API"
        case .appleLocal: return "Apple Intelligence (Local)"
        case .appleCloud: return "Apple Intelligence (Cloud)"
        }
    }
}

// Request Type Classification
enum AppleIntelligenceRequestType {
    case summary
    case articleQA
    case redditQA
    case commentSummary
}
```

## Local Model Implementation

### LocalSummaryService

The local model uses Apple's on-device Language Model Session available in iOS 18.2+:

```swift
@available(iOS 18.2, macOS 15.2, *)
class LocalSummaryService {
    
    // Check if Apple Intelligence is available on this device
    static func isAvailable() -> Bool {
        // Check if FoundationModels is available
        // This will return true on compatible devices with iOS 18.2+
        return true
    }
    
    // Summarize text using on-device model
    static func summarizeText(_ text: String, completion: @escaping (Result<String, Error>) -> Void) {
        Task {
            do {
                let session = LanguageModelSession()
                let prompt = "Provide a one-paragraph summary (4-6 sentences) of the following text:\n\n\(text)"
                let response = try await session.respond(to: prompt)
                
                DispatchQueue.main.async {
                    completion(.success(response.content))
                }
            } catch {
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
            }
        }
    }
    
    // Ask question about text using on-device model
    static func askQuestion(about text: String, question: String, completion: @escaping (Result<String, Error>) -> Void) {
        Task {
            do {
                let session = LanguageModelSession()
                let prompt = """
                Based on the following text, please answer this question:
                
                Question: \(question)
                
                Text:
                \(text)
                
                If the answer cannot be determined from the text, please state that the information is not available.
                """
                
                let response = try await session.respond(to: prompt)
                
                DispatchQueue.main.async {
                    completion(.success(response.content))
                }
            } catch {
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
            }
        }
    }
}
```

### Local Model Usage Pattern

```swift
private func performLocalWithGeminiFallback(
    prompt: String,
    taskName: String,
    completion: @escaping (String) -> Void
) {
    if #available(iOS 18.2, *), LocalSummaryService.isAvailable() {
        print("📱 AppState: Trying local model for \(taskName)")
        LocalSummaryService.summarizeText(prompt) { [weak self] result in
            guard let self = self else { return }
            
            switch result {
            case .success(let response):
                print("✅ AppState: Local model succeeded for \(taskName)")
                completion(response)
            case .failure(let error):
                print("⚠️ AppState: Local model failed for \(taskName): \(error.localizedDescription)")
                
                // Show user notification about fallback
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    self.fallbackNotification = "Local AI failed. Switching to Gemini for \(taskName.lowercased())..."
                    self.showFallbackNotification = true
                    
                    DispatchQueue.main.asyncAfter(deadline: .now() + 6.0) { [weak self] in
                        self?.showFallbackNotification = false
                    }
                }
                
                // Check if it's a context-related error and fallback to Gemini
                if self.isContextError(error) {
                    print("🔄 AppState: Context error detected, falling back to Gemini for \(taskName)")
                    self.performGeminiFallback(prompt: prompt, taskName: taskName, completion: completion)
                } else {
                    print("❌ AppState: Non-context error, still falling back: \(error.localizedDescription)")
                    self.performGeminiFallback(prompt: prompt, taskName: taskName, completion: completion)
                }
            }
        }
    } else {
        print("⚠️ AppState: Local model not available, using Gemini for \(taskName)")
        
        // Show notification when local AI isn't available
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.fallbackNotification = "Local AI unavailable. Using Gemini for \(taskName.lowercased())..."
            self.showFallbackNotification = true
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 6.0) { [weak self] in
                self?.showFallbackNotification = false
            }
        }
        
        performGeminiFallback(prompt: prompt, taskName: taskName, completion: completion)
    }
}
```

## Cloud Model Implementation

### Shortcuts Integration with x-callback-url

The cloud model uses the Shortcuts app with x-callback-url to prevent app switching:

```swift
func launchCloudRequest(for text: String, type: AppleIntelligenceRequestType, completion: ((String) -> Void)?) {
    // Store the request type and completion handler
    self.currentRequestType = type
    self.currentRequestCompletion = completion
    
    // Start monitoring clipboard for result
    self.startClipboardMonitoring(for: type)
    
    // Use x-callback-url scheme to run shortcut without opening Shortcuts app
    let callbackURL = "shortcuts://x-callback-url/run-shortcut"
    var components = URLComponents(string: callbackURL)!
    
    components.queryItems = [
        URLQueryItem(name: "name", value: "RSS Reader Cloud Summary"),
        URLQueryItem(name: "input", value: "text"),
        URLQueryItem(name: "text", value: text),
        URLQueryItem(name: "x-source", value: "RSS Reader"),
        URLQueryItem(name: "x-success", value: "rssreader://success"),
        URLQueryItem(name: "x-error", value: "rssreader://error")
    ]
    
    guard let url = components.url else {
        print("⚠️ AppState: Could not create x-callback URL")
        fallbackToRegularURL(text: text, type: type)
        return
    }
    
    print("📱 AppState: Using x-callback-url to run shortcut without opening app")
    print("📱 AppState: Text length: \(text.count) characters")
    
    #if os(iOS)
    UIApplication.shared.open(url, options: [:]) { success in
        if success {
            print("✅ AppState: Successfully launched shortcut via x-callback-url")
        } else {
            print("⚠️ AppState: x-callback-url failed, falling back to regular URL")
            self.fallbackToRegularURL(text: text, type: type)
        }
    }
    #elseif os(macOS)
    NSWorkspace.shared.open(url)
    print("✅ AppState: Launched shortcut via x-callback-url on macOS")
    #endif
}
```

### Content Preparation for Cloud Processing

```swift
private func launchCloudSummaryForContent(article: Article? = nil, redditPost: RedditPost? = nil) {
    var content = ""
    if let article = article {
        // Strip HTML tags from article content for cleaner text
        let htmlContent = article.content ?? ""
        let cleanedContent = htmlContent
            .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Add prompt for paragraph-length summary
        let prompt = "Provide a one-paragraph summary (4-6 sentences) of this article's main points:\n\n"
        
        // Limit content length to avoid URL limits (around 10k chars)
        let maxLength = 10000
        let truncatedContent = cleanedContent.count > maxLength ? 
            String(cleanedContent.prefix(maxLength)) + "..." : cleanedContent
        
        content = cleanedContent.isEmpty ? article.title : (prompt + truncatedContent)
    } else if let post = redditPost {
        let prompt = "Provide a one-paragraph summary (4-6 sentences) of this Reddit post:\n\n"
        let maxLength = 10000
        let truncatedContent = post.content.count > maxLength ? 
            String(post.content.prefix(maxLength)) + "..." : post.content
        content = prompt + truncatedContent
    }
    
    print("📱 AppState: Launching Shortcuts for \(settings.selectedSummaryProvider.rawValue)")
    print("📱 AppState: Content length: \(content.count) characters")
    launchCloudSummary(for: content)
}
```

## Clipboard Monitoring System

The cloud model uses a sophisticated clipboard monitoring system to capture responses:

```swift
private func startClipboardMonitoring(for type: AppleIntelligenceRequestType = .summary) {
    // Cancel any existing timer
    clipboardTimer?.invalidate()
    clipboardCheckCount = 0
    
    // Store the original clipboard content
    #if os(iOS)
    let originalClipboard = UIPasteboard.general.string ?? ""
    #elseif os(macOS)
    let originalClipboard = NSPasteboard.general.string(forType: .string) ?? ""
    #endif
    
    print("📋 Starting clipboard monitoring for Apple Intelligence response (\(type))...")
    
    // Set waiting state based on request type
    DispatchQueue.main.async {
        switch type {
        case .summary:
            self.isWaitingForAppleIntelligence = true
            self.appleIntelligenceWaitProgress = "Waiting for Apple Intelligence... (0/\(self.maxClipboardChecks * 5)s)"
        case .articleQA:
            self.isWaitingForArticleQA = true
            self.articleQAWaitProgress = "Waiting for answer... (0/\(self.maxClipboardChecks * 5)s)"
        case .redditQA:
            self.isWaitingForRedditQA = true
            self.redditQAWaitProgress = "Waiting for answer... (0/\(self.maxClipboardChecks * 5)s)"
        case .commentSummary:
            self.isWaitingForCommentSummary = true
            self.commentSummaryWaitProgress = "Waiting for comment summary... (0/\(self.maxClipboardChecks * 5)s)"
        }
    }
    
    // Check clipboard every 5 seconds, up to 2 minutes
    clipboardTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] timer in
        guard let self = self else {
            timer.invalidate()
            return
        }
        
        self.clipboardCheckCount += 1
        let elapsedTime = self.clipboardCheckCount * 5
        let totalTime = self.maxClipboardChecks * 5
        
        #if os(iOS)
        let currentClipboard = UIPasteboard.general.string ?? ""
        #elseif os(macOS)
        let currentClipboard = NSPasteboard.general.string(forType: .string) ?? ""
        #endif
        
        print("📋 Checking clipboard for \(type)... (attempt \(self.clipboardCheckCount)/\(self.maxClipboardChecks))")
        
        // Update progress based on request type
        DispatchQueue.main.async {
            switch type {
            case .summary:
                self.appleIntelligenceWaitProgress = "Waiting for Apple Intelligence... (\(elapsedTime)/\(totalTime)s)"
            case .articleQA:
                self.articleQAWaitProgress = "Waiting for answer... (\(elapsedTime)/\(totalTime)s)"
            case .redditQA:
                self.redditQAWaitProgress = "Waiting for answer... (\(elapsedTime)/\(totalTime)s)"
            case .commentSummary:
                self.commentSummaryWaitProgress = "Waiting for comment summary... (\(elapsedTime)/\(totalTime)s)"
            }
        }
        
        // If clipboard changed and contains meaningful content
        if currentClipboard != originalClipboard && !currentClipboard.isEmpty && currentClipboard.count > 10 {
            print("✅ Found \(type) response in clipboard after \(elapsedTime) seconds!")
            
            // Handle the response based on request type
            DispatchQueue.main.async {
                self.clearWaitingState(for: type)
                
                switch type {
                case .summary:
                    if let article = self.selectedArticle {
                        self.updateArticleSummaryFromCloud(article, summary: currentClipboard)
                    } else if let post = self.selectedRedditPost {
                        self.updateRedditPostSummaryFromCloud(post, summary: currentClipboard)
                    }
                case .articleQA, .redditQA, .commentSummary:
                    self.currentRequestCompletion?(currentClipboard)
                }
            }
            
            // Stop monitoring
            timer.invalidate()
            self.clipboardTimer = nil
            return
        }
        
        // Check if we've exceeded the maximum attempts
        if self.clipboardCheckCount >= self.maxClipboardChecks {
            print("⏱️ Clipboard monitoring timed out after \(totalTime) seconds for \(type)")
            
            DispatchQueue.main.async {
                self.clearWaitingState(for: type)
                
                let timeoutMessage = "Apple Intelligence processing took longer than expected. Please check your clipboard manually or try again."
                
                switch type {
                case .summary:
                    if let article = self.selectedArticle {
                        self.updateArticleSummaryFromCloud(article, summary: timeoutMessage)
                    } else if let post = self.selectedRedditPost {
                        self.updateRedditPostSummaryFromCloud(post, summary: timeoutMessage)
                    }
                case .articleQA, .redditQA, .commentSummary:
                    self.currentRequestCompletion?(timeoutMessage)
                }
            }
            
            timer.invalidate()
            self.clipboardTimer = nil
        }
    }
}
```

## Provider Selection System

### Unified Request Handler

```swift
func requestSummary(for article: Article? = nil, redditPost: RedditPost? = nil) {
    // Only use Gemini if it's selected
    if settings.selectedSummaryProvider == .gemini {
        if let article = article {
            summarizeArticle(article)
        } else if let post = redditPost {
            summarizeRedditPost(post)
        }
    } else if settings.selectedSummaryProvider == .appleLocal {
        // Use on-device AI with Gemini fallback
        var textToSummarize = ""
        if let article = article {
            // Clean HTML for local processing
            let htmlContent = article.content ?? ""
            textToSummarize = htmlContent
                .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
                .replacingOccurrences(of: "&nbsp;", with: " ")
                .replacingOccurrences(of: "&quot;", with: "\"")
                .replacingOccurrences(of: "&amp;", with: "&")
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } else if let post = redditPost {
            textToSummarize = post.content
        }
        
        let prompt = "Provide a one-paragraph summary (4-6 sentences) of the following text:\n\n\(textToSummarize)"
        let taskName = article != nil ? "Article Summary" : "Reddit Post Summary"
        
        performLocalWithGeminiFallback(prompt: prompt, taskName: taskName, completion: { [weak self] summary in
            if let article = article {
                self?.updateArticleSummaryFromCloud(article, summary: summary)
            } else if let post = redditPost {
                self?.updateRedditPostSummaryFromCloud(post, summary: summary)
            }
        })
    } else {
        // Apple Cloud
        launchCloudSummaryForContent(article: article, redditPost: redditPost)
    }
}
```

### Q&A Implementation

```swift
func askQuestionAboutArticle(article: Article, question: String, completion: @escaping (String) -> Void) {
    print("📱 AppState: Processing question about article: \"\(question)\"")
    
    // Check if we should use Apple Intelligence instead
    if settings.selectedSummaryProvider == .appleLocal {
        // Use on-device AI for Q&A with Gemini fallback
        let content = article.content ?? article.title
        let prompt = """
        Article Title: \(article.title)
        Article Content:
        \(content)
        
        Based solely on the information in the article above, please answer the following question:
        \(question)
        
        If the answer cannot be determined from the article, please state that the information is not available in the article.
        """
        
        performLocalWithGeminiFallback(prompt: prompt, taskName: "Article Q&A", completion: completion)
        return
    } else if settings.selectedSummaryProvider == .appleCloud {
        // Use Apple Cloud via Shortcuts
        let prompt = """
        Article Title: \(article.title)
        Article Content:
        \(article.content)
        
        Based solely on the information in the article above, please answer the following question:
        \(question)
        
        If the answer cannot be determined from the article, please state that the information is not available in the article.
        """
        
        print("📱 AppState: Using Apple Cloud for Article Q&A")
        launchCloudRequest(for: prompt, type: .articleQA, completion: completion)
        return
    }
    
    // Fallback to Gemini if neither Apple Intelligence option is selected
    // ... Gemini implementation
}
```

## UI Integration

### Progress Indicators

```swift
// In SwiftUI Views - Show different states based on provider
if appState.isLoading {
    ProgressView("Generating summary...")
        .padding()
} else if appState.isWaitingForAppleIntelligence {
    VStack(spacing: 8) {
        ProgressView()
        Text(appState.appleIntelligenceWaitProgress)
            .foregroundColor(.secondary)
            .font(.caption)
    }
    .frame(maxWidth: .infinity)
    .padding()
} else if let summary = article.summary, !summary.isEmpty {
    // Show summary content
    VStack(alignment: .leading) {
        if appState.isSummaryFromCloud {
            HStack {
                Image(systemName: "cloud.fill")
                    .foregroundColor(.blue)
                Text("Generated by Apple Intelligence")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal)
            .padding(.top, 8)
        }
        
        ScrollView {
            Text(summary)
                .padding()
                .textSelection(.enabled)
        }
    }
}
```

### Fallback Notifications

```swift
// Fallback notification overlay
.overlay(
    VStack {
        Spacer()
        if appState.showFallbackNotification {
            HStack {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .foregroundColor(.orange)
                    .font(.subheadline)
                Text(appState.fallbackNotification)
                    .font(.subheadline)
                    .foregroundColor(.primary)
                    .multilineTextAlignment(.leading)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.regularMaterial)
            .cornerRadius(12)
            .shadow(color: .black.opacity(0.3), radius: 12, x: 0, y: 6)
            .padding(.horizontal, 20)
            .padding(.bottom, 100)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .animation(.spring(response: 0.6, dampingFraction: 0.8), value: appState.showFallbackNotification)
        }
    }
)
.zIndex(1000)
```

## Error Handling

### Context Error Detection

```swift
private func isContextError(_ error: Error) -> Bool {
    let errorMessage = error.localizedDescription.lowercased()
    
    // Common context/length related errors from Apple Intelligence
    let contextKeywords = [
        "context", "token", "length", "limit", "exceeded",
        "too long", "too large", "maximum", "size",
        "input too large", "content too long", "text too long",
        "request too large", "payload too large", "truncated",
        "buffer", "capacity", "overflow", "quota"
    ]
    
    for keyword in contextKeywords {
        if errorMessage.contains(keyword) {
            return true
        }
    }
    
    // Check error codes that typically indicate context limits
    if let nsError = error as? NSError {
        let contextErrorCodes = [413, 422, 400, 431]
        if contextErrorCodes.contains(nsError.code) {
            return true
        }
    }
    
    return false
}
```

### URL Callback Handling

```swift
private func handleURLCallback(_ url: URL) {
    print("🔗 Received URL callback: \(url.absoluteString)")
    
    // Handle success callback from x-callback-url
    if url.scheme == "rssreader" && url.host == "success" {
        print("✅ Shortcut executed successfully via x-callback-url")
        return
    }
    
    // Handle error callback from x-callback-url
    if url.scheme == "rssreader" && url.host == "error" {
        print("❌ Shortcut execution failed via x-callback-url")
        if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let queryItems = components.queryItems {
            
            if let errorMessage = queryItems.first(where: { $0.name == "errorMessage" })?.value {
                print("❌ Error details: \(errorMessage)")
            }
        }
        return
    }
    
    // Handle the callback from Shortcuts (legacy)
    if url.scheme == "rssreader" && url.host == "summary" {
        // ... existing callback handling
    }
}
```

## Best Practices

### 1. **Always Provide Fallbacks**
- Local model should fallback to Gemini on context errors
- Cloud model should have timeout handling
- Provide clear user feedback during transitions

### 2. **Content Preprocessing**
- Clean HTML tags for better processing
- Limit content length to avoid URL/context limits
- Provide meaningful prompts for better results

### 3. **User Experience**
- Use x-callback-url to prevent app switching
- Show progress indicators with time estimates
- Provide clear notifications about provider switches

### 4. **Error Handling**
- Detect context-related errors specifically
- Provide helpful error messages to users
- Log detailed information for debugging

### 5. **Performance Optimization**
- Cache responses when possible
- Use appropriate timeouts for different operations
- Limit recursive comment extraction for performance

### 6. **Privacy Considerations**
- Clearly indicate when data goes to cloud vs local processing
- Allow users to choose their preferred provider
- Respect user preferences for private vs cloud processing

## Implementation Checklist

- [ ] Add iOS 18.2+ availability checks
- [ ] Implement LocalSummaryService with LanguageModelSession
- [ ] Set up x-callback-url scheme for cloud processing
- [ ] Implement clipboard monitoring system
- [ ] Add fallback mechanisms between providers
- [ ] Create context error detection system
- [ ] Add progress indicators for all states
- [ ] Implement user notifications for fallbacks
- [ ] Add URL scheme handling for callbacks
- [ ] Test on compatible devices
- [ ] Add appropriate error handling
- [ ] Implement content preprocessing
- [ ] Add provider selection UI
- [ ] Test fallback scenarios
- [ ] Optimize for performance and user experience

This implementation provides a robust, user-friendly system for leveraging Apple Intelligence while maintaining compatibility and providing reliable fallbacks. 