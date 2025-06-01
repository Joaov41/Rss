import Foundation
import Combine
#if os(iOS)
import UIKit
import AVFoundation
#elseif os(macOS)
import AppKit
#endif

// TTS Provider enum
enum TTSProvider: String, CaseIterable {
    case gemini = "Gemini"
    case openai = "OpenAI"
    
    var displayName: String {
        return self.rawValue
    }
}

class SummaryService {
    private var apiKey: String
    private var openaiApiKey: String = ""
    private let baseURL = "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash-preview-05-20:generateContent"
    private let ttsBaseURL = "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash-preview-tts:generateContent"
    private let openaiTTSURL = "https://api.openai.com/v1/audio/speech"
    
    // TTS Cache
    private var ttsCache: [String: Data] = [:]
    private let maxCacheSize = 20 // Cache up to 20 TTS responses
    private let cacheQueue = DispatchQueue(label: "com.rssreader.ttscache", attributes: .concurrent)
    
    // TTS chunk size for long texts
    private let ttsChunkSize = 400 // Reduced from 500 to 400 characters for better reliability
    
    // Voice configuration
    private var selectedTTSProvider: TTSProvider = .gemini
    private var selectedGeminiVoice: String = "Puck" // Default to fastest voice
    private var selectedOpenAIVoice: String = "alloy" // Default OpenAI voice
    
    private let geminiVoices = ["Puck", "Charon", "Kore", "Fenrir", "Aoede", "Leda", "Orus", "Zephyr"]
    private let openaiVoices = ["alloy", "echo", "fable", "onyx", "nova", "shimmer"]
    
    // Preloading
    private var isPreloadingEnabled = true
    private var enableFallback = true // Enable automatic fallback between providers
    private let commonPhrases = [
        "Loading summary...",
        "Generating response...",
        "Please wait...",
        "Processing your request...",
        "Summary complete.",
        "Error occurred.",
        "No content available."
    ]
    
    init(apiKey: String? = nil) {
        self.apiKey = apiKey ?? ""
        
        // Load settings from AppSettings via PersistenceManager
        let persistenceManager = PersistenceManager()
        let settings = persistenceManager.loadSettings()
        
        // If provided API key is empty, use the one from settings
        if self.apiKey.isEmpty {
            self.apiKey = settings.geminiApiKey
        }
        
        // Load OpenAI API key from settings (preferred) or environment
        if !settings.openaiApiKey.isEmpty {
            self.openaiApiKey = settings.openaiApiKey
        } else if let openaiKey = ProcessInfo.processInfo.environment["OPENAI_API_KEY"] {
            self.openaiApiKey = openaiKey
        }
        
        // Load TTS provider preferences
        if let provider = TTSProvider(rawValue: settings.selectedTTSProvider) {
            self.selectedTTSProvider = provider
        }
        
        // Load voice preferences
        if !settings.selectedGeminiVoice.isEmpty && geminiVoices.contains(settings.selectedGeminiVoice) {
            self.selectedGeminiVoice = settings.selectedGeminiVoice
        }
        
        if !settings.selectedOpenAIVoice.isEmpty && openaiVoices.contains(settings.selectedOpenAIVoice) {
            self.selectedOpenAIVoice = settings.selectedOpenAIVoice
        }
        
        // Start preloading common phrases in background
        if isPreloadingEnabled && (!self.apiKey.isEmpty || !self.openaiApiKey.isEmpty) {
            Task {
                await preloadCommonPhrases()
            }
        }
    }
    
    func updateApiKey(_ newApiKey: String) {
        self.apiKey = newApiKey
        
        // Save Gemini API key to AppSettings via PersistenceManager
        let persistenceManager = PersistenceManager()
        var settings = persistenceManager.loadSettings()
        settings.geminiApiKey = newApiKey
        persistenceManager.saveSettings(settings)
        
        // Start preloading when API key becomes available
        if isPreloadingEnabled && (!newApiKey.isEmpty || !openaiApiKey.isEmpty) {
            Task {
                await preloadCommonPhrases()
            }
        }
    }
    
    func updateOpenAIApiKey(_ newApiKey: String) {
        self.openaiApiKey = newApiKey
        print("🔊 SummaryService: OpenAI API key updated")
        
        // Save OpenAI API key to AppSettings via PersistenceManager
        let persistenceManager = PersistenceManager()
        var settings = persistenceManager.loadSettings()
        settings.openaiApiKey = newApiKey
        persistenceManager.saveSettings(settings)
        
        // Start preloading when API key becomes available
        if isPreloadingEnabled && (!apiKey.isEmpty || !newApiKey.isEmpty) {
            Task {
                await preloadCommonPhrases()
            }
        }
    }
    
    // MARK: - Provider and Voice Configuration
    
    func setTTSProvider(_ provider: TTSProvider) {
        selectedTTSProvider = provider
        print("🔊 SummaryService: TTS provider changed to \(provider.displayName)")
        
        // Save TTS provider preference to settings
        let persistenceManager = PersistenceManager()
        var settings = persistenceManager.loadSettings()
        settings.selectedTTSProvider = provider.rawValue
        persistenceManager.saveSettings(settings)
    }
    
    func getTTSProvider() -> TTSProvider {
        return selectedTTSProvider
    }
    
    func getAvailableTTSProviders() -> [TTSProvider] {
        return TTSProvider.allCases
    }
    
    func setGeminiVoice(_ voiceName: String) {
        if geminiVoices.contains(voiceName) {
            selectedGeminiVoice = voiceName
            print("🔊 SummaryService: Gemini voice changed to \(voiceName)")
            
            // Save Gemini voice preference to settings
            let persistenceManager = PersistenceManager()
            var settings = persistenceManager.loadSettings()
            settings.selectedGeminiVoice = voiceName
            persistenceManager.saveSettings(settings)
        } else {
            print("🔊 SummaryService: Invalid Gemini voice name \(voiceName). Available voices: \(geminiVoices)")
        }
    }
    
    func setOpenAIVoice(_ voiceName: String) {
        if openaiVoices.contains(voiceName) {
            selectedOpenAIVoice = voiceName
            print("🔊 SummaryService: OpenAI voice changed to \(voiceName)")
            
            // Save OpenAI voice preference to settings
            let persistenceManager = PersistenceManager()
            var settings = persistenceManager.loadSettings()
            settings.selectedOpenAIVoice = voiceName
            persistenceManager.saveSettings(settings)
        } else {
            print("🔊 SummaryService: Invalid OpenAI voice name \(voiceName). Available voices: \(openaiVoices)")
        }
    }
    
    func getAvailableVoicesForCurrentProvider() -> [String] {
        switch selectedTTSProvider {
        case .gemini:
            return geminiVoices
        case .openai:
            return openaiVoices
        }
    }
    
    func getCurrentVoice() -> String {
        switch selectedTTSProvider {
        case .gemini:
            return selectedGeminiVoice
        case .openai:
            return selectedOpenAIVoice
        }
    }
    
    // Legacy method for backwards compatibility
    func setVoice(_ voiceName: String) {
        switch selectedTTSProvider {
        case .gemini:
            setGeminiVoice(voiceName)
        case .openai:
            setOpenAIVoice(voiceName)
        }
    }
    
    func getAvailableVoices() -> [String] {
        return getAvailableVoicesForCurrentProvider()
    }
    
    func setFallbackEnabled(_ enabled: Bool) {
        enableFallback = enabled
        print("🔊 SummaryService: Fallback \(enabled ? "enabled" : "disabled")")
    }
    
    // MARK: - Preloading
    
    private func preloadCommonPhrases() async {
        print("🔊 SummaryService: Starting preload of common phrases")
        
        for phrase in commonPhrases {
            do {
                let cacheKey = generateCacheKey(for: phrase)
                
                // Skip if already cached
                if getCachedTTS(for: cacheKey) != nil {
                    continue
                }
                
                // Preload with a small delay to avoid rate limiting
                try await Task.sleep(nanoseconds: 500_000_000) // 0.5 second delay
                
                let _ = try await synthesizeSpeechSingle(text: phrase, cacheKey: cacheKey)
                print("🔊 SummaryService: Preloaded phrase: '\(phrase)'")
                
            } catch {
                print("🔊 SummaryService: Failed to preload phrase '\(phrase)': \(error)")
            }
        }
        
        print("🔊 SummaryService: Preloading complete")
    }
    
    func enablePreloading(_ enabled: Bool) {
        isPreloadingEnabled = enabled
        
        if enabled && (!apiKey.isEmpty || !openaiApiKey.isEmpty) {
            Task {
                await preloadCommonPhrases()
            }
        }
    }
    
    // MARK: - Fast TTS for Short Phrases
    
    func synthesizeSpeechFast(text: String) async throws -> Data {
        // For very short text, use optimized settings
        if text.count <= 100 {
            switch selectedTTSProvider {
            case .gemini:
                return try await synthesizeGeminiSingle(text: text, cacheKey: generateCacheKey(for: text, provider: .gemini), useFastSettings: true)
            case .openai:
                return try await synthesizeOpenAISingle(text: text, cacheKey: generateCacheKey(for: text, provider: .openai))
            }
        } else {
            return try await synthesizeSpeech(text: text)
        }
    }
    
    func summarizeText(_ text: String, customPrompt: String? = nil) -> AnyPublisher<String, Never> {
        // Check if API key is available
        guard !apiKey.isEmpty else {
            return Just("API key not configured. Please add your Gemini API key in Settings.")
                .eraseToAnyPublisher()
        }
        
        // Prepare the URL with API key
        let urlString = "\(baseURL)?key=\(apiKey)"
        guard let url = URL(string: urlString) else {
            return Just("Invalid API URL")
                .eraseToAnyPublisher()
        }
        
        // Handle large text inputs
        var inputText = text
        let maxTextLength = 150000  // Adjust this based on API limits
        
        if inputText.count > maxTextLength {
            print("⚠️ SummaryService: Text exceeds maximum length (\(inputText.count) chars). Truncating to \(maxTextLength) chars.")
            inputText = String(inputText.prefix(maxTextLength))
        }
        
        // Prepare the request body
        let prompt: String
        if let customPrompt = customPrompt {
            // Use the custom prompt if provided
            prompt = customPrompt
        } else {
            // Default prompt for article summarization
            prompt = "Summarize the following text in a concise way, highlighting the key points: \(inputText)"
        }

        // Disable thinking
        let thinkingConfig = ThinkingConfig(thinkingBudget: 0)
        let generationConfig = GenerationConfig(thinkingConfig: thinkingConfig)
        let requestBody = GeminiRequest(contents: [GeminiContent(parts: [GeminiPart(text: prompt)])], generationConfig: generationConfig)

        // Log the model and thinking status
        let modelName = baseURL.split(separator: "/").last?.split(separator: ":").first ?? "unknown model"
        print("🧠 SummaryService: Calling Gemini model '\(modelName)' with thinking disabled (budget: 0).")
        print("📱 SummaryService: Processing \(inputText.count) characters for summarization")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        
        do {
            let jsonData = try JSONEncoder().encode(requestBody)
            request.httpBody = jsonData
        } catch {
            return Just("Error encoding request: \(error.localizedDescription)")
                .eraseToAnyPublisher()
        }
        
        return URLSession.shared.dataTaskPublisher(for: request)
            .handleEvents(receiveOutput: { data, response in
                if let httpResponse = response as? HTTPURLResponse {
                    print("🧠 SummaryService: Received HTTP status code: \(httpResponse.statusCode)")
                }
                if let jsonString = String(data: data, encoding: .utf8) {
                    print("🧠 SummaryService: Raw Gemini API Response:\n---\n\(jsonString)\n---")
                } else {
                    print("🧠 SummaryService: Could not convert response data to UTF-8 string.")
                }
            })
            .map { $0.data }
            .decode(type: GeminiResponse.self, decoder: JSONDecoder())
            .map { response -> String in
                if let text = response.candidates?.first?.content.parts.first?.text {
                    print("✅ SummaryService: Successfully decoded Gemini response.")
                    return text
                } else if let errorMessage = response.error?.message {
                    return "Error: \(errorMessage)"
                } else {
                    return "No summary available"
                }
            }
            .replaceError(with: "Error generating summary")
            .eraseToAnyPublisher()
    }
    
    // MARK: - Text-to-Speech
    
    func synthesizeSpeech(text: String) async throws -> Data {
        // Check if any API key is available
        guard !apiKey.isEmpty || !openaiApiKey.isEmpty else {
            print("🔊 SummaryService (TTS) - Error: No API keys configured.")
            throw NSError(domain: "SummaryService.synthesizeSpeech", code: 0, 
                          userInfo: [NSLocalizedDescriptionKey: "No TTS API keys configured. Please add your Gemini or OpenAI API key in Settings."])
        }

        // Generate cache key (using first 100 chars + hash of full text + provider)
        let cacheKey = generateCacheKey(for: text)
        
        // Check cache first
        if let cachedData = getCachedTTS(for: cacheKey) {
            print("🔊 SummaryService (TTS) - Info: Using cached TTS data for key: \(cacheKey)")
            return cachedData
        }

        // Try primary provider first
        do {
            let audioData = try await synthesizeWithProvider(text: text, provider: selectedTTSProvider, cacheKey: cacheKey)
            return audioData
        } catch {
            print("🔊 SummaryService (TTS) - Warning: Primary provider (\(selectedTTSProvider.displayName)) failed: \(error.localizedDescription)")
            
            // Try fallback provider if enabled
            if enableFallback {
                let fallbackProvider: TTSProvider = selectedTTSProvider == .gemini ? .openai : .gemini
                let fallbackApiKey = fallbackProvider == .gemini ? apiKey : openaiApiKey
                
                if !fallbackApiKey.isEmpty {
                    print("🔊 SummaryService (TTS) - Info: Attempting fallback to \(fallbackProvider.displayName)")
                    do {
                        let fallbackCacheKey = generateCacheKey(for: text, provider: fallbackProvider)
                        let audioData = try await synthesizeWithProvider(text: text, provider: fallbackProvider, cacheKey: fallbackCacheKey)
                        print("🔊 SummaryService (TTS) - Info: ✅ Fallback successful")
                        return audioData
                    } catch {
                        print("🔊 SummaryService (TTS) - Error: Fallback provider also failed: \(error.localizedDescription)")
                    }
                }
            }
            
            // If we get here, both providers failed or fallback is disabled
            throw error
        }
    }
    
    private func synthesizeWithProvider(text: String, provider: TTSProvider, cacheKey: String) async throws -> Data {
        switch provider {
        case .gemini:
            return try await synthesizeWithGemini(text: text, cacheKey: cacheKey)
        case .openai:
            return try await synthesizeWithOpenAI(text: text, cacheKey: cacheKey)
        }
    }
    
    private func synthesizeWithGemini(text: String, cacheKey: String) async throws -> Data {
        guard !apiKey.isEmpty else {
            throw NSError(domain: "SummaryService.synthesizeSpeech", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Gemini API key not configured."])
        }
        
        // For long texts, try chunked processing for faster initial response
        if text.count > ttsChunkSize {
            print("🔊 SummaryService (TTS) - Info: Text is long (\(text.count) chars), using Gemini chunked processing")
            return try await synthesizeSpeechChunkedGemini(text: text, cacheKey: cacheKey)
        }

        return try await synthesizeGeminiSingle(text: text, cacheKey: cacheKey)
    }
    
    private func synthesizeWithOpenAI(text: String, cacheKey: String) async throws -> Data {
        guard !openaiApiKey.isEmpty else {
            throw NSError(domain: "SummaryService.synthesizeSpeech", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "OpenAI API key not configured."])
        }
        
        // For long texts, try chunked processing
        if text.count > ttsChunkSize {
            print("🔊 SummaryService (TTS) - Info: Text is long (\(text.count) chars), using OpenAI chunked processing")
            return try await synthesizeSpeechChunkedOpenAI(text: text, cacheKey: cacheKey)
        }

        return try await synthesizeOpenAISingle(text: text, cacheKey: cacheKey)
    }
    
    // MARK: - OpenAI TTS Implementation
    
    private func synthesizeOpenAISingle(text: String, cacheKey: String, retryCount: Int = 0) async throws -> Data {
        guard let url = URL(string: openaiTTSURL) else {
            print("🔊 SummaryService (OpenAI TTS) - Error: Invalid API URL.")
            throw NSError(domain: "SummaryService.synthesizeSpeech", code: 1, 
                          userInfo: [NSLocalizedDescriptionKey: "Invalid OpenAI API URL."])
        }

        let startTime = Date()
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(openaiApiKey)", forHTTPHeaderField: "Authorization")
        
        // OpenAI TTS is generally faster, so use shorter timeouts
        let baseTimeout: TimeInterval = 20
        let timeoutMultiplier = 1.0 + (0.3 * Double(retryCount))
        let adaptiveTimeout = baseTimeout * timeoutMultiplier + Double(text.count) / 200.0
        request.timeoutInterval = min(adaptiveTimeout, 45) // Cap at 45 seconds
        
        let requestBody: [String: Any] = [
            "model": "tts-1", // Using tts-1 for speed, could also use tts-1-hd for quality
            "input": text,
            "voice": selectedOpenAIVoice,
            "response_format": "mp3", // OpenAI returns MP3 directly
            "speed": 1.0
        ]
        
        guard let httpBody = try? JSONSerialization.data(withJSONObject: requestBody, options: []) else {
            print("🔊 SummaryService (OpenAI TTS) - Error: Failed to serialize request body.")
            throw NSError(domain: "SummaryService.synthesizeSpeech", code: 2, 
                          userInfo: [NSLocalizedDescriptionKey: "Failed to serialize request body."])
        }
        request.httpBody = httpBody
        
        print("🔊 SummaryService (OpenAI TTS) - Info: Processing \(text.count) characters with voice '\(selectedOpenAIVoice)' - Timeout: \(String(format: "%.1f", request.timeoutInterval))s (Retry: \(retryCount))")
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            
            let responseTime = Date().timeIntervalSince(startTime)
            print("🔊 SummaryService (OpenAI TTS) - Performance: API response time: \(String(format: "%.2f", responseTime)) seconds")
            
            guard let httpResponse = response as? HTTPURLResponse else {
                print("🔊 SummaryService (OpenAI TTS) - Error: Invalid HTTP response.")
                throw NSError(domain: "SummaryService.synthesizeSpeech", code: 3, 
                              userInfo: [NSLocalizedDescriptionKey: "Invalid HTTP response."])
            }
            
            print("🔊 SummaryService (OpenAI TTS) - Debug: Response status code: \(httpResponse.statusCode)")
            
            guard (200...299).contains(httpResponse.statusCode) else {
                let responseString = String(data: data, encoding: .utf8) ?? "[Could not decode response body]"
                print("🔊 SummaryService (OpenAI TTS) - Error: API request failed with status \(httpResponse.statusCode). Response: \(responseString)")
                
                // For rate limiting (429) or server errors (5xx), retry with exponential backoff
                if (httpResponse.statusCode == 429 || httpResponse.statusCode >= 500) && retryCount < 2 {
                    print("🔊 SummaryService (OpenAI TTS) - Info: Retrying request due to status \(httpResponse.statusCode)")
                    let delay = pow(2.0, Double(retryCount))
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    return try await synthesizeOpenAISingle(text: text, cacheKey: cacheKey, retryCount: retryCount + 1)
                }
                
                throw NSError(domain: "SummaryService.synthesizeSpeech", code: httpResponse.statusCode, 
                              userInfo: [NSLocalizedDescriptionKey: "OpenAI API request failed with status \(httpResponse.statusCode). Response: \(responseString)"])
            }
            
            // OpenAI returns MP3 data directly
            print("🔊 SummaryService (OpenAI TTS) - Info: Successfully synthesized speech. Audio data size: \(data.count / 1024) KB")
            
            // Cache the result
            cacheTTS(data, for: cacheKey)
            
            return data
            
        } catch {
            let responseTime = Date().timeIntervalSince(startTime)
            print("🔊 SummaryService (OpenAI TTS) - Error: Request failed after \(String(format: "%.2f", responseTime))s: \(error.localizedDescription)")
            
            // Handle timeout and network errors with retry logic
            if let urlError = error as? URLError {
                switch urlError.code {
                case .timedOut, .networkConnectionLost, .notConnectedToInternet:
                    if retryCount < 2 {
                        print("🔊 SummaryService (OpenAI TTS) - Info: Retrying due to network error: \(urlError.localizedDescription)")
                        let delay = pow(2.0, Double(retryCount))
                        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                        return try await synthesizeOpenAISingle(text: text, cacheKey: cacheKey, retryCount: retryCount + 1)
                    } else if text.count > 250 {
                        print("🔊 SummaryService (OpenAI TTS) - Info: Retries exhausted, attempting smaller chunk processing")
                        return try await synthesizeOpenAIWithSmallerChunks(text: text, cacheKey: cacheKey)
                    }
                default:
                    break
                }
            }
            
            throw error
        }
    }
    
    private func synthesizeOpenAIWithSmallerChunks(text: String, cacheKey: String) async throws -> Data {
        print("🔊 SummaryService (OpenAI TTS) - Info: Attempting recovery with smaller chunks (250 chars max)")
        
        let smallChunkSize = 250
        var chunks: [String] = []
        var currentIndex = text.startIndex
        
        while currentIndex < text.endIndex {
            let endIndex = text.index(currentIndex, offsetBy: min(smallChunkSize, text.distance(from: currentIndex, to: text.endIndex)))
            let chunk = String(text[currentIndex..<endIndex])
            chunks.append(chunk)
            currentIndex = endIndex
        }
        
        print("🔊 SummaryService (OpenAI TTS) - Info: Split into \(chunks.count) small chunks for recovery")
        
        var audioData = Data()
        
        for (index, chunk) in chunks.enumerated() {
            do {
                let chunkData = try await synthesizeOpenAISingle(text: chunk, cacheKey: "\(cacheKey)_small_\(index)", retryCount: 0)
                audioData.append(chunkData)
                
                if index < chunks.count - 1 {
                    try await Task.sleep(nanoseconds: 300_000_000) // 0.3 second delay
                }
            } catch {
                print("🔊 SummaryService (OpenAI TTS) - Warning: Small chunk \(index) failed: \(error.localizedDescription)")
            }
        }
        
        if audioData.isEmpty {
            throw NSError(domain: "SummaryService.synthesizeSpeech", code: 6, 
                          userInfo: [NSLocalizedDescriptionKey: "All OpenAI recovery attempts failed"])
        }
        
        cacheTTS(audioData, for: cacheKey)
        return audioData
    }
    
    private func synthesizeSpeechChunkedOpenAI(text: String, cacheKey: String) async throws -> Data {
        print("🔊 SummaryService (OpenAI TTS) - Info: Starting chunked processing for \(text.count) characters")
        
        let sentences = splitIntoSentences(text)
        var chunks: [String] = []
        var currentChunk = ""
        
        for sentence in sentences {
            if currentChunk.count + sentence.count > ttsChunkSize && !currentChunk.isEmpty {
                chunks.append(currentChunk.trimmingCharacters(in: .whitespacesAndNewlines))
                currentChunk = sentence
            } else {
                if !currentChunk.isEmpty { currentChunk += " " }
                currentChunk += sentence
            }
        }
        if !currentChunk.isEmpty { chunks.append(currentChunk.trimmingCharacters(in: .whitespacesAndNewlines)) }
        
        print("🔊 SummaryService (OpenAI TTS) - Info: Split into \(chunks.count) chunks")
        
        // Concurrent processing with limited parallelism
        let maxConcurrency = 3
        var audioChunks = Array<Data?>(repeating: nil, count: chunks.count)
        
        try await withThrowingTaskGroup(of: (Int, Data).self) { group in
            var nextIndexToSubmit = 0
            // Helper to submit a task
            func submitTask(for index: Int) {
                let chunkText = chunks[index]
                group.addTask {
                    let data = try await self.synthesizeOpenAISingle(text: chunkText, cacheKey: "\(cacheKey)_chunk_\(index)")
                    return (index, data)
                }
            }
            // Kick off initial tasks
            let initialTasks = min(maxConcurrency, chunks.count)
            for i in 0..<initialTasks { submitTask(for: i) }
            nextIndexToSubmit = initialTasks
            
            // Collect results and keep submitting until all processed
            while let result = try await group.next() {
                let (idx, data) = result
                audioChunks[idx] = data
                // Progress logs
                print("🔊 SummaryService (OpenAI TTS) - Info: ✅ Chunk \(idx) completed (size: \(data.count/1024) KB)")
                // Submit next pending chunk if any
                if nextIndexToSubmit < chunks.count {
                    submitTask(for: nextIndexToSubmit)
                    nextIndexToSubmit += 1
                }
            }
        }
        // Verify all chunks produced
        let finalChunks = audioChunks.compactMap { $0 }
        guard finalChunks.count == chunks.count else {
            print("🔊 SummaryService (OpenAI TTS) - Error: Some chunks failed during concurrent processing, falling back to sequential combination")
            return try await synthesizeSpeechChunkedOpenAISequential(text: text, cacheKey: cacheKey)
        }
        let combinedAudio = combineAudioChunks(finalChunks)
        cacheTTS(combinedAudio, for: cacheKey)
        print("🔊 SummaryService (OpenAI TTS) - Info: Successfully combined \(finalChunks.count) audio chunks (concurrent)")
        return combinedAudio
    }
    
    // Fallback sequential version (existing logic extracted)
    private func synthesizeSpeechChunkedOpenAISequential(text: String, cacheKey: String) async throws -> Data {
        var audioChunks: [Data] = []
        let sentences = splitIntoSentences(text)
        var chunks: [String] = []
        var currentChunk = ""
        for sentence in sentences {
            if currentChunk.count + sentence.count > ttsChunkSize && !currentChunk.isEmpty {
                chunks.append(currentChunk.trimmingCharacters(in: .whitespacesAndNewlines))
                currentChunk = sentence
            } else {
                if !currentChunk.isEmpty { currentChunk += " " }
                currentChunk += sentence
            }
        }
        if !currentChunk.isEmpty { chunks.append(currentChunk.trimmingCharacters(in: .whitespacesAndNewlines)) }
        
        for (index, chunk) in chunks.enumerated() {
            do {
                let chunkData = try await synthesizeOpenAISingle(text: chunk, cacheKey: "\(cacheKey)_chunk_\(index)")
                audioChunks.append(chunkData)
            } catch {
                print("🔊 SummaryService (OpenAI TTS) - Warning: Sequential chunk \(index) failed: \(error.localizedDescription)")
            }
        }
        let combined = combineAudioChunks(audioChunks)
        return combined
    }
    
    // MARK: - Gemini API Models
    struct GeminiRequest: Encodable {
        let contents: [GeminiContent]
        let generationConfig: GenerationConfig?
    }

    struct GeminiContent: Codable {
        let parts: [GeminiPart]
    }

    struct GeminiPart: Codable {
        let text: String
    }

    struct GenerationConfig: Encodable {
        let thinkingConfig: ThinkingConfig
    }

    struct ThinkingConfig: Encodable {
        let thinkingBudget: Int
    }

    struct GeminiResponse: Decodable {
        let candidates: [GeminiCandidate]?
        let error: GeminiError?
    }

    struct GeminiCandidate: Decodable {
        let content: GeminiContent
    }

    struct GeminiError: Decodable {
        let code: Int
        let message: String
    }

    // MARK: - TTS Cache Management
    
    private func generateCacheKey(for text: String) -> String {
        return generateCacheKey(for: text, provider: selectedTTSProvider)
    }
    
    private func generateCacheKey(for text: String, provider: TTSProvider) -> String {
        let prefix = String(text.prefix(100))
        let hash = text.hashValue
        return "\(prefix)_\(hash)_\(provider.rawValue)"
    }
    
    private func getCachedTTS(for key: String) -> Data? {
        cacheQueue.sync {
            return ttsCache[key]
        }
    }
    
    private func cacheTTS(_ data: Data, for key: String) {
        cacheQueue.async(flags: .barrier) {
            self.ttsCache[key] = data
            
            // If cache exceeds max size, remove oldest entries
            if self.ttsCache.count > self.maxCacheSize {
                // Simple FIFO removal (in production, use LRU)
                let keysToRemove = Array(self.ttsCache.keys.prefix(self.ttsCache.count - self.maxCacheSize))
                for keyToRemove in keysToRemove {
                    self.ttsCache.removeValue(forKey: keyToRemove)
                    print("🔊 SummaryService (TTS) - Cache: Removed cached entry for key: \(keyToRemove)")
                }
            }
            
            print("🔊 SummaryService (TTS) - Cache: Added entry for key: \(key). Cache size: \(self.ttsCache.count)")
        }
    }
    
    func clearTTSCache() {
        cacheQueue.async(flags: .barrier) {
            self.ttsCache.removeAll()
            print("🔊 SummaryService (TTS) - Cache: Cleared all cached TTS data")
        }
    }
    
    func getTTSCacheSize() -> Int {
        cacheQueue.sync {
            return ttsCache.count
        }
    }
    
    // MARK: - Network Status and Diagnostics
    
    func checkTTSHealth() async -> (isWorking: Bool, responseTime: TimeInterval?, error: String?) {
        let testText = "Hello, this is a test."
        let startTime = Date()
        
        do {
            let _ = try await synthesizeSpeechSingle(text: testText, cacheKey: "health_check_\(Date().timeIntervalSince1970)", useFastSettings: true)
            let responseTime = Date().timeIntervalSince(startTime)
            print("🔊 SummaryService (TTS) - Health Check: ✅ Healthy (Response time: \(String(format: "%.2f", responseTime))s)")
            return (true, responseTime, nil)
        } catch {
            let responseTime = Date().timeIntervalSince(startTime)
            print("🔊 SummaryService (TTS) - Health Check: ❌ Failed (Response time: \(String(format: "%.2f", responseTime))s, Error: \(error.localizedDescription))")
            return (false, responseTime, error.localizedDescription)
        }
    }
    
    func checkBothProvidersHealth() async -> (gemini: (isWorking: Bool, responseTime: TimeInterval?, error: String?), openai: (isWorking: Bool, responseTime: TimeInterval?, error: String?)) {
        let testText = "Health check test."
        
        // Test Gemini
        var geminiResult: (isWorking: Bool, responseTime: TimeInterval?, error: String?) = (false, nil, "API key not configured")
        if !apiKey.isEmpty {
            let startTime = Date()
            do {
                let _ = try await synthesizeGeminiSingle(text: testText, cacheKey: "health_gemini_\(Date().timeIntervalSince1970)", useFastSettings: true)
                let responseTime = Date().timeIntervalSince(startTime)
                geminiResult = (true, responseTime, nil)
                print("🔊 SummaryService (Gemini) - Health Check: ✅ Healthy (Response time: \(String(format: "%.2f", responseTime))s)")
            } catch {
                let responseTime = Date().timeIntervalSince(startTime)
                geminiResult = (false, responseTime, error.localizedDescription)
                print("🔊 SummaryService (Gemini) - Health Check: ❌ Failed (Response time: \(String(format: "%.2f", responseTime))s, Error: \(error.localizedDescription))")
            }
        }
        
        // Test OpenAI
        var openaiResult: (isWorking: Bool, responseTime: TimeInterval?, error: String?) = (false, nil, "API key not configured")
        if !openaiApiKey.isEmpty {
            let startTime = Date()
            do {
                let _ = try await synthesizeOpenAISingle(text: testText, cacheKey: "health_openai_\(Date().timeIntervalSince1970)")
                let responseTime = Date().timeIntervalSince(startTime)
                openaiResult = (true, responseTime, nil)
                print("🔊 SummaryService (OpenAI) - Health Check: ✅ Healthy (Response time: \(String(format: "%.2f", responseTime))s)")
            } catch {
                let responseTime = Date().timeIntervalSince(startTime)
                openaiResult = (false, responseTime, error.localizedDescription)
                print("🔊 SummaryService (OpenAI) - Health Check: ❌ Failed (Response time: \(String(format: "%.2f", responseTime))s, Error: \(error.localizedDescription))")
            }
        }
        
        return (gemini: geminiResult, openai: openaiResult)
    }
    
    func getDiagnosticInfo() -> String {
        let geminiStatus = apiKey.isEmpty ? "Not Set" : "Set (length: \(apiKey.count))"
        let openaiStatus = openaiApiKey.isEmpty ? "Not Set" : "Set (length: \(openaiApiKey.count))"
        
        return """
        TTS Diagnostic Information:
        - Current Provider: \(selectedTTSProvider.displayName)
        - Fallback Enabled: \(enableFallback ? "Yes" : "No")
        
        Gemini Configuration:
        - Voice: \(selectedGeminiVoice)
        - Available Voices: \(geminiVoices.joined(separator: ", "))
        - API Key: \(geminiStatus)
        
        OpenAI Configuration:
        - Voice: \(selectedOpenAIVoice)
        - Available Voices: \(openaiVoices.joined(separator: ", "))
        - API Key: \(openaiStatus)
        
        General Settings:
        - Cache Size: \(getTTSCacheSize()) items
        - Chunk Size: \(ttsChunkSize) characters
        - Preloading: \(isPreloadingEnabled ? "Enabled" : "Disabled")
        """
    }
    
    // MARK: - Gemini TTS Implementation (renamed from previous functions)
    
    private func synthesizeGeminiSingle(text: String, cacheKey: String, useFastSettings: Bool = false, retryCount: Int = 0) async throws -> Data {
        guard let url = URL(string: "\(ttsBaseURL)?key=\(apiKey)") else {
            print("🔊 SummaryService (Gemini TTS) - Error: Invalid API URL.")
            throw NSError(domain: "SummaryService.synthesizeSpeech", code: 1, 
                          userInfo: [NSLocalizedDescriptionKey: "Invalid Gemini API URL."])
        }

        let startTime = Date()
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        // Adaptive timeout based on text length and retry count
        let baseTimeout: TimeInterval = useFastSettings ? 20 : 30
        let timeoutMultiplier = 1.0 + (0.5 * Double(retryCount))
        let adaptiveTimeout = baseTimeout * timeoutMultiplier + Double(text.count) / 100.0
        request.timeoutInterval = min(adaptiveTimeout, 60) // Cap at 60 seconds

        // Use selected voice or fastest voice for short phrases
        let voiceToUse = useFastSettings ? "Puck" : selectedGeminiVoice
        
        // Optimized request body with selected voice
        let requestBody: [String: Any] = [
            "contents": [
                [
                    "parts": [
                        ["text": text]
                    ]
                ]
            ],
            "generationConfig": [
                "responseModalities": ["AUDIO"],
                "speechConfig": [
                    "voiceConfig": [
                        "prebuiltVoiceConfig": [
                            "voiceName": voiceToUse
                        ]
                    ]
                ]
            ]
        ]
        
        guard let httpBody = try? JSONSerialization.data(withJSONObject: requestBody, options: []) else {
            print("🔊 SummaryService (Gemini TTS) - Error: Failed to serialize request body.")
            throw NSError(domain: "SummaryService.synthesizeSpeech", code: 2, 
                          userInfo: [NSLocalizedDescriptionKey: "Failed to serialize request body."])
        }
        request.httpBody = httpBody
        
        print("🔊 SummaryService (Gemini TTS) - Info: Processing \(text.count) characters with voice '\(voiceToUse)'\(useFastSettings ? " (fast mode)" : "") - Timeout: \(String(format: "%.1f", request.timeoutInterval))s (Retry: \(retryCount))")
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            
            let responseTime = Date().timeIntervalSince(startTime)
            print("🔊 SummaryService (Gemini TTS) - Performance: API response time: \(String(format: "%.2f", responseTime)) seconds")
            
            guard let httpResponse = response as? HTTPURLResponse else {
                print("🔊 SummaryService (Gemini TTS) - Error: Invalid HTTP response.")
                throw NSError(domain: "SummaryService.synthesizeSpeech", code: 3, 
                              userInfo: [NSLocalizedDescriptionKey: "Invalid HTTP response."])
            }
            
            print("🔊 SummaryService (Gemini TTS) - Debug: Response status code: \(httpResponse.statusCode)")
            
            guard (200...299).contains(httpResponse.statusCode) else {
                let responseString = String(data: data, encoding: .utf8) ?? "[Could not decode response body]"
                print("🔊 SummaryService (Gemini TTS) - Error: API request failed with status \(httpResponse.statusCode). Response: \(responseString)")
                
                // For rate limiting (429) or server errors (5xx), retry with exponential backoff
                if (httpResponse.statusCode == 429 || httpResponse.statusCode >= 500) && retryCount < 2 {
                    print("🔊 SummaryService (Gemini TTS) - Info: Retrying request due to status \(httpResponse.statusCode)")
                    let delay = pow(2.0, Double(retryCount))
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    return try await synthesizeGeminiSingle(text: text, cacheKey: cacheKey, useFastSettings: useFastSettings, retryCount: retryCount + 1)
                }
                
                throw NSError(domain: "SummaryService.synthesizeSpeech", code: httpResponse.statusCode, 
                              userInfo: [NSLocalizedDescriptionKey: "Gemini API request failed with status \(httpResponse.statusCode). Response: \(responseString)"])
            }
            
            guard let json = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else {
                print("🔊 SummaryService (Gemini TTS) - Error: Failed to parse JSON response.")
                throw NSError(domain: "SummaryService.synthesizeSpeech", code: 4, 
                              userInfo: [NSLocalizedDescriptionKey: "Failed to parse JSON response."])
            }
            
            // Extract the base64 audio data from the response
            guard let candidates = json["candidates"] as? [[String: Any]],
                  let firstCandidate = candidates.first,
                  let content = firstCandidate["content"] as? [String: Any],
                  let parts = content["parts"] as? [[String: Any]],
                  let firstPart = parts.first,
                  let inlineData = firstPart["inlineData"] as? [String: Any],
                  let audioBase64 = inlineData["data"] as? String,
                  let audioData = Data(base64Encoded: audioBase64) else {
                print("🔊 SummaryService (Gemini TTS) - Error: Could not extract audio data from response structure.")
                throw NSError(domain: "SummaryService.synthesizeSpeech", code: 5, 
                              userInfo: [NSLocalizedDescriptionKey: "Could not extract audio data from response structure."])
            }
            
            print("🔊 SummaryService (Gemini TTS) - Info: Successfully synthesized speech. Audio data size: \(audioData.count / 1024) KB")
            
            // Cache the result
            cacheTTS(audioData, for: cacheKey)
            
            return audioData
            
        } catch {
            let responseTime = Date().timeIntervalSince(startTime)
            print("🔊 SummaryService (Gemini TTS) - Error: Request failed after \(String(format: "%.2f", responseTime))s: \(error.localizedDescription)")
            
            // Handle timeout and network errors with retry logic
            if let urlError = error as? URLError {
                switch urlError.code {
                case .timedOut, .networkConnectionLost, .notConnectedToInternet:
                    if retryCount < 2 {
                        print("🔊 SummaryService (Gemini TTS) - Info: Retrying due to network error: \(urlError.localizedDescription)")
                        let delay = pow(2.0, Double(retryCount))
                        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                        return try await synthesizeGeminiSingle(text: text, cacheKey: cacheKey, useFastSettings: useFastSettings, retryCount: retryCount + 1)
                    } else if text.count > 250 {
                        print("🔊 SummaryService (Gemini TTS) - Info: Retries exhausted, attempting smaller chunk processing")
                        return try await synthesizeGeminiWithSmallerChunks(text: text, cacheKey: cacheKey)
                    }
                default:
                    break
                }
            }
            
            throw error
        }
    }
    
    private func synthesizeGeminiWithSmallerChunks(text: String, cacheKey: String) async throws -> Data {
        print("🔊 SummaryService (Gemini TTS) - Info: Attempting recovery with smaller chunks (250 chars max)")
        
        let smallChunkSize = 250
        var chunks: [String] = []
        var currentIndex = text.startIndex
        
        while currentIndex < text.endIndex {
            let endIndex = text.index(currentIndex, offsetBy: min(smallChunkSize, text.distance(from: currentIndex, to: text.endIndex)))
            let chunk = String(text[currentIndex..<endIndex])
            chunks.append(chunk)
            currentIndex = endIndex
        }
        
        print("🔊 SummaryService (Gemini TTS) - Info: Split into \(chunks.count) small chunks for recovery")
        
        var audioData = Data()
        
        for (index, chunk) in chunks.enumerated() {
            do {
                let chunkData = try await synthesizeGeminiSingle(text: chunk, cacheKey: "\(cacheKey)_small_\(index)", useFastSettings: true, retryCount: 0)
                audioData.append(chunkData)
                
                if index < chunks.count - 1 {
                    try await Task.sleep(nanoseconds: 500_000_000) // 0.5 second delay
                }
            } catch {
                print("🔊 SummaryService (Gemini TTS) - Warning: Small chunk \(index) failed: \(error.localizedDescription)")
            }
        }
        
        if audioData.isEmpty {
            throw NSError(domain: "SummaryService.synthesizeSpeech", code: 6, 
                          userInfo: [NSLocalizedDescriptionKey: "All Gemini recovery attempts failed"])
        }
        
        cacheTTS(audioData, for: cacheKey)
        return audioData
    }
    
    private func synthesizeSpeechChunkedGemini(text: String, cacheKey: String) async throws -> Data {
        print("🔊 SummaryService (Gemini TTS) - Info: Starting chunked processing for \(text.count) characters")
        
        let sentences = splitIntoSentences(text)
        var chunks: [String] = []
        var currentChunk = ""
        
        for sentence in sentences {
            if currentChunk.count + sentence.count > ttsChunkSize && !currentChunk.isEmpty {
                chunks.append(currentChunk.trimmingCharacters(in: .whitespacesAndNewlines))
                currentChunk = sentence
            } else {
                if !currentChunk.isEmpty {
                    currentChunk += " "
                }
                currentChunk += sentence
            }
        }
        
        if !currentChunk.isEmpty {
            chunks.append(currentChunk.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        
        print("🔊 SummaryService (Gemini TTS) - Info: Split into \(chunks.count) chunks (target size: \(ttsChunkSize) chars)")
        
        var audioChunks: [Data] = []
        
        // Process chunks sequentially for better reliability
        for (index, chunk) in chunks.enumerated() {
            do {
                let chunkData = try await synthesizeGeminiSingle(text: chunk, cacheKey: "\(cacheKey)_chunk_\(index)")
                audioChunks.append(chunkData)
                
                if index < chunks.count - 1 {
                    try await Task.sleep(nanoseconds: 200_000_000) // 0.2 second delay
                }
                
            } catch {
                print("🔊 SummaryService (Gemini TTS) - Warning: Chunk \(index) failed: \(error.localizedDescription)")
                // Try recovery for failed chunks
                do {
                    let smallerChunkData = try await synthesizeGeminiWithSmallerChunks(text: chunk, cacheKey: "\(cacheKey)_chunk_\(index)_recovery")
                    audioChunks.append(smallerChunkData)
                } catch {
                    print("🔊 SummaryService (Gemini TTS) - Warning: Recovery for chunk \(index) also failed, skipping")
                }
            }
        }
        
        let combinedAudio = combineAudioChunks(audioChunks)
        cacheTTS(combinedAudio, for: cacheKey)
        
        print("🔊 SummaryService (Gemini TTS) - Info: Successfully combined \(audioChunks.count) audio chunks")
        return combinedAudio
    }
    
    // MARK: - Helper Functions
    
    // Helper function to split text into sentences
    private func splitIntoSentences(_ text: String) -> [String] {
        let sentenceEnders = CharacterSet(charactersIn: ".!?")
        var sentences: [String] = []
        var currentSentence = ""
        
        for char in text {
            currentSentence.append(char)
            
            if sentenceEnders.contains(char.unicodeScalars.first!) {
                let trimmed = currentSentence.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    sentences.append(trimmed)
                }
                currentSentence = ""
            }
        }
        
        // Add any remaining text as the last sentence
        let trimmed = currentSentence.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            sentences.append(trimmed)
        }
        
        // If no sentences were found, return the original text
        if sentences.isEmpty {
            sentences.append(text)
        }
        
        return sentences
    }
    
    // Helper function to combine audio chunks
    private func combineAudioChunks(_ chunks: [Data]) -> Data {
        var combinedData = Data()
        
        for chunk in chunks {
            combinedData.append(chunk)
        }
        
        return combinedData
    }
    
    // Legacy method name for backwards compatibility 
    private func synthesizeSpeechSingle(text: String, cacheKey: String, useFastSettings: Bool = false) async throws -> Data {
        // Route to the appropriate provider
        switch selectedTTSProvider {
        case .gemini:
            return try await synthesizeGeminiSingle(text: text, cacheKey: cacheKey, useFastSettings: useFastSettings)
        case .openai:
            return try await synthesizeOpenAISingle(text: text, cacheKey: cacheKey)
        }
    }
    
    // Public accessor for SettingsView
    func getOpenAIApiKey() -> String {
        return openaiApiKey
    }
    
    // MARK: - Fast-Start TTS for Immediate Playback
    
    func synthesizeSpeechFastStart(text: String, onFirstChunk: @escaping (Data) -> Void, onComplete: @escaping (Data) -> Void, onError: @escaping (Error) -> Void) async {
        // Generate cache key
        let cacheKey = generateCacheKey(for: text)
        
        // Check cache first - if fully cached, return immediately
        if let cachedData = getCachedTTS(for: cacheKey) {
            print("🔊 SummaryService (FastStart) - Info: Using fully cached audio")
            onFirstChunk(cachedData)
            onComplete(cachedData)
            return
        }
        
        // For short text, just use regular synthesis
        if text.count <= 600 {
            do {
                let audioData = try await synthesizeSpeechSingle(text: text, cacheKey: cacheKey)
                onFirstChunk(audioData)
                onComplete(audioData)
            } catch {
                onError(error)
            }
            return
        }
        
        // For long text, use fast-start approach
        await synthesizeFastStartChunked(text: text, cacheKey: cacheKey, onFirstChunk: onFirstChunk, onComplete: onComplete, onError: onError)
    }
    
    private func synthesizeFastStartChunked(text: String, cacheKey: String, onFirstChunk: @escaping (Data) -> Void, onComplete: @escaping (Data) -> Void, onError: @escaping (Error) -> Void) async {
        print("🔊 SummaryService (FastStart) - Info: Starting fast-start synthesis for \(text.count) characters")
        
        // Create a larger first chunk (800 chars) for substantial immediate playback
        let firstChunkSize = 800
        let sentences = splitIntoSentences(text)
        var firstChunk = ""
        var remainingText = ""
        var usedSentences = 0
        
        // Build first chunk up to target size
        for (index, sentence) in sentences.enumerated() {
            if firstChunk.count + sentence.count <= firstChunkSize {
                if !firstChunk.isEmpty { firstChunk += " " }
                firstChunk += sentence
                usedSentences = index + 1
            } else {
                break
            }
        }
        
        // Remaining text is everything after the first chunk
        if usedSentences < sentences.count {
            remainingText = sentences[usedSentences...].joined(separator: " ")
        }
        
        print("🔊 SummaryService (FastStart) - Info: First chunk: \(firstChunk.count) chars, Remaining: \(remainingText.count) chars")
        
        // Synthesize and play first chunk immediately
        do {
            let firstChunkData = try await synthesizeWithProvider(text: firstChunk, provider: selectedTTSProvider, cacheKey: "\(cacheKey)_first")
            onFirstChunk(firstChunkData)
            print("🔊 SummaryService (FastStart) - Info: ✅ First chunk ready and playing")
            
            // If no remaining text, we're done
            if remainingText.isEmpty {
                cacheTTS(firstChunkData, for: cacheKey)
                onComplete(firstChunkData)
                return
            }
            
            // Synthesize remaining text in background
            let remainingData = try await synthesizeWithProvider(text: remainingText, provider: selectedTTSProvider, cacheKey: "\(cacheKey)_remaining")
            print("🔊 SummaryService (FastStart) - Info: ✅ Remaining audio ready")
            
            // Combine all audio for cache and completion callback
            let completeAudio = combineAudioChunks([firstChunkData, remainingData])
            cacheTTS(completeAudio, for: cacheKey)
            onComplete(completeAudio)
            
        } catch {
            onError(error)
        }
    }
}

// MARK: - Shared Audio Utilities and Delegate (Fallback definitions if Utilities not in target)

import Foundation
#if os(iOS)
import AVFoundation
#elseif os(macOS)
import AppKit
#endif

// Provide the SoundDelegate definition here to ensure availability in all compilation units.
#if os(iOS)
public class SoundDelegate: NSObject, ObservableObject, AVAudioPlayerDelegate, AVSpeechSynthesizerDelegate {
    public var onPlaybackFinished: (() -> Void)?
    public var onSpeechFinished: (() -> Void)?
    public override init() { super.init() }
    public func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        if flag { onPlaybackFinished?() }
    }
    public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        onSpeechFinished?()
    }
}
#elseif os(macOS)
public class SoundDelegate: NSObject, ObservableObject, NSSoundDelegate, NSSpeechSynthesizerDelegate {
    public var onPlaybackFinished: (() -> Void)?
    public var onSpeechFinished: (() -> Void)?
    public override init() { super.init() }
    public func sound(_ sound: NSSound, didFinishPlaying flag: Bool) {
        if flag { onPlaybackFinished?() }
    }
    public func speechSynthesizer(_ sender: NSSpeechSynthesizer, didFinishSpeaking finishedSpeaking: Bool) {
        if finishedSpeaking { onSpeechFinished?() }
    }
}
#endif

// Utility to convert raw PCM to WAV data.
public func createWavData(from pcmData: Data, sampleRate: UInt32, channels: UInt16, bitsPerSample: UInt16) -> Data {
    var header = Data()
    let pcmDataSize = UInt32(pcmData.count)
    var chunkSize: UInt32 = 36 + pcmDataSize
    var subChunk1Size: UInt32 = 16
    var audioFormat: UInt16 = 1

    // RIFF header
    header.append("RIFF".data(using: .ascii)!)
    header.append(Data(bytes: &chunkSize, count: 4))
    header.append("WAVE".data(using: .ascii)!)

    // fmt sub-chunk
    header.append("fmt ".data(using: .ascii)!)
    header.append(Data(bytes: &subChunk1Size, count: 4))
    header.append(Data(bytes: &audioFormat, count: 2))
    var mutableChannels = channels
    header.append(Data(bytes: &mutableChannels, count: 2))
    var mutableSampleRate = sampleRate
    header.append(Data(bytes: &mutableSampleRate, count: 4))
    let byteRate = sampleRate * UInt32(channels) * UInt32(bitsPerSample) / 8
    var mutableByteRate = byteRate
    header.append(Data(bytes: &mutableByteRate, count: 4))
    let blockAlign = channels * bitsPerSample / 8
    var mutableBlockAlign = blockAlign
    header.append(Data(bytes: &mutableBlockAlign, count: 2))
    var mutableBits = bitsPerSample
    header.append(Data(bytes: &mutableBits, count: 2))

    // data sub-chunk
    header.append("data".data(using: .ascii)!)
    var mutablePcmSize = pcmDataSize
    header.append(Data(bytes: &mutablePcmSize, count: 4))

    var out = header
    out.append(pcmData)
    return out
}

// Detect MP3 format via header bytes.
public func isMP3Data(_ data: Data) -> Bool {
    guard data.count >= 3 else { return false }
    let bytes = [UInt8](data.prefix(3))
    if bytes[0] == 0x49 && bytes[1] == 0x44 && bytes[2] == 0x33 { return true } // ID3 tag
    let sync = (UInt16(bytes[0]) << 8) | UInt16(bytes[1])
    return (sync & 0xFFE0) == 0xFFE0 // Frame sync pattern
}
