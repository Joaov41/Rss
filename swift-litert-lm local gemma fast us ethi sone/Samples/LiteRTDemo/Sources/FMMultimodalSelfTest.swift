// LiteRTDemo — Foundation Models multimodal + guided-generation self-test.
//
// Exercises the full FM-mode consumer API over the LiteRT backend:
//   • G2 guided generation — `respond(generating:)` with a `@Generable` type
//   • audio via `LiteRTAudioSegment` in a `@PromptBuilder`
//   • video via `LiteRTVideoSegment` (frames from `VideoFrameSampler`)
//
// Launch with LITERT_FM=1. Lines are tagged "FM:" for devicectl polling.

#if canImport(FoundationModels)

import Foundation
import FoundationModels
import LiteRTFoundation
import os

@available(iOS 27.0, macOS 27.0, *)
@Generable
struct PrimaryColors {
  @Guide(description: "Exactly three additive primary colors")
  var colors: [String]
}

/// A sample Foundation Models tool the LiteRT backend can call.
/// (Qualify `FoundationModels.Tool` — LiteRT-LM also exports a `Tool` type.)
@available(iOS 27.0, macOS 27.0, *)
struct TemperatureTool: FoundationModels.Tool {
  let name = "get_temperature"
  let description = "Get the current temperature for a city."

  @Generable
  struct Arguments {
    @Guide(description: "The city name")
    var city: String
  }

  func call(arguments: Arguments) async throws -> String {
    "The temperature in \(arguments.city) is 22°C and sunny."
  }
}

@available(iOS 27.0, macOS 27.0, *)
enum FMMultimodalSelfTest {
  private static let logger = Logger(subsystem: "com.example.litertdemo", category: "FM")

  static var isRequested: Bool { ProcessInfo.processInfo.environment["LITERT_FM"] != nil }

  static func log(_ message: String) {
    logger.log("\(message, privacy: .public)")
    print("FM: \(message)")
    fflush(stdout)
  }

  static func run() async {
    log("start — guided + audio + video over the Foundation Models API")

    let model: LiteRTLanguageModel
    let session: LanguageModelSession
    do {
      model = try await LiteRTLanguageModel(.gemma4_E2B)
      session = LanguageModelSession(model: model)
      log("session ready (LiteRT backend)")
    } catch {
      log("FATAL setup: \(error.localizedDescription)")
      log("DONE")
      return
    }

    // Each modality is independent so one failure doesn't mask the others.

    // Audio understanding through the FM API (custom segment) — the world-first.
    if let wav = Bundle.main.url(forResource: "have_a_wonderful_day", withExtension: "wav") {
      do {
        let data = try Data(contentsOf: wav)
        let answer = try await session.respond {
          LiteRTAudioSegment(data: data)
          "Listen to this audio and reply to what is said."
        }
        log("AUDIO(FM reply) → \(answer.content.replacingOccurrences(of: "\n", with: " "))")
      } catch {
        log("AUDIO(FM) FAILED: \(error.localizedDescription)")
      }
    }

    // Audio understanding can also answer a spoken question.
    if let q = Bundle.main.url(forResource: "question", withExtension: "wav"),
      let data = try? Data(contentsOf: q) {
      do {
        let answer = try await session.respond {
          LiteRTAudioSegment(data: data)
          "Answer the question that is asked in this audio."
        }
        log("AUDIO(Q&A) → \(answer.content.replacingOccurrences(of: "\n", with: " "))")
      } catch {
        log("AUDIO(Q&A) FAILED: \(error.localizedDescription)")
      }
    }

    // G2 — guided generation into a @Generable type.
    do {
      let guided = try await session.respond(generating: PrimaryColors.self) {
        "List the three additive primary colors."
      }
      log("GUIDED → colors = \(guided.content.colors)")
    } catch {
      log("GUIDED FAILED: \(error.localizedDescription)")
    }

    // Tool calling through the FM API (the model calls the app's tool; FM runs
    // it and feeds the result back).
    do {
      let toolSession = LanguageModelSession(model: model, tools: [TemperatureTool()])
      let answer = try await toolSession.respond(to: "What is the temperature in Tokyo right now?")
      log("TOOL → \(answer.content.replacingOccurrences(of: "\n", with: " "))")
    } catch {
      log("TOOL FAILED: \(error.localizedDescription)")
    }

    // Video understanding through the FM API (app-sampled frames).
    if let mov = Bundle.main.url(forResource: "sample", withExtension: "mp4") {
      do {
        let frames = try await VideoFrameSampler.sampleFrames(from: mov, count: 4)
        let answer = try await session.respond {
          LiteRTVideoSegment(frames: frames)
          "These images are frames sampled from a video in chronological order. "
            + "Describe what is happening in the video."
        }
        log("VIDEO(FM) → \(answer.content.replacingOccurrences(of: "\n", with: " "))")
      } catch {
        log("VIDEO(FM) FAILED: \(error.localizedDescription)")
      }
    } else {
      log("VIDEO(FM) skipped — bundle a sample.mp4 to exercise it")
    }

    log("DONE")
  }
}

#endif
