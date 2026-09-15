//
//  PodcastEpisodePlayerView.swift
//  RSSReaderApp
//


#if os(iOS)
import SwiftUI

struct PodcastEpisodePlayerView: View {
    let article: Article
    @ObservedObject var player: PodcastEpisodePlayerController

    @State private var scrubPosition: Double = 0
    @State private var isScrubbing = false

    private let availableRates: [Float] = [0.75, 1, 1.25, 1.5, 2]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center, spacing: 16) {
                artwork

                VStack(alignment: .leading, spacing: 5) {
                    Label("Podcast episode", systemImage: "waveform")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)

                    Text(article.feedTitle)
                        .font(.headline)
                        .lineLimit(2)

                    if let author = article.author,
                       !author.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(author)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 0)
            }

            VStack(spacing: 8) {
                Slider(
                    value: $scrubPosition,
                    in: 0...max(player.duration, 1),
                    onEditingChanged: { editing in
                        isScrubbing = editing
                        if !editing { player.seek(to: scrubPosition) }
                    }
                )
                .accessibilityLabel("Episode position")
                .accessibilityValue("\(timeLabel(scrubPosition)) of \(timeLabel(player.duration))")

                HStack {
                    Text(timeLabel(scrubPosition))
                    Spacer()
                    Text(player.duration > 0 ? timeLabel(player.duration) : "Loading…")
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }

            HStack(spacing: 26) {
                Spacer()

                Button { player.skip(by: -15) } label: {
                    Image(systemName: "gobackward.15")
                        .font(.title2)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Go back 15 seconds")

                Button { player.togglePlayback() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(width: 58, height: 58)
                        .background(Circle().fill(Color.accentColor))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(player.isPlaying ? "Pause episode" : "Play episode")

                Button { player.skip(by: 15) } label: {
                    Image(systemName: "goforward.15")
                        .font(.title2)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Go forward 15 seconds")

                Spacer()
            }

            HStack {
                Label("Background playback", systemImage: "lock.open")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                Menu {
                    ForEach(availableRates, id: \.self) { rate in
                        Button {
                            player.setPlaybackRate(rate)
                        } label: {
                            if rate == player.playbackRate {
                                Label(rateLabel(rate), systemImage: "checkmark")
                            } else {
                                Text(rateLabel(rate))
                            }
                        }
                    }
                } label: {
                    Label(rateLabel(player.playbackRate), systemImage: "speedometer")
                        .font(.callout.weight(.medium))
                }
            }

            if let errorMessage = player.errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
        }
        .padding(18)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        }
        .onAppear {
            player.prepare(article)
            scrubPosition = player.currentTime
        }
        .onChange(of: article.id) { _, _ in
            player.prepare(article)
            scrubPosition = player.currentTime
        }
        .onChange(of: player.currentTime) { _, newValue in
            if !isScrubbing { scrubPosition = newValue }
        }
    }

    @ViewBuilder
    private var artwork: some View {
        if let imageURL = article.imageURL {
            AsyncImage(url: imageURL) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFill()
                } else {
                    artworkPlaceholder
                }
            }
            .frame(width: 76, height: 76)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        } else {
            artworkPlaceholder
                .frame(width: 76, height: 76)
        }
    }

    private var artworkPlaceholder: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(Color.accentColor.opacity(0.16))
            .overlay {
                Image(systemName: "mic.fill")
                    .font(.title)
                    .foregroundStyle(Color.accentColor)
            }
    }

    private func timeLabel(_ value: TimeInterval) -> String {
        guard value.isFinite else { return "0:00" }
        let total = max(0, Int(value.rounded(.down)))
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        let seconds = total % 60
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, seconds) }
        return String(format: "%d:%02d", minutes, seconds)
    }

    private func rateLabel(_ rate: Float) -> String {
        rate == rate.rounded() ? "\(Int(rate))×" : "\(rate.formatted(.number.precision(.fractionLength(2))))×"
    }
}

struct PodcastEpisodeMiniPlayer: View {
    @ObservedObject var player: PodcastEpisodePlayerController
    let onOpenEpisode: () -> Void

    @ViewBuilder
    var body: some View {
        if #available(iOS 26.0, *) {
            playerContent
                .glassEffect(
                    .regular
                        .tint(Color(red: 0.24, green: 0.42, blue: 0.62).opacity(0.16))
                        .interactive(),
                    in: RoundedRectangle(cornerRadius: 20, style: .continuous)
                )
                .shadow(color: .black.opacity(0.24), radius: 16, y: 7)
        } else {
            playerContent
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(Color.primary.opacity(0.10), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.24), radius: 16, y: 7)
        }
    }

    private var playerContent: some View {
        HStack(spacing: 12) {
            Button(action: onOpenEpisode) {
                artwork
            }
            .buttonStyle(.plain)
            .help("Open podcast episode")
            .accessibilityLabel("Open currently playing podcast episode")

            VStack(alignment: .leading, spacing: 4) {
                Text(player.activeEpisodeTitle)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)

                Text(player.activeShowTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                ProgressView(
                    value: min(max(player.currentTime, 0), max(player.duration, 1)),
                    total: max(player.duration, 1)
                )
                .progressViewStyle(.linear)
                .accessibilityLabel("Episode progress")
            }

            Button {
                player.togglePlayback()
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.headline)
                    .frame(width: 40, height: 40)
                    .background(Color.accentColor, in: Circle())
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(player.isPlaying ? "Pause episode" : "Resume episode")

            Button(role: .destructive) {
                player.stop()
            } label: {
                Image(systemName: "stop.fill")
                    .font(.subheadline.weight(.semibold))
                    .frame(width: 36, height: 36)
                    .background(Color.primary.opacity(0.08), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Stop episode and close player")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(maxWidth: 620)
    }

    @ViewBuilder
    private var artwork: some View {
        if let artworkURL = player.activeArtworkURL {
            AsyncImage(url: artworkURL) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFill()
                } else {
                    artworkPlaceholder
                }
            }
            .frame(width: 46, height: 46)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        } else {
            artworkPlaceholder
                .frame(width: 46, height: 46)
        }
    }

    private var artworkPlaceholder: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color.accentColor.opacity(0.16))
            .overlay {
                Image(systemName: "waveform")
                    .foregroundStyle(Color.accentColor)
            }
    }
}

struct PodcastTranscriptStatusView: View {
    let availability: PodcastTranscriptAvailability?
    let activityMessage: String?

    var body: some View {
        if let activityMessage {
            Label(activityMessage, systemImage: "captions.bubble")
                .font(.callout)
                .foregroundStyle(activityIsError ? Color.orange : Color.secondary)
        } else {
            switch availability ?? .checking {
            case .checking:
                Label("Checking transcript availability…", systemImage: "ellipsis.bubble")
                    .foregroundStyle(.secondary)
            case .publisherAvailable:
                Label("Publisher transcript available", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .generatedAvailable:
                Label("Private on-device transcript ready", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .generationRequired:
                Label(
                    "No publisher transcript — one will be created privately on-device when needed",
                    systemImage: "iphone.and.arrow.forward"
                )
                .foregroundStyle(.secondary)
            case .checkUnavailable:
                Label(
                    "Couldn’t check the publisher transcript — the app will retry and use on-device transcription if needed",
                    systemImage: "exclamationmark.bubble"
                )
                .foregroundStyle(.orange)
            }
        }
    }

    private var activityIsError: Bool {
        guard let activityMessage else { return false }
        let normalized = activityMessage.lowercased()
        return normalized.contains("could not")
            || normalized.contains("couldn’t")
            || normalized.contains("failed")
            || normalized.contains("stopped")
            || normalized.contains("unavailable")
    }
}
#endif
