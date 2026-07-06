import SwiftUI
#if os(iOS)
import UIKit
import WebKit
#endif

func cleanMarkdownArtifactsForDisplay(_ input: String) -> String {
    var value = input
    value = value.replacingOccurrences(of: "\r\n", with: "\n")
    value = value.replacingOccurrences(of: "\r", with: "\n")
    value = value.replacingOccurrences(of: "(?s)```[a-zA-Z0-9_-]*\\s*(.*?)\\s*```", with: "$1", options: .regularExpression)
    value = value.replacingOccurrences(of: "```", with: "")
    value = value.replacingOccurrences(of: "\\*\\*(.*?)\\*\\*", with: "$1", options: .regularExpression)
    value = value.replacingOccurrences(of: "\\*(.*?)\\*", with: "$1", options: .regularExpression)
    value = value.replacingOccurrences(of: "__(.*?)__", with: "$1", options: .regularExpression)
    value = value.replacingOccurrences(of: "_(.*?)_", with: "$1", options: .regularExpression)
    value = value.replacingOccurrences(of: "`([^`]*)`", with: "$1", options: .regularExpression)
    value = value.replacingOccurrences(of: "(?m)^\\s{0,3}#{1,6}\\s*", with: "", options: .regularExpression)
    value = value.replacingOccurrences(of: "(?m)(^\\s*[-•]?\\s*)#{1,6}\\s*", with: "$1", options: .regularExpression)
    value = value.replacingOccurrences(of: "(?m)^\\s*\\*\\s+", with: "• ", options: .regularExpression)
    value = value.replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
    return value.trimmingCharacters(in: .whitespacesAndNewlines)
}

func cleanAndFormatCommentSummaryForDisplay(_ input: String) -> String {
    var value = cleanMarkdownArtifactsForDisplay(input)
    guard !value.isEmpty else { return value }

    if !value.contains("\n\n") {
        let normalized = value
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let marked = normalized.replacingOccurrences(
            of: "([\\.\\!\\?])\\s+(?=[A-Z0-9])",
            with: "$1|||",
            options: .regularExpression
        )
        let sentences = marked
            .components(separatedBy: "|||")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if sentences.count >= 2 {
            value = sentences.joined(separator: "\n\n")
        } else {
            value = normalized
        }
    }

    value = value.replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
    return value.trimmingCharacters(in: .whitespacesAndNewlines)
}

func formatAskAIResponseForDisplay(_ input: String) -> String {
    var value = cleanMarkdownArtifactsForDisplay(input)
    guard !value.isEmpty else { return value }

    if !value.contains("\n\n") && !value.contains("\n") && value.count > 180 {
        let normalized = value
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let marked = normalized.replacingOccurrences(
            of: "([a-z0-9][\\.\\!\\?])\\s+(?=[A-Z0-9])",
            with: "$1|||",
            options: .regularExpression
        )
        let sentences = marked
            .components(separatedBy: "|||")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if sentences.count >= 2 {
            value = sentences.joined(separator: "\n\n")
        } else {
            value = normalized
        }
    }

    value = value.replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
    return value.trimmingCharacters(in: .whitespacesAndNewlines)
}

func buildAskAISelectionPrompt(selectedText: String, extractedContext: String) -> String {
    buildAskAISelectionPrompt(
        selectedText: selectedText,
        extractedContext: extractedContext,
        sourceContext: "",
        sourceLabel: ""
    )
}

func buildAskAISelectionPrompt(
    selectedText: String,
    extractedContext: String,
    sourceContext: String,
    sourceLabel: String = "Original source"
) -> String {
    func normalized(_ value: String, maxCharacters: Int) -> String {
        var normalized = value
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if normalized.count > maxCharacters {
            normalized = String(normalized.prefix(maxCharacters))
        }

        return normalized
    }

    let selected = normalized(selectedText, maxCharacters: 1_500)
    let context = normalized(extractedContext, maxCharacters: 8_000)
    let source = normalized(sourceContext, maxCharacters: 24_000)
    let label = normalized(sourceLabel, maxCharacters: 120)

    guard !selected.isEmpty else {
        return ""
    }

    if !source.isEmpty {
        return """
        Answer the question using only the selected text, nearby rendered context, and original source material.

        Rules:
        - Return plain text only.
        - Do not use Markdown symbols, headings, bullets, or code fences.
        - Use short paragraphs separated by a blank line when the answer has multiple ideas.
        - Treat the selected text as the thing being asked about.
        - Use the original source material to verify, explain, or add relevant detail.
        - If the original source material does not answer it, say the information is not available in the source.

        Question:
        What is said about this selected text in the original source?

        Selected text:
        \(selected)

        Nearby rendered context:
        \(context.isEmpty ? "(No nearby rendered context was captured.)" : context)

        \(label.isEmpty ? "Original source" : label):
        \(source)
        """
    }

    if context.isEmpty {
        return """
        Answer the question using only the selected text.

        Rules:
        - Return plain text only.
        - Do not use Markdown symbols, headings, bullets, or code fences.
        - Use short paragraphs separated by a blank line when the answer has multiple ideas.
        - If the selected text does not answer it, say the information is not available in the selection.

        Question:
        What is said about this selected text?

        Selected text:
        \(selected)
        """
    }

    return """
    Answer the question using only the selected text and extracted context.

    Rules:
    - Return plain text only.
    - Do not use Markdown symbols, headings, bullets, or code fences.
    - Use short paragraphs separated by a blank line when the answer has multiple ideas.
    - If the context does not answer it, say the information is not available in the context.

    Question:
    What is said about this selected text in the context?

    Selected text:
    \(selected)

    Extracted context:
    \(context)
    """
}

enum AskAISelectionAction {
    case standard
    case web
}

struct AskAIWebView: View {
    let content: String

    var body: some View {
        ScrollView {
            Text(formatAskAIResponseForDisplay(content))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .textSelection(.enabled)
        }
    }
}

struct AskAIResponseSheet: View {
    let question: String
    let answer: String
    var onCopy: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            AskAIWebView(content: answer.isEmpty ? "No answer available." : answer)
            .navigationTitle("Ask AI")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        onCopy?()
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                    .disabled(answer.isEmpty)
                }
            }
        }
    }
}

struct AskAILoadingOverlay: View {
    var message: String = "Asking AI..."

    var body: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text(message)
                .font(.callout.weight(.medium))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(
            Capsule()
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.16), radius: 14, x: 0, y: 6)
        .accessibilityElement(children: .combine)
    }
}

extension View {
    func askAILoadingOverlay(_ isPresented: Bool, message: String = "Asking AI...") -> some View {
        overlay {
            if isPresented {
                AskAILoadingOverlay(message: message)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
                    .allowsHitTesting(false)
                    .zIndex(10_000)
            }
        }
        .animation(.easeInOut(duration: 0.16), value: isPresented)
    }
}

#if os(iOS)
private func configureSelectableTextView(
    _ textView: AskAITextView,
    onAskAI: ((AskAISelectionAction, String, String) -> Void)?,
    supportsStandardAskAI: Bool,
    supportsWebAskAI: Bool
) {
    textView.backgroundColor = .clear
    textView.isEditable = false
    textView.isSelectable = true
    textView.isScrollEnabled = false
    textView.textContainerInset = .zero
    textView.textContainer.lineFragmentPadding = 0
    textView.adjustsFontForContentSizeCategory = true
    textView.font = .preferredFont(forTextStyle: .body)
    textView.textColor = UIColor(white: 0.96, alpha: 1.0)
    textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    textView.setContentHuggingPriority(.required, for: .vertical)
    textView.setContentCompressionResistancePriority(.required, for: .vertical)
    textView.onAskAISelection = onAskAI
    textView.supportsStandardAskAI = supportsStandardAskAI
    textView.supportsWebAskAI = supportsWebAskAI
}

struct SelectableText: UIViewRepresentable {
    let text: String
    var onAskAI: ((String, String) -> Void)? = nil
    var onAskAIWeb: ((String, String) -> Void)? = nil
    var textIsPrecleaned: Bool = false

    func makeUIView(context: Context) -> AskAITextView {
        let textView = AskAITextView()
        configureSelectableTextView(
            textView,
            onAskAI: selectionHandler,
            supportsStandardAskAI: onAskAI != nil,
            supportsWebAskAI: onAskAIWeb != nil
        )
        applyText(resolvedText, on: textView)
        return textView
    }

    func updateUIView(_ uiView: AskAITextView, context: Context) {
        uiView.onAskAISelection = selectionHandler
        uiView.supportsStandardAskAI = onAskAI != nil
        uiView.supportsWebAskAI = onAskAIWeb != nil
        applyText(resolvedText, on: uiView)
    }

    @available(iOS 16.0, *)
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: AskAITextView, context: Context) -> CGSize? {
        let width = proposal.width ?? uiView.bounds.width
        guard width > 0 else { return nil }
        let fitting = uiView.cachedSizeThatFits(width: width)
        return CGSize(width: width, height: ceil(fitting.height))
    }

    private var resolvedText: String {
        textIsPrecleaned ? text : cleanMarkdownArtifactsForDisplay(text)
    }

    private var selectionHandler: ((AskAISelectionAction, String, String) -> Void)? {
        guard onAskAI != nil || onAskAIWeb != nil else { return nil }
        return { action, selectedText, context in
            switch action {
            case .standard:
                onAskAI?(selectedText, context)
            case .web:
                onAskAIWeb?(selectedText, context)
            }
        }
    }

    private func applyText(_ value: String, on textView: AskAITextView) {
        guard textView.currentRenderedText != value else { return }
        textView.prepareForDisplay(text: value, layoutWidth: textView.bounds.width)
    }
}

struct SelectableTextPrewarm: UIViewRepresentable {
    let text: String
    let width: CGFloat
    var textIsPrecleaned: Bool = false
    var onPrepared: (() -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(onPrepared: onPrepared)
    }

    func makeUIView(context: Context) -> AskAITextView {
        let textView = AskAITextView()
        configureSelectableTextView(
            textView,
            onAskAI: nil,
            supportsStandardAskAI: false,
            supportsWebAskAI: false
        )
        textView.isUserInteractionEnabled = false
        textView.alpha = 0.01
        prepare(textView, coordinator: context.coordinator)
        return textView
    }

    func updateUIView(_ uiView: AskAITextView, context: Context) {
        prepare(uiView, coordinator: context.coordinator)
    }

    private var resolvedText: String {
        textIsPrecleaned ? text : cleanMarkdownArtifactsForDisplay(text)
    }

    private func prepare(_ textView: AskAITextView, coordinator: Coordinator) {
        textView.prepareForDisplay(text: resolvedText, layoutWidth: max(1, width))
        guard !coordinator.didNotifyPrepared else { return }
        coordinator.didNotifyPrepared = true
        DispatchQueue.main.async {
            coordinator.onPrepared?()
        }
    }

    final class Coordinator {
        var didNotifyPrepared = false
        let onPrepared: (() -> Void)?

        init(onPrepared: (() -> Void)?) {
            self.onPrepared = onPrepared
        }
    }
}

final class AskAITextView: UITextView, UITextViewDelegate {
    var onAskAISelection: ((AskAISelectionAction, String, String) -> Void)?
    var supportsStandardAskAI = false
    var supportsWebAskAI = false
    private(set) var currentRenderedText: String = ""
    private var lastMeasuredWidth: CGFloat = 0
    private var lastMeasuredSize: CGSize = .zero
    private static var didInstallAskAIMenuItem = false

    override var canBecomeFirstResponder: Bool { true }

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        delegate = self
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        delegate = self
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        installAskAIMenuItem()
    }

    func prepareForDisplay(text: String, layoutWidth: CGFloat) {
        let clampedWidth = max(1, layoutWidth)
        let textChanged = currentRenderedText != text
        let widthChanged = abs(lastMeasuredWidth - clampedWidth) > 0.5

        if textChanged {
            self.text = text
            currentRenderedText = text
        }

        installAskAIMenuItem()

        guard textChanged || widthChanged else { return }

        bounds.size.width = clampedWidth
        setNeedsLayout()
        layoutIfNeeded()
        lastMeasuredWidth = clampedWidth
        lastMeasuredSize = super.sizeThatFits(CGSize(width: clampedWidth, height: .greatestFiniteMagnitude))
        invalidateIntrinsicContentSize()
    }

    func cachedSizeThatFits(width: CGFloat) -> CGSize {
        let clampedWidth = max(1, width)
        if abs(lastMeasuredWidth - clampedWidth) <= 0.5, lastMeasuredSize != .zero {
            return lastMeasuredSize
        }
        prepareForDisplay(text: currentRenderedText, layoutWidth: clampedWidth)
        return lastMeasuredSize == .zero ? super.sizeThatFits(CGSize(width: clampedWidth, height: .greatestFiniteMagnitude)) : lastMeasuredSize
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(handleAskAIAction(_:)) {
            return supportsStandardAskAI && hasSelectedText
        }

        if action == #selector(handleAskAIWebAction(_:)) {
            return supportsWebAskAI && hasSelectedText
        }

        if usesCompactEditMenu {
            let allowedCompactActions: Set<Selector> = [
                #selector(UIResponderStandardEditActions.copy(_:)),
                #selector(UIResponderStandardEditActions.select(_:)),
                #selector(UIResponderStandardEditActions.selectAll(_:))
            ]
            guard allowedCompactActions.contains(action) else { return false }
        }

        return super.canPerformAction(action, withSender: sender)
    }

    @available(iOS 16.0, *)
    func textView(_ textView: UITextView, editMenuForTextIn range: NSRange, suggestedActions: [UIMenuElement]) -> UIMenu? {
        guard usesCompactEditMenu, hasSelectedText else { return nil }

        var actions: [UIMenuElement] = [
            UIAction(title: "Copy", image: UIImage(systemName: "doc.on.doc")) { [weak self] _ in
                self?.copySelectedTextToPasteboard()
            }
        ]

        if supportsStandardAskAI {
            actions.append(
                UIAction(title: "Ask AI", image: UIImage(systemName: "questionmark.circle")) { [weak self] _ in
                    self?.handleAskAISelection(action: .standard)
                }
            )
        }

        if supportsWebAskAI {
            actions.append(
                UIAction(title: "Ask Web", image: UIImage(systemName: "globe")) { [weak self] _ in
                    self?.handleAskAISelection(action: .web)
                }
            )
        }

        return UIMenu(children: actions)
    }

    @objc private func handleAskAIAction(_ sender: Any?) {
        handleAskAISelection(action: .standard)
    }

    @objc private func handleAskAIWebAction(_ sender: Any?) {
        handleAskAISelection(action: .web)
    }

    private var hasSelectedText: Bool {
        let range = selectedRange
        return range.location != NSNotFound && range.length > 0
    }

    private var usesCompactEditMenu: Bool {
        guard let window else { return false }
        return window.bounds.width < 700
    }

    private func copySelectedTextToPasteboard() {
        let range = selectedRange
        guard range.location != NSNotFound, range.length > 0 else { return }

        let nsText = text as NSString
        guard NSMaxRange(range) <= nsText.length else { return }
        UIPasteboard.general.string = nsText.substring(with: range)
    }

    private func handleAskAISelection(action: AskAISelectionAction) {
        let range = selectedRange
        guard range.location != NSNotFound, range.length > 0 else { return }

        let nsText = text as NSString
        guard NSMaxRange(range) <= nsText.length else { return }
        let selected = nsText.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !selected.isEmpty else { return }

        let window = 320
        let start = max(0, range.location - window)
        let end = min(nsText.length, NSMaxRange(range) + window)
        let contextRange = NSRange(location: start, length: max(0, end - start))
        let context = nsText.substring(with: contextRange)

        onAskAISelection?(action, selected, context)
    }

    private func installAskAIMenuItem() {
        guard !Self.didInstallAskAIMenuItem else { return }
        let standardSelector = #selector(handleAskAIAction(_:))
        let webSelector = #selector(handleAskAIWebAction(_:))
        var menuItems = UIMenuController.shared.menuItems ?? []
        if !menuItems.contains(where: { $0.action == standardSelector }) {
            menuItems.append(UIMenuItem(title: "Ask AI", action: standardSelector))
        }
        if !menuItems.contains(where: { $0.action == webSelector }) {
            menuItems.append(UIMenuItem(title: "Ask AI Web", action: webSelector))
        }
        UIMenuController.shared.menuItems = menuItems
        Self.didInstallAskAIMenuItem = true
    }
}

final class AskAIEnabledWKWebView: WKWebView {
    var onAskAISelection: ((AskAISelectionAction, String, String) -> Void)?

    override var canBecomeFirstResponder: Bool { true }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        installAskAIMenuItem()
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(handleAskAIAction(_:)) {
            return onAskAISelection != nil
        }

        if action == #selector(handleAskAIWebAction(_:)) {
            return false
        }

        if usesCompactEditMenu {
            let allowedCompactActions: Set<Selector> = [
                #selector(UIResponderStandardEditActions.copy(_:)),
                #selector(UIResponderStandardEditActions.select(_:)),
                #selector(UIResponderStandardEditActions.selectAll(_:))
            ]
            guard allowedCompactActions.contains(action) else { return false }
        }

        return super.canPerformAction(action, withSender: sender)
    }

    @objc private func handleAskAIAction(_ sender: Any?) {
        handleAskAISelection(action: .standard)
    }

    @objc private func handleAskAIWebAction(_ sender: Any?) {
        handleAskAISelection(action: .web)
    }

    private func handleAskAISelection(action: AskAISelectionAction) {
        let js = """
        (function() {
            var sel = window.getSelection ? window.getSelection() : null;
            var selected = sel ? (sel.toString() || '') : '';
            selected = selected.trim();
            if (!selected) {
                return JSON.stringify({selected: '', context: ''});
            }

            var bodyText = (document.body && document.body.innerText) ? document.body.innerText : '';
            var idx = bodyText.indexOf(selected);
            var context = '';
            if (idx >= 0) {
                var start = Math.max(0, idx - 320);
                var end = Math.min(bodyText.length, idx + selected.length + 320);
                context = bodyText.substring(start, end);
            } else {
                var nodeText = (sel && sel.anchorNode && sel.anchorNode.textContent) ? sel.anchorNode.textContent : '';
                context = nodeText;
            }
            return JSON.stringify({selected: selected, context: context});
        })();
        """

        evaluateJavaScript(js) { [weak self] result, _ in
            guard let self,
                  let payload = result as? String,
                  let data = payload.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let selected = object["selected"] as? String,
                  let context = object["context"] as? String else {
                return
            }

            let trimmedSelection = selected.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedSelection.isEmpty else { return }
            self.onAskAISelection?(action, trimmedSelection, context)
        }
    }

    private var usesCompactEditMenu: Bool {
        guard let window else { return false }
        return window.bounds.width < 700
    }

    private func installAskAIMenuItem() {
        let standardSelector = #selector(handleAskAIAction(_:))
        let webSelector = #selector(handleAskAIWebAction(_:))
        var menuItems = UIMenuController.shared.menuItems ?? []
        if !menuItems.contains(where: { $0.action == standardSelector }) {
            menuItems.append(UIMenuItem(title: "Ask AI", action: standardSelector))
        }
        if !menuItems.contains(where: { $0.action == webSelector }) {
            menuItems.append(UIMenuItem(title: "Ask AI Web", action: webSelector))
        }
        UIMenuController.shared.menuItems = menuItems
    }
}
#else
struct SelectableText: View {
    let text: String
    var onAskAI: ((String, String) -> Void)? = nil
    var onAskAIWeb: ((String, String) -> Void)? = nil
    var textIsPrecleaned: Bool = false

    var body: some View {
        Text(textIsPrecleaned ? text : cleanMarkdownArtifactsForDisplay(text))
            .textSelection(.enabled)
    }
}
#endif
