# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a cross-platform RSS/Reddit reader app built with SwiftUI for iOS, iPadOS, and macOS. The app features RSS feed reading, Reddit browsing, AI-powered summaries, and text-to-speech capabilities.

## Build Commands

This is an Xcode project. To build and run:

```bash
# Open in Xcode
open RSSReaderApp.xcodeproj

# Build from command line (iOS)
xcodebuild -scheme "RSSReaderApp (iOS)" -destination "platform=iOS Simulator,name=iPhone 15"

# Build from command line (macOS) 
xcodebuild -scheme "RSSReaderApp (macOS)"
```

## Architecture

### Core Architecture Pattern
- **MVVM with Centralized State**: Uses `AppState` as a single source of truth with `@StateObject`
- **Service Layer**: Each external integration has its own service class
- **Platform-Specific Views**: Separate view implementations for iOS, iPadOS, and macOS

### Key Services
- **FeedService**: Handles RSS feed parsing and fetching
- **RedditService**: Reddit API integration for posts and comments
- **SummaryService**: AI summaries using Gemini or OpenAI APIs
- **CommentSummaryService**: Specialized service for Reddit comment summaries
- **PersistenceManager**: UserDefaults-based storage for settings and feed URLs

### View Architecture
- **MainSplitView**: Primary navigation structure with platform-specific layouts
- **ContentView**: Main content display with article/post rendering
- **Platform-specific behaviors**: Different navigation styles and layouts for iOS vs iPad vs macOS

### AI Integration
- Supports both Gemini and OpenAI APIs for summaries
- Prompts defined in `prompts.md`
- TTS implementation with fast-start optimization (see `TTS_OPTIMIZATION_README.md`)

## Important Implementation Details

### API Keys
API keys are stored in UserDefaults via SettingsView. Never hardcode API keys.

### Text-to-Speech
The app implements an optimized TTS system with:
- Multi-provider support (Gemini/OpenAI)
- Sentence-based chunking for fast audio start
- Background audio session handling
- See `TTS_OPTIMIZATION_README.md` for implementation details

### Reddit Integration  
- Uses official Reddit API endpoints
- Handles both posts and comments
- Special parsing for Reddit's JSON structure

### State Management
All app state flows through `AppState` which is passed as an `@StateObject` to views. This includes:
- Current feeds and items
- Selected items
- Loading states
- Error handling