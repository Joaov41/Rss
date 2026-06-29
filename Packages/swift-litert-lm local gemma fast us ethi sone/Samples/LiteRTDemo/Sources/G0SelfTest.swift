// LiteRTDemo — G0 headless self-test
//
// The make-or-break gate: prove Gemma 4 E2B runs text → image → audio on a
// physical iPhone with the Metal GPU, and record tokens/sec + memory footprint.
//
// Launch with the environment variable LITERT_G0_TEST=1 (e.g. via
// `devicectl device process launch --environment-variables '{"LITERT_G0_TEST":"1"}'`).
// Every line is logged with the "G0:" prefix to both os_log and stdout so a
// `devicectl --console` session can be polled for results, then killed.
//
// Each modality is exercised independently and its failure is caught and logged
// rather than aborting the run — so we always learn *which* modalities work on
// device (e.g. if audio isn't ready on iOS yet, the text/image numbers still
// land).

import Foundation
import LiteRTFoundation
import os

enum G0SelfTest {
  private static let logger = Logger(subsystem: "com.example.litertdemo", category: "G0")

  static var isRequested: Bool {
    ProcessInfo.processInfo.environment["LITERT_G0_TEST"] != nil
  }

  static func log(_ message: String) {
    logger.log("\(message, privacy: .public)")
    print("G0: \(message)")
    fflush(stdout)
  }

  private static func mb(_ bytes: Int64) -> String {
    String(format: "%.0f MB", Double(bytes) / 1_048_576)
  }

  /// Run the full text → image → audio gate. Never throws; logs everything.
  static func run() async {
    log("start — device=\(deviceModel()) iOS=\(ProcessInfo.processInfo.operatingSystemVersionString)")
    log("baseline footprint \(mb(LiteRTChat.memoryFootprintBytes()))")

    let model = LiteRTModel.gemma4_E2B

    // 1) Ensure the model is on device (download on first run).
    do {
      var lastPct = -10
      let path = try await LiteRTChat.ensureModel(model) { p in
        let pct = Int(p.fraction * 100)
        if pct >= lastPct + 10 {
          lastPct = pct
          log("download \(pct)%  (\(mb(p.completedBytes)) / \(mb(p.totalBytes)))")
        }
      }
      log("model ready at \(path)")
    } catch {
      log("FATAL could not obtain model: \(error.localizedDescription)")
      log("DONE (failed)")
      return
    }

    // 2) Bring each modality up in its OWN engine, tearing it down before the
    // next. Loading text + vision + audio + the speculative drafter all at once
    // exceeds the device memory budget (std::bad_alloc during vision-encoder init
    // on the iPhone), so we isolate each tower to learn its real footprint + tok/s.
    peak = 0

    await runConfig("TEXT", modalities: [] as Modality) { chat in
      try await chat.respond("Explain quantum computing in one sentence.")
    }

    if let img = bundledData("apple", "png") {
      await runConfig("IMAGE", modalities: .vision) { chat in
        try await chat.respond("What object is in this image? Answer in one word.", image: img)
      }
    } else {
      log("IMAGE skipped — apple.png not in bundle")
    }

    if let audioURL = Bundle.main.url(forResource: "have_a_wonderful_day", withExtension: "wav") {
      await runConfig("AUDIO", modalities: .audio) { chat in
        try await chat.respond("Transcribe the spoken words in this audio.", audio: .file(audioURL))
      }
    } else {
      log("AUDIO skipped — wav not in bundle")
    }

    log("PEAK footprint \(mb(peak))")
    log("DONE")
  }

  private static var peak: Int64 = 0
  private static func notePeak() { peak = max(peak, LiteRTChat.memoryFootprintBytes()) }

  /// Bring up a fresh engine with the given modalities, run one generation, log
  /// init time + output + engine-measured tok/s + footprint, then release it.
  private static func runConfig(
    _ name: String, modalities: Modality, _ body: (LiteRTChat) async throws -> String
  ) async {
    let initStart = Date()
    do {
      let chat = try await LiteRTChat(.gemma4_E2B, modalities: modalities, enableBenchmark: true)
      let initDt = Date().timeIntervalSince(initStart)
      notePeak()
      log(String(format: "%@ engine up in %.1fs · footprint %@", name, initDt,
        mb(LiteRTChat.memoryFootprintBytes())))

      let genStart = Date()
      let output = try await body(chat)
      let wall = Date().timeIntervalSince(genStart)
      notePeak()
      let oneLine = output.replacingOccurrences(of: "\n", with: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)
      log("\(name) output: \(oneLine.prefix(200))")
      if let b = try? chat.lastBenchmark() {
        log(String(
          format: "%@ decode %.1f tok/s · prefill %.1f tok/s · ttft %.2fs · wall %.1fs · footprint %@",
          name, b.lastDecodeTokensPerSecond, b.lastPrefillTokensPerSecond,
          b.timeToFirstTokenInSecond, wall, mb(LiteRTChat.memoryFootprintBytes())))
      } else {
        log(String(format: "%@ wall %.1fs · footprint %@", name, wall, mb(LiteRTChat.memoryFootprintBytes())))
      }
    } catch {
      log("\(name) FAILED: \(error.localizedDescription)")
    }
    // `chat` is released at scope exit; give the native engine a moment to free
    // GPU memory before the next config initializes.
    try? await Task.sleep(nanoseconds: 800_000_000)
  }

  private static func bundledData(_ name: String, _ ext: String) -> Data? {
    guard let url = Bundle.main.url(forResource: name, withExtension: ext) else { return nil }
    return try? Data(contentsOf: url)
  }

  private static func deviceModel() -> String {
    var sysinfo = utsname()
    uname(&sysinfo)
    let machine = withUnsafeBytes(of: &sysinfo.machine) { raw -> String in
      let ptr = raw.baseAddress!.assumingMemoryBound(to: CChar.self)
      return String(cString: ptr)
    }
    return machine
  }
}
