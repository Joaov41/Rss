import pathlib
import unittest


CONTENT_VIEW = (
    pathlib.Path(__file__).resolve().parents[1] / "Views" / "ContentView.swift"
).read_text()


class ArticleReaderLoadingFallbackTests(unittest.TestCase):
    def test_reader_starts_in_loading_state_and_has_cached_fallback(self):
        self.assertIn("@State private var isArticleReaderLoading = true", CONTENT_VIEW)
        self.assertIn("@Binding var isLoadingReader: Bool", CONTENT_VIEW)
        self.assertIn("readerLoadingFallback(viewportHeight: viewportHeight)", CONTENT_VIEW)
        self.assertIn(".opacity(isLoadingReader ? 1 : 0)", CONTENT_VIEW)

    def test_metadata_capsule_only_appears_after_reader_finishes(self):
        self.assertIn("articleViewMode == .reader", CONTENT_VIEW)
        self.assertIn("!isArticleReaderLoading", CONTENT_VIEW)
        self.assertIn("isLoadingReader: $isArticleReaderLoading", CONTENT_VIEW)

    def test_remote_reader_stays_mounted_behind_fallback(self):
        reader_start = CONTENT_VIEW.index("ZStack(alignment: .top)")
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
