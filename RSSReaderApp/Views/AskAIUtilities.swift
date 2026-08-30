import Foundation
import SwiftUI
#if os(iOS)
import UIKit
import WebKit
#endif

private let conversationalMarkdownParagraphMarker = "\u{E000}"
private let conversationalMarkdownParagraphSeparator = "\n\n\(conversationalMarkdownParagraphMarker)\n\n"

/// Makes provider responses with single soft line breaks render as distinct
/// paragraphs without changing Markdown block syntax. `AttributedString`'s
/// full Markdown parser treats a single newline inside a paragraph as a soft
/// break, which makes otherwise paragraph-separated AI replies appear as one
/// continuous block.
func normalizeAIReplyMarkdown(_ input: String) -> String {
    let normalizedNewlines = input
        .replacingOccurrences(of: "\r\n", with: "\n")
        .replacingOccurrences(of: "\r", with: "\n")
    let lines = normalizedNewlines.components(separatedBy: "\n")
    guard lines.count > 1 else { return normalizedNewlines }

    func isFence(_ line: String) -> Bool {
        line.range(of: #"^\s{0,3}(?:```|~~~)"#, options: .regularExpression) != nil
    }

    func isListItem(_ line: String) -> Bool {
        line.range(of: #"^\s*(?:[-+*]|\d+[.)])\s+"#, options: .regularExpression) != nil
    }

    func isBlockQuote(_ line: String) -> Bool {
        line.range(of: #"^\s*>"#, options: .regularExpression) != nil
    }

    func isHeading(_ line: String) -> Bool {
        line.range(of: #"^\s{0,3}#{1,6}(?:\s|$)"#, options: .regularExpression) != nil
    }

    func isThematicBreak(_ line: String) -> Bool {
        line.range(of: #"^\s{0,3}(?:\*\s*){3,}$|^\s{0,3}(?:-\s*){3,}$|^\s{0,3}(?:_\s*){3,}$"#, options: .regularExpression) != nil
    }

    // Be conservative around tables. A pipe can be ordinary prose, but when
    // it appears on either side of a table separator we must preserve rows.
    func looksLikeTableRow(at index: Int) -> Bool {
        guard lines[index].contains("|") else { return false }
        let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
        if trimmed.range(of: #"^\|?\s*:?-{3,}:?\s*(?:\|\s*:?-{3,}:?\s*)+\|?$"#, options: .regularExpression) != nil {
            return true
        }
        let previous = index > 0 ? lines[index - 1].trimmingCharacters(in: .whitespaces) : ""
        let next = index + 1 < lines.count ? lines[index + 1].trimmingCharacters(in: .whitespaces) : ""
        return previous.contains("|") && next.contains("|")
    }

    func isBlockSyntax(at index: Int) -> Bool {
        let line = lines[index]
        return isListItem(line)
            || isBlockQuote(line)
            || isHeading(line)
            || isThematicBreak(line)
            || looksLikeTableRow(at: index)
    }

    var result: [String] = []
    result.reserveCapacity(lines.count * 2)
    var insideFence = false

    for index in lines.indices {
        let line = lines[index]
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        if isFence(line) {
            result.append(line)
            insideFence.toggle()
            continue
        }

        if insideFence || trimmed.isEmpty || result.last?.isEmpty == true {
            result.append(line)
            continue
        }

        guard index > lines.startIndex else {
            result.append(line)
            continue
        }

        let previousIndex = index - 1
        let canSeparateProse = !isBlockSyntax(at: previousIndex) && !isBlockSyntax(at: index)
        let hasExplicitHardBreak = lines[previousIndex].hasSuffix("\\")
            || lines[previousIndex].hasSuffix("  ")

        if canSeparateProse && !hasExplicitHardBreak {
            result.append("")
        }
        result.append(line)
    }

    return result.joined(separator: "\n")
}

/// Adds readable paragraph spacing to long conversational answers that arrive
/// as a single line. Existing Markdown blocks and provider-supplied line breaks
/// are left to the general Markdown normalizer above.
func normalizeConversationalAIReplyMarkdown(_ input: String) -> String {
    let normalized = normalizeAIReplyMarkdown(input)
    let value = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else { return normalized }

    // `normalizeAIReplyMarkdown` deliberately turns provider-supplied soft
    // prose line breaks into blank-line paragraph boundaries. Foundation's
    // full Markdown parser removes those boundaries when it flattens the
    // result into one AttributedString (and can even join `17.` + `The` as
    // `17.The`). Convert prose-only boundaries to explicit Markdown hard
    // breaks so the Q&A UITextView retains the visible paragraph spacing.
    if value.contains("\n") {
        let collapsedParagraphBoundaries = value.replacingOccurrences(
            of: #"\n[ \t]*\n+"#,
            with: "\n\n",
            options: .regularExpression
        )
        return collapsedParagraphBoundaries.replacingOccurrences(
            of: "\n\n",
            with: conversationalMarkdownParagraphSeparator
        )
    }

    // A single-line response that declares structural Markdown cannot be
    // safely reflowed without potentially changing its structure.
    let beginsWithBlockSyntax = value.range(
        of: #"^(?:\s{0,3}#{1,6}(?:\s|$)|\s*(?:[-+*]|\d+[.)])\s+|\s*>|\s*\|)"#,
        options: .regularExpression
    ) != nil
    guard !beginsWithBlockSyntax,
          !value.contains("`"),
          !value.contains("~~~"),
          !value.contains("|") else {
        return normalized
    }

    // Some conversational providers collapse their original line breaks
    // without preserving the separating space (for example, "answer.Next").
    // Recover only an obvious prose sentence boundary. Requiring an uppercase
    // letter followed by a lowercase letter avoids changing decimal numbers,
    // URLs, model versions, and most identifier-like text.
    let recoveredValue = value.replacingOccurrences(
        of: #"([.!?])([\"'”’]?[A-Z][a-z])"#,
        with: "$1 $2",
        options: .regularExpression
    )
    let recoveredOutput = recoveredValue == value ? normalized : recoveredValue

    var sentences: [String] = []
    recoveredValue.enumerateSubstrings(
        in: recoveredValue.startIndex..<recoveredValue.endIndex,
        options: .bySentences
    ) { substring, _, _, _ in
        guard let sentence = substring?.trimmingCharacters(in: .whitespacesAndNewlines),
              !sentence.isEmpty else { return }
        sentences.append(sentence)
    }

    guard sentences.count > 1 else { return recoveredOutput }

    // Keep genuinely short answers compact. A long two-sentence response can
    // still benefit from a single paragraph break.
    if sentences.count == 2, recoveredValue.count < 600 {
        return recoveredOutput
    }
    if sentences.count >= 3, recoveredValue.count < 260 {
        return recoveredOutput
    }

    let desiredParagraphs = max(2, Int(ceil(Double(recoveredValue.count) / 420.0)))
    let maximumParagraphs = max(2, sentences.count / 2)
    let paragraphCount = min(desiredParagraphs, min(maximumParagraphs, sentences.count))
    guard paragraphCount > 1 else { return recoveredOutput }

    var paragraphs: [String] = []
    paragraphs.reserveCapacity(paragraphCount)
    var sentenceIndex = 0

    for paragraphIndex in 0..<paragraphCount {
        let remainingSentences = sentences.count - sentenceIndex
        let remainingParagraphs = paragraphCount - paragraphIndex
        let sentencesInParagraph = Int(ceil(Double(remainingSentences) / Double(remainingParagraphs)))
        let endIndex = min(sentenceIndex + sentencesInParagraph, sentences.count)
        paragraphs.append(sentences[sentenceIndex..<endIndex].joined(separator: " "))
        sentenceIndex = endIndex
    }

    // Foundation's full Markdown parser drops blank lines between block
    // paragraphs when flattening them into one AttributedString. Explicit
    // Markdown hard breaks retain the two visible line breaks in UITextView.
    return paragraphs.joined(separator: conversationalMarkdownParagraphSeparator)
}

func cleanMarkdownArtifactsForDisplay(_ input: String) -> String {
    var value = normalizeAIReplyMarkdown(input)
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
    let conversationalMarkdown = normalizeConversationalAIReplyMarkdown(input)
    let plainTextParagraphs = conversationalMarkdown.replacingOccurrences(
        of: conversationalMarkdownParagraphSeparator,
        with: "\n\n"
    )
    var value = cleanMarkdownArtifactsForDisplay(plainTextParagraphs)
    guard !value.isEmpty else { return value }

    value = value.replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
    return value.trimmingCharacters(in: .whitespacesAndNewlines)
}

func attributedAskAIResponseForDisplay(_ input: String) -> AttributedString {
    let value = formatAskAIResponseForDisplay(input)
    guard !value.isEmpty,
          let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
        return AttributedString(value)
    }

    let source = value as NSString
    let markdown = NSMutableString(string: value)
    let matches = detector.matches(
        in: value,
        range: NSRange(location: 0, length: source.length)
    )

    for match in matches.reversed() {
        guard let url = match.url else { continue }

        let markdownPrefix = match.range.location >= 2
            ? source.substring(with: NSRange(location: match.range.location - 2, length: 2))
            : ""
        let startsMarkdownDestination = markdownPrefix.hasSuffix("](")
        let isAngleBracketLink = match.range.location >= 1
            && NSMaxRange(match.range) < source.length
            && source.substring(with: NSRange(location: match.range.location - 1, length: 1)) == "<"
            && source.substring(with: NSRange(location: NSMaxRange(match.range), length: 1)) == ">"
        guard !startsMarkdownDestination, !isAngleBracketLink else { continue }

        var replacementRange = match.range
        if match.range.location >= 1,
           NSMaxRange(match.range) < source.length,
           source.substring(with: NSRange(location: match.range.location - 1, length: 1)) == "[",
           source.substring(with: NSRange(location: NSMaxRange(match.range), length: 1)) == "]" {
            replacementRange = NSRange(location: match.range.location - 1, length: match.range.length + 2)
        }

        let label = source.substring(with: match.range)
            .replacingOccurrences(of: "]", with: "\\]")
        markdown.replaceCharacters(
            in: replacementRange,
            with: "[\(label)](<\(url.absoluteString)>)"
        )
    }

    return (try? AttributedString(
        markdown: markdown as String,
        options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
    )) ?? AttributedString(value)
}

/// Carries the bounded source that grounded an answer into a later selection
/// follow-up. The source and the original Q&A are kept separate so a reply
/// selection can add its current displayed answer without losing the source.
struct AskAISelectionOrigin {
    let sourceLabel: String
    let sourceText: String
    let originalQuestion: String?
    let originalAnswer: String?

    init(
        sourceLabel: String,
        sourceText: String,
        originalQuestion: String? = nil,
        originalAnswer: String? = nil
    ) {
        self.sourceLabel = sourceLabel
        self.sourceText = sourceText
        self.originalQuestion = originalQuestion
        self.originalAnswer = originalAnswer
    }

    var promptSourceLabel: String {
        let hasQA = !(originalQuestion?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            || !(originalAnswer?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        return hasQA ? "Original source and Q&A context" : sourceLabel
    }

    func boundedSource(additionalAnswer: String? = nil, maxCharacters: Int = 40_000) -> String {
        func normalized(_ value: String?) -> String {
            guard let value else { return "" }
            return value
                .replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
                .replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let source = normalized(sourceText)
        let question = normalized(originalQuestion)
        let answer = normalized(originalAnswer)
        let currentAnswer = normalized(additionalAnswer)
        var qaSections: [(label: String, body: String)] = []
        if !question.isEmpty {
            qaSections.append(("Original Q&A question", question))
        }
        if !answer.isEmpty {
            qaSections.append(("Complete Q&A answer", answer))
        }
        if !currentAnswer.isEmpty, currentAnswer != answer {
            qaSections.append(("Current displayed Ask AI answer", currentAnswer))
        }
        let sourceLabel = sourceLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Original source"
            : sourceLabel
        let sectionCount = (source.isEmpty ? 0 : 1) + qaSections.count
        let separatorBudget = max(0, sectionCount - 1) * 2
        let sourceHeaderBudget = source.isEmpty ? 0 : sourceLabel.count + 2
        let qaHeaderBudget = qaSections.reduce(0) { $0 + $1.label.count + 2 }
        let availableBodyBudget = max(0, maxCharacters - separatorBudget - sourceHeaderBudget - qaHeaderBudget)
        let qaBodyCount = qaSections.reduce(0) { $0 + $1.body.count }

        // Keep at least a quarter of the available body budget for the source
        // when both the source and Q&A are oversized. This prevents a long
        // answer from silently replacing the article or Reddit grounding.
        let sourceMinimumBudget = source.isEmpty ? 0 : min(source.count, max(1, availableBodyBudget / 4))
        let sourceBudget: Int
        if source.isEmpty {
            sourceBudget = 0
        } else if source.count + qaBodyCount <= availableBodyBudget {
            sourceBudget = source.count
        } else {
            let qaReservation = min(qaBodyCount, max(0, availableBodyBudget - sourceMinimumBudget))
            sourceBudget = min(source.count, max(sourceMinimumBudget, availableBodyBudget - qaReservation))
        }

        let qaBudget = max(0, availableBodyBudget - sourceBudget)
        var qaBodyBudgets = Array(repeating: 0, count: qaSections.count)
        var remainingQABudget = qaBudget
        for index in qaSections.indices where remainingQABudget > 0 {
            qaBodyBudgets[index] = min(1, qaSections[index].body.count)
            remainingQABudget -= qaBodyBudgets[index]
        }
        while remainingQABudget > 0 {
            var madeProgress = false
            for index in qaSections.indices where remainingQABudget > 0 {
                guard qaBodyBudgets[index] < qaSections[index].body.count else { continue }
                qaBodyBudgets[index] += 1
                remainingQABudget -= 1
                madeProgress = true
            }
            if !madeProgress { break }
        }

        var sections: [String] = []
        if sourceBudget > 0 {
            sections.append("\(sourceLabel):\n\(source.prefix(sourceBudget))")
        }
        for (index, section) in qaSections.enumerated() where qaBodyBudgets[index] > 0 {
            sections.append("\(section.label):\n\(section.body.prefix(qaBodyBudgets[index]))")
        }

        let composed = sections.joined(separator: "\n\n")
        return composed.count > maxCharacters ? String(composed.prefix(maxCharacters)) : composed
    }

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

    let selected = normalized(selectedText, maxCharacters: 8_000)
    let context = normalized(extractedContext, maxCharacters: 16_000)
    let source = normalized(sourceContext, maxCharacters: 40_000)
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
    var markdownContent: String? = nil
    var onAskAISelection: ((String, String) -> Void)? = nil
    var onAskAIWebSelection: ((String, String) -> Void)? = nil

    var body: some View {
        ScrollView {
            #if os(iOS)
            SelectableText(
                text: formatAskAIResponseForDisplay(content),
                markdownText: markdownContent.map(normalizeConversationalAIReplyMarkdown),
                onAskAI: onAskAISelection,
                onAskAIWeb: onAskAIWebSelection,
                textIsPrecleaned: true
            )
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            #else
            Text(attributedAskAIResponseForDisplay(content))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .textSelection(.enabled)
            #endif
        }
    }
}

#if os(iOS)
struct AskAIPresentationBackground: View {
    private let tint = Color(red: 0.34, green: 0.47, blue: 0.62).opacity(0.32)

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 32, style: .continuous)
        shape
            .fill(.clear)
            .glassEffect(.regular.tint(tint), in: .rect(cornerRadius: 32))
            .overlay {
                shape.stroke(
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
}

struct AskAISheetTransparencyBridge: UIViewRepresentable {
    func makeUIView(context: Context) -> AskAISheetTransparencyView {
        AskAISheetTransparencyView(frame: .zero)
    }

    func updateUIView(_ uiView: AskAISheetTransparencyView, context: Context) {
        uiView.enforceHostTransparency()
    }
}

final class AskAISheetTransparencyView: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func didMoveToSuperview() {
        super.didMoveToSuperview()
        enforceHostTransparency()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        enforceHostTransparency()
        DispatchQueue.main.async { [weak self] in
            self?.enforceHostTransparency()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        enforceHostTransparency()
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        enforceHostTransparency()
    }

    fileprivate func enforceHostTransparency() {
        backgroundColor = .clear
        isOpaque = false

        var ancestor = superview
        var depth = 0
        while let current = ancestor, !(current is UIWindow), depth < 12 {
            current.backgroundColor = .clear
            current.isOpaque = false
            ancestor = current.superview
            depth += 1
        }

        var responder: UIResponder? = self
        while let next = responder?.next {
            if let viewController = next as? UIViewController {
                clearPresentationSurfaces(startingAt: viewController)
                break
            }
            responder = next
        }
    }

    private func clearPresentationSurfaces(startingAt viewController: UIViewController) {
        var current: UIViewController? = viewController
        var visited = Set<ObjectIdentifier>()

        while let controller = current {
            let identifier = ObjectIdentifier(controller)
            guard visited.insert(identifier).inserted else { break }

            controller.view.backgroundColor = .clear
            controller.view.isOpaque = false

            if controller.presentingViewController != nil,
               let presentationController = controller.presentationController {
                presentationController.presentedView?.backgroundColor = .clear
                presentationController.presentedView?.isOpaque = false
                presentationController.containerView?.backgroundColor = .clear
                presentationController.containerView?.isOpaque = false
                break
            }

            current = controller.parent
        }
    }
}
#endif

struct AskAIResponseSheet: View {
    let question: String
    let answer: String
    var markdownAnswer: String? = nil
    var selectionOrigin: AskAISelectionOrigin? = nil
    var onCopy: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    #if os(iOS)
    @EnvironmentObject private var appState: AppState
    @State private var isAskingFollowUp = false
    @State private var followUpPrompt = ""
    @State private var followUpAnswer = ""
    @State private var followUpMarkdownAnswer: String?
    @State private var showFollowUpSheet = false
    #endif

    var body: some View {
        NavigationStack {
            AskAIWebView(
                content: answer.isEmpty ? "No answer available." : answer,
                markdownContent: markdownAnswer,
                onAskAISelection: {
                    #if os(iOS)
                    askFollowUp(selectedText: $0, context: $1, useWebAI: false)
                    #endif
                },
                onAskAIWebSelection: {
                    #if os(iOS)
                    askFollowUp(selectedText: $0, context: $1, useWebAI: true)
                    #endif
                }
            )
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
                    .buttonStyle(.plain)
                    .foregroundStyle(.primary)
                    .tint(.primary)
                }
            }
        }
        .background(Color.clear)
        #if os(iOS)
        .background(AskAISheetTransparencyBridge())
        .toolbarBackground(.hidden, for: .navigationBar)
        .presentationBackground {
            AskAIPresentationBackground()
        }
        .askAILoadingOverlay(isAskingFollowUp)
        .sheet(isPresented: $showFollowUpSheet) {
            AskAIResponseSheet(
                question: followUpPrompt,
                answer: followUpAnswer,
                markdownAnswer: followUpMarkdownAnswer,
                selectionOrigin: selectionOrigin,
                onCopy: {
                    UIPasteboard.general.string = followUpAnswer
                }
            )
            .environmentObject(appState)
            .presentationDetents([.medium, .large])
            .presentationCornerRadius(32)
        }
        #endif
    }

    #if os(iOS)
    private func askFollowUp(selectedText: String, context: String, useWebAI: Bool) {
        guard !isAskingFollowUp else { return }

        let prompt = buildAskAISelectionPrompt(
            selectedText: selectedText,
            extractedContext: context,
            sourceContext: (selectionOrigin ?? AskAISelectionOrigin(
                sourceLabel: "Current Ask AI answer",
                sourceText: answer
            )).boundedSource(additionalAnswer: answer),
            sourceLabel: (selectionOrigin?.promptSourceLabel ?? "Current Ask AI answer")
        )
        guard !prompt.isEmpty else { return }

        followUpPrompt = prompt
        followUpAnswer = ""
        followUpMarkdownAnswer = nil
        isAskingFollowUp = true

        let completion: (String) -> Void = { response in
            DispatchQueue.main.async {
                self.followUpMarkdownAnswer = response
                self.followUpAnswer = formatAskAIResponseForDisplay(response)
                self.isAskingFollowUp = false
                self.showFollowUpSheet = true
            }
        }

        if useWebAI {
            appState.askWebQuestionAboutSelection(prompt: prompt, completion: completion)
        } else {
            appState.askQuestionAboutSelection(prompt: prompt, completion: completion)
        }
    }
    #endif
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
    textView.textColor = UIColor { traitCollection in
        traitCollection.userInterfaceStyle == .dark
            ? UIColor(white: 0.96, alpha: 1.0)
            : UIColor.label
    }
    textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    textView.setContentHuggingPriority(.required, for: .vertical)
    textView.setContentCompressionResistancePriority(.required, for: .vertical)
    textView.onAskAISelection = onAskAI
    textView.supportsStandardAskAI = supportsStandardAskAI
    textView.supportsWebAskAI = supportsWebAskAI
}

struct SelectableText: UIViewRepresentable {
    let text: String
    var markdownText: String? = nil
    var onAskAI: ((String, String) -> Void)? = nil
    var onAskAIWeb: ((String, String) -> Void)? = nil
    var summaryReferenceCount: Int = 0
    var onSummaryReferenceTap: ((Int) -> Void)? = nil
    var onPodcastTimestampTap: ((TimeInterval) -> Void)? = nil
    var textIsPrecleaned: Bool = false

    func makeUIView(context: Context) -> AskAITextView {
        let textView = AskAITextView()
        configureSelectableTextView(
            textView,
            onAskAI: selectionHandler,
            supportsStandardAskAI: onAskAI != nil,
            supportsWebAskAI: onAskAIWeb != nil
        )
        textView.onSummaryReferenceTap = onSummaryReferenceTap
        textView.onPodcastTimestampTap = onPodcastTimestampTap
        applyText(resolvedText, markdown: markdownText, on: textView)
        return textView
    }

    func updateUIView(_ uiView: AskAITextView, context: Context) {
        uiView.onAskAISelection = selectionHandler
        uiView.supportsStandardAskAI = onAskAI != nil
        uiView.supportsWebAskAI = onAskAIWeb != nil
        uiView.onSummaryReferenceTap = onSummaryReferenceTap
        uiView.onPodcastTimestampTap = onPodcastTimestampTap
        applyText(resolvedText, markdown: markdownText, on: uiView)
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

    private func applyText(_ value: String, markdown: String?, on textView: AskAITextView) {
        textView.prepareForDisplay(
            text: value,
            markdownText: markdown,
            layoutWidth: textView.bounds.width,
            summaryReferenceCount: summaryReferenceCount,
            podcastTimestampsEnabled: onPodcastTimestampTap != nil
        )
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

private final class TextSelectionIntentGestureRecognizer: UIGestureRecognizer {
    var onTouchBegan: (() -> Void)?
    var onTouchEnded: (() -> Void)?

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard touches.count == 1 else {
            state = .failed
            return
        }
        onTouchBegan?()
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        onTouchEnded?()
        state = .failed
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        onTouchEnded?()
        state = .failed
    }

    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool {
        false
    }

    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool {
        false
    }
}

final class AskAITextView: UITextView, UITextViewDelegate {
    var onAskAISelection: ((AskAISelectionAction, String, String) -> Void)?
    var onSummaryReferenceTap: ((Int) -> Void)?
    var onPodcastTimestampTap: ((TimeInterval) -> Void)?
    var supportsStandardAskAI = false
    var supportsWebAskAI = false
    private(set) var currentRenderedText: String = ""
    private var currentRenderedMarkdownText: String?
    private var isMarkdownRendered = false
    private var currentSummaryReferenceCount = 0
    private var currentPodcastTimestampsEnabled = false
    private var lastMeasuredWidth: CGFloat = 0
    private var lastMeasuredSize: CGSize = .zero
    private static weak var currentTextTouchView: AskAITextView?
    static var didActiveTextTouchChangeSelection: Bool {
        currentTextTouchView?.didSelectionChangeDuringCurrentTouch == true
    }

    private var isTrackingCurrentTextTouch = false
    private var didSelectionChangeDuringCurrentTouch = false
    private var textSelectionIntentRecognizer: TextSelectionIntentGestureRecognizer?
    private var textSelectionGestureResetWorkItem: DispatchWorkItem?
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
        installTextSelectionIntentObserver()
    }

    func prepareForDisplay(
        text: String,
        markdownText: String? = nil,
        layoutWidth: CGFloat,
        summaryReferenceCount: Int = 0,
        podcastTimestampsEnabled: Bool = false
    ) {
        let clampedWidth = max(1, layoutWidth)
        let normalizedMarkdown = markdownText
            .map(normalizeAIReplyMarkdown)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let textChanged = currentRenderedText != text
        let markdownChanged = currentRenderedMarkdownText != normalizedMarkdown
        let referenceConfigurationChanged = currentSummaryReferenceCount != summaryReferenceCount
        let podcastTimestampConfigurationChanged = currentPodcastTimestampsEnabled != podcastTimestampsEnabled
        let widthChanged = abs(lastMeasuredWidth - clampedWidth) > 0.5

        if textChanged || markdownChanged {
            if let normalizedMarkdown, !normalizedMarkdown.isEmpty,
               let parsed = try? AttributedString(
                   markdown: normalizedMarkdown,
                   options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .full)
               ) {
                let rendered = NSMutableAttributedString(attributedString: NSAttributedString(parsed))
                rendered.mutableString.replaceOccurrences(
                    of: conversationalMarkdownParagraphMarker,
                    with: "\n\n",
                    range: NSRange(location: 0, length: rendered.length)
                )
                applyBaseAttributes(to: rendered)
                attributedText = rendered
                isMarkdownRendered = true
                currentRenderedText = rendered.string
            } else {
                self.text = text
                isMarkdownRendered = false
                currentRenderedText = text
            }
            currentRenderedMarkdownText = normalizedMarkdown
        }

        if textChanged || markdownChanged || referenceConfigurationChanged || podcastTimestampConfigurationChanged {
            currentSummaryReferenceCount = summaryReferenceCount
            currentPodcastTimestampsEnabled = podcastTimestampsEnabled
            applySummaryReferenceLinks(maximumReference: summaryReferenceCount)
            if podcastTimestampsEnabled {
                applyPodcastTimestampLinks()
            }
        }

        installAskAIMenuItem()
        installTextSelectionIntentObserver()

        guard textChanged || markdownChanged || referenceConfigurationChanged || podcastTimestampConfigurationChanged || widthChanged else { return }

        bounds.size.width = clampedWidth
        setNeedsLayout()
        layoutIfNeeded()
        lastMeasuredWidth = clampedWidth
        lastMeasuredSize = super.sizeThatFits(CGSize(width: clampedWidth, height: .greatestFiniteMagnitude))
        invalidateIntrinsicContentSize()
    }

    private func installTextSelectionIntentObserver() {
        guard textSelectionIntentRecognizer == nil else { return }

        let recognizer = TextSelectionIntentGestureRecognizer()
        recognizer.cancelsTouchesInView = false
        recognizer.delaysTouchesBegan = false
        recognizer.delaysTouchesEnded = false
        recognizer.onTouchBegan = { [weak self] in
            self?.beginTextTouch()
        }
        recognizer.onTouchEnded = { [weak self] in
            self?.endTextTouch()
        }
        addGestureRecognizer(recognizer)
        textSelectionIntentRecognizer = recognizer
    }

    private func beginTextTouch() {
        textSelectionGestureResetWorkItem?.cancel()
        textSelectionGestureResetWorkItem = nil
        isTrackingCurrentTextTouch = true
        didSelectionChangeDuringCurrentTouch = false
        Self.currentTextTouchView = self
    }

    private func endTextTouch() {
        textSelectionGestureResetWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.isTrackingCurrentTextTouch = false
            self.didSelectionChangeDuringCurrentTouch = false
            if Self.currentTextTouchView === self {
                Self.currentTextTouchView = nil
            }
            self.textSelectionGestureResetWorkItem = nil
        }
        textSelectionGestureResetWorkItem = workItem
        // UIKit may publish its final selectedRange after gesture recognizers
        // receive touchesEnded. Keep this touch context alive long enough for it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: workItem)
    }

    func textViewDidChangeSelection(_ textView: UITextView) {
        guard isTrackingCurrentTextTouch else { return }
        didSelectionChangeDuringCurrentTouch = true
        Self.currentTextTouchView = self
    }

    func cachedSizeThatFits(width: CGFloat) -> CGSize {
        let clampedWidth = max(1, width)
        if abs(lastMeasuredWidth - clampedWidth) <= 0.5, lastMeasuredSize != .zero {
            return lastMeasuredSize
        }
        prepareForDisplay(
            text: currentRenderedText,
            markdownText: currentRenderedMarkdownText,
            layoutWidth: clampedWidth,
            summaryReferenceCount: currentSummaryReferenceCount,
            podcastTimestampsEnabled: currentPodcastTimestampsEnabled
        )
        return lastMeasuredSize == .zero ? super.sizeThatFits(CGSize(width: clampedWidth, height: .greatestFiniteMagnitude)) : lastMeasuredSize
    }

    func textView(
        _ textView: UITextView,
        shouldInteractWith URL: URL,
        in characterRange: NSRange,
        interaction: UITextItemInteraction
    ) -> Bool {
        if URL.scheme == "rssreader-podcast",
           URL.host == "seek",
           let value = URL.pathComponents.last,
           let seconds = TimeInterval(value) {
            onPodcastTimestampTap?(seconds)
            return false
        }

        guard URL.scheme == "rssreader-summary",
              let value = URL.pathComponents.last,
              let referenceNumber = Int(value) else {
            return true
        }

        onSummaryReferenceTap?(referenceNumber)
        return false
    }

    private func applyPodcastTimestampLinks() {
        guard !currentRenderedText.isEmpty,
              let regex = try? NSRegularExpression(
                  pattern: #"\[(\d{1,4}:\d{2}(?::\d{2})?)(?:\s*[-–—]\s*\d{1,4}:\d{2}(?::\d{2})?)?\]"#
              ) else {
            return
        }

        let source = currentRenderedText as NSString
        let sourceRange = NSRange(location: 0, length: source.length)
        for match in regex.matches(in: currentRenderedText, range: sourceRange) {
            let startRange = match.range(at: 1)
            guard startRange.location != NSNotFound,
                  let seconds = Self.podcastTimeInterval(from: source.substring(with: startRange)),
                  let destination = URL(string: "rssreader-podcast://seek/\(seconds)") else {
                continue
            }

            let timestampFont = UIFont.systemFont(
                ofSize: (font ?? UIFont.preferredFont(forTextStyle: .body)).pointSize,
                weight: .semibold
            )
            textStorage.addAttributes(
                [
                    .link: destination,
                    .foregroundColor: UIColor.systemBlue,
                    .underlineStyle: NSUnderlineStyle.single.rawValue,
                    .font: timestampFont
                ],
                range: match.range
            )
        }

        linkTextAttributes = [
            .foregroundColor: UIColor.systemBlue,
            .underlineStyle: NSUnderlineStyle.single.rawValue
        ]
    }

    private static func podcastTimeInterval(from timestamp: String) -> TimeInterval? {
        let values = timestamp.split(separator: ":").compactMap { Int($0) }
        guard values.count == 2 || values.count == 3,
              values.count == timestamp.split(separator: ":").count,
              let seconds = values.last,
              (0..<60).contains(seconds) else {
            return nil
        }

        if values.count == 2 {
            return TimeInterval(values[0] * 60 + values[1])
        }

        guard (0..<60).contains(values[1]) else { return nil }
        return TimeInterval(values[0] * 3_600 + values[1] * 60 + values[2])
    }

    private func applySummaryReferenceLinks(maximumReference: Int) {
        let fullRange = NSRange(location: 0, length: textStorage.length)
        if fullRange.length > 0 {
            if isMarkdownRendered {
                applyBaseAttributes(to: textStorage)
            } else {
                textStorage.setAttributes(
                    [
                        .font: font ?? UIFont.preferredFont(forTextStyle: .body),
                        .foregroundColor: textColor ?? UIColor.label
                    ],
                    range: fullRange
                )
            }
        }
        applyDetectedURLLinks()
        guard maximumReference > 0, !currentRenderedText.isEmpty else { return }

        // Providers do not always use the exact same citation spelling. Accept
        // "Article 2", "Article #2", "Article [2]", and compact bracketed
        // citations such as "[2]" without turning ordinary prose numbers into
        // links.
        let referenceToken = #"(?:#\s*)?(?:\[\s*)?\d+(?:\s*\])?"#
        let phrasePattern = #"\b(?:post|posts|article|articles|item|items)\s+\#(referenceToken)(?:\s*(?:,|\band\b|&)\s*(?:(?:post|posts|article|articles|item|items)\s+)?\#(referenceToken))*"#
        guard let phraseRegex = try? NSRegularExpression(pattern: phrasePattern, options: [.caseInsensitive]),
              let numberRegex = try? NSRegularExpression(pattern: #"\d+"#),
              let bracketRegex = try? NSRegularExpression(pattern: #"[\[\(]\s*#?(\d+)\s*[\]\)]"#) else {
            return
        }

        let source = currentRenderedText as NSString
        let sourceRange = NSRange(location: 0, length: source.length)
        func applyReferenceLink(numberRange: NSRange) {
            let number = Int(source.substring(with: numberRange)) ?? 0
            guard (1...maximumReference).contains(number),
                  let destination = URL(string: "rssreader-summary://item/\(number)") else {
                return
            }
            let referenceFont = UIFont.systemFont(
                ofSize: (font ?? UIFont.preferredFont(forTextStyle: .body)).pointSize,
                weight: .bold
            )
            textStorage.addAttributes(
                [
                    .link: destination,
                    .foregroundColor: UIColor.systemBlue,
                    .backgroundColor: UIColor.systemBlue.withAlphaComponent(0.16),
                    .underlineStyle: NSUnderlineStyle.single.rawValue,
                    .font: referenceFont
                ],
                range: numberRange
            )
        }

        for phraseMatch in phraseRegex.matches(in: currentRenderedText, range: sourceRange) {
            let phraseRange = phraseMatch.range
            for numberMatch in numberRegex.matches(in: currentRenderedText, range: phraseRange) {
                applyReferenceLink(numberRange: numberMatch.range)
            }
        }

        for bracketMatch in bracketRegex.matches(in: currentRenderedText, range: sourceRange) {
            let numberRange = bracketMatch.range(at: 1)
            guard numberRange.location != NSNotFound else { continue }
            applyReferenceLink(numberRange: numberRange)
        }

        linkTextAttributes = [
            .foregroundColor: UIColor.systemBlue,
            .underlineStyle: NSUnderlineStyle.single.rawValue
        ]
    }

    private func applyBaseAttributes(to attributedString: NSMutableAttributedString) {
        let fullRange = NSRange(location: 0, length: attributedString.length)
        guard fullRange.length > 0 else { return }

        attributedString.enumerateAttributes(in: fullRange) { attributes, range, _ in
            var additions: [NSAttributedString.Key: Any] = [:]
            if attributes[.font] == nil {
                additions[.font] = font ?? UIFont.preferredFont(forTextStyle: .body)
            }
            if attributes[.foregroundColor] == nil {
                additions[.foregroundColor] = textColor ?? UIColor.label
            }
            if !additions.isEmpty {
                attributedString.addAttributes(additions, range: range)
            }
        }
    }

    private func applyDetectedURLLinks() {
        guard !currentRenderedText.isEmpty,
              let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return
        }

        let source = currentRenderedText as NSString
        let sourceRange = NSRange(location: 0, length: source.length)
        for match in detector.matches(in: currentRenderedText, range: sourceRange) {
            guard let url = match.url,
                  match.range.location != NSNotFound,
                  NSMaxRange(match.range) <= textStorage.length else {
                continue
            }
            textStorage.addAttributes(
                [
                    .link: url,
                    .foregroundColor: UIColor.systemBlue,
                    .underlineStyle: NSUnderlineStyle.single.rawValue
                ],
                range: match.range
            )
        }

        linkTextAttributes = [
            .foregroundColor: UIColor.systemBlue,
            .underlineStyle: NSUnderlineStyle.single.rawValue
        ]
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
        guard range.location != NSNotFound, range.length > 0 else { return nil }
        guard supportsStandardAskAI || supportsWebAskAI else { return nil }

        var actions: [UIMenuElement]
        if usesCompactEditMenu {
            actions = [
                UIAction(title: "Copy", image: UIImage(systemName: "doc.on.doc")) { [weak self] _ in
                    self?.copySelectedTextToPasteboard()
                }
            ]
        } else {
            actions = suggestedActions
        }

        if supportsStandardAskAI {
            actions.append(
                UIAction(title: "Ask AI", image: UIImage(systemName: "questionmark.circle")) { [weak self] _ in
                    self?.handleAskAISelection(action: .standard)
                }
            )
        }

        if supportsWebAskAI {
            actions.append(
                UIAction(title: "Ask AI Web", image: UIImage(systemName: "globe")) { [weak self] _ in
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
    var markdownText: String? = nil
    var onAskAI: ((String, String) -> Void)? = nil
    var onAskAIWeb: ((String, String) -> Void)? = nil
    var onPodcastTimestampTap: ((TimeInterval) -> Void)? = nil
    var textIsPrecleaned: Bool = false

    var body: some View {
        Text(textIsPrecleaned ? text : cleanMarkdownArtifactsForDisplay(text))
            .textSelection(.enabled)
    }
}
#endif
