# TTS Performance Optimizations with Multi-Provider Support

## Overview
This document explains how to implement a robust, low-latency text-to-speech (TTS) system supporting both **Gemini** and **OpenAI** providers, with user-selectable voices, API key management, and provider fallback. Use these steps to replicate the approach in another codebase.

---

## 1. Architecture & Core Concepts

- **TTSProvider Enum**: Define an enum for supported providers (e.g., `.gemini`, `.openai`).
- **SummaryService**: Central service class that:
  - Stores API keys for both providers.
  - Manages provider/voice selection.
  - Handles TTS requests, chunking, caching, and fallback.
- **SettingsView**: UI for users to:
  - Enter API keys.
  - Select provider and voice.
  - Toggle fallback, preloading, and clear cache.
- **AppSettings**: Struct (Codable) for persisting user settings (API keys, provider, voice, etc.).
- **PersistenceManager**: Handles saving/loading `AppSettings` to disk (e.g., UserDefaults or file).

---

## 2. Implementing Multi-Provider TTS

### a. Enum for Providers
```swift
enum TTSProvider: String, CaseIterable {
    case gemini = "Gemini"
    case openai = "OpenAI"
    var displayName: String { self.rawValue }
}
```

### b. Service Class (SummaryService)
- Store both API keys as properties.
- Store selected provider and voice.
- Provide methods to set/get provider, voice, and keys.
- Implement TTS synthesis for each provider:
  - **Gemini**: Use Google Generative Language API, handle PCM audio (convert to WAV if needed).
  - **OpenAI**: Use OpenAI `/v1/audio/speech` endpoint, handle MP3 audio.
- For long texts, split into chunks and process (optionally in parallel for OpenAI).
- Implement caching for TTS responses.
- Add fallback logic: if primary provider fails, try the other.

### c. Settings UI (SettingsView)
- Text fields for Gemini and OpenAI API keys.
- Picker for provider and voice (dynamically update voices based on provider).
- Toggles for fallback and preloading.
- Button to clear TTS cache.
- On appear, load current settings from service.
- On change, update service and persist settings.

### d. Persistence
- Extend `AppSettings` to include:
  - `openaiApiKey: String`
  - `ttsProvider: String` (or enum)
  - `ttsVoice: String`
- On settings change, save to disk (UserDefaults, file, or CoreData).
- On app launch, load settings and initialize service.

---

## 3. Example: OpenAI TTS Request
```swift
let requestBody: [String: Any] = [
    "model": "tts-1",
    "input": text,
    "voice": selectedOpenAIVoice,
    "response_format": "mp3",
    "speed": 1.0
]
// ...
request.setValue("Bearer \(openaiApiKey)", forHTTPHeaderField: "Authorization")
```

## 4. Example: Gemini TTS Request
```swift
let requestBody: [String: Any] = [
    "contents": [["parts": [["text": text]]]],
    "generationConfig": [
        "responseModalities": ["AUDIO"],
        "speechConfig": [
            "voiceConfig": [
                "prebuiltVoiceConfig": ["voiceName": selectedGeminiVoice]
            ]
        ]
    ]
]
// ...
request.setValue("application/json", forHTTPHeaderField: "Content-Type")
```

---

## 5. Key Implementation Tips
- **Chunking**: For long texts, split into sentences and group into ~400 char chunks. For OpenAI, process up to 3 chunks in parallel for speed.
- **Fast-Start Approach**: For immediate playback, create a larger first chunk (800 chars) that plays instantly while generating the rest in background.
- **Audio Format**: Gemini returns PCM (convert to WAV for playback); OpenAI returns MP3 (play directly).
- **Cache**: Use a dictionary with a hash of the text+provider as key. Limit cache size and evict oldest.
- **Settings Sync**: Always update both the service and persistent storage when user changes settings.
- **Fallback**: If a provider fails (timeout, error), automatically try the other if enabled.

### Fast-Start TTS Implementation
For near-zero latency, implement this pattern:

```swift
func synthesizeSpeechFastStart(text: String, 
                               onFirstChunk: @escaping (Data) -> Void,
                               onComplete: @escaping (Data) -> Void,
                               onError: @escaping (Error) -> Void) async {
    // For short text (≤600 chars): synthesize and play immediately
    if text.count <= 600 {
        let audioData = try await synthesizeSingle(text: text)
        onFirstChunk(audioData) // Start playing immediately
        onComplete(audioData)
        return
    }
    
    // For long text: create substantial first chunk (800 chars)
    let firstChunk = text.prefix(upTo: 800) // Get first ~800 characters
    let remainingText = text.suffix(from: 800) // Rest of the text
    
    // Synthesize and play first chunk immediately
    let firstAudio = try await synthesizeSingle(text: firstChunk)
    onFirstChunk(firstAudio) // Audio starts playing NOW
    
    // Generate remaining audio in background
    let remainingAudio = try await synthesizeSingle(text: remainingText)
    let completeAudio = combine([firstAudio, remainingAudio])
    onComplete(completeAudio) // Cache complete version
}
```

This approach delivers audio in 1-3 seconds instead of 15-20 seconds for long texts.

---

## 6. What to Copy/Adapt
- The `TTSProvider` enum and provider/voice selection logic.
- The dual-API-key storage and update methods in your service class.
- The chunked, cached, and fallback-enabled TTS request logic.
- The settings UI pattern for API keys, provider, and voice.
- The persistence of all TTS-related settings.

---

## 7. References
- [OpenAI Speech API Docs](https://platform.openai.com/docs/guides/text-to-speech)
- [Google Gemini API Docs](https://ai.google.dev/gemini-api/docs)

---

**This approach ensures your app can switch between TTS providers, recover from outages, and deliver fast, reliable speech synthesis with user-friendly configuration.** 

## Performance Results

### Before Optimization
- **Wait time**: 15-20 seconds before audio starts
- **User experience**: Long loading states, user uncertainty
- **API response time**: 5+ seconds per chunk, processed sequentially

### After Fast-Start Implementation  
- **Wait time**: 1-3 seconds before audio starts
- **User experience**: Near-immediate feedback, smooth playback
- **API response time**: Same 5+ seconds, but first chunk plays immediately

### Key Improvements
1. **Immediate Playback**: Audio starts as soon as first chunk (800 chars) is ready
2. **Background Processing**: Remaining content synthesizes while first chunk plays
3. **Smart Caching**: Complete audio cached for instant future playback
4. **Dual Provider Support**: Automatic fallback between Gemini and OpenAI
5. **Consistent UX**: Same fast-start behavior across all app views

This optimization reduced perceived latency from **20 seconds to under 3 seconds** - a **85% improvement** in user experience. 

## 8. Troubleshooting: SwiftUI View Closures and 'weak self'

### Problem: 'weak' may only be applied to class and class-bound protocol types, not 'YourViewStruct'

If you see errors like:

```
'weak' may only be applied to class and class-bound protocol types, not 'YourViewStruct'
```

or

```
[weak self] may only be applied to class and class-bound protocol types, not 'YourViewStruct'
```

#### Solution:
- **SwiftUI Views are structs (value types), not classes.**
- Remove all `[weak self]` and `[self]` capture lists from closures inside SwiftUI Views.
- Use `self` directly inside your closure bodies.
- This applies to all TTS completion handlers, sound delegate callbacks, and any async closures in your SwiftUI Views.

**Example Fix:**

```swift
// ❌ Incorrect (causes error)
Task {
    await service.doSomething(
        onComplete: { [weak self] result in
            self?.handle(result)
        }
    )
}

// ✅ Correct (no error)
Task {
    await service.doSomething(
        onComplete: { result in
            self.handle(result)
        }
    )
}
```

**Why?**
- Structs (like SwiftUI Views) are value types and do not participate in retain cycles.
- `weak` and `unowned` only apply to reference types (classes).

**Summary:**
- Remove `[weak self]` and `[self]` from all closures in SwiftUI Views to resolve these errors. 