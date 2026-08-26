import pathlib
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
PROJECT = (ROOT / "RSSReaderApp.xcodeproj/project.pbxproj").read_text()
MODELS = (ROOT / "RSSReaderApp/Models/Models.swift").read_text()
FEEDS = (ROOT / "RSSReaderApp/Services/FeedService.swift").read_text()
SERVICE = (ROOT / "RSSReaderApp/Services/PodcastEpisodeService.swift").read_text()
DISCOVERY = (ROOT / "RSSReaderApp/Services/PodcastDiscoveryService.swift").read_text()
PLAYER_VIEW = (ROOT / "RSSReaderApp/Views/PodcastEpisodePlayerView.swift").read_text()
SEARCH_VIEW = (ROOT / "RSSReaderApp/Views/PodcastSearchView.swift").read_text()
APP_STATE = (ROOT / "RSSReaderApp/Controllers/AppState.swift").read_text()
PERSISTENCE = (ROOT / "RSSReaderApp/Services/PersistenceManager.swift").read_text()
CLOUD_SYNC = (ROOT / "RSSReaderApp/Services/CloudSyncManager.swift").read_text()
CONTENT_VIEW = (ROOT / "RSSReaderApp/Views/ContentView.swift").read_text()
PLATFORM_VIEWS = (ROOT / "RSSReaderApp/Views/PlatformViews.swift").read_text()
ASK_AI_UTILITIES = (ROOT / "RSSReaderApp/Views/AskAIUtilities.swift").read_text()
INFO_PLIST = (ROOT / "RSSReaderApp/Info.plist").read_text()
BACKGROUND_MANAGER = (ROOT / "RSSReaderApp/Services/GeminiBackgroundTaskManager.swift").read_text()
PODCAST_BACKGROUND_MANAGER = (ROOT / "RSSReaderApp/Services/PodcastBackgroundTaskManager.swift").read_text()
PODCAST_GEMINI = (ROOT / "RSSReaderApp/Services/PodcastGeminiTextService.swift").read_text()


class RealPodcastRegressionTests(unittest.TestCase):
    def test_real_episode_feature_is_separate_from_batch_podcast(self):
        batch_files = {path.name for path in (ROOT / "RSSReaderApp/Podcast").glob("*.swift")}
        self.assertNotIn("PodcastEpisodeService.swift", batch_files)
        self.assertNotIn("PodcastEpisodePlayerView.swift", batch_files)
        self.assertIn("PodcastEpisodeService.swift in Sources", PROJECT)
        self.assertIn("PodcastEpisodePlayerView.swift in Sources", PROJECT)

    def test_audio_enclosures_are_not_treated_as_images_or_scraped_articles(self):
        self.assertIn("let podcastAudioURL", MODELS)
        self.assertIn("var isPodcastEpisode: Bool", MODELS)
        self.assertIn("FeedEnclosureClassifier.classify", FEEDS)
        self.assertIn("let isPodcastAudio = enclosureIsAudio", FEEDS)
        self.assertIn("!article.isPodcastEpisode", FEEDS)
        self.assertIn("let enclosureIsImage = isImage", FEEDS)

    def test_player_has_episode_controls_and_background_integration(self):
        for token in (
            "AVPlayerItem(url:",
            "skip(by seconds:",
            "setPlaybackRate",
            "func stop()",
            "MPRemoteCommandCenter.shared()",
            "commands.stopCommand.isEnabled = true",
            "MPNowPlayingInfoCenter.default()",
            "AVAudioSession.interruptionNotification",
        ):
            self.assertIn(token, SERVICE)
        self.assertIn("gobackward.15", PLAYER_VIEW)
        self.assertIn("goforward.15", PLAYER_VIEW)

    def test_background_episode_has_a_global_pause_and_stop_mini_player(self):
        self.assertIn("struct PodcastEpisodeMiniPlayer", PLAYER_VIEW)
        self.assertIn("if #available(iOS 26.0, *)", PLAYER_VIEW)
        self.assertIn(".glassEffect(", PLAYER_VIEW)
        self.assertIn(".interactive()", PLAYER_VIEW)
        self.assertIn("player.togglePlayback()", PLAYER_VIEW)
        self.assertIn("player.stop()", PLAYER_VIEW)
        self.assertIn('accessibilityLabel("Stop episode and close player")', PLAYER_VIEW)
        self.assertIn("PodcastEpisodeMiniPlayer(", CONTENT_VIEW)
        self.assertIn("appState.selectedArticle?.id != activeEpisodeID", CONTENT_VIEW)
        self.assertIn("appState.podcastEpisodePlayer.isPlaying", CONTENT_VIEW)
        self.assertIn("onOpenEpisode: appState.openActivePodcastEpisode", CONTENT_VIEW)

        # Preserve the proven iPad host while placing the physical-iPhone host
        # outside its NavigationView's constrained content viewport.
        self.assertIn("UIDevice.current.userInterfaceIdiom == .pad", CONTENT_VIEW)
        iphone_view = PLATFORM_VIEWS.split("struct iPhoneContentView", 1)[1].split(
            "struct PlatformViews_Previews", 1
        )[0]
        self.assertIn("PodcastEpisodeMiniPlayer(", iphone_view)
        self.assertIn("appState.selectedArticle?.id != activeEpisodeID", iphone_view)
        self.assertIn("appState.podcastEpisodePlayer.isPlaying", iphone_view)
        self.assertIn("onOpenEpisode: appState.openActivePodcastEpisode", iphone_view)

    def test_player_uses_a_valid_playback_audio_session_configuration(self):
        self.assertIn("setCategory(.playback, mode: .spokenAudio, options: [])", SERVICE)
        self.assertNotIn("setCategory(.playback, mode: .spokenAudio, options: [.allowAirPlay])", SERVICE)

    def test_podcast_answer_timestamps_seek_and_play_in_the_episode_player(self):
        self.assertIn("onPodcastTimestampTap", ASK_AI_UTILITIES)
        self.assertIn('URL.scheme == "rssreader-podcast"', ASK_AI_UTILITIES)
        self.assertIn('URL.host == "seek"', ASK_AI_UTILITIES)
        self.assertIn("applyPodcastTimestampLinks()", ASK_AI_UTILITIES)
        self.assertIn("podcastTimestampTapHandler(for: article)", CONTENT_VIEW)
        self.assertIn("appState.podcastEpisodePlayer.seek(to: seconds)", CONTENT_VIEW)
        self.assertIn("appState.podcastEpisodePlayer.play()", CONTENT_VIEW)

    def test_show_notes_and_transcript_availability_are_explicit(self):
        self.assertIn("PodcastShowNotesFormatter.plainText", CONTENT_VIEW)
        self.assertIn("PodcastTranscriptStatusView", CONTENT_VIEW)
        self.assertIn("Publisher transcript available", PLAYER_VIEW)
        self.assertIn("Private on-device transcript ready", PLAYER_VIEW)
        self.assertIn("No publisher transcript", PLAYER_VIEW)
        self.assertIn("refreshPodcastTranscriptAvailability", APP_STATE)

    def test_summary_and_qa_are_grounded_in_episode_transcripts(self):
        self.assertIn("PodcastTranscriptFeedParser.references", SERVICE)
        self.assertIn("generatedTranscript(", SERVICE)
        self.assertIn("SpeechAnalyzer(", SERVICE)
        self.assertIn("priority: .utility", SERVICE)
        self.assertIn("modelRetention: .whileInUse", SERVICE)
        self.assertIn("timeIntervalSince(lastPublishedAt) >= 0.2", SERVICE)
        self.assertIn("lastPublishedPercentage != 100", SERVICE)
        self.assertIn("AssetInventory.assetInstallationRequest", SERVICE)
        self.assertIn("session.download(for: request)", SERVICE)
        self.assertIn("removeItem(at: localAudioURL)", SERVICE)
        self.assertIn("NSSpeechRecognitionUsageDescription", INFO_PLIST)
        self.assertIn("preparedPodcastTranscript(", APP_STATE)
        self.assertIn("backgroundTaskHandle: backgroundHandle", APP_STATE)
        self.assertIn("for (offset, chunk) in chunks.enumerated()", APP_STATE)
        self.assertIn("Every transcript section is analyzed before reduction", APP_STATE)
        self.assertIn("PodcastTranscriptProcessor.relevantChunks", APP_STATE)
        self.assertIn("Do not use the episode title, show notes, webpage, or outside knowledge as evidence", APP_STATE)

    def test_qa_reuses_the_session_transcript_before_transcribing(self):
        self.assertIn("func cachedTranscript(for article: Article)", SERVICE)
        self.assertIn("func discardTranscript(for episodeID: String)", SERVICE)
        self.assertNotIn("saveCachedTranscript", SERVICE)
        self.assertNotIn("loadCachedTranscript", SERVICE)
        self.assertNotIn("data.write(to:", SERVICE)
        self.assertIn("if let savedTranscript = await self.podcastTranscriptService.cachedTranscript(for: article)", APP_STATE)
        self.assertIn('setPodcastStatusMessage("Reusing the current episode transcript…"', APP_STATE)
        self.assertIn("Q&A is allowed to prepare audio only when no transcript", APP_STATE)
        self.assertIn("func beginPodcastEpisodeSession(for article: Article)", APP_STATE)
        self.assertIn("func endPodcastEpisodeSession(for article: Article)", APP_STATE)
        self.assertIn("podcastEpisodeSessionGenerations", APP_STATE)
        self.assertIn("schedulePodcastTranscriptDiscard", APP_STATE)
        self.assertIn("if activePodcastEpisodeSessionID == article.id", APP_STATE)
        self.assertIn("appState.beginPodcastEpisodeSession(for: article)", CONTENT_VIEW)
        self.assertIn("appState.endPodcastEpisodeSession(for: article)", CONTENT_VIEW)

    def test_podcast_status_and_completion_notice_are_scoped_and_deduplicated(self):
        completion_overlay = CONTENT_VIEW.split(
            "// Fallback notification overlay - high priority", 1
        )[1].split(".zIndex(1000)", 1)[0]
        self.assertIn("private func setPodcastStatusMessage(", APP_STATE)
        self.assertIn("guard podcastStatusMessages[articleID] != message else { return }", APP_STATE)
        self.assertIn("onlyWhenSelected: true", APP_STATE)
        self.assertIn("podcastCompletionNotification", APP_STATE)
        self.assertIn("Task.sleep(for: .seconds(8))", APP_STATE)
        self.assertIn("func openPodcastCompletionNotification()", APP_STATE)
        self.assertIn("func openActivePodcastEpisode()", APP_STATE)
        self.assertIn("Transcript ready for", APP_STATE)
        self.assertIn("Transcript and summary ready for", APP_STATE)
        self.assertIn("appState.openPodcastCompletionNotification()", CONTENT_VIEW)
        self.assertIn("PodcastCompletionNoticeSurface", CONTENT_VIEW)
        self.assertIn(".regular.interactive()", CONTENT_VIEW)
        self.assertNotIn("}\n            .allowsHitTesting(false)", completion_overlay)
        self.assertIn(".allowsHitTesting(false)", completion_overlay)

    def test_transcription_summary_and_qa_continue_as_background_jobs(self):
        self.assertIn('beginTask(title: "Preparing Podcast Summary")', APP_STATE)
        self.assertIn('beginTask(title: "Preparing Podcast Q&A")', APP_STATE)
        self.assertEqual(APP_STATE.count("PodcastBackgroundTaskManager.shared.beginTask"), 2)
        self.assertGreaterEqual(APP_STATE.count("waitForTaskStartIfNeeded()"), 2)
        self.assertGreaterEqual(APP_STATE.count("registerCancellationHandler"), 2)
        self.assertIn("backgroundTaskHandle: backgroundHandle", APP_STATE)
        self.assertIn("stage.backgroundProgressFraction", APP_STATE)
        self.assertIn("audioDuration: audioDuration", SERVICE)
        self.assertIn("transcribingAudio(progress: progress)", SERVICE)
        self.assertIn("try Task.checkCancellation()", SERVICE)

    def test_background_session_does_not_discard_concurrent_existing_jobs(self):
        self.assertNotIn("podcast", BACKGROUND_MANAGER.lower())
        self.assertIn("final class PodcastBackgroundTaskManager", PODCAST_BACKGROUND_MANAGER)
        self.assertIn("recordRootCompletion", PODCAST_BACKGROUND_MANAGER)
        self.assertIn("recordDependentCompletion", PODCAST_BACKGROUND_MANAGER)
        self.assertIn(".podcastTask", PODCAST_BACKGROUND_MANAGER)
        self.assertIn(".podcastProcessing", PODCAST_BACKGROUND_MANAGER)
        self.assertIn("PodcastBackgroundTaskManager.shared.beginTask", APP_STATE)
        self.assertIn("PodcastBackgroundTaskManager.swift in Sources", PROJECT)
        self.assertIn("PodcastGeminiTextService.generate", APP_STATE)
        self.assertNotIn("GeminiBackgroundTaskManager", PODCAST_GEMINI)

    def test_stale_background_expiration_cannot_cancel_a_new_podcast_session(self):
        self.assertIn("activeHandle === expectedRoot", PODCAST_BACKGROUND_MANAGER)
        self.assertIn("activeContinuedTask === task", PODCAST_BACKGROUND_MANAGER)
        self.assertIn("activeContinuedTask !== expectedContinuedTask", PODCAST_BACKGROUND_MANAGER)
        self.assertIn("activeProcessingTask !== expectedProcessingTask", PODCAST_BACKGROUND_MANAGER)

    def test_podcast_provider_failures_and_duplicates_are_not_saved_as_success(self):
        self.assertIn("output = try await performPrivateCloudComputeRequest(prompt)", APP_STATE)
        self.assertIn("privateCloudComputeErrorMessage(error)", APP_STATE)
        self.assertIn("activePodcastProcessingIDs.insert(article.id).inserted", APP_STATE)
        self.assertIn("try Task.checkCancellation()\n                completedSuccessfully = true", APP_STATE)

    def test_unknown_legacy_image_enclosures_keep_their_artwork_path(self):
        self.assertIn("enclosureHasNoTypeHint", FEEDS)
        self.assertIn("podcastAudioURL == nil", FEEDS)
        self.assertIn("FeedEnclosureClassifier.classify", FEEDS)
        self.assertIn("enclosureIsImage\n                || enclosureHasNoTypeHint", FEEDS)
        self.assertIn("!hasPodcastMetadata && !enclosureIsAudio", FEEDS)

    def test_selected_provider_and_explicit_web_ai_both_use_podcast_path(self):
        self.assertIn("requestPodcastSummary(for: article, provider: settings.selectedSummaryProvider)", APP_STATE)
        self.assertIn("requestPodcastSummary(for: article, provider: .webAI)", APP_STATE)
        self.assertIn("provider: settings.selectedSummaryProvider", APP_STATE)
        self.assertIn("provider: .webAI", APP_STATE)
        self.assertIn("PodcastEpisodePlayerView(", CONTENT_VIEW)
        self.assertIn("Ask About This Episode", CONTENT_VIEW)

    def test_podcasts_can_be_found_by_name_and_subscribed_by_feed(self):
        self.assertIn("PodcastDiscoveryService.swift in Sources", PROJECT)
        self.assertIn("PodcastSearchView.swift in Sources", PROJECT)
        self.assertIn('URLQueryItem(name: "media", value: "podcast")', DISCOVERY)
        self.assertIn('URLQueryItem(name: "entity", value: "podcast")', DISCOVERY)
        self.assertIn("let feedUrl: String?", DISCOVERY)
        self.assertIn(".task(id: normalizedQuery)", SEARCH_VIEW)
        self.assertIn("Search podcasts or creators", SEARCH_VIEW)
        self.assertIn("addPodcastSubscription", SEARCH_VIEW)
        self.assertIn('Text("Podcast").tag(SubscriptionSource.podcast)', CONTENT_VIEW)

    def test_podcast_subscriptions_have_their_own_sidebar_filter(self):
        self.assertIn("case podcasts", CONTENT_VIEW)
        self.assertIn('case .podcasts: return "Podcasts"', CONTENT_VIEW)
        self.assertIn("case .podcasts:", CONTENT_VIEW)
        self.assertIn("return isPodcastSubscription(subscription)", CONTENT_VIEW)
        self.assertIn("&& !isPodcastSubscription(subscription)", CONTENT_VIEW)
        self.assertIn("RSSReaderApp.PodcastSubscriptionCanonicalKeys.v1", APP_STATE)
        self.assertIn("recordPodcastClassification(subscription)", APP_STATE)
        self.assertIn("forgetPodcastSubscription(subscription)", APP_STATE)

    def test_saved_podcast_survives_relaunch_and_older_cloud_snapshots(self):
        self.assertIn("RSSReaderApp.SavedPodcastSubscriptions.v1", PERSISTENCE)
        self.assertIn("persistenceManager.savePodcastSubscription(tagged)", APP_STATE)
        self.assertIn("persistenceManager.removeSavedPodcastSubscription(tagged)", APP_STATE)
        self.assertIn("func subscriptionsPreservingSavedPodcasts", PERSISTENCE)
        self.assertGreaterEqual(PERSISTENCE.count("subscriptionsPreservingSavedPodcasts("), 7)
        self.assertIn("merged.append(contentsOf: missing)", PERSISTENCE)
        self.assertIn("id: subscription.id", PERSISTENCE)
        self.assertIn("title: title", PERSISTENCE)
        self.assertIn("contentKind: .podcast", PERSISTENCE)
        self.assertIn("!upgradedKeys.contains($0.canonicalKey)", PERSISTENCE)
        self.assertIn("saveSubscriptionsToLocal(effectiveSubscriptions)", PERSISTENCE)

    def test_podcast_identity_and_additions_sync_to_other_devices(self):
        self.assertIn("enum SubscriptionContentKind", MODELS)
        self.assertIn("let contentKind: SubscriptionContentKind?", MODELS)
        self.assertIn("var isPodcast: Bool", MODELS)
        self.assertIn("contentKind: .podcast", APP_STATE)
        self.assertIn("cloudSync.syncPodcastSubscription(subscription)", PERSISTENCE)
        self.assertNotIn("forceSyncSubscriptions(mergedCloudSubscriptions)", PERSISTENCE)
        self.assertIn('podcastSubscriptionRecordPrefix = "pcv1_"', CLOUD_SYNC)
        self.assertIn("digest.prefix(20)", CLOUD_SYNC)
        self.assertIn("podcastSubscriptionRecordKey(for:", CLOUD_SYNC)
        self.assertIn("cloudSync.reconcilePodcastSubscriptions(in: current)", PERSISTENCE)
        self.assertIn("Migration for the first podcast build", PERSISTENCE)
        self.assertIn("localSubscriptions[placeholder.canonicalKey]", PERSISTENCE)
        self.assertIn("(cachedSubscriptions ?? loadSubscriptionsFromLocal())", PERSISTENCE)

    def test_secondary_podcast_deletion_syncs_without_rewriting_other_subscriptions(self):
        self.assertIn("cloudSync.removePodcastSubscription(subscription)", PERSISTENCE)
        self.assertIn("isDeleted: true", CLOUD_SYNC)
        self.assertIn("subscriptions.filter { records[$0.canonicalKey] == nil }", CLOUD_SYNC)
        self.assertIn("where key.hasPrefix(Keys.podcastSubscriptionRecordPrefix)", CLOUD_SYNC)

    def test_podcast_record_can_hydrate_before_base_subscription_blob(self):
        self.assertIn("func hasCloudPodcastSubscriptionRecords()", CLOUD_SYNC)
        self.assertIn("if !cloudSync.hasCloudSubscriptionsValue()", PERSISTENCE)
        self.assertIn("cloudSync.reconcilePodcastSubscriptions(in: current)", PERSISTENCE)
        self.assertIn("hasCloudPodcastSubscriptionRecords()", APP_STATE)
        has_base = CLOUD_SYNC.split("func hasCloudSubscriptionsValue()", 1)[1].split("}", 1)[0]
        self.assertNotIn("podcastSubscriptionRecordPrefix", has_base)


if __name__ == "__main__":
    unittest.main()
