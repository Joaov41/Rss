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


class MarkAllReadBatchingRegressionTests(unittest.TestCase):
    def test_global_mark_all_uses_one_batch_per_content_type(self):
        app_state = read("RSSReaderApp/Controllers/AppState.swift")
        body = method_body(
            app_state,
            "func markAllUnreadAsRead()",
            "func markAllArticlesAsRead(for feedURL: String)",
        )

        self.assertEqual(body.count("markArticlesAsRead(articlesToPersist)"), 1)
        self.assertEqual(body.count("markRedditPostsAsRead(postsToPersist)"), 1)
        self.assertNotIn("markArticleAsRead(", body)
        self.assertNotIn("markRedditPostAsRead(", body)

    def test_subscription_mark_all_paths_use_batch_persistence(self):
        app_state = read("RSSReaderApp/Controllers/AppState.swift")
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

        self.assertEqual(article_body.count("markArticlesAsRead(articlesToPersist)"), 1)
        self.assertNotIn("markArticleAsRead(", article_body)
        self.assertEqual(reddit_body.count("markRedditPostsAsRead(postsToPersist)"), 1)
        self.assertNotIn("markRedditPostAsRead(", reddit_body)

    def test_bulk_persistence_unions_tokens_before_single_write_path(self):
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
