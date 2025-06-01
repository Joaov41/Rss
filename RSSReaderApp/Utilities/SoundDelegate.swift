import Foundation
#if os(iOS)
import AVFoundation
import SwiftUI
#elseif os(macOS)
import AppKit
import SwiftUI
#endif

// MARK: - Sound Delegate for TTS
#if os(iOS)
public class SoundDelegate: NSObject, ObservableObject, AVAudioPlayerDelegate, AVSpeechSynthesizerDelegate {
    public var onPlaybackFinished: (() -> Void)? = nil
    public var onSpeechFinished: (() -> Void)? = nil
    
    public override init() {
        super.init()
    }
    
    public func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        if flag {
            onPlaybackFinished?()
        }
    }
    
    public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        onSpeechFinished?()
    }
}
#elseif os(macOS)
public class SoundDelegate: NSObject, ObservableObject, NSSoundDelegate, NSSpeechSynthesizerDelegate {
    public var onPlaybackFinished: (() -> Void)? = nil
    public var onSpeechFinished: (() -> Void)? = nil
    
    public override init() {
        super.init()
    }
    
    public func sound(_ sound: NSSound, didFinishPlaying flag: Bool) {
        if flag {
            onPlaybackFinished?()
        }
    }
    
    public func speechSynthesizer(_ sender: NSSpeechSynthesizer, didFinishSpeaking finishedSpeaking: Bool) {
        if finishedSpeaking {
            onSpeechFinished?()
        }
    }
}
#endif 