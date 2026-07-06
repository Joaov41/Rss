# Markdown Artifact Removal: Implementation Notes

## Goal
Remove visible Markdown symbols (like `##`, `**`, `_`, and code fences) from AI-generated summaries and deep-analysis text in the app UI.

## Approach Used
This was implemented as a **two-layer fix**:

1. **Prompt-level guidance**
- Prompts were updated to request plain text output (no Markdown symbols).
- This reduces the chance of bad formatting, but does not guarantee it.

2. **Post-generation sanitization**
- A shared text cleaner removes Markdown artifacts before content is stored/displayed.
- This guarantees clean output even when the model ignores prompt instructions.

## Why Prompt-Only Was Not Enough
Even with strict instructions, model outputs can drift and still include headings/bold markers.
So the sanitizer is the enforcement layer.

## Core Cleaner
Added in:
- `RSSReaderApp/Controllers/AppState.swift` (`cleanMarkdownArtifactsForDisplay`)

This function normalizes newlines and strips:
- Heading markers (`#`)
- Bold/italic markers (`**`, `*`, `_`, `__`)
- Inline code markers (`` ` ``)
- Code fences (```...```)
- Extra blank lines

## Where It Was Applied

### 1) Article + Reddit post summaries
Sanitization added before assigning summary text in:
- `RSSReaderApp/Controllers/AppState.swift`
  - `summarizeArticle`
  - `summarizeRedditPost`
  - `updateArticleSummaryFromCloud`
  - `updateRedditPostSummaryFromCloud`

### 2) Comment summaries
Prompt changed to plain text and output cleaned in:
- `RSSReaderApp/Services/CommentSummaryService.swift`
- `RSSReaderApp/Views/RedditDetailView.swift` (provider-specific comment summary flows)

### 3) Deep Analysis (thematic analysis)
Prompt changed to plain text and output cleaned before assigning `thematicAnalysis` in:
- `RSSReaderApp/Views/RedditDetailView.swift`

### 4) Global / overview summary
Aggregate prompt format was changed away from Markdown headings, and aggregate output already goes through formatter/sanitization logic in:
- `RSSReaderApp/Controllers/AppState.swift`

### 5) iPad code paths
Equivalent changes were mirrored in:
- `ipad/RSSReaderApp/Controllers/AppState.swift`
- `ipad/RSSReaderApp/Services/CommentSummaryService.swift`
- `ipad/RSSReaderApp/Views/RedditDetailView.swift`

## Result
Formatting artifacts are now handled by:
- **Prevention** (prompt instructions)
- **Enforcement** (cleaner function)

This combination is what makes the fix reliable across article summaries, Reddit summaries, comment summaries, deep analysis, and overview output.

## If You Want Stronger Guarantees
Next step would be converting summary outputs to strict JSON schema responses and rendering from structured fields instead of raw model text.
