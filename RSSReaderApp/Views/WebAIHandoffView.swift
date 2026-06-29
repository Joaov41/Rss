import SwiftUI
import WebKit
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

@MainActor
final class WebAISessionManager {
    static let shared = WebAISessionManager()

    private let processPool = WKProcessPool()
    private let websiteDataStore = WKWebsiteDataStore.default()
    private var webViews: [WebAIProvider: WKWebView] = [:]

    private init() {}

    func hasWebView(for provider: WebAIProvider) -> Bool {
        webViews[provider] != nil
    }

    func webView(
        for provider: WebAIProvider,
        coordinator: WKNavigationDelegate & WKScriptMessageHandler & WKUIDelegate,
        handlerName: String,
        bootstrapScript: String,
        forceReload: Bool = true
    ) -> WKWebView {
        #if os(macOS)
        let usesPrivateStore = provider == .chatgpt
        let requiresFreshWebView = usesPrivateStore
        #else
        let usesPrivateStore = false
        let requiresFreshWebView = false
        #endif

        if requiresFreshWebView, let existing = webViews.removeValue(forKey: provider) {
            existing.stopLoading()
            existing.navigationDelegate = nil
            existing.uiDelegate = nil
        }

        if !requiresFreshWebView, let existing = webViews[provider] {
            configure(existing, coordinator: coordinator, handlerName: handlerName, bootstrapScript: bootstrapScript)
            applyProviderSettings(to: existing, provider: provider)
            if forceReload || existing.url == nil {
                loadProviderHome(provider, in: existing)
            } else {
                existing.evaluateJavaScript(bootstrapScript, completionHandler: nil)
            }
            return existing
        }

        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        configuration.websiteDataStore = usesPrivateStore ? .nonPersistent() : websiteDataStore
        configuration.processPool = processPool
        #if os(iOS)
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        #endif

        let webView = WKWebView(frame: .zero, configuration: configuration)
        configure(webView, coordinator: coordinator, handlerName: handlerName, bootstrapScript: bootstrapScript)
        applyProviderSettings(to: webView, provider: provider)
        webView.allowsBackForwardNavigationGestures = true
        loadProviderHome(provider, in: webView)
        webViews[provider] = webView
        return webView
    }

    func reconfigure(
        _ webView: WKWebView,
        coordinator: WKNavigationDelegate & WKScriptMessageHandler & WKUIDelegate,
        handlerName: String,
        bootstrapScript: String
    ) {
        configure(webView, coordinator: coordinator, handlerName: handlerName, bootstrapScript: bootstrapScript)
        if let provider = webViews.first(where: { $0.value === webView })?.key {
            applyProviderSettings(to: webView, provider: provider)
        }
    }

    func loadProviderHome(
        _ provider: WebAIProvider,
        in webView: WKWebView,
        cachePolicy: URLRequest.CachePolicy = .useProtocolCachePolicy
    ) {
        webView.load(URLRequest(url: provider.url, cachePolicy: cachePolicy, timeoutInterval: 60))
    }

    func reloadProviderHomeIgnoringCache(_ provider: WebAIProvider, in webView: WKWebView) {
        loadProviderHome(provider, in: webView, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData)
    }

    func removeCachedWebsiteData(
        for provider: WebAIProvider,
        from dataStore: WKWebsiteDataStore,
        completion: @escaping () -> Void
    ) {
        removeWebsiteData(
            for: provider,
            from: dataStore,
            dataTypes: cacheWebsiteDataTypes(),
            completion: completion
        )
    }

    func removeAllWebsiteData(
        for provider: WebAIProvider,
        from dataStore: WKWebsiteDataStore,
        completion: @escaping () -> Void
    ) {
        removeWebsiteData(
            for: provider,
            from: dataStore,
            dataTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
            completion: completion
        )
    }

    private func removeWebsiteData(
        for provider: WebAIProvider,
        from dataStore: WKWebsiteDataStore,
        dataTypes: Set<String>,
        completion: @escaping () -> Void
    ) {
        let domainFragments = sessionDomainFragments(for: provider)

        dataStore.fetchDataRecords(ofTypes: dataTypes) { records in
            let matching = records.filter { record in
                let name = record.displayName.lowercased()
                return domainFragments.contains { name.contains($0) }
            }

            guard !matching.isEmpty else {
                completion()
                return
            }

            dataStore.removeData(ofTypes: dataTypes, for: matching, completionHandler: completion)
        }
    }

    func resetSession(for provider: WebAIProvider, completion: @escaping (String) -> Void) {
        if let webView = webViews.removeValue(forKey: provider) {
            webView.stopLoading()
            webView.navigationDelegate = nil
            webView.uiDelegate = nil
        }

        removeAllWebsiteData(for: provider, from: websiteDataStore) {
            completion("\(provider.displayName) session reset. Open the login session again to sign in.")
        }
    }

    private func configure(
        _ webView: WKWebView,
        coordinator: WKNavigationDelegate & WKScriptMessageHandler & WKUIDelegate,
        handlerName: String,
        bootstrapScript: String
    ) {
        let controller = webView.configuration.userContentController
        controller.removeScriptMessageHandler(forName: handlerName)
        controller.removeAllUserScripts()
        controller.add(coordinator, name: handlerName)
        controller.addUserScript(
            WKUserScript(
                source: bootstrapScript,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
        )
        webView.navigationDelegate = coordinator
        webView.uiDelegate = coordinator
    }

    private func applyProviderSettings(to webView: WKWebView, provider: WebAIProvider) {
        webView.configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        webView.customUserAgent = nil
    }

    private func cacheWebsiteDataTypes() -> Set<String> {
        var dataTypes: Set<String> = [
            WKWebsiteDataTypeDiskCache,
            WKWebsiteDataTypeMemoryCache,
            WKWebsiteDataTypeOfflineWebApplicationCache
        ]

        if #available(iOS 11.3, macOS 10.13.4, *) {
            dataTypes.insert(WKWebsiteDataTypeFetchCache)
            dataTypes.insert(WKWebsiteDataTypeServiceWorkerRegistrations)
        }

        return dataTypes
    }

    private func sessionDomainFragments(for provider: WebAIProvider) -> [String] {
        switch provider {
        case .chatgpt:
            return ["chatgpt.com", "chat.openai.com", "openai.com", "auth.openai.com", "oaistatic.com", "oaiusercontent.com"]
        case .gemini:
            return ["gemini.google.com", "google.com", "accounts.google.com"]
        }
    }
}

struct WebAIHandoffView: View {
    let request: WebAIHandoffRequest
    var showsChrome: Bool = true
    var onMinimize: (() -> Void)? = nil

    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var isLoading = true
    @State private var didInject = false
    @State private var fallbackMessage: String?

    var body: some View {
        #if os(iOS)
        Group {
            if showsChrome {
                NavigationStack {
                    webView
                        .navigationTitle(request.title)
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Done") {
                                    appState.dismissActiveWebAIHandoff(userInitiated: true)
                                    dismiss()
                                }
                            }
                            ToolbarItemGroup(placement: .topBarTrailing) {
                                if isLoading {
                                    ProgressView()
                                }
                                if let onMinimize {
                                    Button {
                                        onMinimize()
                                    } label: {
                                        Image(systemName: "minus")
                                    }
                                    .accessibilityLabel("Minimize")
                                }
                            }
                        }
                }
            } else {
                webView
            }
        }
        #else
        Group {
            if showsChrome {
                VStack(spacing: 0) {
                    HStack {
                        Text(request.title)
                            .font(.headline)
                        Spacer()
                        Text(request.provider.displayName)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        if isLoading {
                            ProgressView()
                                .scaleEffect(0.8)
                        }
                        Button("Done") {
                            appState.dismissActiveWebAIHandoff(userInitiated: true)
                            dismiss()
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding()

                    webView
                }
                .frame(minWidth: 900, minHeight: 700)
            } else {
                webView
            }
        }
        #endif
        
    }

    private var webView: some View {
        webAIRepresentable
        .overlay {
            if isLoading && !didInject {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Loading \(request.provider.displayName)...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.ultraThinMaterial)
            }
        }
        .overlay(alignment: .bottom) {
            if let fallbackMessage {
                Text(fallbackMessage)
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.black.opacity(0.78))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .padding()
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    @ViewBuilder
    private var webAIRepresentable: some View {
        WebAIHandoffRepresentable(
            request: request,
            isLoading: $isLoading,
            didInject: $didInject,
            fallbackMessage: $fallbackMessage,
            onResponseCaptured: { response in
                appState.handleCapturedWebAIResponse(requestID: request.id, response: response)
            },
            onCaptureFailed: { message in
                appState.handleWebAIRequestFailure(requestID: request.id, message: message)
            }
        )
    }
}

#if os(iOS)
struct WebAIHandoffIOSPresenterModifier: ViewModifier {
    @ObservedObject var appState: AppState

    @State private var panelSize = CGSize(width: 980, height: 760)
    @State private var panelOffset: CGSize = .zero
    @State private var dragOrigin: CGSize?
    @State private var resizeOrigin: CGSize?

    private let minimumPanelSize = CGSize(width: 720, height: 520)

    func body(content: Content) -> some View {
        if UIDevice.current.userInterfaceIdiom == .pad {
            content
                .overlay {
                    GeometryReader { proxy in
                        if let request = appState.activeWebAIHandoffRequest {
                            ZStack(alignment: .bottomTrailing) {
                                iPadFloatingPanel(for: request, containerSize: proxy.size)
                                    .frame(
                                        width: min(panelSize.width, max(0, proxy.size.width - 32)),
                                        height: min(panelSize.height, max(0, proxy.size.height - 32))
                                    )
                                    .offset(panelOffset)
                                    .opacity(appState.isWebAIHandoffMinimized ? 0 : 1)
                                    .allowsHitTesting(!appState.isWebAIHandoffMinimized)
                                    .accessibilityHidden(appState.isWebAIHandoffMinimized)

                                if appState.isWebAIHandoffMinimized {
                                    restoreButton(for: request)
                                        .padding(.trailing, 16)
                                        .padding(.bottom, 20)
                                        .transition(.move(edge: .bottom).combined(with: .opacity))
                                }
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .animation(.spring(response: 0.24, dampingFraction: 0.9), value: appState.isWebAIHandoffMinimized)
                        }
                    }
                }
                .onChange(of: appState.activeWebAIHandoffRequest?.id) { _ in
                    if appState.activeWebAIHandoffRequest != nil {
                        resetPanelState()
                    }
                }
        } else {
            content
                .overlay {
                    GeometryReader { proxy in
                        if let request = appState.activeWebAIHandoffRequest {
                            ZStack(alignment: .bottomTrailing) {
                                iPhoneFloatingPanel(for: request, containerSize: proxy.size)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                                    .opacity(appState.isWebAIHandoffMinimized ? 0 : 1)
                                    .allowsHitTesting(!appState.isWebAIHandoffMinimized)
                                    .accessibilityHidden(appState.isWebAIHandoffMinimized)

                                if appState.isWebAIHandoffMinimized {
                                    restoreButton(for: request)
                                        .padding(.trailing, 16)
                                        .padding(.bottom, 20)
                                        .transition(.move(edge: .bottom).combined(with: .opacity))
                                }
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .animation(.spring(response: 0.24, dampingFraction: 0.9), value: appState.isWebAIHandoffMinimized)
                        }
                    }
                }
                .onChange(of: appState.activeWebAIHandoffRequest?.id) { _ in
                    if appState.activeWebAIHandoffRequest != nil {
                        resetPanelState()
                    }
                }
        }
    }

    private func iPadFloatingPanel(for request: WebAIHandoffRequest, containerSize: CGSize) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                HStack(spacing: 12) {
                    Image(systemName: "globe")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(request.title)
                            .font(.headline)
                            .lineLimit(1)
                        Text(request.provider.displayName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer(minLength: 0)

                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
                    .gesture(panelDragGesture(containerSize: containerSize))
                    .padding(.trailing, 4)

                Button {
                    appState.minimizeActiveWebAIHandoff()
                } label: {
                    ZStack {
                        Circle()
                            .fill(.thinMaterial)
                            .frame(width: 32, height: 32)
                        Image(systemName: "minus")
                            .font(.system(size: 12, weight: .bold))
                            .frame(width: 16, height: 16)
                    }
                }
                .frame(width: 56, height: 56)
                .buttonStyle(.plain)
                .contentShape(Rectangle())
                .accessibilityLabel("Minimize")
                .zIndex(3)

                Button {
                    appState.dismissActiveWebAIHandoff(userInitiated: true)
                } label: {
                    ZStack {
                        Circle()
                            .fill(.thinMaterial)
                            .frame(width: 32, height: 32)
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .bold))
                            .frame(width: 16, height: 16)
                    }
                }
                .frame(width: 56, height: 56)
                .buttonStyle(.plain)
                .contentShape(Rectangle())
                .accessibilityLabel("Close")
                .zIndex(3)
            }
            .padding(.horizontal, 18)
            .padding(.top, 16)
            .padding(.bottom, 14)
            .background(.ultraThickMaterial.opacity(0.001))
            .contentShape(Rectangle())
            .zIndex(2)

            Divider()

            WebAIHandoffView(request: request, showsChrome: false)
                .environmentObject(appState)
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .padding(12)
                .zIndex(0)
        }
        .background(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(.ultraThickMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                .allowsHitTesting(false)
        )
        .overlay(alignment: .bottomTrailing) {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 38, height: 38)
                .contentShape(Rectangle())
                .padding(12)
                .gesture(panelResizeGesture(containerSize: containerSize))
        }
        .shadow(color: .black.opacity(0.22), radius: 20, y: 10)
        .padding(16)
    }

    private func iPhoneFloatingPanel(for request: WebAIHandoffRequest, containerSize: CGSize) -> some View {
        let panelHeight = min(max(containerSize.height * 0.72, 420), max(420, containerSize.height - 20))

        return VStack(spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: "globe")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 2) {
                    Text(request.title)
                        .font(.headline)
                        .lineLimit(1)
                    Text(request.provider.displayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    appState.minimizeActiveWebAIHandoff()
                } label: {
                    ZStack {
                        Circle()
                            .fill(.thinMaterial)
                            .frame(width: 32, height: 32)
                        Image(systemName: "minus")
                            .font(.system(size: 12, weight: .bold))
                            .frame(width: 16, height: 16)
                    }
                }
                .frame(width: 56, height: 56)
                .buttonStyle(.plain)
                .contentShape(Rectangle())
                .accessibilityLabel("Minimize")
                .zIndex(3)

                Button {
                    appState.dismissActiveWebAIHandoff(userInitiated: true)
                } label: {
                    ZStack {
                        Circle()
                            .fill(.thinMaterial)
                            .frame(width: 32, height: 32)
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .bold))
                            .frame(width: 16, height: 16)
                    }
                }
                .frame(width: 56, height: 56)
                .buttonStyle(.plain)
                .contentShape(Rectangle())
                .accessibilityLabel("Close")
                .zIndex(3)
            }
            .padding(.horizontal, 18)
            .padding(.top, 14)
            .padding(.bottom, 12)
            .background(.ultraThickMaterial.opacity(0.001))
            .contentShape(Rectangle())
            .zIndex(2)

            Divider()

            WebAIHandoffView(request: request, showsChrome: false)
                .environmentObject(appState)
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .padding(12)
                .zIndex(0)
        }
        .frame(width: max(0, containerSize.width - 16), height: panelHeight, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(.ultraThickMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                .allowsHitTesting(false)
        )
        .shadow(color: .black.opacity(0.22), radius: 20, y: 10)
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
    }

    private func restoreButton(for request: WebAIHandoffRequest) -> some View {
        Button {
            appState.restoreMinimizedWebAIHandoff()
        } label: {
            HStack(spacing: 10) {
                if request.shouldAutoCapture {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "globe")
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(request.title)
                        .lineLimit(1)
                    Text(request.shouldAutoCapture ? "\(request.provider.displayName) working · Tap to open" : "\(request.provider.displayName) ready · Tap to open")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .font(.subheadline.weight(.medium))
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.ultraThickMaterial, in: Capsule())
        }
        .buttonStyle(.plain)
        .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
    }

    private func panelDragGesture(containerSize: CGSize) -> some Gesture {
        DragGesture()
            .onChanged { value in
                let origin = dragOrigin ?? panelOffset
                if dragOrigin == nil {
                    dragOrigin = panelOffset
                }

                panelOffset = clampedOffset(
                    CGSize(
                        width: origin.width + value.translation.width,
                        height: origin.height + value.translation.height
                    ),
                    containerSize: containerSize
                )
            }
            .onEnded { _ in
                dragOrigin = nil
            }
    }

    private func panelResizeGesture(containerSize: CGSize) -> some Gesture {
        DragGesture()
            .onChanged { value in
                let origin = resizeOrigin ?? panelSize
                if resizeOrigin == nil {
                    resizeOrigin = panelSize
                }

                panelSize = clampedPanelSize(
                    CGSize(
                        width: origin.width + value.translation.width,
                        height: origin.height + value.translation.height
                    ),
                    containerSize: containerSize
                )
                panelOffset = clampedOffset(panelOffset, containerSize: containerSize)
            }
            .onEnded { _ in
                resizeOrigin = nil
            }
    }

    private func clampedPanelSize(_ proposed: CGSize, containerSize: CGSize) -> CGSize {
        CGSize(
            width: min(max(minimumPanelSize.width, proposed.width), max(minimumPanelSize.width, containerSize.width - 32)),
            height: min(max(minimumPanelSize.height, proposed.height), max(minimumPanelSize.height, containerSize.height - 32))
        )
    }

    private func clampedOffset(_ proposed: CGSize, containerSize: CGSize) -> CGSize {
        let horizontalLimit = max(0, (containerSize.width - panelSize.width) / 2 - 16)
        let verticalLimit = max(0, (containerSize.height - panelSize.height) / 2 - 16)
        return CGSize(
            width: min(max(proposed.width, -horizontalLimit), horizontalLimit),
            height: min(max(proposed.height, -verticalLimit), verticalLimit)
        )
    }

    private func resetPanelState() {
        panelSize = CGSize(width: 980, height: 760)
        panelOffset = .zero
        dragOrigin = nil
        resizeOrigin = nil
    }
}
#endif

#if os(macOS)
struct WebAIHandoffFloatingPanelModifier: ViewModifier {
    @ObservedObject var appState: AppState

    @State private var panelSize = CGSize(width: 1080, height: 820)
    @State private var panelOffset: CGSize = .zero
    @State private var dragOrigin: CGSize?
    @State private var resizeOrigin: CGSize?

    private let minimumPanelSize = CGSize(width: 760, height: 560)
    private let defaultPanelSize = CGSize(width: 1080, height: 820)

    func body(content: Content) -> some View {
        content
            .overlay {
                GeometryReader { proxy in
                    if let request = appState.activeWebAIHandoffRequest {
                        ZStack(alignment: .bottomTrailing) {
                            floatingPanel(for: request, containerSize: proxy.size)
                                .frame(
                                    width: min(panelSize.width, max(0, proxy.size.width - 32)),
                                    height: min(panelSize.height, max(0, proxy.size.height - 32))
                                )
                                .offset(clampedOffset(panelOffset, containerSize: proxy.size))
                                .opacity(appState.isWebAIHandoffMinimized ? 0 : 1)
                                .allowsHitTesting(!appState.isWebAIHandoffMinimized)
                                .accessibilityHidden(appState.isWebAIHandoffMinimized)

                            if appState.isWebAIHandoffMinimized {
                                restoreButton(for: request)
                                    .padding(20)
                                    .transition(.move(edge: .bottom).combined(with: .opacity))
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .animation(.spring(response: 0.24, dampingFraction: 0.88), value: appState.isWebAIHandoffMinimized)
                    }
                }
            }
            .onChange(of: appState.activeWebAIHandoffRequest?.id) { _ in
                guard appState.activeWebAIHandoffRequest != nil else { return }
                resetPanelState()
            }
    }

    private func floatingPanel(for request: WebAIHandoffRequest, containerSize: CGSize) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                HStack(spacing: 12) {
                    Image(systemName: "globe")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(request.title)
                            .font(.headline)
                            .lineLimit(1)
                        Text(request.provider.displayName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer(minLength: 0)

                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
                    .gesture(panelDragGesture(containerSize: containerSize))
                    .padding(.trailing, 4)

                Button {
                    appState.minimizeActiveWebAIHandoff()
                } label: {
                    ZStack {
                        Circle()
                            .fill(.thinMaterial)
                            .frame(width: 32, height: 32)
                        Image(systemName: "minus")
                            .font(.system(size: 12, weight: .bold))
                            .frame(width: 16, height: 16)
                    }
                }
                .frame(width: 56, height: 56)
                .buttonStyle(.plain)
                .help("Minimize")
                .contentShape(Rectangle())
                .zIndex(3)

                Button {
                    appState.dismissActiveWebAIHandoff(userInitiated: true)
                } label: {
                    ZStack {
                        Circle()
                            .fill(.thinMaterial)
                            .frame(width: 32, height: 32)
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .bold))
                            .frame(width: 16, height: 16)
                    }
                }
                .frame(width: 56, height: 56)
                .buttonStyle(.plain)
                .help("Close")
                .contentShape(Rectangle())
                .zIndex(3)
            }
            .padding(.horizontal, 18)
            .padding(.top, 16)
            .padding(.bottom, 14)
            .background(.ultraThickMaterial.opacity(0.001))
            .contentShape(Rectangle())
            .zIndex(2)

            Divider()

            WebAIHandoffView(request: request, showsChrome: false)
                .environmentObject(appState)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .padding(14)
                .zIndex(0)
        }
        .background(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(.ultraThickMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        )
        .overlay(alignment: .bottomTrailing) {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 34, height: 34)
                .contentShape(Rectangle())
                .padding(12)
                .gesture(panelResizeGesture(containerSize: containerSize))
        }
        .shadow(color: .black.opacity(0.24), radius: 24, y: 12)
        .padding(20)
    }

    private func restoreButton(for request: WebAIHandoffRequest) -> some View {
        Button {
            appState.restoreMinimizedWebAIHandoff()
        } label: {
            HStack(spacing: 10) {
                if request.shouldAutoCapture {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "globe")
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(request.title)
                        .lineLimit(1)
                    Text(request.shouldAutoCapture ? "\(request.provider.displayName) working · Tap to open" : "\(request.provider.displayName) ready · Tap to open")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .font(.subheadline.weight(.medium))
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.ultraThickMaterial, in: Capsule())
        }
        .buttonStyle(.plain)
        .shadow(color: .black.opacity(0.18), radius: 12, y: 6)
    }

    private func panelDragGesture(containerSize: CGSize) -> some Gesture {
        DragGesture()
            .onChanged { value in
                let origin = dragOrigin ?? panelOffset
                if dragOrigin == nil {
                    dragOrigin = panelOffset
                }

                panelOffset = clampedOffset(
                    CGSize(
                        width: origin.width + value.translation.width,
                        height: origin.height + value.translation.height
                    ),
                    containerSize: containerSize
                )
            }
            .onEnded { _ in
                dragOrigin = nil
            }
    }

    private func panelResizeGesture(containerSize: CGSize) -> some Gesture {
        DragGesture()
            .onChanged { value in
                let origin = resizeOrigin ?? panelSize
                if resizeOrigin == nil {
                    resizeOrigin = panelSize
                }

                panelSize = clampedPanelSize(
                    CGSize(
                        width: origin.width + value.translation.width,
                        height: origin.height + value.translation.height
                    ),
                    containerSize: containerSize
                )
                panelOffset = clampedOffset(panelOffset, containerSize: containerSize)
            }
            .onEnded { _ in
                resizeOrigin = nil
            }
    }

    private func clampedPanelSize(_ proposed: CGSize, containerSize: CGSize) -> CGSize {
        CGSize(
            width: min(max(minimumPanelSize.width, proposed.width), max(minimumPanelSize.width, containerSize.width - 32)),
            height: min(max(minimumPanelSize.height, proposed.height), max(minimumPanelSize.height, containerSize.height - 32))
        )
    }

    private func clampedOffset(_ proposed: CGSize, containerSize: CGSize) -> CGSize {
        let visibleWidth = min(panelSize.width, max(0, containerSize.width - 32))
        let visibleHeight = min(panelSize.height, max(0, containerSize.height - 32))
        let horizontalLimit = max(0, (containerSize.width - visibleWidth) / 2 - 16)
        let verticalLimit = max(0, (containerSize.height - visibleHeight) / 2 - 16)

        return CGSize(
            width: min(max(proposed.width, -horizontalLimit), horizontalLimit),
            height: min(max(proposed.height, -verticalLimit), verticalLimit)
        )
    }

    private func resetPanelState() {
        panelSize = defaultPanelSize
        panelOffset = .zero
        dragOrigin = nil
        resizeOrigin = nil
    }
}
#endif

#if os(iOS)
private struct WebAIHandoffRepresentable: UIViewRepresentable {
    let request: WebAIHandoffRequest
    @Binding var isLoading: Bool
    @Binding var didInject: Bool
    @Binding var fallbackMessage: String?
    let onResponseCaptured: (String) -> Void
    let onCaptureFailed: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> WKWebView {
        makeWebView(coordinator: context.coordinator)
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.update(parent: self, webView: webView)
    }
}
#elseif os(macOS)
private struct WebAIHandoffRepresentable: NSViewRepresentable {
    let request: WebAIHandoffRequest
    @Binding var isLoading: Bool
    @Binding var didInject: Bool
    @Binding var fallbackMessage: String?
    let onResponseCaptured: (String) -> Void
    let onCaptureFailed: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> WKWebView {
        makeWebView(coordinator: context.coordinator)
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.update(parent: self, webView: webView)
    }
}
#endif

private extension WebAIHandoffRepresentable {
    static let scriptMessageHandlerName = "webAICapture"

    func makeWebView(coordinator: Coordinator) -> WKWebView {
        WebAISessionManager.shared.webView(
            for: request.provider,
            coordinator: coordinator,
            handlerName: Self.scriptMessageHandlerName,
            bootstrapScript: Coordinator.buildCaptureBootstrapScript(handlerName: Self.scriptMessageHandlerName),
            forceReload: true
        )
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler, WKUIDelegate {
        private var parent: WebAIHandoffRepresentable
        private var currentRequestID: UUID
        private var injectionAttempts = 0
        private let maxAttempts = 10
        private var captureFinished = false
        private var didScheduleReadyWork = false
        private var expectedChunks: [String: Int] = [:]
        private var chunkBuffers: [String: [Int: String]] = [:]
        private var fallbackExtractionPollToken = UUID()
        private var fallbackExtractionDidStart = false
        private var fallbackExtractionBaselineText = ""
        private var fallbackExtractionLastText = ""
        private var fallbackExtractionLastChangeAt: Date = .distantPast
        private var fallbackExtractionStartedAt: Date = .distantPast
        private let fallbackExtractionPollInterval: TimeInterval = 1.0
        private let fallbackExtractionSettleInterval: TimeInterval = 2.2
        private let fallbackExtractionMaxWait: TimeInterval = 190
        private var providerContentFailureMonitorToken = UUID()
        private var providerContentFailureMonitorStartedAt: Date = .distantPast
        private let providerContentFailureMonitorInterval: TimeInterval = 1.0
        private let providerContentFailureMonitorMaxWait: TimeInterval = 45
        private var didStagePromptForCurrentRequest = false
        private let promptStagingThreshold = 1800
        private let promptStagingChunkSize = 1200
        private var providerContentFailureRecoveryAttempts = 0
        private let maxProviderContentFailureRecoveryAttempts = 4

        private struct ExtractionSnapshot {
            let status: String
            let text: String
        }

        init(parent: WebAIHandoffRepresentable) {
            self.parent = parent
            self.currentRequestID = parent.request.id
        }

        func update(parent: WebAIHandoffRepresentable, webView: WKWebView) {
            let requestChanged = currentRequestID != parent.request.id
            self.parent = parent

            guard requestChanged else { return }

            currentRequestID = parent.request.id
            injectionAttempts = 0
            captureFinished = false
            didScheduleReadyWork = false
            expectedChunks.removeAll()
            chunkBuffers.removeAll()
            resetFallbackExtractionState()
            resetProviderContentFailureMonitorState()
            didStagePromptForCurrentRequest = false
            providerContentFailureRecoveryAttempts = 0

            DispatchQueue.main.async {
                self.parent.isLoading = true
                self.parent.didInject = false
                self.parent.fallbackMessage = nil
            }

            WebAISessionManager.shared.reconfigure(
                webView,
                coordinator: self,
                handlerName: WebAIHandoffRepresentable.scriptMessageHandlerName,
                bootstrapScript: Self.buildCaptureBootstrapScript(handlerName: WebAIHandoffRepresentable.scriptMessageHandlerName)
            )
            WebAISessionManager.shared.loadProviderHome(parent.request.provider, in: webView)
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            injectionAttempts = 0
            captureFinished = false
            didScheduleReadyWork = false
            expectedChunks.removeAll()
            chunkBuffers.removeAll()
            resetFallbackExtractionState()
            resetProviderContentFailureMonitorState()
            didStagePromptForCurrentRequest = false
            DispatchQueue.main.async {
                self.parent.isLoading = true
                self.parent.didInject = false
                self.parent.fallbackMessage = nil
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            DispatchQueue.main.async {
                self.parent.isLoading = false
            }
            scheduleReadyWork(in: webView)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            handleNavigationFailure(error)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            handleNavigationFailure(error)
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            print("[WebAI navigation] web content process terminated for \(parent.request.provider.displayName); reloading")
            webView.reload()
        }

        private func scheduleReadyWork(in webView: WKWebView) {
            guard !didScheduleReadyWork else { return }
            didScheduleReadyWork = true
            armCaptureSession(in: webView)
            if parent.request.provider == .chatgpt || parent.request.provider == .gemini {
                captureFallbackExtractionBaseline(in: webView)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                self.injectPrompt(into: webView)
            }
        }

        private func handleNavigationFailure(_ error: Error) {
            let nsError = error as NSError
            guard nsError.domain != NSURLErrorDomain || nsError.code != NSURLErrorCancelled else { return }
            print("[WebAI navigation] failed provider=\(parent.request.provider.displayName) code=\(nsError.code) error=\(error.localizedDescription)")
            DispatchQueue.main.async {
                self.parent.isLoading = false
                self.parent.fallbackMessage = "Could not load \(self.parent.request.provider.displayName): \(error.localizedDescription)"
            }
        }

        private var shouldStagePromptForInjection: Bool {
            parent.request.prompt.utf16.count > promptStagingThreshold
        }

        private func validateStagedPrompt(in webView: WKWebView, completion: @escaping (Bool) -> Void) {
            let requestID = currentRequestID.uuidString
            let expectedLength = parent.request.prompt.utf16.count

            webView.evaluateJavaScript("""
            (function() {
                return JSON.stringify({
                    requestId: window.__codexCapturePromptRequestId || "",
                    pendingLength: (window.__codexPendingPromptText || "").length,
                    captureLength: (window.__codexCapturePromptText || "").length
                });
            })();
            """) { [weak self] result, error in
                guard self != nil else { return }
                guard error == nil,
                      let payload = result as? String,
                      let data = payload.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    completion(false)
                    return
                }

                let stagedRequestID = json["requestId"] as? String ?? ""
                let pendingLength = json["pendingLength"] as? Int ?? 0
                let captureLength = json["captureLength"] as? Int ?? 0
                completion(
                    stagedRequestID == requestID &&
                    pendingLength == expectedLength &&
                    captureLength == expectedLength
                )
            }
        }

        private func stagePromptIfNeeded(in webView: WKWebView, completion: @escaping (Bool) -> Void) {
            guard shouldStagePromptForInjection else {
                completion(true)
                return
            }

            guard !didStagePromptForCurrentRequest else {
                validateStagedPrompt(in: webView) { [weak self] isStillStaged in
                    guard let self else { return }
                    if isStillStaged {
                        completion(true)
                        return
                    }

                    self.didStagePromptForCurrentRequest = false
                    self.stagePromptIfNeeded(in: webView, completion: completion)
                }
                return
            }

            let requestID = currentRequestID
            let prompt = parent.request.prompt
            let chunks = stride(from: 0, to: prompt.count, by: promptStagingChunkSize).map { start in
                let startIndex = prompt.index(prompt.startIndex, offsetBy: start)
                let endIndex = prompt.index(startIndex, offsetBy: promptStagingChunkSize, limitedBy: prompt.endIndex) ?? prompt.endIndex
                return String(prompt[startIndex..<endIndex])
            }

            var scripts = [
                """
                (function() {
                    window.__codexPendingPromptChunks = [];
                    window.__codexPendingPromptText = "";
                    window.__codexCapturePromptText = "";
                    window.__codexCapturePromptRequestId = "";
                    return "reset";
                })();
                """
            ]

            scripts.append(contentsOf: chunks.map { chunk in
                let escapedChunk = escapedJavaScriptString(chunk)
                return """
                (function() {
                    window.__codexPendingPromptChunks = window.__codexPendingPromptChunks || [];
                    window.__codexPendingPromptChunks.push("\(escapedChunk)");
                    return window.__codexPendingPromptChunks.length;
                })();
                """
            })

            scripts.append("""
            (function() {
                const parts = window.__codexPendingPromptChunks || [];
                window.__codexPendingPromptText = parts.join("");
                window.__codexCapturePromptText = window.__codexPendingPromptText;
                window.__codexCapturePromptRequestId = "\(requestID.uuidString)";
                window.__codexPendingPromptChunks = [];
                return window.__codexPendingPromptText.length;
            })();
            """)

            func runScript(at index: Int) {
                guard index < scripts.count else {
                    self.validateStagedPrompt(in: webView) { [weak self] isStillStaged in
                        guard let self else { return }
                        guard self.currentRequestID == requestID, isStillStaged else {
                            completion(false)
                            return
                        }
                        self.didStagePromptForCurrentRequest = true
                        completion(true)
                    }
                    return
                }

                webView.evaluateJavaScript(scripts[index]) { [weak self] _, error in
                    guard let self else { return }
                    guard self.currentRequestID == requestID, error == nil else {
                        completion(false)
                        return
                    }
                    runScript(at: index + 1)
                }
            }

            runScript(at: 0)
        }

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            guard navigationAction.targetFrame == nil,
                  navigationAction.request.url != nil else {
                return nil
            }

            webView.load(navigationAction.request)
            return nil
        }

        private func injectPrompt(into webView: WKWebView) {
            recoverProviderContentFailureIfNeeded(in: webView) { [weak self, weak webView] recovered in
                guard let self, let webView else { return }
                if recovered {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                        self.injectPrompt(into: webView)
                    }
                    return
                }

                self.injectPromptAfterContentFailureCheck(into: webView)
            }
        }

        private func injectPromptAfterContentFailureCheck(into webView: WKWebView) {
            if parent.request.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                DispatchQueue.main.async {
                    self.parent.didInject = true
                    self.parent.fallbackMessage = nil
                }
                return
            }

            guard !parent.didInject else { return }
            guard injectionAttempts < maxAttempts else {
                triggerManualFallback()
                return
            }

            injectionAttempts += 1
            stagePromptIfNeeded(in: webView) { [weak self] staged in
                guard let self else { return }
                guard staged else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                        self.injectPrompt(into: webView)
                    }
                    return
                }

                webView.evaluateJavaScript(self.buildInjectionScript()) { [weak self] result, _ in
                    guard let self else { return }

                    if let status = result as? String, status == "success" {
                        self.handlePromptInjectionSucceeded(in: webView)
                        return
                    }

                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                        self.injectPrompt(into: webView)
                    }
                }
            }
        }

        private func recoverProviderContentFailureIfNeeded(
            in webView: WKWebView,
            completion: @escaping (Bool) -> Void
        ) {
            guard (parent.request.provider == .chatgpt || parent.request.provider == .gemini),
                  providerContentFailureRecoveryAttempts < maxProviderContentFailureRecoveryAttempts else {
                completion(false)
                return
            }

            webView.evaluateJavaScript(Self.providerContentFailureDetectionScript()) { [weak self, weak webView] result, _ in
                guard let self, let webView else { return }
                guard (result as? Bool) == true else {
                    completion(false)
                    return
                }

                self.providerContentFailureRecoveryAttempts += 1
                let attempt = self.providerContentFailureRecoveryAttempts
                print("[WebAI navigation] \(self.parent.request.provider.displayName) content failed to load; recovery attempt \(attempt)")

                DispatchQueue.main.async {
                    self.parent.isLoading = true
                    self.parent.fallbackMessage = "\(self.parent.request.provider.displayName) failed to load. Retrying..."
                }

                self.didScheduleReadyWork = false
                self.didStagePromptForCurrentRequest = false

                if attempt == 1 {
                    webView.evaluateJavaScript(Self.providerRetryButtonClickScript()) { _, _ in
                        completion(true)
                    }
                    return
                }

                if attempt == 2 {
                    webView.reloadFromOrigin()
                    completion(true)
                    return
                }

                webView.stopLoading()
                let clearCompletion = {
                    DispatchQueue.main.async {
                        WebAISessionManager.shared.reloadProviderHomeIgnoringCache(
                            self.parent.request.provider,
                            in: webView
                        )
                        completion(true)
                    }
                }

                if attempt >= 4 {
                    DispatchQueue.main.async {
                        self.parent.fallbackMessage = "\(self.parent.request.provider.displayName) session data looked corrupt, so RSSReaderApp reset that web session. Sign in again if prompted."
                    }
                    WebAISessionManager.shared.removeAllWebsiteData(
                        for: self.parent.request.provider,
                        from: webView.configuration.websiteDataStore,
                        completion: clearCompletion
                    )
                } else {
                    WebAISessionManager.shared.removeCachedWebsiteData(
                        for: self.parent.request.provider,
                        from: webView.configuration.websiteDataStore,
                        completion: clearCompletion
                    )
                }
            }
        }

        private static func providerContentFailureDetectionScript() -> String {
            """
            (function() {
                const text = ((document.body && document.body.innerText) || "")
                    .replace(/\\s+/g, " ")
                    .trim()
                    .toLowerCase();
                if (!text) return false;
                const hasRetryButton = Array.from(document.querySelectorAll("button, [role='button'], a")).some(node => {
                    const label = [
                        node.textContent,
                        node.getAttribute("aria-label"),
                        node.getAttribute("title")
                    ].filter(Boolean).join(" ").replace(/\\s+/g, " ").trim().toLowerCase();
                    return label.includes("try again") || label.includes("retry") || label.includes("reload");
                });
                return text.includes("content failed to load") ||
                    text.includes("could not load content") ||
                    text.includes("couldn't load content") ||
                    text.includes("unable to load content") ||
                    (text.includes("something went wrong") && text.includes("1096")) ||
                    (text.includes("something went wrong") && hasRetryButton) ||
                    (text.length < 240 && hasRetryButton && text.includes("failed"));
            })();
            """
        }

        private static func providerRetryButtonClickScript() -> String {
            """
            (function() {
                function isUsable(node) {
                    if (!node) return false;
                    const rect = node.getBoundingClientRect();
                    const style = window.getComputedStyle(node);
                    return !node.disabled &&
                        node.getAttribute("aria-disabled") !== "true" &&
                        rect.width > 0 &&
                        rect.height > 0 &&
                        style.display !== "none" &&
                        style.visibility !== "hidden" &&
                        style.pointerEvents !== "none";
                }

                const retryButton = Array.from(document.querySelectorAll("button, [role='button'], a")).find(node => {
                    const label = [
                        node.textContent,
                        node.getAttribute("aria-label"),
                        node.getAttribute("title")
                    ].filter(Boolean).join(" ").replace(/\\s+/g, " ").trim().toLowerCase();
                    return isUsable(node) &&
                        (label.includes("try again") || label.includes("retry") || label.includes("reload"));
                });

                if (!retryButton) return false;
                retryButton.scrollIntoView({ block: "center", inline: "center" });
                retryButton.click();
                return true;
            })();
            """
        }

        private func triggerManualFallback() {
            copyToPasteboard(parent.request.prompt)
            DispatchQueue.main.async {
                self.parent.fallbackMessage = "Auto-send could not find the message box. The prompt was copied to the clipboard so you can paste it manually."
            }
        }

        private func handlePromptInjectionSucceeded(in webView: WKWebView) {
            providerContentFailureRecoveryAttempts = 0
            didStagePromptForCurrentRequest = false
            webView.evaluateJavaScript("window.__codexPendingPromptText = '';") { _, _ in }
            DispatchQueue.main.async {
                self.parent.didInject = true
                self.parent.fallbackMessage = nil
            }

            guard parent.request.shouldAutoCapture else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                self.startFallbackExtractionPollingIfNeeded(in: webView)
            }
        }

        private func finishWithCaptureFailure() {
            deliverCaptureFailure("Automatic response capture timed out for \(parent.request.provider.displayName).")
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == WebAIHandoffRepresentable.scriptMessageHandlerName,
                  let payload = message.body as? [String: Any],
                  let type = payload["type"] as? String,
                  let requestID = payload["requestId"] as? String,
                  requestID == parent.request.id.uuidString else {
                return
            }

            switch type {
            case "progress":
                let length = payload["length"] as? Int ?? 0
                let preview = payload["preview"] as? String ?? ""
                let streaming = payload["streaming"] as? Bool ?? false
                let stableForMs = payload["stableForMs"] as? Int ?? 0
                print("[WebAI][\(requestID)] len=\(length) streaming=\(streaming) stable=\(stableForMs) preview=\(preview)")

            case "finalBegin":
                expectedChunks[requestID] = payload["totalChunks"] as? Int ?? 0
                chunkBuffers[requestID] = [:]

            case "finalChunk":
                let index = payload["index"] as? Int ?? 0
                let text = payload["text"] as? String ?? ""
                var buffer = chunkBuffers[requestID] ?? [:]
                buffer[index] = text
                chunkBuffers[requestID] = buffer

            case "finalEnd":
                guard let expected = expectedChunks[requestID],
                      let buffer = chunkBuffers[requestID],
                      buffer.count == expected else {
                    finishWithCaptureFailure()
                    return
                }

                let fullText = (0..<expected).compactMap { buffer[$0] }.joined()
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                expectedChunks[requestID] = nil
                chunkBuffers[requestID] = nil

                guard !fullText.isEmpty else {
                    finishWithCaptureFailure()
                    return
                }

                deliverCapturedResponse(fullText)

            case "failed":
                let reason = (payload["message"] as? String) ?? "Automatic response capture timed out for \(parent.request.provider.displayName)."
                deliverCaptureFailure(reason)

            case "debug":
                print("[WebAI debug] \(payload)")

            default:
                break
            }
        }

        private func armCaptureSession(in webView: WKWebView) {
            guard parent.request.shouldAutoCapture else { return }
            captureFinished = false
            expectedChunks.removeAll()
            chunkBuffers.removeAll()
            webView.evaluateJavaScript(Self.buildCaptureBootstrapScript(handlerName: WebAIHandoffRepresentable.scriptMessageHandlerName)) { [weak self] _, _ in
                guard let self else { return }
                webView.evaluateJavaScript(self.buildArmCaptureScript(), completionHandler: nil)
            }
        }

        private func deliverCapturedResponse(_ response: String) {
            guard !captureFinished else { return }
            captureFinished = true
            resetFallbackExtractionState()
            DispatchQueue.main.async {
                self.parent.fallbackMessage = nil
                self.parent.onResponseCaptured(response)
            }
        }

        private func deliverCaptureFailure(_ message: String) {
            guard !captureFinished else { return }
            captureFinished = true
            resetFallbackExtractionState()
            DispatchQueue.main.async {
                self.parent.fallbackMessage = message
                self.parent.onCaptureFailed(message)
            }
        }

        private func resetFallbackExtractionState() {
            fallbackExtractionPollToken = UUID()
            fallbackExtractionDidStart = false
            fallbackExtractionBaselineText = ""
            fallbackExtractionLastText = ""
            fallbackExtractionLastChangeAt = .distantPast
            fallbackExtractionStartedAt = .distantPast
        }

        private func resetProviderContentFailureMonitorState() {
            providerContentFailureMonitorToken = UUID()
            providerContentFailureMonitorStartedAt = .distantPast
        }

        private func startProviderContentFailureMonitorIfNeeded(in webView: WKWebView) {
            guard parent.request.provider == .chatgpt || parent.request.provider == .gemini else { return }
            guard !parent.request.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            guard providerContentFailureMonitorStartedAt == .distantPast else { return }

            providerContentFailureMonitorStartedAt = Date()
            let token = providerContentFailureMonitorToken
            scheduleProviderContentFailureMonitorPoll(in: webView, token: token, delay: 0.5)
        }

        private func scheduleProviderContentFailureMonitorPoll(in webView: WKWebView, token: UUID, delay: TimeInterval) {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak webView] in
                guard let self, let webView else { return }
                guard self.providerContentFailureMonitorToken == token,
                      self.currentRequestID == self.parent.request.id,
                      !self.parent.didInject else { return }

                let elapsed = Date().timeIntervalSince(self.providerContentFailureMonitorStartedAt)
                guard elapsed <= self.providerContentFailureMonitorMaxWait else { return }
                self.pollProviderContentFailureMonitor(in: webView, token: token)
            }
        }

        private func pollProviderContentFailureMonitor(in webView: WKWebView, token: UUID) {
            webView.evaluateJavaScript(Self.providerContentFailureDetectionScript()) { [weak self, weak webView] result, _ in
                guard let self, let webView else { return }
                guard self.providerContentFailureMonitorToken == token,
                      self.currentRequestID == self.parent.request.id,
                      !self.parent.didInject else { return }

                if (result as? Bool) == true {
                    self.recoverProviderContentFailureIfNeeded(in: webView) { [weak self, weak webView] _ in
                        guard let self, let webView else { return }
                        self.scheduleProviderContentFailureMonitorPoll(
                            in: webView,
                            token: token,
                            delay: max(self.providerContentFailureMonitorInterval, 2.0)
                        )
                    }
                    return
                }

                self.scheduleProviderContentFailureMonitorPoll(
                    in: webView,
                    token: token,
                    delay: self.providerContentFailureMonitorInterval
                )
            }
        }

        private func captureFallbackExtractionBaseline(in webView: WKWebView) {
            guard parent.request.shouldAutoCapture,
                  (parent.request.provider == .chatgpt || parent.request.provider == .gemini) else { return }

            let requestID = currentRequestID
            webView.evaluateJavaScript(buildExtractionScript()) { [weak self] result, _ in
                guard let self else { return }
                guard !self.captureFinished, self.currentRequestID == requestID else { return }
                guard let snapshot = self.parseExtractionSnapshot(from: result) else { return }
                self.fallbackExtractionBaselineText = snapshot.text
            }
        }

        private func startFallbackExtractionPollingIfNeeded(in webView: WKWebView) {
            guard parent.request.shouldAutoCapture,
                  (parent.request.provider == .chatgpt || parent.request.provider == .gemini),
                  !captureFinished,
                  !fallbackExtractionDidStart else { return }

            fallbackExtractionDidStart = true
            fallbackExtractionStartedAt = Date()
            fallbackExtractionLastChangeAt = fallbackExtractionStartedAt
            let token = fallbackExtractionPollToken
            scheduleFallbackExtractionPoll(in: webView, token: token, delay: fallbackExtractionPollInterval)
        }

        private func scheduleFallbackExtractionPoll(in webView: WKWebView, token: UUID, delay: TimeInterval) {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak webView] in
                guard let self, let webView else { return }
                guard !self.captureFinished,
                      self.fallbackExtractionPollToken == token,
                      self.currentRequestID == self.parent.request.id else { return }
                self.pollFallbackExtraction(in: webView, token: token)
            }
        }

        private func pollFallbackExtraction(in webView: WKWebView, token: UUID) {
            webView.evaluateJavaScript(buildExtractionScript()) { [weak self, weak webView] result, _ in
                guard let self else { return }
                guard !self.captureFinished,
                      self.fallbackExtractionPollToken == token,
                      self.currentRequestID == self.parent.request.id else { return }

                if let snapshot = self.parseExtractionSnapshot(from: result) {
                    self.handleFallbackExtractionSnapshot(snapshot, in: webView, token: token)
                    return
                }

                guard let webView else { return }
                self.scheduleFallbackExtractionPoll(in: webView, token: token, delay: self.fallbackExtractionPollInterval)
            }
        }

        private func handleFallbackExtractionSnapshot(_ snapshot: ExtractionSnapshot, in webView: WKWebView?, token: UUID) {
            let now = Date()
            let text = snapshot.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let changed = !text.isEmpty && text != fallbackExtractionLastText

            if changed {
                fallbackExtractionLastText = text
                fallbackExtractionLastChangeAt = now
            }

            let matchesBaseline = !text.isEmpty && text == fallbackExtractionBaselineText
            let lastTextMatchesBaseline = !fallbackExtractionLastText.isEmpty && fallbackExtractionLastText == fallbackExtractionBaselineText
            let isStable = !text.isEmpty && now.timeIntervalSince(fallbackExtractionLastChangeAt) >= fallbackExtractionSettleInterval
            let hasEnoughContent = text.count >= 24 || text.contains("\n\n")
            let staleStreaming = snapshot.status == "streaming" &&
                !text.isEmpty &&
                now.timeIntervalSince(fallbackExtractionLastChangeAt) >= max(fallbackExtractionSettleInterval, 5.0)
            let timedOut = now.timeIntervalSince(fallbackExtractionStartedAt) >= fallbackExtractionMaxWait

            if !text.isEmpty,
               !matchesBaseline,
               snapshot.status == "found",
               isStable {
                deliverCapturedResponse(text)
                return
            }

            if !matchesBaseline,
               staleStreaming,
               hasEnoughContent {
                deliverCapturedResponse(text)
                return
            }

            if timedOut, !fallbackExtractionLastText.isEmpty, !lastTextMatchesBaseline {
                deliverCapturedResponse(fallbackExtractionLastText)
                return
            }

            guard let webView else { return }
            scheduleFallbackExtractionPoll(in: webView, token: token, delay: fallbackExtractionPollInterval)
        }

        private func parseExtractionSnapshot(from result: Any?) -> ExtractionSnapshot? {
            guard let payload = result as? String,
                  let data = payload.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }

            let status = (json["status"] as? String ?? "waiting")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let text = (json["text"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return ExtractionSnapshot(status: status, text: text)
        }

        private func escapedJavaScriptString(_ value: String) -> String {
            value
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: "\\n")
                .replacingOccurrences(of: "\r", with: "\\r")
                .replacingOccurrences(of: "\t", with: "\\t")
                .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
                .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
        }

        private func capturePromptReference(maxLength: Int = 480) -> String {
            let normalized = parent.request.prompt
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return String(normalized.prefix(maxLength))
        }

        private func buildArmCaptureScript() -> String {
            let requestID = parent.request.id.uuidString
            let responseFormat = parent.request.responseFormat.rawValue
            let escapedPrompt = escapedJavaScriptString(capturePromptReference())
            let promptSource = shouldStagePromptForInjection
                ? "(window.__codexCapturePromptText || \"\(escapedPrompt)\")"
                : "\"\(escapedPrompt)\""

            return """
            (function() {
                if (!window.__webAICapture || typeof window.__webAICapture.start !== "function") return "missing";
                window.__webAICapture.start({
                    requestId: "\(requestID)",
                    provider: "\(parent.request.provider.rawValue)",
                    prompt: \(promptSource),
                    responseFormat: "\(responseFormat)",
                    settleMs: \(parent.request.responseFormat == .strictJSON ? 1200 : 1800),
                    minLength: \(parent.request.responseFormat == .strictJSON ? 40 : 24),
                    maxWaitMs: \(parent.request.responseFormat == .strictJSON ? 150000 : 180000)
                });
                return "armed";
            })();
            """
        }

        static func buildCaptureBootstrapScript(handlerName: String) -> String {
            """
            (function () {
              if (window.__webAICaptureInstalled) return;
              window.__webAICaptureInstalled = true;

              const HANDLER = "\(handlerName)";

              function post(payload) {
                try {
                  window.webkit.messageHandlers[HANDLER].postMessage(payload);
                } catch (_) {}
              }

              function normalize(value) {
                return (value || "")
                  .replace(/\\u00a0/g, " ")
                  .replace(/[ \\t]+\\n/g, "\\n")
                  .replace(/\\n{3,}/g, "\\n\\n")
                  .replace(/[ \\t]{2,}/g, " ")
                  .trim();
              }

              function activePromptText(state) {
                return normalize(window.__codexCapturePromptText || (state && state.promptText) || "");
              }

              function uniqueNodes(nodes) {
                return Array.from(new Set(nodes.filter(Boolean)));
              }

              function cleanText(node) {
                if (!node) return "";
                const clone = node.cloneNode(true);
                clone.querySelectorAll([
                  "button",
                  "svg",
                  "textarea",
                  "input",
                  "select",
                  "form",
                  "nav",
                  "footer",
                  "rich-textarea",
                  "[contenteditable='true']",
                  "[aria-hidden='true']",
                  "[role='toolbar']",
                  "[data-testid*='copy']",
                  "[data-testid*='thumb']",
                  ".sr-only"
                ].join(",")).forEach(el => el.remove());
                return normalize(clone.innerText || clone.textContent || "");
              }

              function isGeminiComposerNode(node) {
                if (!node) return false;
                return Boolean(
                  node.closest("rich-textarea") ||
                  node.closest("textarea") ||
                  node.closest("[contenteditable='true']") ||
                  node.closest("form") ||
                  node.closest("[class*='composer']") ||
                  node.closest("[class*='input']") ||
                  node.closest("[class*='prompt']")
                );
              }

              function isGeminiLandingText(value) {
                const text = normalize(value).toLowerCase();
                return text === "what can i help with, gemini?" ||
                  text === "what can i help with gemini?" ||
                  text.includes("what can i help with, gemini?") ||
                  text === "meet gemini, your personal ai assistant" ||
                  text === "meet gemini, your ai assistant" ||
                  (text.includes("meet gemini") && text.includes("personal ai assistant") && text.length < 180);
              }

              function isGeminiBoilerplateText(value) {
                const text = normalize(value).toLowerCase();
                if (!text) return true;
                if (text === "gemini apps activity is off") return true;
                if (text.includes("apps activity is off") && text.length < 120) return true;
                if (text.includes("gemini is ai and can make mistakes")) return true;
                if (text.includes("your privacy") && text.includes("gemini")) return true;
                if (text.includes("google apps")) return true;
                if (text.includes("google terms") && text.includes("privacy policy")) return true;
                if (text.includes("sign in") && text.length < 120) return true;
                if (text === "new chat" || text === "tools" || text === "flash" || text === "3.1 flash-lite") return true;
                return false;
              }

              function stripGeminiBoilerplate(value) {
                let text = normalize(value);
                if (!text) return "";
                const patterns = [
                  /gemini is ai and can make mistakes[^]*$/i,
                  /your privacy[^]*gemini[^]*$/i,
                  /google terms[^]*privacy policy[^]*$/i,
                  /gemini apps activity is off/i
                ];
                patterns.forEach(pattern => {
                  text = text.replace(pattern, " ").trim();
                });
                return normalize(text);
              }

              function isPromptEcho(value, promptText) {
                const text = normalize(value);
                const prompt = normalize(promptText);
                if (!text || !prompt) return false;
                if (text === prompt) return true;
                if (text.length > 120 && prompt.includes(text)) return true;
                if (text.length > 120 && prompt.startsWith(text)) return true;
                const responsePrefix = text.slice(0, Math.min(text.length, 500));
                if (responsePrefix.length >= 120 && prompt.includes(responsePrefix)) return true;
                const promptPrefix = prompt.slice(0, Math.min(prompt.length, 240));
                if (text.length > 120 &&
                  promptPrefix.length > 80 &&
                  text.startsWith(promptPrefix) &&
                  text.length <= prompt.length * 1.1) {
                  return true;
                }

                if (text.length < 400) return false;
                const probeLength = Math.min(260, text.length);
                const probes = [
                  text.slice(0, probeLength),
                  text.slice(Math.max(0, Math.floor((text.length - probeLength) / 2)), Math.max(0, Math.floor((text.length - probeLength) / 2)) + probeLength),
                  text.slice(Math.max(0, text.length - probeLength))
                ];
                return probes.filter(probe => probe.length >= 120 && prompt.includes(probe)).length >= 2;
              }

              function stripPromptEcho(value, promptText) {
                const text = normalize(value);
                const prompt = normalize(promptText);
                if (!text || !prompt) return text;
                if (text === prompt) return "";
                if (text.startsWith(prompt)) return normalize(text.slice(prompt.length));
                if (text.length > 120 && prompt.includes(text)) return "";

                const maxProbeLength = Math.min(1200, text.length);
                for (let length = maxProbeLength; length >= 160; length -= 80) {
                  const probe = text.slice(0, length);
                  const promptIndex = prompt.indexOf(probe);
                  if (promptIndex === -1) continue;

                  let matched = length;
                  while (
                    matched < text.length &&
                    promptIndex + matched < prompt.length &&
                    text.charCodeAt(matched) === prompt.charCodeAt(promptIndex + matched)
                  ) {
                    matched += 1;
                  }

                  if (matched >= 160) {
                    return normalize(text.slice(matched));
                  }
                }
                return text;
              }

              function isProviderContentLoadFailure(value) {
                const text = normalize(value).toLowerCase();
                if (!text) return false;
                return text.includes("content failed to load") ||
                  text.includes("could not load content") ||
                  text.includes("couldn't load content") ||
                  text.includes("unable to load content") ||
                  (text.includes("something went wrong") && text.includes("1096")) ||
                  ((text.includes("something went wrong") || text.includes("failed to load")) && text.length < 260);
              }

              function clickProviderRetryButton() {
                const candidates = Array.from(document.querySelectorAll("button, [role='button'], a"));
                const retryButton = candidates.find(node => {
                  const rect = node.getBoundingClientRect();
                  const style = window.getComputedStyle(node);
                  const label = [
                    node.textContent,
                    node.getAttribute("aria-label"),
                    node.getAttribute("title")
                  ].filter(Boolean).join(" ").replace(/\\s+/g, " ").trim().toLowerCase();
                  return rect.width > 0 &&
                    rect.height > 0 &&
                    style.display !== "none" &&
                    style.visibility !== "hidden" &&
                    style.pointerEvents !== "none" &&
                    !node.disabled &&
                    node.getAttribute("aria-disabled") !== "true" &&
                    (label.includes("try again") || label.includes("retry") || label.includes("reload"));
                });

                if (!retryButton) return false;
                try {
                  retryButton.scrollIntoView({ block: "center", inline: "center" });
                } catch (_) {}
                retryButton.click();
                return true;
              }

              function assistantContainers(provider, promptText) {
                if (provider === "chatgpt") {
                  const assistantNodes = Array.from(document.querySelectorAll("[data-message-author-role='assistant']"));
                  const containers = assistantNodes.map(node =>
                    node.closest("article") || node.closest("[data-testid*='conversation-turn']") || node.parentElement || node
                  );
                  return uniqueNodes(containers);
                }

                const selectors = [
                  "message-content",
                  "model-response",
                  ".model-response-text",
                  "[class*='model-response']",
                  "[data-test-id='response-content']",
                  "main .response-content",
                  "main .markdown",
                  "main article",
                  "main [role='article']",
                  "main [class*='message']",
                  "main [class*='response']"
                ];
                return uniqueNodes(selectors.flatMap(selector => Array.from(document.querySelectorAll(selector))))
                  .filter(node => !isGeminiComposerNode(node))
                  .filter(node => {
                    const text = cleanText(node);
                    return !isGeminiLandingText(text) &&
                      !isGeminiBoilerplateText(text) &&
                      !isPromptEcho(text, promptText);
                  });
              }

              function latestContainer(provider, promptText) {
                const nodes = assistantContainers(provider, promptText);
                if (!nodes.length) return null;
                const sorted = nodes.slice().sort((a, b) => {
                  if (a === b) return 0;
                  const position = a.compareDocumentPosition(b);
                  if (position & Node.DOCUMENT_POSITION_FOLLOWING) return -1;
                  if (position & Node.DOCUMENT_POSITION_PRECEDING) return 1;
                  return 0;
                });
                return sorted[sorted.length - 1];
              }

              function isStreaming(provider) {
                if (provider === "chatgpt") {
                  return Boolean(
                    document.querySelector("button[aria-label*='Stop']") ||
                    document.querySelector("button[data-testid*='stop']") ||
                    document.querySelector("[aria-busy='true']")
                  );
                }

                return Boolean(
                  document.querySelector("[aria-busy='true']") ||
                  document.querySelector("[data-state='streaming']")
                );
              }

              window.__webAICapture = {
                state: null,
                observer: null,
                timer: null,

                stop() {
                  if (this.observer) {
                    this.observer.disconnect();
                    this.observer = null;
                  }
                  if (this.timer) {
                    clearInterval(this.timer);
                    this.timer = null;
                  }
                  this.state = null;
                },

                start(opts) {
                  this.stop();

                  const promptText = opts.prompt || "";
                  const baselineNode = latestContainer(opts.provider, promptText);
                  const baselineNodes = assistantContainers(opts.provider, promptText);
                  this.state = {
                    requestId: opts.requestId,
                    provider: opts.provider,
                    promptText: promptText,
                    responseFormat: opts.responseFormat || "plainText",
                    baselineCount: baselineNodes.length,
                    baselineText: cleanText(baselineNode),
                    lastText: "",
                    lastChangeAt: Date.now(),
                    startedAt: Date.now(),
                    progressAt: 0,
                    settleMs: opts.settleMs || 1800,
                    minLength: opts.minLength || 120,
                    maxWaitMs: opts.maxWaitMs || 180000,
                    contentFailureRetries: 0,
                    lastContentFailureAt: 0,
                    delivered: false
                  };

                  this.observer = new MutationObserver(() => this.scan());
                  this.observer.observe(document.body, {
                    subtree: true,
                    childList: true,
                    characterData: true,
                    attributes: true
                  });

                  this.timer = setInterval(() => this.scan(), 700);

                  post({
                    type: "debug",
                    phase: "start",
                    requestId: this.state.requestId,
                    baselineCount: this.state.baselineCount,
                    baselineLength: this.state.baselineText.length
                  });
                },

                currentTarget() {
                  const s = this.state;
                  if (!s) return null;
                  const promptText = activePromptText(s);

                  const containers = assistantContainers(s.provider, promptText);
                  if (!containers.length) return null;

                  const latest = latestContainer(s.provider, promptText);
                  const latestText = cleanText(latest);
                  if (isPromptEcho(latestText, promptText)) return null;

                  if (containers.length > s.baselineCount) {
                    return latest;
                  }

                  if (latestText && latestText !== s.baselineText) {
                    return latest;
                  }

                  return null;
                },

                scan() {
                  const s = this.state;
                  if (!s || s.delivered) return;

                  const target = this.currentTarget();
                  let text = target ? cleanText(target) : "";
                  const now = Date.now();
                  const streaming = isStreaming(s.provider);
                  const promptText = activePromptText(s);

                  if (s.provider === "gemini" && isGeminiLandingText(text)) return;
                  text = stripPromptEcho(text, promptText);
                  if (s.provider === "gemini") {
                    text = stripGeminiBoilerplate(text);
                  }
                  if (s.provider === "gemini" && isGeminiBoilerplateText(text)) return;
                  if (isPromptEcho(text, promptText)) return;

                  if (isProviderContentLoadFailure(text)) {
                    if (s.contentFailureRetries < 3 && (now - s.lastContentFailureAt) > 2200 && clickProviderRetryButton()) {
                      s.contentFailureRetries += 1;
                      s.lastContentFailureAt = now;
                      s.lastText = "";
                      s.lastChangeAt = now;
                    } else if (s.contentFailureRetries >= 3 || (now - s.startedAt) > 12000) {
                      const providerName = s.provider === "chatgpt" ? "ChatGPT" : "Web AI";
                      this.fail(providerName + " could not load the response. Try again.");
                    }
                    return;
                  }

                  if (text && text !== s.lastText) {
                    s.lastText = text;
                    s.lastChangeAt = now;
                  }

                  if (text && (now - s.progressAt) > 1000) {
                    s.progressAt = now;
                    post({
                      type: "progress",
                      requestId: s.requestId,
                      length: text.length,
                      streaming: streaming,
                      stableForMs: now - s.lastChangeAt,
                      preview: text.slice(0, 160)
                    });
                  }

                  const stable = !!s.lastText && (now - s.lastChangeAt) >= s.settleMs;
                  const hasEnoughContent = s.responseFormat === "strictJSON"
                    ? s.lastText.length >= s.minLength
                    : (s.lastText.length >= s.minLength || /\\n\\n/.test(s.lastText));

                  if (hasEnoughContent && !streaming && stable) {
                    this.deliver("stable_complete", s.lastText);
                    return;
                  }

                  if ((now - s.startedAt) > s.maxWaitMs) {
                    if (s.lastText) {
                      this.deliver("timeout_partial", s.lastText);
                    } else {
                      this.fail("Automatic response capture timed out.");
                    }
                  }
                },

                deliver(reason, text) {
                  const s = this.state;
                  if (!s || s.delivered) return;
                  const promptText = activePromptText(s);
                  text = stripPromptEcho(text, promptText);
                  if (s.provider === "gemini") {
                    text = stripGeminiBoilerplate(text);
                  }
                  if (s.provider === "gemini" && (isGeminiLandingText(text) || isGeminiBoilerplateText(text))) return;
                  if (isPromptEcho(text, promptText)) return;
                  if (isProviderContentLoadFailure(text)) {
                    const providerName = s.provider === "chatgpt" ? "ChatGPT" : "Web AI";
                    this.fail(providerName + " could not load the response. Try again.");
                    return;
                  }

                  s.delivered = true;
                  if (this.observer) this.observer.disconnect();
                  if (this.timer) clearInterval(this.timer);

                  const chunkSize = 12000;
                  const totalChunks = Math.max(1, Math.ceil(text.length / chunkSize));

                  post({
                    type: "finalBegin",
                    requestId: s.requestId,
                    reason: reason,
                    totalChunks: totalChunks,
                    totalLength: text.length
                  });

                  for (let i = 0; i < totalChunks; i += 1) {
                    post({
                      type: "finalChunk",
                      requestId: s.requestId,
                      index: i,
                      text: text.slice(i * chunkSize, (i + 1) * chunkSize)
                    });
                  }

                  post({
                    type: "finalEnd",
                    requestId: s.requestId
                  });
                },

                fail(message) {
                  const s = this.state;
                  if (!s || s.delivered) return;
                  s.delivered = true;
                  if (this.observer) this.observer.disconnect();
                  if (this.timer) clearInterval(this.timer);
                  post({
                    type: "failed",
                    requestId: s.requestId,
                    message: message
                  });
                }
              };
            })();
            """
        }

        private func buildInjectionScript() -> String {
            let provider = parent.request.provider.rawValue
            let shouldAutoCapture = parent.request.shouldAutoCapture ? "true" : "false"
            let textSource = shouldStagePromptForInjection
                ? "(window.__codexPendingPromptText || \"\")"
                : "\"\(escapedJavaScriptString(parent.request.prompt))\""

            return """
            (function() {
                const text = \(textSource);
                const provider = "\(provider)";
                const shouldAutoCapture = \(shouldAutoCapture);

                function pickFirst(list) {
                    for (let i = 0; i < list.length; i += 1) {
                        if (list[i]) return list[i];
                    }
                    return null;
                }

                function uniqueElements(list) {
                    return Array.from(new Set(list.filter(Boolean)));
                }

                function normalizeText(value) {
                    return (value || "")
                        .replace(/\\u00a0/g, " ")
                        .replace(/\\s+/g, " ")
                        .trim();
                }

                function findInput() {
                    if (provider === "chatgpt") {
                        return pickFirst([
                            document.getElementById("prompt-textarea"),
                            document.querySelector(".ProseMirror[contenteditable='true']"),
                            document.querySelector("[data-testid='composer-input'] [contenteditable='true']"),
                            document.querySelector("div[contenteditable='true'][data-placeholder]"),
                            document.querySelector("textarea"),
                            document.querySelector("[contenteditable='true']")
                        ]);
                    }

                    return pickFirst([
                        document.querySelector("rich-textarea [contenteditable='true']"),
                        document.querySelector("rich-textarea textarea"),
                        document.querySelector("rich-textarea .ql-editor"),
                        document.querySelector("[aria-label*='Enter a prompt'][contenteditable='true']"),
                        document.querySelector("[aria-label*='Enter a prompt'][role='textbox']"),
                        document.querySelector("[aria-label*='Ask Gemini'][contenteditable='true']"),
                        document.querySelector("[data-placeholder*='Enter a prompt'][contenteditable='true']"),
                        document.querySelector("[role='textbox'][contenteditable='true']"),
                        document.querySelector("[role='textbox']"),
                        document.querySelector("textarea"),
                        document.querySelector("[contenteditable='true']")
                    ]);
                }

                function editableText(el) {
                    if (!el) return "";
                    if (el.tagName === "TEXTAREA" || el.tagName === "INPUT") {
                        return el.value || "";
                    }
                    return el.innerText || el.textContent || "";
                }

                function dispatchInputEvents(el, value) {
                    try {
                        el.dispatchEvent(new InputEvent("beforeinput", {
                            bubbles: true,
                            cancelable: true,
                            composed: true,
                            inputType: "insertText",
                            data: value
                        }));
                    } catch (error) {
                    }

                    try {
                        el.dispatchEvent(new InputEvent("input", {
                            bubbles: true,
                            cancelable: true,
                            composed: true,
                            inputType: "insertText",
                            data: value
                        }));
                    } catch (error) {
                        el.dispatchEvent(new Event("input", { bubbles: true }));
                    }

                    el.dispatchEvent(new Event("change", { bubbles: true }));
                }

                function setContentEditableValue(el, value) {
                    if (!el) return false;
                    el.focus();

                    let inserted = false;
                    try {
                        const selection = window.getSelection();
                        const range = document.createRange();
                        range.selectNodeContents(el);
                        selection.removeAllRanges();
                        selection.addRange(range);
                        inserted = document.execCommand("insertText", false, value);
                    } catch (error) {
                        inserted = false;
                    }

                    if (!inserted || normalizeText(editableText(el)) !== normalizeText(value)) {
                        const lines = value.split("\\n");
                        el.innerHTML = "";
                        lines.forEach(line => {
                            const p = document.createElement("p");
                            p.textContent = line.length ? line : " ";
                            el.appendChild(p);
                        });
                    }

                    dispatchInputEvents(el, value);
                    return true;
                }

                function setValue(el, value) {
                    if (!el) return false;
                    el.focus();

                    if (provider === "gemini" && (
                        el.getAttribute("contenteditable") === "true" ||
                        el.getAttribute("role") === "textbox" ||
                        el.classList.contains("ql-editor")
                    )) {
                        return setContentEditableValue(el, value);
                    }

                    const isProseMirror = el.classList.contains("ProseMirror") || el.querySelector("p") !== null;
                    if (isProseMirror) {
                        let p = el.querySelector("p");
                        if (!p) {
                            p = document.createElement("p");
                            el.innerHTML = "";
                            el.appendChild(p);
                        }
                        p.textContent = value;
                        el.dispatchEvent(new InputEvent("input", {
                            bubbles: true,
                            cancelable: true,
                            inputType: "insertText",
                            data: value
                        }));
                        return true;
                    }

                    if (el.tagName === "TEXTAREA" || el.tagName === "INPUT") {
                        try {
                            const proto = el.tagName === "TEXTAREA" ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
                            const nativeSetter = Object.getOwnPropertyDescriptor(proto, "value").set;
                            nativeSetter.call(el, value);
                            if (el.setSelectionRange) el.setSelectionRange(value.length, value.length);
                        } catch (error) {
                            el.value = value;
                        }
                        dispatchInputEvents(el, value);
                        return true;
                    }

                    if (el.getAttribute("contenteditable") === "true") {
                        return setContentEditableValue(el, value);
                    }

                    return false;
                }

                function dispatchEnter(el) {
                    if (!el) return;
                    el.focus();

                    const eventInit = {
                        key: "Enter",
                        code: "Enter",
                        keyCode: 13,
                        which: 13,
                        bubbles: true,
                        cancelable: true,
                        composed: true,
                        shiftKey: false
                    };

                    const targets = uniqueElements([
                        el,
                        el.closest("rich-textarea"),
                        el.closest("[role='textbox']"),
                        document.activeElement,
                        document
                    ]);

                    ["keydown", "keypress", "keyup"].forEach(type => {
                        targets.forEach(target => {
                            target.dispatchEvent(new KeyboardEvent(type, eventInit));
                        });
                    });

                    const form = el.closest("form");
                    if (form && typeof form.requestSubmit === "function") {
                        form.requestSubmit();
                    }
                }

                function blurComposer(el) {
                    try {
                        if (el && typeof el.blur === "function") {
                            el.blur();
                        }
                        if (document.activeElement && typeof document.activeElement.blur === "function") {
                            document.activeElement.blur();
                        }
                        if (document.body && typeof document.body.focus === "function") {
                            document.body.focus();
                        }
                    } catch (error) {
                    }
                }

                function isUsableAction(node) {
                    if (!node) return false;
                    const rect = node.getBoundingClientRect();
                    const style = window.getComputedStyle(node);
                    return !Boolean(node.disabled) &&
                        node.getAttribute("aria-disabled") !== "true" &&
                        rect.width >= 18 &&
                        rect.height >= 18 &&
                        rect.right > 0 &&
                        rect.bottom > 0 &&
                        rect.left < window.innerWidth &&
                        rect.top < window.innerHeight &&
                        style.display !== "none" &&
                        style.visibility !== "hidden" &&
                        style.pointerEvents !== "none";
                }

                function activateAction(node, callNativeClick = true) {
                    if (!isUsableAction(node)) return false;
                    const rect = node.getBoundingClientRect();
                    const clientX = Math.max(rect.left + 1, Math.min(rect.left + rect.width / 2, rect.right - 1));
                    const clientY = Math.max(rect.top + 1, Math.min(rect.top + rect.height / 2, rect.bottom - 1));
                    try {
                        node.scrollIntoView({ block: "nearest", inline: "nearest" });
                    } catch (error) {
                    }
                    ["pointerdown", "mousedown", "pointerup", "mouseup", "click"].forEach(type => {
                        const EventClass = type.startsWith("pointer") && typeof PointerEvent !== "undefined" ? PointerEvent : MouseEvent;
                        node.dispatchEvent(new EventClass(type, {
                            bubbles: true,
                            cancelable: true,
                            view: window,
                            clientX,
                            clientY,
                            pointerId: 1,
                            pointerType: "mouse",
                            isPrimary: true,
                            button: 0,
                            buttons: type.endsWith("down") ? 1 : 0
                        }));
                    });
                    if (callNativeClick && typeof node.click === "function") {
                        node.click();
                    }
                    return true;
                }

                function recoverProviderLoadFailure() {
                    if (provider !== "chatgpt" && provider !== "gemini") return false;
                    const bodyText = ((document.body && document.body.innerText) || "").replace(/\\s+/g, " ").trim().toLowerCase();
                    const hasLoadFailure = bodyText.includes("content failed to load") ||
                        bodyText.includes("could not load content") ||
                        bodyText.includes("couldn't load content") ||
                        bodyText.includes("unable to load content") ||
                        (bodyText.includes("something went wrong") && bodyText.includes("1096"));
                    if (!hasLoadFailure) return false;

                    const retryButton = Array.from(document.querySelectorAll("button, [role='button'], a")).find(node => {
                        const label = [
                            node.textContent,
                            node.getAttribute("aria-label"),
                            node.getAttribute("title")
                        ].filter(Boolean).join(" ").replace(/\\s+/g, " ").trim().toLowerCase();
                        return label.includes("try again") || label.includes("retry");
                    });

                    if (retryButton) {
                        activateAction(retryButton);
                    }
                    return true;
                }

                function findActionFromPoint(x, y) {
                    const raw = document.elementFromPoint(x, y);
                    if (!raw) return null;
                    return raw.closest("button, [role='button'], a");
                }

                function looksLikeChatGPTSendButton(node) {
                    if (!isUsableAction(node)) return false;
                    const dataTestId = (node.getAttribute("data-testid") || "").toLowerCase();
                    const text = (node.textContent || "").trim().toLowerCase();
                    const aria = (node.getAttribute("aria-label") || "").toLowerCase();
                    const title = (node.getAttribute("title") || "").toLowerCase();
                    if (dataTestId.includes("send-button")) return true;
                    if (aria.includes("send prompt") || aria === "send message" || aria === "send") return true;
                    if (title.includes("send prompt") || title === "send message" || title === "send") return true;
                    if (text === "send") return true;
                    const rect = node.getBoundingClientRect();
                    return rect.width <= 90 && rect.height <= 90 && rect.right > window.innerWidth * 0.6 && rect.top > window.innerHeight * 0.35;
                }

                function findChatGPTSendButton(input) {
                    const directMatches = Array.from(new Set([
                        document.querySelector("button[data-testid='send-button']"),
                        document.querySelector("button[data-testid='composer-send-button']"),
                        document.querySelector("button[aria-label='Send prompt']"),
                        document.querySelector("button[aria-label='Send message']"),
                        document.querySelector("button[aria-label='Send']"),
                        document.querySelector("form button[type='submit']"),
                        document.querySelector("button[type='submit']")
                    ].filter(Boolean))).filter(looksLikeChatGPTSendButton);

                    const inputRect = input ? input.getBoundingClientRect() : null;
                    if (directMatches.length > 0) {
                        if (!inputRect) return directMatches[0];
                        return directMatches.sort((a, b) => {
                            const ar = a.getBoundingClientRect();
                            const br = b.getBoundingClientRect();
                            const aDistance = Math.abs(ar.right - inputRect.right) + Math.abs(ar.bottom - inputRect.bottom);
                            const bDistance = Math.abs(br.right - inputRect.right) + Math.abs(br.bottom - inputRect.bottom);
                            return aDistance - bDistance;
                        })[0];
                    }

                    if (inputRect) {
                        const containers = [
                            input.closest("form"),
                            input.closest("[data-testid*='composer']"),
                            input.closest("[class*='composer']"),
                            input.closest("[class*='prompt']"),
                            input.parentElement?.parentElement,
                            input.parentElement
                        ].filter(Boolean);
                        for (const container of containers) {
                            const rect = container.getBoundingClientRect();
                            if (rect.width < 180 || rect.height < 48) continue;
                            const points = [
                                [rect.right - 46, rect.bottom - 46],
                                [rect.right - 34, rect.bottom - 34],
                                [rect.right - 58, rect.bottom - 50]
                            ];
                            for (const point of points) {
                                const action = findActionFromPoint(point[0], point[1]);
                                if (looksLikeChatGPTSendButton(action)) return action;
                            }
                        }

                        const points = [
                            [Math.max(1, inputRect.right - 44), Math.max(1, inputRect.bottom - 44)],
                            [Math.max(1, inputRect.right - 32), Math.max(1, inputRect.bottom - 32)],
                            [Math.min(window.innerWidth - 24, inputRect.right + 40), Math.max(1, inputRect.bottom - 28)],
                            [window.innerWidth - 48, Math.max(1, inputRect.bottom - 32)],
                            [window.innerWidth - 64, Math.max(1, inputRect.bottom - 48)],
                            [window.innerWidth - 48, window.innerHeight - 64]
                        ];
                        for (const point of points) {
                            const action = findActionFromPoint(point[0], point[1]);
                            if (looksLikeChatGPTSendButton(action)) return action;
                        }
                    }

                    return Array.from(document.querySelectorAll("button, [role='button']"))
                        .filter(looksLikeChatGPTSendButton)
                        .sort((a, b) => {
                            const ar = a.getBoundingClientRect();
                            const br = b.getBoundingClientRect();
                            return (br.right + br.bottom) - (ar.right + ar.bottom);
                        })[0] || null;
                }

                function labelForAction(node) {
                    if (!node) return "";
                    return [
                        node.textContent,
                        node.getAttribute("aria-label"),
                        node.getAttribute("title"),
                        node.getAttribute("data-test-id"),
                        node.getAttribute("data-testid")
                    ].filter(Boolean).join(" ").replace(/\\s+/g, " ").trim().toLowerCase();
                }

                function distanceFromInput(node, input) {
                    if (!node || !input) return Number.MAX_SAFE_INTEGER;
                    const nr = node.getBoundingClientRect();
                    const ir = input.getBoundingClientRect();
                    const nx = nr.left + nr.width / 2;
                    const ny = nr.top + nr.height / 2;
                    const ix = ir.right;
                    const iy = ir.bottom;
                    return Math.abs(nx - ix) + Math.abs(ny - iy);
                }

                function looksLikeGeminiSendButton(node, input) {
                    if (!isUsableAction(node)) return false;

                    const label = labelForAction(node);
                    const blocked = ["attach", "upload", "image", "voice", "microphone", "mic", "settings", "tools", "stop"];
                    if (blocked.some(value => label.includes(value))) return false;
                    if (label.includes("send") || label.includes("submit")) return true;

                    const iconText = Array.from(node.querySelectorAll("mat-icon, .google-symbols, .material-symbols-outlined, .material-icons"))
                        .map(icon => (icon.textContent || "").trim().toLowerCase())
                        .join(" ");
                    if (/\\b(send|arrow_upward|arrow_forward)\\b/.test(iconText)) return true;

                    if (!input) return false;
                    const nr = node.getBoundingClientRect();
                    const ir = input.getBoundingClientRect();
                    const nearComposer = nr.width <= 84 &&
                        nr.height <= 84 &&
                        nr.left >= ir.left - 24 &&
                        nr.right <= ir.right + 140 &&
                        nr.top >= ir.top - 48 &&
                        nr.bottom <= ir.bottom + 140;
                    const iconOnly = Boolean(node.querySelector("svg, mat-icon, .google-symbols, .material-symbols-outlined")) ||
                        (node.textContent || "").trim().length <= 24;

                    return nearComposer && iconOnly && nr.left > ir.left + ir.width * 0.55;
                }

                function findGeminiSendButton(input) {
                    const containers = uniqueElements([
                        input?.closest("form"),
                        input?.closest("rich-textarea")?.parentElement,
                        input?.closest("[class*='composer']"),
                        input?.closest("[class*='input']"),
                        input?.closest("[class*='prompt']"),
                        input?.parentElement?.parentElement,
                        input?.parentElement
                    ]);

                    const scoped = containers.flatMap(container =>
                        Array.from(container.querySelectorAll("button, [role='button'], [aria-label], [data-test-id], [data-testid]"))
                    );
                    const iconButtons = Array.from(document.querySelectorAll("mat-icon, .google-symbols, .material-symbols-outlined, .material-icons"))
                        .map(icon => icon.closest("button, [role='button']"));
                    const global = Array.from(document.querySelectorAll("button, [role='button'], [aria-label], [data-test-id], [data-testid]"));

                    return uniqueElements(scoped.concat(iconButtons, global))
                        .filter(node => looksLikeGeminiSendButton(node, input))
                        .sort((a, b) => distanceFromInput(a, input) - distanceFromInput(b, input))[0] || null;
                }

                function findSendButton(input) {
                    if (provider === "chatgpt") {
                        return findChatGPTSendButton(input) || pickFirst([
                            document.querySelector("button[data-testid='send-button']"),
                            document.querySelector("button[data-testid='composer-send-button']"),
                            document.querySelector("button[aria-label='Send prompt']"),
                            document.querySelector("button[aria-label='Send message']"),
                            document.querySelector("button[aria-label='Send']"),
                            document.querySelector("form button[type='submit']"),
                            document.querySelector("button[type='submit']")
                        ]);
                    }

                    return findGeminiSendButton(input) || pickFirst([
                        document.querySelector("button[aria-label='Send message']"),
                        document.querySelector("button[aria-label='Send prompt']"),
                        document.querySelector("button[aria-label='Send']"),
                        document.querySelector("button[aria-label='Submit']"),
                        document.querySelector("button[type='submit']"),
                        document.querySelector("div[role='button'][aria-label*='Send']")
                    ]);
                }

                function findNewChatButton() {
                    if (provider === "chatgpt") {
                        return pickFirst([
                            document.querySelector("a[href='/']"),
                            document.querySelector("button[aria-label='New chat']"),
                            document.querySelector("a[aria-label='New chat']"),
                            Array.from(document.querySelectorAll("button, a, [role='button']")).find(node => {
                                const text = (node.textContent || "").trim();
                                return text === "New chat" || text === "Temporary chat";
                            })
                        ]);
                    }
                    if (provider !== "gemini") return null;
                    return pickFirst([
                        document.querySelector("a[href='/app']"),
                        document.querySelector("button[aria-label='New chat']"),
                        document.querySelector("a[aria-label='New chat']"),
                        Array.from(document.querySelectorAll("button, a, [role='button']")).find(node => {
                            const text = (node.textContent || "").trim();
                            return text === "New chat" || text === "Start new chat";
                        })
                    ]);
                }

                function assistantTurnCount() {
                    if (provider === "chatgpt") {
                        return document.querySelectorAll("[data-message-author-role='assistant']").length;
                    }
                    if (provider === "gemini") {
                        return document.querySelectorAll([
                            "message-content",
                            "model-response",
                            ".model-response-text",
                            "[class*='model-response']",
                            "[data-test-id='response-content']",
                            "[data-testid*='response']",
                            "[class*='response-content']",
                            "[class*='response-container']"
                        ].join(",")).length;
                    }
                    return 0;
                }

                function selectGeminiModelIfNeeded() {
                    return "ready";
                }

                if (recoverProviderLoadFailure()) return "waiting";

                if ((provider === "chatgpt" || provider === "gemini") && shouldAutoCapture) {
                    if (!window.__codexWebAINewChatState) {
                        window.__codexWebAINewChatState = "initial";
                    }

                    const state = window.__codexWebAINewChatState;
                    const hasAssistantTurns = assistantTurnCount() > 0;

                    if (state !== "ready") {
                        if (hasAssistantTurns) {
                            const newChatButton = findNewChatButton();
                            if (newChatButton) {
                                if (state === "initial") {
                                    window.__codexWebAINewChatState = "requested";
                                    newChatButton.click();
                                }
                                return "waiting";
                            }
                            if (provider === "gemini" && state === "initial") {
                                window.__codexWebAINewChatState = "requested";
                                window.location.href = "https://gemini.google.com/app";
                                return "waiting";
                            }
                        }

                        window.__codexWebAINewChatState = "ready";
                    }
                }

                const input = findInput();

                if (provider === "gemini" && window.__codexGeminiSubmissionPending === text) {
                    const pendingAge = Date.now() - (window.__codexGeminiSubmissionPendingAt || 0);
                    const startingTurns = window.__codexGeminiSubmissionTurnCount || 0;
                    const inputNow = input ? normalizeText(editableText(input)) : "";
                    if (assistantTurnCount() > startingTurns || (pendingAge > 350 && (!input || inputNow.length === 0))) {
                        window.__codexGeminiSubmissionPending = "";
                        return "success";
                    }
                    if (pendingAge < 2600) return "waiting";
                    window.__codexGeminiSubmissionPending = "";
                }

                if (!input) return "waiting";

                const geminiModelStatus = selectGeminiModelIfNeeded();
                if (geminiModelStatus === "waiting") return "waiting";

                if (!setValue(input, text)) return "waiting";

                const startingAssistantTurns = assistantTurnCount();
                const sendButton = findSendButton(input);
                if (sendButton && !sendButton.disabled) {
                    if (provider === "chatgpt" || activateAction(sendButton, false)) {
                        if (provider === "chatgpt") {
                            sendButton.click();
                            blurComposer(input);
                            return "success";
                        }
                        window.__codexGeminiSubmissionPending = text;
                        window.__codexGeminiSubmissionPendingAt = Date.now();
                        window.__codexGeminiSubmissionTurnCount = startingAssistantTurns;
                        blurComposer(input);
                        return "waiting";
                    }
                }

                dispatchEnter(input);
                blurComposer(input);

                if (provider === "gemini") {
                    window.__codexGeminiSubmissionPending = text;
                    window.__codexGeminiSubmissionPendingAt = Date.now();
                    window.__codexGeminiSubmissionTurnCount = startingAssistantTurns;
                    return "waiting";
                }

                const retryButton = findSendButton(input);
                if (retryButton && !retryButton.disabled) {
                    if (provider === "chatgpt") {
                        retryButton.click();
                        blurComposer(input);
                        return "success";
                    }
                }

                blurComposer(input);
                return "waiting";
            })();
            """
        }

        private func buildExtractionScript() -> String {
            let escapedPrompt = escapedJavaScriptString(capturePromptReference())

            let provider = parent.request.provider.rawValue

            return """
            (function() {
                const prompt = normalize(window.__codexCapturePromptText || "\(escapedPrompt)");
                const provider = "\(provider)";

                function normalize(value) {
                    return (value || "").replace(/\\s+/g, " ").trim();
                }

                function extractText(node) {
                    if (!node) return "";
                    return normalize(node.innerText || node.textContent || "");
                }

                function limitText(value, maxLength = 20000) {
                    if (!value) return "";
                    if (value.length <= maxLength) return value;
                    return value.slice(0, maxLength).trimEnd();
                }

                function longest(values) {
                    return values.reduce("", (best, current) => current.length > best.length ? current : best);
                }

                function unique(values) {
                    const seen = new Set();
                    return values.filter(value => {
                        if (!value || seen.has(value)) return false;
                        seen.add(value);
                        return true;
                    });
                }

                function uniqueNodes(nodes) {
                    return Array.from(new Set(nodes.filter(Boolean)));
                }

                function isGeminiComposerNode(node) {
                    if (!node) return false;
                    return Boolean(
                        node.closest("rich-textarea") ||
                        node.closest("textarea") ||
                        node.closest("[contenteditable='true']") ||
                        node.closest("form") ||
                        node.closest("[class*='composer']") ||
                        node.closest("[class*='input']") ||
                        node.closest("[class*='prompt']")
                    );
                }

                function isPromptEcho(value) {
                    if (!value) return true;
                    const normalizedValue = normalize(value);
                    const normalizedPrompt = prompt;
                    if (!normalizedPrompt) return false;
                    if (normalizedValue === normalizedPrompt) return true;
                    if (normalizedValue.length > 120 && normalizedPrompt.includes(normalizedValue)) return true;
                    if (normalizedValue.startsWith(normalizedPrompt) && normalizedValue.length <= normalizedPrompt.length * 1.15) return true;
                    const valuePrefix = normalizedValue.slice(0, Math.min(normalizedValue.length, 500));
                    if (valuePrefix.length >= 120 && normalizedPrompt.includes(valuePrefix)) return true;

                    if (normalizedValue.length >= 400) {
                        const probeLength = Math.min(260, normalizedValue.length);
                        const middleStart = Math.max(0, Math.floor((normalizedValue.length - probeLength) / 2));
                        const probes = [
                            normalizedValue.slice(0, probeLength),
                            normalizedValue.slice(middleStart, middleStart + probeLength),
                            normalizedValue.slice(Math.max(0, normalizedValue.length - probeLength))
                        ];
                        if (probes.filter(probe => probe.length >= 120 && normalizedPrompt.includes(probe)).length >= 2) {
                            return true;
                        }
                    }

                    const promptLines = prompt
                        .split(/\\n+/)
                        .map(line => normalize(line))
                        .filter(line => line.length >= 20);
                    if (promptLines.some(line => normalizedValue === line)) return true;

                    return false;
                }

                function stripPromptEcho(value) {
                    const text = normalize(value);
                    const normalizedPrompt = prompt;
                    if (!text || !normalizedPrompt) return text;
                    if (text === normalizedPrompt) return "";
                    if (text.startsWith(normalizedPrompt)) return normalize(text.slice(normalizedPrompt.length));
                    if (text.length > 120 && normalizedPrompt.includes(text)) return "";

                    const maxProbeLength = Math.min(1200, text.length);
                    for (let length = maxProbeLength; length >= 160; length -= 80) {
                        const probe = text.slice(0, length);
                        const promptIndex = normalizedPrompt.indexOf(probe);
                        if (promptIndex === -1) continue;

                        let matched = length;
                        while (
                            matched < text.length &&
                            promptIndex + matched < normalizedPrompt.length &&
                            text.charCodeAt(matched) === normalizedPrompt.charCodeAt(promptIndex + matched)
                        ) {
                            matched += 1;
                        }

                        if (matched >= 160) {
                            return normalize(text.slice(matched));
                        }
                    }
                    return text;
                }

                function stripGeminiBoilerplate(value) {
                    let text = normalize(value);
                    if (!text) return "";
                    const patterns = [
                        /gemini is ai and can make mistakes[^]*$/i,
                        /your privacy[^]*gemini[^]*$/i,
                        /google terms[^]*privacy policy[^]*$/i,
                        /gemini apps activity is off/i
                    ];
                    patterns.forEach(pattern => {
                        text = text.replace(pattern, " ").trim();
                    });
                    return normalize(text);
                }

                function isPageBoilerplate(value) {
                    const text = normalize(value).toLowerCase();
                    if (!text) return true;
                    if (text.includes("content failed to load")) return true;
                    if (text.includes("could not load content")) return true;
                    if (text.includes("couldn't load content")) return true;
                    if (text.includes("unable to load content")) return true;
                    if (text.includes("something went wrong") && text.includes("1096")) return true;
                    if (text === "gemini apps activity is off") return true;
                    if (text.includes("apps activity is off") && text.length < 120) return true;
                    if (text.includes("gemini is ai and can make mistakes")) return true;
                    if (text.includes("your privacy") && text.includes("gemini")) return true;
                    if (text.includes("google apps")) return true;
                    if (text.includes("google terms") && text.includes("privacy policy")) return true;
                    if (text.includes("sign in") && text.length < 120) return true;
                    if (text === "new chat" || text === "tools" || text === "flash" || text === "3.1 flash-lite") return true;
                    return false;
                }

                function isStreaming() {
                    if (provider === "chatgpt") {
                        return Boolean(
                            document.querySelector("button[aria-label*='Stop']") ||
                            document.querySelector("button[aria-label*='Stop generating']") ||
                            document.querySelector("button[data-testid*='stop']") ||
                            document.querySelector("button svg") && Array.from(document.querySelectorAll("button")).some(button => {
                                const label = normalize(button.getAttribute("aria-label") || "");
                                return label.includes("stop");
                            })
                        );
                    }

                    return Boolean(
                        document.querySelector("[data-state='streaming']") ||
                        document.querySelector("button[aria-label*='Stop']") ||
                        document.querySelector("button[aria-label*='stop']") ||
                        document.querySelector("[aria-label*='Stop']") ||
                        document.querySelector("[aria-label*='stop']")
                    );
                }

                function assistantContentFromContainer(container) {
                    if (!container) return "";

                    const selectors = [
                        "[data-message-author-role='assistant'] [data-testid='conversation-turn-content']",
                        "[data-message-author-role='assistant'] .markdown",
                        "[data-message-author-role='assistant'] .prose",
                        "[data-message-author-role='assistant'] [class*='markdown']",
                        "[data-message-author-role='assistant'] [class*='prose']",
                        "[data-testid='conversation-turn-content']",
                        ".markdown",
                        ".prose",
                        "[class*='markdown']",
                        "[class*='prose']",
                        "p",
                        "li",
                        "h1, h2, h3, h4",
                        "pre",
                        "code",
                        "table"
                    ];

                    const fragments = selectors.flatMap(selector =>
                        Array.from(container.querySelectorAll(selector)).map(node => extractText(node))
                    );

                    const cleaned = unique(fragments)
                        .filter(value => value.length > 0)
                        .filter(value => !isPromptEcho(value))
                        .filter(value => !isPageBoilerplate(value));

                    const fallback = extractText(container);
                    return longest(cleaned) || (isPageBoilerplate(fallback) ? "" : fallback);
                }

                function chatGPTCandidates() {
                    const assistantNodes = Array.from(document.querySelectorAll("[data-message-author-role='assistant']"));
                    const containers = assistantNodes.map(node =>
                        node.closest("article") || node.closest("[data-testid*='conversation-turn']") || node.parentElement || node
                    );
                    const fallbackArticles = Array.from(document.querySelectorAll("main article"));
                    return uniqueNodes(containers.concat(fallbackArticles)).map(container => ({
                        node: container,
                        text: assistantContentFromContainer(container)
                    }));
                }

                function geminiCandidates() {
                    const selectors = [
                        "message-content",
                        "model-response",
                        ".model-response-text",
                        "[class*='model-response']",
                        "[data-test-id='response-content']",
                        "[data-testid*='response']",
                        "[class*='response-content']",
                        "[class*='response-container']",
                        "[class*='markdown']",
                        "[aria-live='polite']",
                        "[aria-live='assertive']",
                        "main [dir='ltr']",
                        "main p",
                        "main li",
                        "main .response-content",
                        "main .markdown"
                    ];
                    const nodes = selectors.flatMap(selector => Array.from(document.querySelectorAll(selector)));
                    const containers = nodes.map(node =>
                        node.closest("message-content") ||
                        node.closest("model-response") ||
                        node.closest("[role='article']") ||
                        node.closest("article") ||
                        node.closest("[class*='message']") ||
                        node.closest("[class*='response']") ||
                        node.parentElement ||
                        node
                    );
                    return uniqueNodes(containers)
                        .filter(node => !isGeminiComposerNode(node))
                        .map(node => ({ node, text: extractText(node) }));
                }

                function genericCandidates() {
                    const nodes = Array.from(document.querySelectorAll("main article, main [role='article'], main [class*='message'], main [class*='response']"));
                    return uniqueNodes(nodes).map(node => ({ node, text: extractText(node) }));
                }

                function pickLatestCandidate(candidates) {
                    const filtered = candidates
                        .map(candidate => ({
                            node: candidate.node,
                            text: limitText(provider === "gemini"
                                ? stripGeminiBoilerplate(stripPromptEcho(candidate.text))
                                : stripPromptEcho(candidate.text))
                        }))
                        .filter(candidate => candidate.text.length > 24)
                        .filter(candidate => !isPromptEcho(candidate.text))
                        .filter(candidate => !isPageBoilerplate(candidate.text));

                    if (!filtered.length) return "";

                    filtered.sort((a, b) => {
                        if (a.node === b.node) return 0;
                        const position = a.node.compareDocumentPosition(b.node);
                        if (position & Node.DOCUMENT_POSITION_FOLLOWING) return -1;
                        if (position & Node.DOCUMENT_POSITION_PRECEDING) return 1;
                        return 0;
                    });

                    return filtered[filtered.length - 1].text;
                }

                const providerSpecific = provider === "chatgpt" ? chatGPTCandidates() : geminiCandidates();
                const latest = pickLatestCandidate(providerSpecific.concat(genericCandidates()));
                const status = latest ? (isStreaming() ? "streaming" : "found") : "waiting";
                return JSON.stringify({ status, text: latest });
            })();
            """
        }

        private func copyToPasteboard(_ text: String) {
            #if os(iOS)
            UIPasteboard.general.string = text
            #elseif os(macOS)
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            #endif
        }
    }
}
