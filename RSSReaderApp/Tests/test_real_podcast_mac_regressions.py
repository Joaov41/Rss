import pathlib
import re
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]


def read(relative):
    return (ROOT / relative).read_text()


class RealPodcastMacRegressionTests(unittest.TestCase):
    def test_subscription_and_article_keep_optional_podcast_metadata(self):
        models = read("RSSReaderApp/Models/Models.swift")
        self.assertIn("enum SubscriptionContentKind: String, Codable", models)
        self.assertIn("case podcast", models)
        self.assertIn("let contentKind: SubscriptionContentKind?", models)
        for field in ("podcastAudioURL", "podcastAudioMIMEType", "podcastDuration", "podcastLanguageCode"):
            self.assertIn(field, models)

    def test_audio_enclosures_are_not_artwork(self):
        feed = read("RSSReaderApp/Services/FeedService.swift")
        self.assertIn("FeedEnclosureClassifier", feed)
        self.assertIn("isPodcastAudio", feed)
        self.assertIn("podcastAudioURL", feed)
        self.assertIn("if !article.isPodcastEpisode", feed)

    def test_transcript_parser_and_session_cache_are_private_and_timestamped(self):
        service = read("RSSReaderApp/Services/PodcastEpisodeService.swift")
        for parser_type in ("parseJSON", "parseTimedText", "treatingAsHTML"):
            self.assertIn(parser_type, service)
        self.assertIn('ext == "vtt"', service)
        self.assertIn('ext == "srt"', service)
        self.assertIn("memoryCache", service)
        self.assertIn("discardTranscript", service)
        self.assertIn("citationLabel", service)
        self.assertIn("relevantChunks", service)

    def test_cloud_records_use_versioned_40_hex_keys_and_tombstones(self):
        cloud = read("RSSReaderApp/Services/CloudSyncManager.swift")
        self.assertIn('podcastSubscriptionRecordPrefix = "pcv1_"', cloud)
        self.assertIn("Keys.podcastSubscriptionRecordPrefix + digest.prefix(20)", cloud)
        self.assertIn(".map { String(format: \"%02x\", $0) }.joined()", cloud)
        self.assertIn("isDeleted", cloud)
        self.assertIn("modifiedAt", cloud)
        self.assertIn("reconcilePodcastSubscriptions", cloud)

    def test_saved_podcasts_and_partial_cloud_hydration_preserve_other_subscriptions(self):
        persistence = read("RSSReaderApp/Services/PersistenceManager.swift")
        cloud = read("RSSReaderApp/Services/CloudSyncManager.swift")
        self.assertIn("RSSReaderApp.SavedPodcastSubscriptions.v1", persistence)
        self.assertIn("subscriptionsPreservingSavedPodcasts", persistence)
        self.assertGreaterEqual(persistence.count("subscriptionsPreservingSavedPodcasts("), 7)
        self.assertIn("cloudSync.syncPodcastSubscription(subscription)", persistence)
        self.assertIn("cloudSync.removePodcastSubscription(subscription)", persistence)
        self.assertNotIn("forceSyncSubscriptions(mergedCloudSubscriptions)", persistence)
        self.assertIn("if !cloudSync.hasCloudSubscriptionsValue()", persistence)
        self.assertIn("cloudSync.reconcilePodcastSubscriptions(in: current)", persistence)
        self.assertIn("localSubscriptions[placeholder.canonicalKey]", persistence)
        self.assertIn("subscriptions.filter { records[$0.canonicalKey] == nil }", cloud)

    def test_podcast_sync_does_not_share_or_rewrite_read_state(self):
        cloud = read("RSSReaderApp/Services/CloudSyncManager.swift")
        self.assertIn('readArticlesShardPrefix = "cloud_v2_readArticles_"', cloud)
        self.assertIn('readRedditPostsShardPrefix = "cloud_v2_readRedditPosts_"', cloud)
        podcast_record = cloud.split(
            "private func setPodcastSubscriptionRecord", 1
        )[1].split("private func podcastSubscriptionRecords", 1)[0]
        self.assertNotIn("readArticles", podcast_record)
        self.assertNotIn("readRedditPosts", podcast_record)

    def test_mac_background_activity_and_speech_usage_description(self):
        background = read("RSSReaderApp/Services/PodcastBackgroundTaskManager.swift")
        self.assertIn("ProcessInfo.processInfo.beginActivity", background)
        self.assertIn("automaticTerminationDisabled", background)
        transcript = read("RSSReaderApp/Services/PodcastEpisodeService.swift")
        self.assertIn("#if os(iOS) || os(macOS)", transcript)
        self.assertIn("SpeechAnalyzer.Options", transcript)
        self.assertIn("priority: .utility", transcript)
        self.assertIn("modelRetention: .whileInUse", transcript)
        plist = read("RSSReaderApp/Info-macOS.plist")
        self.assertIn("NSSpeechRecognitionUsageDescription", plist)
        self.assertNotIn("NSMicrophoneUsageDescription", plist)

    def test_podcast_transcription_progress_is_coalesced(self):
        transcript = read("RSSReaderApp/Services/PodcastEpisodeService.swift")
        self.assertIn("lastReportedPercentage", transcript)
        self.assertIn("lastReportedAt", transcript)
        self.assertIn("timeIntervalSince(lastReportedAt) >= 0.2", transcript)
        self.assertIn("if audioDuration != nil, lastReportedPercentage != 100", transcript)

    def test_podcast_status_updates_are_deduplicated_and_visible_episode_scoped(self):
        app_state = read("RSSReaderApp/Controllers/AppState.swift")
        self.assertIn("private func setPodcastStatusMessage(", app_state)
        self.assertIn("guard podcastStatusMessages[articleID] != message else { return }", app_state)
        self.assertGreaterEqual(app_state.count("onlyWhenSelected: true"), 8)
        helper_body = app_state.split("private func setPodcastStatusMessage(", 1)[1].split(
            "/// Full single-item context", 1
        )[0]
        self.assertIn("selectedArticle?.id == articleID", helper_body)

    def test_article_remote_providers_use_full_context_and_local_models_keep_bound(self):
        app_state = read("RSSReaderApp/Controllers/AppState.swift")
        self.assertIn("String(fullArticleContext(article).prefix(12_000))", app_state)
        self.assertGreaterEqual(app_state.count("articleFullContextSummaryPrompt(for: article)"), 5)
        self.assertGreaterEqual(app_state.count("articleFullQAPrompt(article: article"), 5)
        self.assertIn("let prompt = articleFullQAPrompt(\n", app_state)
        self.assertIn("prompt = articleSummaryPrompt(for: article)", app_state)
        self.assertIn("let content = localBoundedArticleContext(article)", app_state)
        self.assertNotIn("let maxLength = 10000", app_state)

    def test_reddit_single_item_context_is_uncapped_and_recursive_for_every_provider(self):
        app_state = read("RSSReaderApp/Controllers/AppState.swift")
        full_context = app_state.split(
            "private func fullRedditContext", 1
        )[1].split("private func cleanedArticleContent", 1)[0]
        self.assertIn("flatten(comment.replies", full_context)
        self.assertNotIn("prefix(", full_context)
        self.assertNotIn("maxCharacters", full_context)
        self.assertNotIn("normalizedCommentBodyForSummary", app_state)
        self.assertNotIn("flattenedCommentBodiesForSummary", app_state)
        self.assertIn("fullRedditContext(post: post, comments: comments)", app_state)

    def test_podcast_summary_and_qa_call_selected_provider_and_reuse_transcript(self):
        app_state = read("RSSReaderApp/Controllers/AppState.swift")
        summary = app_state.split(
            "private func requestPodcastSummary(", 1
        )[1].split("private func askQuestionAboutPodcastEpisode", 1)[0]
        qa = app_state.split(
            "private func askQuestionAboutPodcastEpisode", 1
        )[1].split("// MARK: - Unified Summary Request Handler", 1)[0]
        self.assertIn("generatePodcastText(", summary)
        self.assertIn("updateArticleSummaryFromCloud(article, summary: summary)", summary)
        self.assertIn("cachedTranscript(for: article)", qa)
        self.assertIn("generatePodcastText(", qa)
        self.assertIn("PodcastTranscriptProcessor.evidenceText(evidenceChunks)", qa)
        self.assertNotIn("Select a supported provider to continue", qa)
        self.assertIn("requestPodcastSummary(for: article, provider: settings.selectedSummaryProvider)", app_state)
        self.assertGreaterEqual(app_state.count("requestPodcastSummary(for: article, provider: .webAI)"), 2)
        self.assertIn("provider: settings.selectedSummaryProvider", app_state)
        self.assertIn("provider: .webAI", app_state)

    def test_background_podcast_work_reports_transcript_and_summary_completion(self):
        app_state = read("RSSReaderApp/Controllers/AppState.swift")
        content = read("RSSReaderApp/Views/ContentView.swift")
        self.assertIn("podcastCompletionNotification", app_state)
        self.assertIn("transcript.sourceURL == article.podcastAudioURL", app_state)
        self.assertIn("selectedArticle?.id != article.id", app_state)
        self.assertIn("Transcript ready for", app_state)
        self.assertIn("Transcript and summary ready for", app_state)
        self.assertIn("appState.podcastCompletionNotification", content)
        self.assertIn('Image(systemName: "checkmark.circle.fill")', content)

    def test_podcast_completion_banner_is_glassy_and_opens_completed_episode(self):
        app_state = read("RSSReaderApp/Controllers/AppState.swift")
        content = read("RSSReaderApp/Views/ContentView.swift")
        banner = content.split(
            "if let podcastNotification = appState.podcastCompletionNotification", 1
        )[1].split("if appState.showFallbackNotification", 1)[0]

        self.assertIn("private var podcastCompletionArticleID: String?", app_state)
        self.assertIn("func openPodcastCompletionNotification()", app_state)
        self.assertIn("articleForGlobalSummaryReference(articleID)", app_state)
        self.assertIn("setSelectedArticle(article)", app_state)
        self.assertIn("articleID: article.id", app_state)
        self.assertIn("Button {", banner)
        self.assertIn("appState.openPodcastCompletionNotification()", banner)
        self.assertIn(".regular.interactive()", banner)
        self.assertNotIn(".background(.regularMaterial)", banner)

    def test_mini_player_artwork_opens_the_active_podcast_episode(self):
        app_state = read("RSSReaderApp/Controllers/AppState.swift")
        content = read("RSSReaderApp/Views/ContentView.swift")
        player_view = read("RSSReaderApp/Views/PodcastEpisodePlayerView.swift")
        mini_player = player_view.split("struct PodcastEpisodeMiniPlayer", 1)[1].split(
            "struct PodcastTranscriptStatusView", 1
        )[0]

        self.assertIn("func openActivePodcastEpisode()", app_state)
        self.assertIn("podcastEpisodePlayer.activeEpisodeID", app_state)
        self.assertIn("articleForGlobalSummaryReference(articleID)", app_state)
        self.assertIn("setSelectedArticle(article)", app_state)
        self.assertIn("onOpenEpisode: appState.openActivePodcastEpisode", content)
        self.assertIn("let onOpenEpisode: () -> Void", mini_player)
        self.assertIn("Button(action: onOpenEpisode)", mini_player)
        self.assertIn('.help("Open podcast episode")', mini_player)

    def test_mini_player_is_visible_only_during_active_playback(self):
        content = read("RSSReaderApp/Views/ContentView.swift")
        mini_player_host = content.split(
            "// Podcast presentation is rooted here", 1
        )[1].split("// (iOS share presented", 1)[0]

        self.assertIn("podcastEpisodePlayer.activeEpisodeID != nil", mini_player_host)
        self.assertIn("podcastEpisodePlayer.isPlaying", mini_player_host)
        self.assertIn("PodcastEpisodeMiniPlayer(", mini_player_host)

    def test_mac_ui_and_project_membership(self):
        content = read("RSSReaderApp/Views/ContentView.swift")
        player = read("RSSReaderApp/Views/PodcastEpisodePlayerView.swift")
        project = read("RSSReaderApp.xcodeproj/project.pbxproj")
        self.assertIn("case podcasts", content)
        self.assertIn('Text("Podcast").tag(SubscriptionSource.podcast)', content)
        self.assertIn("PodcastTranscriptStatusView", content)
        self.assertIn("PodcastTimestampCitationView", content)
        self.assertIn("player.seek(to: seconds)", player)
        for name in (
            "PodcastDiscoveryService.swift",
            "PodcastEpisodeService.swift",
            "PodcastGeminiTextService.swift",
            "PodcastBackgroundTaskManager.swift",
            "PodcastEpisodePlayerView.swift",
            "PodcastSearchView.swift",
        ):
            self.assertGreaterEqual(project.count(name), 2, name)

    def test_full_and_local_article_context_helpers_are_distinct(self):
        app_state = read("RSSReaderApp/Controllers/AppState.swift")
        full = re.search(r"private func fullArticleContext\(_ article: Article\).*?\n    }", app_state, re.S).group(0)
        bounded = re.search(r"private func localBoundedArticleContext\(_ article: Article\).*?\n    }", app_state, re.S).group(0)
        self.assertIn("article.content", full)
        self.assertNotIn("prefix(12_000)", full)
        self.assertIn("fullArticleContext(article).prefix(12_000)", bounded)
        self.assertIn("articleFullContextSummaryPrompt", app_state)
        self.assertIn("articleFullQAPrompt", app_state)

    def test_reddit_context_helper_recurses_without_single_item_caps(self):
        app_state = read("RSSReaderApp/Controllers/AppState.swift")
        helper = re.search(r"private func fullRedditContext\(post: RedditPost, comments: \[RedditCommentModel\]\).*?\n    }", app_state, re.S).group(0)
        self.assertIn("flatten(comment.replies", helper)
        self.assertNotIn("prefix(18)", helper)
        self.assertNotIn("prefix(280)", helper)
        self.assertIn("redditFullSummaryPrompt", app_state)
        self.assertIn("redditFullQAPrompt", app_state)


if __name__ == "__main__":
    unittest.main()
