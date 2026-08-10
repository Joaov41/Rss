# Whiteboard Feature Implementation Guide

## Overview

The Whiteboard feature generates a visual, sticky-note style collaboration board from Reddit post summaries using Google's Gemini LLM. It's designed to look and feel like a real brainstorming whiteboard with color-coded sections, sticky notes, and interactive elements.

**Key Differences from Infographic:**
- **Visual Style**: Sticky notes, hand-drawn aesthetic, grid paper background
- **Content Structure**: Organized into brainstorming sections (What We Know, Open Questions, Action Items, etc.)
- **Interaction**: Links open in Safari, scrollable content, snapshot/save capabilities
- **Data Model**: Custom WhiteboardPayload vs InfographicPayload

---

## Architecture

```
┌─────────────────┐
│   ContentView   │
│  (State + UI)   │
└────────┬────────┘
         │
         ├─► generateWhiteboard()
         │   └─► LLM Prompt with URL references
         │
         ├─► parseWhiteboardPayload()
         │   └─► JSON parsing to WhiteboardPayload
         │
         ├─► buildWhiteboardHTML()
         │   └─► HTML/CSS generation
         │
         └─► InfographicView
             └─► WKWebView rendering
```

---

## Part 1: Data Structure

### WhiteboardPayload Struct

```swift
private struct WhiteboardPayload {
    // Sub-structures for complex data
    struct ActionItem {
        let task: String
        let owner: String
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
        let why: String  // Why this post is important
    }

    // Main payload fields
    let sessionTitle: String
    let sessionContext: String
    let whatWeKnow: [String]           // Facts and confirmed information
    let openQuestions: [String]        // Unanswered questions
    let actionItems: [ActionItem]      // Tasks with owners
    let painPoints: [PainPoint]        // Issues with severity
    let hotTakes: [HotTake]           // Controversial/interesting quotes
    let connections: [String]          // Relationships between topics
    let ideasToExplore: [String]      // Future investigation areas
    let keyPosts: [KeyPost]           // Important posts with links
    let bottomLine: String            // TL;DR summary

    // Initializer from JSON dictionary
    init(dict: [String: Any]) throws {
        guard let sessionTitle = dict["sessionTitle"] as? String,
              let sessionContext = dict["sessionContext"] as? String,
              let whatWeKnow = dict["whatWeKnow"] as? [String],
              let openQuestions = dict["openQuestions"] as? [String],
              let bottomLine = dict["bottomLine"] as? String else {
            throw NSError(domain: "WhiteboardPayload", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Missing required fields"])
        }

        self.sessionTitle = sessionTitle
        self.sessionContext = sessionContext
        self.whatWeKnow = whatWeKnow
        self.openQuestions = openQuestions
        self.bottomLine = bottomLine

        // Parse action items
        var actionItems: [ActionItem] = []
        if let actionItemsArray = dict["actionItems"] as? [[String: String]] {
            for itemDict in actionItemsArray {
                if let task = itemDict["task"], let owner = itemDict["owner"] {
                    actionItems.append(ActionItem(task: task, owner: owner))
                }
            }
        }
        self.actionItems = actionItems

        // Parse pain points
        var painPoints: [PainPoint] = []
        if let painPointsArray = dict["painPoints"] as? [[String: String]] {
            for ppDict in painPointsArray {
                if let issue = ppDict["issue"], let severity = ppDict["severity"] {
                    painPoints.append(PainPoint(issue: issue, severity: severity))
                }
            }
        }
        self.painPoints = painPoints

        // Parse hot takes
        var hotTakes: [HotTake] = []
        if let hotTakesArray = dict["hotTakes"] as? [[String: String]] {
            for htDict in hotTakesArray {
                if let quote = htDict["quote"], let context = htDict["context"] {
                    hotTakes.append(HotTake(quote: quote, context: context))
                }
            }
        }
        self.hotTakes = hotTakes

        // Parse key posts
        var keyPosts: [KeyPost] = []
        if let keyPostsArray = dict["keyPosts"] as? [[String: String?]] {
            for kpDict in keyPostsArray {
                if let title = kpDict["title"] as? String,
                   let why = kpDict["why"] as? String {
                    let url = kpDict["url"] as? String
                    keyPosts.append(KeyPost(title: title, url: url, why: why))
                }
            }
        }
        self.keyPosts = keyPosts

        // Simple string arrays
        self.connections = dict["connections"] as? [String] ?? []
        self.ideasToExplore = dict["ideasToExplore"] as? [String] ?? []
    }
}
```

---

## Part 2: State Management

### State Variables in ContentView

Add these to your view's state section:

```swift
struct BatchResultsView: View {
    // ... existing state variables ...

    // Whiteboard state
    @State private var showWhiteboard: Bool = false
    @State private var whiteboardContent: Data?
    @State private var isGeneratingWhiteboard: Bool = false
    @State private var whiteboardError: String?

    // ... rest of view ...
}
```

---

## Part 3: LLM Prompt Engineering

### Building the URL Reference List

```swift
private func generateWhiteboard() {
    guard !isGeneratingWhiteboard else { return }

    isGeneratingWhiteboard = true
    whiteboardError = nil

    // Build content from batch summaries
    let content = viewModel.batchSummaries.enumerated().map { index, summary in
        let title = summary.postTitle.isEmpty ? "Post \(index + 1)" : summary.postTitle
        let truncatedContent = String(summary.content.prefix(2000))
        return "[\(index + 1)] \"\(title)\"\n\(truncatedContent)\n"
    }.joined(separator: "\n---\n")

    // Build URL reference list - CRITICAL for working links
    let urlReferenceList = viewModel.batchSummaries.enumerated().map { (index, summary) in
        let url = normalizeRedditPermalink(summary.permalink)
        return "[\(index + 1)] \"\(summary.postTitle)\" → \(url)"
    }.joined(separator: "\n")

    let prompt = makeWhiteboardPrompt(from: content, urlReference: urlReferenceList)

    // Send to LLM...
}
```

### The Whiteboard Prompt

```swift
private func makeWhiteboardPrompt(from content: String, urlReference: String) -> String {
    return """
    You are creating a **collaborative whiteboard** summarizing key insights from Reddit discussions.

    Think of this as a brainstorming session output - organize information into thematic sections with a visual, sticky-note style presentation.

    **CRITICAL FOR keyPosts URLs:**
    You MUST use ONLY the exact URLs from the POST REFERENCE LIST below.
    DO NOT generate, modify, or create any URLs.
    If a post should be included in keyPosts, copy its exact URL from the reference list.

    === POST REFERENCE LIST (use these exact URLs) ===
    \(urlReferenceList)
    === END REFERENCE LIST ===

    Based on the Reddit posts below, create a whiteboard-style summary with these sections:

    1. **sessionTitle**: A catchy title for this brainstorming session (e.g., "r/webdev Discussion: State Management Wars")
    2. **sessionContext**: 1-2 sentences setting the scene (e.g., "Developers debating the best state management solutions for React apps")

    3. **whatWeKnow**: Array of 3-5 confirmed facts or widely agreed-upon points
       - Keep each point concise (1 sentence)
       - Focus on consensus, not debate

    4. **openQuestions**: Array of 3-5 unresolved questions the community is asking
       - Frame as actual questions
       - Highlight areas of uncertainty or debate

    5. **actionItems**: Array of 2-4 tasks or next steps
       - Each item has: {"task": "description", "owner": "who/what"}
       - Owner can be "community", "devs", "maintainers", etc.

    6. **painPoints**: Array of 2-4 major issues or frustrations
       - Each has: {"issue": "description", "severity": "high|medium|low"}
       - Severity based on how often/strongly mentioned

    7. **hotTakes**: Array of 2-3 controversial or interesting quotes
       - Each has: {"quote": "the actual quote", "context": "why it matters"}
       - Look for spicy opinions or unique perspectives

    8. **connections**: Array of 2-4 relationships between topics
       - Format: "Topic A relates to Topic B because..."
       - Show how different threads connect

    9. **ideasToExplore**: Array of 2-4 future investigation areas
       - What should the community research next?
       - What interesting tangents emerged?

    10. **keyPosts**: Array of 2-4 most important posts
        - Each has: {"title": "post title", "url": "EXACT URL from reference list", "why": "why it's important"}
        - **CRITICAL**: Copy the exact URL from the POST REFERENCE LIST above
        - Match by post title and use the corresponding URL

    11. **bottomLine**: One sentence TL;DR (max 20 words)

    Return ONLY valid JSON matching this structure:

    ```json
    {
      "sessionTitle": "...",
      "sessionContext": "...",
      "whatWeKnow": ["...", "..."],
      "openQuestions": ["...", "..."],
      "actionItems": [{"task": "...", "owner": "..."}],
      "painPoints": [{"issue": "...", "severity": "high|medium|low"}],
      "hotTakes": [{"quote": "...", "context": "..."}],
      "connections": ["...", "..."],
      "ideasToExplore": ["...", "..."],
      "keyPosts": [{"title": "...", "url": "EXACT URL", "why": "..."}],
      "bottomLine": "..."
    }
    ```

    === REDDIT POSTS ===
    \(content)
    === END POSTS ===

    Respond ONLY with the JSON object, no markdown formatting, no explanation.
    """
}
```

---

## Part 4: JSON Parsing

```swift
private func parseWhiteboardPayload(from text: String) -> WhiteboardPayload? {
    // Clean up response (remove markdown code blocks if present)
    var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if cleaned.hasPrefix("```json") {
        cleaned = cleaned.replacingOccurrences(of: "```json", with: "")
    }
    if cleaned.hasPrefix("```") {
        cleaned = cleaned.replacingOccurrences(of: "```", with: "")
    }
    if cleaned.hasSuffix("```") {
        cleaned = String(cleaned.dropLast(3))
    }
    cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)

    // Parse JSON
    guard let data = cleaned.data(using: .utf8),
          let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let payload = try? WhiteboardPayload(dict: dict) else {
        return nil
    }

    return payload
}
```

---

## Part 5: HTML/CSS Generation

### Main HTML Builder

```swift
private func buildWhiteboardHTML(from payload: WhiteboardPayload) -> String {
    let sanitizedTitle = escapeHTML(payload.sessionTitle)
    let sanitizedContext = escapeHTML(payload.sessionContext)
    let sanitizedBottomLine = escapeHTML(payload.bottomLine)

    // Build all sections
    let whatWeKnowHTML = buildWhatWeKnowSection(items: payload.whatWeKnow)
    let openQuestionsHTML = buildOpenQuestionsSection(items: payload.openQuestions)
    let actionItemsHTML = buildActionItemsSection(items: payload.actionItems)
    let painPointsHTML = buildPainPointsSection(items: payload.painPoints)
    let hotTakesHTML = buildHotTakesSection(items: payload.hotTakes)
    let connectionsHTML = buildConnectionsSection(items: payload.connections)
    let ideasHTML = buildIdeasSection(items: payload.ideasToExplore)
    let keyPostsHTML = buildKeyPostsSection(items: payload.keyPosts)

    return """
    <!DOCTYPE html>
    <html lang="en">
    <head>
        <meta charset="UTF-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        <title>Whiteboard: \(sanitizedTitle)</title>
        <style>
        \(whiteboardCSS())
        </style>
    </head>
    <body>
        <div class="whiteboard">
            <!-- Header -->
            <div class="wb-header">
                <h1 class="wb-title">\(sanitizedTitle)</h1>
                <p class="wb-context">\(sanitizedContext)</p>
            </div>

            <!-- Main content grid -->
            <div class="wb-grid">
                \(whatWeKnowHTML)
                \(openQuestionsHTML)
                \(actionItemsHTML)
                \(painPointsHTML)
                \(hotTakesHTML)
                \(connectionsHTML)
                \(ideasHTML)
                \(keyPostsHTML)
            </div>

            <!-- Bottom line -->
            <div class="wb-bottomline">
                <div class="bottomline-label">Bottom Line:</div>
                <div class="bottomline-text">\(sanitizedBottomLine)</div>
            </div>
        </div>
    </body>
    </html>
    """
}
```

### CSS Styling

```swift
private func whiteboardCSS() -> String {
    return """
    :root {
        --green: #b8e994;
        --blue: #82ccdd;
        --yellow: #f8c291;
        --red: #ff6b81;
        --purple: #c7b8ff;
        --orange: #ffa502;
        --pink: #ff9ff3;
        --teal: #54a0ff;
    }

    * {
        margin: 0;
        padding: 0;
        box-sizing: border-box;
    }

    body {
        font-family: 'Marker Felt', 'Comic Sans MS', cursive, sans-serif;
        background: #f5f5f0;
        background-image:
            repeating-linear-gradient(0deg, transparent, transparent 24px, #ddd 24px, #ddd 25px),
            repeating-linear-gradient(90deg, transparent, transparent 24px, #ddd 24px, #ddd 25px);
        background-size: 25px 25px;
        padding: 20px;
        color: #333;
    }

    .whiteboard {
        max-width: 1200px;
        margin: 0 auto;
        background: rgba(255, 255, 255, 0.9);
        border-radius: 16px;
        padding: 30px;
        box-shadow: 0 10px 40px rgba(0, 0, 0, 0.15);
    }

    .wb-header {
        text-align: center;
        margin-bottom: 40px;
        padding-bottom: 20px;
        border-bottom: 3px dashed #ccc;
    }

    .wb-title {
        font-size: 2.5rem;
        color: #2c3e50;
        margin-bottom: 12px;
        transform: rotate(-1deg);
    }

    .wb-context {
        font-size: 1.1rem;
        color: #666;
        font-style: italic;
    }

    .wb-grid {
        display: grid;
        grid-template-columns: repeat(auto-fit, minmax(320px, 1fr));
        gap: 30px;
        margin-bottom: 40px;
    }

    /* Section cards */
    .wb-section {
        background: white;
        border-radius: 12px;
        padding: 20px;
        box-shadow: 0 4px 12px rgba(0, 0, 0, 0.1);
        position: relative;
    }

    .section-header {
        font-size: 1.4rem;
        font-weight: bold;
        margin-bottom: 16px;
        padding-bottom: 10px;
        border-bottom: 2px solid currentColor;
        display: flex;
        align-items: center;
        gap: 8px;
    }

    /* Sticky notes */
    .sticky-note {
        background: var(--yellow);
        padding: 12px 16px;
        margin-bottom: 12px;
        border-radius: 4px;
        box-shadow: 2px 2px 8px rgba(0, 0, 0, 0.15);
        transform: rotate(-0.5deg);
        transition: transform 0.2s, box-shadow 0.2s;
        position: relative;
    }

    .sticky-note:nth-child(even) {
        transform: rotate(0.5deg);
    }

    .sticky-note:hover {
        transform: rotate(0deg) translateY(-2px);
        box-shadow: 3px 3px 12px rgba(0, 0, 0, 0.2);
    }

    /* What We Know - Green */
    .what-we-know .sticky-note {
        background: var(--green);
        border-left: 4px solid #78e08f;
    }

    .what-we-know .section-header {
        color: #218c74;
    }

    /* Open Questions - Blue */
    .open-questions .sticky-note {
        background: var(--blue);
        border-left: 4px solid #60a3bc;
    }

    .open-questions .section-header {
        color: #0984e3;
    }

    /* Action Items - Yellow */
    .action-items .action-item {
        background: var(--yellow);
        padding: 12px;
        margin-bottom: 10px;
        border-radius: 6px;
        display: flex;
        align-items: flex-start;
        gap: 10px;
        box-shadow: 2px 2px 6px rgba(0, 0, 0, 0.1);
    }

    .action-checkbox {
        width: 20px;
        height: 20px;
        border: 2px solid #e67e22;
        border-radius: 4px;
        flex-shrink: 0;
        margin-top: 2px;
    }

    .action-content {
        flex: 1;
    }

    .action-task {
        font-weight: 600;
        margin-bottom: 4px;
    }

    .action-owner {
        font-size: 0.85rem;
        color: #666;
        font-style: italic;
    }

    .action-items .section-header {
        color: #d35400;
    }

    /* Pain Points - Red */
    .pain-points .pain-point {
        background: var(--red);
        padding: 12px;
        margin-bottom: 10px;
        border-radius: 6px;
        box-shadow: 2px 2px 6px rgba(0, 0, 0, 0.1);
    }

    .pain-issue {
        font-weight: 600;
        margin-bottom: 4px;
    }

    .pain-severity {
        font-size: 0.75rem;
        padding: 2px 8px;
        border-radius: 12px;
        background: rgba(0, 0, 0, 0.1);
        display: inline-block;
        text-transform: uppercase;
        font-weight: bold;
    }

    .severity-high {
        background: #c0392b;
        color: white;
    }

    .severity-medium {
        background: #e67e22;
        color: white;
    }

    .severity-low {
        background: #f39c12;
        color: white;
    }

    .pain-points .section-header {
        color: #c0392b;
    }

    /* Hot Takes - Purple */
    .hot-takes .hot-take {
        background: var(--purple);
        padding: 14px;
        margin-bottom: 12px;
        border-radius: 8px;
        border-left: 4px solid #8e44ad;
        box-shadow: 2px 2px 8px rgba(0, 0, 0, 0.1);
    }

    .hot-quote {
        font-size: 1.05rem;
        font-weight: 600;
        margin-bottom: 8px;
        font-style: italic;
    }

    .hot-quote::before {
        content: '"';
        font-size: 1.5rem;
        color: #8e44ad;
    }

    .hot-quote::after {
        content: '"';
        font-size: 1.5rem;
        color: #8e44ad;
    }

    .hot-context {
        font-size: 0.9rem;
        color: #555;
    }

    .hot-takes .section-header {
        color: #8e44ad;
    }

    /* Connections - Orange */
    .connections .connection {
        background: var(--orange);
        padding: 12px 16px;
        margin-bottom: 12px;
        border-radius: 6px;
        box-shadow: 2px 2px 6px rgba(0, 0, 0, 0.1);
        position: relative;
        padding-left: 30px;
    }

    .connections .connection::before {
        content: '→';
        position: absolute;
        left: 10px;
        top: 50%;
        transform: translateY(-50%);
        font-size: 1.2rem;
        font-weight: bold;
        color: #e84118;
    }

    .connections .section-header {
        color: #e84118;
    }

    /* Ideas to Explore - Teal */
    .ideas .idea {
        background: var(--teal);
        padding: 12px 16px;
        margin-bottom: 12px;
        border-radius: 6px;
        box-shadow: 2px 2px 6px rgba(0, 0, 0, 0.1);
        position: relative;
        padding-left: 30px;
    }

    .ideas .idea::before {
        content: '💡';
        position: absolute;
        left: 8px;
        top: 50%;
        transform: translateY(-50%);
        font-size: 1.1rem;
    }

    .ideas .section-header {
        color: #0652DD;
    }

    /* Key Posts - Pink */
    .key-posts .key-post {
        background: var(--pink);
        padding: 14px;
        margin-bottom: 14px;
        border-radius: 8px;
        box-shadow: 2px 2px 8px rgba(0, 0, 0, 0.1);
        position: relative;
    }

    .key-post::before {
        content: '📌';
        position: absolute;
        top: -8px;
        right: -8px;
        font-size: 1.5rem;
        transform: rotate(45deg);
    }

    .post-title {
        font-weight: bold;
        margin-bottom: 6px;
        font-size: 1.05rem;
    }

    .post-why {
        font-size: 0.9rem;
        color: #555;
        margin-bottom: 8px;
    }

    .post-link {
        display: inline-block;
        padding: 6px 12px;
        background: #e84393;
        color: white;
        text-decoration: none;
        border-radius: 6px;
        font-size: 0.85rem;
        font-weight: 600;
        transition: background 0.2s;
    }

    .post-link:hover {
        background: #c0396f;
    }

    .key-posts .section-header {
        color: #e84393;
    }

    /* Bottom Line */
    .wb-bottomline {
        background: var(--red);
        padding: 20px 30px;
        border-radius: 12px;
        box-shadow: 0 6px 20px rgba(0, 0, 0, 0.15);
        text-align: center;
        transform: rotate(-0.5deg);
    }

    .bottomline-label {
        font-size: 1rem;
        font-weight: bold;
        color: #c0392b;
        margin-bottom: 8px;
        text-transform: uppercase;
        letter-spacing: 1px;
    }

    .bottomline-text {
        font-size: 1.4rem;
        font-weight: bold;
        color: #2c3e50;
        line-height: 1.4;
    }

    /* Responsive */
    @media (max-width: 768px) {
        .wb-grid {
            grid-template-columns: 1fr;
        }

        .wb-title {
            font-size: 2rem;
        }

        .bottomline-text {
            font-size: 1.1rem;
        }
    }
    """
}
```

### Individual Section Builders

```swift
private func buildWhatWeKnowSection(items: [String]) -> String {
    guard !items.isEmpty else { return "" }

    let notesHTML = items.map { item in
        let sanitized = escapeHTML(item)
        return "<div class=\"sticky-note\">\(sanitized)</div>"
    }.joined()

    return """
    <div class="wb-section what-we-know">
        <div class="section-header">✓ What We Know</div>
        \(notesHTML)
    </div>
    """
}

private func buildOpenQuestionsSection(items: [String]) -> String {
    guard !items.isEmpty else { return "" }

    let notesHTML = items.map { item in
        let sanitized = escapeHTML(item)
        return "<div class=\"sticky-note\">\(sanitized)</div>"
    }.joined()

    return """
    <div class="wb-section open-questions">
        <div class="section-header">? Open Questions</div>
        \(notesHTML)
    </div>
    """
}

private func buildActionItemsSection(items: [WhiteboardPayload.ActionItem]) -> String {
    guard !items.isEmpty else { return "" }

    let itemsHTML = items.map { item in
        let task = escapeHTML(item.task)
        let owner = escapeHTML(item.owner)
        return """
        <div class="action-item">
            <div class="action-checkbox"></div>
            <div class="action-content">
                <div class="action-task">\(task)</div>
                <div class="action-owner">Owner: \(owner)</div>
            </div>
        </div>
        """
    }.joined()

    return """
    <div class="wb-section action-items">
        <div class="section-header">☑ Action Items</div>
        \(itemsHTML)
    </div>
    """
}

private func buildPainPointsSection(items: [WhiteboardPayload.PainPoint]) -> String {
    guard !items.isEmpty else { return "" }

    let itemsHTML = items.map { item in
        let issue = escapeHTML(item.issue)
        let severity = item.severity.lowercased()
        let severityClass = "severity-\(severity)"
        return """
        <div class="pain-point">
            <div class="pain-issue">\(issue)</div>
            <span class="pain-severity \(severityClass)">\(severity)</span>
        </div>
        """
    }.joined()

    return """
    <div class="wb-section pain-points">
        <div class="section-header">⚠️ Pain Points</div>
        \(itemsHTML)
    </div>
    """
}

private func buildHotTakesSection(items: [WhiteboardPayload.HotTake]) -> String {
    guard !items.isEmpty else { return "" }

    let itemsHTML = items.map { item in
        let quote = escapeHTML(item.quote)
        let context = escapeHTML(item.context)
        return """
        <div class="hot-take">
            <div class="hot-quote">\(quote)</div>
            <div class="hot-context">\(context)</div>
        </div>
        """
    }.joined()

    return """
    <div class="wb-section hot-takes">
        <div class="section-header">🔥 Hot Takes</div>
        \(itemsHTML)
    </div>
    """
}

private func buildConnectionsSection(items: [String]) -> String {
    guard !items.isEmpty else { return "" }

    let itemsHTML = items.map { item in
        let sanitized = escapeHTML(item)
        return "<div class=\"connection\">\(sanitized)</div>"
    }.joined()

    return """
    <div class="wb-section connections">
        <div class="section-header">🔗 Connections</div>
        \(itemsHTML)
    </div>
    """
}

private func buildIdeasSection(items: [String]) -> String {
    guard !items.isEmpty else { return "" }

    let itemsHTML = items.map { item in
        let sanitized = escapeHTML(item)
        return "<div class=\"idea\">\(sanitized)</div>"
    }.joined()

    return """
    <div class="wb-section ideas">
        <div class="section-header">💡 Ideas to Explore</div>
        \(itemsHTML)
    </div>
    """
}

private func buildKeyPostsSection(items: [WhiteboardPayload.KeyPost]) -> String {
    guard !items.isEmpty else { return "" }

    let itemsHTML = items.map { item in
        let title = escapeHTML(item.title)
        let why = escapeHTML(item.why)

        let linkHTML: String
        if let url = item.url, !url.isEmpty {
            let normalized = normalizeRedditPermalink(url)
            linkHTML = "<a href=\"\(normalized)\" class=\"post-link\" target=\"_blank\">View Post →</a>"
        } else {
            linkHTML = ""
        }

        return """
        <div class="key-post">
            <div class="post-title">\(title)</div>
            <div class="post-why">\(why)</div>
            \(linkHTML)
        </div>
        """
    }.joined()

    return """
    <div class="wb-section key-posts">
        <div class="section-header">📌 Key Posts</div>
        \(itemsHTML)
    </div>
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

## Part 6: URL Normalization

Critical for working Reddit links:

```swift
private func normalizeRedditPermalink(_ permalink: String) -> String {
    var cleaned = permalink.trimmingCharacters(in: .whitespacesAndNewlines)

    // If already full URL, return as-is
    if cleaned.hasPrefix("http://") || cleaned.hasPrefix("https://") {
        return cleaned
    }

    // If starts with /r/, prepend reddit.com
    if cleaned.hasPrefix("/r/") {
        return "https://www.reddit.com\(cleaned)"
    }

    // If starts with r/, prepend reddit.com/
    if cleaned.hasPrefix("r/") {
        return "https://www.reddit.com/\(cleaned)"
    }

    // Otherwise, assume it's a relative path
    if cleaned.hasPrefix("/") {
        return "https://www.reddit.com\(cleaned)"
    } else {
        return "https://www.reddit.com/\(cleaned)"
    }
}
```

---

## Part 7: Complete Generation Function

```swift
private func generateWhiteboard() {
    guard !isGeneratingWhiteboard else { return }

    isGeneratingWhiteboard = true
    whiteboardError = nil

    // Build content summary
    let content = viewModel.batchSummaries.enumerated().map { index, summary in
        let title = summary.postTitle.isEmpty ? "Post \(index + 1)" : summary.postTitle
        let truncatedContent = String(summary.content.prefix(2000))
        return "[\(index + 1)] \"\(title)\"\n\(truncatedContent)\n"
    }.joined(separator: "\n---\n")

    // Build URL reference list
    let urlReferenceList = viewModel.batchSummaries.enumerated().map { (index, summary) in
        let url = normalizeRedditPermalink(summary.permalink)
        return "[\(index + 1)] \"\(summary.postTitle)\" → \(url)"
    }.joined(separator: "\n")

    let prompt = makeWhiteboardPrompt(from: content, urlReference: urlReferenceList)

    Task {
        do {
            // Call your LLM API (example with Gemini)
            let model = GenerativeModel(name: "gemini-1.5-flash-002", apiKey: geminiAPIKey)
            let response = try await model.generateContent(prompt)

            guard let text = response.text else {
                await MainActor.run {
                    self.whiteboardError = "No response from AI"
                    self.isGeneratingWhiteboard = false
                }
                return
            }

            // Parse payload
            guard let payload = parseWhiteboardPayload(from: text) else {
                await MainActor.run {
                    self.whiteboardError = "Failed to parse whiteboard data"
                    self.isGeneratingWhiteboard = false
                }
                return
            }

            // Build HTML
            let html = buildWhiteboardHTML(from: payload)

            // Convert to Data
            guard let htmlData = html.data(using: .utf8) else {
                await MainActor.run {
                    self.whiteboardError = "Failed to generate whiteboard"
                    self.isGeneratingWhiteboard = false
                }
                return
            }

            // Update UI
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

---

## Part 8: UI Integration

### Button in View

```swift
var body: some View {
    VStack {
        // ... your content ...

        HStack {
            // Other buttons...

            Button(action: {
                generateWhiteboard()
            }) {
                Group {
                    if isGeneratingWhiteboard {
                        ProgressView()
                            .scaleEffect(0.8)
                    } else {
                        Text("WB")
                            .font(.headline)
                            .fontWeight(.bold)
                    }
                }
            }
            .buttonStyle(LiquidGlassButtonStyle(isProminent: true))
            .disabled(isGeneratingWhiteboard || batchSummaries.isEmpty)
        }

        // Error display
        if let whiteboardError {
            Text(whiteboardError)
                .font(.caption)
                .foregroundColor(.red)
        }
    }
    // Sheet presentation
    .fullScreenCover(isPresented: $showWhiteboard) {
        InfographicView(
            htmlData: whiteboardContent,
            title: "Whiteboard",
            filePrefix: "whiteboard",
            loadingLabel: "Rendering whiteboard…",
            emptyLabel: "Unable to load whiteboard"
        )
        .interactiveDismissDisabled(false)
    }
}
```

---

## Part 9: InfographicView (Reusable Viewer)

The InfographicView is reused for both infographic and whiteboard display:

```swift
struct InfographicView: View {
    let htmlData: Data?
    var title: String = "Infographic"
    var filePrefix: String = "infographic"
    var loadingLabel: String? = nil
    var emptyLabel: String? = nil

    @Environment(\.dismiss) var dismiss
    @State private var isLoading = true
    @State private var webViewRef: WKWebView?
    @State private var isSaving = false
    @State private var isCapturingSnapshot = false
    @State private var saveMessage: String?
    @State private var shareURL: URL?
    @State private var showShareSheet = false

    private var loadingText: String {
        loadingLabel ?? "Rendering \(title.lowercased())…"
    }

    private var emptyText: String {
        emptyLabel ?? "Unable to load \(title.lowercased())"
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                if let data = htmlData,
                   let htmlString = String(data: data, encoding: .utf8) {
                    ZStack {
                        WebView(
                            htmlContent: htmlString,
                            webView: $webViewRef,
                            isLoading: $isLoading
                        )
                        .edgesIgnoringSafeArea(.bottom)

                        if isLoading {
                            ProgressView(loadingText)
                                .padding(12)
                                .background(.ultraThinMaterial)
                                .cornerRadius(12)
                        }
                    }
                    .edgesIgnoringSafeArea(.bottom)
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.largeTitle)
                            .foregroundColor(.secondary)
                        Text(emptyText)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button(action: snapshotAndCopyImage) {
                        Label("Copy Image", systemImage: "square.on.square")
                    }
                    .disabled(htmlData == nil || webViewRef == nil || isLoading)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button(action: snapshotAndSaveImage) {
                        Label("Save Image", systemImage: "arrow.down.doc")
                    }
                    .disabled(htmlData == nil || webViewRef == nil || isLoading || isSaving)
                }
            }
            .overlay(alignment: .bottom) {
                if let message = saveMessage {
                    Text(message)
                        .font(.caption)
                        .padding(8)
                        .background(.ultraThinMaterial)
                        .cornerRadius(8)
                        .padding(.bottom, 20)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .onAppear {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                withAnimation { saveMessage = nil }
                            }
                        }
                }
            }
            .sheet(isPresented: $showShareSheet, onDismiss: { shareURL = nil }) {
                if let shareURL {
                    ShareSheet(activityItems: [shareURL])
                        .presentationDetents([.medium, .large])
                }
            }
        }
    }

    // Snapshot functions (see iOS implementation for full code)
    private func snapshotAndCopyImage() { /* ... */ }
    private func snapshotAndSaveImage() { /* ... */ }
}
```

---

## Part 10: WebView with Link Handling

```swift
#if os(iOS)
struct WebView: UIViewRepresentable {
    let htmlContent: String
    @Binding var webView: WKWebView?
    @Binding var isLoading: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.preferences.javaScriptEnabled = false
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear

        DispatchQueue.main.async {
            self.webView = webView
        }

        context.coordinator.lastHTML = htmlContent
        webView.loadHTMLString(htmlContent, baseURL: nil)
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        guard context.coordinator.lastHTML != htmlContent else { return }
        context.coordinator.lastHTML = htmlContent
        uiView.loadHTMLString(htmlContent, baseURL: nil)
    }

    class Coordinator: NSObject, WKNavigationDelegate {
        var parent: WebView
        var lastHTML: String?

        init(parent: WebView) {
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

        // CRITICAL: Handle link clicks
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            // Allow initial HTML load
            if navigationAction.navigationType == .other {
                decisionHandler(.allow)
                return
            }

            // Open links in Safari
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

---

## Testing Checklist

- [ ] Whiteboard generates with correct sections
- [ ] Links open in Safari (not broken)
- [ ] Visual style looks like sticky notes/whiteboard
- [ ] Responsive on different screen sizes
- [ ] Copy to clipboard works
- [ ] Save as image works
- [ ] Error handling displays properly
- [ ] Loading states show correctly
- [ ] No XSS vulnerabilities (HTML escaping works)
- [ ] Works on both iPhone and iPad

---

## Common Issues & Solutions

### Issue: Links don't work
**Solution**: Ensure you're building and using the `urlReferenceList` in the prompt, and the LLM is copying exact URLs from the reference list.

### Issue: LLM returns invalid JSON
**Solution**: Add cleanup logic in `parseWhiteboardPayload` to remove markdown code blocks.

### Issue: Visual style looks broken
**Solution**: Verify all CSS is included and grid paper background is rendering.

### Issue: WebView shows blank
**Solution**: Check that `htmlData` is valid UTF-8 and the WebView configuration allows the content.

### Issue: Snapshot fails
**Solution**: Ensure WebView has finished loading (`isLoading = false`) before attempting snapshot.

---

## Dependencies

- **SwiftUI**: UI framework
- **WebKit**: For WKWebView rendering
- **Google Generative AI SDK**: For LLM integration
- Your custom UI components (LiquidGlassButtonStyle, etc.)

---

## Performance Considerations

1. **Content Truncation**: Limit each post to 2000 characters to avoid token limits
2. **Async/Await**: Use Task for LLM calls to avoid blocking UI
3. **Snapshot Size**: Large whiteboards may take time to snapshot
4. **Memory**: Release `whiteboardContent` when dismissed if needed

---

## Security Notes

1. **HTML Escaping**: Always escape user content before inserting into HTML
2. **JavaScript Disabled**: WebView has JS disabled for security
3. **URL Validation**: Normalize and validate Reddit URLs
4. **XSS Prevention**: Never trust LLM output without escaping

---

## License

This implementation guide is based on the Reddit App whiteboard feature. Adapt as needed for your use case.
