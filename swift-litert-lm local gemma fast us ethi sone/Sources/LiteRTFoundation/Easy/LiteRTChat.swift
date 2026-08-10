// swift-litert-lm — Easy mode (`LiteRTChat`)
//
// The 10-minute on-ramp: pick a model, get a chat. `LiteRTChat` owns every part
// of running Gemma 4 on iPhone that is otherwise a multi-day yak-shave —
// downloading the right `.litertlm`, refusing to load on a device that would
// jetsam, bringing up the Metal GPU backend (and the vision/audio towers you
// ask for), and streaming tokens.
//
//   let chat = try await LiteRTChat(.gemma4_E2B)
//   for try await token in chat.stream("Describe this", image: jpeg) { print(token) }

import Foundation
@_exported import LiteRTLM  // re-export Message/Content/etc. for callers

/// Audio input for a multimodal turn.
public enum AudioInput: Sendable {
  /// Raw audio bytes (e.g. a WAV file's contents).
  case data(Data)
  /// An absolute file URL to an audio file.
  case file(URL)

  var content: Content {
    switch self {
    case .data(let d): return .audioData(d)
    case .file(let url): return .audioFile(url.path)
    }
  }
}

/// A ready-to-use LiteRT-LM chat session backed by the Metal GPU.
public final class LiteRTChat {

  /// The catalog model this session is running, or `nil` when loaded from a
  /// custom local file via `init(modelFileURL:)`.
  public let model: LiteRTModel?
  /// The modalities actually brought up for this session.
  public let modalities: Modality
  /// Absolute path to the loaded model file.
  public let modelPath: String

  private let engine: Engine
  private var conversation: Conversation?
  private let conversationConfig: ConversationConfig
  private var didSendDocumentTurn = false

  // MARK: Lifecycle

  /// Bring up a chat session, downloading the model on first use.
  ///
  /// - Parameters:
  ///   - model: Which catalog model to run.
  ///   - modalities: Towers to enable. Defaults to the model's `defaultModalities`
  ///     (text+image for Gemma 4 E2B). Requesting an unsupported tower is ignored.
  ///   - storageDirectory: Where to keep the downloaded model. Defaults to
  ///     Application Support/LiteRTModels (persistent, excluded from backup).
  ///   - allowUnsafeMemory: Bypass the device-RAM safety check. Off by default —
  ///     Easy mode refuses to load on a device that would likely jetsam mid-run.
  ///   - enableBenchmark: Turn on the engine's benchmark instrumentation so
  ///     `lastBenchmark()` reports real prefill/decode tokens-per-second.
  ///   - speculativeDecoding: Use the model's multi-token-prediction (MTP) drafter.
  ///     Off by default — on the current runtime build enabling it is flaky and
  ///     gives no measured decode speedup for Gemma 4 E2B.
  ///   - sampler: Sampling configuration for generation. Defaults to a balanced
  ///     chat sampler. (A non-nil sampler also avoids a benchmark-mode crash.)
  ///   - prewarm: Run a tiny throwaway generation during setup so the GPU decode
  ///     kernels are warm — the *first* real message is then fast (~50 vs ~33
  ///     tok/s cold on iPhone 17 Pro). On by default; adds ~1–2 s to setup.
  ///   - onDownloadProgress: Called on the first run as the model downloads.
  /// - Throws: `LiteRTChatError` for memory/availability problems, `LiteRTLMError`
  ///   for engine failures, or a download error.
  public convenience init(
    _ model: LiteRTModel,
    modalities: Modality? = nil,
    storageDirectory: URL? = nil,
    allowUnsafeMemory: Bool = false,
    enableBenchmark: Bool = false,
    speculativeDecoding: Bool = false,
    sampler: SamplerConfig? = nil,
    prewarm: Bool = true,
    onDownloadProgress: (@Sendable (ModelDownloader.Progress) -> Void)? = nil
  ) async throws {
    // Memory gate: refuse rather than let the OS kill us partway through a load.
    if !allowUnsafeMemory {
      let ram = Int64(ProcessInfo.processInfo.physicalMemory)
      if ram < model.minimumDeviceRAM {
        throw LiteRTChatError.insufficientMemory(
          haveBytes: ram, needBytes: model.minimumDeviceRAM)
      }
    }

    let path = try await LiteRTChat.ensureModel(
      model, storageDirectory: storageDirectory, onProgress: onDownloadProgress)

    var wanted = modalities ?? model.defaultModalities
    wanted.formIntersection(model.supportedModalities)

    // Gemma 4's variable-resolution vision: cap per-image visual tokens to keep
    // the GPU working set bounded. Takes effect immediately, so set before init.
    ExperimentalFlags.optIntoExperimentalAPIs()
    if wanted.contains(.vision), let budget = model.defaultVisualTokenBudget {
      ExperimentalFlags.visualTokenBudget = budget
    }
    if enableBenchmark { ExperimentalFlags.enableBenchmark = true }
    ExperimentalFlags.enableSpeculativeDecoding = speculativeDecoding

    let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
    // Each tower's backend is dictated by the model's section constraints, not a
    // free choice: e.g. Gemma 4 E2B's audio encoder is CPU-only (see catalog).
    let config = try EngineConfig(
      modelPath: path,
      backend: .gpu,
      visionBackend: wanted.contains(.vision) ? model.visionBackend : nil,
      audioBackend: wanted.contains(.audio) ? model.audioBackend : nil,
      maxNumTokens: model.defaultMaxTokens,
      cacheDir: caches?.path
    )
    let engine = Engine(engineConfig: config)
    try await engine.initialize()  // runs on the engine actor, off the main thread

    // A balanced default sampler unless the caller supplied one.
    let activeSampler = try sampler ?? SamplerConfig(topK: 40, topP: 0.95, temperature: 0.8)

    // Prewarm on a throwaway conversation: the first generation compiles/warms the
    // GPU decode kernels (cold ~44 → warm ~50 tok/s). Doing it here, on a separate
    // conversation (same sampler — a non-nil sampler avoids the benchmark-mode
    // crash), keeps the user's real conversation history clean.
    if prewarm {
      let warmup = try await engine.createConversation(
        with: ConversationConfig(samplerConfig: activeSampler))
      for try await _ in warmup.sendMessageStream(Message("Hi")) {}
    }

    let conversation = try await engine.createConversation(
      with: ConversationConfig(samplerConfig: activeSampler))

    self.init(
      model: model, modalities: wanted, modelPath: path,
      engine: engine, conversation: conversation,
      conversationConfig: ConversationConfig(samplerConfig: activeSampler))
  }

  /// Bring up a chat session from a **local `.litertlm` file** — no catalog, no
  /// download. The fast path for experimenting with your own (e.g. fine-tuned)
  /// models: drop the file in the app bundle, push it with `devicectl`, or import
  /// it via the Files app, then load it straight by URL.
  ///
  /// - Parameters:
  ///   - modelFileURL: Absolute file URL of an on-disk `.litertlm`.
  ///   - modalities: Towers to bring up. Defaults to `.all`; only the ones the
  ///     model actually contains will work.
  ///   - visionBackend / audioBackend: Backend for each encoder tower. Default
  ///     `.cpu()` (the safe choice — Gemma 4's vision/audio must run on CPU).
  ///   - visualTokenBudget: Per-image visual-token cap (nil = engine default).
  ///   - maxTokens: KV/context budget.
  ///   - minimumDeviceRAM: If set, refuse to load on a device with less RAM.
  ///   - enableBenchmark / speculativeDecoding / sampler / prewarm: as the
  ///     catalog initializer.
  public convenience init(
    modelFileURL url: URL,
    modalities: Modality = .all,
    visionBackend: Backend = .cpu(),
    audioBackend: Backend = .cpu(),
    visualTokenBudget: Int32? = nil,
    maxTokens: Int = 2048,
    minimumDeviceRAM: Int64? = nil,
    enableBenchmark: Bool = false,
    speculativeDecoding: Bool = false,
    sampler: SamplerConfig? = nil,
    prewarm: Bool = true
  ) async throws {
    if let need = minimumDeviceRAM {
      let ram = Int64(ProcessInfo.processInfo.physicalMemory)
      if ram < need {
        throw LiteRTChatError.insufficientMemory(haveBytes: ram, needBytes: need)
      }
    }
    guard FileManager.default.fileExists(atPath: url.path) else {
      throw LiteRTChatError.modelFileNotFound(url)
    }

    ExperimentalFlags.optIntoExperimentalAPIs()
    if modalities.contains(.vision), let budget = visualTokenBudget {
      ExperimentalFlags.visualTokenBudget = budget
    }
    if enableBenchmark { ExperimentalFlags.enableBenchmark = true }
    ExperimentalFlags.enableSpeculativeDecoding = speculativeDecoding

    let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
    let config = try EngineConfig(
      modelPath: url.path,
      backend: .gpu,
      visionBackend: modalities.contains(.vision) ? visionBackend : nil,
      audioBackend: modalities.contains(.audio) ? audioBackend : nil,
      maxNumTokens: maxTokens,
      cacheDir: caches?.path
    )
    let engine = Engine(engineConfig: config)
    try await engine.initialize()

    let activeSampler = try sampler ?? SamplerConfig(topK: 40, topP: 0.95, temperature: 0.8)
    if prewarm {
      let warmup = try await engine.createConversation(
        with: ConversationConfig(samplerConfig: activeSampler))
      for try await _ in warmup.sendMessageStream(Message("Hi")) {}
    }
    let conversation = try await engine.createConversation(
      with: ConversationConfig(samplerConfig: activeSampler))

    self.init(
      model: nil, modalities: modalities, modelPath: url.path,
      engine: engine, conversation: conversation,
      conversationConfig: ConversationConfig(samplerConfig: activeSampler))
  }

  /// Bring up a chat session from **any Hugging Face repo** that hosts a
  /// `.litertlm` — downloaded on first use, then run. Lets you try any community
  /// model (e.g. `litert-community/gemma-4-E4B-it-litert-lm`) without a catalog
  /// entry.
  ///
  /// - Parameters:
  ///   - huggingFaceRepo: e.g. `"litert-community/gemma-4-E4B-it-litert-lm"`.
  ///   - fileName: the `.litertlm` file in that repo (a repo may host several).
  ///   - revision: git revision / branch (default `main`).
  ///   - modalities: defaults to **text-only** (`[]`) — the safe choice for an
  ///     unknown model; pass `.all` (or `.textImage`) only if you know the model
  ///     ships those encoders, or engine init may refuse.
  ///   - (other parameters as `init(modelFileURL:)`.)
  public convenience init(
    huggingFaceRepo: String,
    fileName: String,
    revision: String = "main",
    modalities: Modality = [],
    visionBackend: Backend = .cpu(),
    audioBackend: Backend = .cpu(),
    visualTokenBudget: Int32? = nil,
    maxTokens: Int = 2048,
    minimumDeviceRAM: Int64? = nil,
    storageDirectory: URL? = nil,
    enableBenchmark: Bool = false,
    speculativeDecoding: Bool = false,
    sampler: SamplerConfig? = nil,
    prewarm: Bool = true,
    onDownloadProgress: (@Sendable (ModelDownloader.Progress) -> Void)? = nil
  ) async throws {
    guard
      let url = URL(
        string: "https://huggingface.co/\(huggingFaceRepo)/resolve/\(revision)/\(fileName)?download=true")
    else {
      throw LiteRTChatError.modelFileNotFound(URL(fileURLWithPath: fileName))
    }
    let dir = try storageDirectory ?? Self.defaultStorageDirectory()
    let dest = dir.appendingPathComponent(fileName)
    try await ModelDownloader.shared.download(
      from: url, to: dest, expectedBytes: nil, onProgress: onDownloadProgress)
    try await self.init(
      modelFileURL: dest, modalities: modalities,
      visionBackend: visionBackend, audioBackend: audioBackend,
      visualTokenBudget: visualTokenBudget, maxTokens: maxTokens,
      minimumDeviceRAM: minimumDeviceRAM, enableBenchmark: enableBenchmark,
      speculativeDecoding: speculativeDecoding, sampler: sampler, prewarm: prewarm)
  }

  private init(
    model: LiteRTModel?, modalities: Modality, modelPath: String,
    engine: Engine, conversation: Conversation, conversationConfig: ConversationConfig
  ) {
    self.model = model
    self.modalities = modalities
    self.modelPath = modelPath
    self.engine = engine
    self.conversation = conversation
    self.conversationConfig = conversationConfig
  }

  // MARK: Generation

  /// Stream a response token-by-token. Each yielded value is the next text delta.
  ///
  /// - Parameters:
  ///   - prompt: The user's text.
  ///   - image: Optional image bytes (PNG/JPEG). Requires the vision tower.
  ///   - images: Optional multiple images (e.g. sampled video frames). Each costs
  ///     visual tokens — keep the count small. Requires the vision tower.
  ///   - audio: Optional audio input. Requires the audio tower.
  ///   - documents: Optional PDF/TXT/EML context. Documents are sent as text.
  public func stream(
    _ prompt: String, image: Data? = nil, images: [Data] = [], audio: AudioInput? = nil,
    documents: [LiteRTDocument] = []
  ) -> AsyncThrowingStream<String, Error> {
    return AsyncThrowingStream { continuation in
      let task = Task {
        do {
          var contents: [Content] = [.text(Self.prompt(prompt, with: documents))]
          if let image { contents.append(.imageData(image)) }
          contents.append(contentsOf: images.map { .imageData($0) })
          if let audio { contents.append(audio.content) }
          let message = Message(contents: contents)
          let activeConversation: Conversation
          if documents.isEmpty, let conversation {
            activeConversation = conversation
          } else if let conversation, !didSendDocumentTurn {
            activeConversation = conversation
            didSendDocumentTurn = true
          } else {
            conversation = nil
            let freshConversation = try await engine.createConversation(with: conversationConfig)
            conversation = freshConversation
            activeConversation = freshConversation
            didSendDocumentTurn = true
          }

          for try await chunk in activeConversation.sendMessageStream(message) {
            let delta = chunk.toString
            if !delta.isEmpty { continuation.yield(delta) }
          }
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  /// Generate a full response (non-streaming convenience).
  public func respond(
    _ prompt: String, image: Data? = nil, images: [Data] = [], audio: AudioInput? = nil,
    documents: [LiteRTDocument] = []
  ) async throws -> String {
    var out = ""
    for try await delta in stream(prompt, image: image, images: images, audio: audio, documents: documents) {
      out += delta
    }
    return out
  }

  /// Cancel the in-flight generation, if any.
  public func cancel() throws { try conversation?.cancel() }

  /// Reset chat history while keeping the loaded model/engine resident.
  public func resetConversation() async throws {
    try conversation?.cancel()
    conversation = try await engine.createConversation(with: conversationConfig)
    didSendDocumentTurn = false
  }

  /// Engine-measured benchmark info for the most recent turn (prefill/decode
  /// tokens-per-second, time-to-first-token). Requires `enableBenchmark: true`
  /// at construction.
  public func lastBenchmark() throws -> BenchmarkInfo {
    guard let conversation else { throw LiteRTChatError.conversationUnavailable }
    return try conversation.getBenchmarkInfo()
  }

  private static func prompt(_ prompt: String, with documents: [LiteRTDocument]) -> String {
    let documentContext = documents.liteRTPromptContext
    guard !documentContext.isEmpty else { return prompt }

    let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    let userPrompt = trimmedPrompt.isEmpty ? "Use the document context to answer." : prompt
    return """
      Active document context for this conversation turn:

      \(documentContext)

      Answer the user's prompt using the active document context above when it is relevant.

      User prompt:
      \(userPrompt)
      """
  }

  /// Current resident memory footprint of the app process, in bytes — the
  /// jetsam-relevant `phys_footprint`. Handy for verifying you're under the
  /// device's memory ceiling while a model is loaded.
  public static func memoryFootprintBytes() -> Int64 { processFootprintBytes() }

  // MARK: Model management

  /// Ensure the model file is present locally, downloading it if needed, and
  /// return its absolute path. Useful to pre-download before constructing a chat.
  @discardableResult
  public static func ensureModel(
    _ model: LiteRTModel,
    storageDirectory: URL? = nil,
    onProgress: (@Sendable (ModelDownloader.Progress) -> Void)? = nil
  ) async throws -> String {
    let dir = try storageDirectory ?? defaultStorageDirectory()
    let dest = dir.appendingPathComponent(model.fileName)
    try await ModelDownloader.shared.download(
      from: model.downloadURL, to: dest,
      expectedBytes: model.approximateBytes, onProgress: onProgress)
    return dest.path
  }

  /// The default on-device storage location for models.
  public static func defaultStorageDirectory() throws -> URL {
    let base = try FileManager.default.url(
      for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    let dir = base.appendingPathComponent("LiteRTModels", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }
}

/// Errors specific to Easy mode.
public enum LiteRTChatError: Error, LocalizedError {
  /// The device does not have enough RAM to load this model safely.
  case insufficientMemory(haveBytes: Int64, needBytes: Int64)
  /// `init(modelFileURL:)` was given a path with no file at it.
  case modelFileNotFound(URL)
  /// The conversation has not been initialized or has already been released.
  case conversationUnavailable

  public var errorDescription: String? {
    switch self {
    case .insufficientMemory(let have, let need):
      let haveStr = ByteCountFormatter.string(fromByteCount: have, countStyle: .memory)
      let needStr = ByteCountFormatter.string(fromByteCount: need, countStyle: .memory)
      return
        "This device has \(haveStr) of RAM; this model needs at least \(needStr). "
        + "Pass allowUnsafeMemory: true to try anyway."
    case .modelFileNotFound(let url):
      return "No model file found at \(url.path)."
    case .conversationUnavailable:
      return "The chat conversation is not available."
    }
  }
}
