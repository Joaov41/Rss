# Port the iPad UI/behaviour changes to the Mac version of RSSum

You are working on the **macOS version** of RSSum (the RSS / Reddit / YouTube / podcast reader, bundle `com.joaovalente.RSSReaderApp`). The Mac version lives in its **own project folder**, separate from the iOS code:

**Mac project (the one you change): `/Volumes/screen/rss mac`** (Xcode project `RSSReaderApp.xcodeproj`, sources in `RSSReaderApp/`).

> ⚠️ **It already has uncommitted work.** `/Volumes/screen/rss mac` is a git repo (last commit `0cc061c3c`) with about 60 uncommitted changes that belong to the user. **Before editing anything**, run `git status` and ask the user how to protect that work: commit it as-is first, or work on a new branch on top of it. Never discard, stash-and-forget, reset or overwrite it.

Orientation (checked in the Mac sources): it mirrors the iOS layout. `Views/ContentView.swift` contains `ReaderModeService`, `ArticleReaderWebView`, `DraggableGlobalSummaryView` and `SummaryTTSMiniPlayer`; `Views/RedditDetailView.swift` has `GlassyCommentSummary`; `Models/RedditCommentModels.swift` has `extractDisplayLinks`; `Views/YouTubePlayerView.swift` exists; Kokoro TTS is used from `Podcast/MLXPodcastPlaybackController.swift`, `Views/SummaryColumnView.swift` and `Views/SettingsView.swift`. **LiteRT is still present** (`Models/Models.swift`, `Controllers/AppState.swift`, `Views/SettingsView.swift`). The Mac sources have **no** `AskAITextView` (find the Mac text view that renders summaries for B1), **no** `OverlayBarScrollEdgeFade` (G2 is likely not applicable), and **no** `scrollEdgeEffect` modifiers (see G1).

A long series of UI and behaviour changes was made to the **iOS/iPadOS** code. Your job is to bring **every one of them that applies to iPad** to the Mac version, adapted to macOS. Each one is described below, with nothing left out. Changes that were iPhone-only, website-only or later undone are listed at the end as **not to port**, so you can see nothing was dropped silently.

## Where the reference code is

- **iOS reference project (read-only, do not modify):** `/Volumes/screen/rss latest ios27 - UI fix copy`
  - This is a git repo. Baseline = commit `7a58b3c`; final = `HEAD`.
  - The **final state of the iOS code is the source of truth**. Read the actual code there for anything you need to match. `git show <hash>` works for any commit named below.
- **This handoff folder:** `/Volumes/screen/rss latest ios27 - UI fix copy/MacPortHandoff/`
  - `net-changes-baseline-to-final.diff`: every app-code change from baseline to final, in one diff (the net result, with no back-and-forth).
  - `patches/NN-<hash>-<title>.patch`: the same changes one commit at a time, in order, for context on why and how each changed. Patches 06 and 20 were removed because they were reverted later.

Main iOS files involved: `RSSReaderApp/Views/ContentView.swift` (very large; also contains `#if os(macOS)` branches you can learn from), `RSSReaderApp/Views/RedditDetailView.swift`, `RSSReaderApp/Views/AskAIUtilities.swift`, `RSSReaderApp/Views/CommentViews.swift`, `RSSReaderApp/Models/RedditCommentModels.swift`, `RSSReaderApp/Models/Models.swift`, `RSSReaderApp/Controllers/AppState.swift`, `RSSReaderApp/Views/SettingsView.swift`, `RSSReaderApp/Views/YouTubePlayerView.swift`, `RSSReaderApp/Services/KokoroTTSService.swift`, `RSSReaderApp/Utilities/KokoroPlayback.swift`.

## How to work

1. **Explore the Mac project first.** Map each item below to the Mac equivalent: file, view, function. Names may differ: iOS has `DetailTopBar`, `IOSArticleActionCapsule`, `AskAITextView: UITextView`, `ArticleReaderWebView: UIViewRepresentable`; the Mac will have NSView/NSTextView/NSViewRepresentable versions or different structures. Don't force an iOS construct where the Mac has its own. Reproduce the **behaviour and look** described.
2. **Port the final behaviour, not the history.** Where an item was changed several times, only the final state matters. It's described here and it's what `HEAD` contains.
3. Work **one numbered item at a time**. After each item, build the macOS scheme and fix any errors before moving on. If the Mac project is a git repo, commit each item separately with a clear message.
4. **Don't change anything not listed here.** No refactors or extra "improvements". Keep the Mac project's existing conventions: naming, comment style, `#if os(macOS)` usage.
5. Use Mac idioms where needed: `NSPasteboard` instead of `UIPasteboard`, `NSFont`/`NSTextView` instead of `UIFont`/`UITextView`, no `UIDevice`, no memory-warning notification, `.help()` tooltips on icon buttons, pointer hover states.
6. If an item **does not apply** on Mac (the feature doesn't exist there), don't invent it. Record it as "not applicable" with the reason.
7. **Decisions for the user** are marked **DECISION**. Implement the iPad behaviour as the default, but call these out in your final report so the user can confirm.

---

## A. Models and providers

### A1. Remove the LiteRT local model provider (patch 01)
- Remove the "LiteRT Local" summary provider completely: the `SummaryProvider` case `mlxLocal` (raw value `"MLX Local"`), `LiteRTLocalService.swift`, `LocalLLMCompatibility.swift` if it only served LiteRT, the Swift package / framework reference in the Xcode project, all settings UI rows for it, and every `case .mlxLocal` branch in AppState, ContentView, RedditDetailView, SettingsView, SummaryColumnView and AIQuestionView.
- **Settings must still decode:** give `SummaryProvider` a custom `init(from:)` that maps any unknown stored raw value (including the old `"MLX Local"`) to `.coreAIMLXLocal`.
- The MLX settings stay, but are now owned by the CoreAI MLX path: `mlxModelID` defaults to `CoreAIMLXLocalService.defaultModelRepo`; the context/output token helpers are renamed `normalizedMLXContextTokens`, `effectiveMLXContextTokens`, `normalizedMLXOutputTokens` with constants `localMLXDefaultContextTokens = 2_048`, `localMLXContextTokenCap = 8_192`.
- Wherever the code chose `.mlxLocal` as a prompt/fallback provider (for example when the selected provider is Apple Local/Cloud), use `.coreAIMLXLocal`.
- Done when: the Mac app builds with no LiteRT references (`grep -ri litert` is empty in code and project), and a settings file saved with "MLX Local" loads without error.

---

## B. Summary cards (articles, Reddit posts, comment summaries, batch/overall summaries)

### B1. Visual structure inside summary text, without changing the text (patches 02, 03)
In the text view that shows summaries (iOS: `AskAITextView.applySummaryStructureStyling()` in `AskAIUtilities.swift`), after the text is set, apply **attribute-only** styling. The characters must stay identical so Copy, read-aloud and Ask AI still use the same text.
- A paragraph is a **heading** when it's a short standalone line: 70 characters or fewer, starts with an uppercase letter or digit, 1–9 words, doesn't start with "• ", and either ends with ":" (with no other colon) or doesn't end in sentence punctuation (`.!?,;:"”`) and contains no ": ". Headings are bold at the body size **+4 pt**.
- A leading **"Short Label:"** (regex `^[A-Z0-9][A-Za-z0-9&/'’()\- ]{0,48}:(?=\s)`, at most 6 words, with text after it) is **bold** at body size, including after a "• " bullet.
- Paragraphs starting with **"• "** get a hanging indent equal to the width of "• ".
- The empty line right **after a heading** is drawn in a tiny font (`max(4, body * 0.35)`), so the heading sits closer to its own text than to the paragraph above.
- Only apply this when the text has more than one non-empty paragraph.
- Done when: a multi-paragraph summary shows larger bold headings, bold "Label:" prefixes and indented bullets, and copying it gives exactly the original plain text.

### B2. Summary text clean-up (patch 02)
In the summary display-cleaning function (iOS: in `AskAIUtilities.swift`, where summaries are cleaned for display):
- Convert lines starting with "-" or "–" followed by a space into "• " bullets: `(?m)^[ \t]*[-–][ \t]+` becomes `• `.
- Remove fake `[0:00]` / `[00:00]` timestamps **only when 3 or more** appear in the text (`removingRepeatedZeroTimestamps`). A single one can be a genuine citation, so leave it.

### B3. Summary card header row: title, then copy, then quiet audio icons (patches 02, 04)
- `ArticleGlassySummary` gained `headerTitle: String?` and `onCopy: (() -> Void)?`. The card's top row shows the title ("Summary") on the left, and on the right a **copy** icon button (`doc.on.doc`, turning into a green `checkmark` for 1.5 s after copying) plus the read-aloud controls. There's no separate "Copy Summary" capsule button under the card any more. Remove those capsule buttons everywhere (article summary, Today summary, Reddit comment summary).
- Card spacing: header row top padding 12 (was 16); text block top 8 / bottom 16 (was 16/16).
- The article detail summary passes `headerTitle: "Summary"` and `onCopy:`. The Today "Topics Overview" summary passes `onCopy:` only (its section already has a title).

### B4. Quiet read-aloud icons instead of the glass capsule (patch 04)
- `SummaryTTSMiniPlayer` renders **plain small icons**, with no glass capsule. When not speaking it shows `play.fill` (cloud/Settings voice) and `speaker.wave.2` (local voice). While speaking it shows only `stop.fill`, green when the local voice is speaking. The two states crossfade (0.15 s).
- New `SummaryQuietIconButton`: 15 pt medium SF Symbol, secondary colour, 36×36 hit area, a subtle circular pressed highlight, 40% opacity when disabled, `.help` and accessibility label from `helpText`.
- `SummaryGlassActionButton` now just renders a `SummaryQuietIconButton`. Keep its signature so existing callers compile.
- On Mac, add a hover highlight if that's the Mac convention in the project.

### B5. Reddit comment-summary header row (patch 03)
In `GlassyCommentSummary` the first row is: a **sentiment pill** (`Neutral`/`Positive`/…, sentiment colour on a 15% tint capsule, subheadline semibold) + "**N comments**" (secondary), a Spacer, then the quiet audio icons + copy icon in one group. The old separate "stats" block and copy capsule under the summary are removed.

### B6. No width cap on summary text
Summary and answer text runs the **full width of its card**. A readable-width cap was tried and reverted, so do not cap it.

---

## C. Ask / Q&A

### C1. Compact Ask composer with suggestion chips (patch 12)
Replace the old article and Reddit Q&A panels with the shared `AskComposerBar` (iOS: `ContentView.swift`, `struct AskComposerBar`):
- One rounded field row: a `questionmark.circle` icon, the text field (17 pt, `.plain` style, submit sends), then **inside the field on the right** the web-model button (`quote.bubble`, only when a web AI provider is enabled, tooltip/label = provider name) and a **send** button (arrow-up in an accent-filled circle when there's text). An **✕** button outside the field closes the composer.
- Under the field, **suggestion chips** that fill in and send a question:
  - Articles: "Key points", "What's new here?", "Explain simply". The questions use "article", "episode" or "video" depending on the item (`qaSuggestions(for:)`).
  - Reddit: "Key points", "Where do people disagree?", "Consensus".
- Placeholder: "Ask about this article…", "Ask about this episode…" or "Ask about this video…", and "Ask about this post and its comments…" for Reddit.
- The answer panel appears **only once there's something to show** (a question is processing or an answer exists): a softly filled rounded panel with the answer, then the quiet audio + copy icons (C2).

### C2. Answer actions as quiet icons (patch 13)
Under an answer: the same `SummaryTTSMiniPlayer` + copy `SummaryGlassActionButton` (`doc.on.doc`, "Copy answer") as a plain icon row (spacing 2, top padding 2, leading 12). No capsule.

### C3. Batch/overall summary Ask box: ✕ closes it (patch 23)
In the overall-summary window's Ask box, the ✕ in the button group used to only clear the text (`resetQAState(keepInterface: true)`), which looked like it did nothing. It now **closes the Ask box**: `resetQAState()` inside `withAnimation(.easeInOut(duration: 0.2))`, accessibility label "Close".

---

## D. One consistent icon set, and the toolbars

### D1. Final symbol meanings, used everywhere (patches 07, 09, 24)
| Action | SF Symbol |
|---|---|
| Summarize (Settings model) | `text.quote` (replaces `sparkles`, `text.bubble`) |
| Anything sent to the **web** model (summary, ask, menus, badges) | `quote.bubble` (replaces `globe`, `arrow.up.forward.app`, `bubble.left.and.bubble.right`) |
| Ask (Settings model) | `questionmark.circle` (replaces `questionmark.bubble`, `questionmark.circle.fill`, `sparkles` in answer headers) |
| Answer header icon | `questionmark` |
| Copy | `doc.on.doc` |
| Retry | `arrow.clockwise` |

Also: "Summarize Today", "Summarize Articles" and "Summarize Reddit" use `text.quote`, and the empty overall summary says "Tap the summarize button to generate an overall summary." No logos or provider brand marks anywhere, only the symbols (trademark concern). Search the whole Mac project for `globe`, `sparkles`, `text.bubble`, `arrow.up.forward.app`, `bubble.left.and.bubble.right` and `questionmark.bubble` in action buttons, and replace them per the table.

### D2. Article top bar: labelled Summarize (patch 02)
In the article detail top bar (iOS `DetailTopBar`), Summarize is an **icon + "Summarize" text** button (`IOSArticleChromeLabeledButtonStyle`: 14 pt semibold, 12 horizontal padding, min height 36, capsule pressed highlight). It's icon-only on iPhone, so use the **labelled** version on Mac. Add accessibility labels and tooltips: "Summarize", "Add/Remove Favorites", "Ask about this article", "Summarize with <provider>".

### D3. Reddit comments toolbar (patches 02, 08, 10)
Final layout of the comments header bar: **"Summarize"** (icon + text), **"Ask"** (icon + text, becomes "Close" with `xmark.circle` while Ask is open), **Deep Analysis** as its own icon button (`chart.pie.fill`, disabled while comments load), then, only when web AI is enabled, a **web menu** with icon `quote.bubble`. Inside the menu is a section header "**Send to <provider name>**" with "Comment Summary" and "Deep Analysis". The same "Send to <provider>" section is used in the compact variant of that menu. Labelled buttons use `RedditCommentsChromeLabeledButtonStyle` (same metrics as D2).

### D4. Overall/batch summary window toolbar (patches 02, 11, 14)
Order, left to right: (drag handle) · summarize (`text.quote`, only when there's no overall summary yet) · **home** (`house.fill`, "Back to overall summary", only when one exists) · separator · **retry** (`arrow.clockwise`) · **copy** (`doc.on.doc`) · separator · **"Ask"** (`questionmark.circle` + text) · **"Create"** menu (`wand.and.stars` + text) containing Whiteboard (`square.grid.3x3`), Infographic (`chart.bar.doc.horizontal`) and Podcast (`waveform.badge.mic`, iOS-only; include it on Mac only if batch podcast exists there) · separator · **web menu** (`quote.bubble`, only with web AI: "Generate Overall Summary with <provider>", "Send Whiteboard Prompt", "Send Infographic Prompt") · separator · **minimize** (`minus.circle.fill`) · **close** (`xmark.circle.fill`) at the far end. "Ask" and "Create" labels must never wrap (`.lineLimit(1).fixedSize()`). Every button gets an accessibility label and tooltip. Separator = 1×24 line at 24% primary, 4 pt horizontal padding.

---

## E. Feed cards, lists and titles (patch 02)

### E1. Unread dot and inline score
- New `UnreadDot` (8×8 accent circle, a11y "Unread"), shown at the start of the source row on **unread** article cards and Reddit post cards.
- Reddit post cards: the old vertical up/score/down column is replaced by an **inline score** (`arrow.up` + compact-formatted number such as "1.2K", semibold, grey, a11y "N points") in the metadata row, followed by "•".

### E2. Card density
- Article cards: excerpt `lineLimit(3)` (was 6); expanded-layout description `lineLimit(4)` (was 11); thumbnail max height 170 (was fixed 220) and **no fixed min height**, so cards without an image aren't padded out; border width 1 (was 1.1).
- Reddit post cards: preview text `lineLimit(4)` (was 10); expanded subscription layout 3 lines (was 5); thumbnail height 180, or 140 when the post has no preview text (`compactThumbnailHeight`), and no fixed min height; border width 1 in both light and dark.
- Softer card borders: the article card border colour is `Color.blue.opacity(0.35)` (was solid blue), and the Reddit card border gradient (`AppColors.redditCardBorder`) uses 40%-opacity colour stops.

### E3. HTML entities decoded in visible titles
`RedditCardPreview.decodeHTMLEntities` is now non-private and used for: subscription navigation titles, the article card source name, the sidebar row title (sidebar rows may use **2 lines**, `fixedSize(vertical)`), and the article header source name. So "&amp;" shows as "&" everywhere.

---

## F. Article header and reader page

### F1. One-line article metadata (patch 02)
Replace the three-panel metadata card (Source / Author / Published, with icons and dividers) with **one quiet line**: source (15 pt semibold, primary) · author · date (15 pt, secondary), separated by "·". If the feed has no author, or it's "Unknown", **omit it** (`knownArticleAuthor` returns nil) rather than showing "Unknown". On iPad the header has no panel background and small padding (6/6); keep the panel only on the phone layout, so on Mac use the iPad version.

### F2. Reader page font (patch 02)
Reader-mode HTML body uses the system font: `font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", Helvetica, Arial, sans-serif;`. The iOS file already changed **both** the iOS and the macOS `ReaderModeService` scripts; make sure the Mac project's reader CSS has it.

### F3. Toast / notification overlay placement (patch 02)
The bottom overlay (status/notification banner) is anchored **bottom-trailing**, width `maxWidth 520`, horizontal padding 24, so it sits inside the content column instead of straddling the sidebar.

### F4. Reader article uses the full width (iPad-only on iOS, patches 29, 30) — **DECISION**
- On iPad the reader's `.reader-shell` no longer caps at `max-width: 860px`. It's `max-width: none` with **32 px** side padding (iPhone keeps 860px/20px). iOS implements this with a `usesFullWidth` parameter on `ReaderModeService.toggleScript(...)` and cached full-width script variants.
- On iPad, **web articles run edge to edge inside the article card**: the extra 28 pt inner horizontal padding around the reader is 0 for normal web articles (`articlePrimaryHorizontalPadding(for:)`), while podcasts and YouTube keep their padding.
- **DECISION for Mac:** Mac windows can be very wide, so full width can give very long lines. Implement the full-width behaviour to match iPad, but tell the user in your report and offer a wide cap such as 1100–1200 px as an alternative.

---

## G. Scroll edges under glass toolbars

### G1. Soft top scroll edge on every feed list (patches 01, 22)
Every feed list uses `.scrollEdgeEffectStyle(.soft, for: .top)` (previously some hid it or used the default hard band): All, Today, Unread, Favorites, RSS subscription feeds and Reddit subscription lists. In iOS it's inside the shared `feedListColumnStyle(...)` modifier. On macOS 26+, apply the same if the API exists there; otherwise match the look with the Mac's toolbar/titlebar background.

### G2. Reddit post: content under the floating top toolbar is dimmed, not cut (patches 18, 19)
`OverlayBarScrollEdgeFade` masks the Reddit detail scroll content. Top band: a gradient from `black.opacity(0.18)` at 0, to `black.opacity(0.3)` at 0.75, to `black` at 1, so scrolled content stays faintly visible under the glass toolbar but doesn't clash with other glass pills. Bottom: a 40 pt fade to 15% under the floating bottom toolbar pill, plus `bottomToolbarClearance = 88` pt of padding below the last content. On Mac, apply this only if the Mac Reddit view has the same floating overlay toolbars.

### G3. Article summary clears the toolbar (patch 18)
On iPad the article's summary/Q&A section gets top clearance of **100** (104 when Ask is open), was 72, so the summary card never sits under the floating toolbar. Match it if the Mac article view has a floating toolbar.

### G4. Reddit floating scroll-to-top removed
The separate floating "scroll to top" button on the Reddit detail (iPad) was removed. Scroll to top lives in the bottom toolbar pill.

---

## H. Today view (patch 21)
The Today list's section titles ("Today's Topics Overview", "RSS Articles", "Reddit Posts") are **ordinary rows that scroll away** (`TodayListSectionTitle`: headline, secondary colour, top padding 6, clear background, no separator), no longer sticky headers with a tinted band and hairline. Convert `Section(header: Text("…"))` to `Section { TodayListSectionTitle("…"); …rows }`.

## I. Sidebar top spacing (patches 15–17)
Only the sidebar **background** extends under the status bar/toolbar (`.background { sidebarSurfaceBackground.ignoresSafeArea() }`); the list itself stays below the sidebar toggle, so sticky headers and the Subscriptions filter pin beneath it. The list's default top content margin is reduced (`.contentMargins(.top, 4, for: .scrollContent)`) and the first section header has **no extra top padding** (`showsDivider ? 10 : 0`). On Mac, check whether the sidebar has the same "header slides under the toggle" problem. Apply it if so; otherwise mark it not applicable.

## J. YouTube: tap a timestamp in the summary to seek the video (patch 02)
`YouTubeSeekRequest { id = UUID(); seconds }`. `YouTubePlayerView` takes an optional `seekRequest`. When a new request id arrives it runs `player.seekTo(seconds, true); player.playVideo();` in the player web view. The article detail keeps `@State youtubeSeekRequest`, and the summary's timestamp tap handler sets it for YouTube items (when YouTube support is on and there's a video ID). Port this to the Mac YouTube player view (NSViewRepresentable).

## K. Local text-to-speech (Kokoro) responsiveness (patch 05)
- **Short first chunk:** the first synthesized chunk is at most 240 characters, cut at the last sentence end (if at least 60 chars in) or otherwise the last space, so speech starts quickly without splitting a word.
- **Keep the model warm:** after playback finishes, `KokoroTTSService.scheduleIdleUnload()` frees the model only after **300 s** of idle. Starting a new read cancels the pending unload.
- iOS-only parts: unload on `UIApplication.didReceiveMemoryWarningNotification`, and wait while the app is in the background before GPU work. Mac has neither, so skip them or use the Mac equivalent if the project already has one.

---

## L. Reader mode: faster and cleaner (patches 31–34)
iOS reference: `ArticleReaderWebView` (UIViewRepresentable) and `ReaderModeService` in `ContentView.swift`, plus `ReaderDOMReadyMessageProxy`. Port to the Mac reader web view (NSViewRepresentable) and the Mac `ReaderModeService` script.

1. **Extract as soon as the HTML is parsed, instead of waiting for the full page load.** Add a `WKUserScript` at `.atDocumentEnd` (main frame only) that posts `location.href` to a script message handler named `rssumReaderDOMReady`. Register the handler through a small proxy object with a **weak** reference to the coordinator, so the user content controller doesn't retain it. On the message, if the reader isn't applied, isn't mid-evaluation, and isn't already loading a reader page, run extraction marked as an "early" attempt.
2. **Early attempt that finds nothing is not a failure:** clear the flag; if the page has already finished loading, run the normal attempt; otherwise wait for `didFinish`, which runs the normal path. `didFinish` does nothing while an evaluation is in flight.
3. **The Readability script returns the finished reader HTML string** instead of `document.open(); document.write(html); document.close(); return true`. The app then calls `webView.stopLoading()` and `webView.loadHTMLString(html, baseURL: articleURL)`, so the reader is a **fresh document**. None of the site's scripts survive: no cookie/consent banners, ads or anti-ad-block overlays can reach the reader. This was the fix for cookie banners and ads appearing after the speed-up. The page's `didFinish` for that load completes reader mode (`finishReaderModeSuccess`).
4. **Ignore the interrupted original load:** while an extraction is running, or once the reader is applied, `didFail` / `didFailProvisionalNavigation` from the original page are expected and must **not** fall back to RSS. Record the failure; if the early attempt then finds nothing, fall back.
5. **Cache extracted pages:** `NSCache<NSString, NSString>`, `countLimit = 40`, key = `"<url>|<compactTitle>|<fullWidth>"`. When opening an article with a cached page, load the cached HTML directly and finish on its `didFinish`. Reopening a recent article should then be instant.
6. **Keep the original site invisible while it loads:** the web view stays in the hierarchy (so it loads) but at alpha 0, and fades in (0.15 s) only when the reader page is ready. iOS: `conceal()` sets alpha 0, `reveal()` animates to 1.
7. **Loading placeholder:** replace the old placeholder, which showed the RSS version of the article and cross-faded into the reader (that caused a "doubled images" flash), with an empty panel that shows a small "Opening article…" spinner **only if loading takes longer than 0.35 s** (`DelayedReveal` in `AskAIUtilities.swift`).
- Done when: articles open noticeably faster; no cookie banner, ad or doubled-image flash appears; reopening an article is instant; sites that build their text with JavaScript still open (via the fallback) instead of dropping to RSS.

## M. Reddit comments: links shown once, cleanly (patch 35)
Model-level, platform-independent: port `RedditCommentModels.swift` changes **as is** if the Mac shares the same model.
- `unescapingRedditURLs(in:)`: inside URLs only, remove Reddit's backslash escapes (`nothing\_loads` becomes `nothing_loads`).
- `extractDisplayLinks`: link chips are built from the unescaped body. `[words](url)` gives a chip labelled with the words (empty label if the words are themselves a URL); every other URL gives a chip. URLs stop at whitespace, brackets, parentheses, `<>` and quotes, and never end in sentence punctuation. Chips are **de-duplicated** by lower-cased, percent-decoded URL without a trailing slash.
- `removingRawURLs(from:)` for the **comment text**: remove bare URLs and links whose text is a URL (including Reddit's nested `[url](url](url))` form), but **keep** `[words](url)` links so they render as tappable words. Tidy what's left: stray `)`/`]` after a space or dash, space before punctuation, a dangling dash at the end of a line, and empty `()`/`[]`.
- The old step that turned bare URLs into `[url](url)` markdown in the text is removed.
- Test with this comment. The text must end cleanly at "…a few days ago", with exactly one chip `https://www.reddit.com/r/AllDebrid/comments/1wl3rn9/nothing_loads/`:
  `…opened my own thread about it a few days ago - [https://www.reddit.com/r/AllDebrid/comments/1wl3rn9/nothing_loads/](https://www.reddit.com/r/AllDebrid/comments/1wl3rn9/nothing\_loads/](https://www.reddit.com/r/AllDebrid/comments/1wl3rn9/nothing_loads/))`
  Also: `Check [my guide](https://example.com/guide) and also https://foo.com/bar. Here's how:` must keep "my guide" as a link, give two chips, and keep "Here's how:".

## N. Article scroll-to-top button hides while scrolling (patch 36)
The floating scroll-to-top button in the article view (iOS: `scrollToTopOverlay`, iPad layout) **fades out** (opacity 0, scale 0.9, not hittable, 0.2 s ease) while the article is being scrolled, and fades back **0.5 s after scrolling stops**. iOS: `ArticleScrollActivity` (shared `ObservableObject` with `isScrolling`, `setScrolling(_:)` with the 0.5 s delayed reset, and `noteScroll()`), plus `HidesWhileArticleScrolls` wrapper, both in `AskAIUtilities.swift`. Scroll signals come from the SwiftUI article `ScrollView` via `.onScrollPhaseChange { phase != .idle }`, and from the reader web view's scroll delegate **only when `isDragging || isDecelerating`**, so programmatic scrolls don't blink it. On Mac, use the reader web view's scroll activity (for example `NSScrollView` live-scroll notifications), or the equivalent available.

---

## Not to port (listed so nothing is silently dropped)
- **iPhone-only layout changes**, patches **25, 26, 27**: wider phone summary cards, tighter phone Reddit margins and smaller avatars, the phone batch toolbar spreading icons evenly. All are guarded by an iPhone device check and don't affect iPad, so they don't apply to Mac. Patch 25 introduced helpers `isPhoneDevice` and `summaryCardTextInset` (14 on iPhone, **20 otherwise**). If code you port references them, on Mac use the non-phone values (inset 20, default paddings), or add the helpers returning `false` / 20.
- **Patch 28** only restores the iPad path to the system default padding after the iPhone change. It's a no-op for iPad/Mac.
- **Website and tutorial work** (`tutorial/` folder, the rssapp.top site, the promo film). Not app code.
- **Reverted experiments:** "Web AI buttons with provider name" (reverted, patch removed) and "fade comments header actions near the top toolbar" (reverted: it broke subscription taps, patch removed).
- **Deliberately left as they are** (user decision, don't change on Mac either): grouping the subscription list by source type (already exists), the few missing feed icons (e.g. iDownloadBlog), and the selected sidebar row's colour changing by source type (intentional).

## Final report (required)
When finished, reply with a table containing **every item above** (A1…N, plus each "not to port" entry) and its status: **Done**, **Adapted** (say how it differs on Mac), or **Not applicable** (say why). Then list the **DECISION** items for the user, confirm the macOS build succeeds, and list anything you could not verify by running the app.
