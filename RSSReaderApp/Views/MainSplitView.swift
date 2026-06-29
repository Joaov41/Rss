import SwiftUI

struct MainSplitView: View {
    @EnvironmentObject var appState: AppState
    @State private var showSettings = false

    var body: some View {
        NavigationSplitView {
            // LEFT COLUMN: Sidebar
            SidebarView()
        } content: {
            // MIDDLE COLUMN: List of Articles
            ArticleListView()
        } detail: {
            // RIGHT COLUMN: Summaries
            SummaryColumnView()
                .environmentObject(appState)
        }
        .navigationSplitViewColumnWidth(min: 200, ideal: 250)
        .toolbar {
            #if os(iOS)
            ToolbarItem(placement: .navigationBarTrailing) {
                settingsButton
            }
            #else
            ToolbarItem(placement: .automatic) {
                settingsButton
            }
            #endif
        }
        .sheet(isPresented: $showSettings) {
            settingsSheetContent
        }
    }
}

private extension MainSplitView {
    var settingsButton: some View {
        Button {
            showSettings = true
        } label: {
            Image(systemName: "gear")
        }
    }

    @ViewBuilder
    var settingsSheetContent: some View {
        #if os(iOS)
        NavigationView {
            SettingsView()
                .environmentObject(appState)
                .navigationTitle("Settings")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") { showSettings = false }
                    }
                }
        }
        .presentationDetents([.large])
        .presentationCornerRadius(40)
        .presentationBackground(.ultraThinMaterial)
        .presentationBackgroundInteraction(.enabled)
        #else
        SettingsView()
            .environmentObject(appState)
            .frame(minWidth: 760, idealWidth: 860, minHeight: 640, idealHeight: 760)
        #endif
    }
}

struct MainSplitView_Previews: PreviewProvider {
    static var previews: some View {
        MainSplitView()
            .environmentObject(AppState())
    }
}

// Minimal SidebarView definition
struct SidebarView: View {
    @EnvironmentObject var appState: AppState
    
    var body: some View {
        List {
            NavigationLink(destination: ContentView()) {
                Text("Home")
            }
            // You can add more sidebar items here if needed.
        }
        .navigationTitle("Sidebar")
    }
}

// Minimal ArticleListView definition
struct ArticleListView: View {
    @EnvironmentObject var appState: AppState
    
    var sortedArticles: [Article] {
        appState.feeds.flatMap { $0.articles }
            .sorted(by: { $0.publishDate > $1.publishDate })
    }
    
    var body: some View {
        List {
            ForEach(sortedArticles) { article in
                NavigationLink(destination: ArticleDetailView()) {
                    Text(article.title)
                        .contentShape(Rectangle())
                }
                .simultaneousGesture(TapGesture().onEnded {
                    // Set article data on tap
                    appState.selectedArticle = article
                    appState.selectedArticleId = article.id
                })
            }
        }
        .navigationTitle("Articles")
    }
}
