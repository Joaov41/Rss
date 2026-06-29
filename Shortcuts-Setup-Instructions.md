# RSS Reader Cloud Summary - Shortcut Setup Instructions

Your shortcut should have exactly these 2 actions:

## Updated Setup (No Clipboard Permission Prompts)

1. **Use Cloud model**
   - Input: **Shortcut Input** (this receives the article text directly from RSS Reader)
   - The app already adds a prompt asking for a paragraph summary

2. **Copy to Clipboard**
   - Content: Output from "Use Cloud model" action

That's it! Just 2 actions.

## How it works:

1. RSS Reader sends the article text directly to your shortcut (no clipboard needed for input)
2. Your shortcut processes it with Apple's Cloud AI
3. The summary is copied to clipboard
4. RSS Reader detects the clipboard change and shows the summary

## Important:

- Do NOT use "Get Clipboard" action (this causes permission prompts)
- The input comes as "Shortcut Input" automatically
- Make sure your shortcut can receive text input

## Benefits:

- No clipboard permission prompts
- Cleaner, simpler shortcut
- Text is limited to 10,000 characters to avoid errors
- Includes prompt for paragraph-length summaries