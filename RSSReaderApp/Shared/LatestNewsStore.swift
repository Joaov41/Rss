import Foundation

struct LatestNewsSnapshot: Codable {
    let generatedAt: Date
    let items: [LatestNewsItem]
}

struct LatestNewsItem: Codable, Identifiable, Sendable {
    let id: String
    let title: String
    let source: String
    let subtitle: String?
    let publishedAt: Date
    let deeplink: URL?
    let imageURL: URL?
    var imageData: Data?
}

final class LatestNewsStore {
    static let shared = LatestNewsStore()

    private let storageKey = "latest-news-snapshot"
    private let userDefaults: UserDefaults?

    private init() {
        userDefaults = UserDefaults(suiteName: "group.com.joaovalente.rssreader")
    }

    func save(_ snapshot: LatestNewsSnapshot) {
        guard
            let defaults = userDefaults
        else {
            print("⚠️ LatestNewsStore: App Group user defaults unavailable; snapshot not saved.")
            return
        }

        guard let data = try? JSONEncoder().encode(snapshot) else {
            print("⚠️ LatestNewsStore: Failed to encode snapshot with \(snapshot.items.count) items.")
            return
        }

        defaults.set(data, forKey: storageKey)
        print("✅ LatestNewsStore: Saved snapshot with \(snapshot.items.count) items at \(snapshot.generatedAt).")
    }

    func load() -> LatestNewsSnapshot? {
        guard
            let defaults = userDefaults,
            let data = defaults.data(forKey: storageKey)
        else {
            print("ℹ️ LatestNewsStore: No cached snapshot found.")
            return nil
        }

        do {
            let snapshot = try JSONDecoder().decode(LatestNewsSnapshot.self, from: data)
            print("✅ LatestNewsStore: Loaded snapshot with \(snapshot.items.count) items generated at \(snapshot.generatedAt).")
            return snapshot
        } catch {
            print("❌ LatestNewsStore: Failed to decode snapshot: \(error)")
            return nil
        }
    }
}
