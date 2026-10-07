//
//  CloudKitSyncManager.swift
//  RSSReaderApp
//
//  Syncs read states, favorites and subscriptions through CloudKit (the user's private
//  database), one record per item. Replaces iCloud key-value storage as the source of truth
//  on updated devices: no 1 MB limit, and errors that can be seen and retried.
//  The key-value sync keeps running alongside it so older app versions keep working.
//
//  Favorite and subscription records are never deleted: each carries its state (favorited or
//  not, subscribed or removed) and when the user made that change, and the newest change wins.
//  "The record exists" can't mean "favorited", because a stale upload from another device
//  would then bring back something the user had just removed.
//

import CloudKit
import Combine
import CryptoKit
import Foundation
#if os(iOS)
import UIKit
#endif

enum CloudKitItemKind: String, Codable {
    case article
    case reddit
}

/// Changes that arrived from other devices through CloudKit.
enum CloudKitChange {
    case reads(CloudKitItemKind, Set<String>)
    case favorites(CloudKitItemKind, added: Set<String>, removed: Set<String>, removedRecordNames: Set<String>)
    case subscriptions(upserted: [Subscription], removedKeys: Set<String>, removedRecordNames: Set<String>)
}

/// What a device uploads the first time it syncs with an iCloud account.
struct CloudKitInitialUpload {
    var readArticles: Set<String>
    var readRedditPosts: Set<String>
    var favoriteArticles: Set<String>
    var favoriteRedditPosts: Set<String>
    var subscriptions: [Subscription]
}

final class CloudKitSyncManager: @unchecked Sendable {
    static let shared = CloudKitSyncManager()

    static let containerIdentifier = "iCloud.com.joaovalente.RSSReaderApp"
    private static let zoneName = "RSSumSync"
    /// Older read history doesn't affect any badge, so the first upload is capped.
    private static let initialReadUploadLimit = 2_000
    /// A device's one-time upload is dated here, so it never overrides a change a user made.
    private static let initialUploadDate = Date(timeIntervalSince1970: 1)

    private enum RecordType {
        static let read = "ReadItem"
        static let favorite = "Favorite"
        static let subscription = "Subscription"
    }

    private enum Field {
        static let kind = "kind"
        static let itemID = "itemID"
        static let date = "date"
        static let title = "title"
        static let url = "url"
        static let type = "type"
        static let contentKind = "contentKind"
        static let isFavorite = "isFavorite"
        static let isDeleted = "isDeleted"
        /// When the user made the change (not when it was uploaded).
        static let changedAt = "changedAt"
    }

    /// Delivered on the main queue.
    let changes = PassthroughSubject<CloudKitChange, Never>()
    /// Supplies local data for the one-time upload; set by PersistenceManager.
    var initialUploadProvider: (() -> CloudKitInitialUpload)?

    private let zoneID = CKRecordZone.ID(zoneName: zoneName, ownerName: CKCurrentUserDefaultName)
    private let lock = NSLock()
    private var engine: CKSyncEngine?
    private var data = LocalData()
    private var pendingSave: DispatchWorkItem?
    private var foregroundObserver: NSObjectProtocol?

    /// True once CloudKit sync is running with an available iCloud account.
    private(set) var isActive = false

    // Shown in Settings → Cloud Sync so sync problems can be seen.
    private var accountMessage: String?
    private var lastFetch: Date?
    private var lastSend: Date?
    private var lastError: String?
    private var lastErrorDate: Date?
    private var lastSuccessfulSend: Date?
    private var sentCounts: [String: Int] = [:]
    private var receivedCounts: [String: Int] = [:]

    private init() {
        data = Self.loadLocalData() ?? LocalData()
    }

    // MARK: - Local persistence

    private enum Payload: Codable {
        case read(CloudKitItemKind, String)
        case favorite(CloudKitItemKind, String, isFavorite: Bool, changedAt: Date)
        case subscription(Subscription, isDeleted: Bool, changedAt: Date)

        var changedAt: Date? {
            switch self {
            case .read: return nil
            case .favorite(_, _, _, let changedAt): return changedAt
            case .subscription(_, _, let changedAt): return changedAt
            }
        }
    }

    private struct LocalData: Codable {
        var engineState: CKSyncEngine.State.Serialization?
        /// Records waiting to be sent, by record name.
        var pending: [String: Payload] = [:]
        /// Last server copy of favorites/subscriptions, so updates don't conflict.
        var systemFields: [String: Data] = [:]
        /// When the newest known change to each favorite/subscription was made, from this
        /// device or another one; older incoming changes are ignored.
        var changeTimes: [String: Date] = [:]
        var didInitialUpload = false
    }

    private static var dataURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("CloudKitSync", isDirectory: true)
            .appendingPathComponent("SyncState.json")
    }

    private static func loadLocalData() -> LocalData? {
        guard let url = dataURL, let stored = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(LocalData.self, from: stored)
    }

    private func scheduleLocalSave() {
        let work = DispatchWorkItem { [weak self] in self?.saveLocalData() }
        lock.lock()
        pendingSave?.cancel()
        pendingSave = work
        lock.unlock()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1, execute: work)
    }

    private func saveLocalData() {
        lock.lock()
        let snapshot = data
        lock.unlock()
        guard let url = Self.dataURL, let encoded = try? JSONEncoder().encode(snapshot) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? encoded.write(to: url, options: .atomic)
    }

    // MARK: - Start

    /// Starts syncing if the user is signed in to iCloud. Safe to call more than once.
    func start() {
        Task { await startIfPossible() }
        #if os(iOS)
        if foregroundObserver == nil {
            foregroundObserver = NotificationCenter.default.addObserver(
                forName: UIApplication.willEnterForegroundNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.syncNow()
            }
        }
        #endif
    }

    private func startIfPossible() async {
        guard engine == nil else { return }
        let status: CKAccountStatus
        do {
            status = try await CKContainer(identifier: Self.containerIdentifier).accountStatus()
        } catch {
            syncLog("☁️ CloudKit: account status unavailable - \(error.localizedDescription)")
            lock.withLock { accountMessage = "iCloud account unavailable: \(error.localizedDescription)" }
            return
        }
        guard status == .available else {
            syncLog("☁️ CloudKit: no iCloud account available (status \(status.rawValue))")
            lock.withLock { accountMessage = "Not signed in to iCloud (status \(status.rawValue))" }
            return
        }
        lock.withLock { accountMessage = nil }

        lock.lock()
        let savedState = data.engineState
        let isFirstRun = savedState == nil
        lock.unlock()

        let configuration = CKSyncEngine.Configuration(
            database: CKContainer(identifier: Self.containerIdentifier).privateCloudDatabase,
            stateSerialization: savedState,
            delegate: self
        )
        let newEngine = CKSyncEngine(configuration)
        lock.lock()
        engine = newEngine
        isActive = true
        let pendingNames = Array(data.pending.keys)
        lock.unlock()

        if isFirstRun {
            newEngine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])
        }
        // Re-queue anything left from a previous run.
        newEngine.state.add(pendingRecordZoneChanges: pendingNames.map { .saveRecord(recordID($0)) })

        performInitialUploadIfNeeded()
        syncNow()
        syncLog("☁️ CloudKit: sync engine started")
    }

    /// Fetches changes from other devices, then sends local ones.
    func syncNow() {
        guard let engine = lock.withLock({ self.engine }) else {
            start()
            return
        }
        Task {
            do {
                try await engine.fetchChanges()
                try await engine.sendChanges()
            } catch {
                syncLog("☁️ CloudKit: sync failed - \(error.localizedDescription)")
                guard !Self.isOnlyExpectedConflicts(error) else { return }
                self.lock.withLock { self.lastErrorDate = Date(); self.lastError = "Sync: \(Self.describe(error))" }
            }
        }
    }

    private func performInitialUploadIfNeeded() {
        guard !lock.withLock({ data.didInitialUpload }) else { return }
        guard let provider = initialUploadProvider else { return }
        let upload = Thread.isMainThread ? provider() : DispatchQueue.main.sync { provider() }

        let recentArticles = ReadRecencyStore.shared.newest(upload.readArticles, limit: Self.initialReadUploadLimit)
        let recentReddit = ReadRecencyStore.shared.newest(upload.readRedditPosts, limit: Self.initialReadUploadLimit)
        var payloads: [String: Payload] = [:]
        for id in recentArticles { payloads[Self.readRecordName(.article, id)] = .read(.article, id) }
        for id in recentReddit { payloads[Self.readRecordName(.reddit, id)] = .read(.reddit, id) }
        let seed = Self.initialUploadDate
        for id in upload.favoriteArticles {
            payloads[Self.favoriteRecordName(.article, id)] = .favorite(.article, id, isFavorite: true, changedAt: seed)
        }
        for id in upload.favoriteRedditPosts {
            payloads[Self.favoriteRecordName(.reddit, id)] = .favorite(.reddit, id, isFavorite: true, changedAt: seed)
        }
        for subscription in upload.subscriptions {
            payloads[Self.subscriptionRecordName(subscription.canonicalKey)] = .subscription(subscription, isDeleted: false, changedAt: seed)
        }

        lock.withLock { data.didInitialUpload = true }
        enqueueSaves(payloads)
        syncLog("☁️ CloudKit: queued first upload of \(payloads.count) record(s)")
    }

    // MARK: - Status

    /// Two devices uploading the same item, or the rest of a batch waiting on such an item, is
    /// expected (handled in `handleSent`) and not worth reporting as an error.
    private static func isOnlyExpectedConflicts(_ error: Error) -> Bool {
        guard let ckError = error as? CKError, ckError.code == .partialFailure,
              let partials = ckError.partialErrorsByItemID?.values, !partials.isEmpty else { return false }
        return partials.allSatisfy { partial in
            guard let code = (partial as? CKError)?.code else { return false }
            return code == .serverRecordChanged || code == .batchRequestFailed
        }
    }

    /// CloudKit's own messages are often generic ("Failed to send changes"); include the code,
    /// the first per-item reason and any retry delay so a problem can actually be diagnosed.
    private static func describe(_ error: Error) -> String {
        guard let ckError = error as? CKError else { return error.localizedDescription }
        var text = "\(ckError.code) (\(ckError.code.rawValue))"
        if let partial = ckError.partialErrorsByItemID?.values.first as? CKError {
            text += " · first item: \(partial.code) (\(partial.code.rawValue)) \(partial.localizedDescription)"
        } else {
            text += " · \(ckError.localizedDescription)"
        }
        if let retry = ckError.retryAfterSeconds {
            text += " · retry in \(Int(retry))s"
        }
        return text
    }

    struct FriendlyStatus {
        let text: String
        let systemImage: String
        let isProblem: Bool
    }

    /// One plain line for Settings → Cloud Sync; the technical summary sits behind "Sync Details".
    func friendlyStatus() -> FriendlyStatus {
        lock.lock()
        defer { lock.unlock() }
        if accountMessage != nil {
            return FriendlyStatus(text: "iCloud sync is off. Sign in to iCloud in the Settings app to sync.", systemImage: "icloud.slash", isProblem: true)
        }
        guard isActive else {
            return FriendlyStatus(text: "Connecting to iCloud…", systemImage: "icloud", isProblem: false)
        }
        let pending = data.pending.count
        if pending > 0, let errorDate = lastErrorDate, errorDate > (lastSuccessfulSend ?? .distantPast) {
            return FriendlyStatus(text: "Sync problem. Tap Sync Now to retry.", systemImage: "exclamationmark.icloud", isProblem: true)
        }
        if pending > 0 {
            return FriendlyStatus(text: "Syncing… \(pending) item\(pending == 1 ? "" : "s") left", systemImage: "arrow.triangle.2.circlepath.icloud", isProblem: false)
        }
        let lastSync = [lastFetch, lastSend].compactMap { $0 }.max()
        let time = lastSync.map { " · " + $0.formatted(date: .omitted, time: .shortened) } ?? ""
        return FriendlyStatus(text: "Synced with iCloud\(time)", systemImage: "checkmark.icloud", isProblem: false)
    }

    /// The technical summary shown under "Sync Details".
    func statusSummary() -> String {
        lock.lock()
        defer { lock.unlock() }
        if let accountMessage { return "CloudKit: off. \(accountMessage)" }
        guard isActive else { return "CloudKit: starting…" }

        let time: (Date?) -> String = { date in
            guard let date else { return "not yet" }
            return date.formatted(date: .omitted, time: .standard)
        }
        let counts: ([String: Int]) -> String = { dict in
            dict.isEmpty ? "none" : dict.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
        }
        var lines = [
            "CloudKit: on · waiting to send: \(data.pending.count)",
            "Last fetch: \(time(lastFetch)) · last send: \(time(lastSend))",
            "Sent: \(counts(sentCounts))",
            "Received: \(counts(receivedCounts))"
        ]
        if let lastError { lines.append("Last error: \(lastError)") }
        return lines.joined(separator: "\n")
    }

    // MARK: - Local changes

    func recordReads(_ kind: CloudKitItemKind, ids: Set<String>) {
        guard !ids.isEmpty else { return }
        var payloads: [String: Payload] = [:]
        for id in ids { payloads[Self.readRecordName(kind, id)] = .read(kind, id) }
        enqueueSaves(payloads)
    }

    func setFavorite(_ kind: CloudKitItemKind, id: String, isFavorite: Bool) {
        let now = Date()
        let name = Self.favoriteRecordName(kind, id)
        lock.withLock { data.changeTimes[name] = now }
        enqueueSaves([name: .favorite(kind, id, isFavorite: isFavorite, changedAt: now)])
    }

    /// Records added, changed and removed subscriptions (all kinds, podcasts included).
    func recordSubscriptionChanges(from old: [Subscription], to new: [Subscription]) {
        let oldByKey = Dictionary(old.map { ($0.canonicalKey, $0) }, uniquingKeysWith: { first, _ in first })
        let newByKey = Dictionary(new.map { ($0.canonicalKey, $0) }, uniquingKeysWith: { first, _ in first })
        let now = Date()
        var saves: [String: Payload] = [:]
        for (key, subscription) in newByKey where oldByKey[key] != subscription {
            saves[Self.subscriptionRecordName(key)] = .subscription(subscription, isDeleted: false, changedAt: now)
        }
        for (key, subscription) in oldByKey where newByKey[key] == nil {
            saves[Self.subscriptionRecordName(key)] = .subscription(subscription, isDeleted: true, changedAt: now)
        }
        stampAndEnqueue(saves, at: now)
    }

    func saveSubscription(_ subscription: Subscription) {
        let now = Date()
        stampAndEnqueue([Self.subscriptionRecordName(subscription.canonicalKey): .subscription(subscription, isDeleted: false, changedAt: now)], at: now)
    }

    func deleteSubscription(_ subscription: Subscription) {
        let now = Date()
        stampAndEnqueue([Self.subscriptionRecordName(subscription.canonicalKey): .subscription(subscription, isDeleted: true, changedAt: now)], at: now)
    }

    private func stampAndEnqueue(_ payloads: [String: Payload], at date: Date) {
        guard !payloads.isEmpty else { return }
        lock.withLock {
            for name in payloads.keys { data.changeTimes[name] = date }
        }
        enqueueSaves(payloads)
    }

    private func enqueueSaves(_ payloads: [String: Payload]) {
        guard !payloads.isEmpty else { return }
        let engine: CKSyncEngine? = lock.withLock {
            for (name, payload) in payloads { data.pending[name] = payload }
            return self.engine
        }
        scheduleLocalSave()
        engine?.state.add(pendingRecordZoneChanges: payloads.keys.map { .saveRecord(recordID($0)) })
    }

    // MARK: - Record names

    private func recordID(_ name: String) -> CKRecord.ID {
        CKRecord.ID(recordName: name, zoneID: zoneID)
    }

    private static func hashed(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    static func readRecordName(_ kind: CloudKitItemKind, _ id: String) -> String {
        "read-\(kind.rawValue)-\(hashed(id))"
    }

    static func favoriteRecordName(_ kind: CloudKitItemKind, _ id: String) -> String {
        "fav-\(kind.rawValue)-\(hashed(id))"
    }

    static func subscriptionRecordName(_ canonicalKey: String) -> String {
        "sub-\(hashed(canonicalKey))"
    }

    // MARK: - Building and reading records

    private func record(for name: String, payload: Payload) -> CKRecord {
        let id = recordID(name)
        let recordType: String
        switch payload {
        case .read: recordType = RecordType.read
        case .favorite: recordType = RecordType.favorite
        case .subscription: recordType = RecordType.subscription
        }

        var record = CKRecord(recordType: recordType, recordID: id)
        if let fields = lock.withLock({ data.systemFields[name] }),
           let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: fields) {
            unarchiver.requiresSecureCoding = true
            if let stored = CKRecord(coder: unarchiver) { record = stored }
            unarchiver.finishDecoding()
        }

        switch payload {
        case .read(let kind, let itemID):
            record[Field.kind] = kind.rawValue
            record[Field.itemID] = itemID
            record[Field.date] = Date()
        case .favorite(let kind, let itemID, let isFavorite, let changedAt):
            record[Field.kind] = kind.rawValue
            record[Field.itemID] = itemID
            record[Field.isFavorite] = isFavorite ? 1 : 0
            record[Field.changedAt] = changedAt
        case .subscription(let subscription, let isDeleted, let changedAt):
            record[Field.title] = subscription.title
            record[Field.url] = subscription.url
            record[Field.type] = subscription.type.rawValue
            record[Field.contentKind] = subscription.contentKind?.rawValue
            record[Field.isDeleted] = isDeleted ? 1 : 0
            record[Field.changedAt] = changedAt
        }
        return record
    }

    private func rememberSystemFields(of record: CKRecord) {
        guard record.recordType != RecordType.read else { return }
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: archiver)
        archiver.finishEncoding()
        lock.withLock { data.systemFields[record.recordID.recordName] = archiver.encodedData }
    }

    /// When the user made the change a record holds. Records from before change times existed
    /// fall back to when they were last saved.
    private static func changedAt(of record: CKRecord) -> Date {
        (record[Field.changedAt] as? Date) ?? record.modificationDate ?? .distantPast
    }

    private static func subscription(from record: CKRecord) -> Subscription? {
        guard let url = record[Field.url] as? String,
              let typeRaw = record[Field.type] as? String,
              let type = SubscriptionType(rawValue: typeRaw) else { return nil }
        let title = (record[Field.title] as? String) ?? url
        let contentKind = (record[Field.contentKind] as? String).flatMap(SubscriptionContentKind.init(rawValue:))
        return Subscription(title: title, url: url, type: type, contentKind: contentKind)
    }

    // MARK: - Applying fetched changes

    private func applyFetched(_ event: CKSyncEngine.Event.FetchedRecordZoneChanges) {
        lock.withLock {
            for modification in event.modifications { receivedCounts[modification.record.recordType, default: 0] += 1 }
            for deletion in event.deletions { receivedCounts[deletion.recordType + " deleted", default: 0] += 1 }
        }
        var outgoing = changes(from: event.modifications.map(\.record))

        // Records deleted outright (by builds from before change times existed).
        var favoritesRemoved: [CloudKitItemKind: Set<String>] = [:]
        var subscriptionsRemoved = Set<String>()
        for deletion in event.deletions {
            let name = deletion.recordID.recordName
            lock.withLock { _ = data.systemFields.removeValue(forKey: name) }
            switch deletion.recordType {
            case RecordType.favorite:
                let kind: CloudKitItemKind = name.hasPrefix("fav-\(CloudKitItemKind.reddit.rawValue)-") ? .reddit : .article
                favoritesRemoved[kind, default: []].insert(name)
            case RecordType.subscription:
                subscriptionsRemoved.insert(name)
            default:
                break
            }
        }
        for (kind, names) in favoritesRemoved {
            outgoing.append(.favorites(kind, added: [], removed: [], removedRecordNames: names))
        }
        if !subscriptionsRemoved.isEmpty {
            outgoing.append(.subscriptions(upserted: [], removedKeys: [], removedRecordNames: subscriptionsRemoved))
        }
        scheduleLocalSave()
        deliver(outgoing)
    }

    /// Turns server records into local changes, keeping only favorite/subscription changes newer
    /// than what this device already knows (its own changes included).
    private func changes(from records: [CKRecord]) -> [CloudKitChange] {
        var reads: [CloudKitItemKind: Set<String>] = [:]
        var favoritesAdded: [CloudKitItemKind: Set<String>] = [:]
        var favoritesRemoved: [CloudKitItemKind: Set<String>] = [:]
        var subscriptionsUpserted: [Subscription] = []
        var subscriptionsRemoved = Set<String>()

        for record in records {
            rememberSystemFields(of: record)
            let name = record.recordID.recordName
            switch record.recordType {
            case RecordType.read:
                if let kind = (record[Field.kind] as? String).flatMap(CloudKitItemKind.init(rawValue:)),
                   let itemID = record[Field.itemID] as? String {
                    reads[kind, default: []].insert(itemID)
                }
            case RecordType.favorite:
                guard let kind = (record[Field.kind] as? String).flatMap(CloudKitItemKind.init(rawValue:)),
                      let itemID = record[Field.itemID] as? String,
                      acceptIfNewer(name, changedAt: Self.changedAt(of: record)) else { continue }
                if ((record[Field.isFavorite] as? Int64) ?? 1) != 0 {
                    favoritesAdded[kind, default: []].insert(itemID)
                } else {
                    favoritesRemoved[kind, default: []].insert(itemID)
                }
            case RecordType.subscription:
                guard let subscription = Self.subscription(from: record),
                      acceptIfNewer(name, changedAt: Self.changedAt(of: record)) else { continue }
                if ((record[Field.isDeleted] as? Int64) ?? 0) != 0 {
                    subscriptionsRemoved.insert(subscription.canonicalKey)
                } else {
                    subscriptionsUpserted.append(subscription)
                }
            default:
                break
            }
        }

        var result: [CloudKitChange] = []
        for (kind, ids) in reads { result.append(.reads(kind, ids)) }
        for kind in [CloudKitItemKind.article, .reddit] {
            let added = favoritesAdded[kind] ?? []
            let removed = favoritesRemoved[kind] ?? []
            if !added.isEmpty || !removed.isEmpty {
                result.append(.favorites(kind, added: added, removed: removed, removedRecordNames: []))
            }
        }
        if !subscriptionsUpserted.isEmpty || !subscriptionsRemoved.isEmpty {
            result.append(.subscriptions(upserted: subscriptionsUpserted, removedKeys: subscriptionsRemoved, removedRecordNames: []))
        }
        return result
    }

    /// True (and remembered) when a change is newer than the newest one this device knows of.
    private func acceptIfNewer(_ name: String, changedAt: Date) -> Bool {
        lock.withLock {
            if let known = data.changeTimes[name], known >= changedAt { return false }
            data.changeTimes[name] = changedAt
            return true
        }
    }

    private func deliver(_ outgoing: [CloudKitChange]) {
        guard !outgoing.isEmpty else { return }
        DispatchQueue.main.async { [changes] in
            outgoing.forEach { changes.send($0) }
        }
    }

    // MARK: - Send results

    private func handleSent(_ event: CKSyncEngine.Event.SentRecordZoneChanges, syncEngine: CKSyncEngine) {
        for record in event.savedRecords {
            rememberSystemFields(of: record)
            lock.withLock {
                _ = data.pending.removeValue(forKey: record.recordID.recordName)
                sentCounts[record.recordType, default: 0] += 1
            }
        }
        lock.withLock {
            if !event.savedRecords.isEmpty || !event.deletedRecordIDs.isEmpty {
                lastSuccessfulSend = Date()
            }
            if !event.deletedRecordIDs.isEmpty {
                sentCounts["deleted", default: 0] += event.deletedRecordIDs.count
            }
            for (recordID, error) in event.failedRecordDeletes where error.code != .unknownItem {
                lastErrorDate = Date(); lastError = "Delete \(recordID.recordName): \(Self.describe(error))"
            }
        }

        var retrySaves: [CKSyncEngine.PendingRecordZoneChange] = []
        var needsZone = false
        for failure in event.failedRecordSaves {
            let name = failure.record.recordID.recordName
            switch failure.error.code {
            case .serverRecordChanged:
                // Another device saved this record first. A read is the same either way. For a
                // favorite or subscription the newer change wins: resend ours on top of the
                // server copy, or drop ours and take the server's state.
                let serverRecord = failure.error.serverRecord
                if let serverRecord { rememberSystemFields(of: serverRecord) }
                let ours = lock.withLock { data.pending[name]?.changedAt }
                if let ours, let serverRecord, ours > Self.changedAt(of: serverRecord) {
                    retrySaves.append(.saveRecord(failure.record.recordID))
                } else {
                    lock.withLock { _ = data.pending.removeValue(forKey: name) }
                    if let serverRecord, serverRecord.recordType != RecordType.read {
                        deliver(changes(from: [serverRecord]))
                    }
                }
            case .zoneNotFound:
                needsZone = true
                retrySaves.append(.saveRecord(failure.record.recordID))
            case .batchRequestFailed:
                // Another record in the same batch failed; this one is fine, so send it again.
                retrySaves.append(.saveRecord(failure.record.recordID))
            case .unknownItem:
                // The server copy was deleted; save it as a new record.
                lock.withLock { _ = data.systemFields.removeValue(forKey: name) }
                retrySaves.append(.saveRecord(failure.record.recordID))
            case .networkFailure, .networkUnavailable, .serviceUnavailable, .requestRateLimited, .zoneBusy, .notAuthenticated, .operationCancelled:
                // CKSyncEngine retries these on its own.
                lock.withLock { lastErrorDate = Date(); lastError = "\(failure.record.recordType) (will retry): \(Self.describe(failure.error))" }
            default:
                syncLog("☁️ CloudKit: could not save \(name) - \(failure.error.localizedDescription)")
                lock.withLock {
                    _ = data.pending.removeValue(forKey: name)
                    lastErrorDate = Date(); lastError = "\(failure.record.recordType): \(Self.describe(failure.error))"
                }
            }
        }

        if needsZone {
            syncEngine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])
        }
        if !retrySaves.isEmpty {
            syncEngine.state.add(pendingRecordZoneChanges: retrySaves)
        }
        scheduleLocalSave()
    }

    // MARK: - Account changes

    private func handleAccountChange(_ event: CKSyncEngine.Event.AccountChange) {
        switch event.changeType {
        case .signIn:
            performInitialUploadIfNeeded()
        case .signOut, .switchAccounts:
            // Local data stays on the device; the next account gets its own first upload.
            lock.withLock {
                data = LocalData()
                engine = nil
                isActive = false
            }
            saveLocalData()
            start()
        @unknown default:
            break
        }
    }
}

// MARK: - CKSyncEngineDelegate

extension CloudKitSyncManager: CKSyncEngineDelegate {
    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        switch event {
        case .stateUpdate(let update):
            lock.withLock { data.engineState = update.stateSerialization }
            scheduleLocalSave()
        case .accountChange(let change):
            handleAccountChange(change)
        case .fetchedRecordZoneChanges(let changes):
            applyFetched(changes)
        case .sentRecordZoneChanges(let sent):
            handleSent(sent, syncEngine: syncEngine)
        case .didFetchChanges:
            lock.withLock { lastFetch = Date() }
        case .didSendChanges:
            lock.withLock { lastSend = Date() }
        case .fetchedDatabaseChanges(let changes):
            // Our zone was deleted (e.g. the user cleared iCloud data): upload everything again.
            if changes.deletions.contains(where: { $0.zoneID == zoneID }) {
                lock.withLock {
                    data.systemFields = [:]
                    data.didInitialUpload = false
                }
                syncEngine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])
                performInitialUploadIfNeeded()
            }
        default:
            break
        }
    }

    /// Removals, then favorite and feed changes, then read history, so a large first upload of
    /// read history never delays what the user just did.
    private static func sendPriority(_ change: CKSyncEngine.PendingRecordZoneChange) -> Int {
        switch change {
        case .deleteRecord:
            return 0
        case .saveRecord(let recordID):
            return recordID.recordName.hasPrefix("read-") ? 2 : 1
        @unknown default:
            return 3
        }
    }

    func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext,
        syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let changes = syncEngine.state.pendingRecordZoneChanges
            .filter { context.options.scope.contains($0) }
            .sorted { Self.sendPriority($0) < Self.sendPriority($1) }
        guard !changes.isEmpty else { return nil }
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: changes) { [weak self] recordID in
            guard let self else { return nil }
            let name = recordID.recordName
            guard let payload = self.lock.withLock({ self.data.pending[name] }) else {
                // Nothing to send for it any more.
                syncEngine.state.remove(pendingRecordZoneChanges: [.saveRecord(recordID)])
                return nil
            }
            return self.record(for: name, payload: payload)
        }
    }
}
