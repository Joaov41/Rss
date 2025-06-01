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
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "gear")
                }
            }
        }
        .sheet(isPresented: $showSettings) {
            NavigationView {
                SettingsView()
                    .environmentObject(appState)
                    .navigationBarTitle("Settings", displayMode: .inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Close") { showSettings = false }
                        }
                    }
            }
        }
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
    
    var body: some View {
        List {
            ForEach(appState.feeds.flatMap { $0.articles }
                .sorted(by: { $0.publishDate > $1.publishDate })) { article in
                    NavigationLink(destination: ArticleDetailView()) {
                        Text(article.title)
                            .contentShape(Rectangle())
                    }
                    .simultaneousGesture(TapGesture().onEnded {
                        // Set article data on tap
                        DispatchQueue.main.async {
                            appState.selectedArticle = article
                            appState.selectedArticleId = article.id
                        }
                    })
                }
        }
        .navigationTitle("Articles")
    }
}
