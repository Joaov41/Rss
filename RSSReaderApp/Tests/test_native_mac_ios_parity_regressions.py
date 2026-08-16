import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]


def read(path: str) -> str:
    return (ROOT / path).read_text()


def method_body(source: str, signature: str, next_signature: str) -> str:
    match = re.search(
        rf"{re.escape(signature)}[\s\S]*?(?=\n\s+{re.escape(next_signature)})",
        source,
    )
    if match is None:
        raise AssertionError(f"Could not find method: {signature}")
    return match.group(0)


class NativeMacIOSParityRegressionTests(unittest.TestCase):
    def test_feed_cards_have_wide_and_compact_window_layouts(self):
        content = read("RSSReaderApp/Views/ContentView.swift")
        self.assertIn("expandedArticleContent", content)
        self.assertIn("compactArticleContent", content)
        self.assertIn("expandedRedditContent", content)
        self.assertIn("compactRedditContent", content)
        self.assertGreaterEqual(content.count("ViewThatFits(in: .horizontal)"), 2)

    def test_compact_feed_previews_fill_the_column_beside_images(self):
        content = read("RSSReaderApp/Views/ContentView.swift")
        article_compact = content.split(
            "private var compactArticleContent: some View {", 1
        )[1].split("private func formatDate", 1)[0]
        reddit_compact = content.split(
            "private var compactRedditContent: some View {", 1
        )[1].split("// MARK: - Article Detail View", 1)[0]

        self.assertRegex(
            article_compact,
            r"HStack\(alignment: \.top, spacing: 12\) \{[\s\S]*?"
            r"VStack\(alignment: \.leading, spacing: 8\) \{[\s\S]*?"
            r"articleTitle[\s\S]*?articlePreview[\s\S]*?"
            r"FeedRowThumbnailView",
        )
        self.assertEqual(article_compact.count("articlePreview"), 1)
        self.assertRegex(
            reddit_compact,
            r"HStack\(alignment: \.top, spacing: 12\) \{[\s\S]*?"
            r"VStack\(alignment: \.leading, spacing: 8\) \{[\s\S]*?"
            r"redditTitle[\s\S]*?redditPreview[\s\S]*?"
            r"FeedRowThumbnailView",
        )
        self.assertEqual(reddit_compact.count("redditPreview"), 1)

    def test_article_summary_references_open_the_article(self):
        content = read("RSSReaderApp/Views/ContentView.swift")
        self.assertIn("private func openSummaryReference(referenceNumber: Int)", content)
        self.assertRegex(
            content,
            r"summaryReferences\(count: parsedSummaries\.count\)[\s\S]*?"
            r"if isRedditContent[\s\S]*?scrollToSummary[\s\S]*?else[\s\S]*?"
            r"openSummaryReference",
        )
        self.assertIn('accessibilityLabel("Open article \\(index + 1)")', content)

    def test_open_overall_summary_is_a_stable_refresh_snapshot(self):
        content = read("RSSReaderApp/Views/ContentView.swift")
        draggable = content.split("struct DraggableGlobalSummaryView: View", 1)[1].split(
            "struct GlobalSummaryResultView: View", 1
        )[0]

        self.assertIn("snapshotAggregateSummaryText", draggable)
        self.assertIn("hasCapturedSummarySnapshot", draggable)
        self.assertIn("captureSummarySnapshotIfAvailable(from: newValue)", draggable)
        self.assertIn("guard !hasCapturedSummarySnapshot else { return }", draggable)
        self.assertIn("acceptRequestedAggregateSummaryIfAvailable(newValue)", draggable)
        self.assertNotIn("rebuildParsedSummaryCache(from: newValue)", draggable)

    def test_reference_parser_accepts_bracketed_citations(self):
        components = read("RSSReaderApp/Views/AskAIComponents.swift")
        self.assertIn("let referenceToken", components)
        self.assertIn("let bracketRegex", components)
        self.assertIn("applyReferenceLink(numberRange: numberRange)", components)

    def test_reddit_summary_actions_request_scroll_to_results(self):
        detail = read("RSSReaderApp/Views/RedditDetailView.swift")
        self.assertIn('redditPostSummaryAnchor = "redditPostSummaryAnchor"', detail)
        self.assertIn('redditCommentSummaryAnchor = "redditCommentSummaryAnchor"', detail)
        self.assertIn("commentSummaryScrollRequest &+= 1", detail)
        self.assertIn("onChange(of: appState.selectedRedditPost?.summary)", detail)
        self.assertIn("onChange(of: commentSummary?.summary)", detail)

    def test_mark_all_paths_use_batch_persistence(self):
        app_state = read("RSSReaderApp/Controllers/AppState.swift")
        global_body = method_body(
            app_state,
            "func markAllUnreadAsRead()",
            "func markAllArticlesAsRead(for feedURL: String)",
        )
        article_body = method_body(
            app_state,
            "func markAllArticlesAsRead(for feedURL: String)",
            "func markAllRedditPostsAsRead(for subreddit: String)",
        )
        reddit_body = method_body(
            app_state,
            "func markAllRedditPostsAsRead(for subreddit: String)",
            "func navigateToNextSubscription(after currentURL: String)",
        )

        self.assertEqual(global_body.count("markArticlesAsRead(articlesToPersist)"), 1)
        self.assertEqual(global_body.count("markRedditPostsAsRead(postsToPersist)"), 1)
        self.assertNotIn("markArticleAsRead(", global_body)
        self.assertNotIn("markRedditPostAsRead(", global_body)
        self.assertEqual(article_body.count("markArticlesAsRead(articlesToPersist)"), 1)
        self.assertEqual(reddit_body.count("markRedditPostsAsRead(postsToPersist)"), 1)

    def test_bulk_persistence_unions_tokens_before_one_write_path(self):
        persistence = read("RSSReaderApp/Services/PersistenceManager.swift")
        article_body = method_body(
            persistence,
            "func markArticlesAsRead(_ articles: [Article])",
            "func markArticleAsRead(_ articleId: String)",
        )
        reddit_body = method_body(
            persistence,
            "func markRedditPostsAsRead(_ posts: [RedditPost])",
            "func markRedditPostAsRead(_ postId: String)",
        )

        self.assertIn("tokens.formUnion(articleReadTokens(for: article))", article_body)
        self.assertEqual(article_body.count("markArticleAsRead(tokens:"), 1)
        self.assertIn("tokens.formUnion(redditReadTokens(for: post))", reddit_body)
        self.assertEqual(reddit_body.count("markRedditPostAsRead(tokens:"), 1)


if __name__ == "__main__":
    unittest.main()
