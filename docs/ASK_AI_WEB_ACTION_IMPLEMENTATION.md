# Ask AI Web Action Implementation

This document describes the pattern used to add the `Ask AI Web` long-press action alongside the existing `Ask AI` action.

It focuses only on the web action: how to expose a second selection menu command, keep the selection extraction shared, and route the new action into the existing web model path.

## Goal

The app already had selectable summary text with an `Ask AI` long-press action. The new requirement was to add another action:

- `Ask AI`: use the normal selected AI provider path.
- `Ask AI Web`: use the web-summary model path, meaning the same ChatGPT/Gemini web provider selection already used elsewhere for web summaries.

The important design choice was to parameterize the existing selection flow instead of copying it.

## 1. Add An Action Enum

The selection UI needs to tell callers which menu action the user picked. Use a tiny enum instead of separate duplicated selection handlers.

File: `RSSReaderApp/Views/AskAIUtilities.swift`

```swift
enum AskAISelectionAction {
    case standard
    case web
}
```

This keeps the low-level text selection code independent from model routing. It only says what the user chose.

## 2. Extend SelectableText With A Web Callback

`SelectableText` previously exposed one callback for `Ask AI`. It now accepts two callbacks:

```swift
struct SelectableText: UIViewRepresentable {
    let text: String
    var onAskAI: ((String, String) -> Void)? = nil
    var onAskAIWeb: ((String, String) -> Void)? = nil
    var textIsPrecleaned: Bool = false

    private var selectionHandler: ((AskAISelectionAction, String, String) -> Void)? {
        guard onAskAI != nil || onAskAIWeb != nil else { return nil }
        return { action, selectedText, context in
            switch action {
            case .standard:
                onAskAI?(selectedText, context)
            case .web:
                onAskAIWeb?(selectedText, context)
            }
        }
    }
}
```

The caller still works with simple `(selectedText, context)` closures. The wrapper maps `.standard` and `.web` to the right closure.

## 3. Add A Second Menu Item

The menu installation keeps both actions together.

```swift
private func installAskAIMenuItem() {
    guard !Self.didInstallAskAIMenuItem else { return }

    let standardSelector = #selector(handleAskAIAction(_:))
    let webSelector = #selector(handleAskAIWebAction(_:))

    var menuItems = UIMenuController.shared.menuItems ?? []

    if !menuItems.contains(where: { $0.action == standardSelector }) {
        menuItems.append(UIMenuItem(title: "Ask AI", action: standardSelector))
    }

    if !menuItems.contains(where: { $0.action == webSelector }) {
        menuItems.append(UIMenuItem(title: "Ask AI Web", action: webSelector))
    }

    UIMenuController.shared.menuItems = menuItems
    Self.didInstallAskAIMenuItem = true
}
```

Each selector calls the same extraction function with a different action:

```swift
@objc private func handleAskAIAction(_ sender: Any?) {
    handleAskAISelection(action: .standard)
}

@objc private func handleAskAIWebAction(_ sender: Any?) {
    handleAskAISelection(action: .web)
}
```

## 4. Reuse Selection Extraction

Do not duplicate the selection parsing. The same code should extract selected text and context, then pass the action through.

```swift
private func handleAskAISelection(action: AskAISelectionAction) {
    let range = selectedRange
    guard range.location != NSNotFound, range.length > 0 else { return }

    let nsText = text as NSString
    guard NSMaxRange(range) <= nsText.length else { return }

    let selected = nsText
        .substring(with: range)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !selected.isEmpty else { return }

    let window = 320
    let start = max(0, range.location - window)
    let end = min(nsText.length, NSMaxRange(range) + window)
    let contextRange = NSRange(location: start, length: max(0, end - start))
    let context = nsText.substring(with: contextRange)

    onAskAISelection?(action, selected, context)
}
```

The web view variant follows the same pattern: JavaScript extracts `{ selected, context }`, then the callback receives `.standard` or `.web`.

## 5. Add A Web Entry Point In AppState

The view should not know which web provider is selected. It should call one AppState method that already knows how to use the selected ChatGPT/Gemini web provider.

File: `RSSReaderApp/Controllers/AppState.swift`

```swift
func askWebQuestionAboutSelection(
    prompt: String,
    title: String = "Ask AI Web",
    completion: @escaping (String) -> Void
) {
    let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
        completion("Select some text first.")
        return
    }

    performExplicitWebAIQuestion(
        title: title,
        prompt: trimmed,
        completion: completion
    )
}
```

The key is `performExplicitWebAIQuestion(...)`. That function already uses the app's selected web AI provider, so `Ask AI Web` automatically follows the existing web model settings.

## 6. Route View Actions Into The Web Path

Each screen uses the same local handler shape:

```swift
private func handleAskAIWebSelection(selectedText: String, context: String) {
    runSelectionAskAI(selectedText: selectedText, context: context, useWebPath: true)
}
```

Then the shared runner chooses between normal Ask AI and web Ask AI:

```swift
private func runSelectionAskAI(
    selectedText: String,
    context: String,
    useWebPath: Bool
) {
    guard !isAskingSelectionAI else { return }

    let prompt = buildAskAISelectionPrompt(
        selectedText: selectedText,
        extractedContext: context
    )
    guard !prompt.isEmpty else { return }

    selectionAskAIPrompt = prompt
    selectionAskAIResponse = ""
    isAskingSelectionAI = true

    let finish: (String) -> Void = { answer in
        DispatchQueue.main.async {
            self.selectionAskAIResponse = cleanMarkdownArtifactsForDisplay(answer)
            self.isAskingSelectionAI = false
            self.showSelectionAskAISheet = true
        }
    }

    if useWebPath {
        appState.askWebQuestionAboutSelection(prompt: prompt, completion: finish)
    } else {
        appState.askQuestionAboutSelection(prompt: prompt, completion: finish)
    }
}
```

This avoids separate prompt building, response cleanup, sheet state, and loading state for web.

## 7. Wire The Web Callback Into Summary Text

Wherever summary or answer text is selectable, pass both actions:

```swift
SelectableText(
    text: qaState.answerText,
    onAskAI: handleAskAISelection(selectedText:context:),
    onAskAIWeb: handleAskAIWebSelection(selectedText:context:),
    textIsPrecleaned: true
)
```

For custom summary components, add an optional web callback and forward it:

```swift
struct ArticleGlassySummary: View {
    var onAskAISelection: ((String, String) -> Void)? = nil
    var onAskAIWebSelection: ((String, String) -> Void)? = nil

    var body: some View {
        ArticleGlassySummaryContent(
            summary: summary,
            onAskAISelection: onAskAISelection,
            onAskAIWebSelection: onAskAIWebSelection
        )
    }
}
```

Then inside the component:

```swift
if onAskAISelection != nil || onAskAIWebSelection != nil {
    SelectableText(
        text: displaySummary,
        onAskAI: onAskAISelection,
        onAskAIWeb: onAskAIWebSelection,
        textIsPrecleaned: true
    )
} else {
    Text(displaySummary)
}
```

That keeps old call sites working. If a caller does not provide either closure, the component falls back to plain `Text`.

## 8. Checklist For Porting This Elsewhere

Use this sequence when adding the same feature to another codebase:

1. Add an action enum, for example `.standard` and `.web`.
2. Change the selectable text callback from one action to a parameterized action callback.
3. Add a second menu item titled `Ask AI Web`.
4. Make both menu selectors call the same selection extraction function.
5. Add one app-level method for the web path.
6. Have that method call the existing web provider selection logic.
7. In each view, share prompt building and response UI between normal Ask AI and Ask AI Web.
8. Wire `onAskAIWeb` into every selectable summary/answer surface.
9. Add tests that prove the web action uses the web provider path and appears anywhere the normal Ask AI action appears.

## Common Mistakes

- Do not make `Ask AI Web` call the Gemini service directly.
- Do not duplicate prompt construction for web unless the prompt genuinely needs to differ.
- Do not put provider selection in the view layer.
- Do not add a button label without changing the underlying model path.
- Do not forget answer/Q&A surfaces; the same selectable text component should be used there too.

