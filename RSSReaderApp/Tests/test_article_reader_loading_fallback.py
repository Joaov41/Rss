import pathlib
import unittest


CONTENT_VIEW = (
    pathlib.Path(__file__).resolve().parents[1] / "Views" / "ContentView.swift"
).read_text()


class ArticleReaderLoadingFallbackTests(unittest.TestCase):
    def test_reader_starts_in_loading_state_and_has_cached_fallback(self):
        self.assertIn(
            "@State private var isArticleReaderLoading: Bool = true", CONTENT_VIEW
        )
        self.assertIn("@Binding var isLoadingReader: Bool", CONTENT_VIEW)
        self.assertIn("readerLoadingFallback", CONTENT_VIEW)
        self.assertIn(".opacity(isLoadingReader ? 1 : 0)", CONTENT_VIEW)

    def test_metadata_capsule_only_appears_after_reader_finishes(self):
        metadata_start = CONTENT_VIEW.index(
            "private func articleTopChromeOverlay(article: Article)"
        )
        metadata_end = CONTENT_VIEW.index(
            "private func articleHeader(article: Article)", metadata_start
        )
        metadata_overlay = CONTENT_VIEW[metadata_start:metadata_end]

        self.assertIn("articleViewMode == .reader", metadata_overlay)
        self.assertIn("!isArticleReaderLoading", metadata_overlay)
        self.assertIn("!isArticleMetadataChromeHidden", metadata_overlay)
        self.assertIn("isLoadingReader: $isArticleReaderLoading", CONTENT_VIEW)

    def test_remote_reader_stays_mounted_behind_fallback(self):
        panel_start = CONTENT_VIEW.index("private var articleContentPanel")
        reader_start = CONTENT_VIEW.index("ZStack(alignment: .top)", panel_start)
        reader_end = CONTENT_VIEW.index(
            ".animation(.easeOut(duration: 0.18), value: isLoadingReader)",
            reader_start,
        )
        reader_stack = CONTENT_VIEW[reader_start:reader_end]

        self.assertIn("readerLoadingFallback", reader_stack)
        self.assertIn("ArticleReaderWebView(", reader_stack)
        self.assertIn(".allowsHitTesting(!isLoadingReader)", reader_stack)

    def test_readability_work_is_cached(self):
        self.assertIn(
            "private static let readabilitySource = loadReadabilitySource()",
            CONTENT_VIEW,
        )
        self.assertIn(
            "private static let compactToggleScript = makeToggleScript(useCompactTitle: true)",
            CONTENT_VIEW,
        )
        self.assertIn(
            "private static let regularToggleScript = makeToggleScript(useCompactTitle: false)",
            CONTENT_VIEW,
        )


if __name__ == "__main__":
    unittest.main()
