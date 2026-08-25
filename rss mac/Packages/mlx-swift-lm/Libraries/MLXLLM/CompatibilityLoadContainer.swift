// Copyright © 2026

import Foundation
import MLXLMCommon

extension LLMModelFactory {
    public func loadContainer(
        from downloader: any MLXLMCommon.Downloader,
        using _: any MLXLMCommon.TokenizerLoader,
        configuration: ModelConfiguration,
        progressHandler: @Sendable @escaping (Progress) -> Void = { _ in }
    ) async throws -> ModelContainer {
        let directory: URL
        switch configuration.id {
        case .id(let id, let revision):
            directory = try await downloader.download(
                id: id,
                revision: revision,
                matching: ["*.safetensors", "*.json", "*.model", "*.txt", "*.tiktoken"],
                useLatest: true,
                progressHandler: progressHandler
            )
        case .directory(let url):
            directory = url
        }

        return try await loadContainer(
            hub: defaultHubApi,
            configuration: ModelConfiguration(
                directory: directory,
                tokenizerId: configuration.tokenizerId,
                overrideTokenizer: configuration.overrideTokenizer,
                defaultPrompt: configuration.defaultPrompt,
                extraEOSTokens: configuration.extraEOSTokens
            ),
            progressHandler: progressHandler
        )
    }

    public func loadContainer(
        from directory: URL,
        using _: any MLXLMCommon.TokenizerLoader
    ) async throws -> ModelContainer {
        try await loadContainer(
            hub: defaultHubApi,
            configuration: ModelConfiguration(directory: directory)
        )
    }
}
