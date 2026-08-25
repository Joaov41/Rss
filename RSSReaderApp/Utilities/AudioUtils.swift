import Foundation
#if os(macOS)
import AppKit
#endif
#if os(iOS)
import AVFoundation
#endif

// MARK: - Audio Utility Functions
// Made public so it can be accessed from other files
public func createWavData(from pcmData: Data, sampleRate: UInt32, channels: UInt16, bitsPerSample: UInt16) -> Data {
    var header = Data()
    let pcmDataSize = UInt32(pcmData.count)
    var chunkSize: UInt32 = 36 + pcmDataSize
    var subChunk1Size: UInt32 = 16 // For PCM
    var audioFormat: UInt16 = 1   // For PCM

    // RIFF Header
    header.append("RIFF".data(using: .ascii)!)
    header.append(Data(bytes: &chunkSize, count: MemoryLayout.size(ofValue: chunkSize)))
    header.append("WAVE".data(using: .ascii)!)

    // FMT Subchunk
    header.append("fmt ".data(using: .ascii)!)
    header.append(Data(bytes: &subChunk1Size, count: MemoryLayout.size(ofValue: subChunk1Size)))
    header.append(Data(bytes: &audioFormat, count: MemoryLayout.size(ofValue: audioFormat)))
    
    var mutableChannels = channels // Create a mutable copy
    header.append(Data(bytes: &mutableChannels, count: MemoryLayout.size(ofValue: mutableChannels)))
    
    var mutableSampleRate = sampleRate // Create a mutable copy
    header.append(Data(bytes: &mutableSampleRate, count: MemoryLayout.size(ofValue: mutableSampleRate)))
    
    let byteRate = sampleRate * UInt32(channels) * UInt32(bitsPerSample) / 8
    var mutableByteRate = byteRate // Create a mutable copy for the pointer
    header.append(Data(bytes: &mutableByteRate, count: MemoryLayout.size(ofValue: mutableByteRate)))
    
    let blockAlign = channels * bitsPerSample / 8
    var mutableBlockAlign = blockAlign // Create a mutable copy
    header.append(Data(bytes: &mutableBlockAlign, count: MemoryLayout.size(ofValue: mutableBlockAlign)))
    
    var mutableBitsPerSample = bitsPerSample // Create a mutable copy
    header.append(Data(bytes: &mutableBitsPerSample, count: MemoryLayout.size(ofValue: mutableBitsPerSample)))

    // DATA Subchunk
    header.append("data".data(using: .ascii)!)
    var mutablePcmDataSize = pcmDataSize // Create a mutable copy
    header.append(Data(bytes: &mutablePcmDataSize, count: MemoryLayout.size(ofValue: mutablePcmDataSize)))
    
    // Append PCM data
    var result = header
    result.append(pcmData)
    
    return result
}

// Helper function to detect MP3 data format (used by multiple views)
public func isMP3Data(_ data: Data) -> Bool {
    // MP3 files typically start with ID3 tag (0x494433) or sync header (0xFFE or 0xFFF)
    guard data.count >= 3 else { return false }
    
    let bytes = data.prefix(3)
    let header = [UInt8](bytes)
    
    // Check for ID3 tag (ID3v2)
    if header.count >= 3 && header[0] == 0x49 && header[1] == 0x44 && header[2] == 0x33 {
        return true
    }
    
    // Check for MP3 sync header (frame sync)
    if header.count >= 2 {
        let syncPattern = (UInt16(header[0]) << 8) | UInt16(header[1])
        // MP3 frame header starts with 11 bits set (0xFFE or 0xFFF followed by specific patterns)
        if (syncPattern & 0xFFE0) == 0xFFE0 {
            return true
        }
    }
    
    return false
}

/// Detect AAC (ADTS) data format by header bytes (0xFFF..)
public func isAACData(_ data: Data) -> Bool {
    guard data.count >= 2 else { return false }
    let bytes = [UInt8](data.prefix(2))
    // AAC ADTS header starts with 12 bits set (0xFFFx)
    return (bytes[0] == 0xFF && (bytes[1] & 0xF0) == 0xF0)
}

#if os(macOS)
// Convenience init for VoiceName to accept String without 'rawValue:' label
public extension NSSpeechSynthesizer.VoiceName {
    init(_ raw: String) { self.init(rawValue: raw) }
}

// MARK: - macOS Voice Selection Helpers
// Returns the best quality macOS voice identifier available
public func preferredMacVoiceIdentifier() -> String? {
    let availableNames = NSSpeechSynthesizer.availableVoices
    
    struct VoiceInfo {
        let id: String
        let name: String
        let locale: String
    }
    
    var voiceInfos: [VoiceInfo] = []
    for voiceName in availableNames {
        let attrs = NSSpeechSynthesizer.attributes(forVoice: voiceName)
        let displayName = (attrs[NSSpeechSynthesizer.VoiceAttributeKey.name] as? String) ?? ""
        let locale = (attrs[NSSpeechSynthesizer.VoiceAttributeKey.localeIdentifier] as? String) ?? ""
        voiceInfos.append(VoiceInfo(id: voiceName.rawValue, name: displayName, locale: locale))
    }
    
    // Score each voice based on quality preferences
    func scoreVoice(_ v: VoiceInfo) -> Int {
        let n = v.name.lowercased()
        var score = 0
        
        // Premium/Enhanced voices (macOS premium voices)
        // These are the highest quality voices on macOS
        if n == "ava (premium)" || n.contains("(premium)") { score += 2000 }
        if n == "ava" && !n.contains("(") { score += 1800 }  // Ava without qualifier is still excellent
        if n == "alex" { score += 1500 }  // Alex is the classic high-quality Mac voice
        if n == "samantha (enhanced)" || n.contains("samantha") && n.contains("enhanced") { score += 1400 }
        if n == "samantha" && !n.contains("(") { score += 1300 }
        if n == "tom (enhanced)" || n.contains("tom") && n.contains("enhanced") { score += 1200 }
        if n == "allison" { score += 1100 }  // Allison is a high-quality voice
        if n == "susan" { score += 1050 }
        if n == "victoria" { score += 1000 }
        if n == "karen" { score += 950 }
        if n == "daniel" { score += 900 }
        if n == "moira" { score += 850 }
        if n == "fiona" { score += 800 }
        if n == "tessa" { score += 750 }
        
        // Language preference
        if v.locale.lowercased().hasPrefix("en-us") { score += 100 }
        else if v.locale.lowercased().hasPrefix("en") { score += 50 }
        
        // Penalize novelty/low-quality voices
        let bad = ["zarvox", "trinoids", "bad news", "good news", "pipe organ", 
                   "bells", "boing", "whisper", "cellos", "princess", "fred", 
                   "albert", "bubbles", "deranged", "hysterical", "junior", "ralph"]
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
    
    return availableNames.first?.rawValue
}

// Stubs to satisfy shared code paths when building macOS target
@discardableResult
public func ensureIOSOnMacPinnedVoice() -> String? { return nil }

@discardableResult
public func ensurelOSOnMacPinnedVoice() -> String? { return nil }
#endif

#if os(iOS)
// MARK: - iOS (on Mac) Voice Selection Helpers
// For iOS apps running on macOS, prefer enhanced English voices for a less robotic sound.
@available(iOS 14.0, *)
public func preferredIOSVoiceForMacEnvironment() -> AVSpeechSynthesisVoice? {
    let voices = AVSpeechSynthesisVoice.speechVoices()
    // Only use voices known to work on iOS-on-Mac
    let working = voices.filter { v in
        v.identifier.contains("com.apple.ttsbundle") || v.identifier.contains("com.apple.speech.synthesis")
    }
    let english = working.filter { $0.language.lowercased().hasPrefix("en") }

    // 1) Try to find Ava among working voices (if surfaced), prefer higher quality
    let avaMatches = english.filter { $0.name.lowercased().contains("ava") }
        .sorted { $0.quality.rawValue > $1.quality.rawValue }
    if let ava = avaMatches.first { return ava }

    // 2) Prefer enhanced-quality English voices
    if let enhanced = english.first(where: { $0.quality == .enhanced }) { return enhanced }

    // 3) Prefer well-known natural voices
    if let named = english.first(where: { v in
        let n = v.name.lowercased()
        return n.contains("samantha") || n.contains("daniel") || n.contains("victoria") || n.contains("alex")
    }) { return named }

    // 4) Fallbacks
    return english.first ?? working.first ?? voices.first
}

// Returns the best available enhanced English AVSpeech voice identifier (ttsbundle only)
@available(iOS 14.0, *)
public func bestEnhancedIOSOnMacVoiceID() -> String? {
    let voices = AVSpeechSynthesisVoice.speechVoices()
    // Restrict to ttsbundle voices that reliably work in iOS-on-Mac
    let english = voices.filter { v in
        v.identifier.hasPrefix("com.apple.ttsbundle") && v.language.lowercased().hasPrefix("en") && v.quality == .enhanced
    }
    if english.isEmpty { return nil }
    // Score to prefer Siri enhanced first, then Samantha/Victoria/Daniel
    func score(_ v: AVSpeechSynthesisVoice) -> Int {
        let n = v.name.lowercased()
        var s = v.quality.rawValue * 100
        if n.contains("siri") { s += 50 }
        if n.contains("samantha") { s += 20 }
        if n.contains("victoria") || n.contains("daniel") || n.contains("karen") { s += 10 }
        return s
    }
    let best = english.sorted { score($0) > score($1) }.first
    return best?.identifier
}

// Ensure a pinned best-enhanced ID exists for iOS-on-Mac and return it
@available(iOS 14.0, *)
@discardableResult
public func ensureIOSOnMacPinnedVoice() -> String? {
    let key = "LocalTTS.iOSOnMac.SelectedVoiceID"
    if let existing = UserDefaults.standard.string(forKey: key),
       let v = AVSpeechSynthesisVoice(identifier: existing),
       v.identifier.hasPrefix("com.apple.ttsbundle") {
        return existing
    }
    if let best = bestEnhancedIOSOnMacVoiceID() {
        UserDefaults.standard.set(best, forKey: key)
        return best
    }
    return nil
}

// Backward-compat alias to avoid typographical mismatch in call sites
@available(iOS 14.0, *)
@discardableResult
public func ensurelOSOnMacPinnedVoice() -> String? { // note: lowercase 'l' after ensure
    return ensureIOSOnMacPinnedVoice()
}

// MARK: - General iOS voice selection (real devices and iOS-on-Mac)
// Returns the best available English AVSpeech voice ID by quality (Premium > Enhanced > Default),
// with heavy preference for premium voices to ensure best quality on real iOS devices.
@available(iOS 13.0, *)
public func pickBestIOSVoiceID(languagePrefix: String = "en") -> String? {
    let voices = AVSpeechSynthesisVoice.speechVoices()
    let target = voices.filter { $0.language.lowercased().hasPrefix(languagePrefix.lowercased()) }
    if target.isEmpty { return voices.first?.identifier }

    func score(_ v: AVSpeechSynthesisVoice) -> Int {
        let n = v.name.lowercased()
        var s = 0
        
        // HEAVILY prioritize premium voices for best quality (especially on real devices)
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
#endif

// MARK: - Shared Local TTS Voice Preferences
public enum LocalTTSVoicePrefs {
    private static let macVoiceKey = "LocalTTS.Mac.SelectedVoiceID"
    private static let iosOnMacVoiceKey = "LocalTTS.iOSOnMac.SelectedVoiceID"

    public static func getSelectedMacVoiceID() -> String? {
        UserDefaults.standard.string(forKey: macVoiceKey)
    }

    public static func setSelectedMacVoiceID(_ id: String?) {
        if let id = id, !id.isEmpty {
            UserDefaults.standard.set(id, forKey: macVoiceKey)
        } else {
            UserDefaults.standard.removeObject(forKey: macVoiceKey)
        }
    }

    public static func getSelectedIOSOnMacVoiceID() -> String? {
        UserDefaults.standard.string(forKey: iosOnMacVoiceKey)
    }

    public static func setSelectedIOSOnMacVoiceID(_ id: String?) {
        if let id = id, !id.isEmpty {
            UserDefaults.standard.set(id, forKey: iosOnMacVoiceKey)
        } else {
            UserDefaults.standard.removeObject(forKey: iosOnMacVoiceKey)
        }
    }
}

#if os(macOS)
@discardableResult
public func setMacSpeechVoice(_ synthesizer: NSSpeechSynthesizer, identifier: String) -> Bool {
    synthesizer.setVoice(NSSpeechSynthesizer.VoiceName(rawValue: identifier))
}

// List available macOS voices with display names
public func availableMacVoices() -> [(id: String, name: String)] {
    let ids = NSSpeechSynthesizer.availableVoices
    return ids.map { id in
        let attrs = NSSpeechSynthesizer.attributes(forVoice: id)
        let name = (attrs[NSSpeechSynthesizer.VoiceAttributeKey.name] as? String) ?? id.rawValue
        return (id: id.rawValue, name: name)
    }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
}
#endif

#if os(iOS)
// List available iOS-on-Mac ttsbundle voices with display names
@available(iOS 14.0, *)
public func availableIOSOnMacVoices() -> [(id: String, name: String)] {
    let all = AVSpeechSynthesisVoice.speechVoices()
    let filtered = all.filter { v in
        v.identifier.hasPrefix("com.apple.ttsbundle.") && v.language.lowercased().hasPrefix("en")
    }
    return filtered.map { (id: $0.identifier, name: $0.name) }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
}
#endif
