import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]


class BackgroundAudioRegressionTests(unittest.TestCase):
    def test_audio_background_mode_remains_declared_for_read_aloud_and_podcasts(self):
        info_plist = (ROOT / "RSSReaderApp/Info.plist").read_text()
        self.assertIn("<key>UIBackgroundModes</key>", info_plist)
        self.assertIn("<string>audio</string>", info_plist)

    def test_summary_audio_falls_back_without_cloud_credentials_on_ios(self):
        sources = [
            ROOT / "RSSReaderApp/Views/SummaryColumnView.swift",
            ROOT / "RSSReaderApp/Views/ContentView.swift",
            ROOT / "RSSReaderApp/Views/RedditDetailView.swift",
        ]
        for source_path in sources:
            source = source_path.read_text()
            self.assertIn("getOpenAIApiKey()", source)
            self.assertIn("speakSummaryLocally", source)

    def test_local_tts_waits_for_initial_model_load_before_short_chunk_timeout(self):
        service = (ROOT / "RSSReaderApp/Services/KokoroTTSService.swift").read_text()
        playback = (ROOT / "RSSReaderApp/Utilities/KokoroPlayback.swift").read_text()
        self.assertIn("var isModelReady", service)
        self.assertIn("var isModelLoading", service)
        self.assertIn("isModelReady", playback)
        self.assertIn("120_000_000_000", playback)
        self.assertIn("Local TTS is still preparing its model", playback)
        self.assertIn("MLX TTS timed out while preparing audio", playback)

    def test_local_tts_prepares_one_complete_file_before_background_playback(self):
        playback = (ROOT / "RSSReaderApp/Utilities/KokoroPlayback.swift").read_text()
        self.assertIn("PreparedKokoroAudioCache", playback)
        self.assertIn("BatchPodcastWAVWriter", playback)
        self.assertIn("AVAudioPlayer(contentsOf: preparedURL)", playback)
        self.assertIn("waitUntilApplicationIsActive", playback)
        self.assertLess(
            playback.index("for chunk in chunks"),
            playback.index("AVAudioPlayer(contentsOf: preparedURL)"),
        )
        self.assertNotIn("var nextTask: Task<Data, Error>", playback)

    def test_all_local_tts_surfaces_report_preparing_until_playback_starts(self):
        sources = [
            ROOT / "RSSReaderApp/Views/SummaryColumnView.swift",
            ROOT / "RSSReaderApp/Views/ContentView.swift",
            ROOT / "RSSReaderApp/Views/RedditDetailView.swift",
        ]
        for source_path in sources:
            source = source_path.read_text()
            self.assertIn('Text("Preparing local TTS...")', source)
            self.assertEqual(
                source.count("startKokoroPlayback("),
                source.count("onPlaybackStarted:"),
                source_path.name,
            )


if __name__ == "__main__":
    unittest.main()
