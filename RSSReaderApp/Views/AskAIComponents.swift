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

private let conversationalMarkdownParagraphMarker = "\u{E000}"
private let conversationalMarkdownParagraphSeparator = "\n\n\(conversationalMarkdownParagraphMarker)\n\n"

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
    guard !selected.isEmpty else { return "" }

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

    return """
    Answer the question using only the selected text and nearby rendered context.

    Rules:
    - Return plain text only.
    - Do not use Markdown symbols, headings, bullets, or code fences.
    - Use short paragraphs separated by a blank line when the answer has multiple ideas.
    - If the selected text and nearby context do not answer it, say the information is not available.

    Question:
    What is said about this selected text?

    Selected text:
    \(selected)

    Nearby rendered context:
    \(context.isEmpty ? "(No nearby rendered context was captured.)" : context)
    """
}

func askAINearbyRenderedContext(selectedText: String, in renderedText: String, window: Int = 320) -> String {
    let selected = selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !selected.isEmpty else { return "" }
    let text = renderedText
    guard let range = text.range(of: selected) else {
        return String(text.prefix(window * 2))
    }
    let start = text.index(range.lowerBound, offsetBy: -window, limitedBy: text.startIndex) ?? text.startIndex
    let end = text.index(range.upperBound, offsetBy: window, limitedBy: text.endIndex) ?? text.endIndex
    return String(text[start..<end])
}

/// Preserve Markdown block syntax while making provider-supplied prose line
/// breaks visible in the native macOS text view.
func normalizeAIReplyMarkdown(_ input: String) -> String {
    let normalizedNewlines = input
        .replacingOccurrences(of: "\r\n", with: "\n")
        .replacingOccurrences(of: "\r", with: "\n")
    let lines = normalizedNewlines.components(separatedBy: "\n")
    guard lines.count > 1 else { return normalizedNewlines }

    func matches(_ line: String, _ pattern: String) -> Bool {
        line.range(of: pattern, options: .regularExpression) != nil
    }
    func isFence(_ line: String) -> Bool {
        matches(line, #"^\s{0,3}(?:```|~~~)"#)
    }
    func isBlockSyntax(at index: Int) -> Bool {
        let line = lines[index]
        if matches(line, #"^\s*(?:[-+*]|\d+[.)])\s+|^\s*>|^\s{0,3}#{1,6}(?:\s|$)"#) {
            return true
        }
        if matches(line, #"^\s{0,3}(?:\*\s*){3,}$|^\s{0,3}(?:-\s*){3,}$|^\s{0,3}(?:_\s*){3,}$"#) {
            return true
        }
        guard line.contains("|") else { return false }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if matches(trimmed, #"^\|?\s*:?-{3,}:?\s*(?:\|\s*:?-{3,}:?\s*)+\|?$"#) {
            return true
        }
        let previous = index > 0 ? lines[index - 1].trimmingCharacters(in: .whitespaces) : ""
        let next = index + 1 < lines.count ? lines[index + 1].trimmingCharacters(in: .whitespaces) : ""
        return previous.contains("|") && next.contains("|")
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
        } else if insideFence || trimmed.isEmpty || result.last?.isEmpty == true || index == lines.startIndex {
            result.append(line)
        } else {
            let previousIndex = index - 1
            let hasExplicitHardBreak = lines[previousIndex].hasSuffix("\\") || lines[previousIndex].hasSuffix("  ")
            if !isBlockSyntax(at: previousIndex) && !isBlockSyntax(at: index) && !hasExplicitHardBreak {
                result.append("")
            }
            result.append(line)
        }
    }
    return result.joined(separator: "\n")
}

/// Recover paragraph boundaries from dense conversational provider output.
func normalizeConversationalAIReplyMarkdown(_ input: String) -> String {
    let normalized = normalizeAIReplyMarkdown(input)
    let value = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else { return normalized }

    // This helper is intentionally used at both the feature boundary and the
    // shared selectable Markdown renderer. Do not expand paragraph markers a
    // second time, or each rendering pass multiplies the blank-line spacing.
    if value.contains(conversationalMarkdownParagraphMarker) {
        return normalized
    }

    if value.contains("\n") {
        let boundaries = value.replacingOccurrences(
            of: #"\n[ \t]*\n+"#, with: "\n\n", options: .regularExpression
        )
        return boundaries.replacingOccurrences(of: "\n\n", with: conversationalMarkdownParagraphSeparator)
    }

    let startsWithBlockSyntax = value.range(
        of: #"^(?:\s{0,3}#{1,6}(?:\s|$)|\s*(?:[-+*]|\d+[.)])\s+|\s*>|\s*\|)"#,
        options: .regularExpression
    ) != nil
    guard !startsWithBlockSyntax, !value.contains("`"), !value.contains("~~~"), !value.contains("|") else {
        return normalized
    }

    let recoveredValue = value.replacingOccurrences(
        of: #"([.!?])([\"'”’]?[A-Z][a-z])"#,
        with: "$1 $2",
        options: .regularExpression
    )

    var sentences: [String] = []
    recoveredValue.enumerateSubstrings(
        in: recoveredValue.startIndex..<recoveredValue.endIndex,
        options: .bySentences
    ) { substring, _, _, _ in
        if let sentence = substring?.trimmingCharacters(in: .whitespacesAndNewlines), !sentence.isEmpty {
            sentences.append(sentence)
        }
    }
    guard sentences.count > 1 else { return recoveredValue }
    if sentences.count == 2, recoveredValue.count < 600 { return recoveredValue }
    if sentences.count >= 3, recoveredValue.count < 260 { return recoveredValue }

    let desiredParagraphs = max(2, Int(ceil(Double(recoveredValue.count) / 420.0)))
    let maximumParagraphs = max(2, sentences.count / 2)
    let paragraphCount = min(desiredParagraphs, min(maximumParagraphs, sentences.count))
    guard paragraphCount > 1 else { return recoveredValue }

    var paragraphs: [String] = []
    var sentenceIndex = 0
    for paragraphIndex in 0..<paragraphCount {
        let remainingSentences = sentences.count - sentenceIndex
        let remainingParagraphs = paragraphCount - paragraphIndex
        let count = Int(ceil(Double(remainingSentences) / Double(remainingParagraphs)))
        let endIndex = min(sentenceIndex + count, sentences.count)
        paragraphs.append(sentences[sentenceIndex..<endIndex].joined(separator: " "))
        sentenceIndex = endIndex
    }
    return paragraphs.joined(separator: conversationalMarkdownParagraphSeparator)
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
    var markdownResponse: String? = nil
    var selectionOrigin: AskAISelectionOrigin? = nil
    let errorMessage: String?
    let onClose: () -> Void
    let onCopy: () -> Void

    @EnvironmentObject private var appState: AppState
    @State private var isAskingFollowUp = false
    @State private var followUpResponse: String?
    @State private var followUpMarkdownResponse: String?
    @State private var showFollowUpSheet = false

    var body: some View {
        rootContainer
            .askAILoadingOverlay(isAskingFollowUp)
            .sheet(isPresented: $showFollowUpSheet) {
                AskAIResponseSheet(
                    isLoading: false,
                    response: followUpResponse,
                    markdownResponse: followUpMarkdownResponse,
                    selectionOrigin: selectionOrigin,
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
                    SelectableText(
                        formatAskAIResponseForDisplay(response),
                        markdownText: markdownResponse ?? normalizeConversationalAIReplyMarkdown(formatAskAIResponseForDisplay(response)),
                        normalizesMarkdownParagraphs: markdownResponse != nil
                    )
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
        let nearbyContext = askAINearbyRenderedContext(selectedText: selected, in: context)

        let origin = selectionOrigin ?? AskAISelectionOrigin(
            sourceLabel: "Current Ask AI answer",
            sourceText: context
        )
        let prompt = buildAskAISelectionPrompt(
            selectedText: selected,
            extractedContext: nearbyContext,
            sourceContext: origin.boundedSource(additionalAnswer: context),
            sourceLabel: origin.promptSourceLabel
        )

        followUpResponse = nil
        followUpMarkdownResponse = nil
        isAskingFollowUp = true

        let completion: (String) -> Void = { answer in
            DispatchQueue.main.async {
                followUpMarkdownResponse = useWebAI ? answer : nil
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
    var markdownText: String? = nil
    var normalizesMarkdownParagraphs: Bool = true
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

    init(
        _ text: String,
        markdownText: String? = nil,
        normalizesMarkdownParagraphs: Bool = true
    ) {
        self.text = text
        self.markdownText = markdownText
        self.normalizesMarkdownParagraphs = normalizesMarkdownParagraphs
    }

    init(_ attributedString: AttributedString) {
        self.text = String(attributedString.characters)
        self.markdownText = nil
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
            markdownText: markdownText,
            normalizesMarkdownParagraphs: normalizesMarkdownParagraphs,
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
    fileprivate var lastRenderedMarkdownText: String?

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
    let markdownText: String?
    let normalizesMarkdownParagraphs: Bool
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
        textView.isRichText = true
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
        let normalizedMarkdown = markdownText
            .map { value in
                normalizesMarkdownParagraphs
                    ? normalizeConversationalAIReplyMarkdown(value)
                    : value
            }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        hasher.combine(normalizedMarkdown ?? "")
        hasher.combine(normalizesMarkdownParagraphs)
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

        if nsView.lastRenderedText != text
            || nsView.lastRenderedMarkdownText != normalizedMarkdown
            || nsView.renderSignature != signature {
            let attributedText: NSMutableAttributedString
            if let normalizedMarkdown, !normalizedMarkdown.isEmpty,
               let parsed = try? AttributedString(
                   markdown: normalizedMarkdown,
                   options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .full)
               ) {
                attributedText = NSMutableAttributedString(attributedString: NSAttributedString(parsed))
                attributedText.mutableString.replaceOccurrences(
                    of: conversationalMarkdownParagraphMarker,
                    with: "\n\n",
                    range: NSRange(location: 0, length: attributedText.length)
                )
                applyBaseAttributes(to: attributedText, fallbackAttributes: attributes)
            } else {
                attributedText = NSMutableAttributedString(string: text, attributes: attributes)
            }
            if underline, attributedText.length > 0 {
                attributedText.addAttribute(
                    .underlineStyle,
                    value: NSUnderlineStyle.single.rawValue,
                    range: NSRange(location: 0, length: attributedText.length)
                )
            }
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
            nsView.lastRenderedMarkdownText = normalizedMarkdown
            nsView.renderSignature = signature
            nsView.invalidateIntrinsicContentSize()
        }
    }

    private func applyBaseAttributes(
        to attributedText: NSMutableAttributedString,
        fallbackAttributes: [NSAttributedString.Key: Any]
    ) {
        let fullRange = NSRange(location: 0, length: attributedText.length)
        guard fullRange.length > 0 else { return }
        attributedText.enumerateAttributes(in: fullRange) { current, range, _ in
            var additions: [NSAttributedString.Key: Any] = [:]
            if current[.font] == nil { additions[.font] = fallbackAttributes[.font] }
            if current[.foregroundColor] == nil { additions[.foregroundColor] = fallbackAttributes[.foregroundColor] }
            if current[.paragraphStyle] == nil { additions[.paragraphStyle] = fallbackAttributes[.paragraphStyle] }
            if !additions.isEmpty { attributedText.addAttributes(additions, range: range) }
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
            guard NSMaxRange(numberRange) <= attributedText.length else { return }
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
