# Global Summary Overlay Enhancements

This document walks through the two UX additions in `DraggableGlobalSummaryView`:

1. The clipboard shortcut (`C`)
2. The mini question-and-answer console (`?`) with the new full-size answer sheet

All code snippets reference `RSSReaderApp/Views/ContentView.swift` unless noted otherwise.

---

## 1. Clipboard Button

### UI Hook

```swift
Button {
    copySummaryToClipboard()
} label: {
    Text("C")
        .font(.system(size: 12, weight: .bold))
        .foregroundColor(.primary)
        .frame(width: 22, height: 22)
        .background(Circle().fill(.regularMaterial))
}
.buttonStyle(PlainButtonStyle())
.disabled(!canCopySummary)
.help("Copy summary overview")
```

### Payload Construction

```swift
private var summaryClipboardText: String? {
    var sections: [String] = []
    sections.append(isRedditContent ? "Reddit Summary Overview"
                                    : "Article Summary Overview")

    if let combined = appState.aggregateSummaryText?.trimmed,
       !combined.isEmpty {
        sections.append("Overall Summary:\n\(combined)")
    }

    for (index, item) in parsedSummaries.enumerated() {
        let subject = "\(index + 1). \(item.subject)"
        let summary = item.summary.trimmed
        sections.append(summary.isEmpty ? subject : "\(subject)\n\(summary)")
    }

    return sections.joined(separator: "\n\n").trimmedOrNil
}
```

```swift
private func copySummaryToClipboard() {
    guard let text = summaryClipboardText else { return }
    #if os(iOS)
    UIPasteboard.general.string = text
    #else
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
    #endif
}
```

`trimmedOrNil` is sugar for `string.trimmingCharacters(in: .whitespacesAndNewlines)` returning `nil` if empty.

---

## 2. Question Console (`?`)

### Toggle Button

```swift
Button {
    withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
        if showQAInterface { resetQAState() } else { showQAInterface = true }
    }
} label: {
    Text("?")
        .font(.system(size: 12, weight: .bold))
        .foregroundColor(showQAInterface ? .white : .primary)
        .frame(width: 22, height: 22)
        .background(
            Circle()
                .fill(.regularMaterial)
                .overlay(
                    Circle()
                        .fill(Color.accentColor)
                        .opacity(showQAInterface ? 1 : 0)
                )
        )
}
.buttonStyle(PlainButtonStyle())
.disabled(!hasSummaryContent)
.help("Ask a question about this overview")
```

### Inline Console

```swift
if showQAInterface {
    VStack(alignment: .leading, spacing: 10) {
        Text("Ask a question about these \(isRedditContent ? "Reddit discussions" : "articles")")

        TextField("Type your question...", text: $qaQuestionText)
            .textFieldStyle(AdaptiveLiquidGlassTextFieldStyle(...))
            .disabled(isProcessingQA || appState.isWaitingForGlobalQA)
            .onSubmit { askGlobalSummaryQuestion() }

        HStack {
            Button("Ask", systemImage: "questionmark.circle") { askGlobalSummaryQuestion() }
                .buttonStyle(LiquidGlassButtonStyle())
                .disabled(qaQuestionText.trimmed.isEmpty || isProcessingQA || appState.isWaitingForGlobalQA)

            Button("Clear", systemImage: "xmark.circle") { resetQAState(keepInterface: true) }
                .buttonStyle(LiquidGlassButtonStyle())
                .disabled(isProcessingQA || appState.isWaitingForGlobalQA)
            Spacer()
        }

        if let inlineError = qaInlineError {
            Text(inlineError).font(.caption).foregroundColor(.red)
        } else if isProcessingQA || appState.isWaitingForGlobalQA {
            HStack(spacing: 8) {
                ProgressView().scaleEffect(0.8)
                Text(appState.globalQAWaitProgress.isEmpty ? "Thinking..." : appState.globalQAWaitProgress)
                    .font(.caption).foregroundColor(.secondary)
            }
        } else if !qaAnswerText.isEmpty {
            HStack {
                Button("Open Answer", systemImage: "arrow.up.left.and.arrow.down.right") {
                    showAnswerSheet = true
                }
                .buttonStyle(LiquidGlassButtonStyle())

                Button("Copy", systemImage: "doc.on.doc") {
                    copySummaryToClipboard(text: qaAnswerText)
                }
                .buttonStyle(LiquidGlassButtonStyle())
                Spacer()
            }
            .transition(.opacity.combined(with: .slide))
        }
    }
    .padding()
    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    .padding(.horizontal)
}
```

### Full-Size Answer Sheet

Whenever a new answer arrives or the user taps “Open Answer,” the sheet appears:

```swift
.sheet(isPresented: $showAnswerSheet) {
    NavigationStack {
        ScrollView {
            Text(qaAnswerText.isEmpty ? "No answer available." : qaAnswerText)
                .font(.body)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .navigationTitle("Summary Answer")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Close") { showAnswerSheet = false }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    copySummaryToClipboard(text: qaAnswerText)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
            }
        }
    }
    #if os(iOS)
    .presentationDetents([.medium, .large])
    .presentationCornerRadius(32)
    #endif
}
```

The sheet uses the same materials and detents as the overlay, so long answers are readable without truncation.

### Dispatching the Question

```swift
private func askGlobalSummaryQuestion() {
    guard !isProcessingQA && !appState.isWaitingForGlobalQA else { return }
    let trimmed = qaQuestionText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
        qaInlineError = "Please enter a question first."
        return
    }

    qaInlineError = nil
    isProcessingQA = true
    qaAnswerText = ""

    appState.askQuestionAboutGlobalSummary(question: trimmed) { answer in
        DispatchQueue.main.async {
            self.qaAnswerText = answer
            self.isProcessingQA = false
            self.showAnswerSheet = true
        }
    }
}
```

Copying answers uses the same helper as the main `C` button:

```swift
private func copySummaryToClipboard(text: String) {
    guard !text.isEmpty else { return }
    #if os(iOS)
    UIPasteboard.general.string = text
    #else
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
    #endif
}
```

---

## 3. AppState Pipeline

`AppState.askQuestionAboutGlobalSummary(question:completion:)` (`RSSReaderApp/Controllers/AppState.swift:3671-3876`) reuses the exact articles/posts that generated the overview:

1. **Articles:** grabs `globalSummaryArticles`, strips HTML, truncates to ~1800 chars per item, and builds a prompt block.
2. **Reddit:** uses `globalSummaryPosts`, re-fetches the same `topComments` count via `fetchCommentsForGlobalSummary`, filters AutoModerator, truncates each comment (~400 chars), and includes post metadata.
3. Hands the prompt to `executeGlobalQAPrompt`, which routes through:
   - Apple Intelligence on-device (with Gemini fallback)
   - Apple Cloud Shortcuts (clipboard monitoring uses the new `.globalSummaryQA` case)
   - Gemini (default)

When the callback fires, the view updates `qaAnswerText` and opens the sheet automatically.

---

## Summary

- The `C` button copies the exact overlay content (overall + per-item summaries) to the clipboard.
- The `?` console lets users ask follow-up questions using the same data set that fueled the summary.
- Answers always open in a full-size sheet, ensuring long responses stay readable and easy to copy.
