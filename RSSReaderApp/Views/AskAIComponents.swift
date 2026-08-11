import SwiftUI
import WebKit
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

enum AskAISelectionAction {
    case standard
    case web
}

private func splitDenseAskAISingleSentence(_ text: String) -> [String] {
    func cleanedParts(from marked: String) -> [String] {
        marked
            .components(separatedBy: "|||")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    let splitPatterns = [
        "([:;])\\s+(?=[A-Z])",
        "(\\))\\s+(?=(?:while|though|because|but)\\b)",
        "(,)\\s+(?=(?:while|though|because|but)\\b)",
        "(,)\\s+(?=(?:and|so|which|where|as)\\b)"
    ]

    var paragraphs = [text]
    for pattern in splitPatterns {
        paragraphs = paragraphs.flatMap { paragraph in
            guard paragraph.count > 160 else { return [paragraph] }
            let marked = paragraph.replacingOccurrences(
                of: pattern,
                with: "$1|||",
                options: [.regularExpression, .caseInsensitive]
            )
            let parts = cleanedParts(from: marked)
            return parts.count >= 2 ? parts : [paragraph]
        }
    }

    if paragraphs.count >= 2 {
        return paragraphs
    }

    let words = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    var fallbackParagraphs: [String] = []
    var current = ""
    for word in words {
        if !current.isEmpty && current.count + word.count + 1 > 170 {
            fallbackParagraphs.append(current)
            current = word
        } else {
            current = current.isEmpty ? word : "\(current) \(word)"
        }
    }
    if !current.isEmpty {
        fallbackParagraphs.append(current)
    }
    return fallbackParagraphs.count >= 2 ? fallbackParagraphs : [text]
}

func formatAskAIResponseForDisplay(_ input: String) -> String {
    var value = input
    value = value.replacingOccurrences(of: "\r\n", with: "\n")
    value = value.replacingOccurrences(of: "\r", with: "\n")
    value = value.replacingOccurrences(of: #"\\r\\n"#, with: "\n", options: .regularExpression)
    value = value.replacingOccurrences(of: #"\\n"#, with: "\n", options: .regularExpression)
    value = value.replacingOccurrences(of: #"\\r"#, with: "\n", options: .regularExpression)
    value = value.replacingOccurrences(of: #"(?m)^```[a-zA-Z0-9_-]*\s*$"#, with: "", options: .regularExpression)
    value = value.replacingOccurrences(of: "```", with: "")
    value = value.replacingOccurrences(of: "\\*\\*(.*?)\\*\\*", with: "$1", options: .regularExpression)
    value = value.replacingOccurrences(of: "\\*(.*?)\\*", with: "$1", options: .regularExpression)
    value = value.replacingOccurrences(of: "__(.*?)__", with: "$1", options: .regularExpression)
    value = value.replacingOccurrences(of: "_(.*?)_", with: "$1", options: .regularExpression)
    value = value.replacingOccurrences(of: "`([^`]*)`", with: "$1", options: .regularExpression)
    value = value.replacingOccurrences(of: "(?m)^\\s{0,3}#{1,6}\\s*", with: "", options: .regularExpression)
    value = value.replacingOccurrences(of: "(?m)(^\\s*[-•]?\\s*)#{1,6}\\s*", with: "$1", options: .regularExpression)
    value = value.replacingOccurrences(of: "(?m)^\\s*\\*\\s+", with: "- ", options: .regularExpression)
    value = value.trimmingCharacters(in: .whitespacesAndNewlines)
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
            value = splitDenseAskAISingleSentence(normalized).joined(separator: "\n\n")
        }
    }

    value = value.replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
    return value.trimmingCharacters(in: .whitespacesAndNewlines)
}

// MARK: - Ask AI Response Sheet
#if os(macOS)
private let macAskAIPanelTint = Color(red: 0.30, green: 0.46, blue: 0.64).opacity(0.26)
#endif

#if os(iOS) || os(macOS)
struct AskAIResponseSheet: View {
    let isLoading: Bool
    let response: String?
    let errorMessage: String?
    let onClose: () -> Void
    let onCopy: () -> Void

    @EnvironmentObject private var appState: AppState
    @State private var isAskingFollowUp = false
    @State private var followUpResponse: String?
    @State private var showFollowUpSheet = false

    var body: some View {
        rootContainer
            .askAILoadingOverlay(isAskingFollowUp)
            .sheet(isPresented: $showFollowUpSheet) {
                AskAIResponseSheet(
                    isLoading: false,
                    response: followUpResponse,
                    errorMessage: nil,
                    onClose: {
                        showFollowUpSheet = false
                    },
                    onCopy: copyFollowUpResponse
                )
                .environmentObject(appState)
                #if os(macOS)
                .frame(
                    minWidth: 480,
                    idealWidth: 640,
                    maxWidth: .infinity,
                    minHeight: 420,
                    idealHeight: 520,
                    maxHeight: .infinity
                )
                #endif
            }
    }

    @ViewBuilder
    private var rootContainer: some View {
        #if os(macOS)
        macSheetContent
        #else
        NavigationView {
            content
        }
        #endif
    }

    #if os(macOS)
    private var macSheetContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button("Close") {
                    onClose()
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.capsule)
                .controlSize(.large)

                Spacer()

                if response != nil {
                    Button {
                        onCopy()
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.title2)
                            .frame(width: 34, height: 34)
                            .accessibilityLabel("Copy")
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .controlSize(.large)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)

            Text("Ask AI")
                .font(.largeTitle.bold())
                .padding(.horizontal, 24)
                .padding(.top, 18)
                .padding(.bottom, 8)

            content
                .padding(.horizontal, 8)
        }
        .frame(
            minWidth: 480,
            idealWidth: 640,
            maxWidth: 760,
            minHeight: 420,
            idealHeight: 520,
            maxHeight: 720
        )
        .glassEffect(
            .regular.tint(macAskAIPanelTint),
            in: .rect(cornerRadius: 32)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 32, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.28),
                            Color.white.opacity(0.08)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.8
                )
        }
    }
    #endif

    private var content: some View {
        VStack(alignment: .leading, spacing: 16) {
            if isLoading {
                ProgressView("Asking AI…")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let response {
                ScrollView {
                    SelectableText(formatAskAIResponseForDisplay(response))
                        .font(.body)
                        .onAskAI {
                            askFollowUp(selectedText: $0, currentAnswer: response, useWebAI: false)
                        }
                        .onAskAIWeb {
                            askFollowUp(selectedText: $0, currentAnswer: response, useWebAI: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)
                }
            } else if let errorMessage {
                Text(errorMessage)
                    .foregroundColor(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Spacer()
        }
        .padding()
        #if os(iOS)
        .navigationTitle("Ask AI")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Close") {
                    onClose()
                }
            }
            ToolbarItem(placement: .primaryAction) {
                if response != nil {
                    Button("Copy") {
                        onCopy()
                    }
                }
            }
        }
        #endif
    }

    private func askFollowUp(selectedText: String, currentAnswer: String, useWebAI: Bool) {
        guard !isAskingFollowUp else { return }

        let selected = selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
        let context = formatAskAIResponseForDisplay(currentAnswer)
        guard !selected.isEmpty, !context.isEmpty else { return }

        let prompt = """
        Answer the question using only the selected text and the current Ask AI answer.

        Rules:
        - Return plain text only.
        - Do not use Markdown symbols, headings, bullets, or code fences.
        - Use short paragraphs separated by a blank line when the answer has multiple ideas.
        - If the current answer does not contain enough information, say so.

        Question:
        What is said about this selected text in the current answer?

        Selected text:
        \(selected)

        Current Ask AI Answer:
        \(context)
        """

        followUpResponse = nil
        isAskingFollowUp = true

        let completion: (String) -> Void = { answer in
            DispatchQueue.main.async {
                followUpResponse = formatAskAIResponseForDisplay(answer)
                isAskingFollowUp = false
                showFollowUpSheet = true
            }
        }

        if useWebAI {
            appState.askWebQuestionAboutSelection(
                prompt: prompt,
                title: "Ask AI Web",
                completion: completion
            )
        } else {
            appState.askQuestionAboutSelection(prompt: prompt, completion: completion)
        }
    }

    private func copyFollowUpResponse() {
        guard let followUpResponse, !followUpResponse.isEmpty else { return }
        #if os(iOS)
        UIPasteboard.general.string = followUpResponse
        #elseif os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(followUpResponse, forType: .string)
        #endif
    }
}
#endif

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
        .background(.thinMaterial, in: Capsule())
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

// MARK: - Ask AI Selection Environment
private struct AskAISelectionHandlerKey: EnvironmentKey {
    static let defaultValue: ((String) -> Void)? = nil
}

private struct AskAIWebSelectionHandlerKey: EnvironmentKey {
    static let defaultValue: ((String) -> Void)? = nil
}

extension EnvironmentValues {
    var askAISelectionHandler: ((String) -> Void)? {
        get { self[AskAISelectionHandlerKey.self] }
        set { self[AskAISelectionHandlerKey.self] = newValue }
    }

    var askAIWebSelectionHandler: ((String) -> Void)? {
        get { self[AskAIWebSelectionHandlerKey.self] }
        set { self[AskAIWebSelectionHandlerKey.self] = newValue }
    }
}

// MARK: - SelectableText
struct SelectableText: View {
    let text: String
    var font: Font = .body
    var fontWeight: Font.Weight? = nil
    var foregroundColor: Color = .primary
    var multilineTextAlignment: TextAlignment = .leading
    var lineLimit: Int? = nil
    var underline: Bool = false
    var frameWidth: CGFloat? = nil
    var frameHeight: CGFloat? = nil
    var frameMaxWidth: CGFloat? = nil
    var frameMaxHeight: CGFloat? = nil
    var framePadding: EdgeInsets? = nil
    var onAskAISelection: ((String) -> Void)? = nil
    var onAskAIWebSelection: ((String) -> Void)? = nil
    var summaryReferenceCount: Int = 0
    var onSummaryReferenceTap: ((Int) -> Void)? = nil
    @Environment(\.askAISelectionHandler) private var askAISelectionHandler
    @Environment(\.askAIWebSelectionHandler) private var askAIWebSelectionHandler

    init(_ text: String) {
        self.text = text
    }

    init(_ attributedString: AttributedString) {
        self.text = String(attributedString.characters)
    }

    var body: some View {
        #if os(iOS)
        SelectableTextRepresentable(
            text: text,
            font: font,
            fontWeight: fontWeight,
            foregroundColor: foregroundColor,
            textAlignment: multilineTextAlignment,
            lineLimit: lineLimit,
            underline: underline,
            onAskAI: onAskAISelection ?? askAISelectionHandler,
            onAskAIWeb: onAskAIWebSelection ?? askAIWebSelectionHandler
        )
        .frame(width: frameWidth, height: frameHeight)
        .frame(maxWidth: frameMaxWidth, maxHeight: frameMaxHeight)
        .padding(framePadding ?? EdgeInsets())
        #elseif os(macOS)
        MacSelectableTextRepresentable(
            text: text,
            font: font,
            fontWeight: fontWeight,
            foregroundColor: foregroundColor,
            textAlignment: multilineTextAlignment,
            lineLimit: lineLimit,
            underline: underline,
            onAskAI: onAskAISelection ?? askAISelectionHandler,
            onAskAIWeb: onAskAIWebSelection ?? askAIWebSelectionHandler,
            summaryReferenceCount: summaryReferenceCount,
            onSummaryReferenceTap: onSummaryReferenceTap
        )
        .frame(width: frameWidth, height: frameHeight)
        .frame(maxWidth: frameMaxWidth, maxHeight: frameMaxHeight)
        .padding(framePadding ?? EdgeInsets())
        #else
        Text(text)
            .font(font)
            .fontWeight(fontWeight)
            .foregroundColor(foregroundColor)
            .multilineTextAlignment(multilineTextAlignment)
            .lineLimit(lineLimit)
            .underline(underline)
            .textSelection(.enabled)
            .frame(width: frameWidth, height: frameHeight)
            .frame(maxWidth: frameMaxWidth, maxHeight: frameMaxHeight)
            .padding(framePadding ?? EdgeInsets())
        #endif
    }

    func font(_ font: Font) -> SelectableText {
        var copy = self
        copy.font = font
        return copy
    }

    func foregroundColor(_ color: Color) -> SelectableText {
        var copy = self
        copy.foregroundColor = color
        return copy
    }

    func multilineTextAlignment(_ alignment: TextAlignment) -> SelectableText {
        var copy = self
        copy.multilineTextAlignment = alignment
        return copy
    }

    func lineLimit(_ limit: Int?) -> SelectableText {
        var copy = self
        copy.lineLimit = limit
        return copy
    }

    func fontWeight(_ weight: Font.Weight?) -> SelectableText {
        var copy = self
        copy.fontWeight = weight
        return copy
    }

    func underline(_ active: Bool = true) -> SelectableText {
        var copy = self
        copy.underline = active
        return copy
    }

    func frame(width: CGFloat? = nil, height: CGFloat? = nil) -> SelectableText {
        var copy = self
        copy.frameWidth = width
        copy.frameHeight = height
        return copy
    }

    func frame(maxWidth: CGFloat? = nil, maxHeight: CGFloat? = nil) -> SelectableText {
        var copy = self
        copy.frameMaxWidth = maxWidth
        copy.frameMaxHeight = maxHeight
        return copy
    }

    func padding(_ insets: EdgeInsets) -> SelectableText {
        var copy = self
        copy.framePadding = insets
        return copy
    }

    func padding(_ edges: Edge.Set = .all, _ length: CGFloat? = nil) -> SelectableText {
        var copy = self
        let padding = length ?? 8
        var insets = EdgeInsets()

        if edges.contains(.top) {
            insets.top = padding
        }
        if edges.contains(.bottom) {
            insets.bottom = padding
        }
        if edges.contains(.leading) {
            insets.leading = padding
        }
        if edges.contains(.trailing) {
            insets.trailing = padding
        }

        copy.framePadding = insets
        return copy
    }

    func onAskAI(_ handler: ((String) -> Void)?) -> SelectableText {
        var copy = self
        copy.onAskAISelection = handler
        return copy
    }

    func onAskAIWeb(_ handler: ((String) -> Void)?) -> SelectableText {
        var copy = self
        copy.onAskAIWebSelection = handler
        return copy
    }

    func summaryReferences(count: Int, onTap: ((Int) -> Void)?) -> SelectableText {
        var copy = self
        copy.summaryReferenceCount = count
        copy.onSummaryReferenceTap = onTap
        return copy
    }
}

#if os(iOS)
final class SelectableUITextView: UITextView {
    var onAskAI: ((String) -> Void)? {
        didSet {
            installAskAIMenuItemIfNeeded()
        }
    }
    var onAskAIWeb: ((String) -> Void)? {
        didSet {
            installAskAIMenuItemIfNeeded()
        }
    }

    override var intrinsicContentSize: CGSize {
        let textSize = sizeThatFits(CGSize(width: bounds.width, height: CGFloat.greatestFiniteMagnitude))
        return CGSize(width: textSize.width, height: textSize.height)
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let fixedWidth = size.width
        let newSize = super.sizeThatFits(CGSize(width: fixedWidth, height: CGFloat.greatestFiniteMagnitude))
        return CGSize(width: fixedWidth, height: max(newSize.height, font?.lineHeight ?? 0))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        invalidateIntrinsicContentSize()
    }

    override var canBecomeFirstResponder: Bool {
        true
    }

    func installAskAIMenuItemIfNeeded() {
        guard onAskAI != nil || onAskAIWeb != nil else { return }
        let askSelector = #selector(askAI(_:))
        let askWebSelector = #selector(askAIWeb(_:))
        let existingItems = UIMenuController.shared.menuItems ?? []
        var menuItems = existingItems
        if !menuItems.contains(where: { $0.action == askSelector }) {
            menuItems.append(UIMenuItem(title: "Ask AI", action: askSelector))
        }
        if !menuItems.contains(where: { $0.action == askWebSelector }) {
            menuItems.append(UIMenuItem(title: "Ask AI Web", action: askWebSelector))
        }
        UIMenuController.shared.menuItems = menuItems
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(askAI(_:)) {
            return onAskAI != nil && selectedRange.length > 0
        }
        if action == #selector(askAIWeb(_:)) {
            return onAskAIWeb != nil && selectedRange.length > 0
        }
        return super.canPerformAction(action, withSender: sender)
    }

    @objc private func askAI(_ sender: Any?) {
        sendSelectedText(to: onAskAI)
    }

    @objc private func askAIWeb(_ sender: Any?) {
        sendSelectedText(to: onAskAIWeb)
    }

    private func sendSelectedText(to handler: ((String) -> Void)?) {
        guard let handler else { return }
        guard selectedRange.length > 0 else { return }
        let selectedText = (text as NSString).substring(with: selectedRange)
        handler(selectedText)
    }

    override func buildMenu(with builder: UIMenuBuilder) {
        super.buildMenu(with: builder)
        guard onAskAI != nil || onAskAIWeb != nil else { return }
        var actions: [UIAction] = []
        if onAskAI != nil {
            actions.append(UIAction(title: "Ask AI", image: UIImage(systemName: "sparkles")) { [weak self] _ in
            self?.askAI(nil)
            })
        }
        if onAskAIWeb != nil {
            actions.append(UIAction(title: "Ask AI Web", image: UIImage(systemName: "globe")) { [weak self] _ in
                self?.askAIWeb(nil)
            })
        }
        let menu = UIMenu(title: "", options: .displayInline, children: actions)
        builder.insertChild(menu, atEndOfMenu: .edit)
    }
}

struct SelectableTextRepresentable: UIViewRepresentable {
    let text: String
    let font: Font
    let fontWeight: Font.Weight?
    let foregroundColor: Color
    let textAlignment: TextAlignment
    let lineLimit: Int?
    let underline: Bool
    let onAskAI: ((String) -> Void)?
    let onAskAIWeb: ((String) -> Void)?

    func makeUIView(context: Context) -> SelectableUITextView {
        let textView = SelectableUITextView()
        textView.isEditable = false
        textView.isScrollEnabled = false
        textView.backgroundColor = .clear
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.textContainer.widthTracksTextView = true
        textView.textContainer.heightTracksTextView = false
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textView.setContentCompressionResistancePriority(.required, for: .vertical)
        textView.setContentHuggingPriority(.defaultHigh, for: .vertical)
        textView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return textView
    }

    func updateUIView(_ textView: SelectableUITextView, context: Context) {
        textView.onAskAI = onAskAI
        textView.onAskAIWeb = onAskAIWeb
        textView.text = text

        let uiFont: UIFont
        switch font {
        case .largeTitle:
            uiFont = UIFont.preferredFont(forTextStyle: .largeTitle)
        case .title:
            uiFont = UIFont.preferredFont(forTextStyle: .title1)
        case .title2:
            uiFont = UIFont.preferredFont(forTextStyle: .title2)
        case .title3:
            uiFont = UIFont.preferredFont(forTextStyle: .title3)
        case .headline:
            uiFont = UIFont.preferredFont(forTextStyle: .headline)
        case .subheadline:
            uiFont = UIFont.preferredFont(forTextStyle: .subheadline)
        case .body:
            uiFont = UIFont.preferredFont(forTextStyle: .body)
        case .callout:
            uiFont = UIFont.preferredFont(forTextStyle: .callout)
        case .footnote:
            uiFont = UIFont.preferredFont(forTextStyle: .footnote)
        case .caption:
            uiFont = UIFont.preferredFont(forTextStyle: .caption1)
        case .caption2:
            uiFont = UIFont.preferredFont(forTextStyle: .caption2)
        default:
            uiFont = UIFont.preferredFont(forTextStyle: .body)
        }

        let finalFont: UIFont
        if let weight = fontWeight {
            let traits: UIFontDescriptor.SymbolicTraits
            switch weight {
            case .bold, .heavy, .black:
                traits = .traitBold
            default:
                traits = []
            }
            if let descriptor = uiFont.fontDescriptor.withSymbolicTraits(traits) {
                finalFont = UIFont(descriptor: descriptor, size: uiFont.pointSize)
            } else {
                finalFont = uiFont
            }
        } else {
            finalFont = uiFont
        }

        textView.font = finalFont
        textView.textColor = UIColor(foregroundColor)

        if underline {
            let attributedString = NSMutableAttributedString(string: text)
            attributedString.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: NSRange(location: 0, length: text.count))
            attributedString.addAttribute(.font, value: finalFont, range: NSRange(location: 0, length: text.count))
            attributedString.addAttribute(.foregroundColor, value: UIColor(foregroundColor), range: NSRange(location: 0, length: text.count))
            textView.attributedText = attributedString
        }

        switch textAlignment {
        case .leading:
            textView.textAlignment = .left
        case .center:
            textView.textAlignment = .center
        case .trailing:
            textView.textAlignment = .right
        }

        if let limit = lineLimit {
            textView.textContainer.maximumNumberOfLines = limit
            textView.textContainer.lineBreakMode = .byWordWrapping
        } else {
            textView.textContainer.maximumNumberOfLines = 0
        }

        textView.invalidateIntrinsicContentSize()
    }
}
#elseif os(macOS)
final class AskAISelectableTextView: NSTextView {
    var onAskAI: ((String) -> Void)?
    var onAskAIWeb: ((String) -> Void)?
    fileprivate var renderSignature: Int = 0
    fileprivate var lastRenderedText: String = ""

    override var intrinsicContentSize: NSSize {
        guard let textContainer, let layoutManager else {
            return super.intrinsicContentSize
        }
        layoutManager.ensureLayout(for: textContainer)
        let usedRect = layoutManager.usedRect(for: textContainer)
        let height = max(usedRect.height + textContainerInset.height * 2, 1)
        return NSSize(width: NSView.noIntrinsicMetric, height: height)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        guard onAskAI != nil || onAskAIWeb != nil else { return menu }
        if !menu.items.contains(where: { $0.action == #selector(askAI) || $0.action == #selector(askAIWeb) }) {
            menu.addItem(NSMenuItem.separator())
        }
        if !menu.items.contains(where: { $0.action == #selector(askAI) }) {
            let item = NSMenuItem(title: "Ask AI", action: #selector(askAI), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        if !menu.items.contains(where: { $0.action == #selector(askAIWeb) }) {
            let item = NSMenuItem(title: "Ask AI Web", action: #selector(askAIWeb), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        return menu
    }

    @objc private func askAI() {
        sendSelectedText(to: onAskAI)
    }

    @objc private func askAIWeb() {
        sendSelectedText(to: onAskAIWeb)
    }

    private func sendSelectedText(to handler: ((String) -> Void)?) {
        guard let handler else { return }
        let length = (string as NSString).length
        guard selectedRange.location != NSNotFound,
              selectedRange.length > 0,
              selectedRange.location + selectedRange.length <= length else {
            return
        }
        let selectedText = (string as NSString).substring(with: selectedRange)
        handler(selectedText)
    }
}

struct MacSelectableTextRepresentable: NSViewRepresentable {
    let text: String
    let font: Font
    let fontWeight: Font.Weight?
    let foregroundColor: Color
    let textAlignment: TextAlignment
    let lineLimit: Int?
    let underline: Bool
    let onAskAI: ((String) -> Void)?
    let onAskAIWeb: ((String) -> Void)?
    let summaryReferenceCount: Int
    let onSummaryReferenceTap: ((Int) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(onSummaryReferenceTap: onSummaryReferenceTap)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var onSummaryReferenceTap: ((Int) -> Void)?

        init(onSummaryReferenceTap: ((Int) -> Void)?) {
            self.onSummaryReferenceTap = onSummaryReferenceTap
        }

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            guard let url = link as? URL,
                  url.scheme == "rssreader-summary",
                  let value = url.pathComponents.last,
                  let referenceNumber = Int(value) else {
                return false
            }
            onSummaryReferenceTap?(referenceNumber)
            return true
        }
    }

    func makeNSView(context: Context) -> AskAISelectableTextView {
        let textView = AskAISelectableTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.drawsBackground = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = false
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textView.setContentCompressionResistancePriority(.required, for: .vertical)
        textView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        textView.setContentHuggingPriority(.required, for: .vertical)
        textView.delegate = context.coordinator
        return textView
    }

    func updateNSView(_ nsView: AskAISelectableTextView, context: Context) {
        nsView.onAskAI = onAskAI
        nsView.onAskAIWeb = onAskAIWeb
        context.coordinator.onSummaryReferenceTap = onSummaryReferenceTap

        let fontKey: String
        let baseFont: NSFont
        switch font {
        case .largeTitle:
            fontKey = "largeTitle"
            baseFont = NSFont.preferredFont(forTextStyle: .largeTitle)
        case .title:
            fontKey = "title"
            baseFont = NSFont.preferredFont(forTextStyle: .title1)
        case .title2:
            fontKey = "title2"
            baseFont = NSFont.preferredFont(forTextStyle: .title2)
        case .title3:
            fontKey = "title3"
            baseFont = NSFont.preferredFont(forTextStyle: .title3)
        case .headline:
            fontKey = "headline"
            baseFont = NSFont.preferredFont(forTextStyle: .headline)
        case .subheadline:
            fontKey = "subheadline"
            baseFont = NSFont.preferredFont(forTextStyle: .subheadline)
        case .body:
            fontKey = "body"
            baseFont = NSFont.preferredFont(forTextStyle: .body)
        case .callout:
            fontKey = "callout"
            baseFont = NSFont.preferredFont(forTextStyle: .callout)
        case .footnote:
            fontKey = "footnote"
            baseFont = NSFont.preferredFont(forTextStyle: .footnote)
        case .caption:
            fontKey = "caption"
            baseFont = NSFont.preferredFont(forTextStyle: .caption1)
        case .caption2:
            fontKey = "caption2"
            baseFont = NSFont.preferredFont(forTextStyle: .caption2)
        default:
            fontKey = "body"
            baseFont = NSFont.preferredFont(forTextStyle: .body)
        }

        let finalFont: NSFont
        let weightKey: String
        if let weight = fontWeight {
            let nsWeight: NSFont.Weight
            switch weight {
            case .bold, .heavy, .black:
                nsWeight = .bold
                weightKey = "bold"
            case .semibold:
                nsWeight = .semibold
                weightKey = "semibold"
            case .medium:
                nsWeight = .medium
                weightKey = "medium"
            case .light:
                nsWeight = .light
                weightKey = "light"
            case .thin:
                nsWeight = .thin
                weightKey = "thin"
            case .ultraLight:
                nsWeight = .ultraLight
                weightKey = "ultraLight"
            default:
                nsWeight = .regular
                weightKey = "regular"
            }
            finalFont = NSFont.systemFont(ofSize: baseFont.pointSize, weight: nsWeight)
        } else {
            finalFont = baseFont
            weightKey = "regular"
        }

        let paragraphStyle = NSMutableParagraphStyle()
        switch textAlignment {
        case .leading:
            paragraphStyle.alignment = .left
        case .center:
            paragraphStyle.alignment = .center
        case .trailing:
            paragraphStyle.alignment = .right
        }
        paragraphStyle.lineBreakMode = .byWordWrapping

        var attributes: [NSAttributedString.Key: Any] = [
            .font: finalFont,
            .foregroundColor: NSColor(foregroundColor),
            .paragraphStyle: paragraphStyle
        ]
        if underline {
            attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }

        let color = NSColor(foregroundColor).usingColorSpace(.deviceRGB) ?? NSColor(foregroundColor)
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)

        var hasher = Hasher()
        hasher.combine(text)
        hasher.combine(fontKey)
        hasher.combine(weightKey)
        hasher.combine(finalFont.pointSize)
        hasher.combine(red)
        hasher.combine(green)
        hasher.combine(blue)
        hasher.combine(alpha)
        hasher.combine(underline)
        hasher.combine(lineLimit ?? -1)
        hasher.combine(paragraphStyle.alignment.rawValue)
        hasher.combine(summaryReferenceCount)
        let signature = hasher.finalize()

        if nsView.lastRenderedText != text || nsView.renderSignature != signature {
            let attributedText = NSMutableAttributedString(string: text, attributes: attributes)
            applySummaryReferenceLinks(
                to: attributedText,
                text: text,
                maximumReference: summaryReferenceCount,
                baseFont: finalFont
            )
            nsView.textStorage?.setAttributedString(attributedText)

            if let limit = lineLimit {
                nsView.textContainer?.maximumNumberOfLines = limit
                nsView.textContainer?.lineBreakMode = .byWordWrapping
            } else {
                nsView.textContainer?.maximumNumberOfLines = 0
            }

            nsView.lastRenderedText = text
            nsView.renderSignature = signature
            nsView.invalidateIntrinsicContentSize()
        }
    }

    private func applySummaryReferenceLinks(
        to attributedText: NSMutableAttributedString,
        text: String,
        maximumReference: Int,
        baseFont: NSFont
    ) {
        guard maximumReference > 0, !text.isEmpty else { return }
        let referenceToken = #"(?:#\s*)?(?:\[\s*)?\d+(?:\s*\])?"#
        let phrasePattern = #"\b(?:post|posts|article|articles|item|items)\s+\#(referenceToken)(?:\s*(?:,|\band\b|&)\s*(?:(?:post|posts|article|articles|item|items)\s+)?\#(referenceToken))*"#
        guard let phraseRegex = try? NSRegularExpression(pattern: phrasePattern, options: [.caseInsensitive]),
              let numberRegex = try? NSRegularExpression(pattern: #"\d+"#),
              let bracketRegex = try? NSRegularExpression(pattern: #"[\[\(]\s*#?(\d+)\s*[\]\)]"#) else { return }

        let source = text as NSString
        let sourceRange = NSRange(location: 0, length: source.length)
        func applyReferenceLink(numberRange: NSRange) {
            let number = Int(source.substring(with: numberRange)) ?? 0
            guard (1...maximumReference).contains(number),
                  let destination = URL(string: "rssreader-summary://item/\(number)") else { return }
            attributedText.addAttributes(
                [
                    .link: destination,
                    .foregroundColor: NSColor.linkColor,
                    .backgroundColor: NSColor.linkColor.withAlphaComponent(0.16),
                    .underlineStyle: NSUnderlineStyle.single.rawValue,
                    .font: NSFont.systemFont(ofSize: baseFont.pointSize, weight: .bold)
                ],
                range: numberRange
            )
        }

        for phraseMatch in phraseRegex.matches(in: text, range: sourceRange) {
            for numberMatch in numberRegex.matches(in: text, range: phraseMatch.range) {
                applyReferenceLink(numberRange: numberMatch.range)
            }
        }

        for bracketMatch in bracketRegex.matches(in: text, range: sourceRange) {
            let numberRange = bracketMatch.range(at: 1)
            guard numberRange.location != NSNotFound else { continue }
            applyReferenceLink(numberRange: numberRange)
        }
    }
}
#endif

// MARK: - Ask AI WebView Helpers
#if os(iOS)
final class AskAIWebView: WKWebView {
    var onAskAI: ((String) -> Void)?
    var onAskAIWeb: ((String) -> Void)?

    override var canBecomeFirstResponder: Bool {
        true
    }

    func installAskAIMenuItemIfNeeded() {
        guard onAskAI != nil || onAskAIWeb != nil else { return }
        let askSelector = #selector(askAI(_:))
        let askWebSelector = #selector(askAIWeb(_:))
        let existingItems = UIMenuController.shared.menuItems ?? []
        var menuItems = existingItems
        if !menuItems.contains(where: { $0.action == askSelector }) {
            menuItems.append(UIMenuItem(title: "Ask AI", action: askSelector))
        }
        if !menuItems.contains(where: { $0.action == askWebSelector }) {
            menuItems.append(UIMenuItem(title: "Ask AI Web", action: askWebSelector))
        }
        UIMenuController.shared.menuItems = menuItems
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(askAI(_:)) {
            return onAskAI != nil
        }
        if action == #selector(askAIWeb(_:)) {
            return onAskAIWeb != nil
        }
        return super.canPerformAction(action, withSender: sender)
    }

    @objc private func askAI(_ sender: Any?) {
        sendSelectedText(to: onAskAI)
    }

    @objc private func askAIWeb(_ sender: Any?) {
        sendSelectedText(to: onAskAIWeb)
    }

    private func sendSelectedText(to handler: ((String) -> Void)?) {
        guard let handler else { return }
        evaluateJavaScript("window.getSelection().toString()") { [weak self] result, error in
            guard let self, error == nil, let selection = result as? String else { return }
            let trimmed = selection.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            DispatchQueue.main.async {
                handler(trimmed)
            }
        }
    }

    override func buildMenu(with builder: UIMenuBuilder) {
        super.buildMenu(with: builder)
        guard onAskAI != nil || onAskAIWeb != nil else { return }
        var actions: [UIAction] = []
        if onAskAI != nil {
            actions.append(UIAction(title: "Ask AI", image: UIImage(systemName: "sparkles")) { [weak self] _ in
                self?.askAI(nil)
            })
        }
        if onAskAIWeb != nil {
            actions.append(UIAction(title: "Ask AI Web", image: UIImage(systemName: "globe")) { [weak self] _ in
                self?.askAIWeb(nil)
            })
        }
        let menu = UIMenu(title: "", options: .displayInline, children: actions)
        builder.insertChild(menu, atEndOfMenu: .edit)
    }
}
#elseif os(macOS)
final class AskAIWebViewMac: WKWebView {
    var onAskAI: ((String) -> Void)?
    var onAskAIWeb: ((String) -> Void)?

    override func rightMouseDown(with event: NSEvent) {
        guard onAskAI != nil || onAskAIWeb != nil else {
            super.rightMouseDown(with: event)
            return
        }

        let menu = NSMenu()
        let copyItem = NSMenuItem(title: "Copy", action: #selector(copySelection), keyEquivalent: "")
        copyItem.target = self
        menu.addItem(copyItem)
        menu.addItem(NSMenuItem.separator())

        if onAskAI != nil {
            let askItem = NSMenuItem(title: "Ask AI", action: #selector(askAI), keyEquivalent: "")
            askItem.target = self
            menu.addItem(askItem)
        }
        if onAskAIWeb != nil {
            let askWebItem = NSMenuItem(title: "Ask AI Web", action: #selector(askAIWeb), keyEquivalent: "")
            askWebItem.target = self
            menu.addItem(askWebItem)
        }

        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func copySelection() {
        evaluateJavaScript("window.getSelection().toString()") { result, error in
            guard error == nil, let selection = result as? String else { return }
            let trimmed = selection.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(trimmed, forType: .string)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        guard onAskAI != nil || onAskAIWeb != nil else { return menu }
        if !menu.items.contains(where: { $0.action == #selector(askAI) || $0.action == #selector(askAIWeb) }) {
            menu.addItem(NSMenuItem.separator())
        }
        if onAskAI != nil && !menu.items.contains(where: { $0.action == #selector(askAI) }) {
            let item = NSMenuItem(title: "Ask AI", action: #selector(askAI), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        if onAskAIWeb != nil && !menu.items.contains(where: { $0.action == #selector(askAIWeb) }) {
            let item = NSMenuItem(title: "Ask AI Web", action: #selector(askAIWeb), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        return menu
    }

    @objc private func askAI() {
        sendSelectedText(to: onAskAI)
    }

    @objc private func askAIWeb() {
        sendSelectedText(to: onAskAIWeb)
    }

    private func sendSelectedText(to handler: ((String) -> Void)?) {
        guard let handler else { return }
        evaluateJavaScript("window.getSelection().toString()") { [weak self] result, error in
            guard let self, error == nil, let selection = result as? String else { return }
            let trimmed = selection.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            DispatchQueue.main.async {
                handler(trimmed)
            }
        }
    }
}
#endif
