import pathlib
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
REDDIT_DETAIL = (ROOT / "RSSReaderApp/Views/RedditDetailView.swift").read_text()
CONTENT_VIEW = (ROOT / "RSSReaderApp/Views/ContentView.swift").read_text()


class RedditReplyRegressionTests(unittest.TestCase):
    def test_top_level_comment_composer_has_one_stable_presentation_host(self):
        self.assertIn("@State private var postCommentTarget: RedditPost?", REDDIT_DETAIL)
        self.assertIn(".sheet(item: $postCommentTarget) { post in", REDDIT_DETAIL)
        self.assertEqual(REDDIT_DETAIL.count(".sheet(item: $postCommentTarget)"), 1)
        self.assertNotIn("showPostCommentSheet", REDDIT_DETAIL)

    def test_both_adaptive_headers_route_to_the_same_comment_target(self):
        self.assertIn("postCommentTarget = appState.selectedRedditPost", REDDIT_DETAIL)
        self.assertIn("postCommentTarget = post", REDDIT_DETAIL)
        self.assertGreaterEqual(REDDIT_DETAIL.count("postCommentTarget ="), 2)

    def test_per_comment_reply_composer_remains_independent(self):
        comment_views = (ROOT / "RSSReaderApp/Views/CommentViews.swift").read_text()
        self.assertIn("@State private var showReplySheet = false", comment_views)
        self.assertIn(".sheet(isPresented: $showReplySheet)", comment_views)
        self.assertIn("RedditCommentReplySheet(comment: comment)", comment_views)

    def test_compact_reddit_detail_does_not_cover_the_scroll_view_edge(self):
        compact_reddit_detail = CONTENT_VIEW.split(
            "if let post = appState.selectedRedditPost {", 1
        )[1].split("} else if appState.selectedArticle != nil {", 1)[0]
        self.assertIn(
            ".phoneStyleBackGestures(enabled: shouldUsePhoneLayout, usesSystemEdgeSwipe: false)",
            compact_reddit_detail,
        )
        self.assertNotIn(".systemEdgeBackSwipe(", compact_reddit_detail)


if __name__ == "__main__":
    unittest.main()
