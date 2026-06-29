import SwiftUI
import UniformTypeIdentifiers
#if os(iOS)
import AVFoundation
#elseif os(macOS)
import AppKit
#endif

struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.presentationMode) var presentationMode
    
    @State private var showingFileImporter = false
    @State private var showingFileExporter = false
    @State private var exportFileURL: URL?
    @State private var importResult: String?
    @State private var showingImportResult = false
    @State private var isImporting = false
    @State private var isExporting = false

    // Read-history migration (legacy → v2 sharded keys)
    @State private var isMigratingReadHistory = false
    @State private var deleteLegacyReadHistoryAfterMigration = true
    @State private var showReadHistoryMigrationConfirm = false
    @State private var resultAlertTitle: String = "Import Result"
    
    // TTS Settings
    @State private var selectedTTSProvider: TTSProvider = .openai  // DEFAULT TO OPENAI!
    @State private var selectedGeminiVoice: String = "Puck"
    @State private var selectedOpenAIVoice: String = "alloy"
    @State private var preloadingEnabled: Bool = true
    @State private var fallbackEnabled: Bool = true
    @State private var cacheSizeDisplay: String = "--"
    @State private var isClearingCaches: Bool = false
    @State private var isCleaningFailedModelDownloads: Bool = false
    @State private var failedModelDownloadCleanupStatus: String? = nil
    @State private var storageBreakdownItems: [AppStorageBreakdownItem] = []
    @State private var isLoadingStorageBreakdown: Bool = false
    @State private var isDeletingStorageBreakdown: Bool = false
    @State private var storageBreakdownStatus: String? = nil
    @State private var pendingStorageBreakdownDelete: AppStorageBreakdownItem? = nil
    @State private var showStorageBreakdownDeleteConfirm: Bool = false
    @State private var modelStorageItems: [LocalModelStorageItem] = []
    @State private var isLoadingModelStorage: Bool = false
    @State private var isDeletingModelStorage: Bool = false
    @State private var modelStorageStatus: String? = nil
    @State private var pendingModelStorageDelete: LocalModelStorageItem? = nil
    @State private var showModelStorageDeleteConfirm: Bool = false
    @State private var localTTSEngine: LocalTTSEngine = .system
    @State private var kokoroVoice: String = KokoroVoice.defaultVoice.rawValue
    @State private var kokoroSpeed: Double = 1.0
    @State private var kokoroPrecacheEnabled: Bool = false
    @State private var isKokoroPrewarming: Bool = false
    @State private var kokoroPrewarmStatus: String? = nil
    @State private var kokoroPrewarmError: String? = nil
    @AppStorage("geminiApiKey") private var geminiApiKey: String = ""
    @AppStorage("openaiApiKey") private var openaiApiKey: String = ""
    @AppStorage("enableTTS") private var enableTTS: Bool = false
    @AppStorage("ttsVoice") private var ttsVoice: String = "com.apple.ttsbundle.Samantha-compact"
    @AppStorage("ttsRate") private var ttsRate: Double = 0.5
    @AppStorage("ttsPitch") private var ttsPitch: Double = 1.0
    @AppStorage("ttsVolume") private var ttsVolume: Double = 1.0
    
    // Local TTS voice picker state
    @State private var localVoiceID: String = ""
    private let iosVoiceKey = "LocalTTS.iOSOnMac.SelectedVoiceID"
    private let macVoiceKey = "LocalTTS.Mac.SelectedVoiceID"
    #if os(iOS)
    @State private var iosVoices: [(id: String, title: String)] = []
    @State private var testSynthIOS: AVSpeechSynthesizer? = nil
    #elseif os(macOS)
    @State private var macVoices: [(id: String, name: String)] = []
    @State private var testSynthMac: NSSpeechSynthesizer? = nil
    #endif
    
    // Appearance Settings
    @AppStorage("appearanceMode") private var appearanceMode: Int = 0 // 0: System, 1: Light, 2: Dark
    
    // Health Check States
    @State private var isCheckingHealth: Bool = false
    @State private var geminiHealthCheck: (isWorking: Bool, responseTime: TimeInterval?, error: String?)? = nil
    @State private var openaiHealthCheck: (isWorking: Bool, responseTime: TimeInterval?, error: String?)? = nil

    // MLX Local model management
    @State private var isLoadingMLXModel = false
    @State private var mlxDownloadProgress: Progress? = nil
    @State private var mlxLoadError: String? = nil
    @State private var isPresentingMLXModelManager = false
    @State private var showDownloadLocationPicker = false
    @State private var isTestingSummarizeConnection = false
    @State private var summarizeConnectionStatus: String? = nil
    @State private var isTestingPCCGatewayConnection = false
    @State private var pccGatewayConnectionStatus: String? = nil
    private let mlxModelBookmarkKey = "MLXExternalModelBookmark"
    private let mlxModelPathKey = "MLXExternalModelPath"
    
    @Environment(\.colorScheme) var colorScheme

    private var settingsPreferredColorScheme: ColorScheme? {
        switch appearanceMode {
        case 1: return .light
        case 2: return .dark
        default: return nil
        }
    }

    private var effectiveSettingsColorScheme: ColorScheme {
        settingsPreferredColorScheme ?? colorScheme
    }

    private var settingsBackground: Color {
        effectiveSettingsColorScheme == .dark
            ? Color(red: 0.05, green: 0.05, blue: 0.1)
            : AppColors.background
    }

    private func launchWebAILogin(_ provider: WebAIProvider) {
        presentationMode.wrappedValue.dismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            appState.openWebAILoginSession(for: provider)
        }
    }
    
    var body: some View {
        settingsNavigationContainer {
            ZStack {
                settingsBackground
                    .ignoresSafeArea()
                
                Form {
                    Section("Appearance") {
                        Picker("Theme", selection: $appearanceMode) {
                            Label("System", systemImage: "circle.lefthalf.filled").tag(0)
                            Label("Light", systemImage: "sun.max.fill").tag(1)
                            Label("Dark", systemImage: "moon.fill").tag(2)
                        }
                        .pickerStyle(SegmentedPickerStyle())
                        .padding(.vertical, 4)
                    }
                    
                    Section("Summary Provider") {
                        Picker("Summary Source", selection: $appState.settings.selectedSummaryProvider) {
                            ForEach(AppSettings.SummaryProvider.allCases, id: \.self) { provider in
                                Text(provider.displayName)
                                    .tag(provider)
                            }
                        }
                        .pickerStyle(.menu)
                        .padding(.vertical, 4)
                        .onChange(of: appState.settings.selectedSummaryProvider) { newValue in
                            // Clear stale throughput labels immediately on provider switch
                            appState.mlxLastThroughput = ""
                            appState.mlxLastQAThroughput = ""
                            var newSettings = appState.settings
                            newSettings.selectedSummaryProvider = newValue
                            appState.updateSettings(newSettings)

                            if newValue != .mlxLocal && newValue != .coreAIMLXLocal {
                                // Offload local models when switching to a different provider
                                Task {
                                    await LiteRTLocalService.shared.unloadAllModels()
                                    await MLXLocalService.shared.unloadAllModels()
                                }
                            } else {
                                // Preload and warm up when switching to a local model
                                Task { await appState.warmUpMLXIfNeeded() }
                            }
                        }
                        
                    Text(summaryProviderDescription)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.top, 4)

                        Picker("Web AI Destination", selection: Binding(
                            get: { appState.settings.selectedWebAIProvider },
                            set: { newValue in
                                var newSettings = appState.settings
                                newSettings.selectedWebAIProvider = newValue
                                appState.updateSettings(newSettings)
                            }
                        )) {
                            ForEach(WebAIProvider.allCases) { provider in
                                Text(provider.displayName).tag(provider)
                            }
                        }
                        .pickerStyle(.segmented)
                        .padding(.top, 6)

                        Text(
                            appState.settings.selectedSummaryProvider == .webAI
                            ? "Web AI summaries use \(appState.settings.selectedWebAIProvider.displayName) in the in-app browser, send the prompt automatically when possible, and capture the reply back into the app."
                            : "Web-send buttons open \(appState.settings.selectedWebAIProvider.displayName) in an in-app browser, paste the prompt, and try to send it automatically."
                        )
                            .font(.caption)
                            .foregroundColor(.secondary)

                        VStack(alignment: .leading, spacing: 8) {
                            Text("Persistent Web AI Sessions")
                                .font(.subheadline)
                                .fontWeight(.semibold)

                            Text("Log in inside RSSReaderApp so ChatGPT and Gemini sessions are reused by the in-app WebAI browser.")
                                .font(.caption)
                                .foregroundColor(.secondary)

                            HStack(spacing: 10) {
                                Button("Log In to ChatGPT") {
                                    launchWebAILogin(.chatgpt)
                                }
                                .buttonStyle(.bordered)

                                Button("Reset ChatGPT") {
                                    appState.resetWebAISession(for: .chatgpt)
                                }
                                .buttonStyle(.bordered)
                            }

                            HStack(spacing: 10) {
                                Button("Log In to Gemini") {
                                    launchWebAILogin(.gemini)
                                }
                                .buttonStyle(.bordered)

                                Button("Reset Gemini") {
                                    appState.resetWebAISession(for: .gemini)
                                }
                                .buttonStyle(.bordered)
                            }
                        }

                        if appState.settings.selectedSummaryProvider == .mlxLocal {
                            mlxSettingsView
                        }

                        if appState.settings.selectedSummaryProvider == .coreAIMLXLocal {
                            coreAIMLXSettingsView
                        }

                        if appState.settings.selectedSummaryProvider == .summarizeDaemon {
                            summarizeSettingsView
                        }

                        if appState.settings.selectedSummaryProvider == .applePCCGateway {
                            pccGatewaySettingsView
                        }
                }

                Section("Cloud Sync") {
                    let persistenceManager = PersistenceManager.shared

                    Button {
                        appState.manualCloudRefresh()
                    } label: {
                        if appState.manualCloudSyncState == .syncing {
                            Label("Syncing…", systemImage: "arrow.triangle.2.circlepath.circle.fill")
                        } else if appState.manualCloudSyncState == .completed {
                            Label("Synced", systemImage: "checkmark.circle.fill")
                        } else {
                            Label("Sync Now", systemImage: "arrow.clockwise.circle.fill")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.blue)
                    .disabled(appState.manualCloudSyncState == .syncing)

                    Text("Pull the latest read states and subscriptions from iCloud immediately.")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    if let status = appState.manualCloudSyncStatusMessage {
                        Text(status)
                            .font(.caption)
                            .foregroundColor(.green)
                    }

                    if persistenceManager.isThisDevicePrimaryForSubscriptions {
                        Toggle("Delete legacy read history after migration (recommended)", isOn: $deleteLegacyReadHistoryAfterMigration)
                            .font(.subheadline)

                        Button {
                            showReadHistoryMigrationConfirm = true
                        } label: {
                            if isMigratingReadHistory {
                                Label("Migrating…", systemImage: "arrow.triangle.2.circlepath.icloud")
                            } else {
                                Label("Migrate Read History", systemImage: "arrow.triangle.2.circlepath.icloud")
                            }
                        }
                        .buttonStyle(.bordered)
                        .tint(.purple)
                        .disabled(isMigratingReadHistory)

                        if isMigratingReadHistory {
                            ProgressView()
                                .frame(maxWidth: .infinity, alignment: .center)
                        }

                        Text("One-time: seeds the new sync format so unread badge counts match across devices.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else {
                        Text("If unread badge counts differ, run “Migrate Read History” on your primary device once.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Section("Primary Device for Subscriptions") {
                    let persistenceManager = PersistenceManager.shared

                    if persistenceManager.isThisDevicePrimaryForSubscriptions {
                        // This device is primary
                        HStack {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                            VStack(alignment: .leading) {
                                Text("This device is primary")
                                    .font(.headline)
                                Text(persistenceManager.thisDeviceName)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        Text("Subscription changes made here sync to all your devices.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else if let primaryName = persistenceManager.primaryDeviceNameForSubscriptions {
                        // Another device is primary
                        HStack {
                            Image(systemName: "icloud.fill")
                                .foregroundColor(.blue)
                            VStack(alignment: .leading) {
                                Text("Syncing from:")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Text(primaryName)
                                    .font(.headline)
                            }
                        }

                        Text("Subscriptions are managed by the primary device. Changes made here won't sync to other devices.")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        Button {
                            persistenceManager.setThisDeviceAsPrimaryForSubscriptions()
                            // Force UI refresh
                            appState.objectWillChange.send()
                        } label: {
                            Label("Make this device primary", systemImage: "arrow.triangle.2.circlepath")
                        }
                        .buttonStyle(.bordered)
                        .tint(.orange)
                    } else {
                        // No primary device set
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                            Text("No primary device set")
                                .font(.headline)
                        }

                        Text("Set a primary device to prevent subscription duplicates across your devices.")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        Button {
                            persistenceManager.setThisDeviceAsPrimaryForSubscriptions()
                            // Force UI refresh
                            appState.objectWillChange.send()
                        } label: {
                            Label("Make this device primary", systemImage: "checkmark.circle")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.green)
                    }
                }
                    
                    Section("API Keys") {
                        SecureField("Gemini API Key", text: $geminiApiKey)
                            .textFieldStyle(AdaptiveLiquidGlassTextFieldStyle(
                                cornerRadius: 12,
                                tintColor: .purple.opacity(0.3)
                            ))
                            .onChange(of: geminiApiKey) { newValue in
                                var newSettings = appState.settings
                                newSettings.geminiApiKey = newValue
                                appState.updateSettings(newSettings)
                            }

                        SecureField("OpenAI API Key (for TTS)", text: $openaiApiKey)
                            .textFieldStyle(AdaptiveLiquidGlassTextFieldStyle(
                                cornerRadius: 12,
                                tintColor: .blue.opacity(0.3)
                            ))
                            .onChange(of: openaiApiKey) { newValue in
                                var newSettings = appState.settings
                                newSettings.openaiApiKey = newValue
                                appState.updateSettings(newSettings)
                            }
                    }

                    redditAuthSection

                    Section("Text-to-Speech") {
                        Toggle("Enable TTS", isOn: $enableTTS)
                        
                        if enableTTS {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Voice: \(ttsVoice)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                
                                Text("Rate: \(ttsRate, specifier: "%.2f")")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Slider(value: $ttsRate, in: 0.1...1.0, step: 0.1)
                                
                                Text("Pitch: \(ttsPitch, specifier: "%.2f")")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Slider(value: $ttsPitch, in: 0.5...2.0, step: 0.1)
                                
                                Text("Volume: \(ttsVolume, specifier: "%.2f")")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Slider(value: $ttsVolume, in: 0.1...1.0, step: 0.1)
                            }
                        }
                    }

                    Section("Local TTS Engine") {
                        Picker("Engine", selection: $localTTSEngine) {
                            ForEach(LocalTTSEngine.availableEngines) { engine in
                                Text(engine.displayName).tag(engine)
                            }
                        }
                        .onChange(of: localTTSEngine) { newValue in
                            appState.summaryService.setLocalTTSEngine(newValue)
                            var newSettings = appState.settings
                            newSettings.localTTSEngine = newValue
                            appState.updateSettings(newSettings)
                            if newValue == .kokoro {
                                kokoroVoice = appState.summaryService.getKokoroVoice()
                                kokoroSpeed = appState.summaryService.getKokoroSpeed()
                                kokoroPrecacheEnabled = appState.summaryService.isKokoroPrecacheEnabled()
                            }
                        }

                        if localTTSEngine == .kokoro && !KokoroTTSService.shared.isAvailable {
                            Text("MLX TTS requires the MLXAudio package and model access.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        } else if localTTSEngine == .kokoro {
                            Text("MLX TTS runs fully on device. First use may download large model assets.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        } else {
                            Text("Uses system voices for on-device speech.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    if localTTSEngine == .kokoro {
                        Section("MLX TTS") {
                            Picker("MLX Voice", selection: $kokoroVoice) {
                                ForEach(KokoroVoice.allCases) { voice in
                                    Text(voice.displayName).tag(voice.rawValue)
                                }
                            }
                            .onChange(of: kokoroVoice) { newValue in
                                appState.summaryService.setKokoroVoice(newValue)
                                kokoroVoice = appState.summaryService.getKokoroVoice()
                                var newSettings = appState.settings
                                newSettings.kokoroVoice = kokoroVoice
                                appState.updateSettings(newSettings)
                            }

                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text("Speed")
                                    Spacer()
                                    Text(String(format: "%.1fx", kokoroSpeed))
                                        .foregroundColor(.secondary)
                                }
                                Slider(
                                    value: Binding(
                                        get: { kokoroSpeed },
                                        set: { newValue in
                                            kokoroSpeed = newValue
                                            appState.summaryService.setKokoroSpeed(newValue)
                                            var newSettings = appState.settings
                                            newSettings.kokoroSpeed = kokoroSpeed
                                            appState.updateSettings(newSettings)
                                        }
                                    ),
                                    in: 0.5...2.0,
                                    step: 0.1
                                )
                            }

                            Button(action: {
                                isKokoroPrewarming = true
                                kokoroPrewarmError = nil
                                kokoroPrewarmStatus = nil
                                Task {
                                    do {
                                        try await appState.summaryService.precacheKokoroNow()
                                        await MainActor.run {
                                            isKokoroPrewarming = false
                                            kokoroPrewarmStatus = "MLX pre-cache complete"
                                            kokoroPrecacheEnabled = true
                                            var newSettings = appState.settings
                                            newSettings.kokoroPrecacheEnabled = true
                                            appState.updateSettings(newSettings)
                                        }
                                    } catch {
                                        await MainActor.run {
                                            isKokoroPrewarming = false
                                            kokoroPrewarmError = error.localizedDescription
                                        }
                                    }
                                }
                            }) {
                                HStack {
                                    if isKokoroPrewarming { ProgressView().scaleEffect(0.8) }
                                    else { Image(systemName: "bolt.circle") }
                                    Text("Pre-cache MLX TTS")
                                }
                            }
                            .buttonStyle(LiquidGlassButtonStyle(isProminent: true))
                            .disabled(isKokoroPrewarming || !KokoroTTSService.shared.isAvailable)

                            if kokoroPrecacheEnabled {
                                Text("Pre-cache enabled (loads models at launch).")
                                    .font(.caption)
                                    .foregroundColor(.secondary)

                                Button("Disable Pre-cache") {
                                    appState.summaryService.setKokoroPrecacheEnabled(false)
                                    kokoroPrecacheEnabled = false
                                    kokoroPrewarmStatus = "Pre-cache disabled (takes effect after relaunch)"
                                    var newSettings = appState.settings
                                    newSettings.kokoroPrecacheEnabled = false
                                    appState.updateSettings(newSettings)
                                }
                                .buttonStyle(LiquidGlassButtonStyle())
                            }

                            if let status = kokoroPrewarmStatus {
                                Text(status).font(.caption).foregroundColor(.green)
                            }
                            if let error = kokoroPrewarmError {
                                Text(error).font(.caption).foregroundColor(.red)
                            }
                        }
                    }
                    
                    // Local TTS voice picker (platform-specific, only lists working voices)
                    if localTTSEngine == .system {
                        Section("Local TTS Voice") {
                        #if os(iOS)
                        // iOS-on-Mac: show only ttsbundle English voices that AVSpeech can use
                        if iosVoices.isEmpty {
                            Text("No iOS voices available. Install voices in System Settings → Accessibility → Spoken Content → System Voice, then relaunch the app.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        } else {
                            Picker("Voice", selection: $localVoiceID) {
                                ForEach(iosVoices, id: \.id) { v in
                                    Text(v.title).tag(v.id)
                                }
                            }
                            .onChange(of: localVoiceID) { newID in
                                UserDefaults.standard.set(newID, forKey: iosVoiceKey)
                            }
                            HStack(spacing: 12) {
                                Button("Test") {
                                    let utterance = AVSpeechUtterance(string: "This is a test of the selected voice.")
                                    if let v = AVSpeechSynthesisVoice(identifier: localVoiceID) { utterance.voice = v }
                                    utterance.rate = AVSpeechUtteranceDefaultSpeechRate
                                    if testSynthIOS == nil { testSynthIOS = AVSpeechSynthesizer() }
                                    testSynthIOS?.speak(utterance)
                                }
                                Button("Set as Default") {
                                    UserDefaults.standard.set(localVoiceID, forKey: iosVoiceKey)
                                }
                            }
                        }
                        #elseif os(macOS)
                        // macOS: list NSSpeechSynthesizer voices (includes Ava Enhanced)
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
                                UserDefaults.standard.set(newID, forKey: macVoiceKey)
                            }
                            HStack(spacing: 12) {
                                Button("Test") {
                                    let synth = NSSpeechSynthesizer()
                                    _ = setMacSpeechVoice(synth, identifier: localVoiceID)
                                    synth.startSpeaking("This is a test of the selected voice.")
                                    testSynthMac = synth
                                }
                                Button("Set as Default") {
                                    UserDefaults.standard.set(localVoiceID, forKey: macVoiceKey)
                                }
                            }
                        }
                        #endif
                    }
                    }
                    
                    Section("OPML Management") {
                        Button(action: {
                            showingFileImporter = true
                        }) {
                            HStack {
                                if isImporting {
                                    ProgressView()
                                        .scaleEffect(0.8)
                                    Text("Importing...")
                                } else {
                                    Image(systemName: "square.and.arrow.down")
                                    Text("Import OPML")
                                }
                            }
                        }
                        .disabled(isImporting || isExporting)
                        .buttonStyle(AdaptiveLiquidGlassButtonStyle(tintColor: .blue.opacity(0.3)))
                        
                        Button(action: {
                            exportOPML()
                        }) {
                            HStack {
                                if isExporting {
                                    ProgressView()
                                        .scaleEffect(0.8)
                                    Text("Exporting...")
                                } else {
                                    Image(systemName: "square.and.arrow.up")
                                    Text("Export OPML")
                                }
                            }
                        }
                        .disabled(isExporting || appState.subscriptions.isEmpty || isImporting)
                        .buttonStyle(AdaptiveLiquidGlassButtonStyle(tintColor: .green.opacity(0.3)))
                    }

                    Section("Cache Management") {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text("Removable Cache Size:")
                                    .foregroundColor(.secondary)
                                Spacer()
                                Text(cacheSizeDisplay)
                                    .fontWeight(.semibold)
                            }

                            Button(action: {
                                isClearingCaches = true
                                appState.clearAllCaches {
                                    updateCacheSize()
                                    refreshStorageBreakdown()
                                    isClearingCaches = false
                                }
                            }) {
                                HStack {
                                    if isClearingCaches {
                                        ProgressView()
                                            .scaleEffect(0.8)
                                        Text("Clearing…")
                                    } else {
                                        Image(systemName: "trash.fill")
                                        Text("Clear All Caches")
                                    }
                                }
                                .frame(maxWidth: .infinity)
                            }
                            .disabled(isClearingCaches)
                            .buttonStyle(.borderedProminent)
                            .tint(.red)

                            Text("Clears removable caches and preserves downloaded LiteRT and MLX models.")
                                .font(.caption)
                                .foregroundColor(.secondary)

                            Divider()

                            Button(action: {
                                isCleaningFailedModelDownloads = true
                                failedModelDownloadCleanupStatus = nil
                                appState.clearFailedModelDownloads { message in
                                    failedModelDownloadCleanupStatus = message
                                    updateCacheSize()
                                    refreshStorageBreakdown()
                                    isCleaningFailedModelDownloads = false
                                }
                            }) {
                                HStack {
                                    if isCleaningFailedModelDownloads {
                                        ProgressView()
                                            .scaleEffect(0.8)
                                        Text("Cleaning…")
                                    } else {
                                        Image(systemName: "arrow.down.doc.fill")
                                        Text("Clean Failed Model Downloads")
                                    }
                                }
                                .frame(maxWidth: .infinity)
                            }
                            .disabled(isCleaningFailedModelDownloads)
                            .buttonStyle(.bordered)

                            Text("Removes only incomplete .download files. Completed LiteRT and MLX models are kept.")
                                .font(.caption)
                                .foregroundColor(.secondary)

                            if let failedModelDownloadCleanupStatus {
                                Text(failedModelDownloadCleanupStatus)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(.vertical, 8)
                    }

                    Section("Storage Breakdown") {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text("App Container")
                                    .foregroundColor(.secondary)
                                Spacer()
                                if isLoadingStorageBreakdown {
                                    ProgressView()
                                        .scaleEffect(0.8)
                                } else {
                                    Button {
                                        refreshStorageBreakdown()
                                    } label: {
                                        Image(systemName: "arrow.clockwise")
                                    }
                                    .buttonStyle(.borderless)
                                }
                            }

                            if storageBreakdownItems.isEmpty {
                                Text(isLoadingStorageBreakdown ? "Scanning storage…" : "No storage details found.")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            } else {
                                ForEach(storageBreakdownItems) { item in
                                    HStack(alignment: .top, spacing: 12) {
                                        Image(systemName: item.isModelStorage ? "cube.box.fill" : "folder.fill")
                                            .foregroundStyle(.secondary)
                                            .frame(width: 22, alignment: .center)

                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(item.name)
                                                .font(.subheadline)
                                                .fontWeight(.semibold)
                                                .lineLimit(1)
                                                .truncationMode(.tail)
                                            Text(item.detail)
                                                .font(.caption2)
                                                .foregroundColor(.secondary)
                                                .lineLimit(1)
                                                .truncationMode(.middle)
                                        }
                                        .frame(maxWidth: .infinity, alignment: .leading)

                                        Text(item.sizeText)
                                            .font(.caption)
                                            .fontWeight(.semibold)
                                            .foregroundColor(.secondary)
                                            .lineLimit(1)
                                            .fixedSize()
                                            .frame(minWidth: 64, alignment: .trailing)

                                        ZStack {
                                            if item.cleanupKind != nil || item.isModelStorage {
                                                Button(role: .destructive) {
                                                    pendingStorageBreakdownDelete = item
                                                    showStorageBreakdownDeleteConfirm = true
                                                } label: {
                                                    Image(systemName: "trash")
                                                }
                                                .buttonStyle(.borderless)
                                                .disabled(isDeletingStorageBreakdown)
                                            }
                                        }
                                        .frame(width: 24, alignment: .center)
                                    }
                                    .padding(.vertical, 3)
                                }
                            }

                            if let storageBreakdownStatus {
                                Text(storageBreakdownStatus)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }

                            Text("Removable cache rows exclude local models. Use the model rows or Local Model Storage to delete downloaded models.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.vertical, 8)
                        .padding(.horizontal, 4)
                    }

                    Section("Local Model Storage") {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text("Downloaded Models")
                                    .foregroundColor(.secondary)
                                Spacer()
                                if isLoadingModelStorage {
                                    ProgressView()
                                        .scaleEffect(0.8)
                                } else {
                                    Button {
                                        refreshModelStorage()
                                    } label: {
                                        Image(systemName: "arrow.clockwise")
                                    }
                                    .buttonStyle(.borderless)
                                }
                            }

                            if modelStorageItems.isEmpty {
                                Text(isLoadingModelStorage ? "Scanning model storage…" : "No local models found.")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            } else {
                                ForEach(modelStorageItems) { item in
                                    HStack(alignment: .top, spacing: 12) {
                                        Image(systemName: item.kind == .liteRT ? "cube.box.fill" : "cpu.fill")
                                            .foregroundStyle(.secondary)
                                            .frame(width: 22, alignment: .center)

                                        VStack(alignment: .leading, spacing: 3) {
                                            HStack(spacing: 6) {
                                                Text(item.name)
                                                    .font(.subheadline)
                                                    .fontWeight(.semibold)
                                                    .lineLimit(1)
                                                    .truncationMode(.middle)
                                                if item.isCurrentSelection {
                                                    Text("Current")
                                                        .font(.caption2)
                                                        .padding(.horizontal, 6)
                                                        .padding(.vertical, 2)
                                                        .background(.blue.opacity(0.18))
                                                        .clipShape(Capsule())
                                                }
                                            }
                                            Text("\(item.kind.rawValue) • \(item.detail)")
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                                .lineLimit(1)
                                                .truncationMode(.middle)
                                        }
                                        .frame(maxWidth: .infinity, alignment: .leading)

                                        Text(item.sizeText)
                                            .font(.caption)
                                            .fontWeight(.semibold)
                                            .foregroundColor(.secondary)
                                            .lineLimit(1)
                                            .fixedSize()
                                            .frame(minWidth: 64, alignment: .trailing)

                                        Button(role: .destructive) {
                                            pendingModelStorageDelete = item
                                            showModelStorageDeleteConfirm = true
                                        } label: {
                                            Image(systemName: "trash")
                                        }
                                        .buttonStyle(.borderless)
                                        .disabled(isDeletingModelStorage)
                                        .frame(width: 24, alignment: .center)
                                    }
                                    .padding(.vertical, 4)
                                }
                            }

                            if let modelStorageStatus {
                                Text(modelStorageStatus)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }

                            Text("Deleting a model removes only that selected model. Other app caches and other models are left alone.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.vertical, 8)
                        .padding(.horizontal, 4)
                    }

                    Section("Actions") {
                        Button("Clear All Data") {
                            // Clear data action
                        }
                        .buttonStyle(AdaptiveLiquidGlassButtonStyle(tintColor: .red.opacity(0.3)))

                        Button("Reset to Defaults") {
                            // Reset action
                        }
                        .buttonStyle(AdaptiveLiquidGlassButtonStyle(tintColor: .orange.opacity(0.3)))
                    }
                }
                .scrollContentBackground(.hidden) // Hide default form background
                #if os(macOS)
                .formStyle(.grouped)
                .frame(minWidth: 700, idealWidth: 820, maxWidth: .infinity)
                #endif
                .safeAreaPadding(.horizontal, 24)
                .safeAreaPadding(.vertical, 8)
                .clipShape(RoundedRectangle(cornerRadius: 25, style: .continuous))
                .padding()
            }
            .navigationTitle("Settings")
            #if os(iOS)
            .navigationBarItems(
                trailing: Button("Done") {
                    presentationMode.wrappedValue.dismiss()
                }
            )
            #elseif os(macOS)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Done") {
                        presentationMode.wrappedValue.dismiss()
                    }
                }
            }
            #endif
            .fileImporter(
                isPresented: $showingFileImporter,
                allowedContentTypes: [.xml, .plainText, .data],
                allowsMultipleSelection: false
            ) { result in
                handleFileImport(result)
            }
            .fileImporter(
                isPresented: $showDownloadLocationPicker,
                allowedContentTypes: [.folder],
                allowsMultipleSelection: false
            ) { result in
                handleDownloadLocationPicker(result)
            }
            .fileExporter(
                isPresented: $showingFileExporter,
                document: exportFileURL != nil ? OPMLDocument(url: exportFileURL!) : nil,
                contentType: .xml,
                defaultFilename: "RSS_Subscriptions"
            ) { result in
                handleFileExport(result)
            }
            .alert(resultAlertTitle, isPresented: $showingImportResult) {
                Button("OK", role: .cancel) {
                    importResult = nil
                }
            } message: {
                Text(importResult ?? "")
            }
            .confirmationDialog("Migrate Read History", isPresented: $showReadHistoryMigrationConfirm, titleVisibility: .visible) {
                Button("Cancel", role: .cancel) {}
                Button(deleteLegacyReadHistoryAfterMigration ? "Migrate & Delete Legacy Keys" : "Migrate", role: deleteLegacyReadHistoryAfterMigration ? .destructive : nil) {
                    startReadHistoryMigration()
                }
            } message: {
                Text(deleteLegacyReadHistoryAfterMigration
	                     ? "This will copy legacy read history into the new sync format and then delete the legacy keys. Make sure all your devices are updated before doing this."
	                     : "This will copy legacy read history into the new sync format. You can delete the legacy keys later to free iCloud KVS space.")
            }
            .confirmationDialog("Delete Local Model", isPresented: $showModelStorageDeleteConfirm, titleVisibility: .visible, presenting: pendingModelStorageDelete) { item in
                Button("Delete \(item.name)", role: .destructive) {
                    deleteModelStorageItem(item)
                }
                Button("Cancel", role: .cancel) {}
            } message: { item in
                Text("This will delete \(item.name) and free \(item.sizeText). The model can be downloaded again later.")
            }
            .confirmationDialog("Delete Storage", isPresented: $showStorageBreakdownDeleteConfirm, titleVisibility: .visible, presenting: pendingStorageBreakdownDelete) { item in
                Button("Delete \(item.name)", role: .destructive) {
                    deleteStorageBreakdownItem(item)
                }
                Button("Cancel", role: .cancel) {}
            } message: { item in
                if item.isModelStorage {
                    Text("This will delete \(item.name). The model can be downloaded again later.")
                } else {
                    Text("This will delete removable files from \(item.name). LiteRT and MLX model folders are preserved.")
                }
            }
            .onAppear {
                loadCurrentSettings()
                updateCacheSize()
                refreshStorageBreakdown()
                refreshModelStorage()
                loadLocalVoices()
            }
        }
        .preferredColorScheme(settingsPreferredColorScheme)
        .environment(\.colorScheme, effectiveSettingsColorScheme)
        .modifier(AdaptiveGlassModifier(cornerRadius: 40))
    }

    @ViewBuilder
    private func settingsNavigationContainer<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        #if os(macOS)
        NavigationStack {
            content()
        }
        #else
        NavigationView {
            content()
        }
        #endif
    }
    
    private func loadCurrentSettings() {
        selectedTTSProvider = appState.summaryService.getTTSProvider()
        
        // Load the correct voice for each provider
        let persistenceManager = PersistenceManager.shared
        let settings = persistenceManager.loadSettings()
        selectedGeminiVoice = settings.selectedGeminiVoice.isEmpty ? "Puck" : settings.selectedGeminiVoice
        selectedOpenAIVoice = settings.selectedOpenAIVoice.isEmpty ? "alloy" : settings.selectedOpenAIVoice
        
        geminiApiKey = appState.settings.geminiApiKey
        openaiApiKey = appState.summaryService.getOpenAIApiKey()
        localTTSEngine = appState.summaryService.getLocalTTSEngine()
        kokoroVoice = appState.summaryService.getKokoroVoice()
        kokoroSpeed = appState.summaryService.getKokoroSpeed()
        kokoroPrecacheEnabled = appState.summaryService.isKokoroPrecacheEnabled()
        // Load other settings from UserDefaults if needed
        preloadingEnabled = true
        fallbackEnabled = true
    }
    
    private func updateCacheSize() {
        cacheSizeDisplay = appState.getCacheSize()
    }

    private func refreshStorageBreakdown() {
        isLoadingStorageBreakdown = true
        appState.loadAppStorageBreakdown { items in
            storageBreakdownItems = items
            isLoadingStorageBreakdown = false
        }
    }

    private func deleteStorageBreakdownItem(_ item: AppStorageBreakdownItem) {
        isDeletingStorageBreakdown = true
        storageBreakdownStatus = nil
        appState.deleteAppStorageBreakdownItem(item) { message in
            storageBreakdownStatus = message
            isDeletingStorageBreakdown = false
            updateCacheSize()
            refreshStorageBreakdown()
            refreshModelStorage()
        }
    }

    private func refreshModelStorage() {
        isLoadingModelStorage = true
        appState.loadLocalModelStorage { items in
            modelStorageItems = items
            isLoadingModelStorage = false
        }
    }

    private func deleteModelStorageItem(_ item: LocalModelStorageItem) {
        isDeletingModelStorage = true
        modelStorageStatus = nil
        appState.deleteLocalModelStorageItem(item) { message in
            modelStorageStatus = message
            isDeletingModelStorage = false
            refreshModelStorage()
            refreshStorageBreakdown()
            updateCacheSize()
        }
    }

    private func startReadHistoryMigration() {
        guard !isMigratingReadHistory else { return }
        isMigratingReadHistory = true
        let deleteLegacy = deleteLegacyReadHistoryAfterMigration

        DispatchQueue.global(qos: .userInitiated).async {
            let result = CloudSyncManager.shared.migrateLegacyReadHistoryToV2(deleteLegacyKeys: deleteLegacy)
            DispatchQueue.main.async {
                isMigratingReadHistory = false

                if result.migrated {
                    importResult = """
                    Legacy: \(result.legacyArticlesCount) articles, \(result.legacyRedditCount) Reddit.
                    Seeded v2: +\(result.articlesAdded) articles, +\(result.redditAdded) Reddit.
                    Deleted legacy keys: \(result.deletedLegacyKeys ? "Yes" : "No").
                    """
                } else {
                    importResult = "Migration skipped. Run this on the primary device."
                }

                resultAlertTitle = "Read History Migration"
                showingImportResult = true
            }
        }
    }
    
    private func checkTTSHealth() {
        isCheckingHealth = true

        Task {
            let result = await appState.summaryService.checkBothProvidersHealth()

            await MainActor.run {
                geminiHealthCheck = result.gemini
                openaiHealthCheck = result.openai
                isCheckingHealth = false
            }
        }
    }
    
    private func handleFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let files):
            if let file = files.first {
                // Start import process
                isImporting = true
                appState.importOPMLFromURL(file) { result in
                    isImporting = false
                    switch result {
                    case .success(let count):
                        if count > 0 {
                            importResult = "Successfully imported \(count) new subscription(s)"
                        } else {
                            importResult = "No new subscriptions were found in the OPML file"
                        }
                    case .failure(let error):
                        importResult = "Import failed: \(error.localizedDescription)"
                    }
                    resultAlertTitle = "Import Result"
                    showingImportResult = true
                }
            }
        case .failure(let error):
            importResult = "Error selecting file: \(error.localizedDescription)"
            resultAlertTitle = "Import Result"
            showingImportResult = true
        }
    }
    
    private func exportOPML() {
        isExporting = true
        
        appState.exportOPMLToFile { result in
            DispatchQueue.main.async {
                isExporting = false
                
                switch result {
                case .success(let fileURL):
                    // Store the file URL and show the file exporter
                    exportFileURL = fileURL
                    showingFileExporter = true
                case .failure(let error):
                    importResult = "Export failed: \(error.localizedDescription)"
                    resultAlertTitle = "Import Result"
                    showingImportResult = true
                }
            }
        }
    }
    
    private func handleFileExport(_ result: Result<URL, Error>) {
        switch result {
        case .success(let savedURL):
            importResult = "OPML file exported successfully to \(savedURL.lastPathComponent)"
            resultAlertTitle = "Import Result"
            showingImportResult = true
        case .failure(let error):
            importResult = "Export failed: \(error.localizedDescription)"
            resultAlertTitle = "Import Result"
            showingImportResult = true
        }
        
        // Clean up temporary file if it exists
        if let tempURL = exportFileURL {
            try? FileManager.default.removeItem(at: tempURL)
            exportFileURL = nil
        }
    }
    
    private var redditAuthSection: some View {
        Section("Reddit Authentication") {
            VStack(alignment: .leading, spacing: 12) {
                Text("1. Register your app at reddit.com/prefs/apps")
                    .font(.caption)
                    .foregroundColor(.secondary)

                TextField("Reddit Client ID", text: Binding(
                    get: { appState.settings.redditClientId },
                    set: { newValue in
                        var newSettings = appState.settings
                        newSettings.redditClientId = newValue
                        appState.updateSettings(newSettings)
                    }
                ))
                .textFieldStyle(AdaptiveLiquidGlassTextFieldStyle(
                    cornerRadius: 12,
                    tintColor: .orange.opacity(0.3)
                ))
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                #endif

                if appState.redditOAuthManager.isAuthenticated {
                    redditAuthenticatedView
                } else if !appState.settings.redditClientId.isEmpty {
                    redditSignInView
                } else {
                    Text("Enter your Client ID above to enable OAuth")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
            }
            .padding(.vertical, 8)
        }
    }

    private var redditAuthenticatedView: some View {
        Group {
            HStack(spacing: 12) {
                VStack(alignment: .leading) {
                    Text("Logged in as")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("u/\(appState.redditOAuthManager.username)")
                        .font(.headline)
                }
                Spacer()
                Button("Refresh Token") {
                    appState.redditOAuthManager.refreshAccessToken { result in
                        switch result {
                        case .success:
                            print("🔐 RedditOAuth: Token refreshed manually from SettingsView")
                        case .failure(let error):
                            print("❌ RedditOAuth: Manual token refresh failed: \(error.localizedDescription)")
                        }
                    }
                }
                .buttonStyle(.bordered)

                Button("Logout") {
                    appState.redditOAuthManager.logout()
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }
            .padding(.vertical, 8)

            Text("✅ Using OAuth - Higher rate limits (600 req/10min)")
                .font(.caption)
                .foregroundColor(.green)
        }
    }

    private var redditSignInView: some View {
        Group {
            Button(action: {
                appState.redditOAuthManager.startOAuthFlow { result in
                    switch result {
                    case .success:
                        print("✅ Successfully authenticated with Reddit")
                    case .failure(let error):
                        print("❌ Reddit auth failed: \(error.localizedDescription)")
                    }
                }
            }) {
                HStack {
                    Image(systemName: "person.circle.fill")
                    Text("Sign in with Reddit")
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)

            Text("⚠️ Using public API - Limited to ~60 requests/min")
                .font(.caption)
                .foregroundColor(.orange)
        }
    }

    private var summaryProviderDescription: String {
        switch appState.settings.selectedSummaryProvider {
        case .gemini:
            return "Uses Google's Gemini API for summaries (requires API key)"
        case .appleLocal:
            return "Uses Apple's on-device AI for private summaries"
        case .appleCloud:
            return "Uses Apple Intelligence cloud AI via Shortcuts"
        case .applePCCGateway:
            #if os(macOS)
            return "Runs /usr/bin/fm respond --model pcc locally on this Mac"
            #else
            return "Uses a token-protected Mac gateway that forwards OpenAI-style requests to fm serve with the pcc model"
            #endif
        case .mlxLocal:
            return "Runs Gemma locally with LiteRT-LM acceleration using .litertlm model files"
        case .coreAIMLXLocal:
            return "Runs an MLX-format model locally through CoreAI MLX for direct comparison with LiteRT"
        case .webAI:
            return "Uses the selected web AI destination as the live summary provider and captures replies back into the app"
        case .summarizeDaemon:
            return "Uses the local Summarize daemon with Codex gpt-5.5 on fast tier, low reasoning, and low verbosity"
        }
    }

    // MARK: - Apple PCC Gateway Settings View
    @ViewBuilder
    private var pccGatewaySettingsView: some View {
        VStack(alignment: .leading, spacing: 10) {
            #if os(macOS)
            Text("Apple PCC")
                .font(.subheadline)
                .fontWeight(.semibold)

            Text("Runs /usr/bin/fm respond --model pcc locally on this Mac. If this beta blocks PCC from the app process, RSSReader retries through a minimized Terminal helper.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button {
                isTestingPCCGatewayConnection = true
                pccGatewayConnectionStatus = "Testing..."
                appState.testPCCGatewayConnection { result in
                    isTestingPCCGatewayConnection = false
                    switch result {
                    case .success(let message):
                        pccGatewayConnectionStatus = message.isEmpty ? "Connected" : message
                    case .failure(let error):
                        pccGatewayConnectionStatus = "Connection failed: \(error.localizedDescription)"
                    }
                }
            } label: {
                if isTestingPCCGatewayConnection {
                    Label("Testing...", systemImage: "arrow.triangle.2.circlepath")
                } else {
                    Label("Check PCC", systemImage: "bolt.horizontal.circle")
                }
            }
            .buttonStyle(.bordered)
            .disabled(isTestingPCCGatewayConnection)

            if let pccGatewayConnectionStatus {
                Text(pccGatewayConnectionStatus)
                    .font(.caption)
                    .foregroundStyle(pccGatewayConnectionStatus.localizedCaseInsensitiveContains("failed") ? Color.secondary : Color.green)
            }
            #else
            Text("Apple PCC Gateway")
                .font(.subheadline)
                .fontWeight(.semibold)

            Text("Run scripts/start-fm-pcc-gateway.command on your Mac, then use this Mac IP from iPhone/iPad.")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextField("Mac host or IP", text: Binding(
                get: { appState.settings.pccGatewayHost },
                set: { appState.setPCCGatewayHost($0) }
            ))
            .textFieldStyle(AdaptiveLiquidGlassTextFieldStyle(
                cornerRadius: 12,
                tintColor: .cyan.opacity(0.3)
            ))
            #if os(iOS)
            .keyboardType(.numbersAndPunctuation)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            #endif

            Stepper(
                "Gateway port: \(appState.settings.pccGatewayPort)",
                value: Binding(
                    get: { appState.settings.pccGatewayPort },
                    set: { appState.setPCCGatewayPort($0) }
                ),
                in: 1...65_535
            )

            TextField("Model", text: Binding(
                get: { appState.settings.pccGatewayModel },
                set: { appState.setPCCGatewayModel($0) }
            ))
            .textFieldStyle(AdaptiveLiquidGlassTextFieldStyle(
                cornerRadius: 12,
                tintColor: .cyan.opacity(0.3)
            ))
            #if os(iOS)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            #endif

            SecureField("Gateway token", text: Binding(
                get: { appState.settings.pccGatewayToken },
                set: { appState.setPCCGatewayToken($0) }
            ))
            .textFieldStyle(AdaptiveLiquidGlassTextFieldStyle(
                cornerRadius: 12,
                tintColor: .cyan.opacity(0.3)
            ))
            #if os(iOS)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            #endif

            Button {
                isTestingPCCGatewayConnection = true
                pccGatewayConnectionStatus = "Testing..."
                appState.testPCCGatewayConnection { result in
                    isTestingPCCGatewayConnection = false
                    switch result {
                    case .success:
                        pccGatewayConnectionStatus = "Connected"
                    case .failure(let error):
                        pccGatewayConnectionStatus = "Connection failed: \(error.localizedDescription)"
                    }
                }
            } label: {
                if isTestingPCCGatewayConnection {
                    Label("Testing...", systemImage: "arrow.triangle.2.circlepath")
                } else {
                    Label("Test Connection", systemImage: "bolt.horizontal.circle")
                }
            }
            .buttonStyle(.bordered)
            .disabled(isTestingPCCGatewayConnection)

            if let pccGatewayConnectionStatus {
                Text(pccGatewayConnectionStatus)
                    .font(.caption)
                    .foregroundStyle(pccGatewayConnectionStatus == "Connected" ? .green : .secondary)
            }
            #endif
        }
        .padding(.top, 8)
    }

    // MARK: - Summarize Settings View
    @ViewBuilder
    private var summarizeSettingsView: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Summarize Bridge")
                .font(.subheadline)
                .fontWeight(.semibold)

            Text("On iPad, use the bridge secret/pass from the Mac setup. Leave the Mac host/IP empty for automatic discovery, or enter the Mac IP if discovery is blocked.")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextField("Mac host or IP", text: Binding(
                get: { appState.settings.summarizeBridgeHost },
                set: { appState.setSummarizeBridgeHost($0) }
            ))
            .textFieldStyle(AdaptiveLiquidGlassTextFieldStyle(
                cornerRadius: 12,
                tintColor: .indigo.opacity(0.3)
            ))
            #if os(iOS)
            .keyboardType(.numbersAndPunctuation)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            #endif

            Stepper(
                "Bridge port: \(appState.settings.summarizeBridgePort)",
                value: Binding(
                    get: { appState.settings.summarizeBridgePort },
                    set: { appState.setSummarizeBridgePort($0) }
                ),
                in: 1...65_535
            )

            Text("Bridge secret/pass from Mac")
                .font(.caption)
                .foregroundStyle(.secondary)

            SecureField("Bridge secret/pass", text: Binding(
                get: { appState.settings.summarizeBridgeSecret },
                set: { appState.setSummarizeBridgeSecret($0) }
            ))
            .textFieldStyle(AdaptiveLiquidGlassTextFieldStyle(
                cornerRadius: 12,
                tintColor: .indigo.opacity(0.3)
            ))
            #if os(iOS)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            #endif

            #if os(macOS)
            SecureField("Daemon token (Mac)", text: Binding(
                get: { appState.settings.summarizeDaemonToken },
                set: { appState.setSummarizeDaemonToken($0) }
            ))
            .textFieldStyle(AdaptiveLiquidGlassTextFieldStyle(
                cornerRadius: 12,
                tintColor: .indigo.opacity(0.3)
            ))

            Text("The gateway config should use \(RSSSummarizeGatewayConfig.codexModel) with fast service tier, low reasoning, and low verbosity. The in-app model label is \(appState.settings.summarizeDaemonModel).")
                .font(.caption)
                .foregroundStyle(.secondary)
            #endif

            Button {
                isTestingSummarizeConnection = true
                summarizeConnectionStatus = "Testing..."
                appState.testSummarizeConnection { result in
                    isTestingSummarizeConnection = false
                    switch result {
                    case .success:
                        summarizeConnectionStatus = "Connected"
                    case .failure(let error):
                        summarizeConnectionStatus = "Connection failed: \(error.localizedDescription)"
                    }
                }
            } label: {
                if isTestingSummarizeConnection {
                    Label("Testing...", systemImage: "arrow.triangle.2.circlepath")
                } else {
                    Label("Test Connection", systemImage: "bolt.horizontal.circle")
                }
            }
            .buttonStyle(.bordered)
            .disabled(isTestingSummarizeConnection)

            if let summarizeConnectionStatus {
                Text(summarizeConnectionStatus)
                    .font(.caption)
                    .foregroundStyle(summarizeConnectionStatus == "Connected" ? .green : .secondary)
            }
        }
        .padding(.top, 8)
        .onAppear {
            #if os(iOS)
            if appState.settings.summarizeBridgeHost.trimmingCharacters(in: .whitespacesAndNewlines) == "127.0.0.1" {
                appState.setSummarizeBridgeHost("")
            }
            #endif
        }
    }

    // MARK: - Local Model Settings View
    @ViewBuilder
    private var mlxSettingsView: some View {
        VStack(alignment: .leading, spacing: 10) {
            let effectiveContextTokens = AppSettings.effectiveLiteRTContextTokens(appState.settings.mlxMaxContextTokens)
            let maxOutputTokens = max(64, min(4096, effectiveContextTokens - max(256, effectiveContextTokens / 4)))

            TextField("LiteRT Hugging Face Repo", text: Binding(
                get: { appState.settings.mlxModelID },
                set: { newValue in
                    var newSettings = appState.settings
                    newSettings.mlxModelID = LiteRTLocalService.normalizedModelID(newValue)
                    appState.updateSettings(newSettings)
                }
            ))
            .textFieldStyle(AdaptiveLiquidGlassTextFieldStyle(
                cornerRadius: 12,
                tintColor: .orange.opacity(0.3)
            ))
            .onSubmit {
                Task { await appState.warmUpMLXIfNeeded() }
            }

            Text("Use a LiteRT-LM repo such as \(LiteRTLocalService.defaultModelRepo).")
                .font(.caption)
                .foregroundStyle(.secondary)

            Stepper(
                value: Binding(
                    get: { appState.settings.mlxMaxContextTokens },
                    set: { newValue in
                        var newSettings = appState.settings
                        newSettings.mlxMaxContextTokens = AppSettings.normalizedLiteRTContextTokens(newValue)
                        newSettings.mlxMaxOutputTokens = AppSettings.normalizedLiteRTOutputTokens(
                            newSettings.mlxMaxOutputTokens,
                            contextTokens: AppSettings.effectiveLiteRTContextTokens(newSettings.mlxMaxContextTokens)
                        )
                        appState.updateSettings(newSettings)
                    }
                ),
                in: 0...LiteRTLocalService.maxContextTokens,
                step: LiteRTLocalService.defaultContextTokens
            ) {
                Text(
                    "Context tokens: " + (appState.settings.mlxMaxContextTokens == 0
                        ? "Auto"
                        : "\(appState.settings.mlxMaxContextTokens)")
                )
            }

            Stepper(
                value: Binding(
                    get: { appState.settings.mlxMaxOutputTokens },
                    set: { newValue in
                        var newSettings = appState.settings
                        newSettings.mlxMaxOutputTokens = AppSettings.normalizedLiteRTOutputTokens(
                            newValue,
                            contextTokens: AppSettings.effectiveLiteRTContextTokens(newSettings.mlxMaxContextTokens)
                        )
                        appState.updateSettings(newSettings)
                    }
                ),
                in: 64...maxOutputTokens,
                step: 128
            ) {
                Text("Max output tokens: \(appState.settings.mlxMaxOutputTokens)")
            }

            Button(action: {
                preloadLiteRTModel()
            }) {
                HStack {
                    if isLoadingMLXModel {
                        ProgressView()
                            .scaleEffect(0.8)
                    } else {
                        Image(systemName: "arrow.down.circle")
                    }
                    Text("Download LiteRT Model")
                }
            }
            .buttonStyle(AdaptiveLiquidGlassButtonStyle(tintColor: .blue.opacity(0.3)))
            .disabled(isLoadingMLXModel)

            if let progress = mlxDownloadProgress {
                ProgressView(progress)
            }

            if let mlxLoadError {
                Text(mlxLoadError)
                    .font(.caption)
                    .foregroundColor(.red)
            }

            Text("If the prompt exceeds LiteRT context, the app asks which provider to reroute to.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 8)
    }

    @ViewBuilder
    private var coreAIMLXSettingsView: some View {
        VStack(alignment: .leading, spacing: 10) {
            let effectiveContextTokens = AppSettings.effectiveCoreAIMLXContextTokens(appState.settings.coreAIMLXMaxContextTokens)
            let maxOutputTokens = max(64, min(512, effectiveContextTokens - max(256, effectiveContextTokens / 4)))

            TextField("CoreAI MLX Hugging Face Repo", text: Binding(
                get: { appState.settings.coreAIMLXModelID },
                set: { newValue in
                    var newSettings = appState.settings
                    newSettings.coreAIMLXModelID = CoreAIMLXLocalService.normalizedModelID(newValue)
                    appState.updateSettings(newSettings)
                }
            ))
            .textFieldStyle(AdaptiveLiquidGlassTextFieldStyle(
                cornerRadius: 12,
                tintColor: .orange.opacity(0.3)
            ))
            .onSubmit {
                Task { await appState.warmUpMLXIfNeeded() }
            }

            Text("Uses an MLX-format Gemma 4 E2B model for comparison with the LiteRT Gemma 4 E2B model.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Stepper(
                value: Binding(
                    get: { appState.settings.coreAIMLXMaxContextTokens },
                    set: { newValue in
                        var newSettings = appState.settings
                        newSettings.coreAIMLXMaxContextTokens = AppSettings.normalizedCoreAIMLXContextTokens(newValue)
                        newSettings.coreAIMLXMaxOutputTokens = AppSettings.normalizedCoreAIMLXOutputTokens(
                            newSettings.coreAIMLXMaxOutputTokens,
                            contextTokens: AppSettings.effectiveCoreAIMLXContextTokens(newSettings.coreAIMLXMaxContextTokens)
                        )
                        appState.updateSettings(newSettings)
                    }
                ),
                in: 0...CoreAIMLXLocalService.maxContextTokens,
                step: CoreAIMLXLocalService.defaultContextTokens
            ) {
                Text(
                    "Context tokens: " + (appState.settings.coreAIMLXMaxContextTokens == 0
                        ? "Auto"
                        : "\(appState.settings.coreAIMLXMaxContextTokens)")
                )
            }

            Stepper(
                value: Binding(
                    get: { appState.settings.coreAIMLXMaxOutputTokens },
                    set: { newValue in
                        var newSettings = appState.settings
                        newSettings.coreAIMLXMaxOutputTokens = AppSettings.normalizedCoreAIMLXOutputTokens(
                            newValue,
                            contextTokens: AppSettings.effectiveCoreAIMLXContextTokens(newSettings.coreAIMLXMaxContextTokens)
                        )
                        appState.updateSettings(newSettings)
                    }
                ),
                in: 64...maxOutputTokens,
                step: 64
            ) {
                Text("Max output tokens: \(appState.settings.coreAIMLXMaxOutputTokens)")
            }

            Button(action: {
                preloadCoreAIMLXModel()
            }) {
                HStack {
                    if isLoadingMLXModel {
                        ProgressView()
                            .scaleEffect(0.8)
                    } else {
                        Image(systemName: "arrow.down.circle")
                    }
                    Text("Download CoreAI MLX Model")
                }
            }
            .buttonStyle(AdaptiveLiquidGlassButtonStyle(tintColor: .blue.opacity(0.3)))
            .disabled(isLoadingMLXModel)

            if let progress = mlxDownloadProgress {
                ProgressView(progress)
            }

            if let mlxLoadError {
                Text(mlxLoadError)
                    .font(.caption)
                    .foregroundColor(.red)
            }

            Text("If the prompt exceeds CoreAI MLX context, the app asks which provider to reroute to.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 8)
    }

    private func preloadLiteRTModel() {
        mlxLoadError = nil
        let progress = Progress(totalUnitCount: 100)
        mlxDownloadProgress = progress
        isLoadingMLXModel = true

        let modelID = LiteRTLocalService.normalizedModelID(appState.settings.mlxModelID)
        if modelID != appState.settings.mlxModelID {
            var newSettings = appState.settings
            newSettings.mlxModelID = modelID
            appState.updateSettings(newSettings)
        }
        let maxContextTokens = appState.settings.mlxMaxContextTokens > 0 ? appState.settings.mlxMaxContextTokens : nil
        Task {
            defer {
                Task { @MainActor in isLoadingMLXModel = false }
            }
            do {
                try await LiteRTLocalService.shared.preloadModel(
                    modelID: modelID,
                    maxContextTokens: maxContextTokens,
                    onProgress: { fraction in
                        Task { @MainActor in
                            progress.completedUnitCount = Int64(max(0, min(1, fraction)) * 100)
                            mlxDownloadProgress = progress
                        }
                    }
                )
                await MainActor.run {
                    progress.completedUnitCount = 100
                    mlxDownloadProgress = progress
                }
                await appState.warmUpMLXIfNeeded()
            } catch {
                await MainActor.run {
                    mlxLoadError = error.localizedDescription
                }
            }
        }
    }

    private func preloadCoreAIMLXModel() {
        mlxLoadError = nil
        mlxDownloadProgress = nil
        isLoadingMLXModel = true

        let modelID = CoreAIMLXLocalService.normalizedModelID(appState.settings.coreAIMLXModelID)
        Task {
            defer {
                Task { @MainActor in isLoadingMLXModel = false }
            }
            do {
                try await CoreAIMLXLocalService.shared.preloadModel(
                    modelID: modelID,
                    onProgress: { progress in
                        Task { @MainActor in
                            mlxDownloadProgress = progress
                        }
                    }
                )
                await appState.warmUpMLXIfNeeded()
            } catch {
                await MainActor.run {
                    mlxLoadError = error.localizedDescription
                }
            }
        }
    }

    private func downloadModel(to location: URL) {
        mlxLoadError = nil
        mlxDownloadProgress = nil
        isLoadingMLXModel = true

        Task {
            defer {
                Task { @MainActor in
                    isLoadingMLXModel = false
                }
            }
            do {
                let modelID = MLXLocalService.normalizedModelIdentifier(from: appState.settings.mlxModelID)
                guard !modelID.isEmpty else {
                    throw NSError(
                        domain: "MLXDownload",
                        code: 0,
                        userInfo: [NSLocalizedDescriptionKey: "Missing Hugging Face model id."]
                    )
                }
                guard !modelID.lowercased().hasPrefix("external:") else {
                    throw NSError(
                        domain: "MLXDownload",
                        code: 0,
                        userInfo: [NSLocalizedDescriptionKey: "Enter a Hugging Face model id (e.g. FakeRockert543/gemma-4-e2b-it-MLX-4bit) before downloading."]
                    )
                }

                let didStartAccessing = location.startAccessingSecurityScopedResource()
                defer {
                    if didStartAccessing {
                        location.stopAccessingSecurityScopedResource()
                    }
                }

                try await MLXLocalService.shared.downloadModelToLocation(
                    modelID: modelID,
                    location: location,
                    progressHandler: { progress in
                        Task { @MainActor in
                            mlxDownloadProgress = progress
                        }
                    }
                )

                let modelPath = location.appending(path: "models/\(modelID)")
                do {
                    #if os(iOS)
                    let bookmarkData = try modelPath.bookmarkData(options: .minimalBookmark)
                    #else
                    let bookmarkData = try modelPath.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess])
                    #endif
                    UserDefaults.standard.set(bookmarkData, forKey: mlxModelBookmarkKey)
                    UserDefaults.standard.set(modelPath.path, forKey: mlxModelPathKey)
                } catch {
                    throw NSError(
                        domain: "MLXDownload",
                        code: 2,
                        userInfo: [NSLocalizedDescriptionKey: "Failed to save folder bookmark: \(error.localizedDescription)"]
                    )
                }

                await MainActor.run {
                    var newSettings = appState.settings
                    newSettings.mlxModelID = "external:\(modelPath.path)"
                    appState.updateSettings(newSettings)
                }
            } catch {
                await MainActor.run {
                    mlxLoadError = error.localizedDescription
                }
            }
        }
    }

    private func handleDownloadLocationPicker(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            downloadModel(to: url)
        case .failure(let error):
            mlxLoadError = error.localizedDescription
        }
    }
}

// MARK: - Local Voices Loader
extension SettingsView {
    private func loadLocalVoices() {
        #if os(iOS)
        if #available(iOS 14.0, *) {
            // Build list of working iOS voices (prefer ttsbundle; any language)
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
            if let sel = UserDefaults.standard.string(forKey: iosVoiceKey), !sel.isEmpty {
                localVoiceID = sel
            } else {
                // Auto-select best available voice: Premium > Enhanced > Default
                let currentLang = AVSpeechSynthesisVoice.currentLanguageCode()
                
                // Try to find best voice for current language
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
                    UserDefaults.standard.set(localVoiceID, forKey: iosVoiceKey) 
                }
            }
        }
        #elseif os(macOS)
        macVoices = availableMacVoices()
        if let sel = UserDefaults.standard.string(forKey: macVoiceKey), !sel.isEmpty {
            localVoiceID = sel
        } else if let preferred = preferredMacVoiceIdentifier() {
            localVoiceID = preferred
            UserDefaults.standard.set(localVoiceID, forKey: macVoiceKey)
        } else {
            localVoiceID = macVoices.first?.id ?? ""
            if !localVoiceID.isEmpty { UserDefaults.standard.set(localVoiceID, forKey: macVoiceKey) }
        }
        #endif
    }
}

// Document wrapper for file export
struct OPMLDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.xml] }
    
    var url: URL
    
    init(url: URL) {
        self.url = url
    }
    
    init(configuration: ReadConfiguration) throws {
        // This is required for FileDocument but not used for export
        fatalError("Reading OPML documents not implemented")
    }
    
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let data = try Data(contentsOf: url)
        return FileWrapper(regularFileWithContents: data)
    }
}

struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        SettingsView()
            .environmentObject(AppState())
    }
}

// MARK: - Manage MLX Models View
struct ManageMLXModelsView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var errorMessage: String? = nil
    @State private var showFolderPicker = false

    private let modelBookmarkKey = "MLXExternalModelBookmark"
    private let modelPathKey = "MLXExternalModelPath"

    var body: some View {
        NavigationView {
            List {
                Section {
                    if let modelPath = UserDefaults.standard.string(forKey: modelPathKey) {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(URL(fileURLWithPath: modelPath).lastPathComponent)
                                    .font(.body)
                                Text("Selected")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Button(role: .destructive) {
                                clearModel()
                            } label: {
                                Image(systemName: "xmark.circle")
                            }
                            .buttonStyle(.plain)
                        }
                    } else {
                        Text("No model selected")
                            .foregroundColor(.secondary)
                    }

                    Button {
                        showFolderPicker = true
                    } label: {
                        Label("Select Model from Files", systemImage: "folder.badge.plus")
                    }
                } header: {
                    Text("Selected Model")
                } footer: {
                    Text("Select a model folder from iCloud Drive, local storage, or external drives. Use \"Download Model\" in Settings to download new models to your preferred location.")
                }
            }
            .navigationTitle("Manage Models")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .fileImporter(
                isPresented: $showFolderPicker,
                allowedContentTypes: [.folder],
                allowsMultipleSelection: false
            ) { result in
                handleFolderSelection(result)
            }
            .alert("Error", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "Unknown error.")
            }
        }
    }

    private func handleFolderSelection(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }

            guard url.startAccessingSecurityScopedResource() else {
                errorMessage = "Cannot access the selected folder"
                return
            }
            defer { url.stopAccessingSecurityScopedResource() }

            let configPath = url.appending(path: "config.json")
            guard FileManager.default.fileExists(atPath: configPath.path) else {
                errorMessage = "Invalid model folder: missing config.json. Please select the folder containing the model files."
                return
            }

            do {
                #if os(iOS)
                let bookmarkData = try url.bookmarkData(options: .minimalBookmark)
                #else
                let bookmarkData = try url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess])
                #endif
                UserDefaults.standard.set(bookmarkData, forKey: modelBookmarkKey)
                UserDefaults.standard.set(url.path, forKey: modelPathKey)

                var newSettings = appState.settings
                newSettings.mlxModelID = "external:\(url.path)"
                appState.updateSettings(newSettings)
            } catch {
                errorMessage = "Failed to save folder bookmark: \(error.localizedDescription)"
            }

        case .failure(let error):
            errorMessage = error.localizedDescription
        }
    }

    private func clearModel() {
        UserDefaults.standard.removeObject(forKey: modelBookmarkKey)
        UserDefaults.standard.removeObject(forKey: modelPathKey)

        var newSettings = appState.settings
        newSettings.mlxModelID = ""
        appState.updateSettings(newSettings)
    }
}
