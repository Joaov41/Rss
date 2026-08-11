import Combine
import Foundation

@MainActor
final class BatchPodcastSession: ObservableObject {
    enum State: Equatable {
        case idle
        case generating
        case ready
        case saving
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var context: BatchPodcastContext?
    @Published private(set) var episode: PodcastEpisode?
    @Published private(set) var progress: Double = 0
    @Published private(set) var progressMessage = ""
    @Published private(set) var errorMessage: String?
    @Published private(set) var isPresented = false
    @Published private(set) var isMinimized = false
    @Published private(set) var requiresSummariesOnlyConfirmation = false
    @Published private(set) var selectedProvider: AppSettings.SummaryProvider?
    @Published var hostAVoice: KokoroVoice = .alba
    @Published var hostBVoice: KokoroVoice = .marius
    @Published var speed: Double = 1.0
    @Published var exportURL: URL?

    let playbackController = MLXPodcastPlaybackController()

    private var textGenerator: (@MainActor (String, String, AppSettings.SummaryProvider) async throws -> String)?
    private var providerProvider: (@MainActor () -> AppSettings.SummaryProvider)?
    private var generationTask: Task<Void, Never>?
    private var exportTask: Task<Void, Never>?

    func configureTextGenerator(
        provider: @escaping @MainActor () -> AppSettings.SummaryProvider = { .gemini },
        generator: @escaping @MainActor (String, String, AppSettings.SummaryProvider) async throws -> String
    ) {
        providerProvider = provider
        textGenerator = generator
    }

    func present(
        context: BatchPodcastContext,
        requiresSummariesOnlyConfirmation: Bool,
        hostAVoice: KokoroVoice = .alba,
        hostBVoice: KokoroVoice = .marius
    ) {
        if self.context?.sourceDigest != context.sourceDigest {
            generationTask?.cancel()
            exportTask?.cancel()
            exportTask = nil
            playbackController.stop()
            playbackController.clearAudioCache()
            cleanupExportURL()
            episode = nil
            progress = 0
            progressMessage = ""
            errorMessage = nil
            state = .idle
        }
        self.context = context
        self.requiresSummariesOnlyConfirmation = requiresSummariesOnlyConfirmation
        self.hostAVoice = hostAVoice
        self.hostBVoice = hostBVoice
        isPresented = true
        isMinimized = false
    }

    func presentError(_ message: String) {
        errorMessage = message
        state = .failed(message)
        isPresented = true
        isMinimized = false
    }

    func confirmSummariesOnly() {
        requiresSummariesOnlyConfirmation = false
        generate()
    }

    func generate() {
        guard let context else {
            presentError(BatchPodcastError.noBatchEvidence.localizedDescription)
            return
        }
        guard !requiresSummariesOnlyConfirmation else { return }
        guard let textGenerator else {
            presentError(BatchPodcastError.providerFailure("The podcast provider is not configured.").localizedDescription)
            return
        }

        generationTask?.cancel()
        playbackController.stop()
        playbackController.clearAudioCache()
        cleanupExportURL()
        episode = nil
        progress = 0
        progressMessage = "Starting podcast generation…"
        errorMessage = nil
        state = .generating

        let provider = providerProvider?() ?? .gemini
        selectedProvider = provider
        let service = BatchPodcastService { prompt, title in
            try await textGenerator(prompt, title, provider)
        }

        generationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let generated = try await service.generateEpisode(from: context) { [weak self] update in
                    self?.apply(update)
                }
                try Task.checkCancellation()
                guard self.context?.sourceDigest == context.sourceDigest else {
                    throw BatchPodcastError.digestMismatch
                }
                self.episode = generated
                self.progress = 1
                self.progressMessage = BatchPodcastProgress.ready.message
                self.state = .ready
            } catch is CancellationError {
                guard !Task.isCancelled else { return }
                self.state = .idle
            } catch {
                guard !Task.isCancelled else { return }
                self.errorMessage = error.localizedDescription
                self.state = .failed(error.localizedDescription)
            }
            self.generationTask = nil
        }
    }

    func cancelGeneration() {
        generationTask?.cancel()
        generationTask = nil
        if state == .generating {
            state = .idle
            progressMessage = "Generation cancelled"
        }
    }

    func play() {
        guard let episode else { return }
        playbackController.play(
            episode: episode,
            hostAVoice: hostAVoice,
            hostBVoice: hostBVoice,
            speed: speed
        )
    }

    func pause() { playbackController.pause() }
    func resume() { playbackController.resume() }
    func stopPlayback() { playbackController.stop() }

    func minimize() {
        guard isPresented else { return }
        isPresented = false
        isMinimized = true
    }

    func restore() {
        guard isMinimized else { return }
        isMinimized = false
        isPresented = true
    }

    func close() {
        generationTask?.cancel()
        generationTask = nil
        exportTask?.cancel()
        exportTask = nil
        playbackController.stop()
        playbackController.clearAudioCache()
        cleanupExportURL()
        context = nil
        episode = nil
        errorMessage = nil
        progress = 0
        progressMessage = ""
        selectedProvider = nil
        state = .idle
        isPresented = false
        isMinimized = false
    }

    func invalidate() {
        close()
    }

    func exportPodcast() {
        guard let episode else { return }
        guard exportTask == nil else { return }

        playbackController.stop()
        state = .saving
        errorMessage = nil
        progress = 0
        progressMessage = "Preparing WAV export…"
        let voiceA = hostAVoice
        let voiceB = hostBVoice
        let speed = self.speed
        let episodeDigest = episode.sourceDigest

        exportTask = Task { [weak self] in
            guard let self else { return }
            do {
                let url = try await self.playbackController.renderEpisodeForExport(
                    episode,
                    hostAVoice: voiceA,
                    hostBVoice: voiceB,
                    speed: speed,
                    progressHandler: { [weak self] completed, total in
                        self?.progress = total > 0 ? Double(completed) / Double(total) : 0
                        self?.progressMessage = "Preparing WAV export \(completed) of \(total)…"
                    }
                )
                guard self.context?.sourceDigest == episodeDigest else {
                    try? FileManager.default.removeItem(at: url)
                    throw BatchPodcastError.digestMismatch
                }
                self.exportURL = url
                self.progress = 1
                self.progressMessage = "Choose where to save the WAV file."
                self.state = .ready
            } catch is CancellationError {
                self.state = .ready
                self.progressMessage = "WAV export cancelled"
            } catch {
                self.errorMessage = error.localizedDescription
                self.state = .failed(error.localizedDescription)
            }
            self.exportTask = nil
        }
    }

    func finishExport() {
        cleanupExportURL()
    }

    private func apply(_ progress: BatchPodcastProgress) {
        progressMessage = progress.message
        switch progress {
        case let .analyzingChunk(current, total):
            self.progress = total > 0 ? Double(current) / Double(total) * 0.65 : 0
        case .mergingEvidence: self.progress = max(self.progress, 0.68)
        case .outlining: self.progress = max(self.progress, 0.76)
        case .writingScript: self.progress = max(self.progress, 0.84)
        case .repairingJSON: self.progress = max(self.progress, 0.9)
        case .validating: self.progress = max(self.progress, 0.96)
        case .ready: self.progress = 1
        }
    }

    private func cleanupExportURL() {
        guard let exportURL else { return }
        try? FileManager.default.removeItem(at: exportURL)
        let directory = exportURL.deletingLastPathComponent()
        if directory.path.hasPrefix(FileManager.default.temporaryDirectory.path) {
            try? FileManager.default.removeItem(at: directory)
        }
        self.exportURL = nil
    }
}
