# macOS Shortcuts TTS Implementation Tutorial

## How Local TTS Was Implemented on Mac Using Shortcuts

This tutorial documents the complete implementation of local Text-to-Speech (TTS) on macOS using Apple Shortcuts, as implemented in the RSS Reader app. This approach allows iOS apps running on Mac to access macOS's superior TTS voices through the Shortcuts app.

## Table of Contents
1. [Overview](#overview)
2. [The Problem](#the-problem)
3. [The Solution: ShortcutsTTS](#the-solution-shortcuttstts)
4. [Complete Implementation Code](#complete-implementation-code)
5. [How It Works](#how-it-works)
6. [Setting Up the Shortcut](#setting-up-the-shortcut)
7. [Integration in Your App](#integration-in-your-app)
8. [Technical Details](#technical-details)
9. [Limitations and Workarounds](#limitations-and-workarounds)
10. [Troubleshooting](#troubleshooting)

## Overview

When running iOS apps on Mac (via Mac Catalyst or "Designed for iPad"), the iOS AVSpeechSynthesizer voices often sound robotic or have compatibility issues. This implementation bypasses these limitations by using macOS Shortcuts to access the native macOS TTS system, which includes premium voices like Ava, Alex, and enhanced Samantha.

## The Problem

iOS apps running on Mac face several TTS challenges:
- iOS voices (AVSpeechSynthesizer) sound robotic on Mac
- Some iOS voice identifiers (`com.apple.voice.*`) don't work on Mac
- Premium macOS voices aren't accessible through iOS APIs
- NSSpeechSynthesizer isn't available in iOS apps

## The Solution: ShortcutsTTS

The `ShortcutsTTS` class provides a bridge to macOS's native TTS system through the Shortcuts app using URL schemes.

## Complete Implementation Code

Here's the actual implementation from `SummaryService.swift`:

```swift
// MARK: - Shortcuts TTS Helper for iOS on Mac
// This helper provides TTS functionality via macOS Shortcuts when running as an iPad app on Mac
// Available for both iOS and macOS targets (but only functional on iOS when running on Mac)
public class ShortcutsTTS {
    public static let shared = ShortcutsTTS()
    private let shortcutName = "Speak Text RSS"
    
    private init() {}
    
    /// Speaks text using macOS Shortcuts when running as iPad app on Mac
    /// - Parameters:
    ///   - text: The text to speak
    ///   - completion: Called when speech completes or fails
    @discardableResult
    public func speakText(_ text: String, completion: (() -> Void)? = nil) -> Bool {
        guard !text.isEmpty else {
            print("🔊 [ShortcutsTTS] Empty text, skipping")
            completion?()
            return false
        }
        
        #if os(iOS)
        // Check if we're running on Mac
        guard ProcessInfo.processInfo.isiOSAppOnMac else {
            print("🔊 [ShortcutsTTS] Not running on Mac, skipping")
            completion?()
            return false
        }
        
        // Encode the shortcut name and text properly
        guard let encodedName = shortcutName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let encodedText = text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            print("🔊 [ShortcutsTTS] Failed to encode text or name")
            completion?()
            return false
        }
        
        // Try x-callback-url format which is more reliable
        // This format tends to actually run the shortcut rather than just opening the app
        let urlString = "shortcuts://x-callback-url/run-shortcut?name=\(encodedName)&input=\(encodedText)"
        
        print("🔊 [ShortcutsTTS] Shortcut name: '\(shortcutName)'")
        print("🔊 [ShortcutsTTS] Encoded name: '\(encodedName)'")
        print("🔊 [ShortcutsTTS] Text preview: '\(String(text.prefix(50)))...'")
        print("🔊 [ShortcutsTTS] Full URL: \(urlString)")
        
        guard let url = URL(string: urlString) else {
            print("🔊 [ShortcutsTTS] Failed to create shortcuts URL")
            completion?()
            return false
        }
        
        // Open the URL to run the shortcut
        UIApplication.shared.open(url, options: [:]) { success in
            if success {
                print("🔊 [ShortcutsTTS] Launched shortcut successfully")
                // Call completion after a delay (we can't track when speech finishes)
                // Estimate based on text length
                let words = text.split(separator: " ").count
                let estimatedDuration = Double(words) / 150.0 * 60.0 // ~150 words per minute
                let delay = min(max(estimatedDuration, 2.0), 30.0) // Between 2-30 seconds
                
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    completion?()
                }
            } else {
                print("🔊 [ShortcutsTTS] Failed to launch shortcut")
                completion?()
            }
        }
        
        return true
        #else
        // On macOS, this doesn't do anything
        print("🔊 [ShortcutsTTS] Not available on macOS")
        completion?()
        return false
        #endif
    }
    
    /// Stops any current speech
    /// Note: We can't actually stop shortcuts once launched via URL scheme
    public func stopSpeaking() {
        // Could potentially open a "stop" shortcut if you create one
        print("🔊 [ShortcutsTTS] Stop not available with URL scheme")
    }
    
    /// Checks if currently speaking
    public var isSpeaking: Bool {
        // We can't track speaking state with URL scheme
        return false
    }
}
```

## How It Works

### 1. Platform Detection
The implementation first checks if the iOS app is running on Mac:
```swift
guard ProcessInfo.processInfo.isiOSAppOnMac else {
    print("🔊 [ShortcutsTTS] Not running on Mac, skipping")
    completion?()
    return false
}
```

### 2. URL Scheme Construction
It uses the `x-callback-url` format for better reliability:
```swift
let urlString = "shortcuts://x-callback-url/run-shortcut?name=\(encodedName)&input=\(encodedText)"
```

Key components:
- `shortcuts://` - Opens the Shortcuts app
- `x-callback-url/run-shortcut` - Runs a specific shortcut
- `name=` - The shortcut name (URL encoded)
- `input=` - The text to speak (URL encoded)

### 3. URL Encoding
Text and shortcut name must be properly encoded:
```swift
guard let encodedName = shortcutName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
      let encodedText = text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
    print("🔊 [ShortcutsTTS] Failed to encode text or name")
    completion?()
    return false
}
```

### 4. Execution
The shortcut is launched using UIApplication:
```swift
UIApplication.shared.open(url, options: [:]) { success in
    if success {
        print("🔊 [ShortcutsTTS] Launched shortcut successfully")
        // Handle completion...
    }
}
```

### 5. Duration Estimation
Since we can't track when speech finishes, duration is estimated:
```swift
let words = text.split(separator: " ").count
let estimatedDuration = Double(words) / 150.0 * 60.0 // ~150 words per minute
let delay = min(max(estimatedDuration, 2.0), 30.0) // Between 2-30 seconds
```

## Setting Up the Shortcut

### Step 1: Open Shortcuts App on Mac
1. Open the **Shortcuts** app on your Mac
2. Click the **+** button to create a new shortcut

### Step 2: Create the TTS Shortcut
Add the following actions to your shortcut:

1. **Receive Text Input**
   - Action: "Receive text input from Share Sheet"
   - This allows the shortcut to receive text from external apps

2. **Speak Text**
   - Action: "Speak"
   - Text: "Shortcut Input"
   - Voice: Choose your preferred voice (e.g., Ava, Alex, Samantha)
   - Rate: Adjust as needed
   - Pitch: 1.0 (default)

3. **Name the Shortcut**
   - Click on the shortcut name at the top
   - Rename it to exactly: `Speak Text RSS`
   - This name must match the `shortcutName` in the code

### Step 3: Configure Shortcut Settings
1. Click the settings icon (⚙️) for the shortcut
2. Enable "Use with Share Sheet"
3. Enable "Use with Quick Actions"
4. Add to Menu Bar if desired

## Integration in Your App

### Basic Usage
```swift
// Simple usage
ShortcutsTTS.shared.speakText("Hello, this is a test of the TTS system.")

// With completion handler
ShortcutsTTS.shared.speakText(articleText) {
    print("Finished speaking (estimated)")
}
```

### Integration with Existing TTS System
Here's how it was integrated with the existing TTS system in the RSS Reader app:

```swift
private func speakTextWithShortcuts(_ text: String) {
    #if os(iOS)
    if ProcessInfo.processInfo.isiOSAppOnMac {
        // Use Shortcuts TTS for better quality on Mac
        let success = ShortcutsTTS.shared.speakText(text) {
            // Handle completion
            self.isSpeaking = false
        }
        
        if success {
            self.isSpeaking = true
            return
        }
    }
    #endif
    
    // Fallback to regular iOS TTS
    speakTextLocally(text)
}
```

### Conditional Platform Usage
```swift
func shouldUseShortcutsTTS() -> Bool {
    #if os(iOS)
    return ProcessInfo.processInfo.isiOSAppOnMac
    #else
    return false
    #endif
}

func speakText(_ text: String) {
    if shouldUseShortcutsTTS() {
        ShortcutsTTS.shared.speakText(text)
    } else {
        // Use standard AVSpeechSynthesizer
        speakWithAVSpeech(text)
    }
}
```

## Technical Details

### URL Scheme Formats

The implementation uses the `x-callback-url` format for reliability:
```
shortcuts://x-callback-url/run-shortcut?name=SHORTCUT_NAME&input=TEXT_INPUT
```

Alternative formats (less reliable):
```
shortcuts://run-shortcut?name=SHORTCUT_NAME&text=TEXT_INPUT
shortcuts://open-shortcut?name=SHORTCUT_NAME
```

### Character Encoding
Special characters must be properly encoded:
- Spaces → `%20`
- Newlines → `%0A`
- Quotes → `%22`
- etc.

### Completion Timing Formula
```swift
// Words per minute (average speaking rate)
let wordsPerMinute = 150.0

// Calculate duration
let wordCount = text.split(separator: " ").count
let estimatedDuration = Double(wordCount) / wordsPerMinute * 60.0

// Apply bounds (2-30 seconds)
let delay = min(max(estimatedDuration, 2.0), 30.0)
```

## Limitations and Workarounds

### Limitations
1. **No Stop Control**: Can't stop speech once started via URL scheme
2. **No Progress Tracking**: Can't track speaking progress
3. **No State Detection**: Can't detect if currently speaking
4. **App Switching**: Opens Shortcuts app (may switch focus)
5. **Duration Estimation**: Completion time is estimated, not exact

### Workarounds

#### 1. Create a Stop Shortcut
Create a separate shortcut that stops all speech:
```swift
public func stopSpeaking() {
    let stopShortcutName = "Stop Speaking RSS"
    if let encodedName = stopShortcutName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
        let urlString = "shortcuts://x-callback-url/run-shortcut?name=\(encodedName)"
        if let url = URL(string: urlString) {
            UIApplication.shared.open(url)
        }
    }
}
```

#### 2. Text Chunking for Long Content
For very long text, consider breaking it into chunks:
```swift
func speakLongText(_ text: String) {
    let maxChunkSize = 1000
    let chunks = text.chunked(into: maxChunkSize)
    
    for (index, chunk) in chunks.enumerated() {
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(index * 10)) {
            ShortcutsTTS.shared.speakText(chunk)
        }
    }
}

extension String {
    func chunked(into size: Int) -> [String] {
        var chunks: [String] = []
        var currentIndex = startIndex
        
        while currentIndex < endIndex {
            let endIndex = index(currentIndex, offsetBy: size, limitedBy: endIndex) ?? endIndex
            chunks.append(String(self[currentIndex..<endIndex]))
            currentIndex = endIndex
        }
        
        return chunks
    }
}
```

## Troubleshooting

### Common Issues

#### 1. Shortcut Not Found
**Error**: "Failed to launch shortcut"
**Solution**: Ensure shortcut name matches exactly (case-sensitive)
```swift
private let shortcutName = "Speak Text RSS" // Must match exactly
```

#### 2. Text Not Speaking
**Check**:
- Shortcut exists with correct name
- Shortcut has "Speak" action
- Shortcut accepts text input
- Volume is not muted

#### 3. Encoding Issues
**Problem**: Special characters cause failures
**Solution**: Always encode text properly
```swift
let encoded = text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
```

#### 4. App Focus Changes
**Problem**: Shortcuts app takes focus
**Solution**: This is a system limitation. Consider informing users:
```swift
func informUserAboutShortcuts() {
    let alert = UIAlertController(
        title: "Text-to-Speech",
        message: "TTS will use Shortcuts app for better voice quality. The app may briefly switch to Shortcuts.",
        preferredStyle: .alert
    )
    alert.addAction(UIAlertAction(title: "OK", style: .default))
    present(alert, animated: true)
}
```

### Debug Logging
Enable detailed logging for troubleshooting:
```swift
print("🔊 [ShortcutsTTS] Shortcut name: '\(shortcutName)'")
print("🔊 [ShortcutsTTS] Encoded name: '\(encodedName)'")
print("🔊 [ShortcutsTTS] Text preview: '\(String(text.prefix(50)))...'")
print("🔊 [ShortcutsTTS] Full URL: \(urlString)")
```

## Advanced Features

### Voice Selection in Shortcut
You can create multiple shortcuts for different voices:
```swift
enum TTSVoice: String {
    case ava = "Speak with Ava"
    case alex = "Speak with Alex"
    case samantha = "Speak with Samantha"
}

func speakWithVoice(_ text: String, voice: TTSVoice) {
    guard let encodedName = voice.rawValue.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
          let encodedText = text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
        return
    }
    
    let urlString = "shortcuts://x-callback-url/run-shortcut?name=\(encodedName)&input=\(encodedText)"
    if let url = URL(string: urlString) {
        UIApplication.shared.open(url)
    }
}
```

### Callback Handling
Use x-callback-url for success/error callbacks:
```swift
let urlString = """
shortcuts://x-callback-url/run-shortcut?
name=\(encodedName)&
input=\(encodedText)&
x-success=myapp://tts-success&
x-error=myapp://tts-error
""".replacingOccurrences(of: "\n", with: "")
```

## Summary

This implementation provides a clever workaround for iOS apps running on Mac to access high-quality macOS TTS voices through the Shortcuts app. While it has some limitations (app switching, no progress tracking), it delivers significantly better voice quality than the standard iOS TTS voices when running on Mac.

### Key Benefits
- Access to premium macOS voices (Ava, Alex, Samantha)
- Better voice quality than iOS AVSpeechSynthesizer on Mac
- Simple integration with existing iOS apps
- No additional frameworks or dependencies needed

### Best Use Cases
- iOS apps designed for iPad running on Mac
- Apps where TTS quality is important
- Reading long-form content (articles, books)
- Accessibility features

The implementation is production-ready and has been successfully used in the RSS Reader app to provide high-quality TTS on macOS while maintaining compatibility with iOS devices.