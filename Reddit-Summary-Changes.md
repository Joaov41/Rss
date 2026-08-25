# Reddit Summary Implementation Changes

## Overview
This document explains the recent changes made to improve Reddit and article summarization across three different contexts in the RSS Reader app. Each summary type now sends more complete data to the LLM for better context and more accurate summaries.

## Summary Types and Changes

### 1. Individual Reddit Post Summaries
**Location**: `AppState.swift` - `summarizeRedditPost()` function  
**Triggered**: When user presses the "Summarize" button while viewing a single Reddit post

#### What it does:
Summarizes a single Reddit post including its title, content, and ALL comments (including nested replies).

#### Data sent to LLM:
- **Post Title**: Full title
- **Post Content**: Full post text (no truncation)
- **Comments**: ALL comments including nested replies, extracted recursively using `extractAllCommentTexts()`

#### Changes Made:
```swift
// BEFORE: Comments weren't being passed through
func summarizeRedditPost(_ post: RedditPost) {
    // Comments were not included in the summary
}

// AFTER: Now accepts and uses all comments
func summarizeRedditPost(_ post: RedditPost, comments: [RedditCommentModel] = []) {
    // Extract all comment texts recursively (includes nested)
    let commentTexts = comments.flatMap { extractAllCommentTexts(from: $0) }
    let combinedComments = commentTexts.joined(separator: "\n\n")
    
    let redditPostPrompt = """
    Reddit Post Title: \(post.title)
    Post Content:
    \(post.content)
    
    Comments:
    \(combinedComments)
    
    Provide a concise, 3 paragraph summary maximum...
    """
}
```

**Key Feature**: Uses `extractAllCommentTexts()` to recursively get ALL nested comments, not just top-level ones.

---

### 2. Subreddit-Wide Summaries
**Location**: `AppState.swift` - `GlobalSummaryService.summarizeRedditGlobally()`  
**Triggered**: When user presses the summary button while viewing a subreddit feed

#### What it does:
Summarizes multiple Reddit posts from a subreddit, including top comments from each post.

#### Data sent to LLM:
- **Post Title**: Full title for each post
- **Post Content**: Full post text (NO TRUNCATION - previously limited to 2000 chars)
- **Top Comments**: Top 10 top-level comments per post, sorted by score
  - Full comment text (NO TRUNCATION - previously limited to 200 chars)
  - Only top-level comments (no nested replies)

#### Changes Made:
```swift
// BEFORE: Posts and comments were truncated
let payload: [RedditPayloadItem] = ordered.map { triple in
    let truncatedComments = triple.topLevel.map { 
        "u/\($0.author): \(firstNChars($0.body, 200))"  // Was truncated to 200 chars
    }
    return RedditPayloadItem(
        title: triple.post.title,
        postText: firstNChars(triple.post.content, 2000),  // Was truncated to 2000 chars
        topComments: truncatedComments
    )
}

// AFTER: Full content sent
let payload: [RedditPayloadItem] = ordered.map { triple in
    let fullComments = triple.topLevel.map { 
        "u/\($0.author): \($0.body)"  // Full comment text
    }
    return RedditPayloadItem(
        title: triple.post.title,
        postText: triple.post.content,  // Full post content
        topComments: fullComments
    )
}
```

**Important Notes**:
- Still limited to top 10 top-level comments (sorted by score)
- Does NOT include nested replies
- Sends complete text for better context

---

### 3. Today View Summaries
**Location**: `AppState.swift` - `buildTodaySummaryPrompt()`  
**Triggered**: When user presses the summary button in the "Today" view

#### What it does:
Creates a clustered summary of today's content, grouping RSS articles and Reddit posts by topic.

#### Data sent to LLM:

**RSS Articles**:
- **Title**: Full title
- **Content**: Full article content (NO LIMIT - previously 320 chars)

**Reddit Posts**:
- **Title**: Full title
- **Post Content**: Up to 2000 characters (increased from 280 chars)
- **Top Comments**: Top 10 top-level comments, up to 1000 chars each (increased from 220 chars)

#### Changes Made:
```swift
// ARTICLES - BEFORE: Limited to 320 characters
let excerpt = previewText(from: source, maxCharacters: 320)

// ARTICLES - AFTER: No limit
let excerpt = previewText(from: source)  // No limit for articles

// REDDIT POSTS - BEFORE: 280 character snippet
let postSnippet = previewText(from: post.content, maxCharacters: 280)

// REDDIT POSTS - AFTER: 2000 character snippet
let postSnippet = previewText(from: post.content, maxCharacters: 2000)

// COMMENTS - BEFORE: 220 characters per comment
let body = previewText(from: comment.body, maxCharacters: 220)

// COMMENTS - AFTER: 1000 characters per comment
let body = previewText(from: comment.body, maxCharacters: 1000)
```

**Purpose**: The Today view clusters topics from multiple sources, so it needs enough context to accurately group related content while balancing token usage.

---

## Summary Comparison Table

| Feature | Individual Post | Subreddit-Wide | Today View |
|---------|----------------|----------------|------------|
| **Scope** | Single post | Multiple posts | Today's RSS + Reddit |
| **Post Title** | Full | Full | Full |
| **Post Content** | Full | Full | 2000 chars |
| **Article Content** | N/A | N/A | Full |
| **Comments Included** | ALL (nested) | Top 10 top-level | Top 10 top-level |
| **Comment Truncation** | None | None | 1000 chars each |
| **Use Case** | Deep dive into one discussion | Overview of subreddit activity | Daily content clustering |

## Key Functions

### `extractAllCommentTexts()`
Recursively extracts all comment text including nested replies:
```swift
func extractAllCommentTexts(from comment: RedditCommentModel) -> [String] {
    var texts: [String] = []
    texts.append("u/\(comment.author): \(comment.body)")
    
    // Recursively get all nested replies
    for reply in comment.replies {
        texts.append(contentsOf: extractAllCommentTexts(from: reply))
    }
    
    return texts
}
```

### `requestSummary()`
Updated to pass comments through to the appropriate summary function:
```swift
func requestSummary(for article: Article?, 
                   redditPost: RedditPost? = nil, 
                   redditComments: [RedditCommentModel] = []) {
    if let post = redditPost {
        summarizeRedditPost(post, comments: redditComments)
    }
    // ... rest of function
}
```

## Token Optimization Considerations

The changes balance between providing complete context and managing token usage:

1. **Individual Posts**: No limits since it's a single post - full context is valuable
2. **Subreddit-Wide**: Full post content but only top 10 comments to manage multiple posts
3. **Today View**: Moderate limits (2000/1000 chars) since it processes many items from multiple sources

## Implementation Notes

- All changes maintain backward compatibility
- The `previewText()` function handles truncation when limits are specified
- Comment sorting by score ensures most relevant comments are included
- Recursive comment extraction only used for individual posts to avoid token explosion