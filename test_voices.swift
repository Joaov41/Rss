import AVFoundation

// List all available voices
let voices = AVSpeechSynthesisVoice.speechVoices()

print("Total voices available: \(voices.count)\n")

// Filter for English voices
let englishVoices = voices.filter { $0.language.starts(with: "en") }

print("English voices:")
for voice in englishVoices {
    print("  ID: \(voice.identifier)")
    print("  Name: \(voice.name)")
    print("  Language: \(voice.language)")
    print("  Quality: \(voice.quality.rawValue) (0=default, 1=enhanced, 2=premium)")
    print("  ---")
}

// Test specific voice identifiers
let testIdentifiers = [
    "com.apple.voice.enhanced.en-US.Ava",
    "com.apple.voice.premium.en-US.Ava",
    "com.apple.eloquence.en-US.Grandma",
    "com.apple.ttsbundle.siri_female_en-US_compact",
    "com.apple.speech.synthesis.voice.Alex",
    "com.apple.speech.voice.Alex",
    "com.apple.voice.enhanced.en-US",
    "com.apple.ttsbundle.Samantha"
]

print("\nTesting specific identifiers:")
for id in testIdentifiers {
    if let voice = AVSpeechSynthesisVoice(identifier: id) {
        print("✅ Found: \(id)")
        print("   Name: \(voice.name), Quality: \(voice.quality.rawValue)")
    } else {
        print("❌ Not found: \(id)")
    }
}

// Find highest quality US English voice
let usVoices = voices.filter { $0.language == "en-US" }
let sortedByQuality = usVoices.sorted { $0.quality.rawValue > $1.quality.rawValue }

print("\nBest quality en-US voices:")
for voice in sortedByQuality.prefix(5) {
    print("  \(voice.name) - Quality: \(voice.quality.rawValue) - ID: \(voice.identifier)")
}