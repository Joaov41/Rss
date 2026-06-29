# RSS Reader App - LLM Prompts

This document contains all the prompts used in the app for interacting with the Gemini API.

## SummaryService - Default Prompt

```swift
// Default prompt for article summarization
prompt = "Provide a brief 2-3 sentence summary of the following text, capturing only the most essential points: \(text)"
```

## Article Summarization

```swift
// Create a customized prompt for article summarization
let articlePrompt = "Provide a brief 3-4 sentence summary of this article. Include only the main point and most important conclusion. Keep it under 100 words:\n\n\(article.content)"
```

## Reddit Post Summarization

```swift
// Create a customized prompt for Reddit post summarization
let redditPostPrompt = "Provide a brief 2-3 sentence summary of this Reddit post. State the main question/topic and key point. Keep it under 75 words:\n\n\(post.content)"
```

## Reddit Comments Summarization

```swift
// Create a customized prompt for Reddit comments instead of using the generic article prompt
let redditCommentsPrompt = "Summarize the following Reddit discussion thread, highlighting key opinions, consensus views, and any significant disagreements. Focus on the main topics being discussed:\n\n\(combinedText)"
```

## Article Q&A

```swift
let prompt = """
Article Title: \(article.title)
Article Content:
\(article.content)

Based solely on the information in the article above, please answer the following question:
\(question)

If the answer cannot be determined from the article, please state that the information is not available in the article.
"""
```

## Reddit Post Q&A

```swift
let prompt = """
Reddit Post Title: \(post.title)
Post Content:
\(post.content)

Comments:
\(combinedComments)

Based solely on the information in the Reddit post and comments above, please answer the following question:
\(question)

If the answer cannot be determined from the post or comments, please state that the information is not available.
"""
``` 