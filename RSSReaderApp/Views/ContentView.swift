import SwiftUI
import WebKit
import Combine
import SwiftSoup // <-- Add SwiftSoup import

// Add this class at the top of the file, before ContentView
class ArticleQAState: ObservableObject {
    @Published var showQAInterface = false
    @Published var questionText = ""
    @Published var answerText = "Ask a question about this article..."
    @Published var isProcessingQuestion = false
    @Published var previousQuestionText: String? = nil

    static let shared = ArticleQAState()

    func resetState() {
        showQAInterface = false
        questionText = ""
        answerText = "Ask a question about this article..."
        isProcessingQuestion = false
        previousQuestionText = nil
    }

    func toggleQAInterface() {
        showQAInterface.toggle()
    }
}

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    
    // Existing properties
    @State private var showAddSubscription = false
    @State private var selectedCategory: FeedCategory = .all
    @State private var showSettings = false
    
    
    var body: some View {
        // FIX: Use a stack-based navigation approach instead
        ZStack {
            // Background color
            Color.black.edgesIgnoringSafeArea(.all)
            
            // Main content
            if let post = appState.selectedRedditPost {
                // Show Reddit post detail when selected
                RedditDetailView()
                    .transition(.move(edge: .trailing))
                    .zIndex(1) // Keep on top
            } else if let article = appState.selectedArticle {
                // Show article detail when selected
                ArticleDetailView()
                    .transition(.move(edge: .trailing))
                    .zIndex(1) // Keep on top
            } else {
                // Regular navigation
                NavigationView {
                    #if os(macOS)
                    sidebar
                    // Restore the appropriate view based on what was active
                    restoreNavigationState()
                    detailView
                    #else
                    sidebar
                    // Restore the appropriate view based on what was active
                    restoreNavigationState()
                    #endif
                }
                .navigationViewStyle(DoubleColumnNavigationViewStyle())
                .zIndex(0)
            }
        }
        // Add a navigation bar overlay when in detail view
        .overlay(
            VStack {
                if appState.selectedRedditPost != nil || appState.selectedArticle != nil {
                    HStack {
                        // Back button - Use the new navigateBack function
                        Button(action: { 
                            // Use the navigation function to go back
                            appState.navigateBack()
                        }) {
                            HStack {
                                Image(systemName: "chevron.left")
                                Text("Back")
                            }
                            .padding(8)
                            .background(Color.black.opacity(0.7))
                            .cornerRadius(8)
                        }
                        
                        Spacer()
                        
                        // Action buttons
                        HStack(spacing: 12) {
                            // Summary button - conditionally show based on what's selected
                            if let article = appState.selectedArticle {
                                Button(action: {
                                    appState.summarizeArticle(article)
                                }) {
                                    Image(systemName: "text.quote")
                                        .padding(8)
                                        .background(Color.black.opacity(0.7))
                                        .cornerRadius(8)
                                }
                                
                                // "Ask AI" button removed from navigation bar overlay
                            } else if let post = appState.selectedRedditPost {
                                Button(action: {
                                    appState.summarizeRedditPost(post)
                                }) {
                                    Image(systemName: "text.quote")
                                        .padding(8)
                                        .background(Color.black.opacity(0.7))
                                        .cornerRadius(8)
                                }
                            }
                            
                            // Favorite button - conditionally show based on what's selected
                            if let article = appState.selectedArticle {
                                Button(action: {
                                    appState.toggleArticleFavorite(article)
                                }) {
                                    Image(systemName: article.isFavorite ? "star.fill" : "star")
                                        .foregroundColor(article.isFavorite ? .yellow : .white)
                                        .padding(8)
                                        .background(Color.black.opacity(0.7))
                                        .cornerRadius(8)
                                }
                            } else if let post = appState.selectedRedditPost {
                                Button(action: {
                                    appState.toggleRedditPostFavorite(post)
                                }) {
                                    Image(systemName: post.isFavorite ? "star.fill" : "star")
                                        .foregroundColor(post.isFavorite ? .yellow : .white)
                                        .padding(8)
                                        .background(Color.black.opacity(0.7))
                                        .cornerRadius(8)
                                }
                            }
                        }
                    }
                    .padding()
                    Spacer()
                }
            }
        )
        // Sheet for adding subscription
        .sheet(isPresented: $showAddSubscription) {
            AddSubscriptionView()
                .environmentObject(appState)
        }
        // Sheet for Settings
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .environmentObject(appState)
        }
        .onAppear {
            NotificationCenter.default.addObserver(
                forName: Notification.Name("ShowAddSubscription"),
                object: nil,
                queue: .main
            ) { _ in
                showAddSubscription = true
            }
        }
        .preferredColorScheme(.dark) // Force app to use dark mode
        .gesture(
            DragGesture()
                .onEnded { gesture in
                    // If swipe from left edge (within 50 points from left) to right
                    if gesture.startLocation.x < 50 && gesture.translation.width > 100 {
                        // Call your existing back navigation function
                        appState.navigateBack()
                    }
                }
        )
    }
    
    // MARK: - Sidebar
    var sidebar: some View {
        List {
            Section(header: Text("Feeds")) {
                NavigationLink(destination: redditView) {
                    Label {
                        Text(FeedCategory.reddit.rawValue)
                    } icon: {
                        Image("RedditLogo")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 20, height: 20)
                            .foregroundColor(.orange)
                    }
                }
                .simultaneousGesture(TapGesture().onEnded { 
                    selectedCategory = .reddit 
                    appState.lastSelectedCategory = .reddit
                    appState.activeSubscriptionURL = nil
                })
                
                NavigationLink(destination: allView) {
                    Label(FeedCategory.all.rawValue, systemImage: FeedCategory.all.systemImageName)
                }
                .simultaneousGesture(TapGesture().onEnded { 
                    selectedCategory = .all 
                    appState.lastSelectedCategory = .all
                    appState.activeSubscriptionURL = nil
                })
                
                NavigationLink(destination: unreadView) {
                    Label(FeedCategory.unread.rawValue, systemImage: FeedCategory.unread.systemImageName)
                }
                .simultaneousGesture(TapGesture().onEnded { 
                    selectedCategory = .unread 
                    appState.lastSelectedCategory = .unread
                    appState.activeSubscriptionURL = nil
                })
                
                NavigationLink(destination: favoritesView) {
                    Label(FeedCategory.favorites.rawValue, systemImage: FeedCategory.favorites.systemImageName)
                }
                .simultaneousGesture(TapGesture().onEnded { 
                    selectedCategory = .favorites 
                    appState.lastSelectedCategory = .favorites
                    appState.activeSubscriptionURL = nil
                })
                
                NavigationLink(destination: todayView) {
                    Label(FeedCategory.today.rawValue, systemImage: FeedCategory.today.systemImageName)
                }
                .simultaneousGesture(TapGesture().onEnded { 
                    selectedCategory = .today 
                    appState.lastSelectedCategory = .today
                    appState.activeSubscriptionURL = nil
                })
                
                Divider()
                
                Button(action: { showSettings = true }) {
                    Label("Settings", systemImage: "gearshape.fill")
                }
            }
            
            Section(header: Text("Subscriptions")) {
                ForEach(appState.subscriptions) { subscription in
                    NavigationLink(destination: subscriptionView(for: subscription)) {
                        if subscription.type == .rss {
                            // Use favicon for RSS subscriptions
                            Label {
                                Text(subscription.title)
                            } icon: {
                                if let url = URL(string: subscription.url), let host = url.host {
                                    DomainIconView(domain: host, size: 16)
                                } else {
                                    Image(systemName: "rss")
                                }
                            }
                        } else {
                            // Use the Reddit logo
                            Label {
                                Text(subscription.title)
                            } icon: {
                                Image("RedditLogo")
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 16, height: 16)
                                    .foregroundColor(.orange)
                            }
                        }
                    }
                    .simultaneousGesture(TapGesture().onEnded {
                        // Remember subscription selection
                        appState.activeSubscriptionURL = subscription.url
                    })
                }
                .onDelete { indexSet in
                    appState.removeSubscription(at: indexSet)
                }
                
                Button(action: { showAddSubscription = true }) {
                    Label("Add Subscription", systemImage: "plus")
                }
            }
        }
        .listStyle(SidebarListStyle())
        .frame(minWidth: 200)
        #if os(macOS)
        .toolbar {
            ToolbarItem {
                Button(action: {
                    NSApp.keyWindow?.firstResponder?.tryToPerform(
                        #selector(NSSplitViewController.toggleSidebar(_:)), with: nil)
                }) {
                    Image(systemName: "sidebar.left")
                }
            }
        }
        #endif
    }
    
    // MARK: - Category Feed List
    var categoryFeedList: some View {
        Group {
            switch appState.lastSelectedCategory {
            case .all:
                allView
            case .unread:
                unreadView
            case .favorites:
                favoritesView
            case .today:
                todayView
            case .reddit:
                redditView
            }
        }
        // Force update on selection change to ensure navigation state is properly updated
        .id("categoryList-\(appState.selectedArticleId ?? "none")-\(appState.selectedRedditPostId ?? "none")")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: { appState.refreshAllFeeds() }) {
                    Image(systemName: "arrow.clockwise")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button(action: { showAddSubscription = true }) {
                    Image(systemName: "plus")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button(action: { showSettings = true }) {
                    Image(systemName: "gearshape.fill")
                }
            }
        }
    }
    
    // MARK: - Feed Views
    var allView: some View {
        ScrollViewReader { scrollProxy in
            List {
                ForEach(appState.feeds.flatMap { $0.articles }
                    .sorted(by: { $0.publishDate > $1.publishDate })) { article in
                        
                    // Use a button for navigation instead of NavigationLink
                    Button(action: {
                        // Set article and navigate
                        appState.selectedArticle = article
                        // Save scroll position for "all" category
                        appState.saveScrollPosition(for: "all_category", itemID: article.id)
                        if !article.isRead {
                            appState.markArticleAsRead(article)
                        }
                    }) {
                        ArticleRow(article: article)
                    }
                    .buttonStyle(PlainButtonStyle())
                    .id(article.id) // Set ID for scroll position tracking
                }
            }
            .onAppear {
                // Restore scroll position when view appears
                if let savedPosition = appState.getSavedScrollPosition(for: "all_category") {
                    withAnimation {
                        scrollProxy.scrollTo(savedPosition, anchor: .top)
                    }
                }
            }
            .navigationTitle("All Articles")
        }
    }
    
    var unreadView: some View {
        ScrollViewReader { scrollProxy in
            List {
                Section(header: Text("RSS Articles")) {
                    let unreadArticles = appState.feeds.flatMap { $0.articles }
                        .filter { !$0.isRead }
                        .sorted(by: { $0.publishDate > $1.publishDate })
                    
                    if unreadArticles.isEmpty {
                        Text("No unread articles")
                            .foregroundColor(.secondary)
                            .padding()
                    } else {
                        ForEach(unreadArticles) { article in
                            Button(action: {
                                // Record that we're in the Unread category before navigating
                                appState.activeSubscriptionURL = nil
                                appState.lastSelectedCategory = .unread
                                
                                // Set article and navigate
                                appState.selectedArticle = article
                                // Save scroll position for "unread" category
                                appState.saveScrollPosition(for: "unread_category", itemID: article.id)
                                appState.markArticleAsRead(article)
                            }) {
                                ArticleRow(article: article)
                            }
                            .buttonStyle(PlainButtonStyle())
                            .id(article.id) // Set ID for scroll position tracking
                        }
                    }
                }
                
                Section(header: Text("Reddit Posts")) {
                    let unreadPosts = appState.redditFeeds.flatMap { $0.posts }
                        .filter { !$0.isRead }
                        .sorted(by: { $0.publishDate > $1.publishDate })
                    
                    if unreadPosts.isEmpty {
                        Text("No unread posts")
                            .foregroundColor(.secondary)
                            .padding()
                    } else {
                        ForEach(unreadPosts) { post in
                            Button(action: {
                                // Record that we're in the Unread category before navigating
                                appState.activeSubscriptionURL = nil
                                appState.lastSelectedCategory = .unread
                                
                                // Set post and navigate
                                appState.selectedRedditPost = post
                                // Save scroll position for "unread" category
                                appState.saveScrollPosition(for: "unread_category", itemID: post.id)
                                appState.markRedditPostAsRead(post)
                            }) {
                                RedditPostRow(post: post)
                            }
                            .buttonStyle(PlainButtonStyle())
                            .id(post.id) // Set ID for scroll position tracking
                        }
                    }
                }
            }
            .onAppear {
                // Update the last selected category when this view appears
                appState.lastSelectedCategory = .unread
                selectedCategory = .unread
                
                // Restore scroll position when view appears
                if let savedPosition = appState.getSavedScrollPosition(for: "unread_category") {
                    withAnimation {
                        scrollProxy.scrollTo(savedPosition, anchor: .top)
                    }
                }
            }
            .navigationTitle("Unread")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    let hasUnreadItems = !(appState.feeds.flatMap { $0.articles }.filter { !$0.isRead }.isEmpty && 
                                          appState.redditFeeds.flatMap { $0.posts }.filter { !$0.isRead }.isEmpty)
                    
                    Button(action: {
                        appState.markAllUnreadAsRead()
                    }) {
                        Label("Mark All as Read", systemImage: "checkmark.circle")
                    }
                    .disabled(!hasUnreadItems)
                }
            }
        }
    }
    
    var favoritesView: some View {
        List {
            Section(header: Text("RSS Articles")) {
                let favoriteArticles = appState.feeds.flatMap { $0.articles }
                    .filter { $0.isFavorite }
                    .sorted(by: { $0.publishDate > $1.publishDate })
                
                if favoriteArticles.isEmpty {
                    Text("No favorite articles")
                        .foregroundColor(.secondary)
                        .padding()
                } else {
                    ForEach(favoriteArticles) { article in
                        Button(action: {
                            // Set article and navigate
                            appState.selectedArticle = article
                            if !article.isRead {
                                appState.markArticleAsRead(article)
                            }
                        }) {
                            ArticleRow(article: article)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(PlainButtonStyle())
                        .swipeActions {
                            Button(role: .destructive) {
                                appState.toggleArticleFavorite(article)
                            } label: {
                                Label("Remove", systemImage: "star.slash")
                            }
                        }
                    }
                }
            }
            
            Section(header: Text("Reddit Posts")) {
                let favoritePosts = appState.redditFeeds.flatMap { $0.posts }
                    .filter { $0.isFavorite }
                    .sorted(by: { $0.publishDate > $1.publishDate })
                
                if favoritePosts.isEmpty {
                    Text("No favorite posts")
                        .foregroundColor(.secondary)
                        .padding()
                } else {
                    ForEach(favoritePosts) { post in
                        Button(action: {
                            // Set post and navigate
                            appState.selectedRedditPost = post
                            if !post.isRead {
                                appState.markRedditPostAsRead(post)
                            }
                        }) {
                            RedditPostRow(post: post)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(PlainButtonStyle())
                        .swipeActions {
                            Button(role: .destructive) {
                                appState.toggleRedditPostFavorite(post)
                            } label: {
                                Label("Remove", systemImage: "star.slash")
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Favorites")
    }
    
    var todayView: some View {
        ScrollViewReader { scrollProxy in
            List {
                let calendar = Calendar.current
                
                // Today's RSS articles
                let todayArticles = appState.feeds.flatMap { $0.articles }
                    .filter { calendar.isDateInToday($0.publishDate) }
                    .sorted(by: { $0.publishDate > $1.publishDate })
                
                if !todayArticles.isEmpty {
                    Section(header: Text("RSS Articles")) {
                        ForEach(todayArticles) { article in
                            Button(action: {
                                // Record that we're in the Today category before navigating
                                appState.activeSubscriptionURL = nil
                                appState.lastSelectedCategory = .today
                                
                                // Set article and navigate
                                appState.selectedArticle = article
                                // Save scroll position for "today" category
                                appState.saveScrollPosition(for: "today_category", itemID: article.id)
                                if !article.isRead {
                                    appState.markArticleAsRead(article)
                                }
                            }) {
                                ArticleRow(article: article)
                            }
                            .buttonStyle(PlainButtonStyle())
                            .id(article.id) // Set ID for scroll position tracking
                        }
                    }
                }
                
                // Today's Reddit posts
                let todayRedditPosts = appState.redditFeeds.flatMap { $0.posts }
                    .filter { calendar.isDateInToday($0.publishDate) }
                    .sorted(by: { $0.publishDate > $1.publishDate })
                
                if !todayRedditPosts.isEmpty {
                    Section(header: Text("Reddit Posts")) {
                        ForEach(todayRedditPosts) { post in
                            Button(action: {
                                // Record that we're in the Today category before navigating
                                appState.activeSubscriptionURL = nil
                                appState.lastSelectedCategory = .today
                                
                                // Set post and navigate
                                appState.selectedRedditPost = post
                                // Save scroll position for "today" category
                                appState.saveScrollPosition(for: "today_category", itemID: post.id)
                                if !post.isRead {
                                    appState.markRedditPostAsRead(post)
                                }
                            }) {
                                RedditPostRow(post: post)
                            }
                            .buttonStyle(PlainButtonStyle())
                            .id(post.id) // Set ID for scroll position tracking
                        }
                    }
                }
                
                if todayArticles.isEmpty && todayRedditPosts.isEmpty {
                    Text("No content from today")
                        .foregroundColor(.secondary)
                        .padding()
                }
            }
            .onAppear {
                // Update the last selected category when this view appears
                appState.lastSelectedCategory = .today
                selectedCategory = .today
                
                // Restore scroll position when view appears
                if let savedPosition = appState.getSavedScrollPosition(for: "today_category") {
                    withAnimation {
                        scrollProxy.scrollTo(savedPosition, anchor: .top)
                    }
                }
            }
            .navigationTitle("Today")
        }
    }
    
    var redditView: some View {
        VStack {
            Picker("Sort", selection: $appState.redditSortOption) {
                Text("Hot").tag(RedditService.SortOption.hot)
                Text("New").tag(RedditService.SortOption.new)
            }
            .pickerStyle(SegmentedPickerStyle())
            .padding(.horizontal)
            .onChange(of: appState.redditSortOption) { newOption in
                print("📱 ContentView: Reddit sort option changed to \(newOption.rawValue) for r/\(appState.activeSubscriptionURL ?? "")")
                // Provide feedback that we're loading
                appState.isLoading = true
                // Use a small delay to ensure UI updates before making the request
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    // Only refresh the current subreddit feed instead of all feeds
                    appState.refreshRedditFeeds(specificSubreddit: appState.activeSubscriptionURL)
                }
            }
            
            List {
                ForEach(appState.redditFeeds.flatMap { $0.posts }
                    .sorted(by: { $0.publishDate > $1.publishDate })) { post in
                        
                        Button(action: {
                            // First set the post selection
                            appState.selectedRedditPost = post
                            appState.markRedditPostAsRead(post)
                        }) {
                            RedditPostRow(post: post)
                        }
                        .buttonStyle(PlainButtonStyle())
                }
            }
        }
        .navigationTitle("Reddit")
    }
    
    func subscriptionView(for subscription: Subscription) -> some View {
        Group {
            if subscription.type == .rss {
                if let feed = appState.feeds.first(where: { $0.url == subscription.url }) {
                    VStack {
                        HStack {
                            // Add favicon for the feed source if available
                            if let url = URL(string: subscription.url), let host = url.host {
                                DomainIconView(domain: host, size: 20)
                            }
                            Text(feed.title)
                                .font(.headline)
                            Spacer()
                        }
                        .padding(.horizontal)
                        
                        // Add ScrollViewReader to maintain scroll position
                        ScrollViewReader { scrollProxy in
                            List {
                                // For 9to5mac, ensure proper date sorting by using a more aggressive comparison
                                if feed.url.contains("9to5mac.com") {
                                    ForEach(feed.articles.sorted(by: { article1, article2 in
                                        // If dates are very close (within 60 seconds), use ID comparison as fallback
                                        if abs(article1.publishDate.timeIntervalSince(article2.publishDate)) < 60 {
                                            return article1.id > article2.id
                                        }
                                        return article1.publishDate > article2.publishDate
                                    })) { article in
                                        Button(action: {
                                            // Remember the current subscription before navigating
                                            appState.rememberCurrentSubscription(url: subscription.url)
                                            // Save current scroll position before navigating
                                            appState.saveScrollPosition(for: subscription.url, itemID: article.id)
                                            // Set article and navigate
                                            appState.selectedArticle = article
                                            if !article.isRead {
                                                appState.markArticleAsRead(article)
                                            }
                                        }) {
                                            ArticleRow(article: article)
                                        }
                                        .buttonStyle(PlainButtonStyle())
                                        .id(article.id) // Set ID for scroll position tracking
                                    }
                                } else {
                                    // Regular sorting for other feeds
                                    ForEach(feed.articles) { article in
                                        Button(action: {
                                            // Remember the current subscription before navigating
                                            appState.rememberCurrentSubscription(url: subscription.url)
                                            // Save current scroll position before navigating
                                            appState.saveScrollPosition(for: subscription.url, itemID: article.id)
                                            // Set article and navigate
                                            appState.selectedArticle = article
                                            if !article.isRead {
                                                appState.markArticleAsRead(article)
                                            }
                                        }) {
                                            ArticleRow(article: article)
                                        }
                                    .buttonStyle(PlainButtonStyle())
                                    .id(article.id) // Set ID for scroll position tracking
                                    }
                                }
                            }
                            .onAppear {
                                // Restore scroll position when view appears
                                if let savedPosition = appState.getSavedScrollPosition(for: subscription.url) {
                                    // Use withAnimation for smooth scrolling
                                    withAnimation {
                                        scrollProxy.scrollTo(savedPosition, anchor: .top)
                                    }
                                }
                            }
                        }
                    }
                    .navigationTitle(subscription.title)
                } else {
                    Text("Loading feed...")
                        .navigationTitle(subscription.title)
                }
            } else {
                if let feed = appState.redditFeeds.first(where: { $0.subreddit == subscription.url }) {
                    VStack {
                        HStack {
                            Image("RedditLogo")
                                .resizable()
                                .scaledToFit()
                                .frame(width: 20, height: 20)
                                .foregroundColor(.orange)
                            Text("r/\(feed.subreddit)")
                                .font(.headline)
                            Spacer()
                        }
                        .padding(.horizontal)
                        
                        Picker("Sort", selection: $appState.redditSortOption) {
                            Text("Hot").tag(RedditService.SortOption.hot)
                            Text("New").tag(RedditService.SortOption.new)
                        }
                        .pickerStyle(SegmentedPickerStyle())
                        .padding(.horizontal)
                        .onChange(of: appState.redditSortOption) { newOption in
                            print("📱 ContentView: Reddit sort option changed to \(newOption.rawValue) for r/\(subscription.url)")
                            // Provide feedback that we're loading
                            appState.isLoading = true
                            // Use a small delay to ensure UI updates before making the request
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                // Only refresh the current subreddit feed instead of all feeds
                                appState.refreshRedditFeeds(specificSubreddit: subscription.url)
                            }
                        }
                        
                        // Add ScrollViewReader to maintain Reddit scroll position
                        ScrollViewReader { scrollProxy in
                            List {
                                ForEach(feed.posts) { post in
                                    Button(action: {
                                        // Remember the current subscription before navigating
                                        appState.rememberCurrentSubscription(url: subscription.url)
                                        // Save current scroll position before navigating
                                        appState.saveScrollPosition(for: subscription.url, itemID: post.id)
                                        // Set post and navigate
                                        appState.selectedRedditPost = post
                                        if !post.isRead {
                                            appState.markRedditPostAsRead(post)
                                        }
                                    }) {
                                        RedditPostRow(post: post)
                                    }
                                    .buttonStyle(PlainButtonStyle())
                                    .id(post.id) // Set ID for scroll position tracking
                                }
                            }
                            .onAppear {
                                // Restore scroll position when view appears
                                if let savedPosition = appState.getSavedScrollPosition(for: subscription.url) {
                                    // Use withAnimation for smooth scrolling
                                    withAnimation {
                                        scrollProxy.scrollTo(savedPosition, anchor: .top)
                                    }
                                }
                            }
                        }
                    }
                    .navigationTitle(subscription.title)
                } else {
                    Text("Loading subreddit...")
                        .navigationTitle(subscription.title)
                }
            }
        }
    }
    
    // MARK: - Detail View
    var detailView: some View {
        Group {
            if appState.selectedArticle != nil {
                ArticleDetailView()
        } else if let selectedRedditPost = appState.selectedRedditPost {
            RedditDetailView()
                .id("post-\(selectedRedditPost.id)") // Force view recreation with unique ID
            } else {
                Text("Select an article or post to read")
                    .font(.title)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
    
    // MARK: - Helper Functions
    private func restoreNavigationState() -> some View {
        // Set the selected category to match what's in AppState
        self.selectedCategory = appState.lastSelectedCategory
        
        return Group {
            if let activeURL = appState.activeSubscriptionURL {
                // If we have an active subscription URL, navigate to it
                let subscription = appState.subscriptions.first(where: { $0.url == activeURL })
                if let subscription = subscription {
                    subscriptionView(for: subscription)
                } else {
                    // Fallback to category if subscription not found
                    categoryFeedList
                }
            } else {
                // Otherwise show the category feed list based on lastSelectedCategory
                categoryFeedList
            }
        }
    }
}

// MARK: - Domain Icon View
struct DomainIconView: View {
    let domain: String?
    let size: CGFloat
    
    var body: some View {
        Group {
            if let domain = domain {
                // Create a Google favicon URL
                if let googleFaviconURL = URL(string: "https://www.google.com/s2/favicons?domain=\(domain)&sz=64") {
                    AsyncImage(url: googleFaviconURL) { image in
                        image
                            .resizable()
                            .scaledToFit()
                    } placeholder: {
                        // While loading, show a placeholder with the domain's first letter
                        DomainLetterView(domain: domain, size: size)
                    }
                    .frame(width: size, height: size)
                } else {
                    // If URL creation failed, use a placeholder
                    DomainLetterView(domain: domain, size: size)
                }
            } else {
                // Fallback generic icon
                Image(systemName: "globe")
                    .resizable()
                    .scaledToFit()
                    .frame(width: size, height: size)
                    .foregroundColor(.gray)
            }
        }
        .frame(width: size, height: size)
    }
}

// Placeholder view with first letter of domain
struct DomainLetterView: View {
    let domain: String
    let size: CGFloat
    
    var body: some View {
        ZStack {
            Circle()
                .fill(colorForDomain(domain))
            Text(String(domain.prefix(1).uppercased()))
                .font(.system(size: size * 0.6, weight: .bold))
                .foregroundColor(.white)
        }
        .frame(width: size, height: size)
    }
    
    // Deterministic color based on domain name
    private func colorForDomain(_ domain: String) -> Color {
        let colors: [Color] = [.blue, .green, .orange, .purple, .red]
        let index = abs(domain.hashValue) % colors.count
        return colors[index]
    }
}

// MARK: - String Extension for Image URL Extraction
extension String {
    func extractImageUrl() -> String {
        // Look for URLs in img tags first
        let imgTagPattern = "<img[^>]+src\\s*=\\s*['\"]([^'\"]+)['\"][^>]*>"
        if let regex = try? NSRegularExpression(pattern: imgTagPattern, options: .caseInsensitive),
           let match = regex.firstMatch(in: self, options: [], range: NSRange(self.startIndex..., in: self)),
           let captureRange = Range(match.range(at: 1), in: self) {
            return String(self[captureRange])
        }
        
        // Then try for URLs with common image extensions
        let pattern = "https?://[^\\s]+\\.(jpg|jpeg|png|gif|webp)"
        if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
           let match = regex.firstMatch(in: self, options: [], range: NSRange(self.startIndex..., in: self)),
           let range = Range(match.range, in: self) {
            return String(self[range])
        }
        
        // Fallback - just find any URL
        let urlPattern = "https?://[^\\s]+"
        if let regex = try? NSRegularExpression(pattern: urlPattern, options: []),
           let match = regex.firstMatch(in: self, options: [], range: NSRange(self.startIndex..., in: self)),
           let range = Range(match.range, in: self) {
            return String(self[range])
        }
        
        return ""
    }
}

// MARK: - Article Row
struct ArticleRow: View {
    @EnvironmentObject var appState: AppState
    let article: Article
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Top row: Domain and date
            HStack {
                // Publication source
                HStack(spacing: 4) {
                    if let url = article.url, let host = url.host {
                        DomainIconView(domain: host, size: 14)
                    }
                    
                            Text(article.feedTitle)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(Color(.lightGray))
                    }
                    
                    Spacer()
                    
                // Date
                Text(formatDate(article.publishDate))
                    .font(.system(size: 12))
                    .foregroundColor(Color(.lightGray))
            }
            
            // Article title with clean typography
            Text(article.title)
                .font(.system(size: 17, weight: .semibold))
                // Revert color change
                .foregroundColor(.white)
                .lineLimit(3)
                .padding(.bottom, 2)
            
            // Content layout - horizontal on larger screens
            HStack(alignment: .top, spacing: 12) {
                // Text preview
                if !article.content.isEmpty {
                    Text(cleanContentPreview(article.content))
                        .font(.system(size: 14))
                        // Revert color change
                        .foregroundColor(Color(.lightGray))
                        .lineLimit(2)
                        .lineSpacing(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                
                // Image if available
                    if let imageURL = article.imageURL {
                        AsyncImage(url: imageURL) { phase in
                            switch phase {
                            case .success(let image):
                                image
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(maxWidth: .infinity) // Use maxWidth, remove fixed height
                                    .background(Color.black.opacity(0.2))
                                    .cornerRadius(8) // Use cornerRadius 8
                            case .failure, .empty, _:
                                Rectangle()
                                    .fill(Color.secondary.opacity(0.1))
                                    // Remove fixed frame, let it adapt or set a placeholder size if needed
                                    .frame(maxWidth: .infinity, idealHeight: 80) // Keep a placeholder height idea
                                    .background(Color.black.opacity(0.2))
                                    .cornerRadius(8)
                            }
                        }
                        // Remove the fixed outer frame, let AsyncImage control size
                        .background(Color.black.opacity(0.2))
                        .cornerRadius(8)
                    }
            }
            
            // Status indicators
            HStack(spacing: 12) {
                // Replace "New" badge with "Seen" badge
                if article.isRead { // Check if IS read
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle") // Checkmark icon
                            .font(.system(size: 10))
                        Text("Seen") // "Seen" text
                            .font(.system(size: 11, weight: .medium))
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.gray.opacity(0.2)) // Grey background
                    .foregroundColor(Color.gray.opacity(0.9)) // Grey foreground
                    .cornerRadius(4)
                }
                
                if article.summary != nil {
                    Text("Summary")
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.green.opacity(0.2))
                        .foregroundColor(Color.green.opacity(0.9))
                        .cornerRadius(4)
                }
                
                if article.isFavorite {
                    HStack(spacing: 4) {
                        Image(systemName: "star.fill")
                            .font(.system(size: 10))
                        Text("Favorite")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.yellow.opacity(0.2))
                    .foregroundColor(Color.yellow)
                    .cornerRadius(4)
                }
                
                Spacer()
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(red: 0.15, green: 0.15, blue: 0.15))
                .shadow(color: Color.black.opacity(0.3), radius: 5, x: 0, y: 2)
        )
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
    }
    
    // Format date in a clean readable format
    private func formatDate(_ date: Date) -> String {
        let calendar = Calendar.current
        
        // If today, show time only
        if calendar.isDateInToday(date) {
            let formatter = DateFormatter()
            formatter.timeStyle = .short
            return formatter.string(from: date)
        }
        
        // If within a week, show day name
        let now = Date()
        if let days = calendar.dateComponents([.day], from: date, to: now).day, days < 7 {
            let formatter = DateFormatter()
            formatter.dateFormat = "EEE"
            return formatter.string(from: date)
        }
        
        // Otherwise show compact date
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return formatter.string(from: date)
    }
    
    // Clean up content for preview
    private func cleanContentPreview(_ content: String) -> String {
        var cleaned = content
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&[^;]+;", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Limit preview length
        if cleaned.count > 140 {
            cleaned = String(cleaned.prefix(140)) + "..."
        }
        
        return cleaned
    }
}

// MARK: - Reddit Post Row
struct RedditPostRow: View {
    let post: RedditPost
    
    var body: some View {
        ZStack {
            // Background
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.orange.opacity(0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Color.orange.opacity(0.2), lineWidth: 1)
                )
            
            VStack(alignment: .leading, spacing: 8) {
                // Image preview if available
                if let imageURL = post.bestImageURL {
                    AsyncImage(url: imageURL) { phase in
                        switch phase {
                        case .empty:
                            ZStack {
                                Rectangle()
                                    .fill(Color.gray.opacity(0.15))
                                ProgressView()
                            }
                        case .success(let image):
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fit) // Changed back to .fit
                                .frame(maxWidth: .infinity)
                                .background(Color.black.opacity(0.2))
                                .cornerRadius(8)
                        case .failure:
                            ZStack {
                                Rectangle()
                                    .fill(Color.gray.opacity(0.15))
                                Image(systemName: "photo")
                                    .foregroundColor(.gray)
                            }
                            .background(Color.black.opacity(0.2)) // Add background here too
                            .cornerRadius(8)
                        @unknown default:
                            EmptyView()
                                .background(Color.black.opacity(0.2)) // Add background here too
                                .cornerRadius(8)
                        }
                    }
                    .frame(maxWidth: .infinity) // Removed maxHeight
                    .background(Color.black.opacity(0.2))
                    .cornerRadius(8)
                }
                // Header with Reddit info
                HStack(alignment: .center) {
                    // Upvote/score/downvote column
                    HStack(spacing: 0) {
                        VStack(spacing: 2) {
                            Image(systemName: "arrow.up")
                                .font(.system(size: 12))
                                .foregroundColor(.gray)
                            Text("\(post.score)")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(.gray)
                            Image(systemName: "arrow.down")
                                .font(.system(size: 12))
                                .foregroundColor(.gray)
                        }
                        .frame(width: 24)
                        .padding(.trailing, 8)
                    }
                    
                    // Subreddit info
                    HStack(spacing: 4) {
                        Image("RedditLogo")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 16, height: 16)
                            .foregroundColor(.orange)
                        
                        Text("r/\(post.subreddit)")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.secondary)
                    }
                    
                    Spacer()
                    
                    // Post metadata
                    HStack {
                        Text("u/\(post.author)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        Text("•")
                            .font(.caption2)
                            .foregroundColor(.gray)
                        
                        Text(post.publishDate, style: .relative)
                            .font(.caption)
                            .foregroundColor(.gray)
                    }
                }
                
                // Post title
                Text(post.title)
                    .font(.headline)
                    .lineLimit(3)
                    // Revert color change - always use primary color
                    .foregroundColor(.primary)
                
                // Add "Seen" badge if read
                if post.isRead {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle")
                            .font(.system(size: 10))
                        Text("Seen")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.gray.opacity(0.2))
                    .foregroundColor(Color.gray.opacity(0.9))
                    .cornerRadius(4)
                    .padding(.top, 4) // Add a little space above the badge
                }
                
                // Post content preview
                if !post.content.isEmpty {
                    Text(post.content)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
                
                // Always show an image/card section
                ZStack(alignment: .bottom) {
                    // Gradient background
                    Rectangle()
                        .fill(LinearGradient(
                            gradient: Gradient(colors: [
                                .orange.opacity(0.6),
                                .orange.opacity(0.2)
                            ]),
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ))
                        .frame(height: 100)
                        .cornerRadius(8)
                    
                    // Action bar
                    HStack(spacing: 24) {
                        // Comments button
                        HStack(spacing: 4) {
                            Image(systemName: "bubble.left.fill")
                                .font(.system(size: 14))
                            Text("\(post.commentCount)")
                                .font(.system(size: 14, weight: .semibold))
                        }
                        .foregroundColor(.white)
                        
                        // Share button
                        HStack(spacing: 4) {
                            Image(systemName: "arrowshape.turn.up.right.fill")
                                .font(.system(size: 14))
                            Text("Share")
                                .font(.system(size: 14))
                        }
                        .foregroundColor(.white)
                        
                        // Summary indicator if available
                        if post.summary != nil {
                            HStack(spacing: 4) {
                                Image(systemName: "text.quote")
                                    .font(.system(size: 14))
                                Text("Summary")
                                    .font(.system(size: 14))
                            }
                            .foregroundColor(.white)
                        }
                        
                        Spacer()
                        
                        // Favorite indicator
                        if post.isFavorite {
                            Image(systemName: "star.fill")
                                .foregroundColor(.yellow)
                                .font(.system(size: 14))
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.black.opacity(0.2))
                    .cornerRadius(8)
                }
            }
            .padding(12)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
    }
}

// MARK: - Article Detail View
struct ArticleDetailView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var qaState = ArticleQAState.shared
    @State private var cancellables = Set<AnyCancellable>()
    
    /// Process content to remove the first image if a header image was already displayed.
    private var contentToRender: String {
        guard let article = appState.selectedArticle else { return "" }

        // Only remove image from content if a header image was found/displayed
        if article.imageURL != nil {
            return removeFirstImage(fromHTML: article.content)
        } else {
            return article.content // Return original content if no header image
        }
    }
    
    var body: some View {
        if let article = appState.selectedArticle {
            GeometryReader { geometry in
                ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 0) {
                        // Publication bar
                        HStack {
                            if let url = article.url, let host = url.host {
                                DomainIconView(domain: host, size: 16)
                            }
                            Text(article.feedTitle)
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(.secondary)
                            
                            if let author = article.author, !author.isEmpty {
                                Text("–")
                                    .foregroundColor(.secondary)
                                Text(author)
                                    .font(.system(size: 14))
                                .foregroundColor(.secondary)
                        }
                            
                            Spacer()
                            
                            Text(formattedDate(article.publishDate))
                                .font(.system(size: 14))
                                .foregroundColor(.secondary)
                        }
                        .padding(.horizontal, 20)
                        .padding(.top, 20)
                        .padding(.bottom, 16)
                        
                        // Article headline
                        Text(article.title)
                            .font(.system(size: 34, weight: .bold))
                            .lineSpacing(0)
                            .padding(.horizontal, 20)
                            .padding(.bottom, 30)
                        
                        // Article body content
                        VStack(alignment: .leading, spacing: 16) {
                            // Leading paragraph or summary
                            if let summary = article.summary {
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack {
                                        Text("Summary")
                                            .font(.headline)
                                        
                                        Spacer()
                                        
                                        if !qaState.showQAInterface {
                                            Button(action: {
                                                qaState.toggleQAInterface()
                                            }) {
                                                Label("Ask about this article", systemImage: "questionmark.circle")
                                                    .font(.subheadline)
                                            }
                                            .buttonStyle(BorderedButtonStyle())
                                        }
                                    }
                                    ArticleGlassySummary(summary: summary)
                                }
                                .padding(.bottom, 16)
                            } else if !qaState.showQAInterface {
                                // If no summary, still show the Ask button
                                HStack {
                                    Spacer()
                                    Button(action: {
                                        qaState.toggleQAInterface()
                                    }) {
                                        Label("Ask about this article", systemImage: "questionmark.circle")
                                            .font(.subheadline)
                                    }
                                    .buttonStyle(BorderedButtonStyle())
                                    .padding(.bottom, 8)
                                }
                            }
                            
                            // Toggle-able Q&A Interface - only visible when enabled
                            if qaState.showQAInterface {
                                VStack(alignment: .leading, spacing: 12) {
                                    Text("Ask a question about this article:")
                                        .font(.headline)
                                    
                                    TextField("Type your question...", text: $qaState.questionText)
                                        .textFieldStyle(RoundedBorderTextFieldStyle())
                                        .disabled(qaState.isProcessingQuestion)
                                        .onSubmit {
                                            if !qaState.questionText.isEmpty && !qaState.isProcessingQuestion {
                                                askQuestion(article: article)
                                            }
                                        }
                                        .onAppear {
                                            print("📱 ArticleDetailView: Q&A interface appeared")
                                        }
                                    
                                    HStack {
                                        Button(action: {
                                            if !qaState.questionText.isEmpty {
                                                askQuestion(article: article)
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
                                        .disabled(qaState.questionText.isEmpty || qaState.isProcessingQuestion)
                                        
                                        Button(action: {
                                            qaState.showQAInterface = false
                                            qaState.questionText = ""
                                            qaState.answerText = "Ask a question about this article..."
                                            print("📱 ArticleDetailView: Q&A interface canceled by user")
                                        }) {
                                            Text("Cancel")
                                        }
                                        
                                        Spacer()
                                    }
                                    
                                    Text(qaState.answerText)
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
                            
                            // Main content - Use the processed content
                            ArticleContentRenderer(content: contentToRender) // <-- Use contentToRender
                                .padding(.top, 8)
                                .frame(minHeight: geometry.size.height * 0.7)
                                .frame(maxHeight: .infinity)
                        }
                        .padding(.horizontal, 20)
                        .padding(.bottom, 40)
                        
                        // Footer with original article link
                        if let url = article.url {
                            Divider()
                                .padding(.horizontal, 20)
                            
                            Link(destination: url) {
                            HStack {
                                    Text("Read full article on")
                                        .font(.system(size: 15))
                                        .foregroundColor(.secondary)
                                    
                                    if let host = url.host {
                                        Text(host)
                                            .font(.system(size: 15, weight: .semibold))
                                            .foregroundColor(.blue)
                                    }
                                    
                                    Image(systemName: "arrow.up.right")
                                        .font(.system(size: 12))
                                        .foregroundColor(.blue)
                                }
                                .padding(.horizontal, 20)
                                .padding(.vertical, 16)
                            }
                        }
                    }
                    .frame(minWidth: geometry.size.width)
                    .frame(minHeight: geometry.size.height)
                }
                .edgesIgnoringSafeArea(.all)
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button(action: { appState.toggleArticleFavorite(article) }) {
                        Image(systemName: article.isFavorite ? "star.fill" : "star")
                            .foregroundColor(article.isFavorite ? .yellow : .primary)
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button(action: { appState.summarizeArticle(article) }) {
                        HStack {
                            Image(systemName: "text.quote")
                            Text("Summarize")
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.orange)
                        .foregroundColor(.white)
                        .cornerRadius(8)
                    }
                }
                // "Ask AI" button removed from toolbar
            }
            .onAppear {
                // Ensure the selection state is correctly set and synchronized
                if appState.selectedArticleId != article.id || appState.selectedArticle?.id != article.id {
                    appState.setSelectedArticle(article)
                }
                
                // Reset Q&A state when viewing a new article
                qaState.resetState()
                print("📱 ArticleDetailView: Reset Q&A state for article: \(article.title)")
            }
        } else {
            Text("Select an article to read")
                .font(.title)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
    
    private func askQuestion(article: Article) {
        guard !qaState.questionText.isEmpty else { return }

        print("📱 ArticleDetailView: Asking question: \"\(qaState.questionText)\"")

        // Set loading state
        qaState.isProcessingQuestion = true
        qaState.answerText = "Thinking..."

        // Compose the prompt to include the previous question if it exists
        let previousQ = qaState.previousQuestionText
        let prompt: String
        if let prev = previousQ, !prev.isEmpty {
            prompt = """
            Article Title: \(article.title)
            Article Content:
            \(article.content)

            Previous Question:
            \(prev)

            Current Question:
            \(qaState.questionText)

            Please answer the current question based on the article above. If the answer cannot be determined from the article, please state that the information is not available in the article.
            """
        } else {
            prompt = """
            Article Title: \(article.title)
            Article Content:
            \(article.content)

            Please answer the following question:
            \(qaState.questionText)

            If the answer cannot be determined from the article, please state that the information is not available in the article.
            """
        }

        // Call the AppState method directly, passing the custom prompt
        appState.summaryService.summarizeText("", customPrompt: prompt)
            .receive(on: RunLoop.main)
            .sink { answer in
                self.qaState.answerText = answer
                self.qaState.isProcessingQuestion = false
                // Update previous question for next time
                self.qaState.previousQuestionText = self.qaState.questionText
                print("📱 ArticleDetailView: Got answer, updating UI")
            }
            .store(in: &cancellables)
    }
    
    // Format date in a clean readable format
    private func formattedDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        
        if Calendar.current.isDateInToday(date) {
            formatter.dateFormat = "'Today at' h:mm a"
        } else if Calendar.current.isDate(date, equalTo: Date(), toGranularity: .year) {
            formatter.dateFormat = "MMM d"
        } else {
            formatter.dateFormat = "MMM d, yyyy"
        }
        
        return formatter.string(from: date)
    }
    
    // Extract image caption if available
    private func extractImageCaption(_ article: Article) -> String? {
        if let imageURL = article.imageURL?.absoluteString {
            // Try to extract caption from title if it contains image reference
            if article.title.contains("Image:") || article.title.contains("image:") {
                let components = article.title.components(separatedBy: "|")
                if components.count > 1 {
                    return components.last?.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
            
            // Default caption with attribution
            return "\(article.feedTitle) | Image: \(article.url?.host ?? "Source")"
        }
        return nil
    }

    /// Helper to remove the first <img> tag from HTML using SwiftSoup.
    private func removeFirstImage(fromHTML html: String) -> String {
        do {
            let document: Document = try SwiftSoup.parseBodyFragment(html)
            if let firstImg = try document.select("img").first() {
                try firstImg.remove()
            }
            return try document.body()?.html() ?? html // Return modified HTML or original if error
        } catch {
            print("SwiftSoup error removing first image: \(error)")
            return html // Return original HTML in case of error
        }
    }
}

// MARK: - Article Content Renderer
struct ArticleContentRenderer: View {
    let content: String
    
    var body: some View {
        // Process and display the HTML content with proper formatting
        VStack(alignment: .leading, spacing: 0) {
            // Use WebView for proper rendering of complex HTML
            HTMLWebView(htmlContent: enhanceHTML(content))
                            .frame(maxWidth: .infinity)
                .frame(minHeight: 800)
        }
        .frame(maxWidth: .infinity)
    }
    
    // Enhance HTML with better styling
    private func enhanceHTML(_ html: String) -> String {
        // Don't process if it's already well-formed HTML with our custom wrapper
        if html.contains("<html") && html.contains("<body") && html.contains("RSSReaderApp-processed") {
            return html
        }
        
        var processedHTML = html
        
        // Fix common encoding issues
        let replacements: [(String, String)] = [
            ("&acirc;&#128;&#148;", "—"),  // em dash
            ("&acirc;&#128;&#153;", "'"),  // right single quote
            ("&acirc;&#128;&#156;", "\""),  // left double quote
            ("&acirc;&#128;&#157;", "\""),  // right double quote
            ("&acirc;&#128;&#147;", "–"),  // en dash
            ("&acirc;&#128;&#152;", "'"),  // left single quote
            ("&#8217;", "'"),             // apostrophe
            ("&#8220;", "\""),            // open double quote
            ("&#8221;", "\""),            // close double quote
            ("&nbsp;", " "),              // non-breaking space
            ("&amp;", "&"),               // ampersand
            ("&lt;", "<"),                // less than
            ("&gt;", ">")                 // greater than
        ]
        
        for (pattern, replacement) in replacements {
            processedHTML = processedHTML.replacingOccurrences(of: pattern, with: replacement)
        }
        
        // Convert any legacy [IMAGE:url] placeholders to proper <img> tags
        let imageTagPattern = "\\[IMAGE:([^\\]]+)\\]"
        processedHTML = processedHTML.replacingOccurrences(
            of: imageTagPattern,
            with: "<img src=\"$1\" alt=\"Article image\" style=\"max-width:100%;height:auto;display:block;margin:24px auto;\">",
            options: .regularExpression
        )
        
        // Also handle IMAGE:url without brackets
        let noBracketPattern = "IMAGE:(https?://\\S+)"
        processedHTML = processedHTML.replacingOccurrences(
            of: noBracketPattern,
            with: "<img src=\"$1\" alt=\"Article image\" style=\"max-width:100%;height:auto;display:block;margin:24px auto;\">",
            options: .regularExpression
        )
        
        // Clean HTML using regex to strip inline styles
        // Remove style attributes
        processedHTML = processedHTML.replacingOccurrences(
            of: "style\\s*=\\s*['\"][^'\"]*['\"]",
            with: "",
            options: .regularExpression
        )
        
        // Remove <style> blocks
        processedHTML = processedHTML.replacingOccurrences(
            of: "<style[^>]*>[\\s\\S]*?</style>",
            with: "",
            options: .regularExpression
        )
        
        // Remove external stylesheets
        processedHTML = processedHTML.replacingOccurrences(
            of: "<link[^>]*rel\\s*=\\s*['\"]stylesheet['\"][^>]*>",
            with: "",
            options: .regularExpression
        )
        
        // Remove any class attributes to prevent external styles from applying
        processedHTML = processedHTML.replacingOccurrences(
            of: "class\\s*=\\s*['\"][^'\"]*['\"]",
            with: "",
            options: .regularExpression
        )
        
        // If the content doesn't seem to be HTML, wrap it in paragraph tags
        if !processedHTML.contains("<") {
            processedHTML = "<p>\(processedHTML)</p>"
        }
        
        // Wrap the content with proper styling
        return """
        <!DOCTYPE html>
        <html data-app="RSSReaderApp-processed">
        <head>
            <meta charset="UTF-8">
            <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
            <style>
                /* Reset all spacing to ensure consistency */
                * {
                    margin: 0;
                    padding: 0;
                    box-sizing: border-box;
                }
                
                html, body {
                    height: 100%;
                    width: 100%;
                    margin: 0;
                    padding: 0;
                    background-color: #121212;
                    color: rgba(255, 255, 255, 0.95);
                }
                
                body {
                    font-family: -apple-system, system-ui, BlinkMacSystemFont, "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif !important;
                    font-size: 19px !important;
                    line-height: 1.7 !important;
                    color: rgba(255, 255, 255, 0.95) !important;
                    -webkit-font-smoothing: antialiased;
                    min-height: 100vh;
                    display: flex;
                    flex-direction: column;
                    padding: 0 !important;
                    margin: 0 !important;
                    background-color: #121212;
                }
                
                /* Override any feed-specific styles */
                p, div, span, li, td, th, address, blockquote, article, aside, details, figcaption, figure, 
                footer, header, main, section, summary {
                    font-family: -apple-system, system-ui, BlinkMacSystemFont, "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif !important;
                    font-size: 19px !important;
                    line-height: 1.7 !important;
                    color: rgba(255, 255, 255, 0.95) !important;
                    margin-bottom: 24px !important;
                }
                
                p {
                    margin-bottom: 24px !important;
                    line-height: 1.7 !important;
                    font-size: 19px !important;
                }
                
                /* Standardize headings */
                h1, h2, h3, h4, h5, h6 {
                    font-family: -apple-system, system-ui, BlinkMacSystemFont, "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif !important;
                    font-weight: 700 !important;
                    line-height: 1.3 !important;
                    margin-top: 32px !important;
                    margin-bottom: 16px !important;
                    color: rgba(255, 255, 255, 0.95) !important;
                }
                
                h1 { font-size: 32px !important; }
                h2 { font-size: 28px !important; }
                h3 { font-size: 24px !important; }
                h4 { font-size: 20px !important; }
                h5 { font-size: 18px !important; }
                h6 { font-size: 16px !important; }
                
                a {
                    color: #4da6ff !important;
                    text-decoration: none !important;
                    border-bottom: 1px solid rgba(77, 166, 255, 0.3) !important;
                }
                
                img, video, iframe {
                    max-width: 100% !important;
                    height: auto !important;
                    display: block !important;
                    margin: 24px auto !important;
                    border-radius: 4px !important;
                }
                
                figure {
                    margin: 30px 0 !important;
                    max-width: 100% !important;
                }
                
                figcaption {
                    color: rgba(255, 255, 255, 0.7) !important;
                    font-size: 14px !important;
                    font-style: italic !important;
                    margin-top: 8px !important;
                    line-height: 1.4 !important;
                    text-align: center !important;
                }
                
                blockquote {
                    border-left: 4px solid #444 !important;
                    margin-left: 0 !important;
                    padding: 0 0 0 20px !important;
                    color: rgba(255, 255, 255, 0.8) !important;
                    font-style: italic !important;
                    margin: 24px 0 !important;
                }
                
                pre, code {
                    background-color: #2d2d2d !important;
                    border-radius: 3px !important;
                    font-family: Menlo, Monaco, Consolas, "Courier New", monospace !important;
                    font-size: 14px !important;
                    padding: 2px 4px !important;
                    color: #e6e6e6 !important;
                }
                
                pre {
                    padding: 16px !important;
                    overflow: auto !important;
                    line-height: 1.45 !important;
                }
                
                ul, ol {
                    padding-left: 24px !important;
                    margin-bottom: 24px !important;
                }
                
                li {
                    margin-bottom: 8px !important;
                }
                
                table {
                    border-collapse: collapse !important;
                    width: 100% !important;
                    margin: 24px 0 !important;
                }
                
                th, td {
                    border: 1px solid #444 !important;
                    padding: 12px !important;
                    text-align: left !important;
                }
                
                th {
                    background-color: #333 !important;
                    font-weight: 600 !important;
                }
                
                /* Fix Twitter embeds */
                .twitter-tweet {
                    margin: 24px auto !important;
                }
                
                /* YouTube/iframe responsive containers */
                .video-container {
                    position: relative !important;
                    padding-bottom: 56.25% !important; /* 16:9 aspect ratio */
                    height: 0 !important;
                    overflow: hidden !important;
                    margin: 24px 0 !important;
                }
                
                .video-container iframe {
                    position: absolute !important;
                    top: 0 !important;
                    left: 0 !important;
                    width: 100% !important;
                    height: 100% !important;
                }
                
                /* Image zoom effect */
                img:active {
                    transform: scale(1.01) !important;
                    transition: transform 0.2s ease !important;
                }
                
                /* Highlighted text */
                mark {
                    background-color: rgba(255, 255, 0, 0.3) !important;
                    padding: 0 2px !important;
                    color: rgba(255, 255, 255, 0.95) !important;
                }
                
                /* Pull quotes - like The Verge uses */
                .pull-quote {
                    font-size: 24px !important;
                    line-height: 1.4 !important;
                    font-weight: 300 !important;
                    color: rgba(255, 255, 255, 0.9) !important;
                    border-left: none !important;
                    padding: 0 40px !important;
                    text-align: center !important;
                    margin: 36px 0 !important;
                }
                
                /* Add additional space at the bottom to prevent cutting off content */
                .content-container {
                    flex: 1 !important;
                    padding-bottom: 100px !important; /* Added extra padding */
                    overflow: visible !important; /* Ensure content isn't cut */
                }
                
                /* Force the content to fill the available space */
                @media screen and (min-height: 700px) {
                    .content-container {
                        min-height: calc(100vh - 200px) !important;
                    }
                }
            </style>
        </head>
        <body>
            <div class="content-container">
                \(processedHTML)
            </div>
        </body>
        </html>
        """
    }
}

// WebView wrapper for displaying HTML content
#if os(macOS)
struct HTMLWebView: NSViewRepresentable {
    let htmlContent: String
    @State private var contentHeight: CGFloat = 800
    
    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let preferences = WKPreferences()
        preferences.javaScriptEnabled = true
        config.preferences = preferences
        
        let userContentController = WKUserContentController()
        userContentController.add(context.coordinator, name: "heightUpdate")
        config.userContentController = userContentController
        
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = false
        webView.translatesAutoresizingMaskIntoConstraints = false
        
        // Configure the web view
        webView.setValue(false, forKey: "drawsBackground")
        
        return webView
    }
    
    func updateNSView(_ nsView: WKWebView, context: Context) {
        // Load the HTML content
        nsView.loadHTMLString(htmlContent, baseURL: nil)
        
        // Add JS to measure content height and resize the WebView
        let script = """
        function updateHeight() {
            var body = document.body;
            var html = document.documentElement;
            
            // Get the max of body and html height to handle different browser rendering
            var height = Math.max(
                body.scrollHeight, body.offsetHeight, 
                html.clientHeight, html.scrollHeight, html.offsetHeight
            );
            
            // Ensure we have a minimum reasonable height
            height = Math.max(height, 800);
            
            window.webkit.messageHandlers.heightUpdate.postMessage(height);
        }
        
        // Update immediately after load
        window.addEventListener('load', updateHeight);
        
        // Update when window is resized
        window.addEventListener('resize', updateHeight);
        
        // Add listener for all images to check when they're loaded
        document.addEventListener('DOMContentLoaded', function() {
            var images = document.querySelectorAll('img');
            for (var i = 0; i < images.length; i++) {
                if (images[i].complete) {
                    updateHeight();
                } else {
                    images[i].addEventListener('load', updateHeight);
                    images[i].addEventListener('error', updateHeight);
                }
            }
        });
        
        // Update periodically to catch dynamic content changes
        setInterval(updateHeight, 500);
        setTimeout(updateHeight, 100);
        setTimeout(updateHeight, 1000);
        setTimeout(updateHeight, 2000);
        """
        
        let userScript = WKUserScript(source: script, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        nsView.configuration.userContentController.removeAllUserScripts()
        nsView.configuration.userContentController.addUserScript(userScript)
        
        // Set initial height
        nsView.frame.size.height = contentHeight
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var parent: HTMLWebView
        
        init(_ parent: HTMLWebView) {
            self.parent = parent
        }
        
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            // Allow the initial HTML load
            if navigationAction.navigationType == .other {
                decisionHandler(.allow)
                return
            }
            
            // Open external links in browser
            if let url = navigationAction.request.url, navigationAction.navigationType == .linkActivated {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
                return
            }
            
            decisionHandler(.allow)
        }
        
        // Handle height updates from JavaScript
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == "heightUpdate", let height = message.body as? CGFloat {
                DispatchQueue.main.async {
                    // Get the updated height from JavaScript
                    let newHeight = max(height, 800) // Ensure minimum height
                    
                    // Only update if height changed significantly
                    if abs(self.parent.contentHeight - newHeight) > 20 {
                        // Update the WebView's height
                        self.parent.contentHeight = newHeight
                        
                        if let webView = message.webView {
                            webView.frame.size.height = newHeight
                            
                            // Also adjust constraints
                            for constraint in webView.constraints where constraint.firstAttribute == .height {
                                webView.removeConstraint(constraint)
                            }
                            
                            webView.addConstraint(NSLayoutConstraint(
                                item: webView,
                                attribute: .height,
                                relatedBy: .equal,
                                toItem: nil,
                                attribute: .notAnAttribute,
                                multiplier: 1.0,
                                constant: newHeight
                            ))
                            
                            // Force layout update
                            webView.needsLayout = true
                        }
                    }
                }
            }
        }
    }
}
#else
struct HTMLWebView: UIViewRepresentable {
    let htmlContent: String
    @State private var contentHeight: CGFloat = 800
    
    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let preferences = WKPreferences()
        preferences.javaScriptEnabled = true
        config.preferences = preferences
        
        let userContentController = WKUserContentController()
        userContentController.add(context.coordinator, name: "heightUpdate")
        config.userContentController = userContentController
        
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = false
        webView.scrollView.bounces = true
        webView.scrollView.isScrollEnabled = true // Enable scrolling for longer content
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        
        return webView
    }
    
    func updateUIView(_ uiView: WKWebView, context: Context) {
        // Load the HTML content
        uiView.loadHTMLString(htmlContent, baseURL: nil)
        
        // Inject JS to measure content height
        let script = """
        function updateHeight() {
            var body = document.body;
            var html = document.documentElement;
            
            // Get the max of body and html height to handle different browser rendering
            var height = Math.max(
                body.scrollHeight, body.offsetHeight, 
                html.clientHeight, html.scrollHeight, html.offsetHeight
            );
            
            // Ensure we have a minimum reasonable height
            height = Math.max(height, 800);
            
            window.webkit.messageHandlers.heightUpdate.postMessage(height);
        }
        
        // Update immediately after load
        window.addEventListener('load', updateHeight);
        
        // Update when window is resized
        window.addEventListener('resize', updateHeight);
        
        // Add listener for all images to check when they're loaded
        document.addEventListener('DOMContentLoaded', function() {
            var images = document.querySelectorAll('img');
            for (var i = 0; i < images.length; i++) {
                if (images[i].complete) {
                    updateHeight();
                } else {
                    images[i].addEventListener('load', updateHeight);
                    images[i].addEventListener('error', updateHeight);
                }
            }
        });
        
        // Update periodically to catch dynamic content changes
        setInterval(updateHeight, 500);
        setTimeout(updateHeight, 100);
        setTimeout(updateHeight, 1000);
        setTimeout(updateHeight, 2000);
        """
        
        let userScript = WKUserScript(source: script, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        uiView.configuration.userContentController.removeAllUserScripts()
        uiView.configuration.userContentController.addUserScript(userScript)
        
        // Configure initial size
        uiView.frame.size.height = contentHeight
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var parent: HTMLWebView
        
        init(_ parent: HTMLWebView) {
            self.parent = parent
        }
        
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            // Allow the initial HTML load
            if navigationAction.navigationType == .other {
                decisionHandler(.allow)
                return
            }
            
            // Open external links in browser
            if let url = navigationAction.request.url, navigationAction.navigationType == .linkActivated {
                UIApplication.shared.open(url)
                decisionHandler(.cancel)
                return
            }
            
            decisionHandler(.allow)
        }
        
        // Handle height updates from JavaScript
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == "heightUpdate", let height = message.body as? CGFloat {
                DispatchQueue.main.async {
                    // Get the updated height from JavaScript
                    let newHeight = max(height, 800) // Minimum height
                    
                    // Only update if height changed significantly
                    if abs(self.parent.contentHeight - newHeight) > 20 {
                        self.parent.contentHeight = newHeight
                        
                        // Update the WebView's height
                        if let webView = message.webView as? WKWebView {
                            var frame = webView.frame
                            frame.size.height = newHeight
                            webView.frame = frame
                            
                            // Configure the scrollView for full content display
                            webView.scrollView.contentSize.height = newHeight
                            
                            // Force layout update
                            webView.setNeedsLayout()
                            webView.layoutIfNeeded()
                        }
                    }
                }
            }
        }
    }
}
#endif

// MARK: - Add Subscription View
struct AddSubscriptionView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.presentationMode) var presentationMode
    
    @State private var title = ""
    @State private var url = ""
    @State private var type: SubscriptionType = .rss
    @State private var errorMessage: String?
    
    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Subscription Details")) {
                    TextField("Title", text: $title)
                    TextField(type == .rss ? "Feed URL" : "Subreddit Name", text: $url)
                    Picker("Type", selection: $type) {
                        Text("RSS Feed").tag(SubscriptionType.rss)
                        Text("Reddit").tag(SubscriptionType.reddit)
                    }
                    .pickerStyle(SegmentedPickerStyle())
                }
                if let errorMessage = errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundColor(.red)
                    }
                }
                Section {
                    Button("Add Subscription") {
                        addSubscription()
                    }
                    .disabled(title.isEmpty || url.isEmpty)
                }
            }
            .navigationTitle("Add Subscription")
            #if os(macOS)
            .frame(minWidth: 400, minHeight: 300)
            .padding()
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        presentationMode.wrappedValue.dismiss()
                    }
                }
            }
        }
    }
    
    private func addSubscription() {
        if type == .rss && !url.lowercased().starts(with: "http") {
            errorMessage = "Please enter a valid URL starting with http:// or https://"
            return
        }
        let finalUrl = type == .rss ? url : url.replacingOccurrences(of: "r/", with: "")
        appState.addSubscription(title: title, url: finalUrl, type: type)
        presentationMode.wrappedValue.dismiss()
    }
}

// Replace the ArticleGlassyBackgroundModifier with this enhanced version
struct ArticleGlassyBackgroundModifier: ViewModifier {
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

// Also update the ArticleGlassySummary with enhanced styling
struct ArticleGlassySummary: View {
    let summary: String
    
    var body: some View {
        Text(.init(summary))
            .font(.system(size: 18))
            .lineSpacing(6)
            .padding(.vertical, 16)
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .modifier(ArticleGlassyBackgroundModifier())
    }
}
