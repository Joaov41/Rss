# RSS Reader App - LLM Prompts

This document contains all the prompts used in the app for interacting with the Gemini API.

## SummaryService - Default Prompt

```swift
// Default prompt for article summarization
prompt = "Summarize the following text in a concise way, highlighting the key points: \(text)"
```

## Article Summarization

```swift
// Create a customized prompt for article summarization
let articlePrompt = "Summarize the following article, highlighting the key points, main arguments, and important conclusions. Focus on providing a concise overview that captures the essential information:\n\n\(article.content)"
```

## Reddit Post Summarization

```swift
// Create a customized prompt for Reddit post summarization
let redditPostPrompt = "Summarize the following Reddit post, highlighting the main question or discussion topic, key points made by the author, and any important context provided. Focus on creating a concise and informative summary that captures the essence of the post:\n\n\(post.content)"
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