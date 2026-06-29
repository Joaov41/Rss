//
//  GlobalSummaryResultView.swift
//  RSSReader
//
//  Displays global summarization results in a readable format.
//

import SwiftUI
#if os(iOS)
import AVFoundation
import UIKit
#elseif os(macOS)
import AppKit
#endif
import Foundation

#if os(iOS)
private typealias KokoroAudioPlayer = AVAudioPlayer
#elseif os(macOS)
private typealias KokoroAudioPlayer = NSSound
#endif

// MARK: - Models (copied from AppState for local decoding)

struct GlobalSummaryItem: Codable, Identifiable {
    let id = UUID()
    let subject: String
    let summary: String
    let referenceId: String?
}

struct DecodedGlobalSummary: Codable {
    let source: String
    let summaries: [GlobalSummaryItem]
    let error: String?
}

// MARK: - Main View

struct GlobalSummaryResultView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    
    let json: String
    let error: String?
    
    // TTS State Variables
    @State private var isSynthesizingSpeech: Bool = false
    @State private var isSpeakingLocally: Bool = false
    @State private var speechSynthesisError: String? = nil
    #if os(iOS)
    @State private var audioPlayer: AVAudioPlayer?
    @State private var localSpeechSynth: AVSpeechSynthesizer?
    @StateObject private var soundDelegate = SoundDelegate()
    @State private var nextAudioChunk: Data? = nil
    @State private var ttsCanceled: Bool = false
    @State private var localTTSTask: Task<Void, Never>? = nil
    #elseif os(macOS)
    @State private var audioPlayer: NSSound?
    @State private var localSpeechSynth: NSSpeechSynthesizer?
    @StateObject private var soundDelegate = SoundDelegate()
    @State private var nextAudioChunk: Data? = nil
    @State private var ttsCanceled: Bool = false
    @State private var localTTSTask: Task<Void, Never>? = nil
    #endif

    // Q&A State Variables
    @State private var showQAInterface = false
    @State private var qaQuestionText: String = ""
    @State private var qaAnswerText: String = ""
    @State private var isProcessingQA = false
    @State private var qaInlineError: String?
    @State private var showAnswerSheet = false
    
    // Attempt to decode the JSON string
    private var decodedSummary: DecodedGlobalSummary? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(DecodedGlobalSummary.self, from: data)
    }
    
    private var parsedSummaries: [GlobalSummaryItem] {
        decodedSummary?.summaries ?? []
    }
    
    private var isRedditContent: Bool {
        decodedSummary?.source == "reddit"
    }
    
    private var hasSummaryContent: Bool {
        !parsedSummaries.isEmpty || !(appState.aggregateSummaryText?.isEmpty ?? true)
    }
    
    var body: some View {
        NavigationView {
            VStack(alignment: .leading, spacing: 12) {
                // Display error from AppState if it exists
                if let error = error, !error.isEmpty {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                        Text(error)
                            .font(.callout)
                            .foregroundColor(.primary)
                    }
                    .padding(10)
                    .background(.regularMaterial)
                    .cornerRadius(8)
                }
                
                // Overall Summary at the top (before individual summaries)
                if let aggregateText = appState.aggregateSummaryText {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Image(systemName: "sparkles")
                                .foregroundColor(.blue)
                            Text("Overall Summary")
                                .font(.headline)
                            if let providerName = appState.aggregateSummaryProviderName {
                                Text(providerName)
                                    .font(.caption)
                                    .fontWeight(.semibold)
                                    .foregroundColor(.secondary)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Capsule().fill(Color.secondary.opacity(0.12)))
                            }
                        }
                        Text(.init(aggregateText))
                            .font(.body)
                            .textSelection(.enabled)
                    }
                    .padding()
                    .background(.regularMaterial)
                    .cornerRadius(12)
                }

                if appState.isGeneratingAggregateSummary {
                    HStack {
                        ProgressView()
                            .scaleEffect(0.8)
                        Text("Generating overall summary...")
                            .foregroundColor(.secondary)
                    }
                }

                if let aggregateError = appState.aggregateSummaryError {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                        Text(aggregateError)
                            .foregroundColor(.secondary)
                    }
                }

                // Display the decoded summary or an error view (individual summaries)
                if let summary = decodedSummary {
                    DecodedSummaryListView(summary: summary)
                } else {
                    ContentUnavailableView(
                        "Invalid Summary Format",
                        systemImage: "exclamationmark.triangle",
                        description: Text("The summary data could not be read. This can happen if the AI model provides an incomplete or malformed response.")
                    )
                }

                Text("Depending on the number of posts, this may take a while.")
                    .foregroundColor(.secondary)
                    .padding(.bottom, 4)

                // TTS status indicators
                if isSynthesizingSpeech {
                    HStack {
                        ProgressView()
                            .scaleEffect(0.7)
                            .padding(.trailing, 5)
                        Text("Reading overview (Cloud TTS)...")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                } else if isSpeakingLocally {
                    HStack {
                        ProgressView()
                            .scaleEffect(0.7)
                            .padding(.trailing, 5)
                        Text("Reading overview (Local TTS)...")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                if let ttsError = speechSynthesisError {
                    Text(ttsError)
                        .font(.caption)
                        .foregroundColor(.red)
                }

                // Q&A Interface
                if showQAInterface {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Ask a question about these \(isRedditContent ? "Reddit discussions" : "articles")")
                            .font(.headline)
                        
                        TextField("Type your question...", text: $qaQuestionText)
                            .textFieldStyle(.roundedBorder)
                            .disabled(isProcessingQA || appState.isWaitingForGlobalQA)
                            .onSubmit {
                                askGlobalSummaryQuestion()
                            }
                        
                        HStack(spacing: 8) {
                            Button {
                                askGlobalSummaryQuestion()
                            } label: {
                                Label("Ask", systemImage: "questionmark.circle")
                                    .font(.subheadline)
                            }
                            .buttonStyle(LiquidGlassButtonStyle())
                            .disabled(qaQuestionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isProcessingQA || appState.isWaitingForGlobalQA)
                            
                            Button {
                                resetQAState(keepInterface: true)
                            } label: {
                                Label("Clear", systemImage: "xmark.circle")
                                    .font(.subheadline)
                            }
                            .buttonStyle(LiquidGlassButtonStyle())
                            .disabled(isProcessingQA || appState.isWaitingForGlobalQA)
                            
                            Spacer()
                        }
                        
                        if let inlineError = qaInlineError {
                            Text(inlineError)
                                .font(.caption)
                                .foregroundColor(.red)
                        } else if isProcessingQA || appState.isWaitingForGlobalQA {
                            HStack(spacing: 8) {
                                ProgressView()
                                    .scaleEffect(0.8)
                                Text(appState.globalQAWaitProgress.isEmpty ? "Thinking..." : appState.globalQAWaitProgress)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        } else if !qaAnswerText.isEmpty {
                            HStack {
                                Button {
                                    showAnswerSheet = true
                                } label: {
                                    Label("Open Answer", systemImage: "arrow.up.left.and.arrow.down.right")
                                        .font(.subheadline)
                                }
                                .buttonStyle(LiquidGlassButtonStyle())
                                
                                Button {
                                    copyToClipboard(text: qaAnswerText)
                                } label: {
                                    Label("Copy", systemImage: "doc.on.doc")
                                        .font(.subheadline)
                                }
                                .buttonStyle(LiquidGlassButtonStyle())
                                
                                Spacer()
                            }
                            .transition(.opacity.combined(with: .slide))
                        }
                    }
                    .padding()
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                }

                // Action buttons
                HStack(spacing: 8) {
                    Button {
                        #if os(iOS)
                        UIPasteboard.general.string = json
                        #elseif os(macOS)
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(json, forType: .string)
                        #endif
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(LiquidGlassButtonStyle())

                    Button {
                        appState.generateCombinedGlobalSummary()
                    } label: {
                        Label("Overall...", systemImage: "sparkles")
                    }
                    .buttonStyle(LiquidGlassButtonStyle())
                    .disabled(appState.isLoading || appState.isGeneratingAggregateSummary)

                    Button {
                        appState.retryLastGlobalSummary()
                    } label: {
                        Label("Reload", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(LiquidGlassButtonStyle())
                    .disabled(appState.isLoading || appState.lastGlobalSummaryContext == nil)

                    // Cloud TTS button
                    Button {
                        speakOverviewCloudTTS()
                    } label: {
                        Image(systemName: "speaker.wave.2")
                    }
                    .buttonStyle(LiquidGlassButtonStyle())
                    .ttsActiveGlow(isSynthesizingSpeech, color: .blue)
                    .help("Read aloud (Cloud TTS)")
                    .disabled(isSynthesizingSpeech || isSpeakingLocally || !hasSummaryContent)

                    // Local TTS button
                    Button {
                        speakOverviewLocally()
                    } label: {
                        Image(systemName: "speaker.wave.2.circle")
                    }
                    .buttonStyle(LiquidGlassButtonStyle())
                    .ttsActiveGlow(isSpeakingLocally, color: .green)
                    .help("Read aloud (Local TTS / MLX)")
                    .disabled(isSynthesizingSpeech || !hasSummaryContent)

                    // Stop button
                    Button {
                        stopOverviewSpeech()
                    } label: {
                        Image(systemName: "stop.fill")
                    }
                    .buttonStyle(LiquidGlassButtonStyle())
                    .help("Stop speech")
                    .disabled(!isSynthesizingSpeech && !isSpeakingLocally)
                    
                    // Q&A Toggle Button
                    Button {
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
                            if showQAInterface {
                                resetQAState()
                            } else {
                                showQAInterface = true
                            }
                        }
                    } label: {
                        Text("?")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(showQAInterface ? .white : .primary)
                            .frame(width: 28, height: 28)
                            .background(
                                Circle()
                                    .fill(.regularMaterial)
                                    .overlay(
                                        Circle()
                                            .fill(Color.accentColor)
                                            .opacity(showQAInterface ? 1 : 0)
                                    )
                            )
                    }
                    .buttonStyle(PlainButtonStyle())
                    .disabled(!hasSummaryContent)
                    .help("Ask a question about this overview")

                    Spacer()

                    Button {
                        dismiss()
                        appState.showGlobalSummary = false
                    } label: {
                        Label("Close", systemImage: "xmark.circle")
                    }
                    .buttonStyle(LiquidGlassButtonStyle())
                }
            }
            .padding()
            .navigationTitle("Global Summary")
            .navigationBarTitleDisplayMode(.inline)
        }
        .sheet(isPresented: $showAnswerSheet) {
            NavigationStack {
                ScrollView {
                    Text(.init(qaAnswerText.isEmpty ? "No answer available." : qaAnswerText))
                        .font(.body)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                        .textSelection(.enabled)
                }
                .navigationTitle("Summary Answer")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") {
                            showAnswerSheet = false
                        }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button {
                            copyToClipboard(text: qaAnswerText)
                        } label: {
                            Label("Copy", systemImage: "doc.on.doc")
                        }
                    }
                }
            }
            #if os(iOS)
            .presentationDetents([.medium, .large])
            .presentationCornerRadius(32)
            #endif
        }
    }
    
    // MARK: - Q&A Methods
    
    private func askGlobalSummaryQuestion() {
        guard !isProcessingQA && !appState.isWaitingForGlobalQA else { return }
        let trimmed = qaQuestionText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            qaInlineError = "Please enter a question first."
            return
        }
        
        qaInlineError = nil
        isProcessingQA = true
        qaAnswerText = ""
        
        appState.askQuestionAboutGlobalSummary(question: trimmed) { answer in
            DispatchQueue.main.async {
                self.qaAnswerText = formatAskAIResponseForDisplay(answer)
                self.isProcessingQA = false
                self.showAnswerSheet = true
            }
        }
    }
    
    private func resetQAState(keepInterface: Bool = false) {
        qaQuestionText = ""
        qaAnswerText = ""
        qaInlineError = nil
        isProcessingQA = false
        if !keepInterface {
            showQAInterface = false
        }
    }
    
    private func copyToClipboard(text: String) {
        guard !text.isEmpty else { return }
        #if os(iOS)
        UIPasteboard.general.string = text
        #elseif os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }

    // MARK: - TTS Methods

    /// Builds the full text to speak from available summary content
    private func buildSpeechText() -> String? {
        // Prefer overall summary if available
        if let aggregate = appState.aggregateSummaryText, !aggregate.isEmpty {
            return aggregate
        }
        // Fall back to concatenating individual summaries
        let items = parsedSummaries
        guard !items.isEmpty else { return nil }
        return items.map { "\($0.subject). \($0.summary)" }.joined(separator: "\n\n")
    }

    private func speakOverviewCloudTTS() {
        ttsCanceled = false
        guard let text = buildSpeechText(), !text.isEmpty else {
            speechSynthesisError = "No summary available to read."
            return
        }

        // Stop any currently playing sounds
        #if os(iOS)
        audioPlayer?.stop()
        audioPlayer = nil
        localSpeechSynth?.stopSpeaking(at: .immediate)
        #elseif os(macOS)
        audioPlayer?.stop()
        audioPlayer = nil
        ShortcutsTTS.shared.stopSpeaking()
        localSpeechSynth?.stopSpeaking()
        #endif

        isSynthesizingSpeech = true
        isSpeakingLocally = false
        speechSynthesisError = nil

        Task {
            await appState.summaryService.synthesizeSpeechFastStartSplit(
                text: text,
                onFirstChunk: { data in
                    DispatchQueue.main.async {
                        self.playAudio(data: data)
                    }
                },
                onRemainingReady: { data in
                    DispatchQueue.main.async {
                        #if os(iOS)
                        if let player = self.audioPlayer, player.isPlaying {
                            self.nextAudioChunk = data
                        } else {
                            self.playAudio(data: data)
                        }
                        #elseif os(macOS)
                        if let player = self.audioPlayer, player.isPlaying {
                            self.nextAudioChunk = data
                        } else {
                            self.playAudio(data: data)
                        }
                        #endif
                    }
                },
                onComplete: {
                    // Playback finished callback will clear state
                },
                onError: { error in
                    DispatchQueue.main.async {
                        self.speechSynthesisError = "Speech synthesis failed: \(error.localizedDescription)"
                        self.isSynthesizingSpeech = false
                        self.nextAudioChunk = nil
                    }
                }
            )
        }
    }

    private func stopOverviewSpeech() {
        ttsCanceled = true
        #if os(iOS)
        audioPlayer?.stop()
        audioPlayer = nil
        localSpeechSynth?.stopSpeaking(at: .immediate)
        #elseif os(macOS)
        audioPlayer?.stop()
        audioPlayer = nil
        ShortcutsTTS.shared.stopSpeaking()
        localSpeechSynth?.stopSpeaking()
        #endif
        localTTSTask?.cancel()
        localTTSTask = nil
        nextAudioChunk = nil
        isSynthesizingSpeech = false
        isSpeakingLocally = false
    }

    private func playAudio(data: Data) {
        #if os(iOS)
        audioPlayer?.stop()

        let audioData: Data
        if isMP3Data(data) || isAACData(data) {
            audioData = data
        } else {
            audioData = createWavData(from: data, sampleRate: 24000, channels: 1, bitsPerSample: 16)
        }

        do {
            audioPlayer = try AVAudioPlayer(data: audioData)
            if let player = audioPlayer {
                player.prepareToPlay()
                player.delegate = soundDelegate
                if !player.play() {
                    speechSynthesisError = "Failed to start audio playback."
                    isSynthesizingSpeech = false
                }
            }
        } catch {
            speechSynthesisError = "Failed to initialize audio player: \(error.localizedDescription)"
            isSynthesizingSpeech = false
        }
        #elseif os(macOS)
        audioPlayer?.stop()

        let audioData: Data
        if isMP3Data(data) || isAACData(data) {
            audioData = data
        } else {
            audioData = createWavData(from: data, sampleRate: 24000, channels: 1, bitsPerSample: 16)
        }

        audioPlayer = NSSound(data: audioData)
        if let player = audioPlayer {
            player.delegate = soundDelegate
            if !player.play() {
                speechSynthesisError = "Failed to start audio playback."
                isSynthesizingSpeech = false
            }
        } else {
            speechSynthesisError = "Failed to initialize audio player with data."
            isSynthesizingSpeech = false
        }
        #endif
    }

    private func speakOverviewLocally() {
        guard let text = buildSpeechText(), !text.isEmpty else {
            speechSynthesisError = "No summary available to read."
            return
        }

        #if os(iOS)
        // Check if Kokoro engine is selected
        let settings = PersistenceManager.shared.loadSettings()
        if settings.localTTSEngine == .kokoro {
            guard KokoroTTSService.shared.isAvailable else {
                isSpeakingLocally = false
                speechSynthesisError = "MLX TTS is not available. Add the MLXAudio package and model access."
                return
            }
            if isSpeakingLocally {
                localTTSTask?.cancel()
                localTTSTask = nil
                audioPlayer?.stop()
                localSpeechSynth?.stopSpeaking(at: .immediate)
                isSpeakingLocally = false
                return
            }
            audioPlayer?.stop()
            isSpeakingLocally = true
            isSynthesizingSpeech = false
            startKokoroPlaybackOverview(
                text: text,
                voice: settings.kokoroVoice,
                speed: settings.kokoroSpeed,
                setAudioPlayer: { player in audioPlayer = player },
                soundDelegate: soundDelegate,
                taskStore: &localTTSTask,
                onCompleted: {
                    isSpeakingLocally = false
                    localTTSTask = nil
                },
                onError: { message in
                    speechSynthesisError = message
                    isSpeakingLocally = false
                }
            )
            return
        }

        // Check if running on Mac as iPad app - use Shortcuts instead
        var isRunningOnMac = false
        if #available(iOS 14.0, *) {
            isRunningOnMac = ProcessInfo.processInfo.isiOSAppOnMac
        }

        if isRunningOnMac {
            if isSpeakingLocally {
                ShortcutsTTS.shared.stopSpeaking()
                isSpeakingLocally = false
                return
            }
            audioPlayer?.stop()
            isSpeakingLocally = true
            isSynthesizingSpeech = false

            let success = ShortcutsTTS.shared.speakText(text) {
                DispatchQueue.main.async {
                    self.isSpeakingLocally = false
                }
            }
            if !success {
                isSpeakingLocally = false
                speechSynthesisError = "Failed to start Shortcuts TTS"
            }
            return
        }

        // Original iOS code for real devices
        if isSpeakingLocally {
            localSpeechSynth?.stopSpeaking(at: .immediate)
            isSpeakingLocally = false
            return
        }

        audioPlayer?.stop()

        if localSpeechSynth == nil {
            localSpeechSynth = AVSpeechSynthesizer()
            localSpeechSynth?.delegate = soundDelegate
        }

        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = 0.52
        utterance.pitchMultiplier = 1.0
        utterance.volume = 1.0
        utterance.preUtteranceDelay = 0.0
        utterance.postUtteranceDelay = 0.0

        if let savedVoiceID = UserDefaults.standard.string(forKey: "LocalTTS.iOSOnMac.SelectedVoiceID"),
           !savedVoiceID.isEmpty,
           let savedVoice = AVSpeechSynthesisVoice(identifier: savedVoiceID) {
            if ProcessInfo.processInfo.isiOSAppOnMac && savedVoice.identifier.contains("com.apple.voice") {
                // Skip com.apple.voice on Mac
            } else {
                utterance.voice = savedVoice
            }
        }

        if utterance.voice == nil {
            let currentLang = AVSpeechSynthesisVoice.currentLanguageCode()
            let allVoices = AVSpeechSynthesisVoice.speechVoices()

            let availableVoices: [AVSpeechSynthesisVoice]
            if ProcessInfo.processInfo.isiOSAppOnMac {
                availableVoices = allVoices.filter {
                    $0.language == currentLang && !$0.identifier.contains("com.apple.voice")
                }
            } else {
                availableVoices = allVoices.filter { $0.language == currentLang }
            }

            let premiumVoices = availableVoices.filter { $0.quality == .premium }
            let enhancedVoices = availableVoices.filter { $0.quality == .enhanced }

            if let premium = premiumVoices.first {
                utterance.voice = premium
            } else if let enhanced = enhancedVoices.first {
                utterance.voice = enhanced
            } else {
                utterance.voice = AVSpeechSynthesisVoice(language: currentLang)
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
        #elseif os(macOS)
        // Check if Kokoro engine is selected
        let settings = PersistenceManager.shared.loadSettings()
        if settings.localTTSEngine == .kokoro {
            guard KokoroTTSService.shared.isAvailable else {
                isSpeakingLocally = false
                speechSynthesisError = "MLX TTS is not available. Add the MLXAudio package and model access."
                return
            }
            if isSpeakingLocally {
                localTTSTask?.cancel()
                localTTSTask = nil
                audioPlayer?.stop()
                isSpeakingLocally = false
                return
            }
            audioPlayer?.stop()
            isSpeakingLocally = true
            isSynthesizingSpeech = false
            startKokoroPlaybackOverview(
                text: text,
                voice: settings.kokoroVoice,
                speed: settings.kokoroSpeed,
                setAudioPlayer: { player in audioPlayer = player },
                soundDelegate: soundDelegate,
                taskStore: &localTTSTask,
                onCompleted: {
                    isSpeakingLocally = false
                    localTTSTask = nil
                },
                onError: { message in
                    speechSynthesisError = message
                    isSpeakingLocally = false
                }
            )
            return
        }

        // macOS native: use ShortcutsTTS
        if isSpeakingLocally {
            ShortcutsTTS.shared.stopSpeaking()
            isSpeakingLocally = false
            return
        }

        audioPlayer?.stop()
        isSpeakingLocally = true
        isSynthesizingSpeech = false

        let success = ShortcutsTTS.shared.speakText(text) {
            DispatchQueue.main.async {
                self.isSpeakingLocally = false
            }
        }

        if !success {
            isSpeakingLocally = false
            speechSynthesisError = "Failed to start Shortcuts TTS on macOS."
        }
        #endif
    }

    private func startKokoroPlaybackOverview(
        text: String,
        voice: String,
        speed: Double,
        setAudioPlayer: @escaping (KokoroAudioPlayer?) -> Void,
        soundDelegate: SoundDelegate,
        taskStore: inout Task<Void, Never>?,
        onCompleted: @escaping () -> Void,
        onError: @escaping (String) -> Void
    ) {
        _ = soundDelegate
        taskStore?.cancel()
        taskStore = Task {
            defer {
                if !PersistenceManager.shared.loadSettings().kokoroPrecacheEnabled {
                    KokoroTTSService.shared.unloadIfAllowed()
                }
                Task { @MainActor in
                    onCompleted()
                }
            }
            do {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }

                func makeKokoroChunks(from input: String) -> [String] {
                    let firstSize = min(240, input.count)
                    let firstChunk = String(input.prefix(firstSize))
                    let remaining = String(input.dropFirst(firstSize)).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !remaining.isEmpty else { return [firstChunk] }

                    var chunks: [String] = [firstChunk]
                    let sentences = remaining.components(separatedBy: CharacterSet(charactersIn: ".!?"))
                    var current = ""
                    let maxChunkSize = 420
                    for sentence in sentences {
                        let trimmedSentence = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
                        if trimmedSentence.isEmpty { continue }
                        let sentenceWithPunctuation = trimmedSentence + "."
                        if current.count + sentenceWithPunctuation.count <= maxChunkSize {
                            current += (current.isEmpty ? "" : " ") + sentenceWithPunctuation
                        } else {
                            if !current.isEmpty { chunks.append(current) }
                            current = sentenceWithPunctuation
                        }
                    }
                    if !current.isEmpty { chunks.append(current) }
                    return chunks
                }

                let chunks = makeKokoroChunks(from: trimmed)
                guard let firstChunk = chunks.first else { return }

                func playChunk(_ data: Data) async throws -> TimeInterval {
                    try await MainActor.run {
                        #if os(iOS)
                        do {
                            let player = try AVAudioPlayer(data: data)
                            player.delegate = nil
                            player.prepareToPlay()
                            setAudioPlayer(player)
                            if player.play() == false {
                                onError("Failed to start audio playback.")
                                throw NSError(domain: "KokoroPlayback", code: -1)
                            }
                            return player.duration
                        } catch {
                            onError("Failed to initialize audio player: \(error.localizedDescription)")
                            throw error
                        }
                        #elseif os(macOS)
                        guard let player = NSSound(data: data) else {
                            onError("Failed to initialize audio player.")
                            throw NSError(domain: "KokoroPlayback", code: -1)
                        }
                        setAudioPlayer(player)
                        if player.play() == false {
                            onError("Failed to start audio playback.")
                            throw NSError(domain: "KokoroPlayback", code: -1)
                        }
                        return player.duration
                        #endif
                    }
                }

                enum KokoroPlaybackError: Error { case timeout }

                func synthesizeWithTimeout(_ text: String) async throws -> Data {
                    try await withThrowingTaskGroup(of: Data.self) { group in
                        group.addTask {
                            try await KokoroTTSService.shared.synthesize(
                                text: text,
                                voice: voice,
                                speed: Float(speed)
                            )
                        }
                        group.addTask {
                            try await Task.sleep(nanoseconds: 20_000_000_000)
                            throw KokoroPlaybackError.timeout
                        }
                        let result = try await group.next()!
                        group.cancelAll()
                        return result
                    }
                }

                let firstData = try await synthesizeWithTimeout(firstChunk)
                if Task.isCancelled { return }
                var currentDuration = try await playChunk(firstData)

                if chunks.count == 1 { return }

                var nextIndex = 1
                var nextTask: Task<Data, Error>? = Task {
                    try await synthesizeWithTimeout(chunks[nextIndex])
                }
                defer { nextTask?.cancel() }

                while nextIndex < chunks.count {
                    try await Task.sleep(nanoseconds: UInt64(currentDuration * 1_000_000_000))
                    if Task.isCancelled { return }

                    guard let task = nextTask else { return }
                    let data = try await task.value
                    nextIndex += 1

                    if nextIndex < chunks.count {
                        nextTask = Task {
                            try await synthesizeWithTimeout(chunks[nextIndex])
                        }
                    } else {
                        nextTask = nil
                    }

                    currentDuration = try await playChunk(data)
                }
            } catch {
                if Task.isCancelled { return }
                await MainActor.run {
                    let message: String
                    if let kokoroError = error as? KokoroTTSServiceError, kokoroError == .notAvailable {
                        message = "MLX TTS is not available. Add the MLXAudio package and model access."
                    } else if String(describing: error).contains("timeout") {
                        message = "Kokoro is still loading models. Please wait a moment and try again."
                    } else {
                        message = "Kokoro TTS failed: \(error.localizedDescription)"
                    }
                    onError(message)
                }
            }
        }
    }
}

// MARK: - Sub-views

struct DecodedSummaryListView: View {
    let summary: DecodedGlobalSummary
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Display error from the JSON payload itself
                if let jsonError = summary.error, !jsonError.isEmpty {
                    HStack {
                        Image(systemName: "exclamationmark.shield.fill")
                            .foregroundColor(.red)
                        Text("Error in summary: \(jsonError)")
                            .font(.headline)
                    }
                }
                
                // Display each summary item
                ForEach(summary.summaries) { item in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(item.subject)
                            .font(.title2).bold()
                        
                        // This is where the Markdown is rendered
                        Text(.init(item.summary))
                            .font(.body)
                            .textSelection(.enabled)
                    }
                    .padding()
                    .background(.regularMaterial)
                    .cornerRadius(12)
                }
            }
            .padding(.vertical)
        }
    }
}
