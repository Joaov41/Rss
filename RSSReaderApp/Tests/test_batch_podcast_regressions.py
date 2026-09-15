import pathlib
import re
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
PODCAST = ROOT / "RSSReaderApp/Podcast"
PROJECT = (ROOT / "RSSReaderApp.xcodeproj/project.pbxproj").read_text()
APP_STATE = (ROOT / "RSSReaderApp/Controllers/AppState.swift").read_text()
CONTENT_VIEW = (ROOT / "RSSReaderApp/Views/ContentView.swift").read_text()


class BatchPodcastRegressionTests(unittest.TestCase):
    def test_module_is_ios_only_and_has_expected_files(self):
        expected = {
            "BatchPodcastModels.swift",
            "BatchPodcastContextBuilder.swift",
            "BatchPodcastService.swift",
            "BatchPodcastSession.swift",
            "MLXPodcastPlaybackController.swift",
            "BatchPodcastView.swift",
        }
        self.assertEqual({path.name for path in PODCAST.glob("*.swift")}, expected)

        ios_sources = PROJECT.split("A1B2C3D4E5F6A7B8C9D0E231 /* Sources */ = {", 1)[1].split(
            "A1B2C3D4E5F6A7B8C9D0E235 /* Sources */ = {", 1
        )[0]
        mac_sources = PROJECT.split("A1B2C3D4E5F6A7B8C9D0E235 /* Sources */ = {", 1)[1].split(
            "D1E2F3A4B5C6D7E8F9A0B1F0 /* Sources */ = {", 1
        )[0]
        for name in expected:
            self.assertIn(name, ios_sources)
            self.assertNotIn(name, mac_sources)

    def test_podcast_module_has_no_fetch_or_extraction_path(self):
        forbidden = (
            "RedditService",
            "FeedService",
            "URLSession",
            "URLRequest",
            "fetchComments",
            "extractAllCommentTexts",
            "fetchReddit",
            "fetchFeed",
        )
        for path in PODCAST.glob("*.swift"):
            source = path.read_text()
            for token in forbidden:
                self.assertNotIn(token, source, f"{token} found in {path.name}")

    def test_snapshot_builder_and_provider_pinning_are_wired(self):
        self.assertIn("BatchPodcastSnapshot(", APP_STATE)
        self.assertIn("BatchPodcastContextBuilder.build", APP_STATE)
        self.assertIn("cachedRedditCommentsForQA", APP_STATE)
        self.assertIn("selectedProvider = provider", (PODCAST / "BatchPodcastSession.swift").read_text())
        self.assertIn("responseFormat: .strictJSON", APP_STATE)
        self.assertIn("summarizeTextAsync", APP_STATE)

    def test_gemini_generation_reuses_one_podcast_background_task(self):
        session = (PODCAST / "BatchPodcastSession.swift").read_text()
        self.assertEqual(session.count("beginLongRunningTask("), 1)
        self.assertIn('title: "Generating Batch Podcast"', session)
        self.assertIn("textGenerator(prompt, title, provider, backgroundHandle)", session)
        self.assertIn("existingBackgroundTaskHandle: backgroundTaskHandle", APP_STATE)

    def test_short_scripts_are_not_rejected_and_long_scripts_are_capped(self):
        service = (PODCAST / "BatchPodcastService.swift").read_text()
        models = (PODCAST / "BatchPodcastModels.swift").read_text()
        self.assertIn("static let maximumWords = 1_060", models)
        self.assertIn("PodcastEpisodeWordLimiter.limit(episode)", service)
        self.assertNotIn("guard turns.count >=", service)
        self.assertNotIn("guard wordCount >=", service)

    def test_batch_actions_and_minimized_restore_are_wired(self):
        self.assertIn("appState.presentBatchPodcast()", CONTENT_VIEW)
        self.assertIn("BatchPodcastPresentationHost", CONTENT_VIEW)
        view = (PODCAST / "BatchPodcastView.swift").read_text()
        self.assertIn("session.minimize()", view)
        self.assertIn("session.restore()", view)

    def test_podcast_uses_the_app_glassy_blue_background(self):
        view = (PODCAST / "BatchPodcastView.swift").read_text()
        self.assertIn("private var podcastBackground", view)
        self.assertIn("Color.blue.opacity(colorScheme == .dark ? 0.22 : 0.10)", view)
        self.assertIn(".toolbarBackground(.hidden, for: .navigationBar)", view)
        self.assertNotIn(".background(Color(.systemGroupedBackground))", view)

    def test_export_picker_audio_cleanup_and_interruption_paths_are_present(self):
        view = (PODCAST / "BatchPodcastView.swift").read_text()
        session = (PODCAST / "BatchPodcastSession.swift").read_text()
        playback = (PODCAST / "MLXPodcastPlaybackController.swift").read_text()
        self.assertIn("UIDocumentPickerViewController(forExporting:", view)
        self.assertIn("cleanupExportURL", session)
        self.assertIn("removeItem(at: directory)", playback)
        self.assertIn("interruptionNotification", playback)
        self.assertIn("pauseForInterruption", playback)
        self.assertIn("isPlaybackTokenCurrent", playback)

    def test_playback_prepares_all_audio_before_background_playback(self):
        playback = (PODCAST / "MLXPodcastPlaybackController.swift").read_text()
        self.assertIn("preparePlaybackAudio", playback)
        self.assertIn("Prepared podcast audio is missing", playback)
        self.assertIn("prepareCompleteEpisode(from: plan)", playback)
        self.assertIn("copyPreparedEpisode(to: url)", playback)
        self.assertIn("await activityGate.waitUntilActive()", playback)
        self.assertNotIn("allowBackgroundPlayback", playback)
        self.assertLess(
            playback.index("try await self.preparePlaybackAudio("),
            playback.index("try await self.runPlayback("),
        )
        run_playback = playback.split("private func runPlayback(", 1)[1].split(
            "private func preparedData", 1
        )[0]
        self.assertNotIn("synthesize(", run_playback)

        export_method = playback.split("func renderEpisodeForExport(", 1)[1].split(
            "private func preparePlaybackAudio", 1
        )[0]
        self.assertLess(
            export_method.index("copyPreparedEpisode(to: url)"),
            export_method.index("newPlaybackToken()"),
        )

        view = (PODCAST / "BatchPodcastView.swift").read_text()
        self.assertIn('Label("Preparing Audio"', view)

    def test_no_mac_checkout_was_added_to_project_sources(self):
        self.assertNotIn("rss mac/Podcast", PROJECT)
        self.assertNotIn("mac/Podcast", PROJECT)


if __name__ == "__main__":
    unittest.main()
