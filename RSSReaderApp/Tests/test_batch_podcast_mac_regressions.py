import pathlib
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
PODCAST = ROOT / "Podcast"
PROJECT = ROOT.parent / "RSSReaderApp.xcodeproj" / "project.pbxproj"


class MacBatchPodcastStaticTests(unittest.TestCase):
    def test_mac_podcast_module_is_complete_and_in_target(self):
        expected = {
            "BatchPodcastModels.swift",
            "BatchPodcastContextBuilder.swift",
            "BatchPodcastService.swift",
            "BatchPodcastSession.swift",
            "MLXPodcastPlaybackController.swift",
            "BatchPodcastView.swift",
        }
        self.assertEqual({path.name for path in PODCAST.glob("*.swift")}, expected)
        project_text = PROJECT.read_text()
        for filename in expected:
            self.assertIn(filename, project_text)
            self.assertIn(f"{filename} in Sources", project_text)

    def test_generation_reads_only_retained_batch_evidence(self):
        source = "\n".join(path.read_text() for path in PODCAST.glob("*.swift"))
        for forbidden in ("import UIKit", "UIDocumentPicker", "RedditService", "FeedService", "fetchComments", "fetchSubreddit"):
            self.assertNotIn(forbidden, source)
        context = (PODCAST / "BatchPodcastContextBuilder.swift").read_text()
        self.assertIn("cachedComments", context)
        self.assertIn("evidenceChunks", context)
        self.assertIn("SHA256", context)

    def test_script_limits_are_targets_with_only_an_upper_cap(self):
        models = (PODCAST / "BatchPodcastModels.swift").read_text()
        service = (PODCAST / "BatchPodcastService.swift").read_text()
        self.assertIn("maximumWords = 1_060", models)
        self.assertNotIn("spokenWordCount <", service)
        self.assertNotIn("turns.count <", service)
        self.assertIn("Unknown evidence references are deliberately discarded", service)

    def test_mac_audio_export_uses_real_wav_and_system_save_panel(self):
        playback = (PODCAST / "MLXPodcastPlaybackController.swift").read_text()
        view = (PODCAST / "BatchPodcastView.swift").read_text()
        self.assertIn("BatchPodcastWAVWriter", playback)
        self.assertIn("NSSavePanel", view)
        self.assertIn("allowedContentTypes = [.wav]", view)
        self.assertIn("copyItem", view)

    def test_state_and_ui_hooks_are_mac_only_and_minimal(self):
        app_state = (ROOT / "Controllers" / "AppState.swift").read_text()
        content_view = (ROOT / "Views" / "ContentView.swift").read_text()
        self.assertIn("let batchPodcastSession = BatchPodcastSession()", app_state)
        self.assertIn("globalSummaryComments", app_state)
        self.assertIn("func presentBatchPodcast()", app_state)
        self.assertIn("BatchPodcastPresentationHost(session: appState.batchPodcastSession)", content_view)
        self.assertIn("appState.presentBatchPodcast()", content_view)


if __name__ == "__main__":
    unittest.main()
