# WebAI Root App Change Log

This file tracks the WebAI-related changes applied to the root source tree under `RSSReaderApp/`.

The intent is to make later porting into the `iphone/` and `mac/` folders mechanical instead of investigative.

## Scope

These changes were applied only to the root app sources:

- [AppState.swift](/Users/johnval/Downloads/ipad/RSSReaderApp/Controllers/AppState.swift)
- [ContentView.swift](/Users/johnval/Downloads/ipad/RSSReaderApp/Views/ContentView.swift)
- [RedditDetailView.swift](/Users/johnval/Downloads/ipad/RSSReaderApp/Views/RedditDetailView.swift)
- [SummaryColumnView.swift](/Users/johnval/Downloads/ipad/RSSReaderApp/Views/SummaryColumnView.swift)
- [WebAIHandoffView.swift](/Users/johnval/Downloads/ipad/RSSReaderApp/Views/WebAIHandoffView.swift)
- [Models.swift](/Users/johnval/Downloads/ipad/RSSReaderApp/Models/Models.swift)

## Change Set 1: Per-Item WebAI Replies Now Write Back Into App UI

### Problem

Overall summary WebAI requests already captured the model reply and wrote it back into SwiftUI state, but per-item article/Reddit summary globe buttons still used manual browser handoff only.

### Root cause

The per-item globe buttons were routed through:

- `openWebSummary(for:)`
- `openWebArticleQuestion(...)`
- `openWebRedditQuestion(...)`

Those helpers call `presentWebAIHandoff(...)`, which intentionally creates requests with:

- `shouldAutoCapture = false`

That means the browser opened, but the answer was not returned to the app.

### Fix

Added explicit captured WebAI feature helpers in [AppState.swift](/Users/johnval/Downloads/ipad/RSSReaderApp/Controllers/AppState.swift):

- `requestWebSummary(for article:)`
- `requestWebSummary(for post:comments:)`
- `askWebQuestionAboutArticle(article:question:completion:)`
- `askWebQuestionAboutRedditPost(post:comments:question:completion:)`
- internal helper `performExplicitWebAIQuestion(...)`

These helpers all route through:

- `performWebAIRequest(...)`

### UI rewiring

Changed per-item summary and Q&A globe buttons to call the explicit capture helpers instead of manual handoff.

#### Article

- article summary globe buttons in [ContentView.swift](/Users/johnval/Downloads/ipad/RSSReaderApp/Views/ContentView.swift)
- article summary globe button in [SummaryColumnView.swift](/Users/johnval/Downloads/ipad/RSSReaderApp/Views/SummaryColumnView.swift)
- article Q&A globe button in [ContentView.swift](/Users/johnval/Downloads/ipad/RSSReaderApp/Views/ContentView.swift)

#### Reddit

- Reddit summary globe buttons in [RedditDetailView.swift](/Users/johnval/Downloads/ipad/RSSReaderApp/Views/RedditDetailView.swift)
- Reddit Q&A globe button in [RedditDetailView.swift](/Users/johnval/Downloads/ipad/RSSReaderApp/Views/RedditDetailView.swift)

### Result

- Per-item summary globe buttons now capture replies and populate the existing summary UI.
- Per-item Q&A globe buttons now capture replies and populate the existing inline answer UI.
- Manual handoff methods still exist in `AppState` for future use, but those per-item controls no longer use them.

## Change Set 2: Hidden-By-Default Auto-Capture WebAI

### Problem

Even after capture-mode wiring, ChatGPT/Gemini still opened visibly every time.

### Requested behavior

Auto-capture requests should run under the hood by default, with only a small indicator visible. The user can tap that indicator to open the full web panel if needed.

### Fix

Extended [WebAIHandoffRequest](/Users/johnval/Downloads/ipad/RSSReaderApp/Models/Models.swift) with:

- `shouldStartMinimized: Bool`

Then updated request creation in [AppState.swift](/Users/johnval/Downloads/ipad/RSSReaderApp/Controllers/AppState.swift):

- manual handoff requests:
  - `shouldAutoCapture = false`
  - `shouldStartMinimized = true`
- captured requests:
  - `shouldAutoCapture = true`
  - `shouldStartMinimized = true`

Updated enqueue logic so new auto-capture requests start with:

- `isWebAIHandoffMinimized = true`

### Failure recovery

Updated `handleWebAIRequestFailure(...)` so if the active request fails while minimized, it is automatically unminimized. This gives the user a recovery path when:

- DOM selectors drift
- login is required
- send/capture fails

### Indicator UI

Updated the minimized restore buttons in [WebAIHandoffView.swift](/Users/johnval/Downloads/ipad/RSSReaderApp/Views/WebAIHandoffView.swift):

- auto-capture requests show a `ProgressView`
- text now reads like a status indicator:
  - `ChatGPT working · Tap to open`
  - `Gemini working · Tap to open`
- manual requests also start minimized and show readiness wording:
  - `ChatGPT ready · Tap to open`
  - `Gemini ready · Tap to open`

### Result

- Auto-capture requests now begin minimized by default.
- Manual WebAI handoff requests now also begin minimized by default.
- The site still runs inside `WKWebView`, but it is not expanded unless the user opens it or a failure occurs.

## Change Set 3: Hide Explicit WebAI Duplicates When WebAI Is Already Selected

### Problem

The explicit WebAI globe buttons were intentionally kept visible when another summary provider was selected, so users could still use WebAI as an alternate path.

Once `selectedSummaryProvider` was already set to `webAI`, those same explicit controls became redundant because the primary summarize/ask actions were already using WebAI.

### Fix

Added a view-level gate in the root UI files:

- [ContentView.swift](/Users/johnval/Downloads/ipad/RSSReaderApp/Views/ContentView.swift)
- [RedditDetailView.swift](/Users/johnval/Downloads/ipad/RSSReaderApp/Views/RedditDetailView.swift)
- [SummaryColumnView.swift](/Users/johnval/Downloads/ipad/RSSReaderApp/Views/SummaryColumnView.swift)

Each view now computes:

- `shouldShowExplicitWebAIControls = appState.settings.selectedSummaryProvider != .webAI`

That condition hides only the duplicate WebAI-specific buttons and menus. It does not change the normal summarize/ask actions.

### Result

- When provider is not `webAI`, explicit WebAI controls stay visible as alternate actions.
- When provider is `webAI`, those duplicate WebAI controls are hidden.
- Primary summarize/ask behavior is unchanged.

## Transport And Architecture Notes

The reusable architectural rule is:

- manual browser flow -> `presentWebAIHandoff(...)`
- in-app result flow -> `performWebAIRequest(...)`

If porting to `iphone/` and `mac/`, preserve that split. Do not point result-producing UI directly at the manual handoff helpers.

## Porting Checklist For `iphone/` And `mac/`

When asked to port these changes, copy this exact sequence:

1. Add `shouldStartMinimized` to `WebAIHandoffRequest`.
2. Update manual request creation to set `shouldStartMinimized = true`.
3. Update captured request creation to set `shouldStartMinimized = true`.
4. Update enqueue logic to honor `request.shouldStartMinimized`.
5. Update failure handling to unminimize the active request on capture failure.
6. Add explicit captured feature helpers in AppState:
   - `requestWebSummary(for article:)`
   - `requestWebSummary(for post:comments:)`
   - `askWebQuestionAboutArticle(...)`
   - `askWebQuestionAboutRedditPost(...)`
7. Rewire article/Reddit summary globe buttons from `openWebSummary(...)` to `requestWebSummary(...)`.
8. Rewire article/Reddit Q&A globe buttons from `openWeb...Question(...)` to the new explicit WebAI Q&A helpers.
9. Update minimized indicator UI in `WebAIHandoffView` to show background-work wording and spinner for auto-capture requests.
10. Hide duplicate explicit WebAI controls whenever `selectedSummaryProvider == .webAI`.
11. Rebuild and manually verify:
   - article summary
   - Reddit summary
   - article Q&A
   - Reddit Q&A
   - failure auto-expand behavior

## Related Docs

- [WEBAI_CAPTURE_TUTORIAL.md](/Users/johnval/Downloads/ipad/docs/WEBAI_CAPTURE_TUTORIAL.md)

## Mac Port Follow-Ups

After the initial `mac/` port, a few WebAI parity gaps were fixed in the mac target:

- regular article/Reddit `Ask` actions now route through WebAI when `selectedSummaryProvider == .webAI`
- Reddit `Comment Summary` and `Deep Analysis` now route through WebAI when `selectedSummaryProvider == .webAI`
- combined/overall article summaries now force minimized WebAI startup before the aggregate request begins, so the ChatGPT/Gemini panel stays hidden like the other WebAI flows

If these changes ever need to be re-applied to another target, verify the normal provider-selected actions, not just the explicit globe buttons.
