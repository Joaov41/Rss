import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]


class CompactFeedPreviewLayoutTests(unittest.TestCase):
    def test_article_and_reddit_compact_previews_share_the_text_column_with_images(self):
        content = (ROOT / "RSSReaderApp/Views/ContentView.swift").read_text()

        article_compact = content.split(
            "private var compactIOSArticleContent: some View {", 1
        )[1].split("private func formatDate", 1)[0]
        reddit_compact = content.split(
            "private var phoneCardContent: some View {", 1
        )[1].split("// MARK: - Article Detail View", 1)[0]

        self.assertRegex(
            article_compact,
            r"HStack\(alignment: \.top, spacing: 12\) \{[\s\S]*?"
            r"VStack\(alignment: \.leading, spacing: 8\) \{[\s\S]*?"
            r"Text\(article\.title\)[\s\S]*?Text\(ipadArticlePreviewText\)[\s\S]*?"
            r"FeedRowThumbnailView",
        )
        self.assertRegex(
            reddit_compact,
            r"HStack\(alignment: \.top, spacing: 12\) \{[\s\S]*?"
            r"VStack\(alignment: \.leading, spacing: 8\) \{[\s\S]*?"
            r"Text\(post\.title\)[\s\S]*?Text\(cardPreviewText\)[\s\S]*?"
            r"FeedRowThumbnailView",
        )
        self.assertEqual(reddit_compact.count("Text(cardPreviewText)"), 1)
        self.assertIn("width: 160", article_compact)
        self.assertIn("height: 220", article_compact)
        self.assertIn("minHeight: 220", article_compact)
        self.assertIn("maxHeight: 220", article_compact)
        self.assertIn(".lineLimit(11)", article_compact)
        self.assertIn("usesBlurredBackdrop: true", article_compact)
        self.assertIn("width: 160", reddit_compact)
        self.assertIn("height: 220", reddit_compact)
        self.assertIn("minHeight: 220", reddit_compact)
        self.assertIn("maxHeight: 220", reddit_compact)
        self.assertIn(".lineLimit(10)", reddit_compact)
        self.assertIn("usesBlurredBackdrop: true", reddit_compact)
        self.assertEqual(content.count("minHeight: 220"), 2)
        self.assertEqual(content.count("maxHeight: 220"), 2)
        self.assertNotIn("onGeometryChange", article_compact)
        self.assertNotIn("onGeometryChange", reddit_compact)


if __name__ == "__main__":
    unittest.main()
