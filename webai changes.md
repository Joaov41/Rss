# Working Procedure
## Problem Being Solved
The working implementation makes `Web AI` a real summary provider for both per-item summaries and global summary overviews, instead of using the existing provider for the first pass and only opening the web model later for optional follow-up questions.

In the final working state, when `selectedSummaryProvider == .webAI`, the app:
1. Generates each article or Reddit summary through the in-app Web AI browser.
2. Captures each reply back into app state.
3. Builds the existing global summary JSON locally from those captured per-item summaries.
4. Keeps the global summary UI usable while the browser handoff is minimized.

## Final Working Solution Overview
The successful pattern is not "replace the whole summary UI with raw Web AI output." The app keeps the existing summary/result pipeline and swaps only the generation backend for the Web AI path.

The final data flow is:
`SettingsView` selects `.webAI` and a `WebAIProvider` -> `AppState.requestSummary(...)` or `AppState.summarize*Globally(...)` routes into `performWebAIRequest` / `performWebAIRequestAsync` -> `enqueueWebAIRequest(...)` creates a `WebAIHandoffRequest` -> `WebAIHandoffView` opens ChatGPT or Gemini inside a `WKWebView`, injects the prompt, and auto-captures the reply -> `AppState.handleCapturedWebAIResponse(...)` calls the pending success closure -> the existing article/post/global summary state is updated.

For overall summary, the working path is itemized and sequential:
1. Summarize each article/post through Web AI.
2. Store each short summary in the existing `GlobalSummaryItem` array.
3. Encode the normal `GlobalSummaryResult` JSON.
4. Show that JSON in the existing global summary UI.

That is why the UI still shows one short summary per article or post first, and why the optional "overall/combined" summary can still be triggered later without changing the rest of the app.

## Exact Implementation Steps
1. Add a persisted Web AI destination and a dedicated summary provider.
Repo-specific implementation:
`/Users/johnval/Downloads/ipad/RSSReaderApp/Models/Models.swift` adds `AppSettings.selectedWebAIProvider`, `AppSettings.SummaryProvider.webAI`, `WebAIProvider`, `WebAIResponseFormat`, and `WebAIHandoffRequest`.
Equivalent in another codebase:
Find the persisted app settings model and the enum that decides which summary backend is active. Add one backend selector for "Web AI" and one provider selector for the actual browser destination such as ChatGPT vs Gemini.

2. Add UI settings that let the user choose both the summary backend and the browser destination.
Repo-specific implementation:
`/Users/johnval/Downloads/ipad/RSSReaderApp/Views/SettingsView.swift`, `/Users/johnval/Downloads/ipad/iphone/RSSReaderApp/Views/SettingsView.swift`, and `/Users/johnval/Downloads/ipad/mac/RSSReaderApp/Views/SettingsView.swift` all bind a segmented picker to `appState.settings.selectedWebAIProvider`.
Equivalent in another codebase:
Find the settings screen where users already pick the summary model. Add a second control for the browser destination and persist it through the same settings update path.

3. Introduce an explicit handoff queue in app state instead of letting views talk directly to WebKit.
Repo-specific implementation:
`/Users/johnval/Downloads/ipad/RSSReaderApp/Controllers/AppState.swift` defines `activeWebAIHandoffRequest`, `isWebAIHandoffMinimized`, `isWebAIBatchHandoffInProgress`, `PendingWebAIRequest`, and `pendingWebAIRequests`.
The same pattern exists in `/Users/johnval/Downloads/ipad/iphone/RSSReaderApp/Controllers/AppState.swift` and `/Users/johnval/Downloads/ipad/mac/RSSReaderApp/Controllers/AppState.swift`.
Equivalent in another codebase:
Find the central state object that already owns summary requests and summary results. Add one active browser request, one minimized flag, one "batch is running" flag, and a lookup table from request ID to success/failure callbacks.

4. Centralize the Web AI request lifecycle in `AppState`.
Repo-specific implementation:
The working symbols are `presentWebAIHandoff(...)`, `enqueueWebAIRequest(...)`, `handleCapturedWebAIResponse(...)`, `handleWebAIRequestFailure(...)`, `dismissActiveWebAIHandoff(...)`, `performWebAIRequest(...)`, `performWebAIRequestAsync(...)`, `minimizeActiveWebAIHandoff()`, and `restoreMinimizedWebAIHandoff()` in each `AppState.swift`.
The key working detail is in `enqueueWebAIRequest(...)`: it only forces `isWebAIHandoffMinimized = false` when there is no active request and no batch in progress. That prevents the handoff panel from reappearing for every next item in a batch.
Equivalent in another codebase:
Do not spread this logic across views. Put prompt enqueueing, response capture, cancellation, and minimize/restore state in one coordinator object that already owns the rest of the summary flow.

5. Route per-item summaries through Web AI when `.webAI` is selected.
Repo-specific implementation:
`requestSummary(for:redditPost:redditComments:)` in each `AppState.swift` checks `settings.selectedSummaryProvider == .webAI` and uses `performWebAIRequest(...)` with `articleSummaryPrompt(for:)` or `redditPostSummaryPrompt(post:comments:)`.
The captured reply is then applied through existing update methods such as `updateArticleSummaryFromCloud(...)` and `updateRedditPostSummaryFromCloud(...)`.
Equivalent in another codebase:
Find the single entry point that currently chooses between Gemini, local, cloud, or other summary providers. Add one new branch that sends the same prepared prompt to the browser handoff layer and then reuses the same "apply summary to model/UI" functions already used by cloud results.

6. Keep overall summary generation local, but feed it with Web AI per-item results.
Repo-specific implementation:
`summarizeAllArticlesGlobally()`, `summarizeAllRedditGlobally(...)`, `summarizeFeedArticlesGlobally(...)`, and `summarizeSubredditPostsGloballyInternal(...)` all short-circuit to `summarizeArticlesGloballyWithWebAI(...)` or `summarizeRedditPostsGloballyWithWebAI(...)` when `.webAI` is selected.
Those functions loop sequentially, call `performWebAIRequestAsync(...)` for each item, create `GlobalSummaryItem` values, and finally pass a `GlobalSummaryResult` into `processGlobalSummaryResult(...)` or `handleSummaryResult(...)`.
Equivalent in another codebase:
Do not ask Web AI for the whole global summary first if the feature requirement is "show one short summary per item first." Keep the existing aggregate result shape and populate it from itemized Web AI calls.

7. Preserve the combined overview as a separate later action.
Repo-specific implementation:
`openWebCombinedGlobalSummary()` builds a second prompt from the already-generated `GlobalSummaryResult` using `combinedGlobalSummaryPrompt(for:)` in the main app and `buildAggregatePrompt(from:)` in the mac variant.
Equivalent in another codebase:
If your product already has an "overall summary" or "ask follow-up" action, leave that as a second-stage action driven from the stored per-item results. Do not merge it into the first pass.

8. Make minimize/restore work for slow sequential Web AI batches.
Repo-specific implementation:
`/Users/johnval/Downloads/ipad/RSSReaderApp/Views/WebAIHandoffView.swift` and the iPhone/mac copies present a floating panel driven by `activeWebAIHandoffRequest`, hide it with `opacity` plus `allowsHitTesting(!isWebAIHandoffMinimized)`, and show a restore capsule when minimized.
The minimize and close buttons use larger `56x56` tap frames in the final working code.
Equivalent in another codebase:
If your browser handoff lives in an overlay or sheet, the minimize state must hide the active browser surface without cancelling the pending request, and the restore affordance must be outside the hidden surface.

9. Hide the app’s own progress overlays while the browser handoff is minimized.
Repo-specific implementation:
`/Users/johnval/Downloads/ipad/RSSReaderApp/Views/ContentView.swift`, `/Users/johnval/Downloads/ipad/iphone/RSSReaderApp/Views/ContentView.swift`, and `/Users/johnval/Downloads/ipad/mac/RSSReaderApp/Views/ContentView.swift` compute:
`(appState.isLoading || appState.isWebAIBatchHandoffInProgress) && appState.isWebAIHandoffMinimized`
and use that to suppress both the draggable global summary view and the "summarizing..." progress overlay while the Web AI panel is minimized.
Equivalent in another codebase:
Find every modal/overlay/progress view that would otherwise re-cover the screen during a slow batch. Gate those views off the same minimized-plus-batch condition.

10. Let the browser layer inject prompts and auto-capture replies, but keep business logic above it.
Repo-specific implementation:
`WebAIHandoffRepresentable` in each `WebAIHandoffView.swift` loads `request.provider.url`, injects `request.prompt`, optionally starts `pollForResponse(...)`, and calls `onResponseCaptured(...)` or `onCaptureFailed(...)`.
The response stability gate uses `requiredStableCount = 2` for `strictJSON` and `3` for `plainText`.
Equivalent in another codebase:
The WebKit/browser component should know how to open the site, paste/send text, and detect finished output. It should not know how article summaries, Reddit summaries, or global summary JSON are stored.

## How to Adapt This to a Similar Codebase
Start from the object that already owns summary generation and summary display state. Add the Web AI browser as another backend under that object, not as a separate feature branch.

Reuse the prompts and result-application code you already have. The reusable pattern is:
1. Keep the existing result models and UI.
2. Replace only the generation step with a queued browser handoff.
3. For global summary, run item-by-item first and assemble the normal aggregate result locally.
4. Track batch progress separately from the active browser request.
5. Use one minimized flag across both the browser overlay and any app-owned loading overlays.

If your codebase has multiple platform folders or target-specific copies, apply the same state machine in each target copy. In this repo the same pattern exists in:
`/Users/johnval/Downloads/ipad/RSSReaderApp`
`/Users/johnval/Downloads/ipad/iphone/RSSReaderApp`
`/Users/johnval/Downloads/ipad/mac/RSSReaderApp`

## Validation and Verification
Verified directly against the final code:
`selectedSummaryProvider == .webAI` routes per-item summaries into `performWebAIRequest(...)`.
Global summary entry points route into `summarizeArticlesGloballyWithWebAI(...)` or `summarizeRedditPostsGloballyWithWebAI(...)`.
The final overall summary JSON is still produced by the app through `GlobalSummaryResult`, not pasted raw from the browser.
The minimized-state fix is present in both `enqueueWebAIRequest(...)` and the `ContentView` overlay guards, which is the key working behavior that prevents the Web UI and the app overlays from popping back up on every item.

Existing build artifacts in the repository show the relevant files were compiled in prior runs, including `WebAIHandoffView` and summary services under `build/DerivedData/.../RSSReaderApp (iOS).build/Objects-normal/...`.

No dedicated app-level automated tests for this feature were found in this repository snapshot. I did not rerun a fresh build in this pass because the instruction for this step was to write the Markdown file only.

## Assumptions and Repo-Specific Notes
Assumption:
The root iOS folder at `/Users/johnval/Downloads/ipad/RSSReaderApp` is the main source of truth, and the `iphone/` and `mac/` folders are maintained parity copies. That assumption is supported by the matching symbols and matching minimize/batch logic across all three targets.

Repo-specific note:
The main app uses `GlobalSummaryService.setWebRequestHandler(...)` in `/Users/johnval/Downloads/ipad/RSSReaderApp/Controllers/AppState.swift` so the service layer can delegate Web AI requests back into `AppState`. The mac variant keeps more of the global summary flow directly in `mac/RSSReaderApp/Controllers/AppState.swift`.

Repo-specific note:
The final working implementation does not remove or replace the existing combined-summary prompt functions. It adds an itemized Web AI first pass and leaves the later combined overview as a separate user action.

Repo-specific note:
Some wording differs slightly between the root, `iphone/`, and `mac/` `SettingsView` copies, but the working architecture is the same: persisted Web AI destination selection plus `.webAI` as a summary provider.
