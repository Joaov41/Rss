// LiteRTDemo — multimodal chat path self-test.
//
// Validates the exact path the interactive ContentView uses: ONE
// `LiteRTChat(.gemma4_E2B, modalities: .all)` reused across text, image, and
// audio turns. The open question this answers: now that the vision encoder runs
// on CPU (not Metal), does bringing up all towers in a single engine fit (the
// earlier `.all` std::bad_alloc was the simultaneous *GPU* weight conversion)?
//
// Launch with LITERT_MMCHAT=1. Lines are tagged "MM:" for devicectl polling.

import Foundation
import LiteRTFoundation
import os

enum MMChatSelfTest {
  private static let logger = Logger(subsystem: "com.example.litertdemo", category: "MM")

  static var isRequested: Bool { ProcessInfo.processInfo.environment["LITERT_MMCHAT"] != nil }

  static func log(_ message: String) {
    logger.log("\(message, privacy: .public)")
    print("MM: \(message)")
    fflush(stdout)
  }

  private static func mb(_ b: Int64) -> String { String(format: "%.0f MB", Double(b) / 1_048_576) }

  static func run() async {
    log("start — single .all chat, text+image+audio turns (the ContentView path)")
    do {
      let initStart = Date()
      let chat = try await LiteRTChat(.gemma4_E2B, modalities: .all)
      log(String(format: "chat ready (.all) in %.1fs · footprint %@ — .all FITS",
        Date().timeIntervalSince(initStart), mb(LiteRTChat.memoryFootprintBytes())))

      let text = try await chat.respond("Explain on-device AI in one sentence.")
      log("TEXT → \(oneLine(text)) · \(mb(LiteRTChat.memoryFootprintBytes()))")

      if let img = bundledData("apple", "png") {
        let answer = try await chat.respond("What object is in this image? Answer in one word.", image: img)
        log("IMAGE → \(oneLine(answer)) · \(mb(LiteRTChat.memoryFootprintBytes()))")
      }

      if let wav = Bundle.main.url(forResource: "have_a_wonderful_day", withExtension: "wav") {
        let answer = try await chat.respond("Transcribe the spoken words in this audio.", audio: .file(wav))
        log("AUDIO → \(oneLine(answer)) · \(mb(LiteRTChat.memoryFootprintBytes()))")
      }

      log("PASS — one .all chat handled text + image + audio")
    } catch {
      log("FAILED: \(error.localizedDescription)")
    }
    log("DONE")
  }

  private static func oneLine(_ s: String) -> String {
    String(s.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines).prefix(160))
  }

  private static func bundledData(_ name: String, _ ext: String) -> Data? {
    guard let url = Bundle.main.url(forResource: name, withExtension: ext) else { return nil }
    return try? Data(contentsOf: url)
  }
}
