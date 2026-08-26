import SwiftUI

struct PodcastSearchView: View {
    private enum SearchPhase {
        case idle
        case loading
        case results([PodcastSearchResult])
        case failed(String)
    }

    @EnvironmentObject private var appState: AppState

    @State private var query = ""
    @State private var phase: SearchPhase = .idle
    @State private var subscriptionError: String?

    private var normalizedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        Group {
            TextField("Search podcasts or creators", text: $query)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Search podcasts by show or creator name")

            switch phase {
            case .idle:
                Label("Type at least two characters to find a podcast.", systemImage: "magnifyingglass")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

            case .loading:
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Searching podcasts…")
                        .foregroundStyle(.secondary)
                }

            case .results(let podcasts) where podcasts.isEmpty:
                Label("No podcasts found for “\(normalizedQuery)”.", systemImage: "waveform.slash")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

            case .results(let podcasts):
                ForEach(podcasts) { podcast in
                    PodcastSearchResultRow(
                        podcast: podcast,
                        isSubscribed: appState.isSubscribed(toPodcastFeedURL: podcast.feedURL),
                        subscribe: { subscribe(to: podcast) }
                    )
                }

            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline)
                    .foregroundStyle(.red)
            }

            if let subscriptionError {
                Label(subscriptionError, systemImage: "exclamationmark.circle.fill")
                    .font(.subheadline)
                    .foregroundStyle(.red)
            }
        }
        .task(id: normalizedQuery) {
            await search(normalizedQuery)
        }
    }

    private func search(_ searchTerm: String) async {
        subscriptionError = nil
        guard searchTerm.count >= 2 else {
            phase = .idle
            return
        }

        do {
            try await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            phase = .loading
            let results = try await appState.searchPodcasts(searchTerm)
            guard !Task.isCancelled else { return }
            phase = .results(results)
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            phase = .failed(error.localizedDescription)
        }
    }

    private func subscribe(to podcast: PodcastSearchResult) {
        subscriptionError = nil
        do {
            try appState.addPodcastSubscription(podcast)
        } catch {
            subscriptionError = error.localizedDescription
        }
    }
}

private struct PodcastSearchResultRow: View {
    let podcast: PodcastSearchResult
    let isSubscribed: Bool
    let subscribe: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            AsyncImage(url: podcast.artworkURL) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                default:
                    ZStack {
                        Color.secondary.opacity(0.12)
                        Image(systemName: "waveform")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(width: 58, height: 58)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(podcast.title)
                    .font(.headline)
                    .lineLimit(2)
                Text(podcast.publisher)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                if let metadata = metadataText {
                    Text(metadata)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer(minLength: 6)

            Button(action: subscribe) {
                if isSubscribed {
                    Label("Subscribed", systemImage: "checkmark")
                } else {
                    Text("Subscribe")
                }
            }
            .font(.subheadline.weight(.semibold))
            .buttonStyle(.borderedProminent)
            .tint(isSubscribed ? Color.secondary : Color.accentColor)
            .disabled(isSubscribed)
            .accessibilityLabel(isSubscribed ? "Subscribed to \(podcast.title)" : "Subscribe to \(podcast.title)")
        }
        .padding(.vertical, 4)
    }

    private var metadataText: String? {
        var parts: [String] = []
        if let genre = podcast.genre, !genre.isEmpty {
            parts.append(genre)
        }
        if let episodeCount = podcast.episodeCount, episodeCount > 0 {
            parts.append("\(episodeCount) episodes")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
