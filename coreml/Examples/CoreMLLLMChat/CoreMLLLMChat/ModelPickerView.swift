import SwiftUI

struct ModelPickerView: View {
    @State private var downloader = ModelDownloader()
    let onModelReady: (URL) -> Void

    var body: some View {
        NavigationStack {
            List {
                Section("Available Models") {
                    ForEach(downloader.availableModels) { model in
                        let _ = downloader.refreshTrigger  // Force re-evaluate on delete
                    ModelRow(
                            model: model,
                            isDownloaded: downloader.isDownloaded(model),
                            hasFiles: downloader.hasFiles(model),
                            isDownloading: downloader.isDownloading,
                            progress: downloader.progress,
                            onDownload: { downloadAndLoad(model) },
                            onLoad: {
                                if let url = downloader.localModelURL(for: model) {
                                    onModelReady(url)
                                }
                            },
                            onDelete: {
                                try? downloader.delete(model)
                                downloader.status = "Deleted \(model.name)"
                            }
                        )
                    }
                }

                if downloader.isDownloading {
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(downloader.status)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            ProgressView(value: downloader.progress)
                            Text(String(format: "%.0f%%", downloader.progress * 100))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Models")
        }
    }

    private func downloadAndLoad(_ model: ModelDownloader.ModelInfo) {
        Task {
            do {
                let url = try await downloader.download(model)
                onModelReady(url)
            } catch {
                downloader.status = "Error: \(error.localizedDescription)"
            }
        }
    }
}

struct ModelRow: View {
    let model: ModelDownloader.ModelInfo
    let isDownloaded: Bool
    let hasFiles: Bool
    let isDownloading: Bool
    let progress: Double
    let onDownload: () -> Void
    let onLoad: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(model.name)
                    .font(.headline)
                HStack(spacing: 4) {
                    Text(model.size)
                    if hasFiles && !isDownloaded {
                        Text("(incomplete)")
                            .foregroundStyle(.orange)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            if isDownloaded {
                HStack(spacing: 12) {
                    Button("Load") { onLoad() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    Button(role: .destructive) { onDelete() } label: {
                        Image(systemName: "trash")
                    }
                    .controlSize(.small)
                }
            } else {
                HStack(spacing: 8) {
                    Button("Download") { onDownload() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(isDownloading)
                    if hasFiles {
                        Button(role: .destructive) { onDelete() } label: {
                            Image(systemName: "trash")
                        }
                        .controlSize(.small)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}
