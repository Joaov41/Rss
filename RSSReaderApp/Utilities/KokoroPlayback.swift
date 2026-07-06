#if os(iOS)
import AVFoundation

final class KokoroPlaybackRegistry {
    static let shared = KokoroPlaybackRegistry()
    private let lock = NSLock()
    private weak var currentPlayer: AVAudioPlayer?
    private var currentToken: UUID?

    private init() {}

    func setCurrent(player: AVAudioPlayer, token: UUID) {
        lock.lock()
        defer { lock.unlock() }
        currentToken = token
        currentPlayer = player
    }

    func clearIfMatching(token: UUID) {
        lock.lock()
        defer { lock.unlock() }
        guard currentToken == token else { return }
        currentPlayer = nil
        currentToken = nil
    }

    func stopCurrent() {
        lock.lock()
        defer { lock.unlock() }
        currentPlayer?.stop()
        currentPlayer = nil
        currentToken = nil
    }
}

func stopAnyKokoroPlaybackNow() {
    KokoroPlaybackRegistry.shared.stopCurrent()
}

func startKokoroPlayback(
    text: String,
    voice: String,
    speed: Double,
    allowCaching: Bool,
    precacheEnabled: Bool,
    setAudioPlayer: @escaping (AVAudioPlayer?) -> Void,
    soundDelegate: SoundDelegate,
    taskStore: inout Task<Void, Never>?,
    onCompleted: @escaping () -> Void,
    onError: @escaping (String) -> Void,
    onPlaybackStarted: (() -> Void)? = nil,
    stopCurrentPlayback: (() -> Void)? = nil
) {
    _ = soundDelegate
    taskStore?.cancel()
    KokoroTTSService.shared.cancelPlayback()
    let playbackToken = KokoroTTSService.shared.newPlaybackToken()
    KokoroPlaybackRegistry.shared.stopCurrent()
    stopCurrentPlayback?()
    setAudioPlayer(nil)
    taskStore = Task {
        defer {
            if !precacheEnabled {
                KokoroTTSService.shared.unloadIfAllowed()
            }
            Task { @MainActor in
                KokoroPlaybackRegistry.shared.clearIfMatching(token: playbackToken)
                setAudioPlayer(nil)
                if !precacheEnabled {
                    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
                }
                onCompleted()
            }
        }
        var nextTask: Task<Data, Error>? = nil
        do {
            print("🧪 [MLX TTS] start playback: chars=\(text.count) voice=\(voice) speed=\(speed)")
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

            try await withTaskCancellationHandler(operation: {
                let chunks = makeKokoroChunks(from: trimmed)
                guard let firstChunk = chunks.first else { return }

                func playChunk(_ data: Data) async throws -> TimeInterval {
                    try await MainActor.run {
                        do {
                            let player = try AVAudioPlayer(data: data)
                            player.delegate = nil
                            player.prepareToPlay()
                            KokoroPlaybackRegistry.shared.setCurrent(player: player, token: playbackToken)
                            setAudioPlayer(player)
                            if player.play() == false {
                                onError("Failed to start audio playback.")
                                throw NSError(domain: "KokoroPlayback", code: -1)
                            }
                            onPlaybackStarted?()
                            return player.duration
                        } catch {
                            onError("Failed to initialize audio player: \(error.localizedDescription)")
                            throw error
                        }
                    }
                }

                enum KokoroPlaybackError: Error {
                    case timeout
                }

                func synthesizeWithTimeout(_ text: String) async throws -> Data {
                    try await withThrowingTaskGroup(of: Data.self) { group in
                        group.addTask {
                            try await KokoroTTSService.shared.synthesize(
                                text: text,
                                voice: voice,
                                speed: Float(speed),
                                allowCaching: allowCaching
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

                if !KokoroTTSService.shared.isPlaybackTokenCurrent(playbackToken) { return }
                let firstData = try await synthesizeWithTimeout(firstChunk)
                if Task.isCancelled { return }
                if !KokoroTTSService.shared.isPlaybackTokenCurrent(playbackToken) { return }
                var currentDuration = try await playChunk(firstData)

                if chunks.count == 1 {
                    if Task.isCancelled { return }
                    if !KokoroTTSService.shared.isPlaybackTokenCurrent(playbackToken) { return }
                    try await Task.sleep(nanoseconds: UInt64(currentDuration * 1_000_000_000))
                    return
                }

                var nextIndex = 1
                nextTask = Task {
                    try await synthesizeWithTimeout(chunks[nextIndex])
                }
                defer { nextTask?.cancel() }

                while nextIndex < chunks.count {
                    try await Task.sleep(nanoseconds: UInt64(currentDuration * 1_000_000_000))
                    if Task.isCancelled { return }

                    guard let task = nextTask else { return }
                    let data = try await task.value
                    if Task.isCancelled { return }
                    if !KokoroTTSService.shared.isPlaybackTokenCurrent(playbackToken) { return }
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
                if Task.isCancelled { return }
                if !KokoroTTSService.shared.isPlaybackTokenCurrent(playbackToken) { return }
                try await Task.sleep(nanoseconds: UInt64(currentDuration * 1_000_000_000))
            }, onCancel: {
                nextTask?.cancel()
                KokoroPlaybackRegistry.shared.stopCurrent()
                stopCurrentPlayback?()
                setAudioPlayer(nil)
            })
        } catch {
            if Task.isCancelled { return }
            await MainActor.run {
                let message: String
                if let kokoroError = error as? KokoroTTSServiceError,
                   kokoroError == .notAvailable {
                    message = "MLX TTS is not available. Add the MLXAudio package and model access."
                } else if String(describing: error).contains("timeout") {
                    message = "MLX TTS is still loading models. Please wait a moment and try again."
                } else {
                    message = "MLX TTS failed: \(error.localizedDescription)"
                }
                onError(message)
            }
        }
    }
}
#endif
