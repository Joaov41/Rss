import SwiftUI
import ImageIO
import UniformTypeIdentifiers
import LiteRTFoundation

@main
struct LiteRTDemoMacApp: App {
  var body: some Scene {
    WindowGroup {
      MacChatView()
        .frame(minWidth: 840, minHeight: 720)
    }
  }
}

private struct MacChatMessage: Identifiable {
  enum Role { case user, assistant }
  let id = UUID()
  let role: Role
  var text: String
  var image: Data?
  var videoThumb: Data?
  var documentName: String?
  var hasAudio = false
  var stats: String?
}

private struct MacChatView: View {
  @StateObject private var vm = MacChatViewModel()
  @State private var input = ""
  @State private var showImageImporter = false
  @State private var showVideoImporter = false
  @State private var showAudioImporter = false
  @State private var showDocumentImporter = false
  private let supportsNativeMultimodal = false

  var body: some View {
    NavigationSplitView {
      sidebar
        .navigationTitle("LiteRT")
    } detail: {
      VStack(spacing: 0) {
        header
        Divider()
        messageList
        inputBar
      }
      .frame(maxWidth: 920)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(Color(nsColor: .textBackgroundColor))
    }
    .navigationSplitViewStyle(.balanced)
    .task { await vm.loadIfNeeded() }
    .fileImporter(isPresented: $showImageImporter, allowedContentTypes: [.image]) {
      result in
      if case .success(let url) = result {
        Task { await vm.attachImage(url) }
      }
    }
    .fileImporter(isPresented: $showVideoImporter, allowedContentTypes: [.movie, .video]) {
      result in
      if case .success(let url) = result {
        Task { await vm.attachVideo(url) }
      }
    }
    .fileImporter(isPresented: $showAudioImporter, allowedContentTypes: [.audio]) {
      result in
      if case .success(let url) = result {
        Task { await vm.attachAudio(url) }
      }
    }
    .fileImporter(isPresented: $showDocumentImporter, allowedContentTypes: Self.documentContentTypes) {
      result in
      if case .success(let url) = result {
        Task { await vm.attachDocument(url) }
      }
    }
  }

  private var sidebar: some View {
    List {
      Section("Model") {
        Label("Gemma 4 E2B", systemImage: "cpu")
        statusRow
        Button {
          Task { await vm.newChat() }
        } label: {
          Label("New Chat", systemImage: "square.and.pencil")
        }
        .disabled(!vm.isReady || vm.isGenerating)
      }

      Section("Add") {
        Button {
          showImageImporter = true
        } label: {
          Label("Photo (iOS target)", systemImage: "photo.on.rectangle")
        }
        .disabled(!supportsNativeMultimodal || !vm.isReady || vm.isGenerating)
        .help("The native macOS LiteRT runtime is currently text/document-only.")

        Button {
          showVideoImporter = true
        } label: {
          Label("Video (iOS target)", systemImage: "video")
        }
        .disabled(!supportsNativeMultimodal || !vm.isReady || vm.isGenerating)
        .help("The native macOS LiteRT runtime is currently text/document-only.")

        Button {
          showAudioImporter = true
        } label: {
          Label("Audio (iOS target)", systemImage: "waveform")
        }
        .disabled(!supportsNativeMultimodal || !vm.isReady || vm.isGenerating)
        .help("The native macOS LiteRT runtime is currently text/document-only.")

        Button {
          showDocumentImporter = true
        } label: {
          Label("Document", systemImage: "doc.text")
        }
        .disabled(!vm.isReady || vm.isGenerating)
      }

      Section("Attached") {
        if !vm.hasOneShotAttachment {
          Label("None", systemImage: "paperclip")
            .foregroundStyle(.secondary)
        }
        if vm.attachedImage != nil {
          removableRow("Photo", system: "photo") { vm.attachedImage = nil }
        }
        if vm.attachedVideoThumb != nil {
          removableRow("Video", system: "video.fill") { vm.clearVideo() }
        }
        if vm.attachedAudioURL != nil {
          removableRow("Audio", system: "waveform") { vm.clearAudio() }
        }
      }

      Section("Active Context") {
        if vm.activeDocuments.isEmpty {
          Label("None", systemImage: "paperclip")
            .foregroundStyle(.secondary)
        }
        ForEach(Array(vm.activeDocuments.enumerated()), id: \.offset) { _, document in
          removableRow(document.name ?? "Document", system: "text.document") {
            vm.removeDocument(document)
          }
        }
      }
    }
    .listStyle(.sidebar)
  }

  private func removableRow(_ title: String, system: String, remove: @escaping () -> Void) -> some View {
    HStack {
      Label(title, systemImage: system)
        .lineLimit(1)
        .truncationMode(.middle)
      Spacer()
      Button(action: remove) {
        Image(systemName: "xmark.circle.fill")
      }
      .buttonStyle(.plain)
      .foregroundStyle(.secondary)
    }
  }

  private var statusRow: some View {
    HStack {
      switch vm.phase {
      case .idle:
        Image(systemName: "circle").foregroundStyle(.secondary)
        Text("Idle")
      case .loading(let fraction):
        ProgressView().controlSize(.small)
        Text("Loading \(Int(fraction * 100))%")
      case .ready:
        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        Text("Ready")
      case .error:
        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
        Text("Error")
      }
    }
  }

  private var header: some View {
    HStack(spacing: 8) {
      Image(systemName: "sparkles").foregroundStyle(.tint)
      Text("Gemma 4 E2B").font(.headline)
      Spacer()
      Button {
        Task { await vm.newChat() }
      } label: {
        Image(systemName: "square.and.pencil")
      }
      .buttonStyle(.borderless)
      .disabled(!vm.isReady || vm.isGenerating)
      .help("New Chat")
      statusRow.font(.callout)
    }
    .padding()
  }

  private var messageList: some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(spacing: 12) {
          ForEach(vm.messages) { message in
            MacMessageBubble(message: message)
              .id(message.id)
          }
        }
        .padding()
      }
      .onChange(of: vm.scrollTick) {
        if let last = vm.messages.last?.id {
          withAnimation { proxy.scrollTo(last, anchor: .bottom) }
        }
      }
    }
  }

  private var inputBar: some View {
    VStack(spacing: 8) {
      if vm.hasOneShotAttachment || !vm.activeDocuments.isEmpty || vm.attachmentError != nil {
        HStack(spacing: 8) {
          if vm.attachedImage != nil {
            chip("Photo", system: "photo") { vm.attachedImage = nil }
          }
          if vm.attachedVideoThumb != nil {
            chip("Video", system: "video.fill") { vm.clearVideo() }
          }
          if vm.attachedAudioURL != nil {
            chip("Audio", system: "waveform") { vm.clearAudio() }
          }
          ForEach(Array(vm.activeDocuments.enumerated()), id: \.offset) { _, document in
            chip(document.name ?? "Document", system: "text.document") {
              vm.removeDocument(document)
            }
          }
          if let error = vm.attachmentError {
            Text(error).font(.caption).foregroundStyle(.red).lineLimit(2)
          }
          Spacer()
        }
      }

      HStack(spacing: 10) {
        Button {
          showImageImporter = true
        } label: {
          Image(systemName: "photo.on.rectangle")
        }
        .disabled(!supportsNativeMultimodal || !vm.isReady || vm.isGenerating)
        .help("Photo is available in the iOS target.")

        Button {
          showVideoImporter = true
        } label: {
          Image(systemName: "video")
        }
        .disabled(!supportsNativeMultimodal || !vm.isReady || vm.isGenerating)
        .help("Video is available in the iOS target.")

        Button {
          showAudioImporter = true
        } label: {
          Image(systemName: "waveform")
        }
        .disabled(!supportsNativeMultimodal || !vm.isReady || vm.isGenerating)
        .help("Audio is available in the iOS target.")

        Button {
          showDocumentImporter = true
        } label: {
          Image(systemName: "doc.text")
        }
        .disabled(!vm.isReady || vm.isGenerating)

        TextField("Message", text: $input, axis: .vertical)
          .textFieldStyle(.roundedBorder)
          .lineLimit(1...5)

        Button {
          let text = input
          input = ""
          Task { await vm.send(text) }
        } label: {
          Image(systemName: "arrow.up.circle.fill")
            .font(.title2)
        }
        .disabled(!vm.canSend(input))
      }
    }
    .padding()
  }

  private func chip(_ title: String, system: String, remove: @escaping () -> Void) -> some View {
    HStack(spacing: 6) {
      Image(systemName: system)
      Text(title).lineLimit(1).truncationMode(.middle).frame(maxWidth: 220)
      Button(action: remove) {
        Image(systemName: "xmark.circle.fill")
      }
      .buttonStyle(.plain)
      .foregroundStyle(.secondary)
    }
    .font(.caption)
    .padding(.horizontal, 8)
    .padding(.vertical, 5)
    .background(Color(nsColor: .controlBackgroundColor))
    .clipShape(Capsule())
  }

  private static var documentContentTypes: [UTType] {
    var types: [UTType] = [.pdf, .plainText, .text, .utf8PlainText, .utf16PlainText]
    if let eml = UTType(filenameExtension: "eml") { types.append(eml) }
    return types
  }
}

private struct MacMessageBubble: View {
  let message: MacChatMessage

  var body: some View {
    HStack {
      if message.role == .user { Spacer(minLength: 80) }
      VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 4) {
        if message.image != nil {
          Label("Photo", systemImage: "photo").font(.caption).foregroundStyle(.secondary)
        }
        if message.videoThumb != nil {
          Label("Video", systemImage: "video.fill").font(.caption).foregroundStyle(.secondary)
        }
        if message.hasAudio {
          Label("Audio", systemImage: "waveform").font(.caption).foregroundStyle(.secondary)
        }
        if let documentName = message.documentName {
          Label(documentName, systemImage: "doc.text")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Text(message.text)
          .padding(.horizontal, 12)
          .padding(.vertical, 8)
          .background(message.role == .user ? Color.accentColor : Color(nsColor: .controlBackgroundColor))
          .foregroundStyle(message.role == .user ? .white : .primary)
          .clipShape(RoundedRectangle(cornerRadius: 14))
          .textSelection(.enabled)
        if let stats = message.stats {
          Text(stats)
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
      }
      if message.role == .assistant { Spacer(minLength: 80) }
    }
  }
}

@MainActor
private final class MacChatViewModel: ObservableObject {
  enum Phase: Equatable { case idle, loading(Double), ready, error(String) }

  @Published var phase: Phase = .idle
  @Published var messages: [MacChatMessage] = []
  @Published var attachedImage: Data?
  @Published var attachedVideoFrames: [Data]?
  @Published var attachedVideoThumb: Data?
  @Published var attachedAudioURL: URL?
  @Published var activeDocuments: [LiteRTDocument] = []
  @Published var attachmentError: String?
  @Published var isGenerating = false
  @Published var scrollTick = 0

  private var chat: LiteRTChat?

  var isReady: Bool {
    if case .ready = phase { return true }
    return false
  }

  var hasOneShotAttachment: Bool {
    attachedImage != nil || attachedVideoThumb != nil || attachedAudioURL != nil
  }

  func canSend(_ text: String) -> Bool {
    isReady && !isGenerating
      && (!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        || hasOneShotAttachment || !activeDocuments.isEmpty)
  }

  func newChat() async {
    guard !isGenerating else { return }
    messages = []
    attachedImage = nil
    clearVideo()
    clearAudio()
    activeDocuments = []
    attachmentError = nil
    try? await chat?.resetConversation()
    scrollTick += 1
  }

  func loadIfNeeded() async {
    guard chat == nil, case .idle = phase else { return }
    phase = .loading(0)
    let onProgress: @Sendable (ModelDownloader.Progress) -> Void = { [weak self] progress in
      Task { @MainActor in
        if let self, case .loading = self.phase {
          self.phase = .loading(progress.fraction)
        }
      }
    }

    do {
      chat = try await LiteRTChat(
        .gemma4_E2B,
        modalities: [],
        enableBenchmark: true,
        prewarm: true,
        onDownloadProgress: onProgress)
      phase = .ready
    } catch {
      phase = .error(error.localizedDescription)
    }
  }

  func attachImage(_ url: URL) async {
    attachmentError = nil
    let granted = url.startAccessingSecurityScopedResource()
    defer {
      if granted { url.stopAccessingSecurityScopedResource() }
    }
    do {
      attachedImage = try MacImageLoader.pngData(from: url)
    } catch {
      attachmentError = error.localizedDescription
    }
  }

  func attachVideo(_ url: URL) async {
    attachmentError = nil
    let granted = url.startAccessingSecurityScopedResource()
    defer {
      if granted { url.stopAccessingSecurityScopedResource() }
    }
    do {
      let copy = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension(url.pathExtension.isEmpty ? "mov" : url.pathExtension)
      try? FileManager.default.removeItem(at: copy)
      try FileManager.default.copyItem(at: url, to: copy)
      let frames = try await VideoFrameSampler.sampleFrames(from: copy, count: 4)
      try? FileManager.default.removeItem(at: copy)
      guard !frames.isEmpty else {
        attachmentError = "Could not sample frames from video."
        return
      }
      attachedVideoFrames = frames
      attachedVideoThumb = frames.first
    } catch {
      attachmentError = error.localizedDescription
    }
  }

  func attachAudio(_ url: URL) async {
    attachmentError = nil
    let granted = url.startAccessingSecurityScopedResource()
    defer {
      if granted { url.stopAccessingSecurityScopedResource() }
    }
    do {
      let copy = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension(url.pathExtension.isEmpty ? "wav" : url.pathExtension)
      try? FileManager.default.removeItem(at: copy)
      try FileManager.default.copyItem(at: url, to: copy)
      attachedAudioURL = copy
    } catch {
      attachmentError = error.localizedDescription
    }
  }

  func clearVideo() {
    attachedVideoFrames = nil
    attachedVideoThumb = nil
  }

  func clearAudio() {
    if let url = attachedAudioURL {
      try? FileManager.default.removeItem(at: url)
    }
    attachedAudioURL = nil
  }

  func attachDocument(_ url: URL) async {
    attachmentError = nil
    let granted = url.startAccessingSecurityScopedResource()
    defer {
      if granted { url.stopAccessingSecurityScopedResource() }
    }

    do {
      let document = try await Task.detached {
        try LiteRTDocument(fileURL: url)
      }.value
      activeDocuments.removeAll { existing in
        existing.name == document.name || existing == document
      }
      activeDocuments.append(document)
    } catch {
      attachmentError = error.localizedDescription
    }
  }

  func removeDocument(_ document: LiteRTDocument) {
    activeDocuments.removeAll { $0 == document }
  }

  func send(_ text: String) async {
    let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let chat, canSend(prompt) else { return }

    let image = attachedImage
    let frames = attachedVideoFrames
    let videoThumb = attachedVideoThumb
    let audioURL = attachedAudioURL
    let documents = activeDocuments
    let displayPrompt = prompt.isEmpty
      ? defaultPrompt(image: image, frames: frames, audio: audioURL, documents: documents)
      : prompt
    let modelPrompt = documents.isEmpty ? displayPrompt : documentPrompt(displayPrompt)
    isGenerating = true
    defer { isGenerating = false }

    attachedImage = nil
    clearVideo()
    attachedAudioURL = nil
    attachmentError = nil

    messages.append(
      MacChatMessage(
        role: .user,
        text: displayPrompt,
        image: image,
        videoThumb: videoThumb,
        documentName: documents.first?.name,
        hasAudio: audioURL != nil))
    scrollTick += 1

    let assistantIndex = messages.count
    messages.append(MacChatMessage(role: .assistant, text: ""))

    let start = Date()
    let audio: AudioInput? = audioURL.map { .file($0) }
    do {
      for try await delta in chat.stream(
        modelPrompt, image: image, images: frames ?? [], audio: audio, documents: documents) {
        messages[assistantIndex].text += delta
        scrollTick += 1
      }
      if documents.isEmpty, let benchmark = try? chat.lastBenchmark() {
        messages[assistantIndex].stats = String(
          format: "%.0f tok/s", benchmark.lastDecodeTokensPerSecond)
      } else {
        messages[assistantIndex].stats = String(
          format: "%.1fs", Date().timeIntervalSince(start))
      }
    } catch {
      messages[assistantIndex].text += "\n[error] \(error.localizedDescription)"
    }
    scrollTick += 1
  }

  private func defaultPrompt(
    image: Data?, frames: [Data]?, audio: URL?, documents: [LiteRTDocument]
  ) -> String {
    if audio != nil {
      return "Listen to this audio and respond to it. If it asks a question, answer it."
    }
    if frames != nil {
      return "These images are frames sampled from a video in chronological order. Describe what is happening in the video."
    }
    if image != nil { return "What is in this photo?" }
    if !documents.isEmpty { return "Summarize" }
    return ""
  }

  private func documentPrompt(_ currentQuestion: String) -> String {
    let recent = recentChatContext()
    guard !recent.isEmpty else { return currentQuestion }
    return """
      Recent chat context:
      \(recent)

      Current question:
      \(currentQuestion)
      """
  }

  private func recentChatContext() -> String {
    messages.suffix(4).compactMap { message in
      let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !text.isEmpty else { return nil }
      let role = message.role == .user ? "User" : "Assistant"
      return "\(role): \(text.prefix(500))"
    }
    .joined(separator: "\n")
  }
}

private enum MacImageLoader {
  static func pngData(from url: URL, maxDimension: Int = 1024) throws -> Data {
    let data = try Data(contentsOf: url)
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
      throw CocoaError(.fileReadCorruptFile)
    }
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceShouldCacheImmediately: true,
      kCGImageSourceThumbnailMaxPixelSize: maxDimension,
    ]
    guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
      throw CocoaError(.fileReadCorruptFile)
    }
    let output = NSMutableData()
    guard
      let destination = CGImageDestinationCreateWithData(
        output, UTType.png.identifier as CFString, 1, nil)
    else {
      throw CocoaError(.fileWriteUnknown)
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
      throw CocoaError(.fileWriteUnknown)
    }
    return output as Data
  }
}
