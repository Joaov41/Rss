#if os(iOS)
import AVFoundation
import CryptoKit
import Foundation
import UIKit

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

private enum PreparedKokoroAudioCache {
    private static let cacheVersion = "prepared-v1"
    private static let maximumFiles = 24

    static func preparedURL(text: String, voice: String, speed: Double) throws -> URL {
        let material = [
            cacheVersion,
            voice,
            String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), speed),
            text,
        ].joined(separator: "\u{1F}")
        let digest = SHA256.hash(data: Data(material.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rss-prepared-summary-audio", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.appendingPathComponent(digest).appendingPathExtension("wav")
    }

    static func existingURL(_ url: URL) -> URL? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
              let fileSize = values.fileSize,
              fileSize > 44 else { return nil }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        return url
    }

    static func temporaryURL(nextTo finalURL: URL) -> URL {
        finalURL.deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString).partial.wav")
    }

    static func publish(temporaryURL: URL, finalURL: URL) throws -> URL {
        let fileManager = FileManager.default
        if existingURL(finalURL) != nil {
            try? fileManager.removeItem(at: temporaryURL)
            return finalURL
        }
        try fileManager.moveItem(at: temporaryURL, to: finalURL)
        prune(directory: finalURL.deletingLastPathComponent(), keeping: finalURL)
        return finalURL
    }

    private static func prune(directory: URL, keeping currentURL: URL) {
        guard var files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        files = files.filter { $0.pathExtension == "wav" && $0 != currentURL }
        files.sort {
            let lhs = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let rhs = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return lhs > rhs
        }
        for staleURL in files.dropFirst(maximumFiles - 1) {
            try? FileManager.default.removeItem(at: staleURL)
        }
    }
}

func stopAnyKokoroPlaybackNow() {
    KokoroPlaybackRegistry.shared.stopCurrent()
}

private func configurePreparedKokoroAudioSession() throws {
    let audioSession = AVAudioSession.sharedInstance()
    try audioSession.setCategory(
        .playback,
        mode: .spokenAudio,
        options: [.duckOthers]
    )
    try audioSession.setActive(true)
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
        var idleTimerProtectionActive = true
        let previousIdleTimerSetting = await MainActor.run {
            let previous = UIApplication.shared.isIdleTimerDisabled
            UIApplication.shared.isIdleTimerDisabled = true
            return previous
        }
        defer {
            if !precacheEnabled {
                KokoroTTSService.shared.unloadIfAllowed()
            }
            Task { @MainActor in
                if idleTimerProtectionActive {
                    UIApplication.shared.isIdleTimerDisabled = previousIdleTimerSetting
                }
                KokoroPlaybackRegistry.shared.clearIfMatching(token: playbackToken)
                setAudioPlayer(nil)
                if !precacheEnabled {
                    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
                }
                onCompleted()
            }
        }

        var partialURL: URL?
        do {
            print("🧪 [MLX TTS] prepare complete audio: chars=\(text.count) voice=\(voice) speed=\(speed)")
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

            enum KokoroPlaybackError: Error {
                case timeout
            }

            func waitUntilApplicationIsActive() async throws {
                while await MainActor.run(body: { UIApplication.shared.applicationState != .active }) {
                    try Task.checkCancellation()
                    try await Task.sleep(nanoseconds: 150_000_000)
                }
            }

            func synthesizeWithTimeout(_ text: String) async throws -> Data {
                let timeoutNanoseconds: UInt64 = KokoroTTSService.shared.isModelReady
                    ? 20_000_000_000
                    : 120_000_000_000
                return try await withThrowingTaskGroup(of: Data.self) { group in
                    group.addTask {
                        try await KokoroTTSService.shared.synthesize(
                            text: text,
                            voice: voice,
                            speed: Float(speed),
                            allowCaching: allowCaching
                        )
                    }
                    group.addTask {
                        try await Task.sleep(nanoseconds: timeoutNanoseconds)
                        throw KokoroPlaybackError.timeout
                    }
                    let result = try await group.next()!
                    group.cancelAll()
                    return result
                }
            }

            try await withTaskCancellationHandler(operation: {
                let chunks = makeKokoroChunks(from: trimmed)
                guard !chunks.isEmpty else { return }
                let finalURL = try PreparedKokoroAudioCache.preparedURL(text: trimmed, voice: voice, speed: speed)
                let preparedURL: URL

                if let cachedURL = PreparedKokoroAudioCache.existingURL(finalURL) {
                    preparedURL = cachedURL
                } else {
                    let temporaryURL = PreparedKokoroAudioCache.temporaryURL(nextTo: finalURL)
                    partialURL = temporaryURL
                    var writer: BatchPodcastWAVWriter? = try BatchPodcastWAVWriter(url: temporaryURL)
                    do {
                        for chunk in chunks {
                            try Task.checkCancellation()
                            guard KokoroTTSService.shared.isPlaybackTokenCurrent(playbackToken) else {
                                throw CancellationError()
                            }
                            try await waitUntilApplicationIsActive()
                            let data = try await synthesizeWithTimeout(chunk)
                            try Task.checkCancellation()
                            guard KokoroTTSService.shared.isPlaybackTokenCurrent(playbackToken) else {
                                throw CancellationError()
                            }
                            try writer?.append(wavData: data)
                        }
                        try writer?.finish()
                        writer = nil
                        preparedURL = try PreparedKokoroAudioCache.publish(
                            temporaryURL: temporaryURL,
                            finalURL: finalURL
                        )
                        partialURL = nil
                    } catch {
                        try? writer?.finish()
                        writer = nil
                        throw error
                    }
                }

                try Task.checkCancellation()
                guard KokoroTTSService.shared.isPlaybackTokenCurrent(playbackToken) else {
                    throw CancellationError()
                }

                await MainActor.run {
                    UIApplication.shared.isIdleTimerDisabled = previousIdleTimerSetting
                }
                idleTimerProtectionActive = false
                let duration = try await MainActor.run { () throws -> TimeInterval in
                    try configurePreparedKokoroAudioSession()
                    let player = try AVAudioPlayer(contentsOf: preparedURL)
                    player.delegate = nil
                    player.prepareToPlay()
                    KokoroPlaybackRegistry.shared.setCurrent(player: player, token: playbackToken)
                    setAudioPlayer(player)
                    guard player.play() else {
                        throw NSError(
                            domain: "KokoroPlayback",
                            code: -1,
                            userInfo: [NSLocalizedDescriptionKey: "Failed to start audio playback."]
                        )
                    }
                    onPlaybackStarted?()
                    return player.duration
                }
                try await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            }, onCancel: {
                KokoroPlaybackRegistry.shared.stopCurrent()
                stopCurrentPlayback?()
                setAudioPlayer(nil)
            })
        } catch {
            if let partialURL { try? FileManager.default.removeItem(at: partialURL) }
            if Task.isCancelled { return }
            await MainActor.run {
                let message: String
                if let kokoroError = error as? KokoroTTSServiceError,
                   kokoroError == .notAvailable {
                    message = "MLX TTS is not available. Add the MLXAudio package and model access."
                } else if KokoroTTSService.shared.isModelLoading {
                    message = "Local TTS is still preparing its model. Keep the app open, then try again."
                } else if !KokoroTTSService.shared.isModelReady {
                    message = "Local TTS could not finish preparing its model. Please try again."
                } else if String(describing: error).contains("timeout") {
                    message = "MLX TTS timed out while preparing audio. Please try again."
                } else {
                    message = "MLX TTS failed: \(error.localizedDescription)"
                }
                onError(message)
            }
        }
    }
}
#endif
