//
//  AppState+OpenAICompatible.swift
//  RSSReaderApp
//
//  Request helpers and settings setters for the Custom Server summary
//  provider (oMLX, Ollama, LM Studio...). They mirror the ChatGPT Plan helpers
//  so every feature routes this provider the same way.
//

import Foundation

extension AppState {
    /// One Custom Server request, timed for the throughput label like ChatGPT Plan.
    func performOpenAICompatibleRequestAsync(
        prompt: String,
        taskName: String = OpenAICompatibleService.displayName,
        isQA: Bool = false
    ) async throws -> String {
        let start = Date()
        let output = try await OpenAICompatibleService.generate(prompt: prompt, settings: settings)
        let elapsed = Date().timeIntervalSince(start)
        recordOpenAICompatibleThroughput(text: output, elapsed: elapsed, isQA: isQA)
        print("✅ AppState: Custom Server succeeded for \(taskName)")
        return output
    }

    /// Completion-based variant matching performChatGPTSummaryPublic.
    /// Errors are returned as text, the same way the other providers report them.
    func performOpenAICompatibleSummaryPublic(
        prompt: String,
        taskName: String = OpenAICompatibleService.displayName,
        isQA: Bool = false,
        managesLoading: Bool = true,
        completion: @escaping @MainActor (String) -> Void
    ) {
        if managesLoading { isLoading = true }
        Task(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            do {
                let output = try await self.performOpenAICompatibleRequestAsync(prompt: prompt, taskName: taskName, isQA: isQA)
                await MainActor.run {
                    if managesLoading { self.isLoading = false }
                    completion(output)
                }
            } catch {
                await MainActor.run {
                    if managesLoading { self.isLoading = false }
                    completion("Custom Server error: \(error.localizedDescription)")
                }
            }
        }
    }

    func recordOpenAICompatibleThroughput(text: String, elapsed: TimeInterval, isQA: Bool = false) {
        guard elapsed > 0 else { return }
        let estimatedTokens = max(1, Int(Double(text.split(separator: " ").count) * 1.3))
        let tokPerSec = Double(estimatedTokens) / elapsed
        let model = settings.openAICompatibleModelID.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = String(format: "%@ · ~%.1f tok/s · ~%d tokens", model.isEmpty ? OpenAICompatibleService.displayName : model, tokPerSec, estimatedTokens)
        if isQA {
            mlxLastQAThroughput = label
        } else {
            mlxLastThroughput = label
        }
    }

    // MARK: - Settings

    func setOpenAICompatibleBaseURL(_ value: String) {
        var newSettings = settings
        newSettings.openAICompatibleBaseURL = value.trimmingCharacters(in: .whitespacesAndNewlines)
        updateSettings(newSettings)
    }

    func setOpenAICompatibleAPIKey(_ value: String) {
        var newSettings = settings
        newSettings.openAICompatibleAPIKey = value.trimmingCharacters(in: .whitespacesAndNewlines)
        updateSettings(newSettings)
    }

    func setOpenAICompatibleModelID(_ value: String) {
        var newSettings = settings
        newSettings.openAICompatibleModelID = value.trimmingCharacters(in: .whitespacesAndNewlines)
        updateSettings(newSettings)
    }

    func setOpenAICompatibleMaxTokens(_ value: Int) {
        var newSettings = settings
        newSettings.openAICompatibleMaxTokens = AppSettings.normalizedOpenAICompatibleMaxTokens(value)
        updateSettings(newSettings)
    }

    func setOpenAICompatibleDisableThinking(_ value: Bool) {
        var newSettings = settings
        newSettings.openAICompatibleDisableThinking = value
        updateSettings(newSettings)
    }
}
