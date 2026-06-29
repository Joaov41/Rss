// LiteRTDemo — "FM API" mode (one demo per screen).
//
// Shows that LiteRT-LM is driven through Apple's *real* Foundation Models API —
// the same `LanguageModelSession` used for Apple Intelligence, but the model is
// Google's Gemma 4 via LiteRT, 100% on-device.
//
// A menu lists three demos; each opens its own full screen that leads with *why*
// the feature matters, shows the Swift contract, takes an editable prompt (type
// your own to prove a real LLM is processing it), and visualizes what the FM API
// did:
//   • respond(to:)        — same call as Apple's own model.
//   • respond(generating:)— the answer comes back as a TYPED Swift value, not
//                           text you parse.
//   • Tool calling        — the model calls YOUR Swift function; FM runs it and
//                           feeds the result back.

#if canImport(FoundationModels)

import SwiftUI
import FoundationModels
import LiteRTFoundation
import CoreLocation
import MapKit

// MARK: - Generable type FM fills for guided generation

/// A general-purpose structured answer, so the guided demo works for *any*
/// question — FM decodes the model's output into these typed fields.
@available(iOS 27.0, macOS 27.0, *)
@Generable
struct StructuredAnswer {
  @Guide(description: "A short title for the answer")
  var title: String
  @Guide(description: "A one-sentence summary")
  var summary: String
  @Guide(description: "The key points, each a short phrase")
  var points: [String]
  @Guide(description: "A few relevant keyword tags")
  var tags: [String]
}

// MARK: - A tool FM invokes (calls a real iOS framework: CoreLocation)

/// Result of a `CLGeocoder` lookup — carries the text fed back to the model plus
/// the real coordinates for the on-screen map.
struct LookupResult: Sendable {
  let argument: String      // the place the model extracted and passed
  let place: String         // resolved name
  let summary: String       // text returned to the model
  let latitude: Double?
  let longitude: Double?
}

/// A resolved place to drop on the map.
struct ToolLocation {
  let name: String
  let coordinate: CLLocationCoordinate2D
}

/// Looks up a place with Apple's `CLGeocoder` (CoreLocation) — real on-device
/// API, no permission or entitlement needed for forward geocoding. Returns the
/// real coordinates, time zone, and current local time, so the answer is genuine
/// data the model could not have known, fetched by your Swift function. The
/// demo also drops the coordinates onto a MapKit map.
@available(iOS 27.0, macOS 27.0, *)
struct LocationLookupTool: FoundationModels.Tool {
  let name = "lookup_location"
  let description = "Look up the real coordinates, time zone, and current local time of a city or place."
  let onCall: @Sendable (LookupResult) -> Void

  @Generable
  struct Arguments {
    @Guide(description: "The city or place name")
    var city: String
  }

  func call(arguments: Arguments) async throws -> String {
    let result = await Self.lookup(arguments.city)
    onCall(result)
    return result.summary
  }

  static func lookup(_ city: String) async -> LookupResult {
    do {
      let placemarks = try await CLGeocoder().geocodeAddressString(city)
      guard let p = placemarks.first, let loc = p.location else {
        return LookupResult(
          argument: city, place: city,
          summary: "Could not find a place named \(city).", latitude: nil, longitude: nil)
      }
      let tz = p.timeZone ?? .current
      let fmt = DateFormatter()
      fmt.timeZone = tz
      fmt.dateFormat = "HH:mm"
      let name = p.locality ?? p.name ?? city
      let summary = String(
        format: "%@: %.2f, %.2f · time zone %@ · local time %@",
        name, loc.coordinate.latitude, loc.coordinate.longitude, tz.identifier,
        fmt.string(from: Date()))
      return LookupResult(
        argument: city, place: name, summary: summary,
        latitude: loc.coordinate.latitude, longitude: loc.coordinate.longitude)
    } catch {
      return LookupResult(
        argument: city, place: city,
        summary: "Location lookup failed for \(city): \(error.localizedDescription)",
        latitude: nil, longitude: nil)
    }
  }
}

// MARK: - Menu

@available(iOS 27.0, macOS 27.0, *)
struct FMModeView: View {
  @StateObject private var vm = FMViewModel()
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      List {
        Section {
          VStack(alignment: .leading, spacing: 8) {
            Label("Apple's Foundation Models API", systemImage: "cpu")
              .font(.headline)
            Text("The same `LanguageModelSession` as Apple Intelligence — but the "
              + "model is Google's Gemma 4 via LiteRT, 100% on-device. Only the "
              + "`model:` argument is LiteRT-specific.")
              .font(.caption).foregroundStyle(.secondary)
          }
          .padding(.vertical, 4)
        }

        Section("Pick a demo") {
          NavigationLink { TextDemoView(vm: vm) } label: {
            menuRow("text.bubble", "Plain text",
              "respond(to:) — same call as Apple's own model")
          }
          NavigationLink { GuidedDemoView(vm: vm) } label: {
            menuRow("checklist", "Guided generation",
              "Get a typed Swift value back — not text to parse")
          }
          NavigationLink { ToolDemoView(vm: vm) } label: {
            menuRow("wrench.and.screwdriver", "Tool calling",
              "The model calls your Swift function")
          }
        }

        if !vm.isReady {
          Section {
            HStack(spacing: 10) {
              ProgressView().controlSize(.small)
              Text(vm.loadError ?? "Bringing up the LiteRT backend…")
                .font(.caption).foregroundStyle(vm.loadError == nil ? Color.secondary : Color.red)
            }
          }
        }
      }
      .navigationTitle("Foundation Models API")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
      }
    }
    .task { await vm.load() }
  }

  private func menuRow(_ icon: String, _ title: String, _ subtitle: String) -> some View {
    HStack(spacing: 12) {
      Image(systemName: icon).font(.title3).foregroundStyle(.tint).frame(width: 28)
      VStack(alignment: .leading, spacing: 2) {
        Text(title).font(.body.bold())
        Text(subtitle).font(.caption).foregroundStyle(.secondary)
      }
    }
    .padding(.vertical, 4)
  }
}

// MARK: - Demo screens

@available(iOS 27.0, macOS 27.0, *)
struct TextDemoView: View {
  @ObservedObject var vm: FMViewModel
  @FocusState private var focused: Bool

  var body: some View {
    DemoScaffold(
      title: "Plain text", focused: $focused,
      why: "The exact call you'd make to Apple's built-in model — "
        + "`session.respond(to:)`. The only difference is `model:`; here it's "
        + "Gemma 4, running on-device.",
      code: "let session = LanguageModelSession(model: model)\n"
        + "let answer  = try await session.respond(to: prompt)",
      prompt: $vm.textPrompt, running: vm.running == .text, ready: vm.isReady,
      run: { Task { await vm.runText() } }
    ) {
      if !vm.textOut.isEmpty {
        ResultBox { Text(vm.textOut).font(.callout).textSelection(.enabled) }
      }
    }
    .navigationTitle("respond(to:)")
  }
}

@available(iOS 27.0, macOS 27.0, *)
struct GuidedDemoView: View {
  @ObservedObject var vm: FMViewModel
  @FocusState private var focused: Bool

  var body: some View {
    DemoScaffold(
      title: "Guided generation", focused: $focused,
      why: "Normally an LLM hands you a blob of text you have to parse. Guided "
        + "generation hands you a TYPED Swift value instead: FM forces the model's "
        + "free-form answer to fill every field of your struct, then decodes it. "
        + "One prompt in → one structured object out. No JSON, no regex.",
      code: "@Generable struct StructuredAnswer {\n"
        + "  var title:   String\n"
        + "  var summary: String\n"
        + "  var points:  [String]\n"
        + "  var tags:    [String]\n"
        + "}\n"
        + "let a = try await session.respond(generating: StructuredAnswer.self) { prompt }",
      prompt: $vm.guidedPrompt, running: vm.running == .guided, ready: vm.isReady,
      run: { Task { await vm.runGuided() } }
    ) {
      if let answer = vm.guidedAnswer {
        ResultBox {
          VStack(alignment: .leading, spacing: 12) {
            // Render like the decoded Swift value, field by typed field.
            Text("StructuredAnswer").font(.callout.monospaced().bold()).foregroundStyle(.tint)
            field("title", "String") { Text(answer.title).font(.callout.bold()) }
            field("summary", "String") { Text(answer.summary).font(.callout) }
            field("points", "[String]") { FlowChips(answer.points) }
            field("tags", "[String]") { FlowChips(answer.tags) }
            Label("One decoded Swift object — every field is typed and ready: "
              + "a.points[0], a.tags.count. No parsing.",
              systemImage: "checkmark.seal.fill")
              .font(.caption2).foregroundStyle(.green)
          }
        }
      } else if let err = vm.guidedError {
        ResultBox {
          Label(err, systemImage: "exclamationmark.triangle.fill")
            .font(.caption).foregroundStyle(.red)
        }
      }
    }
    .navigationTitle("respond(generating:)")
  }

  private func field<V: View>(_ name: String, _ type: String, @ViewBuilder _ value: () -> V)
    -> some View
  {
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 6) {
        Text(name).font(.caption.monospaced().bold())
        Text(": \(type)").font(.caption.monospaced()).foregroundStyle(.secondary)
      }
      value()
    }
  }
}

@available(iOS 27.0, macOS 27.0, *)
struct ToolDemoView: View {
  @ObservedObject var vm: FMViewModel
  @FocusState private var focused: Bool

  var body: some View {
    DemoScaffold(
      title: "Tool calling", focused: $focused,
      why: "The model can't know where a city is — but it can call YOUR code. It "
        + "extracts the place from your prompt, and FM runs your Swift function, "
        + "which calls Apple's CoreLocation (CLGeocoder) for the REAL coordinates, "
        + "time zone, and local time — then the model answers with that data.",
      code: "struct LocationTool: Tool {\n"
        + "  func call(arguments: Arguments) async throws -> String {\n"
        + "    let p = try await CLGeocoder().geocodeAddressString(arguments.city)\n"
        + "    // real coordinates + time zone from CoreLocation\n"
        + "  }\n"
        + "}\n"
        + "let session = LanguageModelSession(model: model, tools: [LocationTool()])",
      prompt: $vm.toolPrompt, running: vm.running == .tool, ready: vm.isReady,
      run: { Task { await vm.runTool() } }
    ) {
      VStack(alignment: .leading, spacing: 12) {
        if vm.toolCity != nil || !vm.toolAnswer.isEmpty {
          ResultBox {
            VStack(alignment: .leading, spacing: 14) {
              step(1, "person.fill", "You asked", vm.lastToolPrompt, active: true)
              step(2, "brain", "Model called your tool",
                vm.toolCity.map { "lookup_location(city: \"\($0)\")" } ?? "…",
                active: vm.toolCity != nil,
                note: vm.toolCity != nil ? "the model extracted the place from your text" : nil)
              step(3, "gearshape.fill", "CoreLocation (CLGeocoder) returned",
                vm.toolReturned ?? "…", active: vm.toolReturned != nil)
              step(4, "text.bubble.fill", "Model's answer",
                vm.toolAnswer.isEmpty ? "…" : vm.toolAnswer, active: !vm.toolAnswer.isEmpty)
            }
          }
        }
        if let loc = vm.toolLocation {
          mapCard(loc)
        }
      }
    }
    .navigationTitle("Tool calling")
  }

  /// The visible payoff: the geocoded coordinates dropped on a real MapKit map.
  private func mapCard(_ loc: ToolLocation) -> some View {
    Map(
      initialPosition: .region(
        MKCoordinateRegion(
          center: loc.coordinate,
          span: MKCoordinateSpan(latitudeDelta: 0.4, longitudeDelta: 0.4)))
    ) {
      Marker(loc.name, coordinate: loc.coordinate)
    }
    .frame(height: 220)
    .clipShape(RoundedRectangle(cornerRadius: 12))
    // Rebuild when a new lookup recenters the map.
    .id("\(loc.coordinate.latitude),\(loc.coordinate.longitude)")
    .overlay(alignment: .bottomTrailing) {
      Text("MapKit").font(.caption2.bold())
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(.ultraThinMaterial).clipShape(Capsule()).padding(8)
    }
  }

  private func step(_ n: Int, _ icon: String, _ title: String, _ body: String,
    active: Bool, note: String? = nil) -> some View
  {
    HStack(alignment: .top, spacing: 10) {
      ZStack {
        Circle().fill(active ? Color.accentColor : Color(.systemGray4))
          .frame(width: 26, height: 26)
        Text("\(n)").font(.caption.bold()).foregroundStyle(.white)
      }
      VStack(alignment: .leading, spacing: 2) {
        Label(title, systemImage: icon).font(.caption.bold())
          .foregroundStyle(active ? Color.primary : Color.secondary)
        Text(body).font(.caption.monospaced())
          .foregroundStyle(active ? Color.primary : Color.secondary)
        if let note { Text(note).font(.caption2).foregroundStyle(.orange) }
      }
    }
    .opacity(active ? 1 : 0.5)
  }
}

// MARK: - Shared scaffold + components

@available(iOS 27.0, macOS 27.0, *)
private struct DemoScaffold<Result: View>: View {
  let title: String
  var focused: FocusState<Bool>.Binding
  let why: String
  let code: String
  @Binding var prompt: String
  let running: Bool
  let ready: Bool
  let run: () -> Void
  @ViewBuilder let result: () -> Result

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        // Why this matters — the "wow", in plain language.
        Text(why).font(.callout)
          .padding()
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(Color.accentColor.opacity(0.12))
          .clipShape(RoundedRectangle(cornerRadius: 12))

        CodeBox(code)

        VStack(alignment: .leading, spacing: 6) {
          Text("YOUR PROMPT").font(.caption2.bold()).foregroundStyle(.secondary)
          TextField("prompt", text: $prompt, axis: .vertical)
            .font(.callout).lineLimit(1...5)
            .textFieldStyle(.plain).focused(focused)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .disabled(running)
          Text("Edit this and Run — a real LLM processes whatever you type.")
            .font(.caption2).foregroundStyle(.secondary)
        }

        Button(action: run) {
          HStack {
            if running { ProgressView().controlSize(.small) }
            else { Image(systemName: "play.fill") }
            Text(running ? "Running…" : "Run").bold()
          }
          .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent).controlSize(.large)
        .disabled(!ready || running)

        result()
      }
      .padding()
    }
    .scrollDismissesKeyboard(.interactively)
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .keyboard) {
        HStack { Spacer(); Button("Done") { focused.wrappedValue = false } }
      }
    }
  }
}

@available(iOS 27.0, macOS 27.0, *)
private struct CodeBox: View {
  let code: String
  init(_ code: String) { self.code = code }
  var body: some View {
    Text(code).font(.caption.monospaced())
      .padding(10)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(Color(.tertiarySystemBackground))
      .clipShape(RoundedRectangle(cornerRadius: 8))
  }
}

@available(iOS 27.0, macOS 27.0, *)
private struct ResultBox<Content: View>: View {
  @ViewBuilder let content: () -> Content
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("RESULT").font(.caption2.bold()).foregroundStyle(.secondary)
      content()
    }
    .padding()
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color(.secondarySystemBackground))
    .clipShape(RoundedRectangle(cornerRadius: 12))
  }
}

/// Wrapping row of chips (colored if the value is a known color name).
@available(iOS 27.0, macOS 27.0, *)
private struct FlowChips: View {
  let items: [String]
  init(_ items: [String]) { self.items = items }
  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      ForEach(items, id: \.self) { item in
        Text(item).font(.caption.bold())
          .padding(.horizontal, 10).padding(.vertical, 6)
          .background(swatch(for: item)).foregroundStyle(.white)
          .clipShape(Capsule())
      }
    }
  }
  private func swatch(for v: String) -> Color {
    switch v.lowercased() {
    case let c where c.contains("red"): return .red
    case let c where c.contains("green"): return .green
    case let c where c.contains("blue"): return .blue
    default: return .gray
    }
  }
}

// MARK: - View model

@available(iOS 27.0, macOS 27.0, *)
@MainActor
final class FMViewModel: ObservableObject {
  enum Running { case text, guided, tool }

  @Published var isReady = false
  @Published var loadError: String?
  @Published var running: Running?

  @Published var textPrompt = "Explain on-device AI in one sentence."
  @Published var guidedPrompt = "Give a brief overview of on-device AI."
  @Published var toolPrompt = "Where is Tokyo, and what time is it there?"

  @Published var textOut = ""
  @Published var guidedAnswer: StructuredAnswer?
  @Published var guidedError: String?
  @Published var lastToolPrompt = ""
  @Published var toolCity: String?
  @Published var toolReturned: String?
  @Published var toolAnswer = ""
  @Published var toolLocation: ToolLocation?

  private var model: LiteRTLanguageModel?

  func load() async {
    guard model == nil else { return }
    // FM mode doesn't display tok/s; disabling the benchmark counters also avoids
    // the engine's no-sampler prewarm tripping `output_buffer_dup` if Easy mode
    // left the global benchmark flag on.
    ExperimentalFlags.enableBenchmark = false
    do {
      self.model = try await LiteRTLanguageModel(.gemma4_E2B)
      isReady = true
    } catch {
      loadError = error.localizedDescription
    }
  }

  func runText() async {
    guard let model, running == nil else { return }
    let prompt = textPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !prompt.isEmpty else { return }
    running = .text; defer { running = nil }
    textOut = ""
    do {
      // Fresh session per run so each Run is self-contained.
      let session = LanguageModelSession(model: model)
      textOut = try await session.respond(to: prompt).content
    } catch {
      textOut = "[error] \(error.localizedDescription)"
    }
  }

  func runGuided() async {
    guard let model, running == nil else { return }
    let prompt = guidedPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !prompt.isEmpty else { return }
    running = .guided; defer { running = nil }
    guidedAnswer = nil; guidedError = nil
    // Fresh session + one retry: schema-in-prompt JSON can occasionally come back
    // unparseable on a 2B model.
    for attempt in 1...2 {
      do {
        let session = LanguageModelSession(model: model)
        guidedAnswer = try await session.respond(generating: StructuredAnswer.self) { prompt }.content
        return
      } catch {
        if attempt == 2 { guidedError = error.localizedDescription }
      }
    }
  }

  func runTool() async {
    guard let model, running == nil else { return }
    let prompt = toolPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !prompt.isEmpty else { return }
    running = .tool; defer { running = nil }
    lastToolPrompt = prompt
    toolCity = nil; toolReturned = nil; toolAnswer = ""; toolLocation = nil
    let tool = LocationLookupTool { [weak self] result in
      Task { @MainActor in
        self?.toolCity = result.argument
        self?.toolReturned = result.summary
        if let lat = result.latitude, let lon = result.longitude {
          self?.toolLocation = ToolLocation(
            name: result.place, coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon))
        }
      }
    }
    let session = LanguageModelSession(model: model, tools: [tool])
    do {
      toolAnswer = try await session.respond(to: prompt).content
    } catch {
      toolAnswer = "[error] \(error.localizedDescription)"
    }
  }
}

#endif
