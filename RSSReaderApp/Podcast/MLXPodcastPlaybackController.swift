import AVFoundation
import Combine
import CryptoKit
import Foundation
import OSLog

struct MLXPodcastPlaybackChunk: Identifiable, Equatable {
    let id: String
    let turnIndex: Int
    let speaker: PodcastSpeaker
    let text: String
    let isSpeakerChange: Bool
}

enum MLXPodcastPlaybackPlan {
    static func chunks(
        for episode: PodcastEpisode,
        firstChunkCharacters: Int = 140,
        maximumChunkCharacters: Int = 220
    ) -> [MLXPodcastPlaybackChunk] {
        var result: [MLXPodcastPlaybackChunk] = []
        var previousSpeaker: PodcastSpeaker?

        for (turnIndex, turn) in episode.turns.enumerated() {
            let text = PodcastSpokenTextCleaner.clean(turn.text)
            guard !text.isEmpty else { continue }
            let chunks = KokoroTTSService.shared.speechChunks(
                from: text,
                firstChunkCharacters: firstChunkCharacters,
                maximumChunkCharacters: maximumChunkCharacters
            )
            for (chunkIndex, chunk) in chunks.enumerated() {
                result.append(
                    MLXPodcastPlaybackChunk(
                        id: "turn-\(turnIndex)-chunk-\(chunkIndex)",
                        turnIndex: turnIndex,
                        speaker: turn.speaker,
                        text: chunk,
                        isSpeakerChange: chunkIndex == 0 && previousSpeaker != nil && previousSpeaker != turn.speaker
                    )
                )
                previousSpeaker = turn.speaker
            }
        }
        return result
    }

    static func voice(for speaker: PodcastSpeaker, hostAVoice: KokoroVoice, hostBVoice: KokoroVoice) -> KokoroVoice {
        speaker == .hostA ? hostAVoice : hostBVoice
    }
}

/// Keeps one bounded WAV file per synthesized podcast chunk. The cache is
/// episode/voice/speed-specific so Save Podcast can reuse audio already made
/// for playback without retaining the complete episode in memory.
private final class PodcastAudioCache {
    let cacheKey: String
    private let directory: URL

    init(
        episode: PodcastEpisode,
        plan: [MLXPodcastPlaybackChunk],
        hostAVoice: KokoroVoice,
        hostBVoice: KokoroVoice,
        speed: Float
    ) throws {
        let material = [
            episode.id.uuidString,
            episode.sourceDigest,
            hostAVoice.rawValue,
            hostBVoice.rawValue,
            String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), speed),
            plan.map { "\($0.id)|\($0.speaker.rawValue)|\($0.text)" }.joined(separator: "\n")
        ].joined(separator: "\u{1F}")
        cacheKey = SHA256.hash(data: Data(material.utf8))
            .map { String(format: "%02x", $0) }
            .joined()

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rss-podcast-audio-cache", isDirectory: true)
        directory = root.appendingPathComponent(cacheKey, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func read(chunkID: String) -> Data? {
        let url = directory.appendingPathComponent(Self.fileName(for: chunkID))
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        return data
    }

    func write(_ data: Data, for chunkID: String) {
        guard !data.isEmpty else { return }
        let url = directory.appendingPathComponent(Self.fileName(for: chunkID))
        try? data.write(to: url, options: .atomic)
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
        let root = directory.deletingLastPathComponent()
        if (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil))?.isEmpty == true {
            try? FileManager.default.removeItem(at: root)
        }
    }

    private static func fileName(for chunkID: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let safe = chunkID.unicodeScalars.map { allowed.contains($0) ? String($0) : "_" }.joined()
        return "\(safe).wav"
    }
}

enum MLXPodcastPlaybackState: Equatable {
    case idle
    case preparing
    case playing
    case paused
    case saving
    case finished
    case failed(String)

    var isPlaying: Bool { self == .playing }
}

@MainActor
final class MLXPodcastPlaybackController: ObservableObject {
    @Published private(set) var state: MLXPodcastPlaybackState = .idle
    @Published private(set) var progress: Double = 0
    @Published private(set) var currentTurnIndex: Int?
    @Published private(set) var currentSpeaker: PodcastSpeaker?
    @Published private(set) var statusMessage = ""
    @Published private(set) var errorMessage: String?

    private let logger = Logger(subsystem: "com.joaovalente.rssreader", category: "BatchPodcastPlayback")
    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private var engineConfigured = false
    private var playbackTask: Task<Void, Never>?
    private var operationID: UUID?
    private var pauseRequested = false
    private var activeLatches: [ObjectIdentifier: AudioCompletionLatch] = [:]
    private var activeAudioCache: PodcastAudioCache?

    func play(episode: PodcastEpisode, hostAVoice: KokoroVoice, hostBVoice: KokoroVoice, speed: Double) {
        stop()
        guard KokoroTTSService.shared.isAvailable else {
            fail(KokoroTTSServiceError.notAvailable.localizedDescription)
            return
        }

        let plan = MLXPodcastPlaybackPlan.chunks(for: episode)
        guard !plan.isEmpty else {
            fail("The podcast has no spoken audio.")
            return
        }

        logger.info("Podcast playback started: chunks=\(plan.count, privacy: .public), hostA=\(hostAVoice.rawValue, privacy: .public), hostB=\(hostBVoice.rawValue, privacy: .public), speed=\(speed, privacy: .public)")

        let token = KokoroTTSService.shared.newPlaybackToken()
        let operation = UUID()
        let clampedSpeed = min(max(speed, 0.5), 2.0)
        let audioCache = makeAudioCache(
            episode: episode,
            plan: plan,
            hostAVoice: hostAVoice,
            hostBVoice: hostBVoice,
            speed: Float(clampedSpeed)
        )
        operationID = operation
        pauseRequested = false
        progress = 0
        currentTurnIndex = nil
        currentSpeaker = nil
        errorMessage = nil
        statusMessage = "Preparing episode…"
        state = .preparing

        playbackTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.runPlayback(
                    plan: plan,
                    hostAVoice: hostAVoice,
                    hostBVoice: hostBVoice,
                    speed: Float(clampedSpeed),
                    token: token,
                    operation: operation,
                    audioCache: audioCache
                )
                guard self.operationID == operation else { return }
                self.playbackTask = nil
                self.operationID = nil
                self.state = .finished
                self.statusMessage = "Episode finished"
            } catch is CancellationError {
                guard self.operationID == operation else { return }
                self.playbackTask = nil
                self.operationID = nil
                self.state = .idle
                self.statusMessage = ""
            } catch {
                guard self.operationID == operation else { return }
                self.playbackTask = nil
                self.operationID = nil
                self.logger.error("Podcast playback failed: \(error.localizedDescription, privacy: .public); type=\(String(reflecting: type(of: error)), privacy: .public); turn=\(self.currentTurnIndex ?? -1, privacy: .public); speaker=\(self.currentSpeaker?.rawValue ?? "none", privacy: .public); engineRunning=\(self.engine.isRunning, privacy: .public)")
                self.fail(error.localizedDescription)
            }
        }
    }

    func pause() {
        guard state == .playing || state == .preparing else { return }
        pauseRequested = true
        playerNode.pause()
        state = .paused
        statusMessage = "Paused"
    }

    func resume() {
        guard state == .paused else { return }
        pauseRequested = false
        if engine.isRunning { playerNode.play() }
        state = .playing
        statusMessage = "Playing"
    }

    func stop() {
        playbackTask?.cancel()
        playbackTask = nil
        operationID = nil
        pauseRequested = false
        KokoroTTSService.shared.cancelPlayback()
        playerNode.stop()
        engine.stop()
        completeAllLatches(with: CancellationError())
        state = .idle
        progress = 0
        currentTurnIndex = nil
        currentSpeaker = nil
        statusMessage = ""
        errorMessage = nil
    }

    func clearAudioCache() {
        activeAudioCache?.remove()
        activeAudioCache = nil
    }

    func renderEpisodeForExport(
        _ episode: PodcastEpisode,
        hostAVoice: KokoroVoice,
        hostBVoice: KokoroVoice,
        speed: Double,
        progressHandler: (@MainActor (Int, Int) -> Void)? = nil
    ) async throws -> URL {
        guard KokoroTTSService.shared.isAvailable else {
            throw BatchPodcastError.audioExportFailed(KokoroTTSServiceError.notAvailable.localizedDescription)
        }
        let plan = MLXPodcastPlaybackPlan.chunks(for: episode)
        guard !plan.isEmpty else { throw BatchPodcastError.audioExportFailed("The podcast has no spoken audio.") }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("rss-podcast-export-\(UUID().uuidString)", isDirectory: true)
        let url = directory.appendingPathComponent(Self.exportFileName(for: episode.title)).appendingPathExtension("wav")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let token = KokoroTTSService.shared.newPlaybackToken()
        let cache = makeAudioCache(
            episode: episode,
            plan: plan,
            hostAVoice: hostAVoice,
            hostBVoice: hostBVoice,
            speed: Float(min(max(speed, 0.5), 2.0))
        )
        var writer: BatchPodcastWAVWriter?
        do {
            for (index, chunk) in plan.enumerated() {
                try Task.checkCancellation()
                let data = try await synthesize(
                    chunk: chunk,
                    hostAVoice: hostAVoice,
                    hostBVoice: hostBVoice,
                    speed: Float(min(max(speed, 0.5), 2.0)),
                    token: token,
                    audioCache: cache
                )
                if writer == nil { writer = try BatchPodcastWAVWriter(url: url) }
                try writer?.append(wavData: data)
                progressHandler?(index + 1, plan.count)
            }
            try writer?.finish()
            writer = nil
            return url
        } catch {
            try? writer?.finish()
            try? FileManager.default.removeItem(at: directory)
            KokoroTTSService.shared.cancelPlayback()
            throw error
        }
    }

    private func runPlayback(
        plan: [MLXPodcastPlaybackChunk],
        hostAVoice: KokoroVoice,
        hostBVoice: KokoroVoice,
        speed: Float,
        token: UUID,
        operation: UUID,
        audioCache: PodcastAudioCache?
    ) async throws {
        var index = 0
        let firstData = try await synthesize(
            chunk: plan[0],
            hostAVoice: hostAVoice,
            hostBVoice: hostBVoice,
            speed: speed,
            token: token,
            audioCache: audioCache
        )
        var currentBuffer = try makeBuffer(from: firstData)
        try ensureEngine(format: currentBuffer.format)
        try await waitIfPaused()

        var currentLatch = schedule(currentBuffer)
        playerNode.play()
        state = .playing
        currentTurnIndex = plan[0].turnIndex
        currentSpeaker = plan[0].speaker
        statusMessage = "Playing \(plan[0].speaker.displayName)"

        var nextTask: Task<Data, Error>? = plan.count > 1
            ? makeSynthesisTask(
                chunk: plan[1],
                hostAVoice: hostAVoice,
                hostBVoice: hostBVoice,
                speed: speed,
                token: token,
                audioCache: audioCache
            )
            : nil
        defer { nextTask?.cancel() }

        while true {
            try Task.checkCancellation()
            guard operationID == operation,
                  KokoroTTSService.shared.isPlaybackTokenCurrent(token) else { throw CancellationError() }

            var nextScheduled: (buffer: AVAudioPCMBuffer, latch: AudioCompletionLatch)?
            if let nextTask {
                state = .playing
                let nextData = try await nextTask.value
                let buffer = try makeBuffer(from: nextData)
                if plan.indices.contains(index + 1), plan[index + 1].isSpeakerChange,
                   let silence = makeSilenceBuffer(format: currentBuffer.format, duration: 0.12) {
                    _ = schedule(silence)
                }
                nextScheduled = (buffer, schedule(buffer))
            }

            try await currentLatch.wait()
            progress = Double(index + 1) / Double(plan.count)
            guard let nextScheduled else { break }

            index += 1
            currentBuffer = nextScheduled.buffer
            currentLatch = nextScheduled.latch
            currentTurnIndex = plan[index].turnIndex
            currentSpeaker = plan[index].speaker
            statusMessage = "Playing \(plan[index].speaker.displayName)"

            let followingIndex = index + 1
            nextTask = plan.indices.contains(followingIndex)
                ? makeSynthesisTask(
                    chunk: plan[followingIndex],
                    hostAVoice: hostAVoice,
                    hostBVoice: hostBVoice,
                    speed: speed,
                    token: token,
                    audioCache: audioCache
                )
                : nil
            try await waitIfPaused()
        }

        progress = 1
    }

    private func makeSynthesisTask(
        chunk: MLXPodcastPlaybackChunk,
        hostAVoice: KokoroVoice,
        hostBVoice: KokoroVoice,
        speed: Float,
        token: UUID,
        audioCache: PodcastAudioCache?
    ) -> Task<Data, Error> {
        Task { [weak self] in
            guard let self else { throw CancellationError() }
            return try await self.synthesize(
                chunk: chunk,
                hostAVoice: hostAVoice,
                hostBVoice: hostBVoice,
                speed: speed,
                token: token,
                audioCache: audioCache
            )
        }
    }

    private func synthesize(
        chunk: MLXPodcastPlaybackChunk,
        hostAVoice: KokoroVoice,
        hostBVoice: KokoroVoice,
        speed: Float,
        token: UUID,
        audioCache: PodcastAudioCache?
    ) async throws -> Data {
        try Task.checkCancellation()
        guard KokoroTTSService.shared.isPlaybackTokenCurrent(token) else { throw CancellationError() }
        if let cached = audioCache?.read(chunkID: chunk.id) {
            logger.info("Reusing cached podcast chunk: id=\(chunk.id, privacy: .public), bytes=\(cached.count, privacy: .public)")
            return cached
        }
        let voice = MLXPodcastPlaybackPlan.voice(for: chunk.speaker, hostAVoice: hostAVoice, hostBVoice: hostBVoice)
        logger.info("Podcast chunk synthesis started: id=\(chunk.id, privacy: .public), turn=\(chunk.turnIndex, privacy: .public), speaker=\(chunk.speaker.rawValue, privacy: .public), voice=\(voice.rawValue, privacy: .public), chars=\(chunk.text.count, privacy: .public)")
        let data: Data
        do {
            data = try await KokoroTTSService.shared.synthesize(
                text: chunk.text,
                voice: voice.rawValue,
                speed: speed,
                allowCaching: false
            )
        } catch {
            logger.error("Podcast chunk synthesis failed: id=\(chunk.id, privacy: .public), voice=\(voice.rawValue, privacy: .public), error=\(error.localizedDescription, privacy: .public), type=\(String(reflecting: type(of: error)), privacy: .public)")
            throw error
        }
        guard KokoroTTSService.shared.isPlaybackTokenCurrent(token) else { throw CancellationError() }
        audioCache?.write(data, for: chunk.id)
        logger.info("Podcast chunk synthesis finished: id=\(chunk.id, privacy: .public), bytes=\(data.count, privacy: .public)")
        return data
    }

    private func makeAudioCache(
        episode: PodcastEpisode,
        plan: [MLXPodcastPlaybackChunk],
        hostAVoice: KokoroVoice,
        hostBVoice: KokoroVoice,
        speed: Float
    ) -> PodcastAudioCache? {
        guard let cache = try? PodcastAudioCache(
            episode: episode,
            plan: plan,
            hostAVoice: hostAVoice,
            hostBVoice: hostBVoice,
            speed: speed
        ) else {
            logger.error("Podcast audio cache could not be created; continuing without disk reuse.")
            return nil
        }

        if let previous = activeAudioCache, previous.cacheKey != cache.cacheKey {
            previous.remove()
        }
        activeAudioCache = cache
        return cache
    }

    private func ensureEngine(format: AVAudioFormat) throws {
        if !engineConfigured {
            engine.attach(playerNode)
            engine.connect(playerNode, to: engine.mainMixerNode, format: format)
            engineConfigured = true
        }
        if !engine.isRunning { try engine.start() }
    }

    private func makeBuffer(from data: Data) throws -> AVAudioPCMBuffer {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rss-podcast-buffer-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try data.write(to: url, options: .atomic)
        let file = try AVAudioFile(forReading: url)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw BatchPodcastError.audioExportFailed("The synthesized chunk could not be decoded.")
        }
        try file.read(into: buffer)
        return buffer
    }

    private func makeSilenceBuffer(format: AVAudioFormat, duration: TimeInterval) -> AVAudioPCMBuffer? {
        let frames = AVAudioFrameCount(max(1, Int(format.sampleRate * duration)))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames
        if let channels = buffer.floatChannelData {
            for channel in 0..<Int(format.channelCount) {
                for frame in 0..<Int(frames) { channels[channel][frame] = 0 }
            }
        }
        return buffer
    }

    private func schedule(_ buffer: AVAudioPCMBuffer) -> AudioCompletionLatch {
        let latch = AudioCompletionLatch()
        activeLatches[ObjectIdentifier(latch)] = latch
        playerNode.scheduleBuffer(buffer) { [weak self, weak latch] in
            latch?.complete()
            Task { @MainActor [weak self, weak latch] in
                guard let self, let latch else { return }
                self.activeLatches.removeValue(forKey: ObjectIdentifier(latch))
            }
        }
        return latch
    }

    private func completeAllLatches(with error: Error) {
        let latches = activeLatches.values
        activeLatches.removeAll()
        latches.forEach { $0.complete(with: error) }
    }

    private func waitIfPaused() async throws {
        while pauseRequested {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    private func fail(_ message: String) {
        logger.error("Podcast playback entered failed state: \(message, privacy: .public)")
        errorMessage = message
        state = .failed(message)
        statusMessage = "Playback failed"
    }

    private static func exportFileName(for title: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(.whitespaces).union(CharacterSet(charactersIn: "-_"))
        let cleaned = title.unicodeScalars.map { allowed.contains($0) ? String($0) : "-" }.joined()
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String((cleaned.isEmpty ? "RSS Batch Podcast" : cleaned).prefix(80))
    }
}

private final class AudioCompletionLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private var continuation: CheckedContinuation<Void, Error>?

    func wait() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if finished {
                    lock.unlock()
                    continuation.resume()
                } else {
                    self.continuation = continuation
                    lock.unlock()
                }
            }
        } onCancel: {
            self.complete(with: CancellationError())
        }
    }

    func complete() { complete(with: nil) }

    func complete(with error: Error?) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        if let error { continuation?.resume(throwing: error) }
        else { continuation?.resume() }
    }
}

final class BatchPodcastWAVWriter {
    private let handle: FileHandle
    private var formatPayload: Data?
    private var dataSizeOffset: UInt64?
    private var dataByteCount: UInt64 = 0
    private var finished = false

    init(url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
    }

    func append(wavData: Data) throws {
        guard !finished else { return }
        guard let chunks = Self.findChunks(in: wavData) else {
            throw BatchPodcastError.audioExportFailed("The synthesized chunk was not a PCM WAV file.")
        }

        if let formatPayload {
            guard formatPayload == chunks.format.payload else {
                throw BatchPodcastError.audioExportFailed("Audio chunks used incompatible formats.")
            }
        } else {
            formatPayload = chunks.format.payload
            try handle.write(contentsOf: Data(wavData[0..<chunks.data.payloadStart]))
            dataSizeOffset = UInt64(chunks.data.payloadStart - 4)
        }

        try handle.seekToEnd()
        try handle.write(contentsOf: Data(wavData[chunks.data.payloadStart..<chunks.data.payloadEnd]))
        dataByteCount += UInt64(chunks.data.payloadEnd - chunks.data.payloadStart)
    }

    func finish() throws {
        guard !finished else { return }
        finished = true
        defer { try? handle.close() }
        guard let dataSizeOffset else { return }
        try handle.seek(toOffset: 4)
        try handle.write(contentsOf: Self.littleEndian(UInt32(min(UInt64(UInt32.max), 36 + dataByteCount))))
        try handle.seek(toOffset: dataSizeOffset)
        try handle.write(contentsOf: Self.littleEndian(UInt32(min(UInt64(UInt32.max), dataByteCount))))
        try handle.synchronize()
    }

    deinit { try? handle.close() }

    private struct Chunk {
        let payloadStart: Int
        let payloadEnd: Int
        let payload: Data
    }

    private static func findChunks(in data: Data) -> (data: Chunk, format: Chunk)? {
        guard data.count >= 12,
              String(bytes: data[0..<4], encoding: .ascii) == "RIFF",
              String(bytes: data[8..<12], encoding: .ascii) == "WAVE" else { return nil }
        var cursor = 12
        var dataChunk: Chunk?
        var formatChunk: Chunk?
        while cursor + 8 <= data.count {
            let id = String(bytes: data[cursor..<(cursor + 4)], encoding: .ascii) ?? ""
            let size = Int(readUInt32(data, offset: cursor + 4))
            let start = cursor + 8
            let end = min(data.count, start + size)
            guard end >= start else { return nil }
            let chunk = Chunk(payloadStart: start, payloadEnd: end, payload: Data(data[start..<end]))
            if id == "fmt " { formatChunk = chunk }
            if id == "data" { dataChunk = chunk }
            cursor = end + (size % 2)
        }
        guard let dataChunk, let formatChunk else { return nil }
        return (dataChunk, formatChunk)
    }

    private static func readUInt32(_ data: Data, offset: Int) -> UInt32 {
        UInt32(data[offset]) | (UInt32(data[offset + 1]) << 8) | (UInt32(data[offset + 2]) << 16) | (UInt32(data[offset + 3]) << 24)
    }

    private static func littleEndian(_ value: UInt32) -> Data {
        Data([UInt8(value & 0xff), UInt8((value >> 8) & 0xff), UInt8((value >> 16) & 0xff), UInt8((value >> 24) & 0xff)])
    }
}
