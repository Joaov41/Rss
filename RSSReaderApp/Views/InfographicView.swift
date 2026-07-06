import SwiftUI
import WebKit
#if os(macOS)
import AppKit
#endif

struct InfographicView: View {
    let htmlData: Data?
    var title: String = "Infographic"
    var filePrefix: String = "infographic"
    var loadingLabel: String? = nil
    var emptyLabel: String? = nil
    var onMinimize: (() -> Void)? = nil
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) var dismiss
    @State private var isSaving = false
    @State private var saveMessage: String?
    @State private var isLoading = true
    @State private var isCapturingSnapshot = false
    @State private var webViewRef: WKWebView?
    @State private var shareURL: URL?
    @State private var showShareSheet = false
    @State private var isAskingAI = false
    @State private var askAIPrompt = ""
    @State private var askAIResponse = ""
    @State private var showAskAIResponseSheet = false
    
    private var loadingText: String {
        loadingLabel ?? "Rendering \(title.lowercased())…"
    }
    
    private var emptyText: String {
        emptyLabel ?? "Unable to load \(title.lowercased())"
    }
    
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                if let data = htmlData, let htmlString = String(data: data, encoding: .utf8) {
                    ZStack {
                        WebView(htmlContent: htmlString,
                                webView: $webViewRef,
                                isLoading: $isLoading,
                                onAskAISelection: handleAskAISelection(selectedText:context:))
                            .edgesIgnoringSafeArea(.bottom)
                        if isLoading {
                            ProgressView(loadingText)
                                .padding(12)
                                .background(.ultraThinMaterial)
                                .cornerRadius(12)
                        } else if isAskingAI {
                            ProgressView("Asking AI...")
                                .padding(12)
                                .background(.ultraThinMaterial)
                                .cornerRadius(12)
                        }
                    }
                        .edgesIgnoringSafeArea(.bottom)
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.largeTitle)
                            .foregroundColor(.secondary)
                        Text(emptyText)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle(title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    if let onMinimize = onMinimize {
                        Button {
                            onMinimize()
                        } label: {
                            Label("Minimize", systemImage: "arrow.down.right.and.arrow.up.left")
                        }
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button(action: snapshotAndCopyImage) {
                        Label("Copy Image", systemImage: "square.on.square")
                    }
                    .disabled(htmlData == nil || webViewRef == nil || isLoading || isCapturingSnapshot)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button(action: snapshotAndSaveImage) {
                        Label("Save Image", systemImage: "arrow.down.doc")
                    }
                    .disabled(htmlData == nil || webViewRef == nil || isLoading || isCapturingSnapshot || isSaving)
                }
            }
            .overlay(alignment: .bottom) {
                if let message = saveMessage {
                    Text(message)
                        .font(.caption)
                        .padding(8)
                        .background(.ultraThinMaterial)
                        .cornerRadius(8)
                        .padding(.bottom, 20)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .onAppear {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                withAnimation {
                                    saveMessage = nil
                                }
                            }
                        }
                }
            }
            #if os(iOS)
            .sheet(isPresented: $showShareSheet, onDismiss: { shareURL = nil }) {
                if let shareURL {
                    ShareSheet(activityItems: [shareURL])
                        .presentationDetents([.medium, .large])
                }
            }
            .sheet(isPresented: $showAskAIResponseSheet) {
                AskAIResponseSheet(
                    question: askAIPrompt,
                    answer: askAIResponse,
                    onCopy: copyAskAIResponseToClipboard
                )
                .presentationDetents([.medium, .large])
            }
            #endif
        }
        #if os(macOS)
        .frame(minWidth: 600, minHeight: 800)
        #endif
    }
    
    private func copyHTMLToClipboard() {
        guard let data = htmlData, let htmlString = String(data: data, encoding: .utf8) else { return }
        #if os(iOS)
        UIPasteboard.general.string = htmlString
        #elseif os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(htmlString, forType: .string)
        #endif
        withAnimation {
            saveMessage = "Copied HTML to clipboard"
        }
    }

    private func captureSnapshot(_ completion: @escaping (Data?) -> Void) {
        guard let webViewRef else { completion(nil); return }
        let config = WKSnapshotConfiguration()
        config.afterScreenUpdates = true
        #if os(iOS)
        let contentSize = webViewRef.scrollView.contentSize
        #elseif os(macOS)
        let contentSize = webViewRef.bounds.size
        #endif
        if contentSize.width > 0 && contentSize.height > 0 {
            #if os(iOS)
            let maxPixels: CGFloat = 24_000_000
            let scale = UIScreen.main.scale
            let maxPointsArea = maxPixels / max(1, (scale * scale))
            let area = contentSize.width * contentSize.height

            if area > maxPointsArea {
                let aspect = max(0.1, contentSize.height / max(1, contentSize.width))
                let targetWidth = min(contentSize.width, sqrt(maxPointsArea / aspect))
                let targetHeight = min(contentSize.height, targetWidth * aspect)
                config.rect = CGRect(origin: .zero, size: CGSize(width: targetWidth, height: targetHeight))
                DispatchQueue.main.async {
                    withAnimation {
                        saveMessage = "Snapshot cropped (content too large)"
                    }
                }
            } else {
                config.rect = CGRect(origin: .zero, size: contentSize)
            }
            #else
            config.rect = CGRect(origin: .zero, size: contentSize)
            #endif
        }

        webViewRef.takeSnapshot(with: config) { image, error in
            DispatchQueue.main.async {
                guard error == nil else { completion(nil); return }
                #if os(iOS)
                completion(image?.pngData())
                #elseif os(macOS)
                if let image, let tiff = image.tiffRepresentation,
                   let rep = NSBitmapImageRep(data: tiff),
                   let png = rep.representation(using: .png, properties: [:]) {
                    completion(png)
                } else {
                    completion(nil)
                }
                #endif
            }
        }
    }

    private func snapshotAndCopyImage() {
        guard htmlData != nil else {
            withAnimation { saveMessage = "Nothing to copy" }
            return
        }
        isCapturingSnapshot = true
        captureSnapshot { data in
            DispatchQueue.main.async {
                self.isCapturingSnapshot = false
                guard let data else {
                    withAnimation { self.saveMessage = "Snapshot failed" }
                    return
                }
                #if os(iOS)
                if let image = UIImage(data: data) {
                    UIPasteboard.general.image = image
                    withAnimation { self.saveMessage = "Copied image to clipboard" }
                } else {
                    withAnimation { self.saveMessage = "Snapshot failed" }
                }
                #elseif os(macOS)
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setData(data, forType: .png)
                withAnimation { self.saveMessage = "Copied image to clipboard" }
                #endif
            }
        }
    }

    private func snapshotAndSaveImage() {
        guard htmlData != nil else {
            withAnimation { saveMessage = "Nothing to save" }
            return
        }
        isCapturingSnapshot = true
        isSaving = true
        captureSnapshot { data in
            DispatchQueue.main.async {
                self.isCapturingSnapshot = false
                self.isSaving = false
                guard let data else {
                    withAnimation { self.saveMessage = "Save failed" }
                    return
                }
                #if os(iOS)
                if let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
                    let filename = "\(filePrefix)-\(Int(Date().timeIntervalSince1970)).png"
                    let url = documents.appendingPathComponent(filename)
                    do {
                        try data.write(to: url)
                        withAnimation { self.saveMessage = "Saved to Files: \(filename)" }
                        self.shareURL = url
                        self.showShareSheet = true
                    } catch {
                        withAnimation { self.saveMessage = "Save failed" }
                    }
                } else {
                    withAnimation { self.saveMessage = "Save failed" }
                }
                #elseif os(macOS)
                if let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first {
                    let filename = "\(filePrefix)-\(Int(Date().timeIntervalSince1970)).png"
                    let url = downloads.appendingPathComponent(filename)
                    do {
                        try data.write(to: url)
                        withAnimation { self.saveMessage = "Saved to \(url.lastPathComponent)" }
                    } catch {
                        withAnimation { self.saveMessage = "Save failed" }
                    }
                } else {
                    withAnimation { self.saveMessage = "Save failed" }
                }
                #endif
            }
        }
    }

    private func handleAskAISelection(selectedText: String, context: String) {
        guard !isAskingAI else { return }
        let prompt = buildAskAISelectionPrompt(selectedText: selectedText, extractedContext: context)
        guard !prompt.isEmpty else { return }

        askAIPrompt = prompt
        askAIResponse = ""
        isAskingAI = true

        appState.askQuestionAboutGlobalSummary(question: prompt) { answer in
            DispatchQueue.main.async {
                self.isAskingAI = false
                self.askAIResponse = formatAskAIResponseForDisplay(answer)
                self.showAskAIResponseSheet = true
            }
        }
    }

    private func copyAskAIResponseToClipboard() {
        guard !askAIResponse.isEmpty else { return }
        #if os(iOS)
        UIPasteboard.general.string = askAIResponse
        #elseif os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(askAIResponse, forType: .string)
        #endif
    }
}

#if os(iOS)
struct WebView: UIViewRepresentable {
    let htmlContent: String
    @Binding var webView: WKWebView?
    @Binding var isLoading: Bool
    var onAskAISelection: ((String, String) -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.preferences.javaScriptEnabled = true
        let webView = AskAIEnabledWKWebView(frame: .zero, configuration: config)
        webView.onAskAISelection = { action, selectedText, context in
            guard action == .standard else { return }
            onAskAISelection?(selectedText, context)
        }
        webView.navigationDelegate = context.coordinator
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        DispatchQueue.main.async {
            self.webView = webView
        }
        context.coordinator.lastHTML = htmlContent
        webView.loadHTMLString(htmlContent, baseURL: nil)
        return webView
    }
    
    func updateUIView(_ uiView: WKWebView, context: Context) {
        if let askAIWebView = uiView as? AskAIEnabledWKWebView {
            askAIWebView.onAskAISelection = { action, selectedText, context in
                guard action == .standard else { return }
                onAskAISelection?(selectedText, context)
            }
        }
        guard context.coordinator.lastHTML != htmlContent else { return }
        context.coordinator.lastHTML = htmlContent
        uiView.loadHTMLString(htmlContent, baseURL: nil)
    }

    class Coordinator: NSObject, WKNavigationDelegate {
        var parent: WebView
        var lastHTML: String?
        init(parent: WebView) {
            self.parent = parent
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            parent.isLoading = true
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.isLoading = false
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            parent.isLoading = false
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            parent.isLoading = false
        }

        // Handle link clicks - open external links in Safari
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            // Allow the initial HTML load
            if navigationAction.navigationType == .other {
                decisionHandler(.allow)
                return
            }

            // For link clicks, open in Safari
            if let url = navigationAction.request.url,
               navigationAction.navigationType == .linkActivated {
                UIApplication.shared.open(url)
                decisionHandler(.cancel)
                return
            }

            decisionHandler(.cancel)
        }
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
#elseif os(macOS)
struct WebView: NSViewRepresentable {
    let htmlContent: String
    @Binding var webView: WKWebView?
    @Binding var isLoading: Bool
    var onAskAISelection: ((String, String) -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.preferences.javaScriptEnabled = false
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        DispatchQueue.main.async {
            self.webView = webView
        }
        context.coordinator.lastHTML = htmlContent
        webView.loadHTMLString(htmlContent, baseURL: nil)
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        guard context.coordinator.lastHTML != htmlContent else { return }
        context.coordinator.lastHTML = htmlContent
        nsView.loadHTMLString(htmlContent, baseURL: nil)
    }

    class Coordinator: NSObject, WKNavigationDelegate {
        var parent: WebView
        var lastHTML: String?
        init(parent: WebView) {
            self.parent = parent
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            parent.isLoading = true
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.isLoading = false
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            parent.isLoading = false
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            parent.isLoading = false
        }

        // Handle link clicks - open external links in default browser
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            // Allow the initial HTML load
            if navigationAction.navigationType == .other {
                decisionHandler(.allow)
                return
            }

            // For link clicks, open in default browser
            if let url = navigationAction.request.url,
               navigationAction.navigationType == .linkActivated {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
                return
            }

            decisionHandler(.cancel)
        }
    }
}
#endif
