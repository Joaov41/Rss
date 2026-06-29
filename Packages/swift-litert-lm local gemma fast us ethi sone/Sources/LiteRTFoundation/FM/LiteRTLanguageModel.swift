// swift-litert-lm — Foundation Models backend (FM mode)
//
// `LiteRTLanguageModel` makes LiteRT-LM a first-class Apple Foundation Models
// backend, alongside Apple's own `CoreAILanguageModel` and `MLXLanguageModel`:
//
//   let model   = try await LiteRTLanguageModel(.gemma4_E2B)
//   let session = LanguageModelSession(model: model)          // Apple's exact API
//   let answer  = try await session.respond(to: "Hi")          // streaming / tools / @Generable
//
// The FM API is transcript-based (each turn hands the executor the full
// conversation), while LiteRT-LM is stateful (a `Conversation` accumulates its
// own KV cache). We bridge by rebuilding a fresh LiteRT `Conversation` from the
// transcript on each turn — correct and simple; an incremental fast-path is a
// later optimization.

#if canImport(FoundationModels)

import Foundation
import FoundationModels
import CoreGraphics
import LiteRTLM

/// A LiteRT-LM model exposed as an Apple Foundation Models backend.
@available(iOS 27.0, macOS 27.0, *)
public struct LiteRTLanguageModel: LanguageModel {
  public typealias Executor = LiteRTExecutor

  public let capabilities: LanguageModelCapabilities
  public let executorConfiguration: LiteRTExecutor.Configuration

  /// Create the backend, downloading the model on first use.
  ///
  /// - Parameters:
  ///   - model: Which catalog model to run.
  ///   - storageDirectory: Where to keep the downloaded model (defaults to
  ///     Application Support/LiteRTModels).
  ///   - onDownloadProgress: Called on first run while the model downloads.
  public init(
    _ model: LiteRTModel,
    storageDirectory: URL? = nil,
    onDownloadProgress: (@Sendable (ModelDownloader.Progress) -> Void)? = nil
  ) async throws {
    let path = try await LiteRTChat.ensureModel(
      model, storageDirectory: storageDirectory, onProgress: onDownloadProgress)
    self.executorConfiguration = LiteRTExecutor.Configuration(model: model, modelPath: path)
    // Declared capabilities: guided generation (best-effort schema-in-prompt; see
    // the executor) and vision (gates image attachments). Audio/video ride the
    // custom-segment hook and are not capability-gated.
    var capabilities: [LanguageModelCapabilities.Capability] = [.guidedGeneration, .toolCalling]
    if model.supportedModalities.contains(.vision) { capabilities.append(.vision) }
    self.capabilities = LanguageModelCapabilities(capabilities: capabilities)
  }

  /// Create the backend from a **local `.litertlm` file** — no catalog, no
  /// download. For experimenting with your own (e.g. fine-tuned) models through
  /// the Foundation Models API: push the file with `devicectl`, bundle it, or
  /// import it via the Files app, then load it straight by URL.
  ///
  /// - Parameters:
  ///   - modelFileURL: Absolute file URL of an on-disk `.litertlm`.
  ///   - modalities: Towers to enable (default `.all`; only the ones the model
  ///     actually contains will work).
  ///   - visionBackend / audioBackend: Backend per encoder tower (default
  ///     `.cpu()` — the safe choice for Gemma 4-class models).
  ///   - visualTokenBudget: Per-image visual-token cap (nil = engine default).
  ///   - maxTokens: KV/context budget.
  public init(
    modelFileURL url: URL,
    modalities: Modality = .all,
    visionBackend: Backend = .cpu(),
    audioBackend: Backend = .cpu(),
    visualTokenBudget: Int32? = nil,
    maxTokens: Int = 2048
  ) throws {
    guard FileManager.default.fileExists(atPath: url.path) else {
      throw LiteRTChatError.modelFileNotFound(url)
    }
    self.executorConfiguration = LiteRTExecutor.Configuration(
      modelPath: url.path,
      visionBackend: modalities.contains(.vision) ? visionBackend : nil,
      audioBackend: modalities.contains(.audio) ? audioBackend : nil,
      visualTokenBudget: visualTokenBudget,
      maxTokens: maxTokens)
    var capabilities: [LanguageModelCapabilities.Capability] = [.guidedGeneration, .toolCalling]
    if modalities.contains(.vision) { capabilities.append(.vision) }
    self.capabilities = LanguageModelCapabilities(capabilities: capabilities)
  }

  /// Release every cached LiteRT engine built for FM sessions, freeing their
  /// multi-GB weights. Call when leaving FM mode so a subsequently-loaded engine
  /// (e.g. an Easy-mode `LiteRTChat`) doesn't sit resident alongside it and OOM
  /// the app. Any live `LanguageModelSession` over this backend transparently
  /// rebuilds its engine on the next turn.
  public static func releaseCachedEngines() async {
    await EngineCache.shared.purgeAll()
  }
}

/// Drives generation for `LiteRTLanguageModel` over the FM executor protocol.
@available(iOS 27.0, macOS 27.0, *)
public final class LiteRTExecutor: LanguageModelExecutor {
  public typealias Model = LiteRTLanguageModel

  /// Lightweight description of what engine to build. The actual (async-init)
  /// engine is created lazily by the executor and shared per `modelPath` (the
  /// cache keys on the path alone, so two sessions over the same file reuse one
  /// engine). Carries the engine settings explicitly so a custom local model
  /// works without a catalog `LiteRTModel`.
  public struct Configuration: Hashable, @unchecked Sendable {
    public let modelPath: String
    let visionBackend: Backend?
    let audioBackend: Backend?
    let visualTokenBudget: Int32?
    let maxTokens: Int

    /// Settings derived from a catalog model.
    init(model: LiteRTModel, modelPath: String) {
      self.modelPath = modelPath
      self.visionBackend = model.supportedModalities.contains(.vision) ? model.visionBackend : nil
      self.audioBackend = model.supportedModalities.contains(.audio) ? model.audioBackend : nil
      self.visualTokenBudget = model.defaultVisualTokenBudget
      self.maxTokens = model.defaultMaxTokens
    }

    /// Explicit settings for a custom / local model.
    public init(
      modelPath: String, visionBackend: Backend?, audioBackend: Backend?,
      visualTokenBudget: Int32?, maxTokens: Int
    ) {
      self.modelPath = modelPath
      self.visionBackend = visionBackend
      self.audioBackend = audioBackend
      self.visualTokenBudget = visualTokenBudget
      self.maxTokens = maxTokens
    }

    // One engine per file: hash/compare on the path only.
    public static func == (a: Configuration, b: Configuration) -> Bool { a.modelPath == b.modelPath }
    public func hash(into hasher: inout Hasher) { hasher.combine(modelPath) }
  }

  private let engine: LazyEngine

  public init(configuration: Configuration) throws {
    // Share one engine per configuration across executors. FM may build a new
    // executor per session (e.g. a session created with tools), and each engine
    // loads multi-GB weights — without sharing, a second session OOMs the app.
    self.engine = EngineCache.shared.engine(for: configuration)
  }

  public func prewarm(model: Model, transcript: Transcript) {
    // Kick off engine creation + a tiny warmup so the first real turn is fast.
    Task { try? await engine.prewarmed() }
  }

  public func respond(
    to request: LanguageModelExecutorGenerationRequest,
    model: Model,
    streamingInto channel: LanguageModelExecutorGenerationChannel
  ) async throws {
    let engine = try await self.engine.ready()
    // Guided generation (G2): if the request carries a schema, encode it to JSON
    // and steer the model toward it via the prompt (schema-in-prompt). Tools: if
    // the request enables tools, describe them in the prompt and detect a
    // tool-call in the output. Both are soft (prompt-driven); hard constrained
    // decoding (llguidance) is a follow-up.
    let tools = request.enabledToolDefinitions
    let schemaJSON = request.schema.flatMap { try? Self.encodeSchema($0) }
    let plan = try Self.plan(from: request.transcript, schemaJSON: schemaJSON, tools: tools)

    // Lower temperature for guided / tool generation (more reliable JSON).
    let structured = schemaJSON != nil || !tools.isEmpty
    let temperature: Float = structured ? 0.0 : 0.8
    let conversation = try await engine.createConversation(
      with: ConversationConfig(
        systemMessage: plan.systemMessage,
        initialMessages: plan.history,
        samplerConfig: try? SamplerConfig(topK: 40, topP: 0.95, temperature: temperature)))

    if !tools.isEmpty {
      // Tool mode: buffer the output; if it's a tool call, emit a ToolCalls event
      // (FM executes the session's tool and re-invokes us with the result);
      // otherwise emit the answer as text.
      var full = ""
      for try await chunk in conversation.sendMessageStream(plan.prompt) { full += chunk.toString }
      if let call = Self.parseToolCall(from: full, tools: tools) {
        await channel.send(
          .toolCalls(
            action: .toolCall(
              id: UUID().uuidString, name: call.name,
              action: .appendArguments(call.arguments, tokenCount: call.arguments.count))))
      } else {
        await channel.send(.response(action: .appendText(full, tokenCount: full.count)))
      }
    } else if schemaJSON != nil {
      // Guided: accumulate, extract the JSON object (models wrap it in
      // prose/fences), and emit once so FM parses the @Generable type cleanly.
      var full = ""
      for try await chunk in conversation.sendMessageStream(plan.prompt) { full += chunk.toString }
      let json = Self.extractJSONObject(from: full) ?? full
      await channel.send(.response(action: .appendText(json, tokenCount: json.count)))
    } else {
      for try await chunk in conversation.sendMessageStream(plan.prompt) {
        let delta = chunk.toString
        if !delta.isEmpty {
          await channel.send(.response(action: .appendText(delta, tokenCount: 1)))
        }
      }
    }
  }

  /// Extract the first balanced JSON object from model text (strips prose/fences).
  private static func extractJSONObject(from text: String) -> String? {
    guard let start = text.firstIndex(of: "{") else { return nil }
    var depth = 0
    var inString = false
    var escaped = false
    var idx = start
    while idx < text.endIndex {
      let ch = text[idx]
      if inString {
        if escaped { escaped = false } else if ch == "\\" { escaped = true }
        else if ch == "\"" { inString = false }
      } else if ch == "\"" {
        inString = true
      } else if ch == "{" {
        depth += 1
      } else if ch == "}" {
        depth -= 1
        if depth == 0 { return String(text[start...idx]) }
      }
      idx = text.index(after: idx)
    }
    return nil
  }

  // MARK: Transcript → LiteRT messages

  private struct Plan {
    let systemMessage: Message?
    let history: [Message]
    let prompt: Message
  }

  /// Split the FM transcript into a system message, prior turns (history), and
  /// the message to generate from. The generation trigger is the last `.prompt`
  /// OR (in a tool round-trip) the last `.toolOutput`. Schema/tool guidance is
  /// added as appropriate.
  private static func plan(
    from transcript: Transcript, schemaJSON: String?, tools: [Transcript.ToolDefinition]
  ) throws -> Plan {
    let entries = Array(transcript)
    guard
      let triggerIndex = entries.lastIndex(where: {
        switch $0 {
        case .prompt, .toolOutput: return true
        default: return false
        }
      })
    else {
      throw LiteRTFMError.noPrompt
    }

    var systemText: [String] = []
    if !tools.isEmpty { systemText.append(toolInstructions(tools)) }
    var history: [Message] = []
    var trigger: Message?

    for (i, entry) in entries.enumerated() {
      let isTrigger = (i == triggerIndex)
      switch entry {
      case .instructions(let instructions):
        systemText.append(text(of: instructions.segments))
      case .prompt(let p):
        var c = contents(of: p.segments)
        if isTrigger, let schemaJSON, !schemaJSON.isEmpty {
          c.append(
            .text(
              "\n\nRespond with ONLY a JSON object that conforms to this JSON schema. "
                + "Output valid JSON and nothing else:\n\(schemaJSON)"))
        }
        let message = Message(contents: c, role: .user)
        if isTrigger { trigger = message } else { history.append(message) }
      case .response(let r):
        history.append(Message(contents: [.text(text(of: r.segments))], role: .model))
      case .toolOutput(let output):
        let result = text(of: output.segments)
        let message = Message(
          "Tool \"\(output.toolName)\" returned: \(result)\nUse this result to answer the user.",
          role: .user)
        if isTrigger { trigger = message } else { history.append(message) }
      case .toolCalls:
        history.append(Message("[the assistant called a tool]", role: .model))
      case .reasoning:
        break
      @unknown default:
        break
      }
    }

    let system = systemText.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    return Plan(
      systemMessage: system.isEmpty ? nil : Message(system, role: .system),
      history: history,
      prompt: trigger!  // guaranteed by triggerIndex
    )
  }

  /// Describe the enabled tools and the tool-call JSON format for the prompt.
  private static func toolInstructions(_ tools: [Transcript.ToolDefinition]) -> String {
    var lines = ["You can call tools to help answer the user. Available tools:"]
    for tool in tools {
      let params = (try? encodeSchema(tool.parameters)) ?? "{}"
      lines.append("- \(tool.name): \(tool.description). arguments schema: \(params)")
    }
    lines.append(
      "To call a tool, reply with ONLY this JSON and nothing else: "
        + "{\"tool_call\": {\"name\": \"<tool name>\", \"arguments\": { ... }}}. "
        + "If no tool is needed, answer the user directly.")
    return lines.joined(separator: "\n")
  }

  /// Parse a tool call from model output, if present and naming a known tool.
  private static func parseToolCall(from text: String, tools: [Transcript.ToolDefinition])
    -> (name: String, arguments: String)?
  {
    guard let json = extractJSONObject(from: text),
      let data = json.data(using: .utf8),
      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let call = obj["tool_call"] as? [String: Any],
      let name = call["name"] as? String,
      tools.contains(where: { $0.name == name })
    else { return nil }
    let args = call["arguments"] ?? [String: Any]()
    let argsData = (try? JSONSerialization.data(withJSONObject: args)) ?? Data("{}".utf8)
    return (name, String(data: argsData, encoding: .utf8) ?? "{}")
  }

  /// Concatenate the text of a segment list (non-text segments ignored for now).
  private static func text(of segments: [Transcript.Segment]) -> String {
    segments.compactMap { segment in
      if case .text(let t) = segment { return t.content } else { return nil }
    }.joined(separator: " ")
  }

  /// Encode an FM `GenerationSchema` to a JSON Schema string (it's `Codable`).
  private static func encodeSchema(_ schema: GenerationSchema) throws -> String {
    let data = try JSONEncoder().encode(schema)
    return String(data: data, encoding: .utf8) ?? ""
  }

  /// Map FM segments to LiteRT content: text, image attachments, and audio via
  /// the `LiteRTAudioSegment` custom segment.
  private static func contents(of segments: [Transcript.Segment]) -> [Content] {
    var out: [Content] = []
    for segment in segments {
      switch segment {
      case .text(let t):
        if !t.content.isEmpty { out.append(.text(t.content)) }
      case .attachment(let attachment):
        if case .image(let image) = attachment.content, let png = pngData(from: image.cgImage) {
          out.append(.imageData(png))
        }
      case .custom(let custom):
        if let audio = custom as? LiteRTAudioSegment {
          out.append(.audioData(audio.content.data))
        } else if let video = custom as? LiteRTVideoSegment {
          out.append(contentsOf: video.content.frames.map { Content.imageData($0) })
        }
      case .structure:
        break  // structured (guided-generation) content — a later phase
      @unknown default:
        break
      }
    }
    return out.isEmpty ? [.text("")] : out
  }
}

/// Errors specific to the Foundation Models bridge.
@available(iOS 27.0, macOS 27.0, *)
public enum LiteRTFMError: Error, LocalizedError {
  case noPrompt

  public var errorDescription: String? {
    switch self {
    case .noPrompt: return "The transcript contains no prompt to respond to."
    }
  }
}

/// Process-wide cache of one `LazyEngine` per configuration, so multiple FM
/// executors / sessions sharing a configuration share a single loaded engine.
@available(iOS 27.0, macOS 27.0, *)
private final class EngineCache: @unchecked Sendable {
  static let shared = EngineCache()
  private let lock = NSLock()
  private var engines: [LiteRTExecutor.Configuration: LazyEngine] = [:]

  func engine(for configuration: LiteRTExecutor.Configuration) -> LazyEngine {
    lock.lock()
    defer { lock.unlock() }
    if let engine = engines[configuration] { return engine }
    let engine = LazyEngine(configuration: configuration)
    engines[configuration] = engine
    return engine
  }

  /// Drop every cached engine and free its weights. Existing sessions rebuild
  /// their engine lazily on next use.
  func purgeAll() async {
    for engine in drain() { await engine.release() }
  }

  /// Synchronously remove and return all cached engines (keeps the `NSLock` out
  /// of the `async` context — locking across a suspension is disallowed).
  private func drain() -> [LazyEngine] {
    lock.lock()
    defer { lock.unlock() }
    let all = Array(engines.values)
    engines.removeAll()
    return all
  }
}

/// Lazily creates and caches the LiteRT engine. The FM executor's `init` is
/// synchronous but engine initialization is async, so we defer it to the first
/// `respond` (which is async) and memoize the result.
@available(iOS 27.0, macOS 27.0, *)
private actor LazyEngine {
  private let configuration: LiteRTExecutor.Configuration
  private var engine: Engine?
  private var warmed = false

  init(configuration: LiteRTExecutor.Configuration) {
    self.configuration = configuration
  }

  func ready() async throws -> Engine {
    if let engine { return engine }
    // Bring up the vision + audio towers so image attachments and audio custom
    // segments work through the FM API. Backends come from the configuration
    // (Gemma 4 E2B: both CPU — vision Metal fails STABLEHLO_COMPOSITE, audio is
    // CPU-only).
    ExperimentalFlags.optIntoExperimentalAPIs()
    if let budget = configuration.visualTokenBudget { ExperimentalFlags.visualTokenBudget = budget }
    let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
    let config = try EngineConfig(
      modelPath: configuration.modelPath, backend: .gpu,
      visionBackend: configuration.visionBackend,
      audioBackend: configuration.audioBackend,
      maxNumTokens: configuration.maxTokens, cacheDir: caches?.path)
    let created = Engine(engineConfig: config)
    try await created.initialize()
    engine = created
    return created
  }

  func prewarmed() async throws {
    let engine = try await ready()
    if warmed { return }
    warmed = true
    let warmup = try await engine.createConversation()
    for try await _ in warmup.sendMessageStream(Message("Hi")) {}
  }

  /// Tear down the loaded engine, freeing its weights. A later `ready()`
  /// rebuilds it from scratch.
  func release() {
    engine = nil
    warmed = false
  }
}

#endif
