import Foundation
import Combine

final class PersistenceManager {
    static let shared = PersistenceManager()

    private let userDefaults = UserDefaults.standard
    private let cloudSync = CloudSyncManager.shared
    private let cloudKit = CloudKitSyncManager.shared

    // Cache for merged read/favorite states (local + cloud)
    private var cachedReadArticles: Set<String>?
    private var cachedFavoriteArticles: Set<String>?
    private var cachedReadRedditPosts: Set<String>?
    private var cachedFavoriteRedditPosts: Set<String>?
    private var cachedSubscriptions: [Subscription]?

    private final class TokenSetCacheEntry {
        let tokens: Set<String>

        init(tokens: Set<String>) {
            self.tokens = tokens
        }
    }

    // NSCache is thread-safe and keeps repeated article/post probes from
    // re-running URL canonicalization and Reddit alias expansion.
    private let expandedReadTokenCache: NSCache<NSString, TokenSetCacheEntry> = {
        let cache = NSCache<NSString, TokenSetCacheEntry>()
        cache.countLimit = 4_096
        cache.totalCostLimit = 4 * 1024 * 1024
        return cache
    }()
    private let normalizedTokenCache: NSCache<NSString, NSString> = {
        let cache = NSCache<NSString, NSString>()
        cache.countLimit = 4_096
        cache.totalCostLimit = 1 * 1024 * 1024
        return cache
    }()

    // Keys for UserDefaults
    private enum Keys {
        static let subscriptions = "subscriptions"
        static let savedPodcastSubscriptions = "RSSReaderApp.SavedPodcastSubscriptions.v1"
        static let podcastSubscriptionCanonicalKeys = "RSSReaderApp.PodcastSubscriptionCanonicalKeys.v1"
        static let readArticles = "readArticles"
        static let favoriteArticles = "favoriteArticles"
        static let readRedditPosts = "readRedditPosts"
        static let favoriteRedditPosts = "favoriteRedditPosts"
        static let settings = "settings"
        /// Once per device: local favorites/subscriptions recorded in the per-item iCloud format.
        static let seededCloudRecordsV2 = "cloudSync.seededRecordsV2"
        /// Items removed on this device or through CloudKit, so stale key-value data can't bring them back.
        static let tombstonesFavoriteArticles = "cloudKit.tombstones.favoriteArticles"
        static let tombstonesFavoriteReddit = "cloudKit.tombstones.favoriteReddit"
        static let tombstonesSubscriptions = "cloudKit.tombstones.subscriptions"
    }

    private init() {
        // Merge local and cloud states on init
        performInitialCloudMerge()

        #if os(iOS)
        cloudKit.initialUploadProvider = { [unowned self] in
            CloudKitInitialUpload(
                readArticles: self.getReadArticles(),
                readRedditPosts: self.getReadRedditPosts(),
                favoriteArticles: self.getFavoriteArticles(),
                favoriteRedditPosts: self.getFavoriteRedditPosts(),
                // A list that is only the built-in defaults (fresh install) is not uploaded.
                subscriptions: self.isOnlyDefaultSubscriptions(self.loadSubscriptions()) ? [] : self.loadSubscriptions()
            )
        }
        cloudKit.start()
        #endif
    }

    struct CloudPollReadState {
        let readArticleTokens: Set<String>
        let readRedditTokens: Set<String>
        let didArticleSetChange: Bool
        let didRedditSetChange: Bool
    }

		// MARK: - Cloud Sync Integration

		/// Pull-only merge: reads from cloud and updates local cache, but does NOT write back to cloud.
		/// Use this for polling to avoid race conditions that could overwrite other devices' changes.
		func pullFromCloud() {
			let readState = pullFromCloudReadState()
			applyCloudPollReadState(readState)
		}

    /// Computes read-state union for polling. Safe to call off the main thread.
    /// This method does not mutate local cache/state; call `applyCloudPollReadState(_:)` on main to commit.
    func pullFromCloudReadState() -> CloudPollReadState {
        cloudSync.forceSynchronize()

        let normalizedLocalReadArticles = normalizeIDs(getLocalReadArticles())
        let cloudReadArticles = normalizeIDs(cloudSync.getCloudReadArticles())
        let effectiveReadArticles = normalizeIDs(normalizedLocalReadArticles.union(cloudReadArticles))

        let normalizedLocalReadPosts = normalizeIDs(getLocalReadRedditPosts())
        let cloudReadPosts = normalizeIDs(cloudSync.getCloudReadRedditPosts())
        let effectiveReadPosts = normalizeIDs(normalizedLocalReadPosts.union(cloudReadPosts))

        return CloudPollReadState(
            readArticleTokens: effectiveReadArticles,
            readRedditTokens: effectiveReadPosts,
            didArticleSetChange: effectiveReadArticles != normalizedLocalReadArticles,
            didRedditSetChange: effectiveReadPosts != normalizedLocalReadPosts
        )
    }

    /// Applies a previously computed poll read-state snapshot.
    func applyCloudPollReadState(_ readState: CloudPollReadState) {
        if readState.didArticleSetChange {
            saveLocalReadArticles(readState.readArticleTokens)
        }
        cachedReadArticles = readState.readArticleTokens

        if readState.didRedditSetChange {
            saveLocalReadRedditPosts(readState.readRedditTokens)
        }
        cachedReadRedditPosts = readState.readRedditTokens
    }

    /// User-initiated "Sync Now": pull latest cloud state and reapply locally.
    /// Read-state is cloud-authoritative so all devices converge on the same unread counts.
    @discardableResult
    func manualPullFromCloud(synchronize: Bool = true) -> Bool {
		if synchronize {
			cloudSync.forceSynchronize()
		}
		var didChangeSubscriptions = false

		// IMPORTANT: Normalize all IDs for consistent cache lookups
		seedCloudRecordsIfReady()

		// Read state: combine local and iCloud, so reads that never reached iCloud are kept.
		let localReadArticles = getLocalReadArticles()
		let effectiveReadArticles = normalizeIDs(localReadArticles.union(cloudSync.getCloudReadArticles()))
		if effectiveReadArticles != localReadArticles {
			saveLocalReadArticles(effectiveReadArticles)
		}
		cachedReadArticles = effectiveReadArticles

		let localFavArticles = getLocalFavoriteArticles()
		let mergedFavArticles = normalizeIDs(mergedFavorites(.articles, local: localFavArticles))
		if mergedFavArticles != localFavArticles {
			saveLocalFavoriteArticles(mergedFavArticles)
		}
		cachedFavoriteArticles = mergedFavArticles

		let localReadPosts = getLocalReadRedditPosts()
		let effectiveReadPosts = normalizeIDs(localReadPosts.union(cloudSync.getCloudReadRedditPosts()))
		if effectiveReadPosts != localReadPosts {
			saveLocalReadRedditPosts(effectiveReadPosts)
		}
		cachedReadRedditPosts = effectiveReadPosts

		let localFavPosts = getLocalFavoriteRedditPosts()
		let mergedFavPosts = normalizeIDs(mergedFavorites(.redditPosts, local: localFavPosts))
		if mergedFavPosts != localFavPosts {
			saveLocalFavoriteRedditPosts(mergedFavPosts)
		}
		cachedFavoriteRedditPosts = mergedFavPosts

		// Subscriptions: every device applies the per-feed records; there is no primary device.
		acknowledgeSyncedPodcastSubscriptions()
		let previousSubscriptions = cachedSubscriptions ?? loadSubscriptionsFromLocal()
		let effectiveSubscriptions = subscriptionsPreservingSavedPodcasts(
			mergedSubscriptions(local: previousSubscriptions)
		)
		if !subscriptionsEqual(previousSubscriptions, effectiveSubscriptions) {
			saveSubscriptionsToLocal(effectiveSubscriptions)
			didChangeSubscriptions = true
		}
		cachedSubscriptions = effectiveSubscriptions

		return didChangeSubscriptions
	}

    func performInitialCloudMerge() {
        // Force sync to get latest from cloud
        cloudSync.forceSynchronize()
        seedCloudRecordsIfReady()

        // Read state: combine local and iCloud. (Taking iCloud alone dropped local reads that
        // had not reached iCloud yet, or were trimmed by a quota cleanup.)
        let localReadArticles = getLocalReadArticles()
        let cloudReadArticles = normalizeIDs(cloudSync.getCloudReadArticles())
        let effectiveReadArticles = normalizeIDs(localReadArticles.union(cloudReadArticles))
        if effectiveReadArticles != localReadArticles {
            saveLocalReadArticles(effectiveReadArticles)
        }
        cachedReadArticles = effectiveReadArticles

        // Favorites: the shared list plus local favorites, with every recorded change applied.
        let localFavArticles = getLocalFavoriteArticles()
        let mergedFavArticles = normalizeIDs(mergedFavorites(.articles, local: localFavArticles))
        if mergedFavArticles != localFavArticles {
            saveLocalFavoriteArticles(mergedFavArticles)
        }
        cachedFavoriteArticles = mergedFavArticles

        let localReadPosts = getLocalReadRedditPosts()
        let cloudReadPosts = normalizeIDs(cloudSync.getCloudReadRedditPosts())
        let effectiveReadPosts = normalizeIDs(localReadPosts.union(cloudReadPosts))
        if effectiveReadPosts != localReadPosts {
            saveLocalReadRedditPosts(effectiveReadPosts)
        }
        cachedReadRedditPosts = effectiveReadPosts

        let localFavPosts = getLocalFavoriteRedditPosts()
        let mergedFavPosts = normalizeIDs(mergedFavorites(.redditPosts, local: localFavPosts))
        if mergedFavPosts != localFavPosts {
            saveLocalFavoriteRedditPosts(mergedFavPosts)
        }
        cachedFavoriteRedditPosts = mergedFavPosts

        // Subscriptions: per-feed records from every device; there is no primary device.
        let localSubs = loadSubscriptionsFromLocal()
        acknowledgeSyncedPodcastSubscriptions()
        let effectiveSubscriptions = subscriptionsPreservingSavedPodcasts(
            mergedSubscriptions(local: localSubs)
        )
        if !subscriptionsEqual(localSubs, effectiveSubscriptions) {
            saveSubscriptionsToLocal(effectiveSubscriptions)
        }
        cachedSubscriptions = effectiveSubscriptions

        syncPendingPodcastSubscriptionsToCloud()

        syncLog("☁️ PersistenceManager: Initial cloud merge complete")
        syncLog("   Local articles: \(localReadArticles.count), Cloud: \(cloudReadArticles.count), Active: \(effectiveReadArticles.count)")
        syncLog("   Local Reddit: \(localReadPosts.count), Cloud: \(cloudReadPosts.count), Active: \(effectiveReadPosts.count)")
        syncLog("   Local subscriptions: \(localSubs.count), Active: \(effectiveSubscriptions.count)")
    }

    /// Once per device, after iCloud's first sync: records local favorites and subscriptions in
    /// the per-item format so they reach every device. Waiting for the first sync avoids
    /// overwriting per-feed records another device wrote that have not downloaded yet.
    /// True for a list that holds nothing but the built-in default feeds (a fresh install).
    private func isOnlyDefaultSubscriptions(_ subscriptions: [Subscription]) -> Bool {
        let defaultKeys = Set(getDefaultSubscriptions().map(\.canonicalKey))
        return Set(subscriptions.map(\.canonicalKey)).isSubset(of: defaultKeys)
    }

    private func seedCloudRecordsIfReady() {
        guard cloudSync.hasCompletedInitialSync,
              !userDefaults.bool(forKey: Keys.seededCloudRecordsV2) else { return }
        userDefaults.set(true, forKey: Keys.seededCloudRecordsV2)
        cloudSync.seedFavoriteRecords(local: getLocalFavoriteArticles(), kind: .articles)
        cloudSync.seedFavoriteRecords(local: getLocalFavoriteRedditPosts(), kind: .redditPosts)
        // A fresh install has only the built-in defaults; don't spread those to other devices.
        let localSubscriptions = loadSubscriptionsFromLocal()
        if userDefaults.data(forKey: Keys.subscriptions) != nil && !isOnlyDefaultSubscriptions(localSubscriptions) {
            cloudSync.seedSubscriptionRecords(from: localSubscriptions)
        }
    }

    /// Call this when remote changes are received to update local cache.
    /// Remote updates merge with local so freshly-read badges don't regress.
    @discardableResult
    func handleRemoteReadArticlesChange(_ ids: Set<String>) -> Bool {
        let normalizedIds = normalizeIDs(ids)
        let local = cachedReadArticles ?? getLocalReadArticles()
        let merged = normalizeIDs(local.union(normalizedIds))
        guard merged != local else { return false }
        saveLocalReadArticles(merged)
        cachedReadArticles = merged
        syncLog("☁️ PersistenceManager: Applied \(ids.count) cloud articles → local cache now has \(merged.count)")
        return true
    }

    @discardableResult
    func handleRemoteFavoriteArticlesChange(_ ids: Set<String>) -> Bool {
        seedCloudRecordsIfReady()
        let local = cachedFavoriteArticles ?? getLocalFavoriteArticles()
        // Recompute from the change records rather than adding `ids`, so removals made on other
        // devices apply here instead of being added back.
        let normalizedMerged = normalizeIDs(mergedFavorites(.articles, local: local))
        guard normalizedMerged != local else { return false }
        saveLocalFavoriteArticles(normalizedMerged)
        cachedFavoriteArticles = normalizedMerged
        return true
    }

    /// Remote updates merge with local so freshly-read badges don't regress.
    @discardableResult
    func handleRemoteReadRedditPostsChange(_ ids: Set<String>) -> Bool {
        let normalizedIds = normalizeIDs(ids)
        let local = cachedReadRedditPosts ?? getLocalReadRedditPosts()
        let merged = normalizeIDs(local.union(normalizedIds))
        guard merged != local else { return false }
        saveLocalReadRedditPosts(merged)
        cachedReadRedditPosts = merged
        syncLog("☁️ PersistenceManager: Applied \(ids.count) cloud Reddit posts → local cache now has \(merged.count)")
        return true
    }

    @discardableResult
    func handleRemoteFavoriteRedditPostsChange(_ ids: Set<String>) -> Bool {
        seedCloudRecordsIfReady()
        let local = cachedFavoriteRedditPosts ?? getLocalFavoriteRedditPosts()
        let normalizedMerged = normalizeIDs(mergedFavorites(.redditPosts, local: local))
        guard normalizedMerged != local else { return false }
        saveLocalFavoriteRedditPosts(normalizedMerged)
        cachedFavoriteRedditPosts = normalizedMerged
        return true
    }

    @discardableResult
    func handleRemoteSubscriptionsChange(_ subscriptions: [Subscription], allowEmptyCloudValue: Bool = false) -> Bool {
        seedCloudRecordsIfReady()
        acknowledgeSyncedPodcastSubscriptions()

        // Every device applies the per-feed records (and additions older builds wrote to the
        // shared list); there is no primary device.
        let current = cachedSubscriptions ?? loadSubscriptionsFromLocal()
        let effectiveSubscriptions = subscriptionsPreservingSavedPodcasts(
            mergedSubscriptions(local: current)
        )
        guard !subscriptionsEqual(current, effectiveSubscriptions) else { return false }
        saveSubscriptionsToLocal(effectiveSubscriptions)
        cachedSubscriptions = effectiveSubscriptions
        syncLog("☁️ PersistenceManager: Applied subscription changes from iCloud")
        return true
    }

    // MARK: - CloudKit

    /// Favorites from the key-value sync, keeping out items removed here or through CloudKit
    /// (stale key-value data could otherwise bring them back). New ones, such as favorites added
    /// on devices still running an older version, are forwarded to CloudKit.
    private func mergedFavorites(_ kind: CloudSyncManager.FavoriteKind, local: Set<String>) -> Set<String> {
        let cloudKitKind: CloudKitItemKind = kind == .articles ? .article : .reddit
        let removed = tombstones(in: favoriteTombstoneKey(cloudKitKind))
        var result = normalizeIDs(cloudSync.effectiveFavorites(kind, local: local))
        let fromKeyValue = result.subtracting(local)
        let blocked = fromKeyValue.filter { removed[$0] != nil }
        result.subtract(blocked)
        // Forward only additions made by older versions. Updated devices already saved theirs to
        // CloudKit; re-sending them could re-create a favorite another device has just removed.
        let fromUpdatedDevices = cloudSync.favoriteIDsWithChangeRecords(kind)
        for id in fromKeyValue.subtracting(blocked).subtracting(fromUpdatedDevices) {
            cloudKit.setFavorite(cloudKitKind, id: id, isFavorite: true)
        }
        return result
    }

    /// Subscriptions from the key-value sync, keeping out feeds removed here or through CloudKit,
    /// and forwarding feeds added elsewhere (including by older versions) to CloudKit.
    private func mergedSubscriptions(local: [Subscription]) -> [Subscription] {
        let removed = tombstones(in: Keys.tombstonesSubscriptions)
        let localKeys = Set(local.map(\.canonicalKey))
        let result = cloudSync.effectiveSubscriptions(local: local).filter {
            localKeys.contains($0.canonicalKey) || removed[$0.canonicalKey] == nil
        }
        // Forward only feeds added by older versions; updated devices already saved theirs.
        let fromUpdatedDevices = cloudSync.subscriptionKeysWithRecords()
            .union(cloudSync.cloudPodcastRecordCanonicalKeys())
        for subscription in result
        where !localKeys.contains(subscription.canonicalKey) && !fromUpdatedDevices.contains(subscription.canonicalKey) {
            cloudKit.saveSubscription(subscription)
        }
        return result
    }

    /// Applies favorites added or removed on other devices through CloudKit.
    @discardableResult
    func applyCloudKitFavorites(_ kind: CloudKitItemKind, added: Set<String>, removed: Set<String>, removedRecordNames: Set<String>) -> Bool {
        let tombstoneKey = favoriteTombstoneKey(kind)
        let before = kind == .article ? getFavoriteArticles() : getFavoriteRedditPosts()
        var favorites = before
        for id in normalizeIDs(added) {
            favorites.insert(id)
            setTombstone(id, in: tombstoneKey, removed: false)
        }
        let removedByName = removedRecordNames.isEmpty
            ? []
            : favorites.filter { removedRecordNames.contains(CloudKitSyncManager.favoriteRecordName(kind, $0)) }
        let removedIDs = normalizeIDs(removed).union(removedByName)
        if !removedIDs.isEmpty {
            for id in removedIDs {
                favorites.remove(id)
                setTombstone(id, in: tombstoneKey, removed: true)
            }
        }
        guard favorites != before else { return false }
        if kind == .article {
            saveLocalFavoriteArticles(favorites)
            cachedFavoriteArticles = favorites
        } else {
            saveLocalFavoriteRedditPosts(favorites)
            cachedFavoriteRedditPosts = favorites
        }
        return true
    }

    /// Applies subscriptions added, renamed or removed on other devices through CloudKit.
    @discardableResult
    func applyCloudKitSubscriptions(upserted: [Subscription], removedKeys: Set<String>, removedRecordNames: Set<String>) -> Bool {
        let current = cachedSubscriptions ?? loadSubscriptionsFromLocal()
        var incoming = Dictionary(upserted.map { ($0.canonicalKey, $0) }, uniquingKeysWith: { _, latest in latest })
        var result: [Subscription] = []
        var removedPodcasts: [Subscription] = []

        for subscription in current {
            let key = subscription.canonicalKey
            if removedKeys.contains(key) || removedRecordNames.contains(CloudKitSyncManager.subscriptionRecordName(key)) {
                setTombstone(key, in: Keys.tombstonesSubscriptions, removed: true)
                if subscription.isPodcast { removedPodcasts.append(subscription) }
                continue
            }
            if let update = incoming.removeValue(forKey: key) {
                // Keep this device's ID; take the name and kind from the other device.
                result.append(Subscription(id: subscription.id, title: update.title, url: subscription.url, type: subscription.type, contentKind: update.contentKind))
            } else {
                result.append(subscription)
            }
        }
        let added = incoming.values.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        result.append(contentsOf: added)
        for subscription in upserted {
            setTombstone(subscription.canonicalKey, in: Keys.tombstonesSubscriptions, removed: false)
        }

        if !removedPodcasts.isEmpty {
            var saved = loadSavedPodcastSubscriptions()
            for podcast in removedPodcasts { saved.removeValue(forKey: podcast.canonicalKey) }
            persistSavedPodcastSubscriptions(saved)
        }

        let effective = subscriptionsPreservingSavedPodcasts(result)
        guard !subscriptionsEqual(current, effective) else { return false }
        saveSubscriptionsToLocal(effective)
        cachedSubscriptions = effective
        return true
    }

    private func favoriteTombstoneKey(_ kind: CloudKitItemKind) -> String {
        kind == .article ? Keys.tombstonesFavoriteArticles : Keys.tombstonesFavoriteReddit
    }

    private func tombstones(in key: String) -> [String: Double] {
        userDefaults.dictionary(forKey: key) as? [String: Double] ?? [:]
    }

    private func setTombstone(_ id: String, in key: String, removed: Bool) {
        var entries = tombstones(in: key)
        if removed {
            entries[id] = Date().timeIntervalSince1970
            if entries.count > 2_000 {
                for oldest in entries.sorted(by: { $0.value < $1.value }).prefix(entries.count - 2_000).map(\.key) {
                    entries.removeValue(forKey: oldest)
                }
            }
        } else {
            guard entries.removeValue(forKey: id) != nil else { return }
        }
        userDefaults.set(entries, forKey: key)
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

    /// Save subscriptions locally and record what changed in iCloud, from any device.
    func saveSubscriptions(_ subscriptions: [Subscription]) {
        let previous = cachedSubscriptions ?? loadSubscriptionsFromLocal()
        saveSubscriptionsToLocal(subscriptions)
        cachedSubscriptions = subscriptions
        cloudSync.recordSubscriptionChanges(from: previous, to: subscriptions)
        cloudKit.recordSubscriptionChanges(from: previous, to: subscriptions)
        let newKeys = Set(subscriptions.map(\.canonicalKey))
        for key in Set(previous.map(\.canonicalKey)).subtracting(newKeys) {
            setTombstone(key, in: Keys.tombstonesSubscriptions, removed: true)
        }
        for key in newKeys {
            setTombstone(key, in: Keys.tombstonesSubscriptions, removed: false)
        }
    }

    /// Load subscriptions (from cache or local storage)
    func loadSubscriptions() -> [Subscription] {
        let loaded = cachedSubscriptions ?? loadSubscriptionsFromLocal()
        let effectiveSubscriptions = subscriptionsPreservingSavedPodcasts(loaded)
        if !subscriptionsEqual(loaded, effectiveSubscriptions) {
            saveSubscriptionsToLocal(effectiveSubscriptions)
            cachedSubscriptions = effectiveSubscriptions
        }
        return effectiveSubscriptions
    }

    /// Podcast discovery is an explicit local save. Keep the complete feed
    /// record so an older primary-device iCloud snapshot cannot erase it on the
    /// next launch. The ordinary subscription array remains backwards compatible.
    func savePodcastSubscription(_ subscription: Subscription) {
        guard subscription.isPodcast else { return }
        cloudKit.saveSubscription(subscription)
        setTombstone(subscription.canonicalKey, in: Keys.tombstonesSubscriptions, removed: false)
        var saved = loadSavedPodcastSubscriptions()

        if cloudSync.isPodcastSubscriptionSynced(subscription) {
            if saved.removeValue(forKey: subscription.canonicalKey) != nil {
                persistSavedPodcastSubscriptions(saved)
            }
            return
        }

        if saved[subscription.canonicalKey] != subscription {
            saved[subscription.canonicalKey] = subscription
            persistSavedPodcastSubscriptions(saved)
        }

        cloudSync.syncPodcastSubscription(subscription)
    }

    func removeSavedPodcastSubscription(_ subscription: Subscription) {
        cloudKit.deleteSubscription(subscription)
        setTombstone(subscription.canonicalKey, in: Keys.tombstonesSubscriptions, removed: true)
        var saved = loadSavedPodcastSubscriptions()
        if saved.removeValue(forKey: subscription.canonicalKey) != nil {
            persistSavedPodcastSubscriptions(saved)
        }
        cloudSync.removePodcastSubscription(subscription)
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

    private func loadSavedPodcastSubscriptions() -> [String: Subscription] {
        var saved: [String: Subscription] = [:]
        if let data = userDefaults.data(forKey: Keys.savedPodcastSubscriptions),
           let subscriptions = try? JSONDecoder().decode([Subscription].self, from: data) {
            saved = Dictionary(
                subscriptions.map { ($0.canonicalKey, $0) },
                uniquingKeysWith: { _, newest in newest }
            )
        }

        // Migration for the first podcast build: it persisted only canonical
        // classification keys. Reconstruct those feeds so a cloud overwrite
        // does not force the user to search and subscribe again.
        var didMigrate = false
        let localSubscriptions = Dictionary(
            loadSubscriptionsFromLocal().map { ($0.canonicalKey, $0) },
            uniquingKeysWith: { existing, _ in existing }
        )
        for canonicalKey in userDefaults.stringArray(forKey: Keys.podcastSubscriptionCanonicalKeys) ?? [] {
            guard canonicalKey.hasPrefix("rss|") else { continue }
            let feedURL = String(canonicalKey.dropFirst(4))
            let placeholder = Subscription(title: "Podcast", url: feedURL, type: .rss)
            let existing = localSubscriptions[placeholder.canonicalKey]
            let migrated = Subscription(
                id: existing?.id ?? UUID(),
                title: existing?.title ?? "Podcast",
                url: feedURL,
                type: .rss,
                contentKind: .podcast
            )
            if saved[migrated.canonicalKey] == nil {
                saved[migrated.canonicalKey] = migrated
                didMigrate = true
            }
        }
        if didMigrate {
            persistSavedPodcastSubscriptions(saved)
        }
        return saved
    }

    private func persistSavedPodcastSubscriptions(_ subscriptions: [String: Subscription]) {
        let sorted = subscriptions.values.sorted {
            if $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedSame {
                return $0.canonicalKey < $1.canonicalKey
            }
            return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
        guard let encoded = try? JSONEncoder().encode(sorted) else { return }
        userDefaults.set(encoded, forKey: Keys.savedPodcastSubscriptions)
    }

    private func subscriptionsPreservingSavedPodcasts(_ subscriptions: [Subscription]) -> [Subscription] {
        let saved = loadSavedPodcastSubscriptions()
        guard !saved.isEmpty else { return subscriptions }

        var upgradedKeys = Set<String>()
        var merged = subscriptions.map { subscription in
            guard let savedPodcast = saved[subscription.canonicalKey] else {
                return subscription
            }
            upgradedKeys.insert(subscription.canonicalKey)
            let title = subscription.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? savedPodcast.title
                : subscription.title
            return Subscription(
                id: subscription.id,
                title: title,
                url: subscription.url,
                type: subscription.type,
                contentKind: .podcast
            )
        }
        let missing = saved.values
            .filter { !upgradedKeys.contains($0.canonicalKey) }
            .sorted {
                if $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedSame {
                    return $0.canonicalKey < $1.canonicalKey
                }
                return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
        merged.append(contentsOf: missing)
        return merged
    }

    private func syncPendingPodcastSubscriptionsToCloud() {
        let saved = loadSavedPodcastSubscriptions()
        guard !saved.isEmpty else { return }
        let currentByKey = Dictionary(
            (cachedSubscriptions ?? loadSubscriptionsFromLocal()).map { ($0.canonicalKey, $0) },
            uniquingKeysWith: { existing, _ in existing }
        )
        for (key, savedPodcast) in saved {
            let current = currentByKey[key] ?? savedPodcast
            let tagged = Subscription(
                id: current.id,
                title: current.title,
                url: current.url,
                type: current.type,
                contentKind: .podcast
            )
            cloudSync.syncPodcastSubscription(tagged)
        }
    }

    private func acknowledgeSyncedPodcastSubscriptions() {
        let syncedKeys = cloudSync.cloudPodcastRecordCanonicalKeys()
        guard !syncedKeys.isEmpty else { return }

        var saved = loadSavedPodcastSubscriptions()
        let previousCount = saved.count
        for key in syncedKeys {
            saved.removeValue(forKey: key)
        }
        if saved.count != previousCount {
            persistSavedPodcastSubscriptions(saved)
        }

        let legacyMarkers = Set(userDefaults.stringArray(forKey: Keys.podcastSubscriptionCanonicalKeys) ?? [])
        let remainingMarkers = legacyMarkers.subtracting(syncedKeys)
        if remainingMarkers != legacyMarkers {
            userDefaults.set(remainingMarkers.sorted(), forKey: Keys.podcastSubscriptionCanonicalKeys)
        }
    }

    /// Get this device's name
    var thisDeviceName: String {
        return cloudSync.thisDeviceName
    }
    
	    // MARK: - Article Read Status
	    func markArticleAsRead(_ article: Article) {
	        markArticleAsRead(tokens: articleReadTokens(for: article), diagnosticID: article.id)
	    }

    /// Persists a bulk read operation with one local write and one cloud-sync pass.
    /// Single-item callers continue to use `markArticleAsRead(_:)` unchanged.
    func markArticlesAsRead(_ articles: [Article]) {
        guard !articles.isEmpty else { return }

        var tokens: Set<String> = []
        for article in articles {
            tokens.formUnion(articleReadTokens(for: article))
        }
        markArticleAsRead(tokens: tokens, diagnosticID: "batch:\(articles.count)")
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

    func readTokensForPolling(articleID: String, articleURL: URL?, title: String?, feedURL: String?) -> Set<String> {
        articleReadTokens(articleId: articleID, articleURL: articleURL, title: title, feedURL: feedURL)
    }

    func containsReadArticle(tokens: Set<String>, in readTokenSet: Set<String>) -> Bool {
        let candidates = normalizeIDs(tokens)
        return !readTokenSet.isDisjoint(with: candidates)
    }

    private func getReadArticles() -> Set<String> {
        return cachedReadArticles ?? getLocalReadArticles()
    }
    
    // MARK: - Article Favorites
    func addFavoriteArticle(_ articleId: String) {
        var favorites = cachedFavoriteArticles ?? getLocalFavoriteArticles()
        favorites.insert(normalizedToken(articleId))
        saveLocalFavoriteArticles(favorites)
        cachedFavoriteArticles = favorites
        cloudSync.recordFavorite(articleId, isFavorite: true, kind: .articles)
        cloudKit.setFavorite(.article, id: normalizedToken(articleId), isFavorite: true)
        setTombstone(normalizedToken(articleId), in: Keys.tombstonesFavoriteArticles, removed: false)
    }

    func removeFavoriteArticle(_ articleId: String) {
        var favorites = cachedFavoriteArticles ?? getLocalFavoriteArticles()
        favorites.remove(normalizedToken(articleId))
        saveLocalFavoriteArticles(favorites)
        cachedFavoriteArticles = favorites
        cloudSync.recordFavorite(articleId, isFavorite: false, kind: .articles)
        cloudKit.setFavorite(.article, id: normalizedToken(articleId), isFavorite: false)
        setTombstone(normalizedToken(articleId), in: Keys.tombstonesFavoriteArticles, removed: true)
    }

    func isArticleFavorite(_ articleId: String) -> Bool {
        let normalized = normalizedToken(articleId)
        return (cachedFavoriteArticles ?? getLocalFavoriteArticles()).contains(normalized)
    }

    private func getFavoriteArticles() -> Set<String> {
        return cachedFavoriteArticles ?? getLocalFavoriteArticles()
    }
    
	    // MARK: - Reddit Post Read Status
	    func markRedditPostAsRead(_ post: RedditPost) {
	        markRedditPostAsRead(tokens: redditReadTokens(for: post), diagnosticID: post.id)
	    }

    /// Persists a bulk read operation with one local write and one cloud-sync pass.
    /// Single-item callers continue to use `markRedditPostAsRead(_:)` unchanged.
    func markRedditPostsAsRead(_ posts: [RedditPost]) {
        guard !posts.isEmpty else { return }

        var tokens: Set<String> = []
        for post in posts {
            tokens.formUnion(redditReadTokens(for: post))
        }
        markRedditPostAsRead(tokens: tokens, diagnosticID: "batch:\(posts.count)")
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

    func readTokensForPolling(postID: String, subreddit: String, postURL: URL?) -> Set<String> {
        var tokens = redditReadTokens(postId: postID, subreddit: subreddit)
        if let rawURL = postURL?.absoluteString, !rawURL.isEmpty {
            tokens.insert(rawURL)
        }
        return normalizeIDs(tokens)
    }

    func containsReadRedditPost(tokens: Set<String>, in readTokenSet: Set<String>) -> Bool {
        let candidates = normalizeIDs(tokens)
        return !readTokenSet.isDisjoint(with: candidates)
    }

    private func getReadRedditPosts() -> Set<String> {
        return cachedReadRedditPosts ?? getLocalReadRedditPosts()
    }
    
    // MARK: - Reddit Post Favorites
    func addFavoriteRedditPost(_ postId: String) {
        var favorites = cachedFavoriteRedditPosts ?? getLocalFavoriteRedditPosts()
        favorites.insert(normalizedToken(postId))
        saveLocalFavoriteRedditPosts(favorites)
        cachedFavoriteRedditPosts = favorites
        cloudSync.recordFavorite(postId, isFavorite: true, kind: .redditPosts)
        cloudKit.setFavorite(.reddit, id: normalizedToken(postId), isFavorite: true)
        setTombstone(normalizedToken(postId), in: Keys.tombstonesFavoriteReddit, removed: false)
    }

    func removeFavoriteRedditPost(_ postId: String) {
        var favorites = cachedFavoriteRedditPosts ?? getLocalFavoriteRedditPosts()
        favorites.remove(normalizedToken(postId))
        saveLocalFavoriteRedditPosts(favorites)
        cachedFavoriteRedditPosts = favorites
        cloudSync.recordFavorite(postId, isFavorite: false, kind: .redditPosts)
        cloudKit.setFavorite(.reddit, id: normalizedToken(postId), isFavorite: false)
        setTombstone(normalizedToken(postId), in: Keys.tombstonesFavoriteReddit, removed: true)
    }

    func isRedditPostFavorite(_ postId: String) -> Bool {
        let normalized = normalizedToken(postId)
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

        hydrated.openAICompatibleAPIKey = RSSSummarizeKeychain.string(for: RSSSummarizeKeychain.openAICompatibleAPIKeyKey) ?? ""

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

        RSSSummarizeKeychain.set(settings.openAICompatibleAPIKey, for: RSSSummarizeKeychain.openAICompatibleAPIKeyKey)
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

    private func subscriptionsEqual(_ lhs: [Subscription], _ rhs: [Subscription]) -> Bool {
        let lhsSet = Set(lhs.map { "\($0.canonicalKey)|\($0.contentKind?.rawValue ?? "feed")|\($0.title)" })
        let rhsSet = Set(rhs.map { "\($0.canonicalKey)|\($0.contentKind?.rawValue ?? "feed")|\($0.title)" })
        return lhsSet == rhsSet
    }

    private func normalizeIDs(_ ids: Set<String>) -> Set<String> {
        guard !ids.isEmpty else { return [] }

        var normalized: Set<String> = []
        normalized.reserveCapacity(ids.count)
        for raw in ids {
            normalized.formUnion(expandedReadTokens(from: raw))
        }
        return normalized
    }

    private func normalizedToken(_ raw: String) -> String {
        let cacheKey = raw as NSString
        if let cached = normalizedTokenCache.object(forKey: cacheKey) {
            return cached as String
        }

        let normalized = ArticleIDNormalizer.normalize(raw)
        normalizedTokenCache.setObject(
            normalized as NSString,
            forKey: cacheKey,
            cost: max(1, normalized.utf8.count)
        )
        return normalized
    }

    private func markArticleAsRead(tokens: Set<String>, diagnosticID: String) {
        guard !tokens.isEmpty else { return }
        syncLog("🔍 DIAGNOSTIC: PersistenceManager.markArticleAsRead called - id=\(diagnosticID.prefix(50))")
        var readArticles = cachedReadArticles ?? getLocalReadArticles()
        readArticles.formUnion(tokens)
        saveLocalReadArticles(readArticles)
        cachedReadArticles = readArticles
        // Sync to cloud
        syncLog("🔍 DIAGNOSTIC: About to call cloudSync.syncReadArticles with \(tokens.count) token(s)")
        cloudSync.syncReadArticles(tokens)
        cloudKit.recordReads(.article, ids: normalizeIDs(tokens))
        syncLog("🔍 DIAGNOSTIC: cloudSync.syncReadArticles returned")
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
        var tokens: Set<String> = [normalizedToken(articleId)]
        if let rawURL = articleURL?.absoluteString, !rawURL.isEmpty {
            tokens.insert(rawURL)
        }
        if let title, !title.isEmpty, let feedURL, !feedURL.isEmpty {
            let fallbackHash = "hash-\(djb2Hex("\(title)|\(feedURL)"))"
            tokens.insert(normalizedToken(fallbackHash))
        }
        return normalizeIDs(tokens)
    }

    private func markRedditPostAsRead(tokens: Set<String>, diagnosticID: String) {
        guard !tokens.isEmpty else { return }
        syncLog("🔍 DIAGNOSTIC: PersistenceManager.markRedditPostAsRead called - id=\(diagnosticID.prefix(50))")
        var readPosts = cachedReadRedditPosts ?? getLocalReadRedditPosts()
        readPosts.formUnion(tokens)
        saveLocalReadRedditPosts(readPosts)
        cachedReadRedditPosts = readPosts
        // Sync to cloud
        syncLog("🔍 DIAGNOSTIC: About to call cloudSync.syncReadRedditPosts with \(tokens.count) token(s)")
        cloudSync.syncReadRedditPosts(tokens)
        cloudKit.recordReads(.reddit, ids: normalizeIDs(tokens))
        syncLog("🔍 DIAGNOSTIC: cloudSync.syncReadRedditPosts returned")
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
        return normalizeIDs(tokens)
    }

    private func redditReadTokens(postId: String, subreddit: String?) -> Set<String> {
        let normalizedID = normalizedToken(postId)
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

        let trimmedURL = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmedURL) else {
            return nil
        }

        components.fragment = nil
        // Keep query parameters for article identity. Dropping them can collapse
        // distinct items (e.g. ?p=123 vs ?p=456) into the same read token.
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()

        if let port = components.port, port == 80 || port == 443 {
            components.port = nil
        }

        if var path = components.percentEncodedPath.removingPercentEncoding {
            if path.count > 1 && path.hasSuffix("/") {
                path.removeLast()
            }
            components.percentEncodedPath = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? components.percentEncodedPath
        }

        guard let canonical = components.string, !canonical.isEmpty else {
            return nil
        }

        return normalizedToken(canonical)
    }

    private func expandedReadTokens(from raw: String) -> Set<String> {
        let rawCacheKey = raw as NSString
        if let cached = expandedReadTokenCache.object(forKey: rawCacheKey) {
            return cached.tokens
        }

        let normalized = normalizedToken(raw)
        guard !normalized.isEmpty else { return [] }

        let cacheKey = normalized as NSString
        if let cached = expandedReadTokenCache.object(forKey: cacheKey) {
            return cached.tokens
        }

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

        let cost = max(1, tokens.reduce(into: 0) { total, token in
            total += token.utf8.count
        })
        let cacheEntry = TokenSetCacheEntry(tokens: tokens)
        expandedReadTokenCache.setObject(cacheEntry, forKey: cacheKey, cost: cost)
        if raw != normalized {
            expandedReadTokenCache.setObject(cacheEntry, forKey: rawCacheKey, cost: cost)
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
        return normalizedToken("https://www.reddit.com/r/\(subreddit)/comments/\(postID)")
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
