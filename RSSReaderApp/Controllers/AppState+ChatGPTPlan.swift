//
//  AppState+ChatGPTPlan.swift
//  RSSReaderApp
//
//  Request helpers for the ChatGPT Plan summary provider. They mirror the
//  Codex / Summarize helpers so every feature routes ChatGPT the same way.
//

import Foundation

extension AppState {
    /// One ChatGPT Plan request, timed for the throughput label like Codex / Summarize.
    func performChatGPTRequestAsync(
        prompt: String,
        taskName: String = "ChatGPT Plan",
        isQA: Bool = false
    ) async throws -> String {
        let start = Date()
        let output = try await ChatGPTPlanService.shared.generate(prompt: prompt, onPartial: nil)
        let elapsed = Date().timeIntervalSince(start)
        recordChatGPTThroughput(text: output, elapsed: elapsed, isQA: isQA)
        print("✅ AppState: ChatGPT Plan succeeded for \(taskName)")
        return output
    }

    /// Completion-based variant matching performSummarizeSummaryPublic.
    /// Errors are returned as text, the same way the other providers report them.
    func performChatGPTSummaryPublic(
        prompt: String,
        taskName: String = "ChatGPT Plan",
        isQA: Bool = false,
        managesLoading: Bool = true,
        completion: @escaping @MainActor (String) -> Void
    ) {
        if managesLoading { isLoading = true }
        Task(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            do {
                let output = try await self.performChatGPTRequestAsync(prompt: prompt, taskName: taskName, isQA: isQA)
                await MainActor.run {
                    if managesLoading { self.isLoading = false }
                    completion(output)
                }
            } catch {
                await MainActor.run {
                    if managesLoading { self.isLoading = false }
                    completion("ChatGPT Plan error: \(error.localizedDescription)")
                }
            }
        }
    }

    func recordChatGPTThroughput(text: String, elapsed: TimeInterval, isQA: Bool = false) {
        guard elapsed > 0 else { return }
        let estimatedTokens = max(1, Int(Double(text.split(separator: " ").count) * 1.3))
        let tokPerSec = Double(estimatedTokens) / elapsed
        let label = String(format: "ChatGPT Plan · ~%.1f tok/s · ~%d tokens", tokPerSec, estimatedTokens)
        if isQA {
            mlxLastQAThroughput = label
        } else {
            mlxLastThroughput = label
        }
    }
}
