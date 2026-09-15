import json
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
CONTENT_VIEW = ROOT / "RSSReaderApp/Views/ContentView.swift"


def renderer_source() -> str:
    source = CONTENT_VIEW.read_text()
    start = source.index("enum RedditCardPreview")
    end = source.index("\nprivate func expandedCardPreviewText", start)
    return source[start:end]


def run_renderer(samples, remove_raw_urls=False):
    swift_samples = ",\n".join(
        f"({json.dumps(text)}, {json.dumps(rendered) if rendered is not None else 'nil'})"
        for text, rendered in samples
    )
    program = f"""import Foundation
{renderer_source()}
let samples: [(String, String?)] = [
{swift_samples}
]
for (index, sample) in samples.enumerated() {{
    let renderedURL = sample.1.flatMap(URL.init(string:))
    let output = RedditCardPreview.text(
        from: sample.0,
        renderedMediaURL: renderedURL,
        maxCharacters: 520,
        removeRawURLs: {"true" if remove_raw_urls else "false"}
    )
    print("\\(index)|\\(output)")
}}
"""
    with tempfile.TemporaryDirectory(prefix="reddit-card-preview-") as directory:
        directory_path = Path(directory)
        source_path = directory_path / "PreviewHarness.swift"
        binary_path = directory_path / "PreviewHarness"
        source_path.write_text(program)
        swiftc = shutil.which("swiftc")
        if swiftc is None:
            raise unittest.SkipTest("swiftc is unavailable")
        subprocess.run(
            [
                swiftc,
                "-module-cache-path",
                str(directory_path / "ModuleCache"),
                "-o",
                str(binary_path),
                str(source_path),
            ],
            check=True,
            capture_output=True,
            text=True,
        )
        result = subprocess.run(
            [str(binary_path)],
            check=True,
            capture_output=True,
            text=True,
        )
    outputs = {}
    for line in result.stdout.splitlines():
        index, output = line.split("|", 1)
        outputs[int(index)] = output
    return [outputs[index] for index in range(len(samples))]


class RedditCardPreviewTests(unittest.TestCase):
    def test_card_boundary_sanitizer_covers_markdown_entities_and_media_artifacts(self):
        rendered_reddit_media = "https://i.redd.it/photo.png"
        rendered_generic_image = "https://cdn.example.test/photo.png"
        samples = [
            (r'**bold** and _italic_ &quot;quoted&quot; \"escaped\"', rendered_reddit_media),
            ("![alt](https://i.redd.it/photo.png)", rendered_reddit_media),
            ("https://preview.redd.it/photo.png", rendered_reddit_media),
            ("https://v.redd.it/clip", rendered_reddit_media),
            ("https://cdn.example.test/photo.png", rendered_generic_image),
            ("Keep this https://i.redd.it/photo.png", rendered_reddit_media),
            ("Keep https://example.com/page and text", rendered_reddit_media),
            ("![chart](https://example.com/chart.png)", rendered_reddit_media),
            ("![chart](https://example.com/chart.png)", None),
            ("https://i.redd.it/photo.png", None),
        ]
        self.assertEqual(
            run_renderer(samples),
            [
                'bold and italic "quoted" "escaped"',
                "",
                "",
                "",
                "",
                "Keep this",
                "Keep https://example.com/page and text",
                "chart (https://example.com/chart.png)",
                "chart (https://example.com/chart.png)",
                "https://i.redd.it/photo.png",
            ],
        )

    def test_screenshot_style_prose_keeps_readable_link_labels_without_raw_markers(self):
        rendered = "https://i.redd.it/photo.png"
        sample = (
            "*Note: hello* # Links * **App Store:** "
            "[https://apps.apple.com/x](https://apps.apple.com/x) * "
            "**Instant Web Demo:** [https://app.bitflinger.tv]"
            "(https://app.bitflinger.tv) * **Website:** "
            "[https://example.com](https://example.com)"
        )
        self.assertEqual(
            run_renderer([(sample, rendered)]),
            [
                "Note: hello Links App Store: https://apps.apple.com/x "
                "Instant Web Demo: https://app.bitflinger.tv Website: https://example.com"
            ],
        )

    def test_podcast_and_youtube_mode_removes_promotional_urls_but_keeps_labels(self):
        sample = (
            "Click this link https://boot.dev/?promo=LTT and use my code. "
            "Discuss on the forum: https://linustechtips.com/topic/example/ "
            "Visit [Channel Partners](https://example.com/partners) or "
            "[https://example.com/raw](https://example.com/raw). Try www.example.com too."
        )
        self.assertEqual(
            run_renderer([(sample, None)], remove_raw_urls=True),
            ["Click this link and use my code. Discuss on the forum: Visit Channel Partners. Try too."],
        )

    def test_card_sanitizer_covers_reddit_and_only_podcast_youtube_article_rows(self):
        source = CONTENT_VIEW.read_text()
        row = source.split("struct RedditPostRow", 1)[1].split("// MARK: - Article Detail View", 1)[0]
        self.assertIn("RedditCardPreview.text", row)
        self.assertIn("Text(cardTitleText)", row)
        self.assertNotIn("Text(post.title)", row)
        preview_name = "previewText" if "private var previewText" in row else "cardPreviewText"
        self.assertIn(f"Text({preview_name})", row)
        self.assertIn("FeedRowThumbnailView", row)
        self.assertIn("private func expandedCardPreviewText", source)
        article_section = source.split("private func expandedCardPreviewText", 1)[1].split(
            "struct RedditPostRow", 1
        )[0]
        self.assertIn("article.isPodcastEpisode || article.isYouTubeVideo", article_section)
        self.assertIn("guard usesSanitizedSourceCardText else { return article.title }", article_section)
        self.assertIn("renderedMediaURL: article.imageURL", article_section)
        self.assertGreaterEqual(article_section.count("removeRawURLs: true"), 2)
        self.assertIn("Text(articleCardTitleText)", article_section)
        self.assertIn("expandedCardPreviewText(from: article.content", article_section)


if __name__ == "__main__":
    unittest.main()
