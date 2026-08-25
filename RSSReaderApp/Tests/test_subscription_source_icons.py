import pathlib
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
CONTENT_VIEW = (ROOT / "RSSReaderApp/Views/ContentView.swift").read_text()
REDDIT_SERVICE = (ROOT / "RSSReaderApp/Services/RedditService.swift").read_text()
YOUTUBE_SERVICE = (ROOT / "RSSReaderApp/Services/YouTubeService.swift").read_text()


class SubscriptionSourceIconTests(unittest.TestCase):
    def test_reddit_uses_each_community_icon_with_a_generic_fallback(self):
        self.assertIn("func fetchSubredditIconURL(subreddit rawSubreddit: String)", REDDIT_SERVICE)
        self.assertIn('case communityIcon = "community_icon"', REDDIT_SERVICE)
        self.assertIn('case iconImg = "icon_img"', REDDIT_SERVICE)
        self.assertIn("fetchSubredditIconURL(subreddit: subreddit)", CONTENT_VIEW)
        self.assertIn("sidebarRedditIcon()", CONTENT_VIEW)

    def test_youtube_uses_each_channel_avatar_with_a_generic_fallback(self):
        self.assertIn("func channelAvatarURL(channelID rawChannelID: String)", YOUTUBE_SERVICE)
        self.assertIn("static func parseChannelAvatarURL(from html: String)", YOUTUBE_SERVICE)
        self.assertIn("static func channelAvatarPageURLs(channelID: String)", YOUTUBE_SERVICE)
        self.assertIn("reloadIgnoringLocalCacheData", YOUTUBE_SERVICE)
        self.assertNotIn("missingChannelAvatarCache", YOUTUBE_SERVICE)
        self.assertIn("YouTubeService.shared.channelAvatarURL(channelID: channelID)", CONTENT_VIEW)
        self.assertIn('"play.rectangle.fill"', CONTENT_VIEW)

    def test_icon_resolution_does_not_change_subscription_persistence(self):
        self.assertIn("private struct SidebarRemoteArtworkView", CONTENT_VIEW)
        self.assertIn(".task(id: cacheKey)", CONTENT_VIEW)
        models = (ROOT / "RSSReaderApp/Models/Models.swift").read_text()
        subscription = models.split("struct Subscription:", 1)[1].split("// MARK: - Feed", 1)[0]
        self.assertNotIn("iconURL", subscription)
        self.assertNotIn("artworkURL", subscription)


if __name__ == "__main__":
    unittest.main()
