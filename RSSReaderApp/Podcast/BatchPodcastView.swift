import SwiftUI
import UIKit

struct BatchPodcastGlassModifier<S: Shape>: ViewModifier {
    let shape: S
    var isClear = false

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(isClear ? .clear : .regular.interactive(), in: shape)
        } else {
            content
                .background(.ultraThinMaterial, in: shape)
                .overlay(
                    shape.stroke(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.25),
                                Color.white.opacity(0.05)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.5
                    )
                )
        }
    }
}

extension View {
    func batchPodcastGlass<S: Shape>(in shape: S) -> some View {
        modifier(BatchPodcastGlassModifier(shape: shape))
    }

    func batchPodcastClearGlass<S: Shape>(in shape: S) -> some View {
        modifier(BatchPodcastGlassModifier(shape: shape, isClear: true))
    }
}

struct BatchPodcastGlassButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .batchPodcastGlass(in: Capsule())
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
    }
}

struct BatchPodcastPresentationHost: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var session: BatchPodcastSession

    var body: some View {
        Color.clear
            .ignoresSafeArea()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .fullScreenCover(
                isPresented: Binding(
                    get: { session.isPresented },
                    set: { isPresented in
                        if !isPresented, session.isPresented { session.minimize() }
                    }
                )
            ) {
                BatchPodcastView(session: session)
                    .environmentObject(appState)
            }
            .overlay(alignment: .bottomTrailing) {
                if session.isMinimized {
                    Button {
                        session.restore()
                    } label: {
                        Label("Podcast", systemImage: "waveform.badge.mic")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                    }
                    .buttonStyle(.plain)
                    .batchPodcastGlass(in: Capsule())
                    .accessibilityLabel("Restore podcast")
                    .help("Restore podcast")
                    .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
                    .padding(.trailing, 16)
                    .padding(.bottom, 96)
                }
            }
    }
}

struct BatchPodcastView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var session: BatchPodcastSession
    @ObservedObject private var playbackController: MLXPodcastPlaybackController

    init(session: BatchPodcastSession) {
        self.session = session
        _playbackController = ObservedObject(wrappedValue: session.playbackController)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                podcastBackground

                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        header
                        sourceSummary
                        hostControls
                        generationControls

                        if let episode = session.episode {
                            episodePreview(episode)
                            playbackControls(episode)
                        } else if session.state == .idle {
                            ContentUnavailableView(
                                "No Script Yet",
                                systemImage: "text.badge.plus",
                                description: Text("Generate a grounded two-host script from this saved Batch Summary.")
                            )
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 28)
                        }

                        if let error = session.errorMessage {
                            errorBanner(error)
                        }

                        if let playbackError = playbackController.errorMessage {
                            errorBanner("Playback: \(playbackError)")
                        }
                    }
                    .padding(20)
                    .frame(maxWidth: 760)
                    .frame(maxWidth: .infinity)
                }
            }
            .navigationTitle("Batch Podcast")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        session.minimize()
                    } label: {
                        Label("Minimize", systemImage: "minus.circle")
                    }
                    .buttonStyle(BatchPodcastGlassButtonStyle())
                    .accessibilityLabel("Minimize podcast")
                    .help("Keep the podcast working while you use the app")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Close") {
                        session.close()
                    }
                    .buttonStyle(BatchPodcastGlassButtonStyle())
                }
            }
            .toolbarBackground(.hidden, for: .navigationBar)
        }
        .overlay(alignment: .bottomTrailing) {
            if session.state == .saving {
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Creating file…")
                        .font(.subheadline.weight(.semibold))
                }
                .foregroundStyle(.primary)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .batchPodcastClearGlass(in: Capsule())
                .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
                .padding(20)
                .transition(.move(edge: .trailing).combined(with: .opacity))
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Creating podcast file")
            }
        }
        .animation(.easeInOut(duration: 0.2), value: session.state == .saving)
        .sheet(
            isPresented: Binding(
                get: { session.exportURL != nil },
                set: { isPresented in
                    if !isPresented { session.finishExport() }
                }
            )
        ) {
            if let url = session.exportURL {
                BatchPodcastFileExporter(url: url) {
                    session.finishExport()
                }
                .ignoresSafeArea()
            }
        }
    }

    private var podcastBackground: some View {
        ZStack {
            LinearGradient(
                colors: colorScheme == .dark
                    ? [
                        Color(red: 0.055, green: 0.058, blue: 0.095),
                        Color(red: 0.025, green: 0.026, blue: 0.047)
                    ]
                    : [
                        Color(red: 0.985, green: 0.988, blue: 1.0),
                        Color(red: 0.925, green: 0.940, blue: 0.975)
                    ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            RadialGradient(
                colors: [
                    Color.blue.opacity(colorScheme == .dark ? 0.22 : 0.10),
                    Color.blue.opacity(0)
                ],
                center: .topLeading,
                startRadius: 20,
                endRadius: 780
            )

            LinearGradient(
                colors: [
                    Color.white.opacity(colorScheme == .dark ? 0.07 : 0.42),
                    Color.clear,
                    Color.black.opacity(colorScheme == .dark ? 0.12 : 0.02)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Grounded in this saved batch", systemImage: "waveform.badge.mic")
                .font(.title2.weight(.semibold))
            Text("The podcast uses the evidence already captured for the current Batch Summary. Creating it does not fetch Reddit or feed data again.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var sourceSummary: some View {
        HStack(spacing: 14) {
            Label("\(session.context?.sources.count ?? 0) sources", systemImage: "doc.text")
            Label("\(session.context?.evidenceChunks.count ?? 0) evidence chunks", systemImage: "text.bubble")
            if session.context?.isSummariesOnly == true {
                Label("Summaries only", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }

    private var hostControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Hosts").font(.headline)
            HStack {
                Picker("Host A voice", selection: $session.hostAVoice) {
                    ForEach(KokoroVoice.allCases) { voice in
                        Text(voice.displayName).tag(voice)
                    }
                }
                .pickerStyle(.menu)

                Picker("Host B voice", selection: $session.hostBVoice) {
                    ForEach(KokoroVoice.allCases) { voice in
                        Text(voice.displayName).tag(voice)
                    }
                }
                .pickerStyle(.menu)
            }
            .accessibilityElement(children: .contain)

            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text("Speed")
                    Spacer()
                    Text(String(format: "%.1fx", session.speed))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Slider(value: $session.speed, in: 0.7...1.4, step: 0.05)
                    .accessibilityLabel("Podcast speed")
            }
            Text("Voice choices apply to this episode only; global MLX settings stay unchanged.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    @ViewBuilder
    private var generationControls: some View {
        if session.requiresSummariesOnlyConfirmation {
            VStack(alignment: .leading, spacing: 10) {
                Label("No saved raw comments are available for this batch.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("This optional episode will use the saved summaries only and may miss discussion details.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button {
                    session.confirmSummariesOnly()
                } label: {
                    Label("Generate summaries-only podcast", systemImage: "sparkles")
                }
                .buttonStyle(BatchPodcastGlassButtonStyle())
            }
            .padding(14)
            .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
        } else {
            HStack(spacing: 10) {
                Button {
                    session.generate()
                } label: {
                    Label(session.episode == nil ? "Generate Script" : "Regenerate Script", systemImage: "sparkles")
                }
                .buttonStyle(BatchPodcastGlassButtonStyle())
                .disabled(session.state == .generating || session.state == .saving)

                if session.state == .generating {
                    Button("Cancel") { session.cancelGeneration() }
                        .buttonStyle(BatchPodcastGlassButtonStyle())
                }
            }
        }

        if session.state == .generating || session.state == .saving {
            VStack(alignment: .leading, spacing: 7) {
                ProgressView(value: session.progress)
                HStack {
                    Text(session.progressMessage)
                    Spacer()
                    Text("\(Int(session.progress * 100))%")
                        .monospacedDigit()
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    private func episodePreview(_ episode: PodcastEpisode) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(episode.title)
                .font(.title3.weight(.semibold))
            if !episode.summary.isEmpty {
                Text(episode.summary)
                    .foregroundStyle(.secondary)
            }
            Text("\(episode.spokenWordCount) spoken words · about \(Int(episode.estimatedDuration / 60.0 + 0.5)) minutes")
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(Array(episode.turns.enumerated()), id: \.element.id) { _, turn in
                VStack(alignment: .leading, spacing: 5) {
                    Text(turn.speaker.displayName)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(turn.speaker == .hostA ? .blue : .orange)
                    Text(turn.text)
                        .textSelection(.enabled)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    private func playbackControls(_ episode: PodcastEpisode) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                if playbackController.state == .playing {
                    Button { session.pause() } label: {
                        Label("Pause", systemImage: "pause.fill")
                    }
                    .buttonStyle(BatchPodcastGlassButtonStyle())
                } else if playbackController.state == .paused {
                    Button { session.resume() } label: {
                        Label("Resume", systemImage: "play.fill")
                    }
                    .buttonStyle(BatchPodcastGlassButtonStyle())
                } else if playbackController.state == .preparing {
                    Button {} label: {
                        Label("Preparing Audio", systemImage: "waveform.badge.magnifyingglass")
                    }
                    .buttonStyle(BatchPodcastGlassButtonStyle())
                    .disabled(true)
                } else {
                    Button { session.play() } label: {
                        Label("Play", systemImage: "play.fill")
                    }
                    .buttonStyle(BatchPodcastGlassButtonStyle())
                }

                Button { session.stopPlayback() } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .buttonStyle(BatchPodcastGlassButtonStyle())
                .disabled([.idle, .finished].contains(playbackController.state))

                Spacer()

                Button {
                    session.exportPodcast()
                } label: {
                    Label("Save Podcast", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(BatchPodcastGlassButtonStyle())
                .disabled(session.state == .saving || playbackController.state == .preparing || playbackController.state == .saving)
                .accessibilityLabel("Save podcast as WAV")
            }

            ProgressView(value: playbackController.progress)
            Text(playbackController.statusMessage.isEmpty ? "Ready to play" : playbackController.statusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
        .onChange(of: episode.id) { _ in session.stopPlayback() }
    }

    private func errorBanner(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.red)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct BatchPodcastFileExporter: UIViewControllerRepresentable {
    let url: URL
    let onFinish: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onFinish: onFinish)
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onFinish: () -> Void

        init(onFinish: @escaping () -> Void) {
            self.onFinish = onFinish
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            onFinish()
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onFinish()
        }
    }
}
