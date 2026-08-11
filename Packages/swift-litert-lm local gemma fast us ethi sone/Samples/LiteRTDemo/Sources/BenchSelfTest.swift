// LiteRTDemo — text decode benchmark probe.
//
// Measures text decode speed the way a real chat app experiences it: one warm
// engine, several short-chat turns in a row, reading LiteRT-LM's own per-turn
// counters (getBenchmarkInfo). The first turn is COLD (GPU shaders / weight
// conversion not yet warmed) and runs ~2× slower; from the second turn on the
// engine is at steady state. This is what explains "33 vs 55 tok/s".
//
// Mirrors the reference setup (ios-llm-benchmark): EngineConfig(.gpu,
// maxNumTokens: 2048) + a SamplerConfig on the conversation (the sampler is also
// what keeps benchmark mode from crashing in `output_buffer_dup`).
//
// Launch with LITERT_BENCH=1. Lines are tagged "BENCH:" for devicectl polling.

import Foundation
import LiteRTFoundation
import os

enum BenchSelfTest {
  private static let logger = Logger(subsystem: "com.example.litertdemo", category: "BENCH")

  static var isRequested: Bool { ProcessInfo.processInfo.environment["LITERT_BENCH"] != nil }

  static func log(_ message: String) {
    logger.log("\(message, privacy: .public)")
    print("BENCH: \(message)")
    fflush(stdout)
  }

  private static func mb(_ bytes: Int64) -> String {
    String(format: "%.0f MB", Double(bytes) / 1_048_576)
  }

  static func run() async {
    log("start — device=\(ProcessInfo.processInfo.operatingSystemVersionString)")

    let model = LiteRTModel.gemma4_E2B
    let path: String
    do {
      path = try await LiteRTChat.ensureModel(model)
    } catch {
      log("FATAL could not obtain model: \(error.localizedDescription)")
      log("DONE")
      return
    }

    // One warm engine, several short-chat turns. The reference benchmark + the
    // Gemma 4 E2B model card both report ~55–56 tok/s decode on iPhone 17 Pro;
    // that's the *warm* steady state, reached from the 2nd turn onward.
    ExperimentalFlags.optIntoExperimentalAPIs()
    ExperimentalFlags.enableBenchmark = true
    let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
    let prompt = "Explain what on-device AI means in simple terms."

    do {
      let config = try EngineConfig(
        modelPath: path, backend: .gpu, maxNumTokens: 2048, cacheDir: caches?.path)
      let engine = Engine(engineConfig: config)
      let initStart = Date()
      try await engine.initialize()
      log(String(format: "engine init %.1fs · %@", Date().timeIntervalSince(initStart),
        mb(LiteRTChat.memoryFootprintBytes())))

      // topK 40 / temperature 0 ≈ greedy, but a non-nil SamplerConfig is what
      // keeps benchmark mode from crashing (output_buffer_dup) on this build.
      let sampler = try SamplerConfig(topK: 40, topP: 0.95, temperature: 0.0)

      for turn in 1...4 {
        let conv = try await engine.createConversation(
          with: ConversationConfig(samplerConfig: sampler))
        for try await _ in conv.sendMessageStream(Message(prompt)) {}
        let b = try conv.getBenchmarkInfo()
        log(String(
          format: "turn %d (%@): decode %.1f tok/s · %d tok · prefill %.1f tok/s · ttft %.2fs · %@",
          turn, turn == 1 ? "cold" : "warm", b.lastDecodeTokensPerSecond,
          b.lastDecodeTokenCount, b.lastPrefillTokensPerSecond, b.timeToFirstTokenInSecond,
          mb(LiteRTChat.memoryFootprintBytes())))
      }
    } catch {
      log("FAILED: \(error.localizedDescription)")
    }

    // Product-API check: does LiteRTChat's prewarm make the *first* message warm?
    for pw in [false, true] {
      do {
        let chat = try await LiteRTChat(
          model, modalities: [] as Modality, enableBenchmark: true, prewarm: pw)
        _ = try await chat.respond(prompt)  // the user's first real message
        let b = try chat.lastBenchmark()
        log(String(format: "LiteRTChat prewarm=%@: first-message decode %.1f tok/s · ttft %.2fs",
          pw ? "ON " : "off", b.lastDecodeTokensPerSecond, b.timeToFirstTokenInSecond))
        try? await Task.sleep(nanoseconds: 800_000_000)
      } catch {
        log("LiteRTChat prewarm=\(pw) FAILED: \(error.localizedDescription)")
      }
    }

    log("DONE")
  }
}
