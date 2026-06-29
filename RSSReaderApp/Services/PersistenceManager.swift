import Foundation
import Combine

final class PersistenceManager {
    static let shared = PersistenceManager()

    private let userDefaults = UserDefaults.standard
    private let cloudSync = CloudSyncManager.shared

    // Cache for merged read/favorite states (local + cloud)
    private var cachedReadArticles: Set<String>?
    private var cachedFavoriteArticles: Set<String>?
    private var cachedReadRedditPosts: Set<String>?
    private var cachedFavoriteRedditPosts: Set<String>?
    private var cachedSubscriptions: [Subscription]?

    // Keys for UserDefaults
    private enum Keys {
        static let subscriptions = "subscriptions"
        static let readArticles = "readArticles"
        static let favoriteArticles = "favoriteArticles"
        static let readRedditPosts = "readRedditPosts"
        static let favoriteRedditPosts = "favoriteRedditPosts"
        static let settings = "settings"
    }

    private init() {
        // Merge local and cloud states on init
        performInitialCloudMerge()
    }

	// MARK: - Cloud Sync Integration

	/// Pull-only merge: reads from cloud and updates local cache, but does NOT write back to cloud.
	/// Use this for polling to avoid race conditions that could overwrite other devices' changes.
	func pullFromCloud() {
		cloudSync.forceSynchronize()

		// Polling path: preserve local read marks immediately while incorporating cloud.
		// Manual sync remains cloud-authoritative.
		let localReadArticles = getLocalReadArticles()
		let cloudReadArticles = normalizeIDs(cloudSync.getCloudReadArticles())
		let effectiveReadArticles = normalizeIDs(localReadArticles.union(cloudReadArticles))
		if effectiveReadArticles != localReadArticles {
			saveLocalReadArticles(effectiveReadArticles)
		}
		cachedReadArticles = effectiveReadArticles

		// Polling path: preserve local read marks immediately while incorporating cloud.
		let localReadPosts = getLocalReadRedditPosts()
		let cloudReadPosts = normalizeIDs(cloudSync.getCloudReadRedditPosts())
		let effectiveReadPosts = normalizeIDs(localReadPosts.union(cloudReadPosts))
		if effectiveReadPosts != localReadPosts {
			saveLocalReadRedditPosts(effectiveReadPosts)
		}
		cachedReadRedditPosts = effectiveReadPosts
	}

	/// User-initiated "Sync Now": pull latest cloud state and reapply locally.
	/// Read-state is cloud-authoritative so all devices converge on the same unread counts.
	func manualPullFromCloud() {
		cloudSync.forceSynchronize()

		// IMPORTANT: Normalize all IDs for consistent cache lookups
		let localReadArticles = getLocalReadArticles()
		let cloudReadArticles = normalizeIDs(cloudSync.getCloudReadArticles())
		let effectiveReadArticles = cloudReadArticles.isEmpty ? localReadArticles : cloudReadArticles
		if effectiveReadArticles != localReadArticles {
			saveLocalReadArticles(effectiveReadArticles)
		}
		cachedReadArticles = effectiveReadArticles

		let localFavArticles = getLocalFavoriteArticles()
		let cloudFavArticles = normalizeIDs(cloudSync.getCloudFavoriteArticles())
		let mergedFavArticles = normalizeIDs(localFavArticles.union(cloudFavArticles))
		if mergedFavArticles != localFavArticles {
			saveLocalFavoriteArticles(mergedFavArticles)
		}
		cachedFavoriteArticles = mergedFavArticles

		let localReadPosts = getLocalReadRedditPosts()
		let cloudReadPosts = normalizeIDs(cloudSync.getCloudReadRedditPosts())
		let effectiveReadPosts = cloudReadPosts.isEmpty ? localReadPosts : cloudReadPosts
		if effectiveReadPosts != localReadPosts {
			saveLocalReadRedditPosts(effectiveReadPosts)
		}
		cachedReadRedditPosts = effectiveReadPosts

		let localFavPosts = getLocalFavoriteRedditPosts()
		let cloudFavPosts = normalizeIDs(cloudSync.getCloudFavoriteRedditPosts())
		let mergedFavPosts = normalizeIDs(localFavPosts.union(cloudFavPosts))
		if mergedFavPosts != localFavPosts {
			saveLocalFavoriteRedditPosts(mergedFavPosts)
		}
		cachedFavoriteRedditPosts = mergedFavPosts

		// Subscriptions: secondary devices should pull from cloud; primary ignores cloud.
		let localSubs = loadSubscriptionsFromLocal()
		let cloudSubs = cloudSync.getCloudSubscriptions()
		if cloudSync.isThisDevicePrimary {
			cachedSubscriptions = localSubs
		} else if !cloudSubs.isEmpty {
			saveSubscriptionsToLocal(cloudSubs)
			cachedSubscriptions = cloudSubs
		} else {
			// Cloud empty: keep local as a fallback.
			cachedSubscriptions = localSubs
		}
	}

	    func performInitialCloudMerge() {
			// Force sync to get latest from cloud
			cloudSync.forceSynchronize()

        // IMPORTANT: Normalize all IDs for consistent cache lookups

        // Merge read articles
        let localReadArticles = getLocalReadArticles()
	        let cloudReadArticles = normalizeIDs(cloudSync.getCloudReadArticles())
        let effectiveReadArticles = cloudReadArticles.isEmpty ? localReadArticles : cloudReadArticles
        if effectiveReadArticles != localReadArticles {
            saveLocalReadArticles(effectiveReadArticles)
        }
        cachedReadArticles = effectiveReadArticles

        // Merge favorite articles
        let localFavArticles = getLocalFavoriteArticles()
        let cloudFavArticles = normalizeIDs(cloudSync.getCloudFavoriteArticles())
        let mergedFavArticles = normalizeIDs(cloudSync.mergeReadStates(local: localFavArticles, cloud: cloudFavArticles))
        if mergedFavArticles != localFavArticles {
            saveLocalFavoriteArticles(mergedFavArticles)
        }
        if mergedFavArticles != cloudFavArticles {
            cloudSync.syncFavoriteArticles(mergedFavArticles)
        }
        cachedFavoriteArticles = mergedFavArticles

        // Merge read Reddit posts
        let localReadPosts = getLocalReadRedditPosts()
	        let cloudReadPosts = normalizeIDs(cloudSync.getCloudReadRedditPosts())
        let effectiveReadPosts = cloudReadPosts.isEmpty ? localReadPosts : cloudReadPosts
        if effectiveReadPosts != localReadPosts {
            saveLocalReadRedditPosts(effectiveReadPosts)
        }
        cachedReadRedditPosts = effectiveReadPosts

        // Merge favorite Reddit posts
        let localFavPosts = getLocalFavoriteRedditPosts()
        let cloudFavPosts = normalizeIDs(cloudSync.getCloudFavoriteRedditPosts())
        let mergedFavPosts = normalizeIDs(cloudSync.mergeReadStates(local: localFavPosts, cloud: cloudFavPosts))
        if mergedFavPosts != localFavPosts {
            saveLocalFavoriteRedditPosts(mergedFavPosts)
        }
        if mergedFavPosts != cloudFavPosts {
            cloudSync.syncFavoriteRedditPosts(mergedFavPosts)
        }
        cachedFavoriteRedditPosts = mergedFavPosts

        // Sync subscriptions based on primary device model
        let localSubs = loadSubscriptionsFromLocal()
        let cloudSubs = cloudSync.getCloudSubscriptions()

        if cloudSync.isThisDevicePrimary {
            // This device is primary: merge and push to cloud
            let mergedSubs = mergeSubscriptions(local: localSubs, cloud: cloudSubs)
            saveSubscriptionsToLocal(mergedSubs)
            cloudSync.syncSubscriptions(mergedSubs)
            cachedSubscriptions = mergedSubs
            print("☁️ PersistenceManager: Primary device - merged subscriptions")
        } else if cloudSync.hasPrimaryDevice {
            // Another device is primary: use cloud subscriptions as source of truth
            if !cloudSubs.isEmpty {
                saveSubscriptionsToLocal(cloudSubs)
                cachedSubscriptions = cloudSubs
                print("☁️ PersistenceManager: Secondary device - using cloud subscriptions from primary")
            } else {
                // Cloud is empty but primary exists - keep local for now
                cachedSubscriptions = localSubs
                print("☁️ PersistenceManager: Secondary device - cloud empty, keeping local")
            }
        } else {
            // No primary device set yet: just use local, don't push to cloud
            // User needs to designate a primary device in Settings
            cachedSubscriptions = localSubs
            print("☁️ PersistenceManager: No primary device set - using local subscriptions only")
        }

        print("☁️ PersistenceManager: Initial cloud merge complete")
        print("   Local articles: \(localReadArticles.count), Cloud: \(cloudReadArticles.count), Active: \(effectiveReadArticles.count)")
        print("   Local Reddit: \(localReadPosts.count), Cloud: \(cloudReadPosts.count), Active: \(effectiveReadPosts.count)")
        print("   Local subscriptions: \(localSubs.count), Cloud: \(cloudSubs.count), Active: \(cachedSubscriptions?.count ?? 0)")
    }

    /// Call this when remote changes are received to update local cache.
    /// Remote updates merge with local so freshly-read badges don't regress.
    func handleRemoteReadArticlesChange(_ ids: Set<String>) {
        let normalizedIds = normalizeIDs(ids)
        let local = getLocalReadArticles()
        let merged = normalizeIDs(local.union(normalizedIds))
        saveLocalReadArticles(merged)
        cachedReadArticles = merged
        print("☁️ PersistenceManager: Applied \(ids.count) cloud articles → local cache now has \(merged.count)")
    }

    func handleRemoteFavoriteArticlesChange(_ ids: Set<String>) {
        let normalizedIds = normalizeIDs(ids)
        let local = getLocalFavoriteArticles()
        let merged = cloudSync.mergeReadStates(local: local, cloud: normalizedIds)
        let normalizedMerged = normalizeIDs(merged)
        saveLocalFavoriteArticles(normalizedMerged)
        cachedFavoriteArticles = normalizedMerged
    }

    /// Remote updates merge with local so freshly-read badges don't regress.
    func handleRemoteReadRedditPostsChange(_ ids: Set<String>) {
        let normalizedIds = normalizeIDs(ids)
        let local = getLocalReadRedditPosts()
        let merged = normalizeIDs(local.union(normalizedIds))
        saveLocalReadRedditPosts(merged)
        cachedReadRedditPosts = merged
        print("☁️ PersistenceManager: Applied \(ids.count) cloud Reddit posts → local cache now has \(merged.count)")
    }

    func handleRemoteFavoriteRedditPostsChange(_ ids: Set<String>) {
        let normalizedIds = normalizeIDs(ids)
        let local = getLocalFavoriteRedditPosts()
        let merged = cloudSync.mergeReadStates(local: local, cloud: normalizedIds)
        let normalizedMerged = normalizeIDs(merged)
        saveLocalFavoriteRedditPosts(normalizedMerged)
        cachedFavoriteRedditPosts = normalizedMerged
    }

    func handleRemoteSubscriptionsChange(_ subscriptions: [Subscription]) {
        // Only accept remote subscription changes if we're not the primary device
        if cloudSync.isThisDevicePrimary {
            print("☁️ PersistenceManager: Ignoring remote subscription change - this device is primary")
            return
        }

        // Secondary device: accept cloud subscriptions as source of truth
        if !subscriptions.isEmpty {
            saveSubscriptionsToLocal(subscriptions)
            cachedSubscriptions = subscriptions
            print("☁️ PersistenceManager: Updated local subscriptions from primary device")
        }
    }

    // MARK: - Local Storage Helpers

    private func getLocalReadArticles() -> Set<String> {
        if let data = userDefaults.data(forKey: Keys.readArticles),
           let articleIds = try? JSONDecoder().decode([String].self, from: data) {
            return Set(articleIds)
        }

        // Backwards compatibility: older builds may have stored arrays directly.
        if let articleIds = userDefaults.array(forKey: Keys.readArticles) as? [String] {
            return Set(articleIds)
        }

        return []
    }

    private func saveLocalReadArticles(_ ids: Set<String>) {
        let normalized = normalizeIDs(ids)
        if let encoded = try? JSONEncoder().encode(Array(normalized)) {
            userDefaults.set(encoded, forKey: Keys.readArticles)
        }
    }

    private func getLocalFavoriteArticles() -> Set<String> {
        if let data = userDefaults.data(forKey: Keys.favoriteArticles),
           let articleIds = try? JSONDecoder().decode([String].self, from: data) {
            return Set(articleIds)
        }

        // Backwards compatibility: older builds may have stored arrays directly.
        if let articleIds = userDefaults.array(forKey: Keys.favoriteArticles) as? [String] {
            return Set(articleIds)
        }

        return []
    }

    private func saveLocalFavoriteArticles(_ ids: Set<String>) {
        let normalized = normalizeIDs(ids)
        if let encoded = try? JSONEncoder().encode(Array(normalized)) {
            userDefaults.set(encoded, forKey: Keys.favoriteArticles)
        }
    }

    private func getLocalReadRedditPosts() -> Set<String> {
        if let data = userDefaults.data(forKey: Keys.readRedditPosts),
           let postIds = try? JSONDecoder().decode([String].self, from: data) {
            return Set(postIds)
        }

        // Backwards compatibility: older builds may have stored arrays directly.
        if let postIds = userDefaults.array(forKey: Keys.readRedditPosts) as? [String] {
            return Set(postIds)
        }

        return []
    }

    private func saveLocalReadRedditPosts(_ ids: Set<String>) {
        let normalized = normalizeIDs(ids)
        if let encoded = try? JSONEncoder().encode(Array(normalized)) {
            userDefaults.set(encoded, forKey: Keys.readRedditPosts)
        }
    }

    private func getLocalFavoriteRedditPosts() -> Set<String> {
        if let data = userDefaults.data(forKey: Keys.favoriteRedditPosts),
           let postIds = try? JSONDecoder().decode([String].self, from: data) {
            return Set(postIds)
        }

        // Backwards compatibility: older builds may have stored arrays directly.
        if let postIds = userDefaults.array(forKey: Keys.favoriteRedditPosts) as? [String] {
            return Set(postIds)
        }

        return []
    }

    private func saveLocalFavoriteRedditPosts(_ ids: Set<String>) {
        let normalized = normalizeIDs(ids)
        if let encoded = try? JSONEncoder().encode(Array(normalized)) {
            userDefaults.set(encoded, forKey: Keys.favoriteRedditPosts)
        }
    }
    
    // MARK: - Subscriptions

    /// Save subscriptions locally and sync to cloud (if this device is primary)
    func saveSubscriptions(_ subscriptions: [Subscription]) {
        saveSubscriptionsToLocal(subscriptions)
        cachedSubscriptions = subscriptions
        // Only syncs if this device is primary (checked inside syncSubscriptions)
        cloudSync.syncSubscriptions(subscriptions)
    }

    /// Load subscriptions (from cache or local storage)
    func loadSubscriptions() -> [Subscription] {
        if let cached = cachedSubscriptions {
            return cached
        }
        return loadSubscriptionsFromLocal()
    }

    /// Save subscriptions to local storage only (no cloud sync)
    private func saveSubscriptionsToLocal(_ subscriptions: [Subscription]) {
        if let encoded = try? JSONEncoder().encode(subscriptions) {
            userDefaults.set(encoded, forKey: Keys.subscriptions)
        }
    }

    /// Load subscriptions from local storage only
    private func loadSubscriptionsFromLocal() -> [Subscription] {
        guard let data = userDefaults.data(forKey: Keys.subscriptions),
              let subscriptions = try? JSONDecoder().decode([Subscription].self, from: data) else {
            return getDefaultSubscriptions()
        }
        return subscriptions
    }

    /// Set this device as primary and push current subscriptions to cloud
    func setThisDeviceAsPrimaryForSubscriptions() {
        cloudSync.setThisDeviceAsPrimary()
        // Force push current local subscriptions to cloud
        let currentSubs = loadSubscriptions()
        cloudSync.forceSyncSubscriptions(currentSubs)
        print("☁️ PersistenceManager: Set as primary and pushed \(currentSubs.count) subscriptions")
    }

    /// Check if this device is the primary for subscriptions
    var isThisDevicePrimaryForSubscriptions: Bool {
        return cloudSync.isThisDevicePrimary
    }

    /// Get the name of the primary device (if any)
    var primaryDeviceNameForSubscriptions: String? {
        return cloudSync.primaryDeviceName
    }

    /// Check if any device is set as primary
    var hasPrimaryDeviceForSubscriptions: Bool {
        return cloudSync.hasPrimaryDevice
    }

    /// Get this device's name
    var thisDeviceName: String {
        return cloudSync.thisDeviceName
    }
    
	    // MARK: - Article Read Status
	    func markArticleAsRead(_ article: Article) {
	        markArticleAsRead(tokens: articleReadTokens(for: article), diagnosticID: article.id)
	    }

	    func markArticleAsRead(_ articleId: String) {
	        markArticleAsRead(tokens: articleReadTokens(articleId: articleId, articleURL: nil), diagnosticID: articleId)
	    }

    func isArticleRead(_ article: Article) -> Bool {
        isArticleRead(tokens: articleReadTokens(for: article))
    }

    func isArticleRead(_ articleId: String) -> Bool {
        isArticleRead(tokens: articleReadTokens(articleId: articleId, articleURL: nil))
    }

    private func getReadArticles() -> Set<String> {
        return cachedReadArticles ?? getLocalReadArticles()
    }
    
    // MARK: - Article Favorites
    func addFavoriteArticle(_ articleId: String) {
        var favorites = cachedFavoriteArticles ?? getLocalFavoriteArticles()
        favorites.insert(ArticleIDNormalizer.normalize(articleId))
        saveLocalFavoriteArticles(favorites)
        cachedFavoriteArticles = favorites
        // Sync to cloud
        cloudSync.syncFavoriteArticles(favorites)
    }

    func removeFavoriteArticle(_ articleId: String) {
        var favorites = cachedFavoriteArticles ?? getLocalFavoriteArticles()
        favorites.remove(ArticleIDNormalizer.normalize(articleId))
        saveLocalFavoriteArticles(favorites)
        cachedFavoriteArticles = favorites
        // Sync to cloud
        cloudSync.syncFavoriteArticles(favorites)
    }

    func isArticleFavorite(_ articleId: String) -> Bool {
        let normalized = ArticleIDNormalizer.normalize(articleId)
        return (cachedFavoriteArticles ?? getLocalFavoriteArticles()).contains(normalized)
    }

    private func getFavoriteArticles() -> Set<String> {
        return cachedFavoriteArticles ?? getLocalFavoriteArticles()
    }
    
	    // MARK: - Reddit Post Read Status
	    func markRedditPostAsRead(_ post: RedditPost) {
	        markRedditPostAsRead(tokens: redditReadTokens(for: post), diagnosticID: post.id)
	    }

	    func markRedditPostAsRead(_ postId: String) {
	        markRedditPostAsRead(tokens: redditReadTokens(postId: postId, subreddit: nil), diagnosticID: postId)
	    }

    func isRedditPostRead(_ post: RedditPost) -> Bool {
        isRedditPostRead(tokens: redditReadTokens(for: post))
    }

    func isRedditPostRead(_ postId: String) -> Bool {
        isRedditPostRead(tokens: redditReadTokens(postId: postId, subreddit: nil))
    }

    private func getReadRedditPosts() -> Set<String> {
        return cachedReadRedditPosts ?? getLocalReadRedditPosts()
    }

    /// Backfill richer read tokens for already-read visible items so future ID variants stay read.
    /// Returns how many new tokens were added for each content type.
    @discardableResult
    func backfillReadTokensIfNeeded(articles: [Article], posts: [RedditPost]) -> (addedArticleTokens: Int, addedRedditTokens: Int) {
        var readArticles = cachedReadArticles ?? getLocalReadArticles()
        var readPosts = cachedReadRedditPosts ?? getLocalReadRedditPosts()

        var articleTokensToSync: Set<String> = []
        var redditTokensToSync: Set<String> = []
        var addedArticleTokens = 0
        var addedRedditTokens = 0

        for article in articles where article.isRead {
            let tokens = articleReadTokens(for: article)
            let missing = tokens.subtracting(readArticles)
            guard !missing.isEmpty else { continue }
            readArticles.formUnion(missing)
            articleTokensToSync.formUnion(missing)
            addedArticleTokens += missing.count
        }

        for post in posts where post.isRead {
            let tokens = redditReadTokens(for: post)
            let missing = tokens.subtracting(readPosts)
            guard !missing.isEmpty else { continue }
            readPosts.formUnion(missing)
            redditTokensToSync.formUnion(missing)
            addedRedditTokens += missing.count
        }

        if addedArticleTokens > 0 {
            saveLocalReadArticles(readArticles)
            cachedReadArticles = readArticles
            cloudSync.syncReadArticles(articleTokensToSync)
        }

        if addedRedditTokens > 0 {
            saveLocalReadRedditPosts(readPosts)
            cachedReadRedditPosts = readPosts
            cloudSync.syncReadRedditPosts(redditTokensToSync)
        }

        return (addedArticleTokens, addedRedditTokens)
    }
    
    // MARK: - Reddit Post Favorites
    func addFavoriteRedditPost(_ postId: String) {
        var favorites = cachedFavoriteRedditPosts ?? getLocalFavoriteRedditPosts()
        favorites.insert(ArticleIDNormalizer.normalize(postId))
        saveLocalFavoriteRedditPosts(favorites)
        cachedFavoriteRedditPosts = favorites
        // Sync to cloud
        cloudSync.syncFavoriteRedditPosts(favorites)
    }

    func removeFavoriteRedditPost(_ postId: String) {
        var favorites = cachedFavoriteRedditPosts ?? getLocalFavoriteRedditPosts()
        favorites.remove(ArticleIDNormalizer.normalize(postId))
        saveLocalFavoriteRedditPosts(favorites)
        cachedFavoriteRedditPosts = favorites
        // Sync to cloud
        cloudSync.syncFavoriteRedditPosts(favorites)
    }

    func isRedditPostFavorite(_ postId: String) -> Bool {
        let normalized = ArticleIDNormalizer.normalize(postId)
        return (cachedFavoriteRedditPosts ?? getLocalFavoriteRedditPosts()).contains(normalized)
    }

    private func getFavoriteRedditPosts() -> Set<String> {
        return cachedFavoriteRedditPosts ?? getLocalFavoriteRedditPosts()
    }
    
    // MARK: - Settings
    func saveSettings(_ settings: AppSettings) {
        persistSummarizeSecrets(settings)
        if let encoded = try? JSONEncoder().encode(settings) {
            userDefaults.set(encoded, forKey: Keys.settings)
        }
    }
    
    func loadSettings() -> AppSettings {
        guard let data = userDefaults.data(forKey: Keys.settings),
              let settings = try? JSONDecoder().decode(AppSettings.self, from: data) else {
            return hydrateSummarizeSettings(AppSettings())
        }
        return hydrateSummarizeSettings(settings)
    }

    private func hydrateSummarizeSettings(_ settings: AppSettings) -> AppSettings {
        var hydrated = settings

        hydrated.summarizeDaemonHost = AppSettings.sanitizedSummarizeHost(hydrated.summarizeDaemonHost)
        hydrated.summarizeDaemonPort = AppSettings.sanitizedSummarizePort(hydrated.summarizeDaemonPort, fallback: 8787)
        hydrated.summarizeDaemonModel = AppSettings.normalizedSummarizeDaemonModel(hydrated.summarizeDaemonModel)
        hydrated.summarizeBridgeHost = AppSettings.sanitizedSummarizeHost(
            userDefaults.string(forKey: "macBridgeHost") ?? hydrated.summarizeBridgeHost
        )
        hydrated.summarizeBridgePort = AppSettings.sanitizedSummarizePort(
            userDefaults.object(forKey: "macBridgePort") as? Int ?? hydrated.summarizeBridgePort,
            fallback: AppSettings.defaultSummarizeBridgePort
        )
        hydrated.pccGatewayHost = AppSettings.sanitizedSummarizeHost(
            userDefaults.string(forKey: "pccGatewayHost") ?? hydrated.pccGatewayHost,
            fallback: AppSettings.defaultPCCGatewayHost
        )
        hydrated.pccGatewayPort = AppSettings.sanitizedSummarizePort(
            userDefaults.object(forKey: "pccGatewayPort") as? Int ?? hydrated.pccGatewayPort,
            fallback: AppSettings.defaultPCCGatewayPort
        )
        hydrated.pccGatewayModel = AppSettings.normalizedPCCGatewayModel(
            userDefaults.string(forKey: "pccGatewayModel") ?? hydrated.pccGatewayModel
        )

        let legacyDaemonToken = userDefaults.string(forKey: "summarizeDaemonToken")
        let keychainDaemonToken = RSSSummarizeKeychain.string(for: RSSSummarizeKeychain.daemonTokenKey)
        let resolvedDaemonToken = RSSSummarizeDaemonTokenResolver.effectiveToken(
            preferred: keychainDaemonToken ?? legacyDaemonToken,
            fallback: hydrated.summarizeDaemonToken
        )
        hydrated.summarizeDaemonToken = resolvedDaemonToken

        let legacyBridgeSecret = userDefaults.string(forKey: "macBridgeSecret")
        let keychainBridgeSecret = RSSSummarizeKeychain.string(for: RSSSummarizeKeychain.bridgeSecretKey)
        let resolvedBridgeSecret = AppSettings.sanitizedSummarizeSecret(
            keychainBridgeSecret ?? legacyBridgeSecret ?? hydrated.summarizeBridgeSecret
        )
        hydrated.summarizeBridgeSecret = resolvedBridgeSecret

        let legacyPCCToken = userDefaults.string(forKey: "pccGatewayToken")
        let keychainPCCToken = RSSSummarizeKeychain.string(for: RSSSummarizeKeychain.pccGatewayTokenKey)
        hydrated.pccGatewayToken = AppSettings.sanitizedSummarizeSecret(
            keychainPCCToken ?? legacyPCCToken ?? hydrated.pccGatewayToken
        )

        return hydrated
    }

    private func persistSummarizeSecrets(_ settings: AppSettings) {
        let daemonToken = AppSettings.sanitizedSummarizeSecret(settings.summarizeDaemonToken)
        RSSSummarizeKeychain.set(daemonToken, for: RSSSummarizeKeychain.daemonTokenKey)
        if daemonToken.isEmpty {
            userDefaults.removeObject(forKey: "summarizeDaemonToken")
        } else {
            userDefaults.set(daemonToken, forKey: "summarizeDaemonToken")
        }

        let bridgeSecret = AppSettings.sanitizedSummarizeSecret(settings.summarizeBridgeSecret)
        RSSSummarizeKeychain.set(bridgeSecret, for: RSSSummarizeKeychain.bridgeSecretKey)
        if bridgeSecret.isEmpty {
            userDefaults.removeObject(forKey: "macBridgeSecret")
        } else {
            userDefaults.set(bridgeSecret, forKey: "macBridgeSecret")
        }

        userDefaults.set(AppSettings.sanitizedSummarizeHost(settings.summarizeBridgeHost), forKey: "macBridgeHost")
        userDefaults.set(AppSettings.sanitizedSummarizePort(settings.summarizeBridgePort, fallback: AppSettings.defaultSummarizeBridgePort), forKey: "macBridgePort")
        userDefaults.set(AppSettings.normalizedSummarizeDaemonModel(settings.summarizeDaemonModel), forKey: "summarizeDaemonModel")

        let pccToken = AppSettings.sanitizedSummarizeSecret(settings.pccGatewayToken)
        RSSSummarizeKeychain.set(pccToken, for: RSSSummarizeKeychain.pccGatewayTokenKey)
        if pccToken.isEmpty {
            userDefaults.removeObject(forKey: "pccGatewayToken")
        } else {
            userDefaults.set(pccToken, forKey: "pccGatewayToken")
        }
        userDefaults.set(
            AppSettings.sanitizedSummarizeHost(settings.pccGatewayHost, fallback: AppSettings.defaultPCCGatewayHost),
            forKey: "pccGatewayHost"
        )
        userDefaults.set(
            AppSettings.sanitizedSummarizePort(settings.pccGatewayPort, fallback: AppSettings.defaultPCCGatewayPort),
            forKey: "pccGatewayPort"
        )
        userDefaults.set(AppSettings.normalizedPCCGatewayModel(settings.pccGatewayModel), forKey: "pccGatewayModel")
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

    // MARK: - Subscription Merge Helpers

    private func mergeSubscriptions(local: [Subscription], cloud: [Subscription]) -> [Subscription] {
        var mergedByURL: [String: Subscription] = [:]

        // Prefer local metadata when present, otherwise use cloud
        for sub in cloud {
            mergedByURL[sub.url] = sub
        }
        for sub in local {
            mergedByURL[sub.url] = sub
        }

        // Return sorted for stable ordering
        return mergedByURL.values.sorted { $0.title.lowercased() < $1.title.lowercased() }
    }

    private func subscriptionsEqual(_ lhs: [Subscription], _ rhs: [Subscription]) -> Bool {
        let lhsSet = Set(lhs.map { "\($0.url)|\($0.type.rawValue)" })
        let rhsSet = Set(rhs.map { "\($0.url)|\($0.type.rawValue)" })
        return lhsSet == rhsSet
    }

    private func normalizeIDs(_ ids: Set<String>) -> Set<String> {
        var normalized: Set<String> = []
        for raw in ids {
            normalized.formUnion(expandedReadTokens(from: raw))
        }
        return normalized
    }

    private func markArticleAsRead(tokens: Set<String>, diagnosticID: String) {
        guard !tokens.isEmpty else { return }
        print("🔍 DIAGNOSTIC: PersistenceManager.markArticleAsRead called - id=\(diagnosticID.prefix(50))")
        var readArticles = cachedReadArticles ?? getLocalReadArticles()
        readArticles.formUnion(tokens)
        saveLocalReadArticles(readArticles)
        cachedReadArticles = readArticles
        // Sync to cloud
        print("🔍 DIAGNOSTIC: About to call cloudSync.syncReadArticles with \(tokens.count) token(s)")
        cloudSync.syncReadArticles(tokens)
        print("🔍 DIAGNOSTIC: cloudSync.syncReadArticles returned")
    }

    private func isArticleRead(tokens: Set<String>) -> Bool {
        guard !tokens.isEmpty else { return false }
        let readArticles = getReadArticles()
        let candidates = normalizeIDs(tokens)
        return !readArticles.isDisjoint(with: candidates)
    }

    private func articleReadTokens(for article: Article) -> Set<String> {
        articleReadTokens(articleId: article.id, articleURL: article.url, title: article.title, feedURL: article.feedURL)
    }

    private func articleReadTokens(articleId: String, articleURL: URL?) -> Set<String> {
        articleReadTokens(articleId: articleId, articleURL: articleURL, title: nil, feedURL: nil)
    }

    private func articleReadTokens(articleId: String, articleURL: URL?, title: String?, feedURL: String?) -> Set<String> {
        var tokens: Set<String> = [ArticleIDNormalizer.normalize(articleId)]
        if let rawURL = articleURL?.absoluteString, !rawURL.isEmpty {
            tokens.insert(rawURL)
        }
        if let canonicalURL = canonicalReadURL(articleURL) {
            tokens.insert(canonicalURL)
        }
        if let title, !title.isEmpty, let feedURL, !feedURL.isEmpty {
            let fallbackHash = "hash-\(djb2Hex("\(title)|\(feedURL)"))"
            tokens.insert(ArticleIDNormalizer.normalize(fallbackHash))
        }
        return normalizeIDs(tokens)
    }

    private func markRedditPostAsRead(tokens: Set<String>, diagnosticID: String) {
        guard !tokens.isEmpty else { return }
        print("🔍 DIAGNOSTIC: PersistenceManager.markRedditPostAsRead called - id=\(diagnosticID.prefix(50))")
        var readPosts = cachedReadRedditPosts ?? getLocalReadRedditPosts()
        readPosts.formUnion(tokens)
        saveLocalReadRedditPosts(readPosts)
        cachedReadRedditPosts = readPosts
        // Sync to cloud
        print("🔍 DIAGNOSTIC: About to call cloudSync.syncReadRedditPosts with \(tokens.count) token(s)")
        cloudSync.syncReadRedditPosts(tokens)
        print("🔍 DIAGNOSTIC: cloudSync.syncReadRedditPosts returned")
    }

    private func isRedditPostRead(tokens: Set<String>) -> Bool {
        guard !tokens.isEmpty else { return false }
        let readPosts = getReadRedditPosts()
        let candidates = normalizeIDs(tokens)
        return !readPosts.isDisjoint(with: candidates)
    }

    private func redditReadTokens(for post: RedditPost) -> Set<String> {
        var tokens = redditReadTokens(postId: post.id, subreddit: post.subreddit)
        if let rawURL = post.url?.absoluteString, !rawURL.isEmpty {
            tokens.insert(rawURL)
        }
        if let canonicalURL = canonicalReadURL(post.url) {
            tokens.insert(canonicalURL)
        }
        return normalizeIDs(tokens)
    }

    private func redditReadTokens(postId: String, subreddit: String?) -> Set<String> {
        let normalizedID = ArticleIDNormalizer.normalize(postId)
        var tokens: Set<String> = [normalizedID]

        if normalizedID.hasPrefix("t3_") {
            tokens.insert(String(normalizedID.dropFirst(3)))
        } else {
            tokens.insert("t3_\(normalizedID)")
        }

        if let subreddit, !subreddit.isEmpty {
            let normalizedSubreddit = subreddit.lowercased()
            let shortID = normalizedID.hasPrefix("t3_") ? String(normalizedID.dropFirst(3)) : normalizedID
            let permalink = "https://www.reddit.com/r/\(normalizedSubreddit)/comments/\(shortID)"
            tokens.insert(permalink)
            tokens.insert("\(permalink)/")
        }

        return normalizeIDs(tokens)
    }

    private func canonicalReadURL(_ url: URL?) -> String? {
        canonicalReadURL(from: url?.absoluteString)
    }

    private func canonicalReadURL(from rawURL: String?) -> String? {
        guard let rawURL,
              !rawURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        // Reuse the global normalizer so we preserve identity-defining query params
        // while still removing volatile tracking parameters.
        let canonical = ArticleIDNormalizer.normalize(rawURL)
        guard !canonical.isEmpty else {
            return nil
        }

        return canonical
    }

    private func expandedReadTokens(from raw: String) -> Set<String> {
        let normalized = ArticleIDNormalizer.normalize(raw)
        guard !normalized.isEmpty else { return [] }

        var tokens: Set<String> = [normalized]
        addRedditIDAliases(from: normalized, into: &tokens)

        if let canonicalURL = canonicalReadURL(from: normalized) {
            tokens.insert(canonicalURL)
            if let redditPermalink = redditPermalinkBase(from: canonicalURL) {
                tokens.insert(redditPermalink)
                tokens.insert("\(redditPermalink)/")
                if let redditPostID = redditPostID(fromPermalink: canonicalURL) {
                    addRedditIDAliases(from: redditPostID, into: &tokens)
                }
            }
        }

        return tokens
    }

    private func addRedditIDAliases(from token: String, into tokens: inout Set<String>) {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if trimmed.hasPrefix("t3_") {
            let short = String(trimmed.dropFirst(3))
            if isLikelyRedditPostID(short) {
                tokens.insert(short)
            }
            return
        }

        if isLikelyRedditPostID(trimmed) {
            tokens.insert("t3_\(trimmed)")
        }
    }

    private func isLikelyRedditPostID(_ token: String) -> Bool {
        guard (4...10).contains(token.count) else { return false }
        return token.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) }
    }

    private func redditPermalinkBase(from token: String) -> String? {
        guard let components = URLComponents(string: token),
              let host = components.host?.lowercased(),
              host.contains("reddit.com") else {
            return nil
        }

        let parts = components.path
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)

        guard parts.count >= 4,
              parts[0].lowercased() == "r",
              parts[2].lowercased() == "comments" else {
            return nil
        }

        let subreddit = parts[1].lowercased()
        let postID = parts[3].hasPrefix("t3_") ? String(parts[3].dropFirst(3)) : parts[3]
        guard !subreddit.isEmpty, isLikelyRedditPostID(postID) else { return nil }
        return ArticleIDNormalizer.normalize("https://www.reddit.com/r/\(subreddit)/comments/\(postID)")
    }

    private func redditPostID(fromPermalink token: String) -> String? {
        guard let components = URLComponents(string: token),
              let host = components.host?.lowercased(),
              host.contains("reddit.com") else {
            return nil
        }

        let parts = components.path
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)

        guard parts.count >= 4,
              parts[0].lowercased() == "r",
              parts[2].lowercased() == "comments" else {
            return nil
        }

        let candidate = parts[3].hasPrefix("t3_") ? String(parts[3].dropFirst(3)) : parts[3]
        return isLikelyRedditPostID(candidate) ? candidate : nil
    }

    private func djb2Hex(_ string: String) -> String {
        var hash: UInt64 = 5381
        for byte in string.utf8 {
            hash = ((hash << 5) &+ hash) &+ UInt64(byte)
        }
        return String(hash, radix: 16)
    }
}
