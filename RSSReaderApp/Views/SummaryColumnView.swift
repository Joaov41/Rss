import SwiftUI
#if os(iOS)
import AVFoundation
#elseif os(macOS)
import AppKit
#endif
import Foundation

// Import createWavData from SummaryService

struct SummaryColumnView: View {
    @EnvironmentObject var appState: AppState
    
    // TTS state variables for summary
    @State private var isSynthesizingSpeech: Bool = false
    @State private var isSpeakingLocally: Bool = false
    @State private var speechSynthesisError: String? = nil
    #if os(iOS)
    @State private var audioPlayer: AVAudioPlayer?
    @State private var localSpeechSynth: AVSpeechSynthesizer?
    @StateObject private var soundDelegate = SoundDelegate()
    #elseif os(macOS)
    @State private var audioPlayer: NSSound?
    @State private var localSpeechSynth: NSSpeechSynthesizer?
    @StateObject private var soundDelegate = SoundDelegate()
    #endif

    var body: some View {
        VStack(alignment: .leading) {
            if let article = appState.selectedArticle {
                Text("Summary for:")
                    .font(.headline)
                    .padding(.bottom, 2)
                Text(article.title)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                    .padding(.bottom, 8)
                
                if appState.isLoading {
                    ProgressView("Generating summary...")
                        .padding()
                } else if let summary = article.summary, !summary.isEmpty {
                    VStack(alignment: .leading) {
                        HStack(spacing: 12) {
                            Spacer()
                            // Cloud TTS button
                            Button {
                                speakSummary()
                            } label: {
                                Image(systemName: "speaker.wave.2")
                                    .padding(6)
                                    .background(Color.blue.opacity(0.2))
                                    .cornerRadius(8)
                            }
                            .buttonStyle(PlainButtonStyle())
                            .help("Read aloud (Cloud)")
                            .disabled(isSynthesizingSpeech || isSpeakingLocally)
                            
                            // Local TTS button
                            Button {
                                speakSummaryLocally(summary)
                            } label: {
                                Image(systemName: "speaker.wave.2.circle")
                                    .padding(6)
                                    .background(Color.green.opacity(0.2))
                                    .cornerRadius(8)
                            }
                            .buttonStyle(PlainButtonStyle())
                            .help("Read aloud (Local)")
                            .disabled(isSynthesizingSpeech)
                            
                            // Copy button
                            Button {
                                copyToClipboard(summary)
                            } label: {
                                Image(systemName: "doc.on.doc")
                                    .padding(6)
                                    .background(Color.gray.opacity(0.2))
                                    .cornerRadius(8)
                            }
                            .buttonStyle(PlainButtonStyle())
                            .help("Copy summary")
                        }
                        .padding(.horizontal)
                        
                        ScrollView {
                            Text(summary)
                                .padding()
                                .textSelection(.enabled)
                        }
                        .frame(maxHeight: .infinity)
                        
                        // TTS status indicators
                        if isSynthesizingSpeech {
                            HStack {
                                ProgressView()
                                    .scaleEffect(0.7)
                                    .padding(.trailing, 5)
                                Text("Reading summary...")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .padding(.horizontal)
                            .padding(.bottom, 4)
                        } else if isSpeakingLocally {
                            HStack {
                                ProgressView()
                                    .scaleEffect(0.7)
                                    .padding(.trailing, 5)
                                Text("Reading with local TTS...")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .padding(.horizontal)
                            .padding(.bottom, 4)
                        }
                        
                        if let error = speechSynthesisError {
                            Text(error)
                                .font(.caption)
                                .foregroundColor(.red)
                                .padding(.horizontal)
                                .padding(.bottom, 4)
                        }
                    }
                } else {
                    Button(action: {
                        appState.summarizeArticle(article)
                    }) {
                        HStack {
                            Image(systemName: "sparkles")
                            Text("Summarize Article")
                        }
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(Color.accentColor.opacity(0.1))
                        .cornerRadius(8)
                    }
                    .padding(.top, 16)
                }
            } else {
                Text("Select an article to see its summary.")
                    .foregroundColor(.secondary)
                    .padding()
            }
            Spacer()
        }
        .frame(minWidth: 300)
        .padding()
        .onAppear {
            // Set up sound delegate callbacks
            #if os(iOS)
            soundDelegate.onPlaybackFinished = {
                DispatchQueue.main.async {
                    self.isSynthesizingSpeech = false
                }
            }
            soundDelegate.onSpeechFinished = {
                DispatchQueue.main.async {
                    self.isSpeakingLocally = false
                }
            }
            #elseif os(macOS)
            soundDelegate.onPlaybackFinished = {
                DispatchQueue.main.async {
                    self.isSynthesizingSpeech = false
                }
            }
            soundDelegate.onSpeechFinished = {
                DispatchQueue.main.async {
                    self.isSpeakingLocally = false
                }
            }
            #endif
        }
    }
    
    // MARK: - TTS Methods
    
    private func speakSummary() {
        guard let article = appState.selectedArticle, 
              let summary = article.summary, 
              !summary.isEmpty else {
            speechSynthesisError = "No summary available to read."
            return
        }
        
        // Stop any currently playing sounds before starting a new one
        #if os(iOS)
        audioPlayer?.stop()
        audioPlayer = nil
        localSpeechSynth?.stopSpeaking(at: .immediate)
        #elseif os(macOS)
        audioPlayer?.stop()
        audioPlayer = nil
        localSpeechSynth?.stopSpeaking()
        #endif
        
        isSynthesizingSpeech = true
        isSpeakingLocally = false
        speechSynthesisError = nil
        
        Task {
            await appState.summaryService.synthesizeSpeechFastStart(
                text: summary,
                onFirstChunk: { audioData in
                    DispatchQueue.main.async {
                        self.playAudio(data: audioData)
                        print("🔊 SummaryColumnView: Started immediate playback")
                    }
                },
                onComplete: { completeAudioData in
                    DispatchQueue.main.async {
                        print("🔊 SummaryColumnView: Complete audio ready for cache")
                    }
                },
                onError: { error in
                    DispatchQueue.main.async {
                        self.speechSynthesisError = "Speech synthesis failed: \(error.localizedDescription)"
                        self.isSynthesizingSpeech = false
                    }
                }
            )
        }
    }
    
    private func playAudio(data: Data) {
        #if os(iOS)
        // Stop any existing playback
        audioPlayer?.stop()
        
        // Detect format and handle accordingly
        let audioData: Data
        if isMP3Data(data) {
            // OpenAI returns MP3 directly
            audioData = data
        } else {
            // Gemini returns PCM that needs WAV conversion
            audioData = createWavData(from: data, sampleRate: 24000, channels: 1, bitsPerSample: 16)
        }
        
        do {
            audioPlayer = try AVAudioPlayer(data: audioData)
            if let player = audioPlayer {
                player.delegate = soundDelegate
                if player.play() {
                    // isSynthesizingSpeech remains true until playback finishes or fails
                } else {
                    speechSynthesisError = "Failed to start audio playback."
                    isSynthesizingSpeech = false // Playback failed to start
                }
            }
        } catch {
            speechSynthesisError = "Failed to initialize audio player: \(error.localizedDescription)"
            isSynthesizingSpeech = false // Player initialization failed
        }
        #elseif os(macOS)
        // Stop any existing playback
        audioPlayer?.stop()
        
        // Detect format and handle accordingly
        let audioData: Data
        if isMP3Data(data) {
            // OpenAI returns MP3 directly
            audioData = data
        } else {
            // Gemini returns PCM that needs WAV conversion
            audioData = createWavData(from: data, sampleRate: 24000, channels: 1, bitsPerSample: 16)
        }
        
        audioPlayer = NSSound(data: audioData)
        if let player = audioPlayer {
            player.delegate = soundDelegate
            if player.play() {
                // isSynthesizingSpeech remains true until playback finishes or fails
            } else {
                speechSynthesisError = "Failed to start audio playback."
                isSynthesizingSpeech = false // Playback failed to start
            }
        } else {
            speechSynthesisError = "Failed to initialize audio player with data."
            isSynthesizingSpeech = false // Player initialization failed
        }
        #endif
    }
    
    private func speakSummaryLocally(_ text: String) {
        #if os(iOS)
        // Toggle off if already speaking
        if isSpeakingLocally {
            localSpeechSynth?.stopSpeaking(at: .immediate)
            isSpeakingLocally = false
            return
        }
        
        guard !text.isEmpty else {
            speechSynthesisError = "No summary available to read."
            return
        }
        
        // Stop any other audio playing
        audioPlayer?.stop()
        
        // Initialize speech synthesizer
        if localSpeechSynth == nil {
            localSpeechSynth = AVSpeechSynthesizer()
            localSpeechSynth?.delegate = soundDelegate
        }
        
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.volume = 1.0
        utterance.voice = AVSpeechSynthesisVoice(identifier: "com.apple.voice.premium.en-US.Ava")
        
        isSpeakingLocally = true
        isSynthesizingSpeech = false
        if let synth = localSpeechSynth {
            synth.speak(utterance)
        } else {
            isSpeakingLocally = false
            speechSynthesisError = "Failed to initialize speech synthesizer."
        }
        #elseif os(macOS)
        // Toggle off if already speaking
        if isSpeakingLocally {
            localSpeechSynth?.stopSpeaking()
            isSpeakingLocally = false
            return
        }
        
        guard !text.isEmpty else {
            speechSynthesisError = "No summary available to read."
            return
        }
        
        // Stop all other audio
        audioPlayer?.stop()
        
        let synth = NSSpeechSynthesizer()
        synth.delegate = soundDelegate
        
        isSpeakingLocally = true
        isSynthesizingSpeech = false
        if !synth.startSpeaking(text) {
            isSpeakingLocally = false
            speechSynthesisError = "Failed to start local speech synthesis."
        } else {
            localSpeechSynth = synth
        }
        #endif
    }
    
    private func copyToClipboard(_ text: String) {
        #if os(iOS)
        UIPasteboard.general.string = text
        #elseif os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
}

struct SummaryColumnView_Previews: PreviewProvider {
    static var previews: some View {
        SummaryColumnView()
            .environmentObject(AppState())
            .previewLayout(.sizeThatFits)
    }
}
