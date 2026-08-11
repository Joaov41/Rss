import Foundation
import Combine
#if os(macOS)
import Security
#endif
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// CloudSyncManager handles syncing read/favorite states across devices using iCloud Key-Value Store.
/// This uses NSUbiquitousKeyValueStore which automatically syncs data across all devices
/// signed into the same iCloud account (iPhone, iPad, Mac).
///
/// Storage limit: 1MB total, 1024 keys max. Each key can store up to 1MB.
/// For read article IDs (typically ~50-100 bytes each), this supports tens of thousands of items.
final class CloudSyncManager {
    static let shared = CloudSyncManager()

    private let cloudStore = NSUbiquitousKeyValueStore.default
    private let localDefaults = UserDefaults.standard
    private var hasCompletedInitialSync: Bool = false
    private var pendingReadArticles: Set<String> = []
    private var pendingReadRedditPosts: Set<String> = []
    private var lastQuotaCompactionAttempt: Date?
    private var isQuotaCompactionInProgress = false

    // Keys for cloud storage - must match across all platforms
    private enum Keys {
        static let readArticles = "cloud_readArticles"
        static let favoriteArticles = "cloud_favoriteArticles"
        static let readRedditPosts = "cloud_readRedditPosts"
        static let favoriteRedditPosts = "cloud_favoriteRedditPosts"
        static let subscriptions = "cloud_subscriptions"
        static let lastSyncTimestamp = "cloud_lastSyncTimestamp"
        // Primary device tracking
        static let primaryDeviceID = "cloud_primaryDeviceID"
        static let primaryDeviceName = "cloud_primaryDeviceName"
    }

    // V2 sharded keys (per-device) for conflict-free, incremental read-state syncing.
    // This avoids one giant payload that can fail to propagate and avoids cross-device overwrites.
    private enum V2Keys {
        static let shardCount = 16
        static let readArticlesShardPrefix = "cloud_v2_readArticles_"
        static let readRedditPostsShardPrefix = "cloud_v2_readRedditPosts_"
        static let readArticlesDeviceIndexKey = "cloud_v2_readArticles_devices"
        static let readRedditPostsDeviceIndexKey = "cloud_v2_readRedditPosts_devices"
        static let quotaMaxArticles = 2_500
        static let quotaMaxRedditPosts = 12_000
    }

    // Local keys (not synced to cloud)
    private enum LocalKeys {
        static let thisDeviceID = "local_thisDeviceID"
    }

    // This device's unique identifier (persisted locally)
    private(set) lazy var thisDeviceID: String = {
        if let existingID = localDefaults.string(forKey: LocalKeys.thisDeviceID) {
            return existingID
        }
        let newID = UUID().uuidString
        localDefaults.set(newID, forKey: LocalKeys.thisDeviceID)
        return newID
    }()

    /// Returns a friendly name for this device
    var thisDeviceName: String {
        #if os(iOS)
        return UIDevice.current.name
        #elseif os(macOS)
        return Host.current().localizedName ?? "Mac"
        #else
        return "Unknown Device"
        #endif
    }

    /// Check if this device is the primary device for subscriptions
    var isThisDevicePrimary: Bool {
        guard let primaryID = cloudStore.string(forKey: Keys.primaryDeviceID) else {
            // No primary set yet
            return false
        }
        return primaryID == thisDeviceID
    }

    /// Get the name of the current primary device (if any)
    var primaryDeviceName: String? {
        return cloudStore.string(forKey: Keys.primaryDeviceName)
    }

    /// Check if any device is set as primary
    var hasPrimaryDevice: Bool {
        return cloudStore.string(forKey: Keys.primaryDeviceID) != nil
    }

    /// Set this device as the primary device for subscriptions
    func setThisDeviceAsPrimary() {
        cloudStore.set(thisDeviceID, forKey: Keys.primaryDeviceID)
        cloudStore.set(thisDeviceName, forKey: Keys.primaryDeviceName)
        cloudStore.synchronize()
        print("☁️ CloudSyncManager: This device is now primary for subscriptions: \(thisDeviceName)")
    }

    /// Clear primary device (no device is primary)
    func clearPrimaryDevice() {
        cloudStore.removeObject(forKey: Keys.primaryDeviceID)
        cloudStore.removeObject(forKey: Keys.primaryDeviceName)
        cloudStore.synchronize()
        print("☁️ CloudSyncManager: Primary device cleared")
    }

    // Snapshot of all read/favorite states for replay to late subscribers
    struct ReadStateSnapshot {
        let readArticles: Set<String>
        let favoriteArticles: Set<String>
        let readRedditPosts: Set<String>
        let favoriteRedditPosts: Set<String>
        let subscriptions: [Subscription]
    }

    // Publisher for remote change notifications - uses CurrentValueSubject for replay
    // Late subscribers immediately receive the latest snapshot
    let snapshotPublisher = CurrentValueSubject<ReadStateSnapshot?, Never>(nil)

    // Legacy publisher for individual changes (kept for compatibility)
    let remoteChangesPublisher = PassthroughSubject<CloudSyncChange, Never>()

    // Observer reference for cleanup
    private var kvsObserver: NSObjectProtocol?

    enum CloudSyncChange {
        case readArticles(Set<String>)
        case favoriteArticles(Set<String>)
        case readRedditPosts(Set<String>)
        case favoriteRedditPosts(Set<String>)
        case subscriptions([Subscription])
    }

    private init() {
        setupCloudSync()
    }

    // MARK: - Setup

    private func setupCloudSync() {
        // Register for remote change notifications using block-based observer on .main queue
        // This guarantees all UI-affecting code runs on main thread
        kvsObserver = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: cloudStore,
            queue: .main
        ) { [weak self] notification in
            self?.cloudStoreDidChange(notification)
        }

        // Synchronize to get latest values from iCloud
        // This returns false if iCloud is unavailable, but we proceed anyway
        // as changes will sync when iCloud becomes available
        let syncStarted = cloudStore.synchronize()
        // Always log for diagnostics
        print("☁️ CloudSyncManager: Initial sync started = \(syncStarted) [mainThread=\(Thread.isMainThread)]")

        if syncStarted {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self else { return }
                if !self.hasCompletedInitialSync {
                    self.hasCompletedInitialSync = true
                    self.flushPendingReadStateWritesIfPossible()
                }
            }
        }

        // Print app identifiers to verify the app is pointed at the correct KVS bucket
        if let bundleID = Bundle.main.bundleIdentifier {
            print("☁️ CloudSyncManager: Bundle ID = \(bundleID)")
        }

        let shortVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let buildVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        if shortVersion != nil || buildVersion != nil {
            print("☁️ CloudSyncManager: App Version = \(shortVersion ?? "?") (\(buildVersion ?? "?"))")
        }

        #if os(iOS)
        if let entitlements = provisioningProfileEntitlements() {
            if let applicationIdentifier = entitlements["application-identifier"] {
                print("☁️ CloudSyncManager: application-identifier = \(applicationIdentifier)")
            }
            if let teamIdentifier = entitlements["com.apple.developer.team-identifier"] {
                print("☁️ CloudSyncManager: team-identifier = \(teamIdentifier)")
            }
            if let kvsIdentifier = entitlements["com.apple.developer.ubiquity-kvstore-identifier"] {
                print("☁️ CloudSyncManager: kvstore-identifier = \(kvsIdentifier)")
            }
        }
        #elseif os(macOS)
        if let task = SecTaskCreateFromSelf(nil) {
            let applicationIdentifier = SecTaskCopyValueForEntitlement(task, "application-identifier" as CFString, nil)
            let teamIdentifier = SecTaskCopyValueForEntitlement(task, "com.apple.developer.team-identifier" as CFString, nil)
            let kvsIdentifier = SecTaskCopyValueForEntitlement(task, "com.apple.developer.ubiquity-kvstore-identifier" as CFString, nil)
            if applicationIdentifier != nil {
                print("☁️ CloudSyncManager: application-identifier = \(String(describing: applicationIdentifier))")
            }
            if teamIdentifier != nil {
                print("☁️ CloudSyncManager: team-identifier = \(String(describing: teamIdentifier))")
            }
            if kvsIdentifier != nil {
                print("☁️ CloudSyncManager: kvstore-identifier = \(String(describing: kvsIdentifier))")
            }
        }
        #endif

        let readArticles = getCloudReadArticles()
        let readPosts = getCloudReadRedditPosts()
        print("☁️ CloudSyncManager: Current cloud state - Articles: \(readArticles.count), Reddit: \(readPosts.count)")
        if !readArticles.isEmpty {
            print("☁️ CloudSyncManager: Sample article IDs: \(Array(readArticles.prefix(3)))")
        }
        if !readPosts.isEmpty {
            print("☁️ CloudSyncManager: Sample Reddit IDs: \(Array(readPosts.prefix(3)))")
        }

        // Log KVS usage for diagnostics (do not prune automatically; pruning drops read history).
        logTotalDataSize()
    }

    // No longer @objc - using block-based observer guarantees main thread delivery
    private func cloudStoreDidChange(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let reasonValue = userInfo[NSUbiquitousKeyValueStoreChangeReasonKey] as? Int else {
            return
        }

        let reasonString: String
        switch reasonValue {
        case NSUbiquitousKeyValueStoreServerChange:
            reasonString = "Server change"
        case NSUbiquitousKeyValueStoreInitialSyncChange:
            reasonString = "Initial sync"
        case NSUbiquitousKeyValueStoreQuotaViolationChange:
            reasonString = "Quota violation"
        case NSUbiquitousKeyValueStoreAccountChange:
            reasonString = "Account change"
        default:
            reasonString = "Unknown (\(reasonValue))"
        }
        print("☁️ CloudSyncManager: Remote change detected - \(reasonString) [mainThread=\(Thread.isMainThread)]")

        // Log changed keys for diagnostic
        if let changedKeys = userInfo[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String] {
            print("🔍 DIAGNOSTIC: changedKeys = \(changedKeys)")
        } else {
            print("🔍 DIAGNOSTIC: changedKeys = nil (no keys in notification)")
        }

        if reasonValue == NSUbiquitousKeyValueStoreInitialSyncChange || reasonValue == NSUbiquitousKeyValueStoreServerChange {
            hasCompletedInitialSync = true
            // Already on main thread (block-based observer with queue: .main)
            flushPendingReadStateWritesIfPossible()
            publishCurrentReadStateSnapshot(context: reasonString)
        }

        // Handle quota violation
        if reasonValue == NSUbiquitousKeyValueStoreQuotaViolationChange {
            print("⚠️ CloudSyncManager: iCloud storage quota exceeded!")
            logTotalDataSize()
            compactReadStateForQuotaIfNeeded()
            return
        }

        // Get the changed keys
        if let changedKeys = userInfo[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String] {
            var sawV2ReadArticlesChange = false
            var sawV2ReadRedditChange = false

            for key in changedKeys {
                switch key {
                case Keys.readArticles:
                    let ids = getCloudReadArticles()
                    print("☁️ CloudSyncManager: Received \(ids.count) read articles from cloud")
                    remoteChangesPublisher.send(.readArticles(ids))

                case Keys.favoriteArticles:
                    let ids = getStringSet(forKey: Keys.favoriteArticles)
                    print("☁️ CloudSyncManager: Received \(ids.count) favorite articles from cloud")
                    remoteChangesPublisher.send(.favoriteArticles(ids))

                case Keys.readRedditPosts:
                    let ids = getCloudReadRedditPosts()
                    print("☁️ CloudSyncManager: Received \(ids.count) read Reddit posts from cloud")
                    remoteChangesPublisher.send(.readRedditPosts(ids))

                case Keys.favoriteRedditPosts:
                    let ids = getStringSet(forKey: Keys.favoriteRedditPosts)
                    print("☁️ CloudSyncManager: Received \(ids.count) favorite Reddit posts from cloud")
                    remoteChangesPublisher.send(.favoriteRedditPosts(ids))

                case Keys.subscriptions:
                    let subs = getSubscriptions(forKey: Keys.subscriptions)
                    print("☁️ CloudSyncManager: Received \(subs.count) subscriptions from cloud")
                    remoteChangesPublisher.send(.subscriptions(subs))

                case let shardKey where shardKey.hasPrefix(V2Keys.readArticlesShardPrefix):
                    sawV2ReadArticlesChange = true

                case let shardKey where shardKey.hasPrefix(V2Keys.readRedditPostsShardPrefix):
                    sawV2ReadRedditChange = true

                case V2Keys.readArticlesDeviceIndexKey:
                    sawV2ReadArticlesChange = true

                case V2Keys.readRedditPostsDeviceIndexKey:
                    sawV2ReadRedditChange = true

                default:
                    break
                }
            }

            if sawV2ReadArticlesChange {
                let ids = getCloudReadArticles()
                print("☁️ CloudSyncManager: Received \(ids.count) read articles from cloud (v2 shards)")
                remoteChangesPublisher.send(.readArticles(ids))
            }

            if sawV2ReadRedditChange {
                let ids = getCloudReadRedditPosts()
                print("☁️ CloudSyncManager: Received \(ids.count) read Reddit posts from cloud (v2 shards)")
                remoteChangesPublisher.send(.readRedditPosts(ids))
            }

            if sawV2ReadArticlesChange || sawV2ReadRedditChange {
                if !hasCompletedInitialSync {
                    hasCompletedInitialSync = true
                    flushPendingReadStateWritesIfPossible()
                }
                publishCurrentReadStateSnapshot(context: "\(reasonString) (v2 shard change)")
            }
        }
    }

    // MARK: - Read Articles

    func syncReadArticles(_ ids: Set<String>) {
        let normalized = Set(ids.map { ArticleIDNormalizer.normalize($0) })
        guard !normalized.isEmpty else { return }
        pendingReadArticles.formUnion(normalized)
        print("🔍 DIAGNOSTIC: syncReadArticles called - hasCompletedInitialSync=\(hasCompletedInitialSync), ids.count=\(ids.count), pending=\(pendingReadArticles.count)")
        guard hasCompletedInitialSync else {
            print("🔍 DIAGNOSTIC: Initial sync not complete, queued \(normalized.count) articles")
            return
        }
        flushPendingReadStateWritesIfPossible()
    }

    func getCloudReadArticles() -> Set<String> {
        let legacy = getStringSet(forKey: Keys.readArticles)
        let v2 = getV2ShardedSet(prefix: V2Keys.readArticlesShardPrefix)
        return legacy.union(v2)
    }

    // MARK: - Favorite Articles

    func syncFavoriteArticles(_ ids: Set<String>) {
        let normalized = Set(ids.map { ArticleIDNormalizer.normalize($0) })
        setStringSet(normalized, forKey: Keys.favoriteArticles)
        updateSyncTimestamp()
    }

    func getCloudFavoriteArticles() -> Set<String> {
        return getStringSet(forKey: Keys.favoriteArticles)
    }

    // MARK: - Read Reddit Posts

    func syncReadRedditPosts(_ ids: Set<String>) {
        let normalized = Set(ids.map { ArticleIDNormalizer.normalize($0) })
        let compacted = compactToCanonicalRedditIDs(normalized)
        guard !compacted.isEmpty else { return }
        pendingReadRedditPosts.formUnion(compacted)
        print("🔍 DIAGNOSTIC: syncReadRedditPosts called - hasCompletedInitialSync=\(hasCompletedInitialSync), ids.count=\(ids.count), compacted=\(compacted.count), pending=\(pendingReadRedditPosts.count)")
        guard hasCompletedInitialSync else {
            print("🔍 DIAGNOSTIC: Initial sync not complete, queued \(compacted.count) Reddit posts")
            return
        }
        flushPendingReadStateWritesIfPossible()
    }

    func getCloudReadRedditPosts() -> Set<String> {
        let legacy = getStringSet(forKey: Keys.readRedditPosts)
        let v2 = getV2ShardedSet(prefix: V2Keys.readRedditPostsShardPrefix)
        return compactToCanonicalRedditIDs(legacy.union(v2))
    }

    // MARK: - Favorite Reddit Posts

    func syncFavoriteRedditPosts(_ ids: Set<String>) {
        let normalized = Set(ids.map { ArticleIDNormalizer.normalize($0) })
        setStringSet(normalized, forKey: Keys.favoriteRedditPosts)
        updateSyncTimestamp()
    }

    func getCloudFavoriteRedditPosts() -> Set<String> {
        return getStringSet(forKey: Keys.favoriteRedditPosts)
    }

    // MARK: - Subscriptions

    /// Syncs subscriptions to cloud. Only works if this device is the primary device.
    /// Returns true if sync was performed, false if skipped (not primary).
    @discardableResult
    func syncSubscriptions(_ subscriptions: [Subscription]) -> Bool {
        guard isThisDevicePrimary else {
            print("☁️ CloudSyncManager: Skipping subscription sync - this device is not primary")
            return false
        }
        setSubscriptions(subscriptions, forKey: Keys.subscriptions)
        updateSyncTimestamp()
        print("☁️ CloudSyncManager: Synced \(subscriptions.count) subscriptions to cloud (primary device)")
        return true
    }

    /// Force sync subscriptions to cloud regardless of primary status.
    /// Use this when setting this device as primary and pushing initial subscriptions.
    func forceSyncSubscriptions(_ subscriptions: [Subscription]) {
        setSubscriptions(subscriptions, forKey: Keys.subscriptions)
        updateSyncTimestamp()
        print("☁️ CloudSyncManager: Force synced \(subscriptions.count) subscriptions to cloud")
    }

    func getCloudSubscriptions() -> [Subscription] {
        return getSubscriptions(forKey: Keys.subscriptions)
    }

    // MARK: - Merge Helpers

    /// Merges local and cloud sets, returning the union.
    /// This ensures items marked as read on any device stay read.
    func mergeReadStates(local: Set<String>, cloud: Set<String>) -> Set<String> {
        return local.union(cloud)
    }

    // MARK: - Private Helpers

    private func flushPendingReadStateWritesIfPossible() {
        guard hasCompletedInitialSync else { return }

        if !pendingReadArticles.isEmpty {
            let queuedArticles = pendingReadArticles
            syncReadArticlesToCloud(queuedArticles)
            let cloudArticles = Set(getCloudReadArticles().map { ArticleIDNormalizer.normalize($0) })
            pendingReadArticles.subtract(cloudArticles)
            if !pendingReadArticles.isEmpty {
                print("⚠️ CloudSyncManager: \(pendingReadArticles.count) article read IDs still pending cloud sync")
            }
        }

        if !pendingReadRedditPosts.isEmpty {
            let queuedReddit = pendingReadRedditPosts
            syncReadRedditPostsToCloud(queuedReddit)
            let cloudReddit = compactToCanonicalRedditIDs(getCloudReadRedditPosts())
            pendingReadRedditPosts.subtract(cloudReddit)
            if !pendingReadRedditPosts.isEmpty {
                print("⚠️ CloudSyncManager: \(pendingReadRedditPosts.count) Reddit read IDs still pending cloud sync")
            }
        }
    }

    private func publishCurrentReadStateSnapshot(context: String) {
        let readArticles = getCloudReadArticles()
        let favoriteArticles = getStringSet(forKey: Keys.favoriteArticles)
        let readRedditPosts = getCloudReadRedditPosts()
        let favoriteRedditPosts = getStringSet(forKey: Keys.favoriteRedditPosts)
        let subscriptions = getSubscriptions(forKey: Keys.subscriptions)

        print("☁️ CloudSyncManager: Read-state snapshot after \(context) - Articles: \(readArticles.count), Reddit: \(readRedditPosts.count) [mainThread=\(Thread.isMainThread)]")
        // Show sample IDs for debugging
        let sampleArticleIds = Array(readArticles.prefix(3))
        print("   → Sample article IDs from iCloud: \(sampleArticleIds)")

        // Publish to CurrentValueSubject for replay to late subscribers
        let snapshot = ReadStateSnapshot(
            readArticles: readArticles,
            favoriteArticles: favoriteArticles,
            readRedditPosts: readRedditPosts,
            favoriteRedditPosts: favoriteRedditPosts,
            subscriptions: subscriptions
        )
        snapshotPublisher.send(snapshot)

        // Also publish to legacy PassthroughSubject for existing subscribers
        remoteChangesPublisher.send(.readArticles(readArticles))
        remoteChangesPublisher.send(.favoriteArticles(favoriteArticles))
        remoteChangesPublisher.send(.readRedditPosts(readRedditPosts))
        remoteChangesPublisher.send(.favoriteRedditPosts(favoriteRedditPosts))
    }

    /// Force publish current state - call this for catch-up after subscribing
    func publishCurrentSnapshot() {
        publishCurrentReadStateSnapshot(context: "manual catch-up")
    }

    private func syncReadArticlesToCloud(_ normalizedIDs: Set<String>) {
        // V2: add IDs to this device's sharded keys (grow-only).
        let result = addIDsToV2Shards(normalizedIDs, prefix: V2Keys.readArticlesShardPrefix)
        guard result.addedCount > 0 else {
            print("🔍 DIAGNOSTIC: No new articles to sync (v2)")
            return
        }
        updateSyncTimestamp()
        // Force immediate sync to ensure iPad→iPhone works reliably
        let syncResult = cloudStore.synchronize()
        print("☁️ CloudSyncManager: Synced \(normalizedIDs.count) read articles to cloud (v2 add=\(result.addedCount), shards=\(result.changedShards)), synchronize()=\(syncResult)")
    }

    private func syncReadRedditPostsToCloud(_ normalizedIDs: Set<String>) {
        // V2: add IDs to this device's sharded keys (grow-only).
        let result = addIDsToV2Shards(normalizedIDs, prefix: V2Keys.readRedditPostsShardPrefix)
        guard result.addedCount > 0 else {
            print("🔍 DIAGNOSTIC: No new Reddit posts to sync (v2)")
            return
        }
        updateSyncTimestamp()
        // Force immediate sync to ensure iPad→iPhone works reliably
        let syncResult = cloudStore.synchronize()
        print("☁️ CloudSyncManager: Synced \(normalizedIDs.count) read Reddit posts to cloud (v2 add=\(result.addedCount), shards=\(result.changedShards)), synchronize()=\(syncResult)")
    }

    private struct V2AddResult {
        let addedCount: Int
        let changedShards: Int
    }

    private func stableHash64(_ string: String) -> UInt64 {
        // FNV-1a 64-bit (stable across launches).
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return hash
    }

    private func shardIndex(for id: String) -> Int {
        Int(stableHash64(id) % UInt64(V2Keys.shardCount))
    }

    private func v2ShardKey(prefix: String, deviceID: String, shard: Int) -> String {
        "\(prefix)\(deviceID)_\(shard)"
    }

    private func getV2ShardedSet(prefix: String) -> Set<String> {
        var keys = Set(cloudStore.dictionaryRepresentation.keys.filter { $0.hasPrefix(prefix) })
        let indexedDeviceIDs = getStringSet(forKey: v2DeviceIndexKey(for: prefix))
        if !indexedDeviceIDs.isEmpty {
            for deviceID in indexedDeviceIDs {
                for shard in 0..<V2Keys.shardCount {
                    keys.insert(v2ShardKey(prefix: prefix, deviceID: deviceID, shard: shard))
                }
            }
        }
        guard !keys.isEmpty else { return [] }
        var merged: Set<String> = []
        for key in keys {
            merged.formUnion(getStringSet(forKey: key))
        }
        return merged
    }

    private func addIDsToV2Shards(_ ids: Set<String>, prefix: String) -> V2AddResult {
        registerCurrentDeviceForV2(prefix: prefix)
        let idsToWrite: Set<String>
        if prefix == V2Keys.readRedditPostsShardPrefix {
            idsToWrite = compactToCanonicalRedditIDs(ids)
        } else {
            idsToWrite = ids
        }
        guard !idsToWrite.isEmpty else { return V2AddResult(addedCount: 0, changedShards: 0) }

        var idsByShard: [Int: Set<String>] = [:]
        for id in idsToWrite {
            let shard = shardIndex(for: id)
            idsByShard[shard, default: []].insert(id)
        }

        var totalAdded = 0
        var changedShards = 0

        for (shard, shardIDsToAdd) in idsByShard {
            let key = v2ShardKey(prefix: prefix, deviceID: thisDeviceID, shard: shard)
            let existing = getStringSet(forKey: key)
            let merged = existing.union(shardIDsToAdd)
            let added = merged.count - existing.count
            guard added > 0 else { continue }
            totalAdded += added
            changedShards += 1
            setStringSet(merged, forKey: key)
        }

        return V2AddResult(addedCount: totalAdded, changedShards: changedShards)
    }

    private func compactToCanonicalRedditIDs(_ ids: Set<String>) -> Set<String> {
        guard !ids.isEmpty else { return [] }
        var canonical: Set<String> = []
        for raw in ids {
            if let postID = canonicalRedditPostID(from: raw) {
                canonical.insert(postID)
            }
        }
        return canonical
    }

    private func canonicalRedditPostID(from token: String) -> String? {
        let normalized = ArticleIDNormalizer.normalize(token)
        guard !normalized.isEmpty else { return nil }

        if normalized.hasPrefix("t3_") {
            let short = String(normalized.dropFirst(3))
            return isLikelyRedditPostID(short) ? short : nil
        }
        if isLikelyRedditPostID(normalized) {
            return normalized
        }
        if let permalinkID = redditPostID(fromPermalink: normalized) {
            return permalinkID
        }
        return nil
    }

    private func isLikelyRedditPostID(_ token: String) -> Bool {
        guard (4...10).contains(token.count) else { return false }
        return token.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) }
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

        guard let commentsIndex = parts.firstIndex(where: { $0.lowercased() == "comments" }),
              parts.count > commentsIndex + 1 else {
            return nil
        }

        let postID = parts[commentsIndex + 1].lowercased()
        return isLikelyRedditPostID(postID) ? postID : nil
    }

    private func compactReadStateForQuotaIfNeeded() {
        guard !isQuotaCompactionInProgress else { return }
        isQuotaCompactionInProgress = true
        defer { isQuotaCompactionInProgress = false }

        let now = Date()
        if let lastAttempt = lastQuotaCompactionAttempt, now.timeIntervalSince(lastAttempt) < 30 {
            return
        }
        lastQuotaCompactionAttempt = now

        let allArticles = Set(getCloudReadArticles().map { ArticleIDNormalizer.normalize($0) })
        let allReddit = compactToCanonicalRedditIDs(getCloudReadRedditPosts())
        let trimmedArticles = trimForQuota(allArticles, maxEntries: V2Keys.quotaMaxArticles)
        let trimmedReddit = trimForQuota(allReddit, maxEntries: V2Keys.quotaMaxRedditPosts)

        let articleRewrite = rewriteV2Shards(prefix: V2Keys.readArticlesShardPrefix, ids: trimmedArticles)
        let redditRewrite = rewriteV2Shards(prefix: V2Keys.readRedditPostsShardPrefix, ids: trimmedReddit)

        let hadLegacyArticles = !getStringSet(forKey: Keys.readArticles).isEmpty
        let hadLegacyReddit = !getStringSet(forKey: Keys.readRedditPosts).isEmpty
        if hadLegacyArticles {
            cloudStore.removeObject(forKey: Keys.readArticles)
        }
        if hadLegacyReddit {
            cloudStore.removeObject(forKey: Keys.readRedditPosts)
        }

        let removedArticles = max(0, allArticles.count - trimmedArticles.count)
        let removedReddit = max(0, allReddit.count - trimmedReddit.count)
        let madeChanges = articleRewrite.changed || redditRewrite.changed || hadLegacyArticles || hadLegacyReddit || removedArticles > 0 || removedReddit > 0
        guard madeChanges else { return }

        updateSyncTimestamp()
        let syncResult = cloudStore.synchronize()
        print("☁️ CloudSyncManager: Quota compaction rewritten v2 read-state - articles \(allArticles.count)→\(trimmedArticles.count), reddit \(allReddit.count)→\(trimmedReddit.count), articleShards=\(articleRewrite.shardsWritten), redditShards=\(redditRewrite.shardsWritten), removedLegacyArticles=\(hadLegacyArticles), removedLegacyReddit=\(hadLegacyReddit), synchronize()=\(syncResult)")
        logTotalDataSize()
        flushPendingReadStateWritesIfPossible()
        publishCurrentReadStateSnapshot(context: "quota compaction")
    }

    private struct V2RewriteResult {
        let changed: Bool
        let shardsWritten: Int
    }

    private func rewriteV2Shards(prefix: String, ids: Set<String>) -> V2RewriteResult {
        let indexKey = v2DeviceIndexKey(for: prefix)
        let shardKeys = allV2ShardKeys(prefix: prefix)
        var removedKeys = 0

        for key in shardKeys {
            cloudStore.removeObject(forKey: key)
            removedKeys += 1
        }
        cloudStore.removeObject(forKey: indexKey)
        removedKeys += 1

        registerCurrentDeviceForV2(prefix: prefix)
        guard !ids.isEmpty else {
            return V2RewriteResult(changed: removedKeys > 0, shardsWritten: 0)
        }

        var idsByShard: [Int: Set<String>] = [:]
        for id in ids {
            let shard = shardIndex(for: id)
            idsByShard[shard, default: []].insert(id)
        }

        var shardsWritten = 0
        for (shard, shardIDs) in idsByShard {
            let key = v2ShardKey(prefix: prefix, deviceID: thisDeviceID, shard: shard)
            setStringSet(shardIDs, forKey: key)
            shardsWritten += 1
        }

        return V2RewriteResult(changed: removedKeys > 0 || shardsWritten > 0, shardsWritten: shardsWritten)
    }

    private func trimForQuota(_ ids: Set<String>, maxEntries: Int) -> Set<String> {
        guard ids.count > maxEntries else { return ids }
        // Deterministic trim to cap KVS usage while preserving a large recent-history window.
        return Set(ids.sorted().suffix(maxEntries))
    }

    private func cleanupRedundantLegacyReadKeysIfPossible() -> (removedArticles: Bool, removedReddit: Bool) {
        var removedArticles = false
        var removedReddit = false

        let legacyArticlesRaw = getStringSet(forKey: Keys.readArticles)
        if !legacyArticlesRaw.isEmpty {
            let legacyArticles = Set(legacyArticlesRaw.map { ArticleIDNormalizer.normalize($0) })
            let v2Articles = Set(getV2ShardedSet(prefix: V2Keys.readArticlesShardPrefix).map { ArticleIDNormalizer.normalize($0) })
            if !v2Articles.isEmpty && v2Articles.isSuperset(of: legacyArticles) {
                cloudStore.removeObject(forKey: Keys.readArticles)
                removedArticles = true
            }
        }

        let legacyRedditRaw = getStringSet(forKey: Keys.readRedditPosts)
        if !legacyRedditRaw.isEmpty {
            let legacyReddit = compactToCanonicalRedditIDs(legacyRedditRaw)
            let v2Reddit = compactToCanonicalRedditIDs(getV2ShardedSet(prefix: V2Keys.readRedditPostsShardPrefix))
            if !v2Reddit.isEmpty && v2Reddit.isSuperset(of: legacyReddit) {
                cloudStore.removeObject(forKey: Keys.readRedditPosts)
                removedReddit = true
            }
        }

        return (removedArticles, removedReddit)
    }

    private func allV2ShardKeys(prefix: String) -> Set<String> {
        var keys = Set(cloudStore.dictionaryRepresentation.keys.filter { $0.hasPrefix(prefix) })
        let indexedDeviceIDs = getStringSet(forKey: v2DeviceIndexKey(for: prefix))
        for deviceID in indexedDeviceIDs {
            for shard in 0..<V2Keys.shardCount {
                keys.insert(v2ShardKey(prefix: prefix, deviceID: deviceID, shard: shard))
            }
        }
        return keys
    }

    private func v2DeviceIndexKey(for prefix: String) -> String {
        if prefix == V2Keys.readArticlesShardPrefix {
            return V2Keys.readArticlesDeviceIndexKey
        }
        return V2Keys.readRedditPostsDeviceIndexKey
    }

    private func registerCurrentDeviceForV2(prefix: String) {
        let indexKey = v2DeviceIndexKey(for: prefix)
        var deviceIDs = getStringSet(forKey: indexKey)
        if deviceIDs.contains(thisDeviceID) {
            return
        }
        deviceIDs.insert(thisDeviceID)
        setStringSet(deviceIDs, forKey: indexKey)
    }

    private func setStringSet(_ set: Set<String>, forKey key: String) {
        // Store directly as a property list array (native for NSUbiquitousKeyValueStore).
        cloudStore.set(Array(set), forKey: key)
    }

    #if os(iOS)
    private func provisioningProfileEntitlements() -> [String: Any]? {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let profile = String(data: data, encoding: .ascii) else {
            return nil
        }

        guard let plistStart = profile.range(of: "<plist"),
              let plistEnd = profile.range(of: "</plist>") else {
            return nil
        }

        let plistString = String(profile[plistStart.lowerBound..<plistEnd.upperBound])
        guard let plistData = plistString.data(using: .utf8) else {
            return nil
        }

        guard let plistObject = try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil),
              let plist = plistObject as? [String: Any],
              let entitlements = plist["Entitlements"] as? [String: Any] else {
            return nil
        }

        return entitlements
    }
    #endif

    private func getStringSet(forKey key: String) -> Set<String> {
        // Current format: [String] stored directly (property list).
        if let array = cloudStore.array(forKey: key) as? [String] {
            return Set(array)
        }

        // Backwards compatibility: some older builds stored the array as encoded Data.
        if let data = cloudStore.data(forKey: key) {
            if let array = try? JSONDecoder().decode([String].self, from: data) {
                return Set(array)
            }
            // Backwards compatibility: some older builds may have used property lists.
            if let array = try? PropertyListDecoder().decode([String].self, from: data) {
                return Set(array)
            }
        }

        return []
    }

    private func setSubscriptions(_ subscriptions: [Subscription], forKey key: String) {
        if let data = try? JSONEncoder().encode(subscriptions) {
            cloudStore.set(data, forKey: key)
        }
    }

    private func getSubscriptions(forKey key: String) -> [Subscription] {
        guard let data = cloudStore.data(forKey: key),
              let array = try? JSONDecoder().decode([Subscription].self, from: data) else {
            return []
        }
        return array
    }

    private func updateSyncTimestamp() {
        cloudStore.set(Date().timeIntervalSince1970, forKey: Keys.lastSyncTimestamp)
    }

    func getLastSyncTimestamp() -> Date? {
        let timestamp = cloudStore.double(forKey: Keys.lastSyncTimestamp)
        guard timestamp > 0 else { return nil }
        return Date(timeIntervalSince1970: timestamp)
    }

    /// Force an immediate sync with iCloud
    @discardableResult
    func forceSynchronize() -> Bool {
        let syncStarted = cloudStore.synchronize()
        if syncStarted && !hasCompletedInitialSync {
            hasCompletedInitialSync = true
            flushPendingReadStateWritesIfPossible()
            publishCurrentReadStateSnapshot(context: "manual synchronize")
        }
        return syncStarted
    }

    // MARK: - Read History Migration (Legacy → V2)

    struct ReadHistoryMigrationResult {
        let migrated: Bool
        let legacyArticlesCount: Int
        let legacyRedditCount: Int
        let articlesAdded: Int
        let redditAdded: Int
        let deletedLegacyKeys: Bool
    }

    /// One-time migration to seed the legacy single-key read history into the v2 sharded keys.
    /// Run this on the primary device to fix badge mismatches on other devices.
    @discardableResult
    func migrateLegacyReadHistoryToV2(deleteLegacyKeys: Bool) -> ReadHistoryMigrationResult {
        // Only the primary device should migrate, to avoid secondary devices seeding incomplete history.
        if hasPrimaryDevice && !isThisDevicePrimary {
            print("☁️ CloudSyncManager: Skipping read-history migration (not primary)")
            return ReadHistoryMigrationResult(
                migrated: false,
                legacyArticlesCount: 0,
                legacyRedditCount: 0,
                articlesAdded: 0,
                redditAdded: 0,
                deletedLegacyKeys: false
            )
        }

        let syncStarted = cloudStore.synchronize()

        // Read legacy keys only (do not include v2 union here).
        let legacyArticlesRaw = getStringSet(forKey: Keys.readArticles)
        let legacyRedditRaw = getStringSet(forKey: Keys.readRedditPosts)
        let legacyArticles = Set(legacyArticlesRaw.map { ArticleIDNormalizer.normalize($0) })
        let legacyReddit = Set(legacyRedditRaw.map { ArticleIDNormalizer.normalize($0) })

        let articlesResult = addIDsToV2Shards(legacyArticles, prefix: V2Keys.readArticlesShardPrefix)
        let redditResult = addIDsToV2Shards(legacyReddit, prefix: V2Keys.readRedditPostsShardPrefix)

        updateSyncTimestamp()
        let syncAfterWrite = cloudStore.synchronize()

        var deleted = false
        if deleteLegacyKeys {
            cloudStore.removeObject(forKey: Keys.readArticles)
            cloudStore.removeObject(forKey: Keys.readRedditPosts)
            updateSyncTimestamp()
            _ = cloudStore.synchronize()
            deleted = true
        }

        DispatchQueue.main.async { [weak self] in
            self?.publishCurrentReadStateSnapshot(context: deleted ? "legacy migration + cleanup" : "legacy migration")
        }

        print("☁️ CloudSyncManager: Read-history migration to v2 complete - legacy articles=\(legacyArticles.count), legacy reddit=\(legacyReddit.count), v2 add articles=\(articlesResult.addedCount), v2 add reddit=\(redditResult.addedCount), deletedLegacy=\(deleted), syncStarted=\(syncStarted), syncAfterWrite=\(syncAfterWrite)")
        logTotalDataSize()

        return ReadHistoryMigrationResult(
            migrated: true,
            legacyArticlesCount: legacyArticles.count,
            legacyRedditCount: legacyReddit.count,
            articlesAdded: articlesResult.addedCount,
            redditAdded: redditResult.addedCount,
            deletedLegacyKeys: deleted
        )
    }

    // MARK: - Cleanup (for future use if quota exceeded)

    /// Removes old entries to stay within quota. Call this if quota violation occurs.
    /// Keeps the most recent entries based on a provided limit.
    func pruneOldEntries(keeping maxEntries: Int = 10000) {
        // WARNING: Pruning drops read history and can change unread counts.
        // Only call this intentionally (e.g., as part of a dedicated migration/cleanup flow).
        let readArticles = Set(getCloudReadArticles().map { ArticleIDNormalizer.normalize($0) })
        let readPosts = compactToCanonicalRedditIDs(getCloudReadRedditPosts())
        let trimmedArticles = trimForQuota(readArticles, maxEntries: maxEntries)
        let trimmedPosts = trimForQuota(readPosts, maxEntries: maxEntries)
        let articleRewrite = rewriteV2Shards(prefix: V2Keys.readArticlesShardPrefix, ids: trimmedArticles)
        let redditRewrite = rewriteV2Shards(prefix: V2Keys.readRedditPostsShardPrefix, ids: trimmedPosts)
        let changed = articleRewrite.changed || redditRewrite.changed
        if changed {
            updateSyncTimestamp()
            cloudStore.synchronize()
        }
        print("☁️ CloudSyncManager: Pruned read history - articles \(readArticles.count)→\(trimmedArticles.count), reddit \(readPosts.count)→\(trimmedPosts.count)")
        logTotalDataSize()
    }

    private func logTotalDataSize() {
        var totalBytes = 0
        var keys = [Keys.readArticles, Keys.favoriteArticles, Keys.readRedditPosts, Keys.favoriteRedditPosts, Keys.subscriptions]
        keys.append(contentsOf: cloudStore.dictionaryRepresentation.keys.filter { $0.hasPrefix("cloud_v2_") })
        
        for key in keys {
            if let data = cloudStore.data(forKey: key) {
                totalBytes += data.count
            } else if let array = cloudStore.array(forKey: key) {
                // Estimate for array
                if let estimated = try? JSONSerialization.data(withJSONObject: array).count {
                    totalBytes += estimated
                }
            }
        }
        
        print("☁️ CloudSyncManager: Estimated total KVS usage: \(totalBytes) bytes (Limit: 1,048,576 bytes)")
        if totalBytes > 900_000 {
            print("⚠️ CloudSyncManager: Approaching 1MB limit!")
        }
    }
}

enum ArticleIDNormalizer {
    static func normalize(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }

        guard var components = URLComponents(string: trimmed) else {
            return trimmed
        }

        components.fragment = nil
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()

        if let port = components.port, (port == 80 || port == 443) {
            components.port = nil
        }

        if let items = components.queryItems, !items.isEmpty {
            // Filter out tracking params that can change between fetches, causing ID instability
            let filtered = items.filter { item in
                let name = item.name.lowercased()
                // UTM campaign tracking
                if name.hasPrefix("utm_") { return false }
                // Facebook/Meta tracking
                if name == "fbclid" { return false }
                // Google Ads tracking
                if name == "gclid" { return false }
                if name == "dclid" { return false }
                // Mailchimp tracking
                if name == "mc_cid" { return false }
                if name == "mc_eid" { return false }
                // Generic referral/source tracking
                if name == "ref" { return false }
                if name == "source" { return false }
                if name == "src" { return false }
                // Session/analytics IDs that change per visit
                if name == "sessionid" { return false }
                if name == "session_id" { return false }
                if name == "sid" { return false }
                if name == "_ga" { return false }
                if name == "_gl" { return false }
                // Microsoft/Bing tracking
                if name == "msclkid" { return false }
                // Twitter/X tracking
                if name == "twclid" { return false }
                // TikTok tracking
                if name == "ttclid" { return false }
                // LinkedIn tracking
                if name == "li_fat_id" { return false }
                // Pinterest tracking
                if name == "epik" { return false }
                // Outbrain/Taboola and other content discovery
                if name == "oborigurl" { return false }
                if name == "dicbo" { return false }
                // News site specific tracking
                if name == "partner" { return false }
                if name == "channel" { return false }
                if name == "campaign" { return false }
                if name == "cmpid" { return false }
                if name == "cid" { return false }
                // Cache busting params
                if name == "_" { return false }
                if name == "t" && (item.value?.count ?? 0) > 8 { return false } // Timestamp param
                if name == "ts" { return false }
                if name == "timestamp" { return false }
                if name == "nocache" { return false }
                if name == "cachebust" { return false }
                return true
            }

            if filtered.isEmpty {
                components.queryItems = nil
            } else {
                components.queryItems = filtered.sorted {
                    let ln = $0.name.lowercased()
                    let rn = $1.name.lowercased()
                    if ln != rn { return ln < rn }
                    return ($0.value ?? "") < ($1.value ?? "")
                }
            }
        }

        if var path = components.percentEncodedPath.removingPercentEncoding {
            if path.count > 1 && path.hasSuffix("/") {
                path.removeLast()
            }
            components.percentEncodedPath = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? components.percentEncodedPath
        }

        return components.string ?? trimmed
    }
}
