// LiteRTDemo — conversational chat UI (ChatGPT / Claude style).
//
// A scrolling message list with user/assistant bubbles, attachments (photo,
// microphone audio, and video — sampled to frames), a bottom input bar, and
// live token streaming. Multi-turn over one LiteRTChat conversation (Gemma 4
// E2B, text + image + audio, Metal GPU).

import SwiftUI
import UIKit
import PhotosUI
import CoreTransferable
import UniformTypeIdentifiers
import LiteRTFoundation

// MARK: - Models

struct ChatMessage: Identifiable {
  enum Role { case user, assistant }
  let id = UUID()
  let role: Role
  var text: String
  var image: Data? = nil
  var videoThumb: Data? = nil
  var documentName: String? = nil
  var hasAudio: Bool = false
  var stats: String? = nil
}

/// A video pulled from the photo library as a temp-file URL (so we can sample
/// frames without loading the whole clip into memory).
struct Movie: Transferable {
  let url: URL
  static var transferRepresentation: some TransferRepresentation {
    FileRepresentation(contentType: .movie) { movie in SentTransferredFile(movie.url) } importing: {
      received in
      let copy = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString + ".mov")
      try? FileManager.default.removeItem(at: copy)
      try FileManager.default.copyItem(at: received.file, to: copy)
      return Movie(url: copy)
    }
  }
}

// MARK: - Theme

private enum MediaKind: CaseIterable {
  case photo, video, audio, document

  var title: String {
    switch self {
    case .photo: return "Photo"
    case .video: return "Video"
    case .audio: return "Audio"
    case .document: return "Document"
    }
  }

  var system: String {
    switch self {
    case .photo: return "photo.on.rectangle"
    case .video: return "video"
    case .audio: return "waveform"
    case .document: return "doc.text"
    }
  }

  var tint: Color {
    switch self {
    case .photo: return Color(red: 0.38, green: 0.62, blue: 0.98)
    case .video: return Color(red: 0.68, green: 0.48, blue: 0.98)
    case .audio: return Color(red: 0.36, green: 0.82, blue: 0.58)
    case .document: return Color(red: 0.96, green: 0.78, blue: 0.28)
    }
  }

  var softFill: Color { tint.opacity(0.16) }
}

private enum AppStyle {
  private static func dynamic(light: UIColor, dark: UIColor) -> Color {
    Color(uiColor: UIColor { traits in
      traits.userInterfaceStyle == .dark ? dark : light
    })
  }

  static let background = dynamic(
    light: UIColor(red: 0.82, green: 0.86, blue: 0.91, alpha: 1),
    dark: UIColor(red: 0.04, green: 0.04, blue: 0.055, alpha: 1))
  static let canvas = dynamic(
    light: UIColor(red: 0.84, green: 0.87, blue: 0.92, alpha: 1),
    dark: UIColor(red: 0.04, green: 0.04, blue: 0.055, alpha: 1))
  static let sidebar = dynamic(
    light: UIColor(red: 0.78, green: 0.82, blue: 0.88, alpha: 0.94),
    dark: UIColor(red: 0.055, green: 0.055, blue: 0.07, alpha: 0.96))
  static let surface = dynamic(
    light: UIColor(red: 0.86, green: 0.89, blue: 0.94, alpha: 0.92),
    dark: UIColor(red: 0.11, green: 0.11, blue: 0.14, alpha: 1))
  static let surfaceMuted = dynamic(
    light: UIColor(red: 0.80, green: 0.84, blue: 0.90, alpha: 1),
    dark: UIColor(red: 0.11, green: 0.11, blue: 0.14, alpha: 1))
  static let glassFill = dynamic(
    light: UIColor(red: 0.70, green: 0.75, blue: 0.84, alpha: 0.42),
    dark: UIColor(red: 0.11, green: 0.11, blue: 0.14, alpha: 0.92))
  static let line = dynamic(
    light: UIColor(red: 0.28, green: 0.34, blue: 0.46, alpha: 0.12),
    dark: UIColor.white.withAlphaComponent(0.08))
  static let lineStrong = dynamic(
    light: UIColor(red: 0.28, green: 0.34, blue: 0.46, alpha: 0.18),
    dark: UIColor.white.withAlphaComponent(0.12))
  static let ink = dynamic(
    light: UIColor(red: 0.12, green: 0.14, blue: 0.20, alpha: 1),
    dark: UIColor(red: 0.96, green: 0.96, blue: 0.94, alpha: 1))
  static let muted = dynamic(
    light: UIColor(red: 0.38, green: 0.42, blue: 0.52, alpha: 1),
    dark: UIColor(red: 0.62, green: 0.63, blue: 0.67, alpha: 1))
  static let faint = dynamic(
    light: UIColor(red: 0.52, green: 0.56, blue: 0.64, alpha: 1),
    dark: UIColor(red: 0.44, green: 0.45, blue: 0.48, alpha: 1))
  static let accent = Color(red: 0.95, green: 0.58, blue: 0.18)
  static let accentSoft = dynamic(
    light: UIColor(red: 0.82, green: 0.86, blue: 0.95, alpha: 1),
    dark: UIColor(red: 0.28, green: 0.17, blue: 0.08, alpha: 1))
  static let accentGradient = LinearGradient(
    colors: [Color(red: 0.98, green: 0.52, blue: 0.14), Color(red: 0.88, green: 0.28, blue: 0.52)],
    startPoint: .topLeading,
    endPoint: .bottomTrailing)
  static let heroGlow = RadialGradient(
    colors: [Color(red: 0.95, green: 0.45, blue: 0.2).opacity(0.55), .clear],
    center: .center,
    startRadius: 8,
    endRadius: 80)
  static let success = Color(red: 0.22, green: 0.82, blue: 0.48)
  static let danger = Color(red: 0.78, green: 0.16, blue: 0.12)
  static let errorFill = dynamic(
    light: UIColor(red: 1.0, green: 0.92, blue: 0.90, alpha: 1),
    dark: UIColor(red: 0.28, green: 0.12, blue: 0.11, alpha: 1))
  static let softShadow = dynamic(
    light: UIColor.black.withAlphaComponent(0.055),
    dark: UIColor.black.withAlphaComponent(0.45))
  static let glow = dynamic(
    light: UIColor(red: 0.34, green: 0.44, blue: 0.72, alpha: 0.22),
    dark: UIColor(red: 0.55, green: 0.28, blue: 0.72, alpha: 0.35))
  static let themePurple = Color(red: 0.55, green: 0.36, blue: 0.86)
  static let themePurpleFill = Color(red: 0.20, green: 0.12, blue: 0.34)
  static let themePurpleBorder = Color(red: 0.48, green: 0.30, blue: 0.72)
  static let themePurpleGlow = Color(red: 0.55, green: 0.28, blue: 0.72)
}

private struct StudioBackdrop: View {
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    ZStack {
      AppStyle.background
      if colorScheme == .dark {
        RadialGradient(
          colors: [AppStyle.themePurpleGlow.opacity(0.22), .clear],
          center: UnitPoint(x: 0.55, y: 0.42),
          startRadius: 20,
          endRadius: 360)
        RadialGradient(
          colors: [Color(red: 0.95, green: 0.42, blue: 0.18).opacity(0.08), .clear],
          center: UnitPoint(x: 0.82, y: 0.92),
          startRadius: 10,
          endRadius: 280)
        RadialGradient(
          colors: [Color(red: 0.18, green: 0.14, blue: 0.32).opacity(0.55), .clear],
          center: UnitPoint(x: 0.12, y: 0.08),
          startRadius: 10,
          endRadius: 320)
      } else {
        LinearGradient(
          colors: [
            Color(red: 0.72, green: 0.78, blue: 0.90).opacity(0.55),
            Color(red: 0.82, green: 0.86, blue: 0.92).opacity(0.2),
          ],
          startPoint: .topLeading,
          endPoint: .bottomTrailing)
        RadialGradient(
          colors: [Color(red: 0.38, green: 0.52, blue: 0.82).opacity(0.28), .clear],
          center: UnitPoint(x: 0.52, y: 0.44),
          startRadius: 20,
          endRadius: 380)
        RadialGradient(
          colors: [AppStyle.themePurpleGlow.opacity(0.16), .clear],
          center: UnitPoint(x: 0.78, y: 0.82),
          startRadius: 10,
          endRadius: 340)
        RadialGradient(
          colors: [Color(red: 0.95, green: 0.48, blue: 0.28).opacity(0.10), .clear],
          center: UnitPoint(x: 0.92, y: 0.95),
          startRadius: 10,
          endRadius: 280)
        RadialGradient(
          colors: [Color(red: 0.28, green: 0.36, blue: 0.58).opacity(0.14), .clear],
          center: UnitPoint(x: 0.08, y: 0.12),
          startRadius: 10,
          endRadius: 300)
      }
    }
    .ignoresSafeArea()
  }
}

private extension View {
  @ViewBuilder
  func liteGlass(cornerRadius: CGFloat = 12, tint: Color = .clear, interactive: Bool = false) -> some View {
    if #available(iOS 26.0, *) {
      if interactive {
        self.glassEffect(.regular.tint(tint).interactive(), in: .rect(cornerRadius: cornerRadius))
      } else {
        self.glassEffect(.regular.tint(tint), in: .rect(cornerRadius: cornerRadius))
      }
    } else {
      self
        .background(AppStyle.glassFill, in: RoundedRectangle(cornerRadius: cornerRadius))
        .background(.ultraThinMaterial.opacity(0.55), in: RoundedRectangle(cornerRadius: cornerRadius))
        .overlay(
          RoundedRectangle(cornerRadius: cornerRadius)
            .stroke(
              LinearGradient(
                colors: [
                  Color(red: 0.55, green: 0.62, blue: 0.78).opacity(0.28),
                  Color(red: 0.72, green: 0.76, blue: 0.86).opacity(0.12),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing),
              lineWidth: 1))
    }
  }

  func studioPanel(cornerRadius: CGFloat = 14) -> some View {
    background(AppStyle.glassFill, in: RoundedRectangle(cornerRadius: cornerRadius))
      .overlay(
        RoundedRectangle(cornerRadius: cornerRadius)
          .stroke(AppStyle.lineStrong, lineWidth: 1))
  }
}

private struct BrandMark: View {
  var size: CGFloat = 42
  var iconSize: CGFloat = 16
  var cornerRadius: CGFloat = 12
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    ZStack {
      if colorScheme == .dark {
        RoundedRectangle(cornerRadius: cornerRadius)
          .fill(AppStyle.accentGradient)
        RoundedRectangle(cornerRadius: cornerRadius)
          .stroke(Color.white.opacity(0.2), lineWidth: 1)
        Image(systemName: "sparkles")
          .font(.system(size: iconSize, weight: .semibold))
          .foregroundStyle(.white)
      } else {
        RoundedRectangle(cornerRadius: cornerRadius)
          .fill(AppStyle.glassFill)
        RoundedRectangle(cornerRadius: cornerRadius)
          .stroke(AppStyle.lineStrong, lineWidth: 1)
        Image(systemName: "sparkles")
          .font(.system(size: iconSize, weight: .semibold))
          .foregroundStyle(Color(red: 0.28, green: 0.34, blue: 0.48))
      }
    }
    .frame(width: size, height: size)
    .shadow(color: colorScheme == .dark ? AppStyle.themePurpleGlow.opacity(0.35) : AppStyle.glow, radius: 10, y: 4)
  }
}

// MARK: - Root

struct ContentView: View {
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  @AppStorage("liteRTDemo.prefersDarkMode") private var prefersDarkMode = false
  @StateObject private var vm = ChatViewModel()
  @State private var photoItem: PhotosPickerItem?
  @State private var videoItem: PhotosPickerItem?
  @State private var showDocumentImporter = false
  @State private var input = ""
  @State private var showFM = false
  @State private var showModelPicker = false
  @State private var inputFocused = false
  @State private var didRequestPadLandscape = false

  var body: some View {
    chatStack
  }

  // The Easy-mode chat, plus an optional "FM API" cover. Entering FM mode frees
  // the Easy engine (`releaseEngine`) and FM builds its own on demand, so only
  // one multi-GB model is ever resident; leaving it reloads the Easy chat.
  @ViewBuilder private var chatStack: some View {
    #if canImport(FoundationModels)
    if #available(iOS 27.0, macOS 27.0, *) {
      baseLayout.fullScreenCover(isPresented: $showFM, onDismiss: {
        Task {
          await LiteRTLanguageModel.releaseCachedEngines()  // free FM engine first
          await vm.loadIfNeeded()                           // then reload Easy chat
        }
      }) { FMModeView() }
    } else {
      baseLayout
    }
    #else
    baseLayout
    #endif
  }

  private var baseLayout: some View {
    GeometryReader { proxy in
      let width = proxy.size.width
      let isWide = isPadStyleEnvironment && horizontalSizeClass == .regular && width >= 760

      Group {
        if isWide {
          regularLayout(width: width)
        } else {
          compactLayout
        }
      }
      .frame(width: proxy.size.width, height: proxy.size.height)
    }
    .background { StudioBackdrop() }
    .preferredColorScheme(prefersDarkMode ? .dark : .light)
    .animation(.easeInOut(duration: 0.25), value: prefersDarkMode)
    .onAppear { requestPadLandscapeIfNeeded() }
    .task { await vm.loadIfNeeded() }
    .onChange(of: photoItem) { item in Task { await vm.attachPhoto(item) } }
    .onChange(of: videoItem) { item in Task { await vm.attachVideo(item) } }
    .sheet(isPresented: $showModelPicker) { ModelPickerView(vm: vm) }
    .fileImporter(isPresented: $showDocumentImporter, allowedContentTypes: Self.documentContentTypes) {
      result in
      if case .success(let url) = result {
        Task { await vm.attachDocument(url) }
      }
    }
  }

  private var isPadStyleEnvironment: Bool {
    UIDevice.current.userInterfaceIdiom == .pad || ProcessInfo.processInfo.isiOSAppOnMac
  }

  private var usesCompactChrome: Bool {
    !isPadStyleEnvironment && horizontalSizeClass == .compact
  }

  @ViewBuilder private func glassGroup<Content: View>(
    spacing: CGFloat = 8,
    @ViewBuilder content: () -> Content
  ) -> some View {
    if #available(iOS 26.0, *) {
      GlassEffectContainer(spacing: spacing) {
        content()
      }
    } else {
      content()
    }
  }

  private func regularLayout(width: CGFloat) -> some View {
    let showInspector = width >= 1500
    let sidebarWidth = min(max(width * 0.22, 238), showInspector ? 292 : 276)

    return HStack(spacing: 0) {
      workspaceSidebar(showsContext: !showInspector)
        .frame(width: sidebarWidth)

      Divider().overlay(AppStyle.line)

      conversationColumn
        .frame(maxWidth: .infinity, maxHeight: .infinity)

      if showInspector {
        Divider().overlay(AppStyle.line)
        contextInspector
          .frame(width: 260)
      }
    }
    .background(AppStyle.background.opacity(0.001))
  }

  private var compactLayout: some View {
    conversationColumn
  }

  private var conversationColumn: some View {
    VStack(spacing: 0) {
      header
      messageList
    }
    .safeAreaInset(edge: .bottom) { inputBar }
  }

  private func workspaceSidebar(showsContext: Bool) -> some View {
    VStack(spacing: 0) {
      ScrollView {
        VStack(alignment: .leading, spacing: 20) {
          sidebarBrand

          sidebarSection("Appearance") {
            darkModeSidebarToggle
          }

          sidebarSection("Model") {
            Button {
              showModelPicker = true
            } label: {
              SidebarPrimaryRow(
                title: vm.currentModelName,
                subtitle: modelSubtitle,
                system: "cpu",
                trailingSystem: "chevron.up.chevron.down")
            }
            .buttonStyle(.plain)
            .disabled(vm.isGenerating)

            statusRow

            Button {
              Task { await vm.newChat() }
            } label: {
              SidebarCommandRow(title: "New Chat", system: "square.and.pencil")
            }
            .buttonStyle(.plain)
            .disabled(!vm.isReady || vm.isGenerating)

            fmSidebarButton
          }

          sidebarSection("Add") {
            sidebarToolGrid
          }

          sidebarSection("Attached") {
            oneShotAttachmentSidebarRows
          }

          sidebarSection("Active Context") {
            activeContextSidebarRows
          }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 18)
      }
      .scrollIndicators(.hidden)

      sidebarSettingsButton
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
    }
    .background(AppStyle.sidebar)
    .overlay(alignment: .trailing) {
      Rectangle()
        .fill(AppStyle.line)
        .frame(width: 1)
    }
  }

  private var sidebarSettingsButton: some View {
    Button {
      showModelPicker = true
    } label: {
      HStack(spacing: 10) {
        Image(systemName: "gearshape")
          .font(.system(size: 14, weight: .semibold))
          .foregroundStyle(AppStyle.muted)
          .frame(width: 26, height: 26)
        Text("Settings")
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(AppStyle.ink)
        Spacer()
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 10)
      .studioPanel(cornerRadius: 12)
    }
    .buttonStyle(.plain)
  }

  private var sidebarBrand: some View {
    HStack(spacing: 12) {
      BrandMark(size: 42, iconSize: 16)

      VStack(alignment: .leading, spacing: 2) {
        Text("LiteRT")
          .font(.title3.weight(.semibold))
          .foregroundStyle(AppStyle.ink)
        Text("On-device studio")
          .font(.caption)
          .foregroundStyle(AppStyle.muted)
      }
      Spacer()
    }
    .padding(.bottom, 4)
  }

  private var darkModeSidebarToggle: some View {
    Button {
      withAnimation(.easeInOut(duration: 0.25)) {
        prefersDarkMode.toggle()
      }
    } label: {
      HStack(spacing: 10) {
        Image(systemName: prefersDarkMode ? "moon.stars.fill" : "sun.max.fill")
          .font(.system(size: 14, weight: .semibold))
          .foregroundStyle(
            prefersDarkMode ? AppStyle.themePurple : AppStyle.accent)
          .frame(width: 26, height: 26)
        Text(prefersDarkMode ? "Dark mode" : "Light mode")
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(AppStyle.ink)
        Spacer()
        if prefersDarkMode {
          Image(systemName: "checkmark.circle.fill")
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(AppStyle.themePurple)
        }
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 11)
      .background {
        if prefersDarkMode {
          RoundedRectangle(cornerRadius: 12)
            .fill(AppStyle.themePurpleFill)
            .overlay(
              RoundedRectangle(cornerRadius: 12)
                .stroke(AppStyle.themePurpleBorder.opacity(0.55), lineWidth: 1))
            .shadow(color: AppStyle.themePurpleGlow.opacity(0.28), radius: 12, y: 4)
        } else {
          RoundedRectangle(cornerRadius: 12)
            .fill(AppStyle.glassFill)
            .background(.ultraThinMaterial.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
            .overlay(
              RoundedRectangle(cornerRadius: 12)
                .stroke(Color(red: 0.38, green: 0.48, blue: 0.68).opacity(0.22), lineWidth: 1))
        }
      }
    }
    .buttonStyle(.plain)
  }

  private func sidebarSection<Content: View>(
    _ title: String,
    @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(title.uppercased())
        .font(.caption2.weight(.bold))
        .foregroundStyle(AppStyle.faint)
        .tracking(0.7)
      VStack(spacing: 8) {
        content()
      }
    }
  }

  private var sidebarToolGrid: some View {
    glassGroup(spacing: 8) {
      LazyVGrid(
        columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)],
        spacing: 8
      ) {
        PhotosPicker(selection: $photoItem, matching: .images) {
          SidebarToolTile(kind: .photo)
        }
        .buttonStyle(.plain)

        PhotosPicker(selection: $videoItem, matching: .videos) {
          SidebarToolTile(kind: .video)
        }
        .buttonStyle(.plain)

        Button {
          Task { await vm.toggleRecording() }
        } label: {
          SidebarToolTile(
            kind: .audio,
            title: vm.isRecording ? "Stop" : "Audio",
            system: vm.isRecording ? "stop.circle.fill" : "waveform",
            tintOverride: vm.isRecording ? AppStyle.danger : nil)
        }
        .buttonStyle(.plain)

        Button {
          showDocumentImporter = true
        } label: {
          SidebarToolTile(kind: .document)
        }
        .buttonStyle(.plain)
      }
    }
    .disabled(!vm.isReady || vm.isGenerating)
  }

  private var contextInspector: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        sidebarSection("Run") {
          statusRow
          if let stats = vm.messages.reversed().compactMap({ $0.stats }).first {
            InspectorMetric(title: "Last Output", value: stats)
          } else {
            InspectorMetric(title: "Last Output", value: "None")
          }
        }

        sidebarSection("Attached") {
          oneShotAttachmentSidebarRows
        }

        sidebarSection("Active Context") {
          activeContextSidebarRows
        }
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 18)
    }
    .scrollIndicators(.hidden)
    .background(AppStyle.sidebar)
  }

  private var statusRow: some View {
    HStack(spacing: 8) {
      switch vm.phase {
      case .loading(let f):
        ProgressView()
          .controlSize(.small)
          .tint(AppStyle.accent)
        Text("Loading \(Int(f * 100))%")
          .font(.caption.weight(.semibold))
      case .ready:
        Image(systemName: "checkmark.circle.fill").foregroundStyle(AppStyle.success)
        Text("Ready").font(.caption.weight(.semibold))
      case .error:
        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(AppStyle.danger)
        Text("Error").font(.caption.weight(.semibold))
      case .idle:
        Image(systemName: "circle").foregroundStyle(AppStyle.faint)
        Text("Idle").font(.caption.weight(.semibold))
      }
    }
    .foregroundStyle(AppStyle.ink)
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
    .studioPanel(cornerRadius: 12)
  }

  @ViewBuilder private var oneShotAttachmentSidebarRows: some View {
    if vm.attachedImage == nil && vm.attachedVideoThumb == nil && vm.attachedAudioURL == nil
      && vm.attachmentError == nil {
      SidebarEmptyRow(title: "None", system: "paperclip")
    }
    if vm.attachedImage != nil {
      removableSidebarRow("Photo", system: "photo") { vm.attachedImage = nil; photoItem = nil }
    }
    if vm.attachedVideoThumb != nil {
      removableSidebarRow("Video", system: "video.fill") { vm.clearVideo(); videoItem = nil }
    }
    if vm.attachedAudioURL != nil {
      removableSidebarRow("Audio", system: "waveform") { vm.attachedAudioURL = nil }
    }
    if let error = vm.attachmentError {
      Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
    }
  }

  @ViewBuilder private var activeContextSidebarRows: some View {
    if vm.contextDocuments.isEmpty {
      SidebarEmptyRow(title: "None", system: "paperclip")
    }
    ForEach(Array(vm.contextDocuments.enumerated()), id: \.offset) { _, document in
      removableSidebarRow(document.name ?? "Document context", system: "text.document") {
        vm.removeContextDocument(document)
      }
    }
  }

  private func removableSidebarRow(_ title: String, system: String, remove: @escaping () -> Void) -> some View {
    HStack {
      Label(title, systemImage: system)
        .font(.caption.weight(.medium))
        .foregroundStyle(AppStyle.ink)
        .lineLimit(1)
        .truncationMode(.middle)
      Spacer()
      Button(action: remove) {
        Image(systemName: "xmark.circle.fill")
          .font(.caption)
      }
      .buttonStyle(.plain)
      .foregroundStyle(AppStyle.faint)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
    .studioPanel(cornerRadius: 12)
  }

  private var header: some View {
    HStack(spacing: 12) {
      Button {
        showModelPicker = true
      } label: {
        HStack(spacing: 10) {
          BrandMark(size: 34, iconSize: 14, cornerRadius: 10)

          VStack(alignment: .leading, spacing: 1) {
            Text(vm.currentModelName)
              .font(.headline.weight(.semibold))
              .foregroundStyle(AppStyle.ink)
              .lineLimit(1)
            if !usesCompactChrome {
              Text(modelSubtitle)
                .font(.caption2.weight(.medium))
                .foregroundStyle(AppStyle.muted)
                .lineLimit(1)
            }
          }

          Image(systemName: "chevron.down")
            .font(.caption2.bold())
            .foregroundStyle(AppStyle.faint)
        }
      }
      .buttonStyle(.plain)
      .disabled(vm.isGenerating)

      Spacer()

      if !usesCompactChrome {
        headerStatus
      } else if case .ready = vm.phase {
        StatusPill(title: "Ready", color: AppStyle.success)
      }

      darkModeHeaderToggle

      Button {
        Task { await vm.newChat() }
      } label: {
        HeaderIconButton(system: "square.and.pencil")
      }
      .buttonStyle(.plain)
      .disabled(!vm.isReady || vm.isGenerating)

      fmButton
    }
    .padding(.horizontal, horizontalSizeClass == .regular ? 22 : 14)
    .padding(.vertical, 14)
    .background(AppStyle.sidebar.opacity(0.001))
    .overlay(alignment: .bottom) {
      Rectangle()
        .fill(AppStyle.line)
        .frame(height: 1)
    }
  }

  private var darkModeHeaderToggle: some View {
    Button {
      withAnimation(.easeInOut(duration: 0.25)) {
        prefersDarkMode.toggle()
      }
    } label: {
      Image(systemName: prefersDarkMode ? "moon.stars.fill" : "sun.max.fill")
        .font(.system(size: 14, weight: .semibold))
        .foregroundStyle(prefersDarkMode ? AppStyle.themePurple : AppStyle.accent)
        .frame(width: 36, height: 36)
        .studioPanel(cornerRadius: 12)
    }
    .buttonStyle(.plain)
    .accessibilityLabel(prefersDarkMode ? "Switch to light mode" : "Switch to dark mode")
  }

  private var modelSubtitle: String {
    switch vm.source {
    case .bundledE2B: return "Text · Image · Audio"
    case .huggingFace(_, _, let multimodal): return multimodal ? "Custom multimodal" : "Custom text"
    case .localFile(_, let multimodal): return multimodal ? "Local multimodal" : "Local text"
    }
  }

  @ViewBuilder private var headerStatus: some View {
    switch vm.phase {
    case .loading(let f):
      HStack(spacing: 6) {
        ProgressView().controlSize(.small).tint(AppStyle.accent)
        Text("\(Int(f * 100))%")
          .font(.caption.weight(.bold))
      }
      .foregroundStyle(AppStyle.muted)
      .padding(.horizontal, 9)
      .padding(.vertical, 7)
      .background(AppStyle.surfaceMuted)
      .clipShape(RoundedRectangle(cornerRadius: 8))
    case .ready:
      StatusPill(title: "Ready", color: AppStyle.success)
    case .error:
      StatusPill(title: "Error", color: AppStyle.danger)
    case .idle:
      EmptyView()
    }
  }

  // Opens the FM-API demo. Releases the Easy engine before presenting so FM
  // mode's own engine doesn't load alongside it.
  @ViewBuilder private var fmButton: some View {
    #if canImport(FoundationModels)
    if #available(iOS 27.0, macOS 27.0, *) {
      Button {
        vm.releaseEngine()
        showFM = true
      } label: {
        HStack(spacing: 6) {
          Image(systemName: "cpu")
          if usesCompactChrome {
            Text("FM")
          } else {
            Text("FM API")
          }
        }
        .font(.caption.weight(.bold))
        .foregroundStyle(AppStyle.accent)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(AppStyle.surface.opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(AppStyle.accent.opacity(0.65), lineWidth: 1))
      }
      .buttonStyle(.plain)
      .disabled(!vm.isReady || vm.isGenerating)
    }
    #endif
  }

  @ViewBuilder private var fmSidebarButton: some View {
    #if canImport(FoundationModels)
    if #available(iOS 27.0, macOS 27.0, *) {
      Button {
        vm.releaseEngine()
        showFM = true
      } label: {
        SidebarCommandRow(title: "Foundation Models", system: "cpu")
      }
      .buttonStyle(.plain)
      .disabled(!vm.isReady || vm.isGenerating)
    }
    #endif
  }

  private var messageList: some View {
    GeometryReader { geometry in
      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(spacing: 14) {
            if case .error(let message) = vm.phase {
              ErrorBanner(message: message)
            }

            if vm.messages.isEmpty {
              if case .loading(let fraction) = vm.phase {
                LoadingCanvas(progress: fraction, modelName: vm.currentModelName)
              } else {
                EmptyConversationView(modelName: vm.currentModelName)
              }
            }

            ForEach(vm.messages) { MessageBubble(message: $0) }

            if vm.isGenerating, vm.messages.last?.role != .assistant {
              TypingIndicator()
            }

            Color.clear.frame(height: 1).id(bottomID)
          }
          .frame(
            minHeight: vm.messages.isEmpty ? max(geometry.size.height - 36, 0) : 0,
            alignment: vm.messages.isEmpty ? .center : .top
          )
          .padding(.horizontal, horizontalSizeClass == .regular ? 28 : 14)
          .padding(.vertical, 18)
        }
        .background(AppStyle.canvas.opacity(0.001))
        .scrollDismissesKeyboard(.interactively)
        .onChange(of: vm.scrollTick) { _ in
          withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(bottomID, anchor: .bottom) }
        }
      }
    }
  }

  private let bottomID = "bottom"

  private var inputBar: some View {
    VStack(spacing: 8) {
      attachmentChips
      HStack(spacing: 10) {
        composerTools
        composerField
        sendButton
      }
      .padding(.leading, 12)
      .padding(.trailing, 10)
      .padding(.vertical, 10)
      .studioPanel(cornerRadius: 22)
      .shadow(color: AppStyle.softShadow, radius: 20, x: 0, y: 10)
      .disabled(!vm.isReady)
    }
    .padding(.horizontal, usesCompactChrome ? 10 : 24)
    .padding(.bottom, 10)
  }

  private var composerTools: some View {
    HStack(spacing: 6) {
      PhotosPicker(selection: $photoItem, matching: .images) {
        ComposerToolButton(kind: .photo)
      }
      .buttonStyle(.plain)

      PhotosPicker(selection: $videoItem, matching: .videos) {
        ComposerToolButton(kind: .video)
      }
      .buttonStyle(.plain)

      Button { Task { await vm.toggleRecording() } } label: {
        ComposerToolButton(
          kind: .audio,
          system: vm.isRecording ? "stop.circle.fill" : "waveform",
          tintOverride: vm.isRecording ? AppStyle.danger : nil)
      }
      .buttonStyle(.plain)

      Button { showDocumentImporter = true } label: {
        ComposerToolButton(kind: .document)
      }
      .buttonStyle(.plain)
    }
  }

  private var composerField: some View {
    ZStack(alignment: .leading) {
      PromptInputTextView(text: $input, isFocused: $inputFocused) {
        submitPrompt()
      }
      if input.isEmpty {
        Text("Message \(vm.currentModelName)…")
          .font(.body)
          .foregroundStyle(AppStyle.faint)
          .allowsHitTesting(false)
      }
    }
    .frame(minWidth: 96)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var sendButton: some View {
    Button {
      submitPrompt()
    } label: {
      Image(systemName: "arrow.up")
        .font(.system(size: 15, weight: .bold))
        .foregroundStyle(Color.white)
        .frame(width: 38, height: 38)
        .background {
          if vm.canSend(text: input) {
            Circle().fill(AppStyle.accentGradient)
          } else {
            Circle().fill(AppStyle.faint.opacity(0.28))
          }
        }
        .overlay(Circle().stroke(Color.white.opacity(vm.canSend(text: input) ? 0.18 : 0), lineWidth: 1))
        .shadow(color: vm.canSend(text: input) ? AppStyle.glow : .clear, radius: 12, y: 4)
    }
    .buttonStyle(.plain)
    .disabled(!vm.canSend(text: input))
  }

  private func submitPrompt() {
    guard vm.canSend(text: input) else { return }
    let text = input
    input = ""
    inputFocused = false
    Task { await vm.send(text) }
  }

  private func requestPadLandscapeIfNeeded() {
    guard !didRequestPadLandscape else { return }
    guard isPadStyleEnvironment else { return }
    guard let windowScene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first
    else { return }

    didRequestPadLandscape = true
    if #available(iOS 16.0, *) {
      let preferences = UIWindowScene.GeometryPreferences.iOS(interfaceOrientations: .landscape)
      windowScene.requestGeometryUpdate(preferences) { error in
        print("APP: iPad landscape request failed: \(error.localizedDescription)")
      }
    }
  }

  @ViewBuilder private var attachmentChips: some View {
    if vm.attachedImage != nil || vm.attachedVideoThumb != nil || vm.attachedAudioURL != nil
      || !vm.contextDocuments.isEmpty || vm.attachmentError != nil {
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 8) {
          if let data = vm.attachedImage, let ui = UIImage(data: data) {
            chip(thumb: ui, label: "Photo") { vm.attachedImage = nil; photoItem = nil }
          }
          if let data = vm.attachedVideoThumb, let ui = UIImage(data: data) {
            chip(thumb: ui, label: "Video", system: "video.fill") {
              vm.clearVideo(); videoItem = nil
            }
          }
          if vm.attachedAudioURL != nil {
            chip(thumb: nil, label: "Audio", system: "waveform") { vm.attachedAudioURL = nil }
          }
          ForEach(Array(vm.contextDocuments.enumerated()), id: \.offset) { _, document in
            chip(thumb: nil, label: document.name ?? "Document context", system: "text.document") {
              vm.removeContextDocument(document)
            }
          }
          if let error = vm.attachmentError {
            Text(error)
              .font(.caption.weight(.medium))
              .foregroundStyle(AppStyle.danger)
              .lineLimit(2)
          }
        }
      }
    }
  }

  private func chip(thumb: UIImage?, label: String, system: String = "photo", remove: @escaping () -> Void)
    -> some View
  {
    HStack(spacing: 6) {
      if let thumb {
        Image(uiImage: thumb).resizable().scaledToFill()
          .frame(width: 26, height: 26).clipShape(RoundedRectangle(cornerRadius: 6))
      } else {
        Image(systemName: system)
          .foregroundStyle(AppStyle.accent)
      }
      Text(label)
        .font(.caption.weight(.medium))
        .foregroundStyle(AppStyle.ink)
        .lineLimit(1)
        .truncationMode(.middle)
        .frame(maxWidth: 160)
      Button(action: remove) {
        Image(systemName: "xmark.circle.fill")
          .font(.caption)
          .foregroundStyle(AppStyle.faint)
      }
      .buttonStyle(.plain)
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 5)
    .background(AppStyle.surface.opacity(0.42))
    .liteGlass(cornerRadius: 8, tint: AppStyle.surface.opacity(0.18), interactive: true)
  }

  private static var documentContentTypes: [UTType] {
    var types: [UTType] = [.pdf, .plainText, .text, .utf8PlainText, .utf16PlainText]
    if let eml = UTType(filenameExtension: "eml") { types.append(eml) }
    return types
  }
}

// MARK: - Shell components

private struct SidebarPrimaryRow: View {
  let title: String
  let subtitle: String
  let system: String
  let trailingSystem: String

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: system)
        .font(.system(size: 14, weight: .semibold))
        .foregroundStyle(AppStyle.accent)
        .frame(width: 28, height: 28)
        .background(AppStyle.accentSoft.opacity(0.85))
        .clipShape(RoundedRectangle(cornerRadius: 8))

      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(AppStyle.ink)
          .lineLimit(1)
          .truncationMode(.middle)
        Text(subtitle)
          .font(.caption2.weight(.medium))
          .foregroundStyle(AppStyle.muted)
          .lineLimit(1)
      }

      Spacer()
      Image(systemName: trailingSystem)
        .font(.caption2.bold())
        .foregroundStyle(AppStyle.faint)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 11)
    .studioPanel(cornerRadius: 12)
  }
}

private struct SidebarCommandRow: View {
  let title: String
  let system: String

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: system)
        .font(.system(size: 14, weight: .semibold))
        .foregroundStyle(AppStyle.muted)
        .frame(width: 26, height: 26)
      Text(title)
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(AppStyle.ink)
        .lineLimit(1)
      Spacer()
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
    .studioPanel(cornerRadius: 12)
  }
}

private struct SidebarToolTile: View {
  let kind: MediaKind
  var title: String?
  var system: String?
  var tintOverride: Color?
  @Environment(\.colorScheme) private var colorScheme

  private var label: String { title ?? kind.title }
  private var icon: String { system ?? kind.system }
  private var color: Color { tintOverride ?? kind.tint }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Image(systemName: icon)
        .font(.system(size: 18, weight: .semibold))
        .foregroundStyle(color)
      Text(label)
        .font(.caption.weight(.semibold))
        .foregroundStyle(AppStyle.ink)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }
    .frame(maxWidth: .infinity, minHeight: 74, alignment: .topLeading)
    .padding(12)
    .background {
      RoundedRectangle(cornerRadius: 12)
        .fill(colorScheme == .dark ? AppStyle.surface : kind.tint.opacity(0.10))
        .background {
          if colorScheme == .light {
            RoundedRectangle(cornerRadius: 12)
              .fill(AppStyle.glassFill)
          }
        }
    }
    .overlay(
      RoundedRectangle(cornerRadius: 12)
        .stroke(colorScheme == .dark ? color.opacity(0.22) : color.opacity(0.28), lineWidth: 1))
  }
}

private struct SidebarEmptyRow: View {
  let title: String
  let system: String

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: system)
      Text(title)
      Spacer()
    }
    .font(.caption.weight(.medium))
    .foregroundStyle(AppStyle.muted)
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
    .studioPanel(cornerRadius: 12)
  }
}

private struct InspectorMetric: View {
  let title: String
  let value: String

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title)
        .font(.caption2.weight(.bold))
        .foregroundStyle(AppStyle.faint)
        .textCase(.uppercase)
      Text(value)
        .font(.caption.monospacedDigit().weight(.semibold))
        .foregroundStyle(AppStyle.ink)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(10)
    .background(AppStyle.surface.opacity(0.42))
    .liteGlass(cornerRadius: 8, tint: AppStyle.surface.opacity(0.14))
  }
}

private struct HeaderIconButton: View {
  let system: String

  var body: some View {
    Image(systemName: system)
      .font(.system(size: 15, weight: .semibold))
      .foregroundStyle(AppStyle.ink)
      .frame(width: 36, height: 36)
      .studioPanel(cornerRadius: 12)
  }
}

private struct StatusPill: View {
  let title: String
  let color: Color

  var body: some View {
    HStack(spacing: 6) {
      Circle().fill(color).frame(width: 7, height: 7)
      Text(title)
        .font(.caption.weight(.bold))
        .foregroundStyle(AppStyle.ink)
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 8)
    .studioPanel(cornerRadius: 999)
  }
}

private struct ErrorBanner: View {
  let message: String

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundStyle(AppStyle.danger)
      Text(message)
        .font(.callout)
        .foregroundStyle(AppStyle.ink)
      Spacer()
    }
    .padding(14)
    .background(AppStyle.errorFill)
    .clipShape(RoundedRectangle(cornerRadius: 14))
    .overlay(RoundedRectangle(cornerRadius: 14).stroke(AppStyle.danger.opacity(0.28)))
  }
}

private struct LoadingCanvas: View {
  let progress: Double
  let modelName: String
  @State private var pulse = false

  var body: some View {
    VStack(spacing: 18) {
      ZStack {
        RoundedRectangle(cornerRadius: 16)
          .fill(AppStyle.accentGradient)
        Image(systemName: "sparkles")
          .font(.system(size: 24, weight: .semibold))
          .foregroundStyle(.white)
      }
      .frame(width: 60, height: 60)
      .scaleEffect(pulse ? 1.04 : 0.96)
      .shadow(color: AppStyle.glow, radius: pulse ? 18 : 10, y: 6)
      .onAppear {
        withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
          pulse = true
        }
      }

      VStack(spacing: 6) {
        Text("Loading \(modelName)")
          .font(.headline.weight(.semibold))
          .foregroundStyle(AppStyle.ink)
          .multilineTextAlignment(.center)
        Text("\(Int(progress * 100))%")
          .font(.caption.monospacedDigit().weight(.semibold))
          .foregroundStyle(AppStyle.muted)
      }

      ProgressView(value: min(max(progress, 0), 1))
        .tint(AppStyle.accent)
        .scaleEffect(x: 1, y: 1.2, anchor: .center)

      VStack(spacing: 8) {
        LoadingSkeletonRow(width: 0.88, height: 12)
        LoadingSkeletonRow(width: 0.68, height: 12)
        LoadingSkeletonRow(width: 0.78, height: 12)
      }
      .redacted(reason: .placeholder)
    }
    .frame(maxWidth: 420)
    .padding(.horizontal, 22)
    .padding(.vertical, 24)
    .background(AppStyle.surface.opacity(0.55))
    .liteGlass(cornerRadius: 20, tint: AppStyle.surface.opacity(0.16))
    .clipShape(RoundedRectangle(cornerRadius: 20))
    .overlay(RoundedRectangle(cornerRadius: 20).stroke(AppStyle.lineStrong.opacity(0.5)))
    .shadow(color: AppStyle.softShadow, radius: 24, x: 0, y: 16)
  }
}

private struct LoadingSkeletonRow: View {
  let width: CGFloat
  let height: CGFloat

  var body: some View {
    GeometryReader { proxy in
      RoundedRectangle(cornerRadius: 4)
        .fill(AppStyle.line)
        .frame(width: proxy.size.width * width, height: height)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .frame(height: height)
  }
}

private struct EmptyConversationView: View {
  let modelName: String
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    VStack(spacing: 22) {
      ZStack {
        Circle()
          .fill(
            colorScheme == .dark
              ? RadialGradient(
                colors: [
                  AppStyle.themePurpleGlow.opacity(0.55),
                  Color(red: 0.95, green: 0.42, blue: 0.18).opacity(0.18),
                  .clear,
                ],
                center: .center,
                startRadius: 8,
                endRadius: 80)
              : RadialGradient(
                colors: [
                  Color(red: 0.38, green: 0.52, blue: 0.82).opacity(0.35),
                  AppStyle.themePurpleGlow.opacity(0.18),
                  .clear,
                ],
                center: .center,
                startRadius: 8,
                endRadius: 80))
          .frame(width: 130, height: 130)
          .blur(radius: colorScheme == .dark ? 12 : 8)
        BrandMark(size: 72, iconSize: 30, cornerRadius: 22)
      }

      VStack(spacing: 8) {
        Text("Start a conversation")
          .font(.title2.weight(.semibold))
          .foregroundStyle(AppStyle.ink)
        Text("Ask anything with \(modelName). Attach media from the toolbar below.")
          .font(.subheadline)
          .foregroundStyle(AppStyle.muted)
          .multilineTextAlignment(.center)
          .frame(maxWidth: 360)
      }

      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 8) {
          ForEach(MediaKind.allCases, id: \.title) { kind in
            HStack(spacing: 6) {
              Image(systemName: kind.system)
                .font(.caption.weight(.semibold))
                .foregroundStyle(kind.tint)
              Text(kind.title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppStyle.ink)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .studioPanel(cornerRadius: 999)
          }
        }
        .padding(.horizontal, 4)
      }
      .frame(maxWidth: 420)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 40)
  }
}

private struct TypingIndicator: View {
  var body: some View {
    HStack(spacing: 10) {
      AssistantMark()
      HStack(spacing: 10) {
        TypingDots()
        Text("Generating")
          .font(.caption.weight(.semibold))
          .foregroundStyle(AppStyle.muted)
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 11)
      .background(AppStyle.surface.opacity(0.55))
      .liteGlass(cornerRadius: 16, tint: AppStyle.surface.opacity(0.16))
      .overlay(RoundedRectangle(cornerRadius: 16).stroke(AppStyle.line))
      Spacer()
    }
  }
}

private struct TypingDots: View {
  var body: some View {
    TimelineView(.animation(minimumInterval: 0.45)) { context in
      let phase = Int(context.date.timeIntervalSinceReferenceDate / 0.45) % 3
      HStack(spacing: 5) {
        ForEach(0..<3, id: \.self) { index in
          Circle()
            .fill(AppStyle.accent)
            .frame(width: 6, height: 6)
            .opacity(phase == index ? 1 : 0.28)
            .scaleEffect(phase == index ? 1.15 : 0.85)
        }
      }
    }
  }
}

private struct ComposerToolButton: View {
  let kind: MediaKind
  var system: String?
  var tintOverride: Color?

  private var icon: String { system ?? kind.system }
  private var color: Color { tintOverride ?? kind.tint }

  var body: some View {
    Image(systemName: icon)
      .font(.system(size: 17, weight: .semibold))
      .foregroundStyle(color)
      .frame(width: 28, height: 28)
  }
}

private struct AssistantMark: View {
  var body: some View {
    ZStack {
      RoundedRectangle(cornerRadius: 10)
        .fill(AppStyle.accentGradient)
      Image(systemName: "sparkles")
        .font(.system(size: 12, weight: .bold))
        .foregroundStyle(.white)
    }
    .frame(width: 32, height: 32)
    .shadow(color: AppStyle.glow, radius: 8, y: 3)
  }
}

// MARK: - Prompt input

private struct PromptInputTextView: UIViewRepresentable {
  @Binding var text: String
  @Binding var isFocused: Bool
  var onSubmit: () -> Void

  func makeUIView(context: Context) -> ReturnSubmittingTextView {
    let textView = ReturnSubmittingTextView()
    textView.backgroundColor = .clear
    textView.delegate = context.coordinator
    textView.font = UIFont.preferredFont(forTextStyle: .body)
    textView.textColor = .label
    textView.adjustsFontForContentSizeCategory = true
    textView.isScrollEnabled = true
    textView.showsVerticalScrollIndicator = false
    textView.returnKeyType = .send
    textView.textContainer.lineFragmentPadding = 0
    textView.textContainerInset = .zero
    textView.onSubmit = onSubmit
    return textView
  }

  func updateUIView(_ uiView: ReturnSubmittingTextView, context: Context) {
    context.coordinator.parent = self
    uiView.onSubmit = onSubmit
    if uiView.text != text {
      uiView.text = text
    }
    if isFocused, !uiView.isFirstResponder {
      uiView.becomeFirstResponder()
    } else if !isFocused, uiView.isFirstResponder {
      uiView.resignFirstResponder()
    }
  }

  func sizeThatFits(_ proposal: ProposedViewSize, uiView: ReturnSubmittingTextView, context: Context)
    -> CGSize?
  {
    let width = proposal.width ?? 0
    let fitting = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
    let lineHeight = uiView.font?.lineHeight ?? UIFont.preferredFont(forTextStyle: .body).lineHeight
    let minHeight = lineHeight
    let maxHeight = lineHeight * 5
    return CGSize(width: width, height: min(max(fitting.height, minHeight), maxHeight))
  }

  func makeCoordinator() -> Coordinator {
    Coordinator(parent: self)
  }

  final class Coordinator: NSObject, UITextViewDelegate {
    var parent: PromptInputTextView

    init(parent: PromptInputTextView) {
      self.parent = parent
    }

    func textViewDidChange(_ textView: UITextView) {
      parent.text = textView.text
    }

    func textViewDidBeginEditing(_ textView: UITextView) {
      parent.isFocused = true
    }

    func textViewDidEndEditing(_ textView: UITextView) {
      parent.isFocused = false
    }

    func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String)
      -> Bool
    {
      if text == "\n" {
        if let textView = textView as? ReturnSubmittingTextView, textView.consumeShiftNewline() {
          return true
        }
        parent.onSubmit()
        return false
      }
      return true
    }
  }
}

private final class ReturnSubmittingTextView: UITextView {
  var onSubmit: (() -> Void)?
  private var shouldAllowNextNewline = false

  override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
    guard let returnPress = presses.first(where: Self.isReturnPress) else {
      super.pressesBegan(presses, with: event)
      return
    }

    if returnPress.key?.modifierFlags.contains(.shift) == true {
      shouldAllowNextNewline = true
      insertText("\n")
      shouldAllowNextNewline = false
    } else {
      onSubmit?()
    }
  }

  func consumeShiftNewline() -> Bool {
    guard shouldAllowNextNewline else { return false }
    shouldAllowNextNewline = false
    return true
  }

  private static func isReturnPress(_ press: UIPress) -> Bool {
    guard let key = press.key else { return false }
    return key.keyCode == .keyboardReturnOrEnter
      || key.charactersIgnoringModifiers == "\r"
      || key.charactersIgnoringModifiers == "\n"
  }
}

// MARK: - Bubble

private struct MessageBubble: View {
  let message: ChatMessage

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      if message.role == .assistant { AssistantMark() }
      if message.role == .user { Spacer(minLength: 52) }

      VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 8) {
        if let data = message.image ?? message.videoThumb, let ui = UIImage(data: data) {
          ZStack(alignment: .bottomLeading) {
            Image(uiImage: ui).resizable().scaledToFill()
              .frame(width: 220, height: 160)
              .clipShape(RoundedRectangle(cornerRadius: 8))
              .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppStyle.line))
            if message.videoThumb != nil {
              Image(systemName: "play.circle.fill")
                .font(.title3)
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
                .padding(8)
            }
          }
        }
        if message.hasAudio {
          MessageAttachmentLabel(title: "Audio", system: "waveform")
        }
        if let documentName = message.documentName {
          MessageAttachmentLabel(title: documentName, system: "doc.text")
        }
        if !message.text.isEmpty {
          Group {
            if message.role == .assistant {
              MarkdownMessageText(message.text)
            } else {
              Text(message.text)
                .font(.body)
                .lineSpacing(3)
            }
          }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: message.role == .user ? 520 : 680, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background {
              if message.role == .user {
                RoundedRectangle(cornerRadius: 18)
                  .fill(AppStyle.accentGradient)
              } else {
                RoundedRectangle(cornerRadius: 18)
                  .fill(AppStyle.surface.opacity(0.88))
              }
            }
            .foregroundStyle(message.role == .user ? Color.white : AppStyle.ink)
            .overlay(
              RoundedRectangle(cornerRadius: 18)
                .stroke(message.role == .user ? Color.white.opacity(0.12) : AppStyle.line)
            )
            .shadow(
              color: message.role == .user ? AppStyle.glow : AppStyle.softShadow,
              radius: message.role == .user ? 10 : 14,
              x: 0,
              y: message.role == .user ? 4 : 8
            )
            .textSelection(.enabled)
        }
        if let stats = message.stats {
          Text(stats)
            .font(.caption2.monospacedDigit().weight(.medium))
            .foregroundStyle(AppStyle.faint)
        }
      }

      if message.role == .assistant { Spacer(minLength: 40) }
    }
  }
}

private struct MessageAttachmentLabel: View {
  let title: String
  let system: String

  var body: some View {
    Label(title, systemImage: system)
      .font(.caption.weight(.medium))
      .foregroundStyle(AppStyle.muted)
      .lineLimit(1)
      .truncationMode(.middle)
      .padding(.horizontal, 8)
      .padding(.vertical, 5)
      .background(AppStyle.surface.opacity(0.48))
      .liteGlass(cornerRadius: 8, tint: AppStyle.surface.opacity(0.14))
  }
}

// MARK: - Markdown rendering

private struct MarkdownMessageText: View {
  private let blocks: [MarkdownBlock]

  init(_ markdown: String) {
    blocks = MarkdownParser.parse(markdown)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      ForEach(blocks.indices, id: \.self) { index in
        blockView(blocks[index])
      }
    }
    .font(.body)
    .lineSpacing(3)
  }

  @ViewBuilder
  private func blockView(_ block: MarkdownBlock) -> some View {
    switch block {
    case .text(let value):
      Text(Self.inlineMarkdown(value))
        .frame(maxWidth: .infinity, alignment: .leading)
    case .heading(let level, let value):
      Text(Self.inlineMarkdown(value))
        .font(headingFont(for: level))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, level <= 2 ? 2 : 0)
    case .list(let list):
      MarkdownListView(list: list)
    case .table(let table):
      MarkdownTableView(table: table)
    }
  }

  private func headingFont(for level: Int) -> Font {
    switch level {
    case 1:
      return .title3.weight(.semibold)
    case 2:
      return .headline.weight(.semibold)
    default:
      return .callout.weight(.semibold)
    }
  }

  static func inlineMarkdown(_ value: String) -> AttributedString {
    let options = AttributedString.MarkdownParsingOptions(
      interpretedSyntax: .inlineOnlyPreservingWhitespace,
      failurePolicy: .returnPartiallyParsedIfPossible)
    return (try? AttributedString(markdown: value, options: options)) ?? AttributedString(value)
  }
}

private enum MarkdownBlock {
  case text(String)
  case heading(level: Int, text: String)
  case list(MarkdownList)
  case table(MarkdownTable)
}

private struct MarkdownList {
  struct Item {
    let marker: String
    let text: String
  }

  let ordered: Bool
  let items: [Item]
}

private struct MarkdownTable {
  let headers: [String]
  let rows: [[String]]
}

private struct MarkdownListView: View {
  let list: MarkdownList

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      ForEach(list.items.indices, id: \.self) { index in
        let item = list.items[index]
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Text(list.ordered ? item.marker : "•")
            .font(.callout.weight(.medium))
            .foregroundStyle(AppStyle.muted)
            .frame(width: list.ordered ? 28 : 14, alignment: .trailing)

          Text(MarkdownMessageText.inlineMarkdown(item.text))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

private struct MarkdownTableView: View {
  let table: MarkdownTable

  private var columnWidths: [CGFloat] {
    table.headers.indices.map { column in
      let values = [table.headers[safe: column] ?? ""]
        + table.rows.map { $0[safe: column] ?? "" }
      let longest = values.map(\.count).max() ?? 0
      return min(max(CGFloat(longest) * 7.2 + 30, 92), 210)
    }
  }

  var body: some View {
    ScrollView(.horizontal, showsIndicators: true) {
      VStack(alignment: .leading, spacing: 0) {
        row(table.headers, isHeader: true)

        ForEach(table.rows.indices, id: \.self) { index in
          Divider().background(AppStyle.line)
          row(table.rows[index], isHeader: false)
        }
      }
      .background(AppStyle.surfaceMuted.opacity(0.35))
      .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .stroke(AppStyle.lineStrong, lineWidth: 0.75)
      )
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func row(_ cells: [String], isHeader: Bool) -> some View {
    HStack(alignment: .top, spacing: 0) {
      ForEach(columnWidths.indices, id: \.self) { index in
        Text(MarkdownMessageText.inlineMarkdown(cells[safe: index] ?? ""))
          .font(isHeader ? .caption.weight(.semibold) : .caption)
          .frame(width: columnWidths[index], alignment: .leading)
          .padding(.horizontal, 9)
          .padding(.vertical, 8)
          .background(isHeader ? AppStyle.surfaceMuted.opacity(0.72) : Color.clear)

        if index < columnWidths.count - 1 {
          Divider().background(AppStyle.line)
        }
      }
    }
  }
}

private enum MarkdownParser {
  static func parse(_ markdown: String) -> [MarkdownBlock] {
    let lines = markdown.components(separatedBy: .newlines)
    var blocks: [MarkdownBlock] = []
    var index = 0

    while index < lines.count {
      if lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
        index += 1
        continue
      }

      if let heading = parseHeading(lines[index]) {
        blocks.append(.heading(level: heading.level, text: heading.text))
        index += 1
        continue
      }

      if let list = parseList(lines, start: index) {
        blocks.append(.list(list.value))
        index = list.nextIndex
        continue
      }

      if let table = parseTable(lines, start: index) {
        blocks.append(.table(table.value))
        index = table.nextIndex
        continue
      }

      var paragraph: [String] = []
      while index < lines.count {
        let line = lines[index]
        if line.trimmingCharacters(in: .whitespaces).isEmpty {
          break
        }
        if !paragraph.isEmpty,
          parseHeading(line) != nil || parseList(lines, start: index) != nil
            || parseTable(lines, start: index) != nil
        {
          break
        }
        paragraph.append(line)
        index += 1
      }
      blocks.append(.text(paragraph.joined(separator: "\n")))
    }

    return blocks.isEmpty ? [.text(markdown)] : blocks
  }

  private static func parseHeading(_ line: String) -> (level: Int, text: String)? {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    var level = 0
    var cursor = trimmed.startIndex

    while cursor < trimmed.endIndex, trimmed[cursor] == "#", level < 6 {
      level += 1
      cursor = trimmed.index(after: cursor)
    }

    guard level > 0, cursor < trimmed.endIndex, trimmed[cursor].isWhitespace else {
      return nil
    }

    let text = trimmed[cursor...].trimmingCharacters(in: .whitespaces)
    return text.isEmpty ? nil : (level, text)
  }

  private static func parseList(_ lines: [String], start: Int)
    -> (value: MarkdownList, nextIndex: Int)?
  {
    guard let first = parseListItem(lines[start]) else { return nil }

    var items = [MarkdownList.Item(marker: first.marker, text: first.text)]
    var index = start + 1

    while index < lines.count, let item = parseListItem(lines[index]), item.ordered == first.ordered {
      items.append(MarkdownList.Item(marker: item.marker, text: item.text))
      index += 1
    }

    return (MarkdownList(ordered: first.ordered, items: items), index)
  }

  private static func parseListItem(_ line: String)
    -> (ordered: Bool, marker: String, text: String)?
  {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { return nil }

    for marker in ["* ", "- ", "+ "] where trimmed.hasPrefix(marker) {
      let text = String(trimmed.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
      return text.isEmpty ? nil : (false, marker.trimmingCharacters(in: .whitespaces), text)
    }

    var digitEnd = trimmed.startIndex
    while digitEnd < trimmed.endIndex, trimmed[digitEnd].isNumber {
      digitEnd = trimmed.index(after: digitEnd)
    }

    guard digitEnd > trimmed.startIndex, digitEnd < trimmed.endIndex else { return nil }
    let delimiter = trimmed[digitEnd]
    guard delimiter == "." || delimiter == ")" else { return nil }

    let afterDelimiter = trimmed.index(after: digitEnd)
    guard afterDelimiter < trimmed.endIndex, trimmed[afterDelimiter].isWhitespace else { return nil }

    let marker = String(trimmed[trimmed.startIndex...digitEnd])
    let text = trimmed[afterDelimiter...].trimmingCharacters(in: .whitespaces)
    return text.isEmpty ? nil : (true, marker, text)
  }

  private static func parseTable(_ lines: [String], start: Int)
    -> (value: MarkdownTable, nextIndex: Int)?
  {
    guard start + 1 < lines.count,
      let headers = parsePipeRow(lines[start]),
      let separator = parsePipeRow(lines[start + 1]),
      headers.count >= 2,
      separator.count == headers.count,
      separator.allSatisfy(isSeparatorCell)
    else {
      return nil
    }

    var rows: [[String]] = []
    var index = start + 2
    while index < lines.count, let row = parsePipeRow(lines[index]), row.count >= 2 {
      rows.append(pad(row, count: headers.count))
      index += 1
    }

    return (MarkdownTable(headers: headers, rows: rows), index)
  }

  private static func parsePipeRow(_ line: String) -> [String]? {
    guard line.contains("|") else { return nil }
    var cells = line.split(separator: "|", omittingEmptySubsequences: false)
      .map { $0.trimmingCharacters(in: .whitespaces) }

    if cells.first == "" { cells.removeFirst() }
    if cells.last == "" { cells.removeLast() }

    guard cells.count >= 2 else { return nil }
    return cells
  }

  private static func isSeparatorCell(_ cell: String) -> Bool {
    let value = cell.trimmingCharacters(in: .whitespaces)
    let dashes = value.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
    return dashes.count >= 3 && dashes.allSatisfy { $0 == "-" }
  }

  private static func pad(_ row: [String], count: Int) -> [String] {
    if row.count >= count { return Array(row.prefix(count)) }
    return row + Array(repeating: "", count: count - row.count)
  }
}

private extension Array {
  subscript(safe index: Index) -> Element? {
    indices.contains(index) ? self[index] : nil
  }
}

// MARK: - Model picker

/// Choose the model: the bundled, device-verified Gemma 4 E2B, any Hugging Face
/// `.litertlm` repo (downloaded on first use), or a local `.litertlm` file.
private struct ModelPickerView: View {
  @ObservedObject var vm: ChatViewModel
  @Environment(\.dismiss) private var dismiss

  @State private var repo = "litert-community/gemma-4-E4B-it-litert-lm"
  @State private var file = "gemma-4-E4B-it.litertlm"
  @State private var multimodal = false
  @State private var showImporter = false

  var body: some View {
    NavigationStack {
      List {
        Section {
          HStack(spacing: 12) {
            ZStack {
              RoundedRectangle(cornerRadius: 12)
                .fill(AppStyle.accentGradient)
              Image(systemName: "cpu")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
            }
            .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 4) {
              Text("Choose a model")
                .font(.headline)
              Text("Bundled, Hugging Face, or local `.litertlm` files.")
                .font(.caption)
                .foregroundStyle(AppStyle.muted)
            }
          }
          .padding(.vertical, 4)
        }

        Section("Bundled (device-verified)") {
          Button { pick(.bundledE2B) } label: {
            row("Gemma 4 E2B", "text · image · audio · ~2.6 GB", selected: vm.source == .bundledE2B)
          }
        }

        Section("Options for downloaded / local models") {
          Toggle("Bring up image / audio towers", isOn: $multimodal)
          Text("Off = text-only (safe default for an unknown model). Turn on only "
            + "if the model ships vision/audio encoders, or loading may fail.")
            .font(.caption).foregroundStyle(.secondary)
        }

        Section("Hugging Face — any .litertlm repo") {
          Button {
            pick(.huggingFace(
              repo: "litert-community/gemma-4-E4B-it-litert-lm",
              file: "gemma-4-E4B-it.litertlm", multimodal: multimodal))
          } label: {
            row("Gemma 4 E4B", "text · ~3.7 GB · downloads on first use", selected: false)
          }
          TextField("owner/repo", text: $repo)
            .textInputAutocapitalization(.never).autocorrectionDisabled().font(.callout)
          TextField("file.litertlm", text: $file)
            .textInputAutocapitalization(.never).autocorrectionDisabled().font(.callout)
          Button("Download & load") {
            pick(.huggingFace(repo: repo, file: file, multimodal: multimodal))
          }
          .disabled(repo.isEmpty || !file.hasSuffix(".litertlm"))
        }

        Section("Local file") {
          Button("Choose a .litertlm…") { showImporter = true }
        }

        Section {
          Text("Only Gemma 4 E2B is verified on device here. Other models run "
            + "through the same engine but aren't tested — bring any LiteRT-LM "
            + "`.litertlm`.")
            .font(.caption).foregroundStyle(.secondary)
        }
      }
      .scrollContentBackground(.hidden)
      .background(AppStyle.background)
      .navigationTitle("Model")
      .navigationBarTitleDisplayMode(.inline)
      .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
      .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Cancel") { dismiss() } } }
      .fileImporter(isPresented: $showImporter, allowedContentTypes: [.data]) { result in
        if case .success(let url) = result { pick(.localFile(url, multimodal: multimodal)) }
      }
    }
  }

  private func pick(_ source: ChatViewModel.ModelSource) {
    dismiss()
    Task { await vm.switchModel(to: source) }
  }

  private func row(_ title: String, _ subtitle: String, selected: Bool) -> some View {
    HStack(spacing: 12) {
      VStack(alignment: .leading, spacing: 3) {
        Text(title).font(.body.bold()).foregroundStyle(AppStyle.ink)
        Text(subtitle).font(.caption).foregroundStyle(AppStyle.muted)
      }
      Spacer()
      if selected {
        Image(systemName: "checkmark.circle.fill")
          .foregroundStyle(AppStyle.accent)
      }
    }
    .padding(.vertical, 2)
  }
}

// MARK: - View model

@MainActor
final class ChatViewModel: ObservableObject {
  enum Phase: Equatable { case idle, loading(Double), ready, error(String) }

  /// Where the model comes from. The bundled E2B is the verified default; the
  /// other two let you run *any* LiteRT-LM model — downloaded from a Hugging Face
  /// repo, or loaded from a local `.litertlm`.
  enum ModelSource: Equatable {
    case bundledE2B
    case huggingFace(repo: String, file: String, multimodal: Bool)
    case localFile(URL, multimodal: Bool)

    var displayName: String {
      switch self {
      case .bundledE2B: return "Gemma 4 E2B"
      case .huggingFace(_, let file, _): return file.replacingOccurrences(of: ".litertlm", with: "")
      case .localFile(let url, _): return url.deletingPathExtension().lastPathComponent
      }
    }
  }

  @Published var phase: Phase = .idle
  @Published var source: ModelSource = .bundledE2B
  @Published var messages: [ChatMessage] = []
  @Published var attachedImage: Data?
  @Published var attachedVideoFrames: [Data]?
  @Published var attachedVideoThumb: Data?
  @Published var attachedAudioURL: URL?
  @Published var attachedDocument: LiteRTDocument?
  @Published var contextDocuments: [LiteRTDocument] = []
  @Published var attachmentError: String?
  @Published var isGenerating = false
  @Published var isRecording = false
  @Published var scrollTick = 0

  var currentModelName: String { source.displayName }

  private var chat: LiteRTChat?
  private var securityScopedURL: URL?
  private let recorder = AudioRecorder()

  var isReady: Bool { if case .ready = phase { return true } else { return false } }

  func canSend(text: String) -> Bool {
    guard isReady, !isGenerating, !isRecording else { return false }
    let hasAttachment = attachedImage != nil || attachedVideoFrames != nil || attachedAudioURL != nil
      || attachedDocument != nil
    return !text.trimmingCharacters(in: .whitespaces).isEmpty || hasAttachment
  }

  func newChat() async {
    guard !isGenerating else { return }
    messages = []
    attachedImage = nil
    clearVideo()
    if let url = attachedAudioURL {
      try? FileManager.default.removeItem(at: url)
    }
    attachedAudioURL = nil
    attachedDocument = nil
    contextDocuments = []
    attachmentError = nil
    try? await chat?.resetConversation()
    scrollTick += 1
  }

  func loadIfNeeded() async {
    guard chat == nil, case .idle = phase else { return }
    await load(source)
  }

  /// Tear down the current model and load a different source (bundled / Hugging
  /// Face / local file). Chat history is kept.
  func switchModel(to newSource: ModelSource) async {
    guard !isGenerating else { return }
    releaseEngine()
    source = newSource
    await load(newSource)
  }

  private func load(_ src: ModelSource) async {
    guard chat == nil else { return }
    phase = .loading(0)
    let onProgress: @Sendable (ModelDownloader.Progress) -> Void = { [weak self] p in
      Task { @MainActor in
        if let self, case .loading = self.phase { self.phase = .loading(p.fraction) }
      }
    }
    do {
      let loaded: LiteRTChat
      switch src {
      case .bundledE2B:
        loaded = try await LiteRTChat(
          .gemma4_E2B, modalities: .all, enableBenchmark: true, prewarm: true,
          onDownloadProgress: onProgress)
      case .huggingFace(let repo, let file, let multimodal):
        loaded = try await LiteRTChat(
          huggingFaceRepo: repo, fileName: file, modalities: multimodal ? .all : [],
          enableBenchmark: true, prewarm: true, onDownloadProgress: onProgress)
      case .localFile(let url, let multimodal):
        // Hold the security scope open while the engine has the file mapped.
        _ = url.startAccessingSecurityScopedResource()
        securityScopedURL = url
        loaded = try await LiteRTChat(
          modelFileURL: url, modalities: multimodal ? .all : [],
          enableBenchmark: true, prewarm: true)
      }
      self.chat = loaded
      phase = .ready
      if ProcessInfo.processInfo.environment["LITERT_DEMO"] != nil { await runDemo() }
    } catch {
      phase = .error(error.localizedDescription)
    }
  }

  /// Drop the Easy-mode engine (freeing its weights) and reset to `.idle` so a
  /// later `loadIfNeeded()` rebuilds it. Used when handing memory to FM mode or
  /// before switching models. Chat history (`messages`) is kept.
  func releaseEngine() {
    chat = nil
    phase = .idle
    if let url = securityScopedURL {
      url.stopAccessingSecurityScopedResource()
      securityScopedURL = nil
    }
  }

  // MARK: Attachments

  func attachPhoto(_ item: PhotosPickerItem?) async {
    guard let item else { return }
    if let data = try? await item.loadTransferable(type: Data.self) { attachedImage = data }
  }

  func attachVideo(_ item: PhotosPickerItem?) async {
    guard let item else { return }
    guard let movie = try? await item.loadTransferable(type: Movie.self) else { return }
    if let frames = try? await VideoFrameSampler.sampleFrames(from: movie.url, count: 4),
      !frames.isEmpty {
      attachedVideoFrames = frames
      attachedVideoThumb = frames.first
    }
    try? FileManager.default.removeItem(at: movie.url)
  }

  func clearVideo() { attachedVideoFrames = nil; attachedVideoThumb = nil }

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
      attachedDocument = document
      upsertContextDocument(document)
    } catch {
      attachedDocument = nil
      attachmentError = error.localizedDescription
    }
  }

  func removeContextDocument(_ document: LiteRTDocument) {
    contextDocuments.removeAll { $0 == document }
    if attachedDocument == document { attachedDocument = nil }
  }

  private func upsertContextDocument(_ document: LiteRTDocument) {
    contextDocuments.removeAll { existing in
      existing.name == document.name || existing == document
    }
    contextDocuments.append(document)
  }

  func toggleRecording() async {
    if isRecording {
      attachedAudioURL = recorder.stop()
      isRecording = false
    } else {
      guard await recorder.requestPermission() else { return }
      if recorder.start() { isRecording = true }
    }
  }

  // MARK: Generation

  func send(_ text: String) async {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let chat, !isGenerating else { return }

    let image = attachedImage
    let frames = attachedVideoFrames
    let videoThumb = attachedVideoThumb
    let audioURL = attachedAudioURL
    let document = attachedDocument
    let documents = contextDocuments
    if trimmed.isEmpty && image == nil && frames == nil && audioURL == nil && document == nil { return }

    isGenerating = true
    defer { isGenerating = false }

    attachedImage = nil
    clearVideo()
    attachedAudioURL = nil
    attachedDocument = nil
    attachmentError = nil

    let prompt = trimmed.isEmpty
      ? defaultPrompt(image: image, frames: frames, audio: audioURL, document: document)
      : trimmed
    let modelPrompt = documents.isEmpty ? prompt : documentPrompt(prompt)
    messages.append(
      ChatMessage(
        role: .user, text: trimmed, image: image, videoThumb: videoThumb,
        documentName: document?.name, hasAudio: audioURL != nil))
    scrollTick += 1

    let assistantIndex = messages.count
    messages.append(ChatMessage(role: .assistant, text: ""))

    let start = Date()
    let audio: AudioInput? = audioURL.map { .file($0) }
    do {
      for try await delta in chat.stream(
        modelPrompt, image: image, images: frames ?? [], audio: audio, documents: documents) {
        messages[assistantIndex].text += delta
        scrollTick += 1
      }
      if documents.isEmpty, let b = try? chat.lastBenchmark() {
        messages[assistantIndex].stats = String(format: "%.0f tok/s", b.lastDecodeTokensPerSecond)
      } else {
        messages[assistantIndex].stats = String(format: "%.1fs", Date().timeIntervalSince(start))
      }
    } catch {
      messages[assistantIndex].text += "\n[error] \(error.localizedDescription)"
    }
    scrollTick += 1
  }

  private func defaultPrompt(image: Data?, frames: [Data]?, audio: URL?, document: LiteRTDocument?) -> String {
    if audio != nil {
      return "Listen to this audio and respond to it. If it asks a question, answer it."
    }
    if frames != nil {
      return "These images are frames sampled from a video in chronological order. "
        + "Describe what is happening in the video."
    }
    if image != nil { return "What is in this photo?" }
    if document != nil { return "Summarize this document and highlight the important details." }
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

  /// Auto-demo (LITERT_DEMO=1): a couple of turns so a screen recording / GIF
  /// shows a real multimodal chat without manual input.
  private func runDemo() async {
    await send("In one short sentence, what can you do?")
    try? await Task.sleep(nanoseconds: 600_000_000)
    if let url = Bundle.main.url(forResource: "apple", withExtension: "png"),
      let data = try? Data(contentsOf: url) {
      attachedImage = data
    }
    await send("What is in this photo? Answer in one short sentence.")
  }
}
