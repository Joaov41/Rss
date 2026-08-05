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
        self.assertIn("trackedItemIDs: appState.subscriptions.map(\\.url)", CONTENT_VIEW)


if __name__ == "__main__":
    unittest.main()
