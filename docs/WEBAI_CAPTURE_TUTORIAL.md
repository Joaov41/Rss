# WebAI In-App Capture Tutorial

## Goal

This document explains how to implement a WebAI flow where:

1. Your app opens ChatGPT or Gemini inside an in-app web view.
2. The app injects a prompt automatically.
3. The app polls the page for the model response.
4. The captured response is written back into your app UI.
5. Auto-capture requests can start minimized so the site works under the hood until the user opens it.

This is the pattern now used in the root `RSSReaderApp/` source tree for:

- per-item article summaries
- per-item Reddit summaries
- per-item article Q&A
- per-item Reddit Q&A
- overall summary and overall Q&A

This guide is written so the same architecture can be copied into another app.

## High-Level Architecture

There are four pieces:

1. A request model that describes what to send and whether the app should auto-capture the answer.
2. A state controller that queues WebAI requests and routes the captured response back to the correct closure.
3. A web handoff view built on `WKWebView` that injects the prompt and extracts the answer.
4. feature-specific helpers that convert the captured text into app state updates.

In this project, those live in:

- [Models.swift](/Users/johnval/Downloads/ipad/RSSReaderApp/Models/Models.swift)
- [AppState.swift](/Users/johnval/Downloads/ipad/RSSReaderApp/Controllers/AppState.swift)
- [WebAIHandoffView.swift](/Users/johnval/Downloads/ipad/RSSReaderApp/Views/WebAIHandoffView.swift)

## Core Design Decision

The most important distinction is:

- `presentWebAIHandoff(...)`
  - opens the provider UI
  - does not auto-capture
  - good for manual browser-only workflows
- `performWebAIRequest(...)`
  - opens the provider UI
  - auto-sends the prompt
  - auto-captures the answer
  - returns the answer to app code

In other words, if you want the answer to appear in your app UI, you should route the feature through `performWebAIRequest(...)`, not through the manual handoff method.

## Step 1: Define a Request Model

Your web handoff layer needs a small request object that tells it:

- which provider to open
- the window title
- the prompt text
- whether the reply is plain text or strict JSON
- whether auto-capture should run
- whether the request should start minimized

In this app that is:

```swift
struct WebAIHandoffRequest: Identifiable, Equatable {
    let id = UUID()
    let provider: WebAIProvider
    let title: String
    let prompt: String
    let responseFormat: WebAIResponseFormat
    let shouldAutoCapture: Bool
    let shouldStartMinimized: Bool
}
```

The two behavior flags are:

- `shouldAutoCapture`
  - manual versus captured flow
- `shouldStartMinimized`
  - visible versus under-the-hood startup behavior

## Step 2: Add App-Level State For Pending Requests

You need app state that tracks:

- the currently presented web handoff request
- whether the handoff is minimized
- a lookup table of pending requests keyed by request ID

In this app:

- `activeWebAIHandoffRequest`
- `isWebAIHandoffMinimized`
- `pendingWebAIRequests`

Each pending request stores:

- title
- expected response format
- success callback
- failure callback

That lets the transport layer stay generic while each feature decides what to do with the captured text.

If you support hidden startup, the minimized state should be driven from the request itself, not from arbitrary UI timing.

## Step 3: Split Manual Handoff From Captured Handoff

### Manual flow

Use a helper like:

```swift
private func presentWebAIHandoff(prompt: String, title: String)
```

That helper should:

- trim the prompt
- reject empty prompts
- create a `WebAIHandoffRequest`
- set `shouldAutoCapture` to `false`
- set `shouldStartMinimized` to `false`

This is useful when you intentionally want the user to interact manually with the browser page.

### Captured flow

Use a helper like:

```swift
func performWebAIRequest(
    title: String,
    prompt: String,
    responseFormat: WebAIResponseFormat = .plainText,
    onSuccess: @escaping (String) -> Void,
    onFailure: @escaping (String) -> Void
)
```

Internally it should:

- call an enqueue function
- create a `WebAIHandoffRequest`
- set `shouldAutoCapture` to `true`
- usually set `shouldStartMinimized` to `true`
- store the completion closures in `pendingWebAIRequests`

When the WebView captures a reply, it sends the request ID back and the app resolves the matching callback.

## Step 3A: Run Auto-Capture Under The Hood

If you want the flow to feel silent without using APIs, do not remove the `WKWebView`. Keep it attached, but start it minimized.

That means:

- the provider site is still loaded
- JS injection still runs
- DOM polling still runs
- the user only sees a small status affordance unless they choose to open the panel

In this app, the request-level rule is:

- manual requests:
  - `shouldAutoCapture = false`
  - `shouldStartMinimized = true`
- captured requests:
  - `shouldAutoCapture = true`
  - `shouldStartMinimized = true`

Then the enqueue path initializes:

```swift
isWebAIHandoffMinimized = request.shouldStartMinimized
```

This is the practical “under the hood” version of a website-driven flow.

## Step 4: Build the WKWebView Handoff Layer

The handoff view should be a wrapper around `WKWebView`.

In this app that is `WebAIHandoffRepresentable` in [WebAIHandoffView.swift](/Users/johnval/Downloads/ipad/RSSReaderApp/Views/WebAIHandoffView.swift).

The sequence is:

1. load the provider URL
2. wait for navigation to finish
3. capture the current assistant text as a baseline
4. inject the prompt into the composer
5. try to click send or dispatch Enter
6. if auto-capture is enabled, poll the DOM for a response

If the request starts minimized, the same sequence still runs. The panel is just visually collapsed while it happens.

The baseline capture matters because provider pages often contain an old answer from a previous conversation. Without the baseline, your app may capture stale content instead of the new answer.

## Step 5: Inject The Prompt Reliably

The injection script should:

- find the input element
- support both `textarea` and `contenteditable`
- support provider-specific selectors
- dispatch proper input/change events
- find a send button if one exists
- fall back to synthetic Enter key events

This app does that in `buildInjectionScript()`.

The important implementation detail is not the exact selector list. The important part is the strategy:

1. detect the provider
2. search for multiple likely composer selectors
3. write the text using native setters/events
4. click send if possible
5. if not, simulate Enter
6. if the input cannot be found after several retries, copy the prompt to the clipboard and show a fallback message

That fallback is important because provider DOMs change over time.

For hidden startup, fallback handling is even more important because the user may otherwise have no clue why the app did not receive an answer.

## Step 6: Extract The Response Reliably

The extraction script should:

- look for likely assistant response containers
- normalize whitespace
- drop prompt echoes
- combine provider-specific selectors with generic selectors
- return the latest meaningful candidate

This app does that in `buildExtractionScript()`.

The polling loop then checks whether the extracted text is stable across multiple polls:

- plain text waits for 3 stable matches
- strict JSON waits for 2 stable matches

That stability check avoids capturing partial streaming output too early.

## Step 7: Route The Captured Reply Back Into App State

When polling succeeds, the WebView calls:

```swift
onResponseCaptured(extractedText)
```

The app state then resolves the request by ID in:

- `handleCapturedWebAIResponse(requestID:response:)`
- `handleWebAIRequestFailure(requestID:message:)`

That is the point where transport stops and feature logic begins.

The transport layer should not know what an article summary or a Q&A answer is. It should only know how to return text.

For hidden startup, failure handling should usually also unminimize the panel if the failed request is still active. That gives the user a recovery path for login prompts, send failures, DOM drift, or capture timeouts.

## Step 8: Write Feature-Specific Helpers

This is the part most teams skip, and it is why many apps end up with “WebAI opens a browser but does not update the UI”.

For every feature that wants in-app results, create a small explicit helper that:

1. builds the prompt
2. calls `performWebAIRequest(...)`
3. applies formatting/cleanup
4. writes the result into feature state

In this app, those explicit helpers are in [AppState.swift](/Users/johnval/Downloads/ipad/RSSReaderApp/Controllers/AppState.swift):

- `requestWebSummary(for article:)`
- `requestWebSummary(for post:comments:)`
- `askWebQuestionAboutArticle(article:question:completion:)`
- `askWebQuestionAboutRedditPost(post:comments:question:completion:)`

### Why explicit helpers matter

Do not point UI buttons directly at the raw browser handoff unless that button is meant to be manual-only.

Instead:

- `Summary` globe button -> call `requestWebSummary(...)`
- `Ask` globe button -> call `askWebQuestion...(...)`

Those helpers are where you:

- trim input
- enforce length limits
- clean markdown artifacts
- update the selected model object
- clear loading state on success or failure

The helper should not care whether the panel was visible or minimized. It should only request text and then update feature state.

## Step 9: Update The Correct Model Object

For summaries, the captured text should not just be displayed transiently. It should be written into the same state used by the rest of the UI.

In this app:

- article summary updates go through `updateArticleSummaryFromCloud(...)`
- Reddit summary updates go through `updateRedditPostSummaryFromCloud(...)`

Even though the name says “FromCloud”, these functions are really “write a summary into the selected item and refresh the arrays”.

That reuse is good. It prevents duplicated update logic.

## Step 10: Reuse Existing UI State For Q&A

For Q&A, do not create a second answer UI just because the transport is WebAI.

The better pattern is:

- primary Ask button uses the app’s currently selected provider
- WebAI globe button forces WebAI
- both write into the same answer area

That is the pattern now used in:

- [ContentView.swift](/Users/johnval/Downloads/ipad/RSSReaderApp/Views/ContentView.swift)
- [RedditDetailView.swift](/Users/johnval/Downloads/ipad/RSSReaderApp/Views/RedditDetailView.swift)

The result is simpler:

- one question field
- one loading state
- one answer display
- two ways to choose the backend

## Implementation Template For Another App

If you want to recreate this in another app, the minimal stack is:

### 1. Models

Create:

- `WebAIProvider`
- `WebAIResponseFormat`
- `WebAIHandoffRequest`

### 2. App coordinator/state

Create:

- `activeWebAIHandoffRequest`
- `pendingWebAIRequests`
- `performWebAIRequest(...)`
- `handleCapturedWebAIResponse(...)`
- `handleWebAIRequestFailure(...)`

### 3. WebView presenter

Create:

- a `WKWebView` wrapper
- DOM injection script
- DOM extraction script
- polling logic

### 4. Feature adapters

For each feature, create one explicit adapter:

- `requestWebSummary(...)`
- `askWebQuestion(...)`
- `requestWebStructuredOutput(...)`

Do not let views build transport details themselves.

## Suggested Pseudocode

```swift
func requestWebSummary(for item: Item) {
    isLoading = true

    performWebAIRequest(
        title: "Item Summary",
        prompt: makeSummaryPrompt(for: item),
        onSuccess: { [weak self] text in
            guard let self else { return }
            let cleaned = self.cleanSummary(text)
            self.updateItem(item, summary: cleaned)
            self.isLoading = false
        },
        onFailure: { [weak self] error in
            self?.showError(error)
            self?.isLoading = false
        }
    )
}
```

For Q&A:

```swift
func askWebQuestion(about item: Item, question: String, completion: @escaping (String) -> Void) {
    let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
        completion("Please enter a question first.")
        return
    }

    performWebAIRequest(
        title: "Item Q&A",
        prompt: makeQuestionPrompt(item: item, question: trimmed),
        onSuccess: { answer in
            completion(cleanQA(answer))
        },
        onFailure: { error in
            completion(cleanQA(error))
        }
    )
}
```

## Common Failure Modes

### 1. The browser opens but the app UI never updates

Cause:

- the button is still calling manual handoff instead of captured handoff

Fix:

- route the button through `performWebAIRequest(...)` via a feature helper

### 2. The app captures an old conversation reply

Cause:

- no baseline assistant text snapshot

Fix:

- capture the current assistant text before prompt injection
- ignore identical baseline text during polling

### 3. The app captures a partial response

Cause:

- first non-empty extraction is accepted immediately

Fix:

- require the extracted text to remain stable for multiple polling cycles

### 4. The provider composer cannot be found

Cause:

- DOM selector drift

Fix:

- retry several times
- keep multiple selectors
- fall back to copying the prompt to the clipboard

If you are using minimized startup, also auto-expand the panel on failure so the user can intervene manually.

### 5. The wrong item gets updated

Cause:

- view selection changed while the request was in flight

Fix:

- update by stable item identity
- guard against stale selection before writing inline Q&A state

### 6. Hidden mode appears to do nothing

Cause:

- the request is minimized but there is no visible status affordance

Fix:

- show a small tappable indicator
- use wording like `ChatGPT working · Tap to open`
- show a spinner for auto-capture requests
- keep full panel restore available

## Adaptation Checklist For Another App

- Decide which WebAI actions are manual-only and which must update the app UI.
- Ensure all in-app-update actions use `performWebAIRequest(...)`.
- Keep transport generic and feature updates specific.
- Reuse the same display state for local/cloud/WebAI answers.
- Add DOM baseline capture before polling.
- Add stability checks before accepting a response.
- Add timeout and manual fallback messaging.
- Keep provider-specific selectors isolated to one place.
- Make summary and Q&A cleanup functions separate.
- If using hidden startup, keep the web view alive but minimized rather than detached.
- Auto-expand on failure so the user can recover.

## What Changed In This App

The reusable lesson from this app is simple:

- the capture infrastructure already existed
- the missing piece was UI wiring

The per-item globe buttons were using manual handoff methods:

- `openWebSummary(...)`
- `openWebArticleQuestion(...)`
- `openWebRedditQuestion(...)`

Those methods intentionally opened the provider page without auto-capture.

The fix was to point those buttons at explicit capture helpers instead:

- `requestWebSummary(...)`
- `askWebQuestionAboutArticle(...)`
- `askWebQuestionAboutRedditPost(...)`

That made the per-item behavior match the overall summary behavior.

The next improvement was to start auto-capture requests minimized by default, so the provider site still runs in `WKWebView` but only expands if the user taps the status indicator or a failure requires intervention.

## Final Recommendation

If you implement this in another app, keep this rule:

> Browser presentation is not the feature. Returning captured text into app state is the feature.

Design the code so your UI never talks directly to the browser layer unless the action is intentionally manual.
