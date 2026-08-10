# RSSReaderApp

RSSReaderApp is a native reader for iPhone and iPad. It began as a personal RSS reader and has gradually grown into one place for following articles, Reddit communities, and YouTube channels.

## Experimental YouTube support

The latest TestFlight build adds experimental YouTube support. Search for a public channel by name, subscribe to it, receive its latest videos in the feed, and watch them inside the app. When captions are available, RSSReaderApp retrieves the actual transcript so summaries and Q&A are based on what was said in the video, not just its title or description.

## Features

- RSS and Atom subscriptions.
- Reddit subscriptions, posts, and comments. You can create posts, reply, vote, and use the app as a lightweight Reddit client through the free Reddit API associated with your account.
- YouTube channel search and subscriptions.
- An internal YouTube player with standard YouTube controls.
- Transcript-grounded YouTube summaries and Q&A.
- Unified All, Unread, Favorites, and Today views.
- Filters for articles, Reddit, and YouTube.
- List, compact, and magazine feed layouts.
- In-app article Reader mode and full webpage access.
- Individual article, post, and comment summaries.
- Overall summaries covering multiple articles or Reddit posts.
- Follow-up Q&A grounded in articles, comments, or video transcripts.
- Select text in a summary and ask the app about it.
- Reddit comment summaries and deeper analysis.
- Clickable source references inside Overall Summaries.
- Whiteboards and infographics.
- Two-host podcasts generated from a saved batch of source material.
- Local and cloud text-to-speech, including on-device MLX speech.
- Multiple AI model options:
  - Apple Local model.
  - Local LiteRT and MLX models.
  - Gemini API with your own key (BYOK).
  - Persistent ChatGPT and Gemini web sessions.
  - Codex/Summarize for subscribers.
  - An optional Mac-based Apple PCC gateway.
- OPML import and export.
- iCloud synchronization for subscriptions and reading state.
- Light, dark, and system appearance.
- Cache, storage, and downloaded-model management.
- Native layouts for iPhone, iPad, and resizable Stage Manager windows.

## AI providers and Apple PCC

Apple Private Cloud Compute is enabled in the app, but TestFlight builds using iOS 27-only APIs are not currently accepted while iOS 27 is still in beta. The PCC path will work when iOS 27 is publicly released.

If you have a Mac running the latest beta, you can use PCC through the optional Mac gateway. The Mac makes the call through the PCC CLI and returns the result to RSSReaderApp over the local network.

Codex/Summarize uses the configured Mac Summarize path and is available to subscribers. Other providers include Apple Local, LiteRT/MLX local models, Gemini API, persistent ChatGPT/Gemini web sessions, Apple Cloud, and the optional PCC gateway.

## YouTube limitations

The YouTube integration uses public channel feeds and does not require access to your YouTube account. Transcript features depend on usable captions being available. If a transcript cannot be retrieved, the app reports that the video cannot currently be summarized instead of generating a summary from metadata alone.

## Beta

This is still a beta. Feedback is especially welcome about YouTube subscriptions, transcript reliability, playback, summaries, Q&A, and the interface on different devices.

Copyright (c) 2026 Joao V. See [LICENSE](LICENSE) for attribution terms.
