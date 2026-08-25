// LiteRTDemo — G1 headless self-test (Foundation Models custom backend).
//
// The G1 gate: does Apple's `LanguageModelSession` actually drive a *non-Apple*
// executor (LiteRT-LM) end-to-end? We build `LiteRTLanguageModel`, wrap it in a
// stock `LanguageModelSession(model:)`, and generate via the exact Foundation
// Models API — `respond(to:)` and `streamResponse(to:)`. If text comes back,
// LiteRT is a working FM backend.
//
// Launch with LITERT_G1_TEST=1. Lines are tagged "G1:" for devicectl polling.

#if canImport(FoundationModels)

import Foundation
import FoundationModels
import LiteRTFoundation
import os

@available(iOS 27.0, macOS 27.0, *)
enum G1SelfTest {
  private static let logger = Logger(subsystem: "com.example.litertdemo", category: "G1")

  static var isRequested: Bool { ProcessInfo.processInfo.environment["LITERT_G1_TEST"] != nil }

  static func log(_ message: String) {
    logger.log("\(message, privacy: .public)")
    print("G1: \(message)")
    fflush(stdout)
  }

  static func run() async {
    log("start — Foundation Models custom-backend gate")
    do {
      let model = try await LiteRTLanguageModel(.gemma4_E2B)
      log("LiteRTLanguageModel(.gemma4_E2B) created")

      let session = LanguageModelSession(model: model)
      log("LanguageModelSession(model:) created — driving a non-Apple executor")

      // 1) Non-streaming respond — the definitive gate.
      let start = Date()
      let response = try await session.respond(to: "Explain on-device AI in one sentence.")
      let oneLine = response.content.replacingOccurrences(of: "\n", with: " ")
      log(String(format: "respond() in %.1fs → %@", Date().timeIntervalSince(start), oneLine))

      // 2) Streaming via the FM ResponseStream.
      var last = ""
      for try await snapshot in session.streamResponse(to: "Name three primary colors.") {
        last = snapshot.content
      }
      log("streamResponse() final → \(last.replacingOccurrences(of: "\n", with: " "))")

      log("PASS — LiteRT-LM drives the Foundation Models API")
    } catch {
      log("FAILED: \(error.localizedDescription)")
    }
    log("DONE")
  }
}

#endif
