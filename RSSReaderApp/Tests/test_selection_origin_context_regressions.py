import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]


def read(path: str) -> str:
    return (ROOT / path).read_text()


def bounded_origin_for_test(source, question, answer, current_answer, max_characters=40_000):
    qa_sections = []
    if question:
        qa_sections.append(("Original Q&A question", question))
    if answer:
        qa_sections.append(("Complete Q&A answer", answer))
    if current_answer and current_answer != answer:
        qa_sections.append(("Current displayed Ask AI answer", current_answer))

    section_count = (1 if source else 0) + len(qa_sections)
    separator_budget = max(0, section_count - 1) * 2
    source_header_budget = len("Original article source") + 2 if source else 0
    qa_header_budget = sum(len(label) + 2 for label, _ in qa_sections)
    available_body_budget = max(
        0,
        max_characters - separator_budget - source_header_budget - qa_header_budget,
    )
    qa_body_count = sum(len(body) for _, body in qa_sections)
    source_minimum_budget = min(len(source), max(1, available_body_budget // 4)) if source else 0
    if not source:
        source_budget = 0
    elif len(source) + qa_body_count <= available_body_budget:
        source_budget = len(source)
    else:
        qa_reservation = min(qa_body_count, max(0, available_body_budget - source_minimum_budget))
        source_budget = min(
            len(source),
            max(source_minimum_budget, available_body_budget - qa_reservation),
        )

    qa_budget = max(0, available_body_budget - source_budget)
    qa_body_budgets = [0] * len(qa_sections)
    remaining_qa_budget = qa_budget
    for index, (_, body) in enumerate(qa_sections):
        if remaining_qa_budget <= 0:
            break
        qa_body_budgets[index] = min(1, len(body))
        remaining_qa_budget -= qa_body_budgets[index]
    while remaining_qa_budget > 0:
        made_progress = False
        for index, (_, body) in enumerate(qa_sections):
            if remaining_qa_budget <= 0:
                break
            if qa_body_budgets[index] >= len(body):
                continue
            qa_body_budgets[index] += 1
            remaining_qa_budget -= 1
            made_progress = True
        if not made_progress:
            break

    sections = []
    if source_budget > 0:
        sections.append(f"Original article source:\n{source[:source_budget]}")
    for (label, body), budget in zip(qa_sections, qa_body_budgets):
        if budget > 0:
            sections.append(f"{label}:\n{body[:budget]}")
    return "\n\n".join(sections)[:max_characters]


def recursive_comment_texts(comments):
    texts = []
    for comment in comments:
        texts.append(f"u/{comment['author']}: {comment['body']}")
        texts.extend(recursive_comment_texts(comment.get("replies", [])))
    return texts


class SelectionOriginContextRegressionTests(unittest.TestCase):
    def test_origin_carrier_and_prompt_keep_source_and_complete_qa_bounded(self):
        source = read("RSSReaderApp/Views/AskAIComponents.swift")
        carrier = re.search(
            r"struct AskAISelectionOrigin \{[\s\S]*?\n\}\n\nfunc buildAskAISelectionPrompt",
            source,
        )
        self.assertIsNotNone(carrier)
        block = carrier.group(0)
        self.assertIn("let sourceText: String", block)
        self.assertIn("let originalQuestion: String?", block)
        self.assertIn("let originalAnswer: String?", block)
        self.assertIn("Original Q&A question", block)
        self.assertIn("Complete Q&A answer", block)
        self.assertIn("Current displayed Ask AI answer", block)
        self.assertIn("maxCharacters: Int = 40_000", block)
        self.assertIn("sourceMinimumBudget", block)
        self.assertIn("qaBodyBudgets", block)
        self.assertIn("source.prefix(sourceBudget)", block)
        self.assertIn("composed.count > maxCharacters", block)
        self.assertIn("sourceBudget", block)

    def test_oversized_qa_keeps_source_and_all_labels_within_bound(self):
        source_marker = "ARTICLE-SOURCE-MARKER "
        question_marker = "QUESTION-MARKER "
        answer_marker = "ANSWER-MARKER "
        current_marker = "CURRENT-ANSWER-MARKER "
        bounded = bounded_origin_for_test(
            source_marker * 2_000,
            question_marker * 2_000,
            answer_marker * 4_000,
            current_marker * 4_000,
        )
        self.assertIn("Original article source:", bounded)
        self.assertIn("ARTICLE-SOURCE-MARKER", bounded)
        self.assertIn("Original Q&A question:", bounded)
        self.assertIn("Complete Q&A answer:", bounded)
        self.assertIn("Current displayed Ask AI answer:", bounded)
        self.assertIn("QUESTION-MARKER", bounded)
        self.assertIn("ANSWER-MARKER", bounded)
        self.assertIn("CURRENT-ANSWER-MARKER", bounded)
        self.assertLessEqual(len(bounded), 40_000)

    def test_article_qa_selection_preserves_article_and_both_provider_paths(self):
        source = read("RSSReaderApp/Views/ContentView.swift")
        qa = re.search(
            r"private func handleQAAskAISelection\([\s\S]*?\n    private func handleQAAskAIWebSelection",
            source,
        )
        self.assertIsNotNone(qa)
        block = qa.group(0)
        self.assertIn("articleSelectionSourceContext(for: article)", block)
        self.assertIn("originalQuestion:", block)
        self.assertIn("originalAnswer: qaState.answerText", block)
        self.assertIn("selectionOrigin: origin", block)

        self.assertIn(".onAskAI { selectedText in", source)
        self.assertIn(".onAskAIWeb { selectedText in", source)
        self.assertIn("sourceContext: selectionOrigin.boundedSource(additionalAnswer: qaState.answerText)", source)

    def test_reddit_qa_selection_preserves_post_comments_and_both_provider_paths(self):
        source = read("RSSReaderApp/Views/RedditDetailView.swift")
        qa = re.search(
            r"private func askAIFromRedditQASelection\([\s\S]*?\n    private func askAIFromRedditSelection",
            source,
        )
        self.assertIsNotNone(qa)
        block = qa.group(0)
        self.assertIn("redditSelectionSourceContext(post: post, comments: comments)", block)
        self.assertIn("originalQuestion:", block)
        self.assertIn("originalAnswer: answerText", block)
        self.assertIn("selectionOrigin: origin", block)

        self.assertIn("askAIFromRedditQASelection(selection", source)
        self.assertIn("sourceContext: selectionOrigin.boundedSource(additionalAnswer: answerText)", source)

    def test_summary_selection_and_nested_followups_retain_the_source(self):
        summary = read("RSSReaderApp/Views/SummaryColumnView.swift")
        self.assertIn("articleSelectionSourceContext(for: article)", summary)
        self.assertIn("appState.articleQAPrompt(", summary)
        self.assertIn("question: \"What is said about \\(trimmed)?\"", summary)
        self.assertIn("selectionOrigin: selectionAskAIOrigin", summary)

        source = read("RSSReaderApp/Views/AskAIComponents.swift")
        self.assertIn("selectionOrigin: selectionOrigin,", source)
        follow_up = re.search(
            r"private func askFollowUp\([\s\S]*?\n    \}\n\n    private func copyFollowUpResponse",
            source,
        )
        self.assertIsNotNone(follow_up)
        block = follow_up.group(0)
        self.assertIn("origin.promptSourceLabel", block)
        self.assertIn("selectionOrigin ?? AskAISelectionOrigin", block)
        self.assertIn("boundedSource(additionalAnswer: context)", block)
        self.assertIn("askQuestionAboutSelection(prompt: prompt", block)
        self.assertIn("askWebQuestionAboutSelection(\n                prompt: prompt", block)

    def test_mac_app_state_source_helpers_match_bounded_context_conventions(self):
        source = read("RSSReaderApp/Controllers/AppState.swift")
        article = re.search(
            r"func articleSelectionSourceContext\([\s\S]*?\n    \}\n\n    func redditSelectionSourceContext",
            source,
        )
        self.assertIsNotNone(article)
        self.assertIn("cleanedArticleContent(article)", article.group(0))
        self.assertIn("maxCharacters: 18_000", article.group(0))

        reddit = re.search(
            r"func redditSelectionSourceContext\([\s\S]*?\n    \}\n\n    func commentSummaryPrompt",
            source,
        )
        self.assertIsNotNone(reddit)
        self.assertIn("redditSummarySourceText(post: post, comments: comments)", reddit.group(0))
        self.assertIn("source.count > 40_000", reddit.group(0))

    def test_individual_reddit_qa_keeps_nested_comments_for_settings_and_web(self):
        source = read("RSSReaderApp/Controllers/AppState.swift")
        qa = re.search(
            r"func askQuestionAboutRedditPost\(post: RedditPost[\s\S]*?\n    func askQuestionAboutGlobalSummary",
            source,
        )
        self.assertIsNotNone(qa)
        block = qa.group(0)
        self.assertIn("settings.selectedSummaryProvider == .webAI", block)
        self.assertIn("redditFullQAPrompt(post: post, comments: comments, question: question)", block)
        self.assertIn("func askWebQuestionAboutRedditPost", source)
        self.assertIn("redditFullQAPrompt(post: post, comments: comments, question: trimmed)", source)
        self.assertIn("for reply in comment.replies", source)
        self.assertIn("extractAllCommentTexts(from: reply)", source)
        self.assertIn("fullRedditContext(post: post, comments: comments)", source)

        nested = recursive_comment_texts([
            {"author": "root", "body": "ROOT-MARKER", "replies": [
                {"author": "reply", "body": "NESTED-REPLY-MARKER", "replies": [
                    {"author": "deep", "body": "DEEP-REPLY-MARKER"}
                ]}
            ]}
        ])
        self.assertEqual(nested, [
            "u/root: ROOT-MARKER",
            "u/reply: NESTED-REPLY-MARKER",
            "u/deep: DEEP-REPLY-MARKER",
        ])

    def test_reddit_qa_treats_theme_as_grounded_synthesis_for_settings_web_and_gemini(self):
        source = read("RSSReaderApp/Controllers/AppState.swift")
        shared = re.search(
            r"private func redditFullQAPrompt[\s\S]*?\n    func redditQAPrompt",
            source,
        )
        self.assertIsNotNone(shared)
        shared_block = shared.group(0)
        self.assertIn("additionalRules", shared_block)
        self.assertIn("theme, main topic, central idea, or main argument", shared_block)
        self.assertIn("grounded synthesis requests", shared_block)
        self.assertIn('literal word \"theme\"', shared_block)

        gemini = re.search(
            r"func askQuestionAboutRedditPost\(post: RedditPost[\s\S]*?\n    // MARK: - Global Summary Q&A",
            source,
        )
        self.assertIsNotNone(gemini)
        gemini_block = gemini.group(0)
        self.assertIn("theme, main topic, central idea, or main argument", gemini_block)
        self.assertIn("grounded synthesis requests", gemini_block)
        self.assertIn('literal word \"theme\"', gemini_block)

    def test_overall_reddit_qa_caches_recursive_comments_for_settings_and_web(self):
        source = read("RSSReaderApp/Controllers/AppState.swift")
        service_start = source.index("final class GlobalSummaryService")
        service_end = source.index("class AppState", service_start)
        service_block = source[service_start:service_end]
        self.assertIn("allComments: [RedditCommentModel]", service_block)
        self.assertIn("flattenedCommentTexts(comment.replies)", service_block)
        self.assertIn("Self.flattenedCommentTexts(triple.allComments)", service_block)
        self.assertIn("depth: 10", service_block)

        web = re.search(
            r"private func summarizeRedditPostsGloballyWithWebAI[\s\S]*?\n    private func fetchTopCommentsForWebGlobalSummary",
            source,
        )
        self.assertIsNotNone(web)
        self.assertIn("comments.flatMap { self.extractAllCommentTexts(from: $0) }", web.group(0))
        self.assertIn("summaryComments", web.group(0))

        fallback = re.search(
            r"private func fetchCommentsForGlobalSummary[\s\S]*?\n    private func sanitizedSnippet",
            source,
        )
        self.assertIsNotNone(fallback)
        self.assertIn("flatMap { self.extractAllCommentTexts(from: $0) }", fallback.group(0))

        global_builder = re.search(
            r"private func buildGlobalRedditQuestionPrompt[\s\S]*?\n    private func fetchCommentsForGlobalSummary",
            source,
        )
        self.assertIsNotNone(global_builder)
        self.assertIn("Comments (including nested replies):", global_builder.group(0))

    def test_gemini_article_qa_allows_grounded_theme_synthesis_without_touching_other_media(self):
        source = read("RSSReaderApp/Controllers/AppState.swift")
        gemini = re.search(
            r"private func geminiArticleQAPrompt[\s\S]*?\n    private func articleFullQAPrompt",
            source,
        )
        self.assertIsNotNone(gemini)
        gemini_block = gemini.group(0)
        for term in ("theme", "main topic", "central idea", "main argument", "Do not invent"):
            self.assertIn(term, gemini_block)
        self.assertIn("fullArticleContext(article)", gemini_block)

        article_qa = re.search(
            r"func askQuestionAboutArticle\(article: Article[\s\S]*?\n    func askQuestionAboutRedditPost",
            source,
        )
        self.assertIsNotNone(article_qa)
        article_block = article_qa.group(0)
        self.assertIn("let prompt = geminiArticleQAPrompt(article: article, question: question)", article_block)
        self.assertIn("article.isPodcastEpisode", article_block)
        self.assertIn("askQuestionAboutPodcastEpisode", article_block)
        self.assertIn("article.isYouTubeVideo", article_block)
        self.assertIn("askQuestionAboutYouTubeVideo", article_block)

        web_article = re.search(
            r"func askWebQuestionAboutArticle\([\s\S]*?\n    func askWebQuestionAboutRedditPost",
            source,
        )
        self.assertIsNotNone(web_article)
        self.assertIn("prompt: articleFullQAPrompt(article: article, question: trimmed)", web_article.group(0))


if __name__ == "__main__":
    unittest.main()
