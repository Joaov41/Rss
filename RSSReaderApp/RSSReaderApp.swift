import SwiftUI
import Combine

@main
struct RSSReaderApp: App {
    @StateObject private var appState: AppState
    @AppStorage("appearanceMode") private var appearanceMode: Int = 0 // 0: System, 1: Light, 2: Dark
    
    init() {
        print("🚀🚀🚀 APP STARTUP - DIAGNOSTIC BUILD v1 🚀🚀🚀")
        _appState = StateObject(wrappedValue: AppState())
        #if os(iOS)
        // Initialize background task manager for long-running Gemini operations
        // This enables summaries and Q&A to complete even when device is locked
        GeminiBackgroundTaskManager.shared.prepareForLaunch()
        print("✅ RSSReaderApp: Background task manager initialized (supports locked device execution)")
        #endif
    }
    
    var colorScheme: ColorScheme? {
        switch appearanceMode {
        case 1: return .light
        case 2: return .dark
        default: return nil // System default
        }
    }
    
    var body: some Scene {
        #if os(macOS)
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .frame(minWidth: 1000, minHeight: 600)
                .preferredColorScheme(colorScheme)
                .modifier(WebAIHandoffFloatingPanelModifier(appState: appState))
                .onOpenURL { url in
                    handleURLCallback(url)
                }
        }
        .commands {
            CommandGroup(after: .appSettings) {
                Button("Preferences...") {
                    NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
                }
                .keyboardShortcut(",", modifiers: .command)
            }
            
            CommandMenu("Feed") {
                Button("Add Subscription...") {
                    NotificationCenter.default.post(name: Notification.Name("ShowAddSubscription"), object: nil)
                }
                .keyboardShortcut("n", modifiers: .command)
                
                Button("Refresh All") {
                    appState.refreshAllFeeds()
                }
                .keyboardShortcut("r", modifiers: .command)
            }
            
            CommandMenu("Article") {
                Button("Mark as Read") {
                    if let article = appState.selectedArticle {
                        appState.markArticleAsRead(article)
                    } else if let post = appState.selectedRedditPost {
                        appState.markRedditPostAsRead(post)
                    }
                }
                .keyboardShortcut("m", modifiers: .command)
                
                Button("Toggle Favorite") {
                    if let article = appState.selectedArticle {
                        appState.toggleArticleFavorite(article)
                    } else if let post = appState.selectedRedditPost {
                        appState.toggleRedditPostFavorite(post)
                    }
                }
                .keyboardShortcut("f", modifiers: .command)
                
                Button("Summarize") {
                    if let article = appState.selectedArticle {
                        appState.requestSummary(for: article)
                    } else if let post = appState.selectedRedditPost {
                        appState.requestSummary(for: nil, redditPost: post)
                    }
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])
            }
        }
        #else
        WindowGroup {
            if UIDevice.current.userInterfaceIdiom == .pad {
                iPadContentView()
                    .environmentObject(appState)
                    .preferredColorScheme(colorScheme)
                    .modifier(WebAIHandoffIOSPresenterModifier(appState: appState))
                    .onOpenURL { url in
                        handleURLCallback(url)
                    }
            } else {
                iPhoneContentView()
                    .environmentObject(appState)
                    .preferredColorScheme(colorScheme)
                    .modifier(WebAIHandoffIOSPresenterModifier(appState: appState))
                    .onOpenURL { url in
                        handleURLCallback(url)
                    }
            }
        }
        #endif
    }
    
    private func handleURLCallback(_ url: URL) {
        print("🔗 Received URL callback: \(url.absoluteString)")
        
        // Handle success callback from x-callback-url
        if url.scheme == "rssreader" && url.host == "success" {
            print("✅ Shortcut executed successfully via x-callback-url")
            
            // Extract result from URL if present (mirrors red sample approach)
            var userInfo: [String: Any] = [:]
            if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
               let queryItems = components.queryItems,
               let resultValue = queryItems.first(where: { $0.name == "result" })?.value {
                var decodedResult = resultValue.removingPercentEncoding ?? resultValue
                if decodedResult.hasPrefix("rssreader://success?result=") {
                    decodedResult = String(decodedResult.dropFirst("rssreader://success?result=".count))
                }
                print("📝 Shortcut callback returned result: \(decodedResult.prefix(100))...")
                userInfo["result"] = decodedResult
            }
            
            NotificationCenter.default.post(
                name: Notification.Name("ShortcutCallbackReceived"),
                object: nil,
                userInfo: userInfo.isEmpty ? nil : userInfo
            )
            return
        }
        
        // Handle error callback from x-callback-url
        if url.scheme == "rssreader" && url.host == "error" {
            print("❌ Shortcut execution failed via x-callback-url")
            // Parse error details if available
            var userInfo: [String: Any] = ["error": true]
            if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
               let queryItems = components.queryItems {
                
                if let errorMessage = queryItems.first(where: { $0.name == "errorMessage" })?.value {
                    let decodedMessage = errorMessage.removingPercentEncoding ?? errorMessage
                    print("❌ Error details: \(decodedMessage)")
                    userInfo["message"] = decodedMessage
                }
            }
            NotificationCenter.default.post(name: Notification.Name("ShortcutCallbackReceived"), object: nil, userInfo: userInfo)
            return
        }
        
        // Handle the callback from Shortcuts
        if url.scheme == "rssreader" && url.host == "summary" {
            // Parse the query parameters
            if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
               let queryItems = components.queryItems {
                
                print("🔗 Query items: \(queryItems)")
                
                if let summaryText = queryItems.first(where: { $0.name == "text" })?.value {
                    print("📝 Received summary text: \(summaryText.prefix(100))...")
                    
                    // Decode any URL encoding
                    let decodedSummary = summaryText.removingPercentEncoding ?? summaryText
                    
                    // Update the summary in AppState
                    DispatchQueue.main.async {
                        // Update the currently selected article with the cloud summary
                        if let article = appState.selectedArticle {
                            appState.updateArticleSummaryFromCloud(article, summary: decodedSummary)
                        } else if let post = appState.selectedRedditPost {
                            appState.updateRedditPostSummaryFromCloud(post, summary: decodedSummary)
                        }
                    }
                } else {
                    print("⚠️ No 'text' parameter found in callback URL")
                }
            }
        }
    }
}
