import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]


def read(path: str) -> str:
    return (ROOT / path).read_text()


def method_named(source: str, name: str) -> str:
    start = source.find(f"func {name}")
    if start == -1:
        return ""
    next_method = source.find("\n    func ", start + 1)
    next_private = source.find("\n    private func ", start + 1)
    candidates = [pos for pos in (next_method, next_private) if pos != -1]
    end = min(candidates) if candidates else len(source)
    return source[start:end]


class MacAskAIRegressionTests(unittest.TestCase):
    def test_ask_ai_standard_uses_codex_when_codex_is_selected(self):
        source = read("RSSReaderApp/Controllers/AppState.swift")
        method = method_named(source, "askQuestionAboutSelection")
        self.assertIn("case .summarizeDaemon:", method)
        self.assertIn("generateContentWithSummarize", method)
        self.assertIn("recordSummarizeThroughput", method)

    def test_ask_ai_standard_uses_gemini_when_gemini_is_selected(self):
        source = read("RSSReaderApp/Controllers/AppState.swift")
        method = method_named(source, "askQuestionAboutSelection")
        self.assertIn("case .gemini:", method)
        self.assertIn("summaryService.summarizeText", method)
        self.assertIn("customPrompt: trimmed", method)

    def test_ask_ai_web_uses_web_model_selection_path(self):
        source = read("RSSReaderApp/Controllers/AppState.swift")
        method = method_named(source, "askWebQuestionAboutSelection")
        self.assertIn("performExplicitWebAIQuestion", method)
        self.assertNotIn("summaryService.summarizeText", method)
        self.assertNotIn("generateContentWithSummarize", method)

    def test_text_and_webview_menus_expose_standard_and_web_actions(self):
        source = read("RSSReaderApp/Views/AskAIComponents.swift")
        self.assertGreaterEqual(source.count('"Ask AI Web"'), 4)
        self.assertIn("var askAIWebSelectionHandler", source)
        self.assertIn("func onAskAIWeb", source)
        self.assertIn("onAskAIWeb", source)
        self.assertRegex(source, r"NSMenuItem\(title: \"Ask AI Web\", action: #selector\(askAIWeb\)")

    def test_ask_ai_response_formatter_preserves_readable_spacing(self):
        source = read("RSSReaderApp/Views/AskAIComponents.swift")
        self.assertIn("private func splitDenseAskAISingleSentence", source)
        self.assertIn('"([:;])\\\\s+(?=[A-Z])"', source)
        self.assertIn("fallbackParagraphs", source)
        formatter = re.search(
            r"func formatAskAIResponseForDisplay\(_ input: String\) -> String \{[\s\S]*?\n\}\n\n// MARK: - Ask AI Response Sheet",
            source,
        )
        self.assertIsNotNone(formatter)
        self.assertIn('!value.contains("\\n\\n")', formatter.group(0))
        self.assertIn('sentences.joined(separator: "\\n\\n")', formatter.group(0))
        self.assertIn("splitDenseAskAISingleSentence(normalized)", formatter.group(0))
        self.assertIn('replacingOccurrences(of: "\\\\n{3,}"', formatter.group(0))

    def test_ask_ai_sheet_uses_response_formatter(self):
        source = read("RSSReaderApp/Views/AskAIComponents.swift")
        sheet = re.search(
            r"struct AskAIResponseSheet: View \{[\s\S]*?// MARK: - Ask AI Selection Environment",
            source,
        )
        self.assertIsNotNone(sheet)
        self.assertIn("Text(formatAskAIResponseForDisplay(response))", sheet.group(0))

    def test_ask_ai_answer_paths_store_formatted_responses(self):
        content = read("RSSReaderApp/Views/ContentView.swift")
        summary_column = read("RSSReaderApp/Views/SummaryColumnView.swift")
        reddit = read("RSSReaderApp/Views/RedditDetailView.swift")
        infographic = read("RSSReaderApp/Views/InfographicView.swift")
        global_summary = read("RSSReaderApp/Views/GlobalSummaryResultView.swift")

        for source in (content, summary_column, reddit, infographic, global_summary):
            self.assertIn("formatAskAIResponseForDisplay(", source)

        self.assertIn(
            "Use short paragraphs separated by a blank line when the answer has multiple ideas.",
            content,
        )
        self.assertNotIn("selectionAskAIResponse = answer", content)
        self.assertNotIn("selectionAskAIResponse = answer", summary_column)
        self.assertNotIn("selectionAskAIResponse = answer", reddit)
        self.assertNotIn("qaState.answerText = answer", content)
        self.assertNotIn("qaAnswerText = answer", content)
        self.assertNotIn("qaAnswerText = answer", global_summary)
        self.assertNotIn("askAIResponse = response", infographic)

    def test_overall_summary_wires_both_selection_actions(self):
        source = read("RSSReaderApp/Views/ContentView.swift")
        struct = re.search(r"struct DraggableGlobalSummaryView[\s\S]*?// MARK: - Whiteboard Generation", source)
        self.assertIsNotNone(struct)
        body = struct.group(0)
        self.assertIn("askAIHandler", body)
        self.assertIn("askAIWebHandler", body)
        self.assertIn("askAIFromSummarySelection(selection, action: .standard)", body)
        self.assertIn("askAIFromSummarySelection(selection, action: .web)", body)
        self.assertIn("performWebAIRequestAsync", body)

    def test_overview_web_ai_answers_return_to_ui_state(self):
        app_state = read("RSSReaderApp/Controllers/AppState.swift")
        content = read("RSSReaderApp/Views/ContentView.swift")
        draggable = re.search(r"struct DraggableGlobalSummaryView[\s\S]*?// MARK: - Whiteboard Generation", content)
        self.assertIsNotNone(draggable)
        body = draggable.group(0)

        self.assertIn("func requestWebCombinedGlobalSummary", app_state)
        self.assertRegex(app_state, r"requestWebCombinedGlobalSummary[\s\S]*?performWebAIRequest")
        self.assertRegex(app_state, r"requestWebCombinedGlobalSummary[\s\S]*?aggregateSummaryText")
        self.assertIn("func askWebQuestionAboutGlobalSummary", app_state)
        self.assertRegex(app_state, r"askWebQuestionAboutGlobalSummary[\s\S]*?executeWebGlobalQAPrompt")
        self.assertRegex(app_state, r"executeWebGlobalQAPrompt[\s\S]*?performWebAIRequest")
        self.assertIn("appState.requestWebCombinedGlobalSummary(force: true)", body)
        self.assertIn("askGlobalSummaryWebQuestion()", body)
        self.assertIn("appState.askWebQuestionAboutGlobalSummary", body)
        self.assertNotIn("appState.openWebCombinedGlobalSummary()", body)
        self.assertNotIn("appState.openWebGlobalSummaryQuestion(question: qaQuestionText)", body)

    def test_web_ai_capture_rejects_prompt_echo_before_updating_ui(self):
        app_state = read("RSSReaderApp/Controllers/AppState.swift")
        web_view = read("RSSReaderApp/Views/WebAIHandoffView.swift")
        handler = method_named(app_state, "handleCapturedWebAIResponse")

        self.assertIn("let prompt: String", app_state)
        self.assertIn("func isWebAIPromptEchoResponse", app_state)
        self.assertIn("isWebAIPromptEchoResponse(cleaned, prompt: pending.prompt)", handler)
        self.assertIn("pending.onSuccess(cleaned)", handler)
        self.assertLess(
            handler.find("isWebAIPromptEchoResponse(cleaned, prompt: pending.prompt)"),
            handler.find("pending.onSuccess(cleaned)"),
        )
        self.assertIn("window.__codexCapturePromptText = window.__codexPendingPromptText", web_view)
        self.assertIn("function activePromptText", web_view)
        self.assertIn("prompt.includes(text)", web_view)
        self.assertIn('window.__codexCapturePromptText || "', web_view)

    def test_web_ai_handoff_gemini_confirms_submission_before_success(self):
        app_state = read("RSSReaderApp/Controllers/AppState.swift")
        web_view = read("RSSReaderApp/Views/WebAIHandoffView.swift")

        self.assertIn("rich-textarea [contenteditable='true']", web_view)
        self.assertIn("[aria-label*='Enter a prompt'][role='textbox']", web_view)
        self.assertIn("function setContentEditableValue(el, value)", web_view)
        self.assertIn("function activateAction(node, callNativeClick = true)", web_view)
        self.assertIn("function findGeminiSendButton(input)", web_view)
        self.assertIn("function looksLikeGeminiSendButton(node, input)", web_view)
        self.assertIn("activateAction(sendButton, false)", web_view)
        self.assertIn("__codexGeminiSubmissionPending", web_view)
        self.assertIn('text.includes("something went wrong") && text.includes("1096")', web_view)
        self.assertIn('normalized.contains("something went wrong") && normalized.contains("1096")', app_state)
        self.assertNotIn('return provider === "chatgpt" ? "waiting" : "success";', web_view)

    def test_whiteboard_and_infographic_web_ai_answers_return_to_ui(self):
        content = read("RSSReaderApp/Views/ContentView.swift")
        whiteboard = method_named(content, "generateWhiteboard")
        infographic = method_named(content, "generateInfographic")
        whiteboard_web = method_named(content, "generateWhiteboardWithWebAI")
        infographic_web = method_named(content, "generateInfographicWithWebAI")

        self.assertIn("generateWhiteboardWithWebAI(prompt: prompt, rankedCandidates: rankedCandidates)", whiteboard)
        self.assertNotIn("appState.openWebWhiteboard(prompt: prompt)", whiteboard)
        self.assertIn("appState.performWebAIRequestAsync", whiteboard_web)
        self.assertIn("responseFormat: .strictJSON", whiteboard_web)
        self.assertIn("parseWhiteboardPayloadFromData", whiteboard_web)
        self.assertIn("whiteboardContent", whiteboard_web)
        self.assertIn("showWhiteboard = true", whiteboard_web)

        self.assertIn("generateInfographicWithWebAI(prompt: prompt, rankedCandidates: rankedCandidates)", infographic)
        self.assertNotIn("appState.openWebInfographic(prompt: prompt)", infographic)
        self.assertIn("appState.performWebAIRequestAsync", infographic_web)
        self.assertIn("responseFormat: .strictJSON", infographic_web)
        self.assertIn("parseInfographicPayloadFromData", infographic_web)
        self.assertIn("infographicContent", infographic_web)
        self.assertIn("showInfographic = true", infographic_web)

    def test_article_summary_and_qa_wire_both_selection_actions(self):
        source = read("RSSReaderApp/Views/ContentView.swift")
        self.assertIn("ArticleGlassySummary(", source)
        self.assertIn("onAskAIWeb:", source)
        self.assertIn("askAIFromArticleSelection(selection, article: article, action: .standard)", source)
        self.assertIn("askAIFromArticleSelection(selection, article: article, action: .web)", source)
        self.assertRegex(source, r"SelectableText\(processedAnswer\)[\s\S]*?\.onAskAIWeb")

    def test_reddit_summary_and_qa_wire_both_selection_actions(self):
        source = read("RSSReaderApp/Views/RedditDetailView.swift")
        self.assertIn("askAIFromRedditSelection(selection, post: post, action: .standard)", source)
        self.assertIn("askAIFromRedditSelection(selection, post: post, action: .web)", source)
        self.assertRegex(source, r"SelectableText\(\.init\(summary\)\)[\s\S]*?\.onAskAIWeb")
        self.assertRegex(source, r"SelectableText\(answerText\)[\s\S]*?\.onAskAIWeb")

    def test_reddit_deep_analysis_web_menu_uses_web_override(self):
        source = read("RSSReaderApp/Views/RedditDetailView.swift")
        generate_analytics = method_named(source, "generateAnalytics")
        generate_thematic = method_named(source, "generateThematicAnalysis")

        self.assertIn("@State private var analyticsProviderOverride: AppSettings.SummaryProvider? = nil", source)
        self.assertIn("analyticsProviderOverride = .webAI", source)
        self.assertIn("providerOverride: analyticsProviderOverride", source)
        self.assertIn(".id(analyticsProviderOverride?.rawValue ?? \"settings\")", source)
        self.assertIn("var providerOverride: AppSettings.SummaryProvider? = nil", source)
        self.assertIn("private var effectiveSummaryProvider: AppSettings.SummaryProvider", source)
        self.assertIn("switch self.effectiveSummaryProvider", generate_analytics)
        self.assertIn("case .appleLocal, .appleCloud, .applePCCGateway, .mlxLocal, .webAI, .summarizeDaemon:", generate_analytics)
        self.assertIn("effectiveSummaryProvider == .webAI", generate_thematic)
        self.assertIn("appState.performWebAIRequest", generate_thematic)
        self.assertNotIn("analyticsForceWebAI", source)
        self.assertNotIn("appState.settings.selectedSummaryProvider == .webAI", generate_thematic)

    def test_reddit_comment_summary_wires_both_selection_actions(self):
        source = read("RSSReaderApp/Views/RedditDetailView.swift")
        comment_section = re.search(
            r"if showCommentSummary \{[\s\S]*?// Throughput badge for on-device providers \(comment summary\)",
            source,
        )
        self.assertIsNotNone(comment_section)
        body = comment_section.group(0)
        self.assertIn("SelectableText(.init(summary.summary))", body)
        self.assertIn("askAIFromRedditSelection(selection, post: post, action: .standard)", body)
        self.assertIn("askAIFromRedditSelection(selection, post: post, action: .web)", body)

        component = re.search(r"struct GlassyCommentSummary[\s\S]*?// Add this new component below GlassyCommentSummary", source)
        self.assertIsNotNone(component)
        self.assertIn("var onAskAI: ((String) -> Void)?", component.group(0))
        self.assertIn("var onAskAIWeb: ((String) -> Void)?", component.group(0))
        self.assertRegex(component.group(0), r"SelectableText\(\.init\(summary\.summary\)\)[\s\S]*?\.onAskAIWeb")

    def test_work_summary_sections_stay_hidden_until_summary_exists(self):
        content = read("RSSReaderApp/Views/ContentView.swift")
        reddit = read("RSSReaderApp/Views/RedditDetailView.swift")
        column = read("RSSReaderApp/Views/SummaryColumnView.swift")
        self.assertRegex(content, r"else if let summary = article\.summary,\s*!summary\.trimmingCharacters")
        self.assertRegex(reddit, r"else if let summary = (post\.summary|visiblePostSummary),\s*!summary\.trimmingCharacters")
        self.assertRegex(column, r"else if let summary = article\.summary,\s*!summary\.trimmingCharacters")


if __name__ == "__main__":
    unittest.main()
