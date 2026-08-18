# Local Text-to-Speech Implementation Guide for iOS/macOS

This guide provides a complete, reusable implementation of local Text-to-Speech (TTS) with premium voice support for iOS, iPadOS, and macOS applications.

## Table of Contents
1. [Overview](#overview)
2. [Key Features](#key-features)
3. [Platform Compatibility](#platform-compatibility)
4. [Core Components](#core-components)
5. [Full Implementation Code](#full-implementation-code)
6. [Settings Voice Picker](#settings-voice-picker)
7. [Usage Examples](#usage-examples)
8. [Troubleshooting](#troubleshooting)

## Overview

This implementation provides a robust local TTS system that:
- Automatically detects and uses premium voices when available
- Falls back gracefully from Premium → Enhanced → Default quality
- Handles platform differences between iOS and macOS
- Provides a user-friendly voice selection interface
- Saves user preferences persistently

## Key Features

- **Premium Voice Detection**: Automatically identifies and prioritizes premium voices (quality == .premium)
- **Quality Hierarchy**: Premium (★) > Enhanced > Default
- **Platform Awareness**: Handles iOS-on-Mac compatibility issues
- **User Choice**: Settings picker lets users select any available voice
- **Persistent Preferences**: Saves selected voice across app launches
- **Optimized Parameters**: Speech rate and pitch tuned for clarity

## Platform Compatibility

### iOS/iPadOS (Native)
- Full support for all AVSpeechSynthesisVoice types
- Premium voices work when downloaded from Settings → Accessibility → Spoken Content

### iOS-on-Mac (Catalyst/Designed for iPad)
- Filters out incompatible `com.apple.voice` identifiers
- Uses only compatible voice types (ttsbundle, speech.synthesis)

### macOS (Native)
- Uses NSSpeechSynthesizer
- Supports premium voices like Ava, Alex, Samantha (Enhanced)

## Core Components

### 1. Voice Selection Logic
- Checks for user-saved voice preference
- Falls back to best available voice by quality
- Platform-specific filtering for compatibility

### 2. Speech Parameters
- Rate: 0.52 (slightly slower than default for clarity)
- Pitch: 1.0 (natural)
- Volume: 1.0 (maximum)

### 3. Audio Session Configuration
- Category: `.playback`
- Mode: `.spokenAudio`
- Options: Duck others, Bluetooth support

## Full Implementation Code

### Main TTS Function for iOS

```swift
import AVFoundation
import UIKit

// MARK: - Local TTS Implementation
private func speakTextLocally(_ text: String) {
    #if os(iOS)
    // Stop if already speaking
    if isSpeakingLocally {
        localSpeechSynth?.stopSpeaking(at: .immediate)
        isSpeakingLocally = false
        return
    }
    
    guard !text.isEmpty else {
        speechSynthesisError = "No text available to read."
        return
    }
    
    // Stop any other audio
    audioPlayer?.stop()
    
    // Configure audio session for high-quality speech
    do {
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers, .allowBluetooth, .allowBluetoothA2DP])
        try audioSession.setActive(true)
    } catch {
        print("🔊 [LocalTTS] Failed to configure audio session: \(error)")
    }
    
    // Initialize speech synthesizer
    if localSpeechSynth == nil {
        localSpeechSynth = AVSpeechSynthesizer()
        localSpeechSynth?.delegate = soundDelegate
    }
    
    let utterance = AVSpeechUtterance(string: text)
    // Optimize speech parameters for quality
    utterance.rate = 0.52  // Slightly slower than default (0.5) for better clarity
    utterance.pitchMultiplier = 1.0  // Natural pitch
    utterance.volume = 1.0
    utterance.preUtteranceDelay = 0.0
    utterance.postUtteranceDelay = 0.0
    
    // Use saved voice from settings
    if let savedVoiceID = UserDefaults.standard.string(forKey: "LocalTTS.SelectedVoiceID"),
       !savedVoiceID.isEmpty,
       let savedVoice = AVSpeechSynthesisVoice(identifier: savedVoiceID) {
        // Only skip com.apple.voice on Mac (they don't work there)
        if ProcessInfo.processInfo.isiOSAppOnMac && savedVoice.identifier.contains("com.apple.voice") {
            print("🔊 [LocalTTS] Skipping com.apple.voice on Mac")
        } else {
            utterance.voice = savedVoice
            let qualityStr = savedVoice.quality == .premium ? "PREMIUM" : 
                            savedVoice.quality == .enhanced ? "Enhanced" : "Default"
            print("🔊 [LocalTTS] Using saved voice: \(savedVoice.name) [\(qualityStr)]")
        }
    }
    
    // If no saved voice, find the best available voice automatically
    if utterance.voice == nil {
        let currentLang = AVSpeechSynthesisVoice.currentLanguageCode()
        let allVoices = AVSpeechSynthesisVoice.speechVoices()
        
        // Filter for current language (and exclude com.apple.voice on Mac)
        let availableVoices: [AVSpeechSynthesisVoice]
        if ProcessInfo.processInfo.isiOSAppOnMac {
            availableVoices = allVoices.filter { 
                $0.language == currentLang && !$0.identifier.contains("com.apple.voice")
            }
        } else {
            availableVoices = allVoices.filter { $0.language == currentLang }
        }
        
        // Simple priority: Premium > Enhanced > Default
        let premiumVoices = availableVoices.filter { $0.quality == .premium }
        let enhancedVoices = availableVoices.filter { $0.quality == .enhanced }
        
        if let premium = premiumVoices.first {
            utterance.voice = premium
            print("🔊 [LocalTTS] Using PREMIUM voice: \(premium.name)")
        } else if let enhanced = enhancedVoices.first {
            utterance.voice = enhanced
            print("🔊 [LocalTTS] Using Enhanced voice: \(enhanced.name)")
        } else {
            // Fall back to default voice for the language
            utterance.voice = AVSpeechSynthesisVoice(language: currentLang)
            if let v = utterance.voice {
                print("🔊 [LocalTTS] Using default voice: \(v.name)")
            }
        }
    }
    
    isSpeakingLocally = true
    isSynthesizingSpeech = false
    if let synth = localSpeechSynth {
        DispatchQueue.main.async { synth.speak(utterance) }
    } else {
        isSpeakingLocally = false
        speechSynthesisError = "Failed to initialize speech synthesizer."
    }
    #endif
}
```

### Voice Selection Helper Functions

```swift
import AVFoundation

// MARK: - Voice Selection Helpers

@available(iOS 13.0, *)
public func pickBestIOSVoiceID(languagePrefix: String = "en") -> String? {
    let voices = AVSpeechSynthesisVoice.speechVoices()
    let target = voices.filter { $0.language.lowercased().hasPrefix(languagePrefix.lowercased()) }
    if target.isEmpty { return voices.first?.identifier }

    func score(_ v: AVSpeechSynthesisVoice) -> Int {
        let n = v.name.lowercased()
        var s = 0
        
        // HEAVILY prioritize premium voices for best quality
        if v.quality == .premium {
            s = 10000  // Premium voices get massive score boost
            // Rank premium voices by preference
            if n.contains("ava") { s += 500 }  // Ava is often the best premium voice
            if n.contains("zoe") { s += 450 }
            if n.contains("siri") { s += 400 }  // Siri voices are usually excellent
            if n.contains("samantha") { s += 350 }
            if n.contains("alex") { s += 300 }
            if n.contains("victoria") { s += 250 }
            if n.contains("daniel") { s += 200 }
            if n.contains("karen") { s += 150 }
            if n.contains("moira") { s += 100 }
            if n.contains("fiona") { s += 90 }
            if n.contains("oliver") { s += 80 }
        } else if v.quality == .enhanced {
            s = 5000  // Enhanced voices get moderate score
            // Rank enhanced voices
            if n.contains("samantha") { s += 200 }
            if n.contains("victoria") || n.contains("daniel") { s += 100 }
            if n.contains("karen") || n.contains("moira") { s += 50 }
        } else {
            s = 1000  // Default quality voices get base score
        }
        
        // Prefer US English slightly
        if v.language == "en-US" { s += 50 }
        
        // Heavily penalize novelty/low-quality voices
        let bad = ["bad news", "good news", "zarvox", "trinoids", "pipe organ", 
                   "bells", "boing", "whisper", "cellos", "princess", "fred", 
                   "albert", "eddy", "bubbles", "deranged", "hysterical"]
        if bad.contains(where: { n.contains($0) }) {
            s -= 5000  // Make sure novelty voices are never selected
        }
        
        return s
    }

    let sorted = target.sorted { score($0) > score($1) }
    if let best = sorted.first {
        let qualityName = best.quality == .premium ? "PREMIUM" : 
                         best.quality == .enhanced ? "Enhanced" : "Default"
        print("🔊 [AudioUtils] pickBestIOSVoiceID selected: \(best.name) [\(qualityName)] score=\(score(best))")
    }
    
    return sorted.first?.identifier
}
```

### macOS Voice Selection

```swift
#if os(macOS)
import AppKit

public func preferredMacVoiceIdentifier() -> String? {
    let available = NSSpeechSynthesizer.availableVoices()
    
    struct VoiceInfo {
        let id: String
        let name: String
        let locale: String
    }
    
    var voiceInfos: [VoiceInfo] = []
    for id in available {
        let attrs = NSSpeechSynthesizer.attributes(forVoice: id)
        let name = (attrs[.name] as? String) ?? ""
        let locale = (attrs[.localeIdentifier] as? String) ?? ""
        voiceInfos.append(VoiceInfo(id: id, name: name, locale: locale))
    }
    
    // Score each voice based on quality preferences
    func scoreVoice(_ v: VoiceInfo) -> Int {
        let n = v.name.lowercased()
        var score = 0
        
        // Premium/Enhanced voices (macOS premium voices)
        if n == "ava (premium)" || n.contains("(premium)") { score += 2000 }
        if n == "ava" && !n.contains("(") { score += 1800 }
        if n == "alex" { score += 1500 }  // Alex is the classic high-quality Mac voice
        if n == "samantha (enhanced)" || n.contains("samantha") && n.contains("enhanced") { score += 1400 }
        if n == "samantha" && !n.contains("(") { score += 1300 }
        if n == "allison" { score += 1100 }
        if n == "victoria" { score += 1000 }
        if n == "karen" { score += 950 }
        if n == "daniel" { score += 900 }
        
        // Language preference
        if v.locale.lowercased().hasPrefix("en-us") { score += 100 }
        else if v.locale.lowercased().hasPrefix("en") { score += 50 }
        
        // Penalize novelty voices
        let bad = ["zarvox", "trinoids", "bad news", "good news", "pipe organ", 
                   "bells", "boing", "whisper", "cellos", "princess", "fred", 
                   "albert", "bubbles", "deranged", "hysterical"]
        if bad.contains(where: { n.contains($0) }) {
            score -= 1000
        }
        
        return score
    }
    
    // Sort voices by score and pick the best one
    let sorted = voiceInfos.sorted { scoreVoice($0) > scoreVoice($1) }
    
    if let best = sorted.first {
        print("🔊 [AudioUtils] macOS voice selected: \(best.name) [score=\(scoreVoice(best))]")
        return best.id
    }
    
    return available.first
}
#endif
```

## Settings Voice Picker

### Complete SwiftUI Settings View with Voice Picker

```swift
import SwiftUI
import AVFoundation

struct TTSSettingsView: View {
    // Voice selection
    @State private var iosVoices: [(id: String, title: String)] = []
    @State private var localVoiceID: String = ""
    private let voiceKey = "LocalTTS.SelectedVoiceID"
    
    #if os(iOS)
    @State private var testSynthIOS: AVSpeechSynthesizer? = nil
    #elseif os(macOS)
    @State private var macVoices: [(id: String, name: String)] = []
    @State private var testSynthMac: NSSpeechSynthesizer? = nil
    #endif
    
    var body: some View {
        Form {
            Section("Text-to-Speech Voice") {
                #if os(iOS)
                if iosVoices.isEmpty {
                    Text("No voices available. Install voices in System Settings → Accessibility → Spoken Content → System Voice")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    Picker("Voice", selection: $localVoiceID) {
                        ForEach(iosVoices, id: \.id) { v in
                            Text(v.title).tag(v.id)
                        }
                    }
                    .onChange(of: localVoiceID) { newID in
                        UserDefaults.standard.set(newID, forKey: voiceKey)
                    }
                    
                    HStack(spacing: 12) {
                        Button("Test Voice") {
                            testSelectedVoice()
                        }
                        .buttonStyle(.borderedProminent)
                        
                        Button("Reset to Default") {
                            resetToDefaultVoice()
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(.top, 8)
                }
                #elseif os(macOS)
                if macVoices.isEmpty {
                    Text("No macOS voices found.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    Picker("Voice", selection: $localVoiceID) {
                        ForEach(macVoices, id: \.id) { v in
                            Text(v.name).tag(v.id)
                        }
                    }
                    .onChange(of: localVoiceID) { newID in
                        UserDefaults.standard.set(newID, forKey: voiceKey)
                    }
                    
                    HStack(spacing: 12) {
                        Button("Test Voice") {
                            testSelectedVoice()
                        }
                        .buttonStyle(.borderedProminent)
                        
                        Button("Reset to Default") {
                            resetToDefaultVoice()
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(.top, 8)
                }
                #endif
            }
        }
        .onAppear {
            loadLocalVoices()
        }
    }
    
    private func loadLocalVoices() {
        #if os(iOS)
        if #available(iOS 14.0, *) {
            let all = AVSpeechSynthesisVoice.speechVoices()
            
            // Filter out com.apple.voice on Mac as they don't work
            let availableVoices: [AVSpeechSynthesisVoice]
            if ProcessInfo.processInfo.isiOSAppOnMac {
                availableVoices = all.filter { !$0.identifier.contains("com.apple.voice") }
            } else {
                availableVoices = all
            }
            
            // Map all available voices with quality labels
            let entries = availableVoices.map { v -> (id: String, title: String) in
                let qualityLabel: String
                switch v.quality {
                case .premium:
                    qualityLabel = "★ Premium"
                case .enhanced:
                    qualityLabel = "Enhanced"
                default:
                    qualityLabel = "Default"
                }
                return (id: v.identifier, title: "\(v.name) (\(qualityLabel))")
            }
            
            // Sort by quality (premium first) then by name
            iosVoices = entries.sorted { a, b in
                // Premium voices first
                if a.title.contains("★ Premium") && !b.title.contains("★ Premium") { return true }
                if !a.title.contains("★ Premium") && b.title.contains("★ Premium") { return false }
                // Then Enhanced
                if a.title.contains("Enhanced") && b.title.contains("Default") { return true }
                if a.title.contains("Default") && b.title.contains("Enhanced") { return false }
                // Then alphabetical
                return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
            }
            
            // Load saved or automatically select best available voice
            if let sel = UserDefaults.standard.string(forKey: voiceKey), !sel.isEmpty {
                localVoiceID = sel
            } else {
                // Auto-select best available voice: Premium > Enhanced > Default
                let currentLang = AVSpeechSynthesisVoice.currentLanguageCode()
                
                let premiumVoices = availableVoices.filter { 
                    $0.language == currentLang && $0.quality == .premium 
                }
                let enhancedVoices = availableVoices.filter { 
                    $0.language == currentLang && $0.quality == .enhanced 
                }
                let defaultVoices = availableVoices.filter { 
                    $0.language == currentLang && $0.quality == .default 
                }
                
                if let premium = premiumVoices.first {
                    localVoiceID = premium.identifier
                    print("🔊 [Settings] Auto-selected PREMIUM voice: \(premium.name)")
                } else if let enhanced = enhancedVoices.first {
                    localVoiceID = enhanced.identifier
                    print("🔊 [Settings] Auto-selected Enhanced voice: \(enhanced.name)")
                } else if let defaultVoice = defaultVoices.first {
                    localVoiceID = defaultVoice.identifier
                    print("🔊 [Settings] Auto-selected Default voice: \(defaultVoice.name)")
                } else {
                    localVoiceID = iosVoices.first?.id ?? ""
                }
                
                if !localVoiceID.isEmpty { 
                    UserDefaults.standard.set(localVoiceID, forKey: voiceKey) 
                }
            }
        }
        #elseif os(macOS)
        // macOS voice loading code here
        macVoices = NSSpeechSynthesizer.availableVoices().map { id in
            let attrs = NSSpeechSynthesizer.attributes(forVoice: id)
            let name = (attrs[.name] as? String) ?? id
            return (id: id, name: name)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        
        if let sel = UserDefaults.standard.string(forKey: voiceKey), !sel.isEmpty {
            localVoiceID = sel
        } else if let preferred = preferredMacVoiceIdentifier() {
            localVoiceID = preferred
            UserDefaults.standard.set(localVoiceID, forKey: voiceKey)
        } else {
            localVoiceID = macVoices.first?.id ?? ""
        }
        #endif
    }
    
    private func testSelectedVoice() {
        #if os(iOS)
        let utterance = AVSpeechUtterance(string: "This is a test of the selected voice. Premium voices sound natural and clear.")
        if let v = AVSpeechSynthesisVoice(identifier: localVoiceID) { 
            utterance.voice = v 
        }
        utterance.rate = 0.52
        utterance.pitchMultiplier = 1.0
        utterance.volume = 1.0
        
        if testSynthIOS == nil { 
            testSynthIOS = AVSpeechSynthesizer() 
        }
        testSynthIOS?.speak(utterance)
        #elseif os(macOS)
        let synth = NSSpeechSynthesizer()
        _ = synth.setVoice(localVoiceID)
        synth.startSpeaking("This is a test of the selected voice.")
        testSynthMac = synth
        #endif
    }
    
    private func resetToDefaultVoice() {
        UserDefaults.standard.removeObject(forKey: voiceKey)
        loadLocalVoices()
    }
}
```

## Usage Examples

### Basic Usage

```swift
class ViewController: UIViewController {
    private var speechSynthesizer: AVSpeechSynthesizer?
    
    func speakText(_ text: String) {
        // Initialize synthesizer
        if speechSynthesizer == nil {
            speechSynthesizer = AVSpeechSynthesizer()
        }
        
        // Create utterance
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = 0.52
        utterance.pitchMultiplier = 1.0
        utterance.volume = 1.0
        
        // Use saved voice or best available
        if let savedVoiceID = UserDefaults.standard.string(forKey: "LocalTTS.SelectedVoiceID"),
           let voice = AVSpeechSynthesisVoice(identifier: savedVoiceID) {
            utterance.voice = voice
        } else {
            // Auto-select best voice
            let voices = AVSpeechSynthesisVoice.speechVoices()
            let currentLang = AVSpeechSynthesisVoice.currentLanguageCode()
            
            // Find premium voice
            if let premium = voices.first(where: { 
                $0.language == currentLang && $0.quality == .premium 
            }) {
                utterance.voice = premium
            } else if let enhanced = voices.first(where: { 
                $0.language == currentLang && $0.quality == .enhanced 
            }) {
                utterance.voice = enhanced
            }
        }
        
        // Speak
        speechSynthesizer?.speak(utterance)
    }
}
```

### SwiftUI Integration

```swift
struct ContentView: View {
    @State private var textToSpeak = "Hello, World!"
    @State private var isSpeaking = false
    @State private var speechSynthesizer: AVSpeechSynthesizer?
    
    var body: some View {
        VStack(spacing: 20) {
            TextEditor(text: $textToSpeak)
                .frame(height: 200)
                .border(Color.gray, width: 1)
                .padding()
            
            Button(action: {
                if isSpeaking {
                    stopSpeaking()
                } else {
                    speakText()
                }
            }) {
                Label(isSpeaking ? "Stop" : "Speak", 
                      systemImage: isSpeaking ? "stop.fill" : "speaker.wave.2.fill")
            }
            .buttonStyle(.borderedProminent)
            
            NavigationLink(destination: TTSSettingsView()) {
                Label("Voice Settings", systemImage: "gear")
            }
            .buttonStyle(.bordered)
        }
        .padding()
    }
    
    private func speakText() {
        // Implementation from above
        // ... (use the speakTextLocally function)
        isSpeaking = true
    }
    
    private func stopSpeaking() {
        speechSynthesizer?.stopSpeaking(at: .immediate)
        isSpeaking = false
    }
}
```

## Troubleshooting

### Common Issues and Solutions

#### 1. Premium Voices Not Available
**Problem**: Premium voices don't appear in the picker.
**Solution**: 
- Go to Settings → Accessibility → Spoken Content → Voices
- Download premium voices (look for cloud icon)
- Restart the app after downloading

#### 2. Voice Reverts to Default
**Problem**: Selected voice doesn't persist.
**Solution**: Ensure UserDefaults key is consistent across all uses:
```swift
let voiceKey = "LocalTTS.SelectedVoiceID"
```

#### 3. iOS App on Mac Issues
**Problem**: Voices don't work when running iOS app on Mac.
**Solution**: The code automatically filters out incompatible voices:
```swift
if ProcessInfo.processInfo.isiOSAppOnMac {
    // Filter out com.apple.voice identifiers
}
```

#### 4. Speech Too Fast/Slow
**Problem**: Speech rate doesn't sound natural.
**Solution**: Adjust the rate parameter (0.0 to 1.0):
```swift
utterance.rate = 0.52  // Slightly slower than default (0.5)
```

### Voice Quality Reference

#### iOS Premium Voices (Examples)
- **Ava**: Female, very natural (Premium)
- **Zoe**: Female, expressive (Premium)
- **Siri voices**: Various accents (Premium)
- **Nicky**: US Female (Premium)
- **Aaron**: US Male (Premium)

#### iOS Enhanced Voices
- **Samantha**: Female, clear (Enhanced)
- **Alex**: Male, natural (Enhanced)
- **Victoria**: Female, British (Enhanced)

#### macOS Premium Voices
- **Ava (Premium)**: Best quality
- **Alex**: Classic Mac voice
- **Samantha (Enhanced)**: High quality
- **Allison**: Natural female

## Additional Features

### Voice Download Detection

```swift
// Check if premium voices are available
func hasPremiumVoices() -> Bool {
    let voices = AVSpeechSynthesisVoice.speechVoices()
    return voices.contains { $0.quality == .premium }
}

// Prompt user to download premium voices
func promptForVoiceDownload() {
    if !hasPremiumVoices() {
        // Show alert or guide user to Settings
        let alert = UIAlertController(
            title: "Premium Voices",
            message: "Download premium voices for the best experience. Go to Settings → Accessibility → Spoken Content → Voices",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        // Present alert
    }
}
```

### Speech Delegate for Events

```swift
class SpeechDelegate: NSObject, AVSpeechSynthesizerDelegate {
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        print("Started speaking")
    }
    
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        print("Finished speaking")
    }
    
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didPause utterance: AVSpeechUtterance) {
        print("Paused speaking")
    }
    
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didContinue utterance: AVSpeechUtterance) {
        print("Resumed speaking")
    }
}
```

## License and Usage

This implementation is provided as a reference guide. You can freely use and modify this code in your own projects.

## Summary

This local TTS implementation provides:
- Automatic premium voice detection and usage
- User-friendly voice selection in settings
- Cross-platform compatibility (iOS/iPadOS/macOS)
- Graceful fallback from Premium → Enhanced → Default
- Persistent user preferences
- Optimized speech parameters for clarity

The key to premium voice support is checking the `quality` property:
- `.premium` (rawValue: 2) - Highest quality
- `.enhanced` (rawValue: 1) - Good quality
- `.default` (rawValue: 0) - Basic quality

Remember to test on real devices, as simulators may not have all voices available.