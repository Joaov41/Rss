import Foundation
import AVFoundation

#if canImport(MLXAudioCore) && canImport(MLXAudioTTS)
import MLXAudioCore
import MLXAudioTTS
import MLXLMCommon
import MLX
#endif

enum LocalTTSEngine: String, CaseIterable, Codable, Identifiable {
    case system = "System"
    case kokoro = "Kokoro"

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .system:
            return "System"
        case .kokoro:
            return "MLX TTS"
        }
    }

    static var availableEngines: [LocalTTSEngine] {
        #if canImport(MLXAudioCore) && canImport(MLXAudioTTS)
        return [.system, .kokoro]
        #else
        return [.system]
        #endif
    }
}

enum KokoroVoice: String, CaseIterable, Codable, Identifiable {
    case alba
    case marius
    case javert
    case jean
    case fantine
    case cosette
    case eponine
    case azelma

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .alba:
            return "Alba"
        case .marius:
            return "Marius"
        case .javert:
            return "Javert"
        case .jean:
            return "Jean"
        case .fantine:
            return "Fantine"
        case .cosette:
            return "Cosette"
        case .eponine:
            return "Eponine"
        case .azelma:
            return "Azelma"
        }
    }

    static var defaultVoice: KokoroVoice { .alba }
}

enum KokoroTTSServiceError: LocalizedError {
    case notAvailable

    var errorDescription: String? {
        switch self {
        case .notAvailable:
            return "Local MLX TTS is not available in this build."
        }
    }
}

final class KokoroTTSService {
    static let shared = KokoroTTSService()
    private let cachedVoiceKey = "Kokoro.CachedVoice"
    private let legacyCachedVoicesKey = "Kokoro.CachedVoices"
    private let playbackLock = NSLock()
    private var playbackToken = UUID()

    #if canImport(MLXAudioCore) && canImport(MLXAudioTTS)
    private let modelRepo = "mlx-community/pocket-tts"
    private let initLock = NSLock()
    private var model: SpeechGenerationModel?
    private var initTask: Task<SpeechGenerationModel, Error>?
    private var hasConfiguredMemory = false
    #endif

    private init() { }

    func newPlaybackToken() -> UUID {
        playbackLock.lock()
        defer { playbackLock.unlock() }
        let token = UUID()
        playbackToken = token
        return token
    }

    func isPlaybackTokenCurrent(_ token: UUID) -> Bool {
        playbackLock.lock()
        defer { playbackLock.unlock() }
        return playbackToken == token
    }

    func cancelPlayback() {
        playbackLock.lock()
        playbackToken = UUID()
        playbackLock.unlock()
    }

    var isAvailable: Bool {
        #if canImport(MLXAudioCore) && canImport(MLXAudioTTS)
        return true
        #else
        return false
        #endif
    }

    func synthesize(text: String, voice: String, speed: Float, allowCaching: Bool = true) async throws -> Data {
        #if canImport(MLXAudioCore) && canImport(MLXAudioTTS)
        if allowCaching {
            recordVoiceForWarmup(voice)
        }
        configureMemoryIfNeeded()

        let model = try await ensureInitialized(preloadVoice: allowCaching ? voice : nil)
        let selectedVoice = normalizedVoice(voice)
        let generationParams = generationParameters(for: speed)

        let audio = try await model.generate(
            text: text,
            voice: selectedVoice,
            refAudio: nil,
            refText: nil,
            language: nil,
            generationParameters: generationParams
        )
        let samples = audio.asArray(Float.self)

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mlx_tts_\(UUID().uuidString).wav")

        defer { try? FileManager.default.removeItem(at: tempURL) }

        try writeWavFile(samples: samples, sampleRate: Double(model.sampleRate), to: tempURL)
        // Keep memory bounded between chunks. This clears temporary MLX buffers, not model weights.
        Memory.clearCache()
        return try Data(contentsOf: tempURL)
        #else
        _ = (text, voice, speed, allowCaching)
        throw KokoroTTSServiceError.notAvailable
        #endif
    }

    func warmUp(preloadVoices: Set<String>? = nil) async throws {
        #if canImport(MLXAudioCore) && canImport(MLXAudioTTS)
        let voice = preloadVoices?.first ?? cachedVoiceForWarmup()
        let model = try await ensureInitialized(preloadVoice: voice)

        let warmupVoice = normalizedVoice(voice)
        _ = try await model.generate(
            text: "Hi.",
            voice: warmupVoice,
            refAudio: nil,
            refText: nil,
            language: nil,
            generationParameters: GenerateParameters(maxTokens: 32, temperature: 0.6)
        )
        #else
        _ = preloadVoices
        throw KokoroTTSServiceError.notAvailable
        #endif
    }

    func recordVoiceForWarmup(_ voice: String) {
        let trimmed = voice.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Keep only the currently selected voice to limit memory usage.
        UserDefaults.standard.removeObject(forKey: legacyCachedVoicesKey)
        UserDefaults.standard.set(trimmed, forKey: cachedVoiceKey)
    }

    func unloadIfAllowed() {
        #if canImport(MLXAudioCore) && canImport(MLXAudioTTS)
        initLock.lock()
        initTask?.cancel()
        initTask = nil
        model = nil
        initLock.unlock()
        Memory.clearCache()
        #endif
    }

    private func cachedVoiceForWarmup() -> String? {
        if let stored = UserDefaults.standard.string(forKey: cachedVoiceKey) {
            let trimmed = stored.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return nil
    }

    #if canImport(MLXAudioCore) && canImport(MLXAudioTTS)
    private func generationParameters(for speed: Float) -> GenerateParameters {
        // Pocket TTS does not expose direct speed control. We keep timing fairly stable.
        let clampedSpeed = max(0.5, min(2.0, speed))
        let temperature: Float = clampedSpeed > 1.2 ? 0.55 : 0.6
        return GenerateParameters(
            // Lower token cap keeps peak memory lower and prevents long runaway generations.
            maxTokens: 220,
            maxKVSize: 256,
            temperature: temperature,
            topP: 0.8,
            repetitionPenalty: 1.3,
            repetitionContextSize: 20,
            prefillStepSize: 128
        )
    }

    private func configureMemoryIfNeeded() {
        initLock.lock()
        defer { initLock.unlock() }
        guard !hasConfiguredMemory else { return }
        // Mirror the bounded-cache strategy used by local LLM inference.
        GPU.set(cacheLimit: 512 * 1024 * 1024)
        hasConfiguredMemory = true
    }

    private func normalizedVoice(_ voice: String?) -> String {
        guard let voice else { return KokoroVoice.defaultVoice.rawValue }
        let trimmed = voice.trimmingCharacters(in: .whitespacesAndNewlines)
        guard KokoroVoice.allCases.map(\.rawValue).contains(trimmed) else {
            return KokoroVoice.defaultVoice.rawValue
        }
        return trimmed
    }

    private func currentModel() -> SpeechGenerationModel? {
        initLock.lock()
        defer { initLock.unlock() }
        return model
    }

    private func currentInitTask() -> Task<SpeechGenerationModel, Error>? {
        initLock.lock()
        defer { initLock.unlock() }
        return initTask
    }

    private func setInitTask(_ task: Task<SpeechGenerationModel, Error>?) {
        initLock.lock()
        initTask = task
        initLock.unlock()
    }

    private func setModel(_ loadedModel: SpeechGenerationModel?) {
        initLock.lock()
        model = loadedModel
        initLock.unlock()
    }

    private func ensureInitialized(preloadVoice: String?) async throws -> SpeechGenerationModel {
        configureMemoryIfNeeded()
        if let model = currentModel() {
            return model
        }

        if let task = currentInitTask() {
            return try await task.value
        }

        let task = Task<SpeechGenerationModel, Error> {
            if let preloadVoice {
                _ = self.normalizedVoice(preloadVoice)
            }
            return try await TTSModelUtils.loadModel(modelRepo: self.modelRepo)
        }

        setInitTask(task)
        do {
            let loadedModel = try await task.value
            setModel(loadedModel)
            setInitTask(nil)
            return loadedModel
        } catch {
            setInitTask(nil)
            throw error
        }
    }

    private func writeWavFile(samples: [Float], sampleRate: Double, to url: URL) throws {
        let frameCount = AVAudioFrameCount(samples.count)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
              let channelData = buffer.floatChannelData else {
            throw NSError(
                domain: "KokoroTTSService",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to create audio buffer for WAV output."]
            )
        }

        buffer.frameLength = frameCount
        for i in 0..<samples.count {
            channelData[0][i] = samples[i]
        }

        let audioFile = try AVAudioFile(forWriting: url, settings: format.settings)
        try audioFile.write(from: buffer)
    }
    #endif
}
