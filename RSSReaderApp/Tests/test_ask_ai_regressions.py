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

    def test_article_summary_context_policy_preserves_full_remote_and_limited_local_paths(self):
        source = read("RSSReaderApp/Controllers/AppState.swift")
        summary_prompts = re.search(
            r"func articleSummaryPrompt\([\s\S]*?\n    func redditPostSummaryPrompt",
            source,
        )
        self.assertIsNotNone(summary_prompts)
        block = summary_prompts.group(0)
        full_prompt, local_and_gemini = block.split("private func localArticleSummaryPrompt", 1)
        local_prompt, gemini_prompt = local_and_gemini.split("func geminiArticleSummaryPrompt", 1)
        self.assertNotIn("maxCharacters:", full_prompt)
        self.assertIn("maxCharacters: 12_000", local_prompt)
        self.assertNotIn("maxCharacters:", gemini_prompt)
        self.assertIn('summaryService.summarizeText("", customPrompt: articlePrompt)', source)

        request_summary = re.search(
            r"func requestSummary\([\s\S]*?\n    // MARK: - Today Summary",
            source,
        )
        self.assertIsNotNone(request_summary)
        self.assertEqual(request_summary.group(0).count("article.map(localArticleSummaryPrompt(for:))"), 2)
        self.assertGreaterEqual(request_summary.group(0).count("article.map(articleSummaryPrompt(for:))"), 2)

    def test_article_qa_context_policy_preserves_full_remote_and_limited_local_paths(self):
        source = read("RSSReaderApp/Controllers/AppState.swift")
        prompts = re.search(
            r"func articleQAPrompt\([\s\S]*?\n    func redditQAPrompt",
            source,
        )
        self.assertIsNotNone(prompts)
        block = prompts.group(0)
        full_prompt, local_and_builder = block.split("private func localArticleQAPrompt", 1)
        local_prompt, _ = local_and_builder.split("private func makeArticleQAPrompt", 1)
        self.assertIn("maxCharacters: nil", full_prompt)
        self.assertIn("maxCharacters: 12_000", local_prompt)

        qa_method = re.search(
            r"func askQuestionAboutArticle\([\s\S]*?\n    func askQuestionAboutRedditPost",
            source,
        )
        self.assertIsNotNone(qa_method)
        self.assertGreaterEqual(qa_method.group(0).count("articleQAPrompt(article: article"), 4)
        self.assertEqual(qa_method.group(0).count("localArticleQAPrompt("), 2)

    def test_reddit_model_context_has_no_hidden_character_or_comment_caps(self):
        source = read("RSSReaderApp/Controllers/AppState.swift")
        reddit_view = read("RSSReaderApp/Views/RedditDetailView.swift")

        helper = re.search(
            r"private func redditSummarySourceText\([\s\S]*?\n    private func normalizedSummarySourceText",
            source,
        )
        self.assertIsNotNone(helper)
        self.assertNotIn("maxCharacters:", helper.group(0))
        self.assertNotIn("maxComments", helper.group(0))

        reddit_qa = re.search(
            r"func redditQAPrompt\([\s\S]*?\n    func articleSelectionSourceContext",
            source,
        )
        self.assertIsNotNone(reddit_qa)
        self.assertIn("redditSummarySourceText(post: post, comments: comments)", reddit_qa.group(0))
        self.assertNotIn("maxComments", reddit_qa.group(0))

        self.assertNotIn("maxComments: 800", source)
        self.assertNotIn("geminiCommentPromptLimit", reddit_view)
        self.assertNotIn("postText: Self.firstNChars(triple.post.content", source)
        self.assertNotIn("let limitedPost", source)
        self.assertNotIn("let limitedComments", source)

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

    def test_ask_ai_response_formatter_preserves_readable_spacing(self):
        source = read("RSSReaderApp/Views/AskAIUtilities.swift")
        formatter = re.search(
            r"func formatAskAIResponseForDisplay\(_ input: String\) -> String \{[\s\S]*?\n\}\n\nfunc buildAskAISelectionPrompt",
            source,
        )
        self.assertIsNotNone(formatter)
        self.assertIn("cleanMarkdownArtifactsForDisplay(input)", formatter.group(0))
        self.assertIn('!value.contains("\\n\\n")', formatter.group(0))
        self.assertIn('sentences.joined(separator: "\\n\\n")', formatter.group(0))
        self.assertIn('replacingOccurrences(of: "\\\\n{3,}"', formatter.group(0))

    def test_ask_ai_sheet_uses_response_formatter(self):
        source = read("RSSReaderApp/Views/AskAIUtilities.swift")
        view = re.search(
            r"struct AskAIWebView: View \{[\s\S]*?struct AskAIResponseSheet: View",
            source,
        )
        self.assertIsNotNone(view)
        self.assertIn("Text(formatAskAIResponseForDisplay(content))", view.group(0))

    def test_selection_ask_ai_prompts_request_blank_line_paragraphs(self):
        source = read("RSSReaderApp/Views/AskAIUtilities.swift")
        self.assertIn(
            "Use short paragraphs separated by a blank line when the answer has multiple ideas.",
            source,
        )

    def test_ask_ai_answer_paths_store_formatted_responses(self):
        content = read("RSSReaderApp/Views/ContentView.swift")
        summary_column = read("RSSReaderApp/Views/SummaryColumnView.swift")
        reddit = read("RSSReaderApp/Views/RedditDetailView.swift")
        infographic = read("RSSReaderApp/Views/InfographicView.swift")

        for source in (content, summary_column, reddit, infographic):
            self.assertIn("formatAskAIResponseForDisplay(answer)", source)

        self.assertIn("formatAskAIResponseForDisplay(processed)", reddit)
        self.assertNotIn("selectionAskAIResponse = cleanMarkdownArtifactsForDisplay(answer)", content)
        self.assertNotIn("selectionAskAIResponse = cleanMarkdownArtifactsForDisplay(answer)", summary_column)
        self.assertNotIn("selectionAskAIResponse = cleanMarkdownArtifactsForDisplay(answer)", reddit)
        self.assertNotIn("qaState.answerText = cleanMarkdownArtifactsForDisplay(answer)", content)
        self.assertNotIn("answerText = cleanMarkdownArtifactsForDisplay(answer)", reddit)

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

    def test_summary_selection_drag_does_not_trigger_full_screen_back(self):
        source = read("RSSReaderApp/Views/ContentView.swift")
        gesture = re.search(
            r"func enhancedSwipeBack\(perform action:[\s\S]*?func anywhereSwipeBack",
            source,
        )
        self.assertIsNotNone(gesture)
        self.assertIn("coordinateSpace: .local", gesture.group(0))
        self.assertIn(
            "guard !AskAITextView.didActiveTextTouchChangeSelection else { return }",
            gesture.group(0),
        )
        self.assertIn("DispatchQueue.main.asyncAfter(deadline: .now() + 0.01)", gesture.group(0))

        utilities = read("RSSReaderApp/Views/AskAIUtilities.swift")
        self.assertIn("TextSelectionIntentGestureRecognizer", utilities)
        self.assertIn("func textViewDidChangeSelection", utilities)
        self.assertIn("didSelectionChangeDuringCurrentTouch = true", utilities)
        self.assertIn("currentTextTouchView = self", utilities)

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
        summary_section = re.search(
            r"private func summarySection\(article: Article\) -> some View \{[\s\S]*?\n    private func qaSection",
            content,
        )
        self.assertIsNotNone(summary_section)
        article_empty = re.search(
            r"else\s*\{\s*if shouldShowExplicitWebAIControls \{[\s\S]*?appState\.requestWebSummary\(for: article\)[\s\S]*?Image\(systemName: \"globe\"\)",
            summary_section.group(0),
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
        self.assertIn("function activateAction(node, callNativeClick = true)", source)
        self.assertIn("activateAction(sendButton, true)", source)
        self.assertIn("__codexWebAIPreparedPrompt", source)
        self.assertIn("__codexWebAISubmissionPending", source)
        self.assertIn("assistantTurnCount() > startingTurns", source)
        self.assertIn("private let websiteDataStore = WKWebsiteDataStore.default()", source)
        self.assertIn("forceFresh: Bool = false", source)
        self.assertIn("let requiresFreshWebView = forceFresh", source)
        self.assertIn("if !requiresFreshWebView, let existing = webViews[provider]", source)
        self.assertIn("configuration.websiteDataStore = websiteDataStore", source)
        self.assertNotIn("WKWebsiteDataStore.nonPersistent()", source)
        self.assertNotIn(".nonPersistent()", source)
        self.assertIn(".id(request.id)", source)
        self.assertIn("forceFresh: request.shouldAutoCapture", source)
        self.assertIn("loadProviderHome(provider, in: webView)", source)
        self.assertIn("func hasWebView(for provider: WebAIProvider) -> Bool", source)
        self.assertIn("forceReload: true", source)
        self.assertNotIn("coordinator.prepareReusablePage(in: webView)", source)
        self.assertNotIn("func prepareReusablePage(in webView: WKWebView)", source)
        self.assertNotIn("function recoverProviderLoadFailure()", source)
        self.assertNotIn("function findNewChatButton()", source)
        self.assertNotIn("__codexWebAINewChatState", source)
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
        self.assertNotIn("removeCachedWebsiteData", source)
        self.assertNotIn("WKWebsiteDataTypeServiceWorkerRegistrations", source)
        self.assertNotIn("WKWebsiteDataTypeFetchCache", source)
        self.assertNotIn("startProviderContentFailureMonitorIfNeeded(in: webView)", source)
        self.assertNotIn("private var isRecoveringProviderContentFailure = false", source)
        self.assertIn("private let composerWaitTimeout: TimeInterval = 30", source)
        self.assertIn("private var pendingInjectionWorkItem: DispatchWorkItem?", source)
        self.assertIn("private func scheduleInjection(in webView: WKWebView, after delay: TimeInterval)", source)
        self.assertNotIn("maxAutomaticRequestRetryAttempts", source)
        self.assertNotIn("retryAutomaticRequestAfterProviderFailure", source)
        recovery = re.search(
            r"private func recoverProviderContentFailureIfNeeded[\s\S]*?private static func providerContentFailureDetectionScript",
            source,
        )
        self.assertIsNotNone(recovery)
        self.assertNotIn("removeAllWebsiteData", recovery.group(0))
        self.assertNotIn("removeCachedWebsiteData", recovery.group(0))
        self.assertIn("completion(.navigationStarted)", recovery.group(0))
        self.assertIn("removeAllWebsiteData(for: provider, from: websiteDataStore)", source)
        self.assertIn("recoverProviderContentFailureIfNeeded(in: webView)", source)
        self.assertIn("providerContentFailureDetectionScript", source)
        self.assertIn("providerRetryButtonClickScript", source)
        self.assertIn("failed to load. Retrying...", source)
        self.assertNotIn("reloadFromOrigin()", source)
        self.assertIn("cachePolicy: .reloadIgnoringLocalAndRemoteCacheData", source)
        self.assertIn("function isUsableComposer(node)", source)
        self.assertIn("function firstUsableComposer(selectors)", source)
        self.assertNotIn("clickProviderRetryButton", source)
        self.assertIn("function findGeminiSendButton(input)", source)
        self.assertIn("function looksLikeGeminiSendButton(node, input)", source)
        self.assertIn("activateAction(sendButton, true)", source)
        self.assertIn("__codexWebAISubmissionPending", source)
        self.assertNotIn("__codexGeminiSubmissionPending", source)
        self.assertIn('text.includes("something went wrong") && text.includes("1096")', source)
        self.assertNotIn('return provider === "chatgpt" ? "waiting" : "success";', source)
        self.assertNotIn('status == "chatgptVerify"', source)
        self.assertNotIn("checkChatGPTSubmissionStarted", source)
        self.assertNotIn("__codexChatGPTSendState", source)
        self.assertIn("stripGeminiBoilerplate(stripPromptEcho(candidate.text))", source)
        self.assertIn("stripPromptEcho(candidate.text))", source)
        app_state = read("RSSReaderApp/Controllers/AppState.swift")
        self.assertRegex(app_state, r"func performWebAIRequest\([\s\S]*enqueueWebAIRequest")
        self.assertIn("var automaticRetryCount: Int", app_state)
        self.assertIn("retryWebAIRequestIfPossible", app_state)
        self.assertIn("isRecoverableWebAIRequestFailure", app_state)
        self.assertNotIn("Auto-clearing caches (10-minute interval)", app_state)
        clear_caches = re.search(
            r"func clearAllCaches[\s\S]*?\n    func clearFailedModelDownloads",
            app_state,
        )
        self.assertIsNotNone(clear_caches)
        self.assertNotIn("WKWebsiteDataStore", clear_caches.group(0))

    def test_interactive_summarize_request_has_cancelling_transport_timeout(self):
        app_state = read("RSSReaderApp/Controllers/AppState.swift")
        summary_service = read("RSSReaderApp/Services/SummaryService.swift")
        bridge = read("RSSReaderApp/Services/SummarizeBridge.swift")

        self.assertIn("private var interactiveAskAITimeoutSeconds: TimeInterval { 120 }", app_state)
        self.assertRegex(
            app_state,
            r"generateContentWithSummarize\([\s\S]*?timeout: self\.interactiveAskAITimeoutSeconds",
        )
        self.assertIn("timeout: TimeInterval = 300", summary_service)
        self.assertIn("timeout: timeout", summary_service)
        self.assertNotIn("withThrowingTaskGroup", bridge)
        self.assertIn("box.installTimeoutWorkItem(timeoutWorkItem)", bridge)
        self.assertIn("queue.asyncAfter(deadline: .now() + timeout, execute: timeoutWorkItem)", bridge)
        self.assertIn("connection?.cancel()", bridge)
        self.assertIn("request.timeoutInterval = timeout", bridge)

    def test_web_ai_timeout_removes_pending_request_and_stops_capture(self):
        app_state = read("RSSReaderApp/Controllers/AppState.swift")
        handoff = read("RSSReaderApp/Views/WebAIHandoffView.swift")

        self.assertIn("private let webAIRequestTimeoutSeconds: TimeInterval = 210", app_state)
        self.assertIn("var timeoutWorkItem: DispatchWorkItem?", app_state)
        self.assertIn("DispatchQueue.main.asyncAfter(", app_state)
        self.assertIn("handleWebAIRequestFailure(", app_state)
        self.assertIn("dismissPanel: true", app_state)
        self.assertGreaterEqual(app_state.count("pending.timeoutWorkItem?.cancel()"), 4)
        self.assertIn("WebAISessionManager.shared.cancelActiveRequest", app_state)
        self.assertIn("func cancelActiveRequest(for provider: WebAIProvider)", handoff)
        self.assertIn("webView.stopLoading()", handoff)
        self.assertIn("window.__webAICapture.stop()", handoff)

    def test_web_ai_capture_failures_are_terminal(self):
        source = read("RSSReaderApp/Views/WebAIHandoffView.swift")

        process_termination = re.search(
            r"func webViewWebContentProcessDidTerminate[\s\S]*?\n        \}",
            source,
        )
        navigation_failure = re.search(
            r"private func handleNavigationFailure[\s\S]*?\n        \}",
            source,
        )
        manual_fallback = re.search(
            r"private func triggerManualFallback[\s\S]*?\n        \}",
            source,
        )
        self.assertIsNotNone(process_termination)
        self.assertIsNotNone(navigation_failure)
        self.assertIsNotNone(manual_fallback)
        self.assertIn("deliverCaptureFailure", process_termination.group(0))
        self.assertIn("deliverCaptureFailure", navigation_failure.group(0))
        self.assertIn("deliverCaptureFailure", manual_fallback.group(0))
        self.assertNotIn("copyToPasteboard", manual_fallback.group(0))
        self.assertNotIn("clipboard", manual_fallback.group(0).lower())
        self.assertIn("if timedOut", source)
        self.assertIn("Automatic response capture timed out", source)
        self.assertIn("bootstrapError == nil", source)
        self.assertIn('(result as? String) == "armed"', source)

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
