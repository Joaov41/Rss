import pathlib
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
CONTENT_VIEW = (ROOT / "RSSReaderApp/Views/ContentView.swift").read_text()
APP_STATE = (ROOT / "RSSReaderApp/Controllers/AppState.swift").read_text()


class NativeScrollRestorationTests(unittest.TestCase):
    def test_feed_lists_use_native_scroll_position_apis(self):
        self.assertIn("ScrollPosition(idType: String.self)", CONTENT_VIEW)
        self.assertIn(".onScrollGeometryChange(", CONTENT_VIEW)
        self.assertIn(".onScrollPhaseChange", CONTENT_VIEW)
        self.assertIn(".onScrollTargetVisibilityChange", CONTENT_VIEW)

    def test_hot_feed_observer_retry_loop_is_removed(self):
        self.assertNotIn("FeedListScrollOffsetObserver", CONTENT_VIEW)
        self.assertNotIn("FeedListScrollOffsetHostView", CONTENT_VIEW)
        self.assertNotIn("SidebarScrollOffsetObserver", CONTENT_VIEW)
        self.assertNotIn("SidebarScrollObserverHostView", CONTENT_VIEW)

    def test_scroll_cache_does_not_publish_during_scroll(self):
        self.assertIn("private var scrollPositions", APP_STATE)
        self.assertNotIn("@Published var scrollPositions", APP_STATE)

    def test_restoration_is_bounded_and_has_stable_anchor_fallback(self):
        self.assertIn("for attempt in 0..<3", CONTENT_VIEW)
        self.assertIn("fallbackAnchorID", CONTENT_VIEW)
        self.assertIn("snapshot.contentFingerprint == fingerprint", CONTENT_VIEW)

    def test_sidebar_uses_stable_native_scroll_targets(self):
        self.assertIn('restorationKey: "sidebar_subscriptions"', CONTENT_VIEW)
        self.assertIn("trackedItemIDs: filteredSidebarSubscriptions.map(\\.url)", CONTENT_VIEW)
        self.assertIn("restorePhoneSidebarPosition(using: scrollProxy)", CONTENT_VIEW)
        self.assertIn("scrollProxy.scrollTo(targetURL, anchor: .center)", CONTENT_VIEW)
        self.assertIn("lastPhoneSidebarSubscriptionURL = newValue", CONTENT_VIEW)

    def test_compact_subscription_list_stays_alive_behind_detail(self):
        self.assertIn("Keep the compact subscription list alive behind its detail", CONTENT_VIEW)
        self.assertIn("subscriptionView(for: subscription)", CONTENT_VIEW)
        self.assertIn(
            ".allowsHitTesting(appState.selectedArticle == nil && appState.selectedRedditPost == nil)",
            CONTENT_VIEW,
        )

    def test_open_global_summary_remains_a_stable_refresh_snapshot(self):
        self.assertIn("Treat the open summary as a stable reading snapshot", CONTENT_VIEW)
        self.assertIn("hasCapturedSummarySnapshot", CONTENT_VIEW)
        self.assertIn("captureSummarySnapshotIfAvailable(from: newValue)", CONTENT_VIEW)
        self.assertIn("guard !hasCapturedSummarySnapshot else { return }", CONTENT_VIEW)
        self.assertIn("if !parsedSummaries.isEmpty || hasAggregateSummary || hasSummaryError", CONTENT_VIEW)
        self.assertIn("rebuildAggregateSummaryCache(from: appState.aggregateSummaryText)", CONTENT_VIEW)
        self.assertIn("acceptRequestedAggregateSummaryIfAvailable(newValue)", CONTENT_VIEW)
        self.assertIn("isAwaitingRequestedAggregateSummary", CONTENT_VIEW)
        self.assertIn("!parsedSummaries.isEmpty || cachedFormattedAggregateSummary != nil", CONTENT_VIEW)
        self.assertNotIn("applySummaryRefresh", CONTENT_VIEW)
        self.assertNotIn("pendingSummaryRefreshJSON", CONTENT_VIEW)
        self.assertNotIn("restoreSummaryScrollPositionAfterRefresh", CONTENT_VIEW)
        self.assertNotIn("summaryRefreshRestoreTask", CONTENT_VIEW)

    def test_feed_refresh_is_deferred_while_overall_summary_is_open(self):
        self.assertIn("guard !showGlobalSummary else", APP_STATE)
        self.assertIn("hasDeferredFeedRefreshForGlobalSummary = true", APP_STATE)
        self.assertIn("func resumeDeferredFeedRefreshAfterGlobalSummary()", APP_STATE)
        self.assertIn("appState.resumeDeferredFeedRefreshAfterGlobalSummary()", CONTENT_VIEW)


if __name__ == "__main__":
    unittest.main()
