import SwiftUI
import Combine

@main
struct RSSReaderApp: App {
    @StateObject private var appState = AppState()
    
    var body: some Scene {
        #if os(macOS)
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .frame(minWidth: 1000, minHeight: 600)
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
                        appState.summarizeArticle(article)
                    } else if let post = appState.selectedRedditPost {
                        appState.summarizeRedditPost(post)
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
            } else {
                iPhoneContentView()
                    .environmentObject(appState)
            }
        }
        #endif
    }
}
