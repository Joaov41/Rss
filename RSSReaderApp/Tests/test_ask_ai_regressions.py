import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]


def read(path: str) -> str:
    return (ROOT / path).read_text()


class AskAIRegressionTests(unittest.TestCase):
    def test_ask_ai_standard_uses_selected_summary_provider_path(self):
        source = read("RSSReaderApp/Controllers/AppState.swift")
        method = re.search(
            r"func askQuestionAboutSelection\([\s\S]*?\n    func askWebQuestionAboutSelection",
            source,
        )
        self.assertIsNotNone(method)
        self.assertIn('answerQuestion(trimmed, context: "", completion: completion)', method.group(0))
        self.assertNotIn("summarizeText", method.group(0))
        self.assertNotIn("askQuestionAboutGlobalSummary", method.group(0))

    def test_selected_question_path_uses_codex_for_summarize_daemon(self):
        source = read("RSSReaderApp/Controllers/AppState.swift")
        method = re.search(
            r"private func answerQuestion\([\s\S]*?\n    // MARK: - MLX Local Summary",
            source,
        )
        self.assertIsNotNone(method)
        branch = re.search(
            r"if provider == \.summarizeDaemon \{[\s\S]*?return\s+\}",
            method.group(0),
        )
        self.assertIsNotNone(branch)
        self.assertIn("generateContentWithSummarize", branch.group(0))
        self.assertIn("recordSummarizeThroughput", branch.group(0))

    def test_selected_question_path_uses_gemini_for_gemini_provider(self):
        source = read("RSSReaderApp/Controllers/AppState.swift")
        method = re.search(
            r"private func answerQuestion\([\s\S]*?\n    // MARK: - MLX Local Summary",
            source,
        )
        self.assertIsNotNone(method)
        fallback = method.group(0).split("if provider == .summarizeDaemon", 1)[-1]
        self.assertIn("summaryService.summarizeText", fallback)
        self.assertIn("customPrompt: prompt", fallback)

    def test_ask_ai_web_uses_web_model_selection_path(self):
        source = read("RSSReaderApp/Controllers/AppState.swift")
        method = re.search(
            r"func askWebQuestionAboutSelection\([\s\S]*?\n    // MARK: - Unified Summary Request Handler",
            source,
        )
        self.assertIsNotNone(method)
        self.assertIn("performExplicitWebAIQuestion", method.group(0))

    def test_web_qa_prompts_use_bounded_summary_style_context(self):
        source = read("RSSReaderApp/Controllers/AppState.swift")
        article_prompt = re.search(
            r"func articleQAPrompt\(article: Article, question: String\) -> String \{[\s\S]*?\n    \}",
            source,
        )
        reddit_prompt = re.search(
            r"func redditQAPrompt\(post: RedditPost, comments: \[RedditCommentModel\], question: String\) -> String \{[\s\S]*?\n    \}",
            source,
        )
        self.assertIsNotNone(article_prompt)
        self.assertIsNotNone(reddit_prompt)
        self.assertIn("strictQAPrompt", source)
        self.assertIn("normalizedSummarySourceText(content, maxCharacters: 12_000)", article_prompt.group(0))
        self.assertIn("redditSummarySourceText(post: post, comments: comments)", reddit_prompt.group(0))
        self.assertNotIn("\\(content)", article_prompt.group(0))
        self.assertNotIn("extractAllCommentTexts", reddit_prompt.group(0))

    def test_ask_ai_web_selection_prompt_is_bounded(self):
        source = read("RSSReaderApp/Views/AskAIUtilities.swift")
        method = re.search(
            r"func buildAskAISelectionPrompt\(selectedText: String, extractedContext: String\) -> String \{[\s\S]*?\n\}",
            source,
        )
        self.assertIsNotNone(method)
        self.assertIn("normalized(selectedText, maxCharacters: 1_500)", method.group(0))
        self.assertIn("normalized(extractedContext, maxCharacters: 8_000)", method.group(0))
        self.assertIn("Return plain text only", method.group(0))

    def test_long_press_menu_exposes_standard_and_web_actions(self):
        source = read("RSSReaderApp/Views/AskAIUtilities.swift")
        self.assertIn('UIMenuItem(title: "Ask AI"', source)
        self.assertIn('UIMenuItem(title: "Ask AI Web"', source)
        self.assertIn("handleAskAIWebAction", source)

    def test_overall_summary_wires_both_selection_actions(self):
        source = read("RSSReaderApp/Views/ContentView.swift")
        overall = re.search(
            r"DraggableGlobalSummaryView\([\s\S]*?onAskAISelection: handleSummaryAskAISelection\(selectedText:context:\),[\s\S]*?onAskAIWebSelection: handleSummaryAskAIWebSelection\(selectedText:context:\)",
            source,
        )
        self.assertIsNotNone(overall)
        self.assertIn("appState.askQuestionAboutSelection(prompt: prompt", source)
        self.assertIn("appState.askWebQuestionAboutSelection(prompt: prompt", source)

    def test_article_summary_and_qa_wire_both_selection_actions(self):
        source = read("RSSReaderApp/Views/ContentView.swift")
        self.assertIn("onAskAIWebSelection: handleAskAIWebSelection(selectedText:context:)", source)
        self.assertIn("appState.askQuestionAboutSelection(prompt: prompt", source)
        self.assertIn("appState.askWebQuestionAboutSelection(prompt: prompt", source)
        self.assertRegex(source, r"SelectableText\(\s*text: qaState\.answerText,[\s\S]*?onAskAIWeb:")

    def test_reddit_summary_and_qa_wire_both_selection_actions(self):
        source = read("RSSReaderApp/Views/RedditDetailView.swift")
        self.assertIn("onAskAIWebSelection: handleAskAIWebSelection(selectedText:context:)", source)
        self.assertRegex(source, r"SelectableText\(\s*text: answerText,[\s\S]*?onAskAIWeb:")
        self.assertIn("appState.askQuestionAboutSelection(prompt: prompt", source)
        self.assertIn("appState.askWebQuestionAboutSelection(prompt: prompt", source)

    def test_reddit_comment_summary_wires_both_selection_actions(self):
        source = read("RSSReaderApp/Views/RedditDetailView.swift")
        comment_summary_call = re.search(
            r"GlassyCommentSummary\(\s*summary: summary,[\s\S]*?onAskAISelection: handleAskAISelection\(selectedText:context:\),[\s\S]*?onAskAIWebSelection: handleAskAIWebSelection\(selectedText:context:\)",
            source,
        )
        self.assertIsNotNone(comment_summary_call)

        comment_summary_component = re.search(
            r"struct GlassyCommentSummary: View \{[\s\S]*?// MARK: - TTS Methods",
            source,
        )
        self.assertIsNotNone(comment_summary_component)
        component = comment_summary_component.group(0)
        self.assertIn("var onAskAISelection: ((String, String) -> Void)? = nil", component)
        self.assertIn("var onAskAIWebSelection: ((String, String) -> Void)? = nil", component)
        self.assertRegex(component, r"SelectableText\(\s*text: displaySummaryText,[\s\S]*?onAskAI: onAskAISelection,[\s\S]*?onAskAIWeb: onAskAIWebSelection")

    def test_explicit_reddit_web_summary_and_deep_analysis_update_ui_state(self):
        source = read("RSSReaderApp/Views/RedditDetailView.swift")
        menu = re.search(
            r"Menu \{[\s\S]*?Label\(\"Comment Summary\", systemImage: \"text\.redaction\"\)[\s\S]*?Label\(\"Deep Analysis\", systemImage: \"chart\.pie\.fill\"\)[\s\S]*?\} label:",
            source,
        )
        self.assertIsNotNone(menu)
        self.assertIn("requestWebCommentSummary(for: post)", menu.group(0))
        self.assertIn("analyticsProviderOverride = .webAI", menu.group(0))
        self.assertNotIn("openWebCommentSummary", menu.group(0))
        self.assertNotIn("openWebThematicAnalysis", menu.group(0))

        helper = re.search(
            r"private func requestWebCommentSummary\(for post: RedditPost\) \{[\s\S]*?\n    private func askQuestion",
            source,
        )
        self.assertIsNotNone(helper)
        self.assertIn("appState.performWebAIRequest", helper.group(0))
        self.assertIn("self.commentSummary = CommentSummary", helper.group(0))
        self.assertIn("self.showCommentSummary = true", helper.group(0))

        analytics = re.search(
            r"struct CommentAnalyticsViewIntegrated: View \{[\s\S]*?// MARK: - Helper Views",
            source,
        )
        self.assertIsNotNone(analytics)
        self.assertIn("@State private var analyticsProviderOverride: AppSettings.SummaryProvider? = nil", source)
        self.assertIn("providerOverride: analyticsProviderOverride", source)
        self.assertIn(".id(analyticsProviderOverride?.rawValue ?? \"settings\")", source)
        self.assertIn("var providerOverride: AppSettings.SummaryProvider? = nil", analytics.group(0))
        self.assertIn("private var effectiveSummaryProvider", analytics.group(0))
        self.assertIn("effectiveSummaryProvider == .webAI", source)
        self.assertIn("self.thematicAnalysis = cleanMarkdownArtifactsForDisplay(analysisText)", source)

    def test_explicit_overall_web_summary_and_qa_update_ui_state(self):
        content = read("RSSReaderApp/Views/ContentView.swift")
        self.assertIn("appState.requestWebCombinedGlobalSummary(force: true)", content)
        self.assertIn("askGlobalSummaryWebQuestion()", content)
        self.assertNotIn("appState.openWebCombinedGlobalSummary()", content)
        self.assertNotIn("appState.openWebGlobalSummaryQuestion(question: qaQuestionText)", content)

        app_state = read("RSSReaderApp/Controllers/AppState.swift")
        combined = re.search(
            r"func requestWebCombinedGlobalSummary\(force: Bool = true\) \{[\s\S]*?\n    func openWebGlobalSummaryQuestion",
            app_state,
        )
        self.assertIsNotNone(combined)
        self.assertIn("performWebAIRequest", combined.group(0))
        self.assertIn("self.aggregateSummaryText = trimmed", combined.group(0))
        self.assertIn("self.aggregateSummaryError = message", combined.group(0))

        global_qa = re.search(
            r"func askWebQuestionAboutGlobalSummary\(question: String, completion: @escaping \(String\) -> Void\) \{[\s\S]*?\n    private func executeWebGlobalQAPrompt",
            app_state,
        )
        self.assertIsNotNone(global_qa)
        self.assertIn("executeWebGlobalQAPrompt", global_qa.group(0))

        executor = re.search(
            r"private func executeWebGlobalQAPrompt\(prompt: String, completion: @escaping \(String\) -> Void\) \{[\s\S]*?\n    func openWebWhiteboard",
            app_state,
        )
        self.assertIsNotNone(executor)
        self.assertIn("performWebAIRequest", executor.group(0))
        self.assertIn('title: "Global Summary Q&A"', executor.group(0))

    def test_overall_web_visual_actions_update_app_ui_state(self):
        content = read("RSSReaderApp/Views/ContentView.swift")
        whiteboard = re.search(
            r"private func sendWhiteboardToWebAI\(\) \{[\s\S]*?\n    \}",
            content,
        )
        infographic = re.search(
            r"private func sendInfographicToWebAI\(\) \{[\s\S]*?\n    \}",
            content,
        )
        infographic_generator = re.search(
            r"private func generateInfographicWithWebAI\(prompt: String\) \{[\s\S]*?\n    private func generateInfographic",
            content,
        )
        self.assertIsNotNone(whiteboard)
        self.assertIsNotNone(infographic)
        self.assertIsNotNone(infographic_generator)
        self.assertIn("generateWhiteboardWithWebAI(prompt: buildWhiteboardPrompt())", whiteboard.group(0))
        self.assertIn("generateInfographicWithWebAI(prompt: buildInfographicPrompt())", infographic.group(0))
        self.assertNotIn("openWebWhiteboard", whiteboard.group(0))
        self.assertNotIn("openWebInfographic", infographic.group(0))
        self.assertIn("performWebAIRequestAsync", infographic_generator.group(0))
        self.assertIn("self.infographicContent = htmlData", infographic_generator.group(0))
        self.assertIn("self.showInfographic = true", infographic_generator.group(0))

    def test_article_no_summary_state_exposes_web_ai_globe(self):
        content = read("RSSReaderApp/Views/ContentView.swift")
        article_empty = re.search(
            r"private func summarySection\(article: Article\) -> some View \{[\s\S]*?\} else \{[\s\S]*?Label\(\"Summarize Article\", systemImage: \"text\.bubble\"\)[\s\S]*?appState\.requestWebSummary\(for: article\)[\s\S]*?Image\(systemName: \"globe\"\)",
            content,
        )
        self.assertIsNotNone(article_empty)

        summary_column = read("RSSReaderApp/Views/SummaryColumnView.swift")
        column_empty = re.search(
            r"Text\(\"Summarize Article\"\)[\s\S]*?appState\.requestWebSummary\(for: article\)[\s\S]*?Image\(systemName: \"globe\"\)",
            summary_column,
        )
        self.assertIsNotNone(column_empty)

    def test_web_ai_handoff_polls_and_cleans_captured_replies_for_ui_callbacks(self):
        source = read("RSSReaderApp/Views/WebAIHandoffView.swift")
        self.assertIn("startFallbackExtractionPollingIfNeeded(in: webView)", source)
        self.assertIn("captureFallbackExtractionBaseline(in: webView)", source)
        self.assertIn("deliverCapturedResponse(text)", source)
        self.assertIn("function chatGPTCandidates()", source)
        self.assertIn("function geminiCandidates()", source)
        self.assertIn("function findChatGPTSendButton(input)", source)
        self.assertIn("function looksLikeChatGPTSendButton(node)", source)
        self.assertIn("function activateAction(node)", source)
        self.assertIn("#if os(macOS)", source)
        self.assertIn("let usesPrivateStore = provider == .chatgpt", source)
        self.assertIn("let requiresFreshWebView = usesPrivateStore", source)
        self.assertIn("let usesPrivateStore = false", source)
        self.assertIn("let requiresFreshWebView = false", source)
        self.assertNotIn(".id(request.id)", source)
        self.assertIn("loadProviderHome(provider, in: webView)", source)
        self.assertIn("func hasWebView(for provider: WebAIProvider) -> Bool", source)
        self.assertIn("forceReload: true", source)
        self.assertNotIn("scheduleReadyWorkForReusablePage(in: webView)", source)
        self.assertIn("function recoverProviderLoadFailure()", source)
        self.assertIn('provider !== "chatgpt" && provider !== "gemini"', source)
        self.assertIn('bodyText.includes("content failed to load")', source)
        self.assertIn("private let promptStagingThreshold = 1800", source)
        self.assertIn("stagePromptIfNeeded(in: webView)", source)
        self.assertIn('? "(window.__codexPendingPromptText || \\"\\")"', source)
        self.assertIn("const text = \\(textSource);", source)
        self.assertIn("window.__codexPendingPromptChunks", source)
        self.assertNotIn("func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!)", source)
        self.assertIn("private func scheduleReadyWork(in webView: WKWebView)", source)
        self.assertIn("Self.buildCaptureBootstrapScript(handlerName: WebAIHandoffRepresentable.scriptMessageHandlerName)", source)
        self.assertIn("webView.customUserAgent = nil", source)
        self.assertNotIn("desktopSafariUserAgent", source)
        self.assertNotIn("preferredContentMode = .desktop", source)
        self.assertIn("removeCachedWebsiteData", source)
        self.assertIn("recoverProviderContentFailureIfNeeded(in: webView)", source)
        self.assertIn("providerContentFailureDetectionScript", source)
        self.assertIn("providerRetryButtonClickScript", source)
        self.assertIn("failed to load. Retrying...", source)
        self.assertIn("reloadFromOrigin()", source)
        self.assertIn("cachePolicy: .reloadIgnoringLocalAndRemoteCacheData", source)
        self.assertIn("sendButton.click();", source)
        self.assertIn('return provider === "chatgpt" ? "waiting" : "success";', source)
        self.assertNotIn('status == "chatgptVerify"', source)
        self.assertNotIn("checkChatGPTSubmissionStarted", source)
        self.assertNotIn("__codexChatGPTSendState", source)
        self.assertIn("stripGeminiBoilerplate(stripPromptEcho(candidate.text))", source)
        self.assertIn("stripPromptEcho(candidate.text))", source)
        app_state = read("RSSReaderApp/Controllers/AppState.swift")
        self.assertRegex(app_state, r"func performWebAIRequest\([\s\S]*enqueueWebAIRequest")

    def test_empty_work_summary_sections_are_not_rendered(self):
        content = read("RSSReaderApp/Views/ContentView.swift")
        reddit = read("RSSReaderApp/Views/RedditDetailView.swift")
        self.assertNotRegex(
            content,
            r"else\s*\{\s*VStack\(alignment: \.leading, spacing: 12\)\s*\{\s*HStack\s*\{\s*Text\(\"Summary\"\)",
        )
        self.assertNotRegex(
            reddit,
            r"else\s*\{\s*VStack\(alignment: \.leading, spacing: 12\)\s*\{\s*HStack\s*\{\s*Text\(\"Summary\"\)",
        )


if __name__ == "__main__":
    unittest.main()
