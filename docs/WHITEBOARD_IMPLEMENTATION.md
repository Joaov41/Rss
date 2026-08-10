# Whiteboard Feature Implementation Guide

A comprehensive guide to implementing the minimalist whiteboard visualization feature that transforms content summaries into structured, scannable insights.

---

## Table of Contents

1. [Overview](#overview)
2. [Architecture](#architecture)
3. [Data Structures](#data-structures)
4. [State Management](#state-management)
5. [LLM Prompt Engineering](#llm-prompt-engineering)
6. [JSON Parsing](#json-parsing)
7. [HTML Generation](#html-generation)
8. [CSS Design System](#css-design-system)
9. [SwiftUI Views](#swiftui-views)
10. [WebView Integration](#webview-integration)
11. [Complete Code Reference](#complete-code-reference)

---

## Overview

The Whiteboard feature generates a structured visualization from content summaries (articles or Reddit posts) using an LLM. It produces a clean, minimalist HTML document rendered in a WebView.

### Key Features

- **Contextual sections**: Different labels for Reddit vs Article content
- **Minimalist aesthetic**: No shadows, gradients, or decorative elements
- **Clickable links**: Posts/articles link to original sources
- **Responsive layout**: Works on iPhone, iPad, and Mac
- **Copy/Save**: Export as image

---

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                      User Taps Button                        │
└─────────────────────────┬───────────────────────────────────┘
                          │
                          ▼
┌─────────────────────────────────────────────────────────────┐
│                   generateWhiteboard()                       │
│  - Collects parsed summaries                                 │
│  - Builds URL reference list                                 │
│  - Creates contextual prompt                                 │
└─────────────────────────┬───────────────────────────────────┘
                          │
                          ▼
┌─────────────────────────────────────────────────────────────┐
│                      LLM API Call                            │
│  - Sends prompt to Gemini/OpenAI                            │
│  - Returns JSON response                                     │
└─────────────────────────┬───────────────────────────────────┘
                          │
                          ▼
┌─────────────────────────────────────────────────────────────┐
│                  parseWhiteboardPayload()                    │
│  - Strips markdown fences                                    │
│  - Parses JSON to WhiteboardPayload struct                  │
└─────────────────────────┬───────────────────────────────────┘
                          │
                          ▼
┌─────────────────────────────────────────────────────────────┐
│                   buildWhiteboardHTML()                      │
│  - Generates semantic HTML                                   │
│  - Applies minimalist CSS                                    │
│  - Returns complete HTML document                            │
└─────────────────────────┬───────────────────────────────────┘
                          │
                          ▼
┌─────────────────────────────────────────────────────────────┐
│                     WhiteboardView                           │
│  - Presents fullScreenCover                                  │
│  - Renders HTML in WKWebView                                │
│  - Handles link navigation                                   │
└─────────────────────────────────────────────────────────────┘
```

---

## Data Structures

### WhiteboardPayload

```swift
private struct WhiteboardPayload {
    struct Takeaway {
        let insight: String
        let source: String  // Credibility indicator
    }

    struct PainPoint {
        let issue: String
        let severity: String  // "high", "medium", "low"
    }

    struct HotTake {
        let quote: String
        let context: String
    }

    struct KeyPost {
        let title: String
        let url: String?
        let why: String
    }

    let sessionTitle: String
    let sessionContext: String
    let whatWeKnow: [String]
    let openQuestions: [String]
    let takeaways: [Takeaway]
    let painPoints: [PainPoint]
    let hotTakes: [HotTake]
    let connections: [String]
    let ideasToExplore: [String]
    let keyPosts: [KeyPost]
    let bottomLine: String
    let isRedditContent: Bool  // For contextual display

    init(dictionary: [String: Any], isReddit: Bool = false) {
        func string(_ value: Any?, default defaultValue: String) -> String {
            if let s = value as? String, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return s.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return defaultValue
        }

        self.isRedditContent = isReddit
        self.sessionTitle = string(dictionary["sessionTitle"], default: "Brainstorm Session")
        self.sessionContext = string(dictionary["sessionContext"], default: "Discussion Notes")

        self.whatWeKnow = (dictionary["whatWeKnow"] as? [String] ?? []).filter { !$0.isEmpty }
        self.openQuestions = (dictionary["openQuestions"] as? [String] ?? []).filter { !$0.isEmpty }
        self.connections = (dictionary["connections"] as? [String] ?? []).filter { !$0.isEmpty }
        self.ideasToExplore = (dictionary["ideasToExplore"] as? [String] ?? []).filter { !$0.isEmpty }

        self.takeaways = (dictionary["takeaways"] as? [[String: Any]] ?? []).map {
            Takeaway(
                insight: string($0["insight"], default: "Key insight"),
                source: string($0["source"], default: isReddit ? "Community" : "Article")
            )
        }

        self.painPoints = (dictionary["painPoints"] as? [[String: Any]] ?? []).map {
            PainPoint(
                issue: string($0["issue"], default: "Issue identified"),
                severity: string($0["severity"], default: "medium")
            )
        }

        self.hotTakes = (dictionary["hotTakes"] as? [[String: Any]] ?? []).map {
            HotTake(
                quote: string($0["quote"], default: "Notable opinion"),
                context: string($0["context"], default: "")
            )
        }

        self.keyPosts = (dictionary["keyPosts"] as? [[String: Any]] ?? []).map {
            KeyPost(
                title: string($0["title"], default: "Post"),
                url: string($0["url"], default: ""),
                why: string($0["why"], default: "")
            )
        }

        self.bottomLine = string(dictionary["bottomLine"], default: "Key insight from this session.")
    }
}
```

---

## State Management

Add these state variables to your view:

```swift
// Whiteboard state
@State private var showWhiteboard: Bool = false
@State private var whiteboardContent: Data?
@State private var isGeneratingWhiteboard: Bool = false
@State private var whiteboardError: String?

// Content type flag (set based on your app's context)
var isRedditContent: Bool { /* your logic */ }
```

---

## LLM Prompt Engineering

The prompt is contextual based on content type (Reddit vs Articles).

### Prompt Generator

```swift
private func makeWhiteboardPrompt(from content: String, urlReference: String) -> String {
    let trimmed = String(content.prefix(2000))

    // Contextual takeaways section based on content type
    let takeawaysSection: String
    let takeawaysGuideline: String

    if isRedditContent {
        takeawaysSection = """
          "takeaways": [
            { "insight": "What the community recommends or suggests (≤80 chars)", "source": "Community consensus/Highly upvoted/Power user/Experienced member" },
            ... 3-5 items
          ],
        """
        takeawaysGuideline = "- Takeaways should capture what the Reddit community recommends, suggests, or advises. Source indicates credibility (highly upvoted, experienced user, community consensus)."
    } else {
        takeawaysSection = """
          "takeaways": [
            { "insight": "Key takeaway or actionable insight from the article (≤80 chars)", "source": "Expert opinion/Research finding/Industry trend/Data-backed" },
            ... 3-5 items
          ],
        """
        takeawaysGuideline = "- Takeaways should capture the most important insights readers should remember. Source indicates the type of insight (expert opinion, research finding, trend)."
    }

    return """
    You are creating brainstorm notes on a whiteboard after reviewing \(isRedditContent ? "Reddit discussions" : "articles"). This is NOT a polished infographic - it's a working document capturing insights, questions, and key takeaways.

    Output ONLY compact JSON (no markdown, no fences):

    {
      "sessionTitle": "What's being discussed (≤40 chars)",
      "sessionContext": "\(isRedditContent ? "r/subreddit • [topic focus]" : "Articles • [topic focus]")",
      "whatWeKnow": [
        "Key fact or finding from the \(isRedditContent ? "discussions" : "articles") (≤80 chars each)",
        ... 4-6 items
      ],
      "openQuestions": [
        "Question that came up or remains unanswered (≤70 chars each)",
        ... 3-5 items
      ],
    \(takeawaysSection)
      "painPoints": [
        { "issue": "\(isRedditContent ? "Problem or frustration users mention" : "Challenge or concern raised in the articles")", "severity": "high/medium/low" },
        ... 3-4 items
      ],
      "hotTakes": [
        { "quote": "\(isRedditContent ? "Interesting or controversial opinion from comments (actual quote)" : "Notable quote or bold claim from the article")", "context": "brief context" },
        ... 2-4 items
      ],
      "connections": [
        "How X relates to Y - cause/effect or pattern (≤60 chars)",
        ... 2-4 items
      ],
      "ideasToExplore": [
        "\(isRedditContent ? "Topic the community wants to explore further" : "Area worth investigating based on the articles") (≤60 chars)",
        ... 2-4 items
      ],
      "keyPosts": [
        { "title": "\(isRedditContent ? "Post" : "Article") title (≤50 chars)", "url": "EXACT_URL_FROM_REFERENCE_LIST", "why": "why it matters (≤30 chars)" },
        ... 3-5 items
      ],
      "bottomLine": "The 'so what' - one sentence takeaway (≤100 chars)"
    }

    IMPORTANT GUIDELINES:
    - This is brainstorm notes, NOT a formal summary. Use informal language, abbreviations, shorthand.
    \(takeawaysGuideline)
    - Hot takes should be ACTUAL quotes or paraphrases from the content, attributed.
    - Connections should show relationships: "X causes Y", "When A happens, B follows", etc.
    - Pain points need severity levels to prioritize.
    - Open questions are things \(isRedditContent ? "the community is debating" : "left unanswered") or unclear about.
    - Bottom line should be the key insight someone should take away.

    **CRITICAL FOR keyPosts URLs:**
    You MUST use ONLY the exact URLs from the POST REFERENCE LIST below. Do NOT make up URLs.
    Copy the URL exactly as shown after the → arrow. If you can't find a matching post, leave the url field empty "".

    === POST REFERENCE LIST (use these exact URLs) ===
    \(urlReference)
    === END REFERENCE LIST ===

    Content:
    \(trimmed)
    """
}
```

---

## JSON Parsing

```swift
private func parseWhiteboardPayload(from text: String) -> WhiteboardPayload? {
    var rawString = text.trimmingCharacters(in: .whitespacesAndNewlines)

    // Strip markdown code fences
    if rawString.hasPrefix("```") {
        rawString = rawString.replacingOccurrences(of: "```json", with: "")
        rawString = rawString.replacingOccurrences(of: "```", with: "")
    }

    // Extract JSON object between braces
    if let firstBrace = rawString.firstIndex(of: "{"),
       let lastBrace = rawString.lastIndex(of: "}") {
        rawString = String(rawString[firstBrace...lastBrace])
    }

    guard let jsonData = rawString.data(using: .utf8),
          let json = try? JSONSerialization.jsonObject(with: jsonData, options: []) as? [String: Any] else {
        return nil
    }

    return WhiteboardPayload(dictionary: json, isReddit: isRedditContent)
}
```

---

## HTML Generation

### HTML Builder

```swift
private func buildWhiteboardHTML(from payload: WhiteboardPayload) -> String {
    // Build list items (no decorations, pure content)

    let whatWeKnowHTML = payload.whatWeKnow.prefix(6).map { item in
        "<li class=\"fact-item\">\(escapeHTML(item))</li>"
    }.joined()

    let questionsHTML = payload.openQuestions.prefix(5).map { item in
        "<li class=\"question-item\">\(escapeHTML(item))</li>"
    }.joined()

    let takeawaysHTML = payload.takeaways.prefix(5).map { item in
        """
        <div class="takeaway-item">
          <p class="takeaway-insight">\(escapeHTML(item.insight))</p>
          <span class="takeaway-source">\(escapeHTML(item.source))</span>
        </div>
        """
    }.joined()

    let painHTML = payload.painPoints.prefix(4).map { item in
        let severityClass = item.severity.lowercased()
        return """
        <div class="pain-item">
          <span class="severity severity-\(severityClass)">\(severityClass.uppercased())</span>
          <p class="pain-text">\(escapeHTML(item.issue))</p>
        </div>
        """
    }.joined()

    let hotTakesHTML = payload.hotTakes.prefix(4).map { item in
        """
        <blockquote class="quote-item">
          <p class="quote-text">"\(escapeHTML(item.quote))"</p>
          <cite class="quote-context">\(escapeHTML(item.context))</cite>
        </blockquote>
        """
    }.joined()

    let connectionsHTML = payload.connections.prefix(4).map { connection in
        "<li class=\"connection-item\">\(escapeHTML(connection))</li>"
    }.joined()

    let ideasHTML = payload.ideasToExplore.prefix(4).map { item in
        "<li class=\"idea-item\">\(escapeHTML(item))</li>"
    }.joined()

    let postsHTML = payload.keyPosts.prefix(5).map { post in
        let normalized = normalizeURL(post.url ?? "")
        let linkHTML = normalized.isEmpty ? "" : "<a class=\"post-link\" href=\"\(normalized)\" target=\"_blank\">View →</a>"
        return """
        <div class="post-item">
          <p class="post-title">\(escapeHTML(post.title))</p>
          <span class="post-why">\(escapeHTML(post.why))</span>
          \(linkHTML)
        </div>
        """
    }.joined()

    // Contextual labels
    let takeawaysLabel = payload.isRedditContent ? "Community Suggestions" : "Key Takeaways"
    let postsLabel = payload.isRedditContent ? "Key Posts" : "Key Articles"
    let emptyTakeawaysMsg = payload.isRedditContent ? "No suggestions yet" : "No takeaways yet"
    let emptyPostsMsg = payload.isRedditContent ? "No posts pinned" : "No articles pinned"

    return """
    <!DOCTYPE html>
    <html lang="en">
    <head>
      <meta charset="UTF-8" />
      <meta name="viewport" content="width=device-width, initial-scale=1.0" />
      <style>
        \(minimalistCSS())
      </style>
    </head>
    <body>
      <div class="board">
        <header class="header">
          <h1 class="session-title">\(escapeHTML(payload.sessionTitle))</h1>
          <p class="session-context">\(escapeHTML(payload.sessionContext))</p>
        </header>

        <div class="grid-2">
          <section class="section">
            <h2 class="section-title">What We Know</h2>
            \(whatWeKnowHTML.isEmpty ? "<p class=\"empty-state\">No confirmed facts yet</p>" : "<ul class=\"item-list\">\(whatWeKnowHTML)</ul>")
          </section>

          <section class="section">
            <h2 class="section-title">Open Questions</h2>
            \(questionsHTML.isEmpty ? "<p class=\"empty-state\">No questions recorded</p>" : "<ul class=\"item-list\">\(questionsHTML)</ul>")
          </section>
        </div>

        <section class="section">
          <h2 class="section-title">\(takeawaysLabel)</h2>
          \(takeawaysHTML.isEmpty ? "<p class=\"empty-state\">\(emptyTakeawaysMsg)</p>" : "<div>\(takeawaysHTML)</div>")
        </section>

        <div class="grid-2">
          <section class="section">
            <h2 class="section-title">Pain Points</h2>
            \(painHTML.isEmpty ? "<p class=\"empty-state\">No issues identified</p>" : "<div>\(painHTML)</div>")
          </section>

          <section class="section">
            <h2 class="section-title">Notable Quotes</h2>
            \(hotTakesHTML.isEmpty ? "<p class=\"empty-state\">No notable quotes</p>" : "<div>\(hotTakesHTML)</div>")
          </section>
        </div>

        \(!payload.connections.isEmpty ? """
        <section class="section">
          <h2 class="section-title">Connections</h2>
          <ul class="item-list">\(connectionsHTML)</ul>
        </section>
        """ : "")

        <div class="grid-2">
          <section class="section">
            <h2 class="section-title">Ideas to Explore</h2>
            \(ideasHTML.isEmpty ? "<p class=\"empty-state\">No ideas yet</p>" : "<ul class=\"item-list\">\(ideasHTML)</ul>")
          </section>

          <section class="section">
            <h2 class="section-title">\(postsLabel)</h2>
            \(postsHTML.isEmpty ? "<p class=\"empty-state\">\(emptyPostsMsg)</p>" : "<div>\(postsHTML)</div>")
          </section>
        </div>

        <footer class="bottom-line">
          <p class="bottom-line-label">Bottom Line</p>
          <p class="bottom-line-text">\(escapeHTML(payload.bottomLine))</p>
        </footer>
      </div>
    </body>
    </html>
    """
}
```

### HTML Escaping Utility

```swift
private func escapeHTML(_ string: String) -> String {
    return string
        .replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
        .replacingOccurrences(of: "\"", with: "&quot;")
        .replacingOccurrences(of: "'", with: "&#39;")
}
```

---

## CSS Design System

### Minimalist Aesthetic Principles

| Principle | Implementation |
|-----------|---------------|
| **Typography** | SF Pro (geometric) for data, system-ui (humanist) for headlines |
| **Scale** | 1.618:1 modular ratio (11, 13, 14, 18, 23, 32, 42px) |
| **Colors** | 3 hues max + 5-value gray ramp |
| **Background** | Pure white `#FFFFFF` |
| **Layout** | 2-column grid, 48px margins, 24px gutters |
| **Contrast** | 7:1 headlines, 4.5:1 body copy |
| **Zero chartjunk** | No shadows, gradients, decorative elements |

### Complete CSS

```swift
private func minimalistCSS() -> String {
    return """
    /* ============================================
       MINIMALIST AESTHETIC
       - Typography: SF Pro (geometric) + system-ui (humanist)
       - Colors: 3 hues max + 5-value gray ramp
       - Layout: 12-col grid, 40%+ negative space
       - Zero chartjunk: no shadows, gradients, decorations
       ============================================ */

    :root {
      /* Primary palette: Blue accent */
      --accent: #2563eb;
      --accent-light: #eff6ff;

      /* Secondary: Amber for highlights */
      --highlight: #d97706;

      /* Tertiary: Red for severity */
      --alert: #dc2626;

      /* Neutral gray ramp (5 values) */
      --gray-900: #0A0A0A;
      --gray-700: #404040;
      --gray-500: #6B6B6B;
      --gray-300: #A3A3A3;
      --gray-100: #E5E5E5;

      /* Typography scale (1.618 ratio) */
      --text-xs: 11px;
      --text-sm: 13px;
      --text-base: 14px;
      --text-lg: 18px;
      --text-xl: 23px;
      --text-2xl: 32px;
      --text-3xl: 42px;

      /* Spacing */
      --space-unit: 8px;
      --gutter: 24px;
      --margin: 48px;
    }

    * {
      box-sizing: border-box;
      margin: 0;
      padding: 0;
    }

    body {
      font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", sans-serif;
      background: #FFFFFF;
      color: var(--gray-900);
      line-height: 1.5;
      min-height: 100vh;
      padding: var(--margin);
      -webkit-font-smoothing: antialiased;
    }

    .board {
      max-width: 1080px;
      margin: 0 auto;
    }

    /* HEADER */
    .header {
      margin-bottom: calc(var(--space-unit) * 6);
      padding-bottom: calc(var(--space-unit) * 4);
      border-bottom: 1px solid var(--gray-100);
    }

    .session-title {
      font-family: system-ui, -apple-system, sans-serif;
      font-size: var(--text-2xl);
      font-weight: 600;
      color: var(--gray-900);
      letter-spacing: -0.02em;
      line-height: 1.2;
    }

    .session-context {
      font-size: var(--text-sm);
      color: var(--gray-500);
      margin-top: var(--space-unit);
    }

    /* GRID LAYOUT */
    .grid-2 {
      display: grid;
      grid-template-columns: 1fr 1fr;
      gap: var(--gutter);
      margin-bottom: calc(var(--space-unit) * 5);
    }

    @media (max-width: 768px) {
      .grid-2 { grid-template-columns: 1fr; }
      body { padding: var(--gutter); }
    }

    .section {
      margin-bottom: calc(var(--space-unit) * 5);
    }

    /* SECTION HEADERS */
    .section-title {
      font-family: system-ui, -apple-system, sans-serif;
      font-size: var(--text-xs);
      font-weight: 600;
      text-transform: uppercase;
      letter-spacing: 0.1em;
      color: var(--gray-500);
      margin-bottom: calc(var(--space-unit) * 2);
    }

    /* LISTS */
    .item-list {
      list-style: none;
    }

    .item-list li {
      font-size: var(--text-base);
      color: var(--gray-700);
      padding: calc(var(--space-unit) * 1.5) 0;
      border-bottom: 1px solid var(--gray-100);
    }

    .item-list li:last-child {
      border-bottom: none;
    }

    .fact-item::before {
      content: "—";
      color: var(--gray-300);
      margin-right: var(--space-unit);
    }

    .question-item {
      color: var(--accent);
    }

    /* TAKEAWAYS */
    .takeaway-item {
      padding: calc(var(--space-unit) * 2) 0;
      border-bottom: 1px solid var(--gray-100);
    }

    .takeaway-item:last-child {
      border-bottom: none;
    }

    .takeaway-insight {
      font-size: var(--text-base);
      font-weight: 500;
      color: var(--gray-900);
      margin: 0;
    }

    .takeaway-source {
      font-size: var(--text-xs);
      color: var(--highlight);
      margin-top: calc(var(--space-unit) / 2);
      display: block;
    }

    /* PAIN POINTS */
    .pain-item {
      display: flex;
      align-items: baseline;
      gap: calc(var(--space-unit) * 1.5);
      padding: calc(var(--space-unit) * 1.5) 0;
      border-bottom: 1px solid var(--gray-100);
    }

    .pain-item:last-child {
      border-bottom: none;
    }

    .severity {
      font-size: var(--text-xs);
      font-weight: 600;
      text-transform: uppercase;
      letter-spacing: 0.05em;
      padding: 2px 6px;
      border-radius: 2px;
      flex-shrink: 0;
    }

    .severity-high {
      color: #FFFFFF;
      background: var(--alert);
    }

    .severity-medium {
      color: var(--gray-900);
      background: var(--gray-100);
    }

    .severity-low {
      color: var(--gray-500);
      background: transparent;
      border: 1px solid var(--gray-300);
    }

    .pain-text {
      font-size: var(--text-base);
      color: var(--gray-700);
      margin: 0;
    }

    /* QUOTES */
    .quote-item {
      padding: calc(var(--space-unit) * 2) 0;
      border-bottom: 1px solid var(--gray-100);
      border-left: 2px solid var(--gray-300);
      padding-left: calc(var(--space-unit) * 2);
      margin: 0;
    }

    .quote-item:last-child {
      border-bottom: none;
    }

    .quote-text {
      font-size: var(--text-base);
      font-style: italic;
      color: var(--gray-700);
      margin: 0;
    }

    .quote-context {
      font-size: var(--text-xs);
      color: var(--gray-500);
      font-style: normal;
      margin-top: calc(var(--space-unit) / 2);
      display: block;
    }

    /* KEY POSTS/ARTICLES */
    .post-item {
      padding: calc(var(--space-unit) * 2) 0;
      border-bottom: 1px solid var(--gray-100);
    }

    .post-item:last-child {
      border-bottom: none;
    }

    .post-title {
      font-size: var(--text-base);
      font-weight: 500;
      color: var(--gray-900);
      margin: 0;
    }

    .post-why {
      font-size: var(--text-xs);
      color: var(--gray-500);
      margin-top: calc(var(--space-unit) / 2);
      display: block;
    }

    .post-link {
      font-size: var(--text-xs);
      color: var(--accent);
      text-decoration: none;
      margin-top: var(--space-unit);
      display: inline-block;
    }

    .post-link:hover {
      text-decoration: underline;
    }

    /* BOTTOM LINE */
    .bottom-line {
      margin-top: calc(var(--space-unit) * 6);
      padding-top: calc(var(--space-unit) * 4);
      border-top: 2px solid var(--gray-900);
    }

    .bottom-line-label {
      font-size: var(--text-xs);
      font-weight: 600;
      text-transform: uppercase;
      letter-spacing: 0.1em;
      color: var(--gray-500);
      margin-bottom: var(--space-unit);
    }

    .bottom-line-text {
      font-family: system-ui, -apple-system, sans-serif;
      font-size: var(--text-lg);
      font-weight: 500;
      color: var(--gray-900);
      line-height: 1.4;
    }

    /* EMPTY STATES */
    .empty-state {
      font-size: var(--text-sm);
      color: var(--gray-300);
      padding: calc(var(--space-unit) * 2) 0;
    }
    """
}
```

---

## SwiftUI Views

### WhiteboardView

```swift
struct WhiteboardView: View {
    let htmlData: Data?
    let onDismiss: () -> Void

    @State private var isLoading = true
    @State private var webViewRef: WKWebView?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let data = htmlData,
                   let htmlString = String(data: data, encoding: .utf8) {
                    ZStack {
                        WhiteboardWebView(
                            htmlContent: htmlString,
                            webView: $webViewRef,
                            isLoading: $isLoading
                        )
                        .edgesIgnoringSafeArea(.bottom)

                        if isLoading {
                            ProgressView("Rendering...")
                                .padding(12)
                                .background(.ultraThinMaterial)
                                .cornerRadius(12)
                        }
                    }
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.largeTitle)
                            .foregroundColor(.secondary)
                        Text("Unable to load whiteboard")
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle("Whiteboard")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { onDismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        copyWhiteboardImage()
                    } label: {
                        Label("Copy Image", systemImage: "square.on.square")
                    }
                    .disabled(htmlData == nil || webViewRef == nil || isLoading)
                }
            }
        }
    }

    private func copyWhiteboardImage() {
        guard let webView = webViewRef else { return }

        let config = WKSnapshotConfiguration()
        config.afterScreenUpdates = true

        webView.takeSnapshot(with: config) { image, error in
            if let image = image {
                #if os(iOS)
                UIPasteboard.general.image = image
                #elseif os(macOS)
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                if let tiffData = image.tiffRepresentation {
                    pasteboard.setData(tiffData, forType: .tiff)
                }
                #endif
            }
        }
    }
}
```

---

## WebView Integration

### iOS WebView

```swift
#if os(iOS)
struct WhiteboardWebView: UIViewRepresentable {
    let htmlContent: String
    @Binding var webView: WKWebView?
    @Binding var isLoading: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.preferences.javaScriptEnabled = false
        let wv = WKWebView(frame: .zero, configuration: config)
        wv.navigationDelegate = context.coordinator
        wv.isOpaque = false
        wv.backgroundColor = .clear
        wv.scrollView.backgroundColor = .clear

        DispatchQueue.main.async {
            self.webView = wv
        }

        context.coordinator.lastHTML = htmlContent
        wv.loadHTMLString(htmlContent, baseURL: nil)
        return wv
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        guard context.coordinator.lastHTML != htmlContent else { return }
        context.coordinator.lastHTML = htmlContent
        uiView.loadHTMLString(htmlContent, baseURL: nil)
    }

    class Coordinator: NSObject, WKNavigationDelegate {
        var parent: WhiteboardWebView
        var lastHTML: String?

        init(parent: WhiteboardWebView) {
            self.parent = parent
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            parent.isLoading = true
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.isLoading = false
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            parent.isLoading = false
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            parent.isLoading = false
        }

        // Handle link clicks - open in Safari
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if navigationAction.navigationType == .other {
                decisionHandler(.allow)
                return
            }

            if let url = navigationAction.request.url,
               navigationAction.navigationType == .linkActivated {
                UIApplication.shared.open(url)
                decisionHandler(.cancel)
                return
            }

            decisionHandler(.cancel)
        }
    }
}
#endif
```

### macOS WebView

```swift
#if os(macOS)
struct WhiteboardWebView: NSViewRepresentable {
    let htmlContent: String
    @Binding var webView: WKWebView?
    @Binding var isLoading: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.preferences.javaScriptEnabled = false
        let wv = WKWebView(frame: .zero, configuration: config)
        wv.navigationDelegate = context.coordinator

        DispatchQueue.main.async {
            self.webView = wv
        }

        context.coordinator.lastHTML = htmlContent
        wv.loadHTMLString(htmlContent, baseURL: nil)
        return wv
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        guard context.coordinator.lastHTML != htmlContent else { return }
        context.coordinator.lastHTML = htmlContent
        nsView.loadHTMLString(htmlContent, baseURL: nil)
    }

    class Coordinator: NSObject, WKNavigationDelegate {
        var parent: WhiteboardWebView
        var lastHTML: String?

        init(parent: WhiteboardWebView) {
            self.parent = parent
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            parent.isLoading = true
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.isLoading = false
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if navigationAction.navigationType == .other {
                decisionHandler(.allow)
                return
            }

            if let url = navigationAction.request.url,
               navigationAction.navigationType == .linkActivated {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
                return
            }

            decisionHandler(.cancel)
        }
    }
}
#endif
```

---

## Complete Code Reference

### Main Generation Function

```swift
private func generateWhiteboard() {
    guard !isGeneratingWhiteboard else { return }

    isGeneratingWhiteboard = true
    whiteboardError = nil

    // 1. Build content from your summaries
    let content = yourSummaries.enumerated().map { index, item in
        let title = item.title.isEmpty ? "Item \(index + 1)" : item.title
        let truncatedContent = String(item.content.prefix(2000))
        return "[\(index + 1)] \"\(title)\"\n\(truncatedContent)\n"
    }.joined(separator: "\n---\n")

    // 2. Build URL reference list
    let urlReferenceList = yourSummaries.enumerated().compactMap { (index, item) -> String? in
        guard let url = item.url else { return nil }
        return "[\(index + 1)] \"\(item.title)\" -> \(url)"
    }.joined(separator: "\n")

    // 3. Create prompt
    let prompt = makeWhiteboardPrompt(from: content, urlReference: urlReferenceList)

    // 4. Call LLM
    Task {
        do {
            let apiKey = yourAPIKey
            guard !apiKey.isEmpty else {
                await MainActor.run {
                    self.whiteboardError = "API key not configured"
                    self.isGeneratingWhiteboard = false
                }
                return
            }

            // Your LLM API call here
            let response = try await callYourLLMAPI(prompt: prompt)

            // 5. Parse response
            guard let payload = parseWhiteboardPayload(from: response) else {
                await MainActor.run {
                    self.whiteboardError = "Failed to parse whiteboard data"
                    self.isGeneratingWhiteboard = false
                }
                return
            }

            // 6. Build HTML
            let html = buildWhiteboardHTML(from: payload)

            guard let htmlData = html.data(using: .utf8) else {
                await MainActor.run {
                    self.whiteboardError = "Failed to generate whiteboard"
                    self.isGeneratingWhiteboard = false
                }
                return
            }

            // 7. Show whiteboard
            await MainActor.run {
                self.whiteboardContent = htmlData
                self.isGeneratingWhiteboard = false
                self.showWhiteboard = true
            }

        } catch {
            await MainActor.run {
                self.whiteboardError = "Error: \(error.localizedDescription)"
                self.isGeneratingWhiteboard = false
            }
        }
    }
}
```

### UI Integration

```swift
// Button to trigger
Button {
    generateWhiteboard()
} label: {
    if isGeneratingWhiteboard {
        ProgressView()
            .scaleEffect(0.7)
    } else {
        Image(systemName: "square.grid.3x3")
    }
}
.disabled(isGeneratingWhiteboard || summaries.isEmpty)

// Sheet presentation
.fullScreenCover(isPresented: $showWhiteboard) {
    WhiteboardView(
        htmlData: whiteboardContent,
        onDismiss: { showWhiteboard = false }
    )
}
```

---

## Checklist for Implementation

- [ ] Add `WhiteboardPayload` struct
- [ ] Add state variables
- [ ] Implement `makeWhiteboardPrompt()`
- [ ] Implement `parseWhiteboardPayload()`
- [ ] Implement `buildWhiteboardHTML()` with `minimalistCSS()`
- [ ] Implement `escapeHTML()` utility
- [ ] Add `WhiteboardView`
- [ ] Add `WhiteboardWebView` (iOS and/or macOS)
- [ ] Add trigger button and `.fullScreenCover`
- [ ] Test with both content types (if applicable)

---

## Dependencies

- **SwiftUI**
- **WebKit** (for WKWebView)
- **Your LLM SDK** (Gemini, OpenAI, etc.)

---

## License

MIT License - Adapt as needed for your use case.
