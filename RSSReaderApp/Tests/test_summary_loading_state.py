import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]


def read(path: str) -> str:
    return (ROOT / path).read_text()


class SummaryLoadingStateRegressionTests(unittest.TestCase):
    def test_reddit_spinner_is_scoped_to_the_selected_post(self):
        reddit_view = read("RSSReaderApp/Views/RedditDetailView.swift")
        self.assertIn(
            "appState.isSummarizingRedditPost(post) && visiblePostSummary == nil",
            reddit_view,
        )
        self.assertNotIn(
            "appState.isLoading && visiblePostSummary == nil",
            reddit_view,
        )

    def test_article_and_reddit_have_independent_active_summary_ids(self):
        app_state = read("RSSReaderApp/Controllers/AppState.swift")
        self.assertIn("activeArticleSummaryIDs", app_state)
        self.assertIn("activeRedditSummaryIDs", app_state)
        self.assertIn("func isSummarizingRedditPost", app_state)
        self.assertRegex(
            app_state,
            r"func requestSummary[\s\S]*?beginSummary\(article: article, redditPost: redditPost\)",
        )

    def test_summary_updates_always_clear_the_matching_item(self):
        app_state = read("RSSReaderApp/Controllers/AppState.swift")
        self.assertRegex(
            app_state,
            r"func updateArticleSummaryFromCloud[\s\S]*?defer \{ finishArticleSummary\(article\) \}",
        )
        self.assertRegex(
            app_state,
            r"func updateRedditPostSummaryFromCloud[\s\S]*?defer \{ finishRedditSummary\(post\) \}",
        )

    def test_apple_cloud_completion_keeps_the_original_target(self):
        app_state = read("RSSReaderApp/Controllers/AppState.swift")
        cloud_method = re.search(
            r"private func launchCloudSummaryForContent[\s\S]*?\n    func launchCloudSummary",
            app_state,
        )
        self.assertIsNotNone(cloud_method)
        body = cloud_method.group(0)
        self.assertIn("launchCloudRequest(for: content, type: .summary) {", body)
        self.assertIn("updateArticleSummaryFromCloud(article, summary: result)", body)
        self.assertIn("updateRedditPostSummaryFromCloud(redditPost, summary: result)", body)

    def test_feed_refresh_preserves_in_memory_summaries(self):
        app_state = read("RSSReaderApp/Controllers/AppState.swift")
        self.assertGreaterEqual(app_state.count("let existingSummaries ="), 2)
        self.assertIn(
            "processedFeed.articles[i].summary = existingSummaries[article.id]",
            app_state,
        )
        self.assertIn(
            "processedFeed.posts[index].summary = existingSummaries[post.id]",
            app_state,
        )


if __name__ == "__main__":
    unittest.main()
