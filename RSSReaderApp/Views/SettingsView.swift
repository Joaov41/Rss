import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.presentationMode) var presentationMode
    
    @State private var showingFileImporter = false
    @State private var importResult: String?
    @State private var showingImportResult = false
    @State private var isImporting = false
    
    // TTS Settings
    @State private var selectedTTSProvider: TTSProvider = .gemini
    @State private var selectedGeminiVoice: String = "Puck"
    @State private var selectedOpenAIVoice: String = "alloy"
    @State private var preloadingEnabled: Bool = true
    @State private var fallbackEnabled: Bool = true
    @State private var cacheSize: Int = 0
    @State private var openaiApiKey: String = ""
    
    // Health Check States
    @State private var isCheckingHealth: Bool = false
    @State private var lastHealthCheck: (gemini: (isWorking: Bool, responseTime: TimeInterval?, error: String?), openai: (isWorking: Bool, responseTime: TimeInterval?, error: String?))? = nil
    
    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("GEMINI API KEY")) {
                    TextField("Enter your Gemini API Key", text: $appState.settings.geminiApiKey)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .onChange(of: appState.settings.geminiApiKey) { newValue in
                            appState.summaryService.updateApiKey(newValue)
                        }
                }
                
                Section(header: Text("OPENAI API KEY")) {
                    TextField("Enter your OpenAI API Key", text: $openaiApiKey)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .onChange(of: openaiApiKey) { newValue in
                            appState.summaryService.updateOpenAIApiKey(newValue)
                        }
                }
                
                Section(header: Text("TEXT-TO-SPEECH SETTINGS")) {
                    // Provider Selection
                    Picker("TTS Provider", selection: $selectedTTSProvider) {
                        ForEach(TTSProvider.allCases, id: \.self) { provider in
                            Text(provider.displayName).tag(provider)
                        }
                    }
                    .onChange(of: selectedTTSProvider) { newProvider in
                        appState.summaryService.setTTSProvider(newProvider)
                    }
                    
                    // Voice selection based on current provider
                    Group {
                        if selectedTTSProvider == .gemini {
                            Picker("Gemini Voice", selection: $selectedGeminiVoice) {
                                ForEach(["Puck", "Charon", "Kore", "Fenrir", "Aoede", "Leda", "Orus", "Zephyr"], id: \.self) { voice in
                                    Text(voice).tag(voice)
                                }
                            }
                            .onChange(of: selectedGeminiVoice) { newVoice in
                                appState.summaryService.setGeminiVoice(newVoice)
                            }
                        } else {
                            Picker("OpenAI Voice", selection: $selectedOpenAIVoice) {
                                ForEach(["alloy", "echo", "fable", "onyx", "nova", "shimmer"], id: \.self) { voice in
                                    Text(voice.capitalized).tag(voice)
                                }
                            }
                            .onChange(of: selectedOpenAIVoice) { newVoice in
                                appState.summaryService.setOpenAIVoice(newVoice)
                            }
                        }
                    }
                    
                    // Fallback option
                    Toggle("Enable Provider Fallback", isOn: $fallbackEnabled)
                        .onChange(of: fallbackEnabled) { enabled in
                            appState.summaryService.setFallbackEnabled(enabled)
                        }
                    
                    // Preloading option
                    Toggle("Preload Common Phrases", isOn: $preloadingEnabled)
                        .onChange(of: preloadingEnabled) { enabled in
                            appState.summaryService.enablePreloading(enabled)
                        }
                    
                    // Cache status and management
                    HStack {
                        Text("Cache Size")
                        Spacer()
                        Text("\(cacheSize) items")
                            .foregroundColor(.secondary)
                    }
                    
                    Button("Clear TTS Cache") {
                        appState.summaryService.clearTTSCache()
                        updateCacheSize()
                    }
                    .foregroundColor(.red)
                }
                
                Section(header: Text("TTS HEALTH CHECK")) {
                    Button(action: {
                        checkTTSHealth()
                    }) {
                        HStack {
                            if isCheckingHealth {
                                ProgressView()
                                    .scaleEffect(0.8)
                                Text("Checking...")
                            } else {
                                Text("Test TTS Providers")
                            }
                        }
                    }
                    .disabled(isCheckingHealth)
                    
                    if let healthResult = lastHealthCheck {
                        VStack(alignment: .leading, spacing: 4) {
                            // Gemini Status
                            HStack {
                                Text("Gemini:")
                                    .font(.caption)
                                    .bold()
                                if healthResult.gemini.isWorking {
                                    Text("✅ \(String(format: "%.2f", healthResult.gemini.responseTime ?? 0))s")
                                        .font(.caption)
                                        .foregroundColor(.green)
                                } else {
                                    Text("❌ \(healthResult.gemini.error ?? "Failed")")
                                        .font(.caption)
                                        .foregroundColor(.red)
                                        .lineLimit(1)
                                }
                            }
                            
                            // OpenAI Status
                            HStack {
                                Text("OpenAI:")
                                    .font(.caption)
                                    .bold()
                                if healthResult.openai.isWorking {
                                    Text("✅ \(String(format: "%.2f", healthResult.openai.responseTime ?? 0))s")
                                        .font(.caption)
                                        .foregroundColor(.green)
                                } else {
                                    Text("❌ \(healthResult.openai.error ?? "Failed")")
                                        .font(.caption)
                                        .foregroundColor(.red)
                                        .lineLimit(1)
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
                
                Section(header: Text("RSS IMPORT/EXPORT")) {
                    Button("Import OPML") {
                        showingFileImporter = true
                    }
                    .disabled(isImporting)
                    
                    if let result = importResult {
                        Text(result)
                            .font(.caption)
                            .foregroundColor(result.contains("Successfully") ? .green : .red)
                    }
                    
                    Button("Export Current Feeds") {
                        exportFeeds()
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarItems(
                trailing: Button("Done") {
                    presentationMode.wrappedValue.dismiss()
                }
            )
            .fileImporter(
                isPresented: $showingFileImporter,
                allowedContentTypes: [.xml],
                allowsMultipleSelection: false
            ) { result in
                handleFileImport(result)
            }
            .alert("Import Result", isPresented: $showingImportResult) {
                Button("OK", role: .cancel) {
                    importResult = nil
                }
            } message: {
                Text(importResult ?? "")
            }
            .onAppear {
                loadCurrentSettings()
                updateCacheSize()
            }
        }
    }
    
    private func loadCurrentSettings() {
        selectedTTSProvider = appState.summaryService.getTTSProvider()
        selectedGeminiVoice = appState.summaryService.getCurrentVoice()
        selectedOpenAIVoice = appState.summaryService.getCurrentVoice()
        openaiApiKey = appState.summaryService.getOpenAIApiKey()
        // Load other settings from UserDefaults if needed
        preloadingEnabled = true
        fallbackEnabled = true
    }
    
    private func updateCacheSize() {
        cacheSize = appState.summaryService.getTTSCacheSize()
    }
    
    private func checkTTSHealth() {
        isCheckingHealth = true
        
        Task {
            let result = await appState.summaryService.checkBothProvidersHealth()
            
            await MainActor.run {
                lastHealthCheck = result
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
                    showingImportResult = true
                }
            }
        case .failure(let error):
            importResult = "Error selecting file: \(error.localizedDescription)"
            showingImportResult = true
        }
    }
    
    private func exportFeeds() {
        // This could be implemented to export current feeds to OPML
        // For now, just show a placeholder message
        importResult = "Export functionality coming soon"
        showingImportResult = true
    }
}

struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        SettingsView()
            .environmentObject(AppState())
    }
}
