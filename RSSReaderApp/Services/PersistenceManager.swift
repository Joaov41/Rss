import Foundation
import Combine

class PersistenceManager {
    private let userDefaults = UserDefaults.standard
    
    // Keys for UserDefaults
    private enum Keys {
        static let subscriptions = "subscriptions"
        static let readArticles = "readArticles"
        static let favoriteArticles = "favoriteArticles"
        static let readRedditPosts = "readRedditPosts"
        static let favoriteRedditPosts = "favoriteRedditPosts"
        static let settings = "settings"
    }
    
    // MARK: - Subscriptions
    func saveSubscriptions(_ subscriptions: [Subscription]) {
        if let encoded = try? JSONEncoder().encode(subscriptions) {
            userDefaults.set(encoded, forKey: Keys.subscriptions)
        }
    }
    
    func loadSubscriptions() -> [Subscription] {
        guard let data = userDefaults.data(forKey: Keys.subscriptions),
              let subscriptions = try? JSONDecoder().decode([Subscription].self, from: data) else {
            return getDefaultSubscriptions()
        }
        return subscriptions
    }
    
    // MARK: - Article Read Status
    func markArticleAsRead(_ articleId: String) {
        var readArticles = getReadArticles()
        readArticles.insert(articleId)
        if let encoded = try? JSONEncoder().encode(Array(readArticles)) {
            userDefaults.set(encoded, forKey: Keys.readArticles)
        }
    }
    
    func isArticleRead(_ articleId: String) -> Bool {
        return getReadArticles().contains(articleId)
    }
    
    private func getReadArticles() -> Set<String> {
        guard let data = userDefaults.data(forKey: Keys.readArticles),
              let articleIds = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return Set(articleIds)
    }
    
    // MARK: - Article Favorites
    func addFavoriteArticle(_ articleId: String) {
        var favorites = getFavoriteArticles()
        favorites.insert(articleId)
        if let encoded = try? JSONEncoder().encode(Array(favorites)) {
            userDefaults.set(encoded, forKey: Keys.favoriteArticles)
        }
    }
    
    func removeFavoriteArticle(_ articleId: String) {
        var favorites = getFavoriteArticles()
        favorites.remove(articleId)
        if let encoded = try? JSONEncoder().encode(Array(favorites)) {
            userDefaults.set(encoded, forKey: Keys.favoriteArticles)
        }
    }
    
    func isArticleFavorite(_ articleId: String) -> Bool {
        return getFavoriteArticles().contains(articleId)
    }
    
    private func getFavoriteArticles() -> Set<String> {
        guard let data = userDefaults.data(forKey: Keys.favoriteArticles),
              let articleIds = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return Set(articleIds)
    }
    
    // MARK: - Reddit Post Read Status
    func markRedditPostAsRead(_ postId: String) {
        var readPosts = getReadRedditPosts()
        readPosts.insert(postId)
        if let encoded = try? JSONEncoder().encode(Array(readPosts)) {
            userDefaults.set(encoded, forKey: Keys.readRedditPosts)
        }
    }
    
    func isRedditPostRead(_ postId: String) -> Bool {
        return getReadRedditPosts().contains(postId)
    }
    
    private func getReadRedditPosts() -> Set<String> {
        guard let data = userDefaults.data(forKey: Keys.readRedditPosts),
              let postIds = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return Set(postIds)
    }
    
    // MARK: - Reddit Post Favorites
    func addFavoriteRedditPost(_ postId: String) {
        var favorites = getFavoriteRedditPosts()
        favorites.insert(postId)
        if let encoded = try? JSONEncoder().encode(Array(favorites)) {
            userDefaults.set(encoded, forKey: Keys.favoriteRedditPosts)
        }
    }
    
    func removeFavoriteRedditPost(_ postId: String) {
        var favorites = getFavoriteRedditPosts()
        favorites.remove(postId)
        if let encoded = try? JSONEncoder().encode(Array(favorites)) {
            userDefaults.set(encoded, forKey: Keys.favoriteRedditPosts)
        }
    }
    
    func isRedditPostFavorite(_ postId: String) -> Bool {
        return getFavoriteRedditPosts().contains(postId)
    }
    
    private func getFavoriteRedditPosts() -> Set<String> {
        guard let data = userDefaults.data(forKey: Keys.favoriteRedditPosts),
              let postIds = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return Set(postIds)
    }
    
    // MARK: - Settings
    func saveSettings(_ settings: AppSettings) {
        if let encoded = try? JSONEncoder().encode(settings) {
            userDefaults.set(encoded, forKey: Keys.settings)
        }
    }
    
    func loadSettings() -> AppSettings {
        guard let data = userDefaults.data(forKey: Keys.settings),
              let settings = try? JSONDecoder().decode(AppSettings.self, from: data) else {
            return AppSettings()
        }
        return settings
    }
    
    // MARK: - Default Data
    private func getDefaultSubscriptions() -> [Subscription] {
        return [
            Subscription(title: "Apple News", url: "https://www.apple.com/newsroom/rss-feed.rss", type: .rss),
            Subscription(title: "Swift", url: "swift", type: .reddit),
            Subscription(title: "BBC News", url: "http://feeds.bbci.co.uk/news/rss.xml", type: .rss),
            Subscription(title: "iOS Programming", url: "iOSProgramming", type: .reddit)
        ]
    }
}
