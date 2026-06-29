// LiteRTDemo — app entry point.
//
// Two modes:
//   • Interactive (default): the ContentView chat UI.
//   • G0 self-test (LITERT_G0_TEST=1): headless text→image→audio benchmark for
//     device runs driven by `devicectl`.

import SwiftUI

@main
struct LiteRTDemoApp: App {
  init() {
    // Make stdout unbuffered so headless self-test logs reach
    // `devicectl --console` immediately — block buffering otherwise swallows
    // them (a single small write can sit in the buffer indefinitely when piped).
    setvbuf(stdout, nil, _IONBF, 0)
    let env = ProcessInfo.processInfo.environment
    print("APP: launched · BENCH=\(env["LITERT_BENCH"] ?? "nil") · G0=\(env["LITERT_G0_TEST"] ?? "nil")")
    fflush(stdout)
  }

  var body: some Scene {
    WindowGroup { rootView }
  }

  @ViewBuilder private var rootView: some View {
    #if canImport(FoundationModels)
    if #available(iOS 27.0, macOS 27.0, *) {
      if G1SelfTest.isRequested {
        SelfTestRunnerView(title: "Running G1 (Foundation Models) self-test…") {
          await G1SelfTest.run()
        }
      } else if FMMultimodalSelfTest.isRequested {
        SelfTestRunnerView(title: "Running FM multimodal self-test…") {
          await FMMultimodalSelfTest.run()
        }
      } else {
        nonFMRoot
      }
    } else {
      nonFMRoot
    }
    #else
    nonFMRoot
    #endif
  }

  @ViewBuilder private var nonFMRoot: some View {
    if MMChatSelfTest.isRequested {
      SelfTestRunnerView(title: "Running multimodal-chat self-test…") { await MMChatSelfTest.run() }
    } else if BenchSelfTest.isRequested {
      SelfTestRunnerView(title: "Running benchmark…") { await BenchSelfTest.run() }
    } else if G0SelfTest.isRequested {
      SelfTestRunnerView(title: "Running G0 self-test…") { await G0SelfTest.run() }
    } else {
      ContentView()
    }
  }
}

/// Minimal view shown while a headless self-test runs; results go to the log.
private struct SelfTestRunnerView: View {
  let title: String
  let action: () async -> Void
  @State private var started = false

  var body: some View {
    VStack(spacing: 12) {
      ProgressView()
      Text(title).font(.headline)
      Text("Results are logged (filter by the test's prefix).")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .task {
      guard !started else { return }
      started = true
      await action()
    }
  }
}
