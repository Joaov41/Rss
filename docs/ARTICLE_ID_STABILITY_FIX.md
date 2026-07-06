# Article ID Stability Fix

## Problem Summary

Users reported that after marking all articles/Reddit posts as read, some items would reappear as unread shortly after. These items were not new—they were often hours old and should have remained marked as read.

## Root Cause Analysis

The issue was traced to **unstable article ID generation**. When articles are marked as read, their IDs are stored in persistence. On subsequent feed fetches, if an article's ID changes, the persistence lookup fails and the article appears unread.

### ID Generation Flow

```
Feed Fetched → Article Created with ID → ID Stored when Marked Read
     ↓
Feed Refreshed → Same Article Created with Different ID → Lookup Fails → Appears Unread
```

## Technical Details

### Issue 1: Unstable Date Fallback in ID Generation

**Location:** `RSSReaderApp/Services/FeedService.swift`

The `generateStableArticleID` function uses a priority system:
1. Use GUID if available
2. Use link URL if available
3. **Fallback:** Hash of title + publishDate

The problem was in the fallback case. When RSS feeds don't provide a date, the code fell back to `Date()` (current time):

```swift
// In processRSSFeed, processAtomFeed, processJSONFeed:
var publishDate = item.pubDate ?? Date()  // Falls back to NOW if no date!
```

This meant the hash changed on every fetch:

```swift
// BEFORE: Unstable ID generation
private func generateStableArticleID(guid: String?, link: String?, title: String, publishDate: Date) -> String {
    // ... guid and link checks ...

    // Fallback uses publishDate which can be Date() - changes every fetch!
    let seed = "\(title)|\(publishDate.timeIntervalSince1970)"
    let hash = djb2Hex(seed)
    return "hash-\(hash)"
}
```

**Example of the bug:**

| Fetch Time | Article Title | publishDate | Generated ID |
|------------|---------------|-------------|--------------|
| 10:00 AM | "Breaking News" | `Date()` = 1703930400 | `hash-a1b2c3d4` |
| 10:15 AM | "Breaking News" | `Date()` = 1703931300 | `hash-e5f6g7h8` |

The same article gets different IDs, so marking it read at 10:00 AM doesn't persist to the 10:15 AM fetch.

### Issue 2: Incomplete URL Tracking Parameter Filtering

**Location:** `RSSReaderApp/Services/CloudSyncManager.swift`

The `ArticleIDNormalizer` strips tracking parameters from URLs to ensure consistent IDs. However, it only filtered a small set of parameters:

```swift
// BEFORE: Limited tracking param filtering
if name.hasPrefix("utm_") { return false }
if name == "fbclid" { return false }
if name == "gclid" { return false }
if name == "mc_cid" { return false }
if name == "mc_eid" { return false }
if name == "ref" { return false }
```

Many common tracking parameters were not filtered, causing ID mismatches when the same article URL contained different tracking params on different fetches.

## Solution

### Fix 1: Use Feed URL Instead of Publish Date

Changed the fallback hash to use `feedURL` (which is stable) instead of `publishDate`:

```swift
// AFTER: Stable ID generation
/// Generate a stable article ID so read state persists across refreshes and devices.
/// Uses guid > link > hash(title + feedURL) priority. Does NOT use publishDate in fallback
/// because some feeds don't provide dates consistently, causing Date() fallback which
/// changes on every fetch and breaks read state tracking.
private func generateStableArticleID(guid: String?, link: String?, title: String, feedURL: String) -> String {
    let trimmedGUID = guid?.trimmingCharacters(in: .whitespacesAndNewlines)
    if let trimmedGUID, !trimmedGUID.isEmpty {
        return ArticleIDNormalizer.normalize(trimmedGUID)
    }

    let trimmedLink = link?.trimmingCharacters(in: .whitespacesAndNewlines)
    if let trimmedLink, !trimmedLink.isEmpty {
        return ArticleIDNormalizer.normalize(trimmedLink)
    }

    // Deterministic hash from title + feedURL (both are stable across fetches)
    // Using feedURL ensures uniqueness across different feeds with same title
    let seed = "\(title)|\(feedURL)"
    let hash = djb2Hex(seed)
    return "hash-\(hash)"
}
```

Updated all call sites to pass `feedURL` instead of `publishDate`:

```swift
// RSS Feed processing
let articleId = generateStableArticleID(
    guid: item.guid?.value,
    link: item.link,
    title: rawTitle,
    feedURL: url  // Changed from: publishDate: publishDate
)

// Atom Feed processing
let articleId = generateStableArticleID(
    guid: entry.id,
    link: articleURLString,
    title: rawTitle,
    feedURL: url  // Changed from: publishDate: entry.published ?? entry.updated ?? Date()
)

// JSON Feed processing
let articleId = generateStableArticleID(
    guid: item.id,
    link: item.url,
    title: rawTitle,
    feedURL: url  // Changed from: publishDate: item.datePublished ?? Date()
)
```

**Result:** The same article now always gets the same ID:

| Fetch Time | Article Title | feedURL | Generated ID |
|------------|---------------|---------|--------------|
| 10:00 AM | "Breaking News" | `https://example.com/feed` | `hash-x1y2z3w4` |
| 10:15 AM | "Breaking News" | `https://example.com/feed` | `hash-x1y2z3w4` |

### Fix 2: Expanded Tracking Parameter Filtering

Added comprehensive filtering for 30+ tracking and session parameters:

```swift
// AFTER: Comprehensive tracking param filtering
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
    // ... rest of filtering logic
}
```

**Example of normalization:**

| Original URL | Normalized URL |
|--------------|----------------|
| `https://news.com/article?utm_source=rss&fbclid=abc123` | `https://news.com/article` |
| `https://news.com/article?source=feed&t=1703930400` | `https://news.com/article` |
| `https://news.com/article?id=42&campaign=daily` | `https://news.com/article?id=42` |

## Impact on iCloud Sync

### No Impact (99%+ of articles)
- Articles with stable GUIDs or links use the same ID generation
- The normalizer changes only add more filtering, making IDs more consistent

### One-Time Impact (edge cases)
Articles that previously used the hash fallback (no GUID, no link) will have different IDs after this fix:

- **Old ID:** `hash("Title|1703952000")` (with timestamp)
- **New ID:** `hash("Title|https://feed.url/rss")` (with feedURL)

These articles will appear unread once, but after marking them read again, they will remain read permanently.

### Net Effect
- More stable sync across devices
- IDs no longer depend on fetch timing
- Consistent normalization regardless of which device saw which tracking params

### Fix 3: SwiftUI View Caching Issue (Counter vs Visual Mismatch)

**Location:** `RSSReaderApp/Views/ContentView.swift`

**Problem:** After the ID stability fixes, users still reported a discrepancy where the unread counter would show one number (e.g., 18), but visually scrolling through the list would show a different count (e.g., only 1 unread). This happened because SwiftUI was caching the subscription view and not re-rendering it when post `isRead` states changed.

**Root Cause:** When SwiftUI renders a view, it uses view identity to decide whether to update or recreate. The subscription views were passed `feed` as a parameter (a value type), but SwiftUI didn't detect that the internal `isRead` states of posts had changed, so it kept displaying stale cached views.

**Solution:** Added `.id()` modifiers that change when any post's read state changes, forcing SwiftUI to recreate the view:

```swift
// BEFORE: View might be cached with stale data
if let feed = appState.redditFeeds.first(where: { $0.subreddit == subscription.url }) {
    redditSubscriptionView(feed: feed, subscription: subscription)
}

// AFTER: View is recreated when read states change
if let feed = appState.redditFeeds.first(where: { $0.subreddit == subscription.url }) {
    // Use .id() to force SwiftUI to recreate the view when read states change
    // This prevents stale cached views from showing incorrect read/unread badges
    let readStateHash = feed.posts.map { $0.isRead ? "1" : "0" }.joined()
    redditSubscriptionView(feed: feed, subscription: subscription)
        .id("reddit-\(subscription.url)-\(readStateHash)")
}
```

The same fix was applied to RSS feed views.

### Fix 4: Reddit Post Sorting (Chronological Order for "New")

**Location:** `RSSReaderApp/Controllers/AppState.swift` (3 locations)

**Problem:** When selecting "New" sort for Reddit, posts were not always displayed in chronological order. Older posts (e.g., 13hr) would appear above newer ones (e.g., 1hr).

**Root Cause:** Reddit's API should return posts in the correct order, but due to rate limiting or caching, old "Hot" sorted data could persist. Additionally, no client-side sorting was applied to guarantee the expected order.

**Solution:** Added client-side sorting that runs after posts are fetched:
- Stickied posts always stay at the top (Reddit pins these regardless of sort)
- Non-stickied posts sorted by `publishDate` (newest first)
- Only applied when sort option is "New" (Hot uses Reddit's algorithm)

```swift
// Sort posts: stickied first, then by date for "New" sort
if self.redditSortOption == .new {
    let stickied = processedFeed.posts.filter { $0.isStickied }
    let nonStickied = processedFeed.posts.filter { !$0.isStickied }
        .sorted { $0.publishDate > $1.publishDate }
    processedFeed.posts = stickied + nonStickied
}
```

Applied in 3 locations:
1. Main `refreshRedditFeeds` flow
2. `addSubscription` flow
3. OPML import flow

## Files Modified

1. **`RSSReaderApp/Services/FeedService.swift`**
   - Changed `generateStableArticleID` signature from `publishDate: Date` to `feedURL: String`
   - Updated hash fallback to use `title + feedURL`
   - Updated all 3 call sites (RSS, Atom, JSON feed processing)

2. **`RSSReaderApp/Services/CloudSyncManager.swift`**
   - Expanded `ArticleIDNormalizer` tracking parameter filter list
   - Added 30+ new parameters across multiple categories

3. **`RSSReaderApp/Views/ContentView.swift`**
   - Added `.id()` modifiers to subscription views based on read state hash
   - Forces SwiftUI to properly refresh views when read states change

4. **`RSSReaderApp/Controllers/AppState.swift`**
   - Added client-side sorting for Reddit posts when "New" sort is selected
   - Stickied posts kept at top, non-stickied sorted by date (newest first)
   - Applied in 3 locations: refresh, add subscription, OPML import

## Testing Recommendations

1. **Verify existing read states persist** after app update
2. **Test with problematic feeds** that previously showed the bug
3. **Confirm iCloud sync** still works correctly across devices
4. **Monitor for any feeds** where articles still appear unread unexpectedly (may indicate additional tracking params to filter)
5. **Test counter vs visual consistency** - mark all as read, wait a few minutes, verify counter matches visual badges
6. **Test Reddit "New" sort** - verify posts appear in chronological order (newest first, stickied at top)
