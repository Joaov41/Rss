"""Settings-only explanation routing; Web and individual Q&A stay unchanged."""
import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
UTILITIES = (ROOT / 'Views/AskAIUtilities.swift').read_text()
STATE = (ROOT / 'Controllers/AppState.swift').read_text()


def between(text, start, end):
    return text.split(start, 1)[1].split(end, 1)[0]


class SettingsAskAIExplanationTests(unittest.TestCase):
    def test_explanation_is_opt_in_and_grounded(self):
        builder = between(UTILITIES, 'sourceLabel: String = "Original source",', 'enum AskAISelectionAction')
        self.assertIn('explainSelection: Bool = false', builder)
        self.assertIn('if explainSelection {', builder)
        self.assertIn('Do not merely repeat or paraphrase', builder)
        self.assertIn('wordplay, contrasts, and implied relationships', builder)
        self.assertIn('Do not invent motives, background facts', builder)
        self.assertIn('No original source was captured', builder)
        self.assertIn('maxCharacters: 40_000', builder)
        self.assertIn('What is said about this selected text in the original source?', builder)

    def test_individual_summary_routes_exclude_web(self):
        for file in ['ContentView.swift', 'RedditDetailView.swift', 'SummaryColumnView.swift']:
            text = (ROOT / 'Views' / file).read_text()
            self.assertIn('explainSelection: !useWebPath && appState.settings.selectedSummaryProvider != .webAI', text)
        self.assertIn('explainSelection: !useWebAI && appState.settings.selectedSummaryProvider != .webAI', UTILITIES)

    def test_batch_selection_single_chunk_and_fallback_exclude_web(self):
        selection = between(STATE, 'func askQuestionAboutGlobalSummarySelection(', 'private func normalizedSelectionText')
        self.assertIn('explainSelection: !useWebAI && settings.selectedSummaryProvider != .webAI', selection)
        self.assertIn('source: chunks[0], useWebAI: useWebAI', selection)
        self.assertIn('if !useWebAI && settings.selectedSummaryProvider != .webAI', selection)
        self.assertIn('interpretQuestion: false', selection)

    def test_chunk_evidence_is_not_truncated_again(self):
        selection = between(STATE, 'func processChunk(_ index:', 'private func executeSelectionPrompt')
        self.assertIn('evidence.enumerated()', selection)
        self.assertIn('finalPrompt +=', selection)
        self.assertNotIn('prefix(', selection)
        self.assertNotIn('buildAskAISelectionPrompt(', selection)
        self.assertIn('NO RELEVANT EVIDENCE', selection)

    def test_batch_qa_guidance_is_settings_only(self):
        execution = between(STATE, 'private func executeGlobalQAPrompt(', 'private func buildGlobalArticlesQuestionPrompt')
        self.assertIn('interpretQuestion && settings.selectedSummaryProvider != .webAI', execution)
        self.assertIn('buildSettingsBatchQAPrompt(prompt)', execution)
        self.assertIn('appleRequestType: .globalSummaryQA, isQA: true', execution)
        self.assertIn('answerQuestion(prompt, context: "", completion: cleanedCompletion)', execution)
        self.assertNotIn('performMLXLocalSummary(', execution)
        self.assertIn('grounded synthesis', UTILITIES)
        self.assertIn("Answer the user's actual question directly", UTILITIES)

    def test_working_individual_qa_not_using_new_batch_guidance(self):
        individual = between(STATE, 'func askQuestionAboutArticle(article:', 'func askQuestionAboutGlobalSummary(question:')
        self.assertNotIn('buildSettingsBatchQAPrompt', individual)
        self.assertNotIn('explainSelection', individual)
        self.assertIn('geminiArticleQAPrompt(article: article, question: question)', individual)
        self.assertIn('geminiRedditQAPrompt(post: post, comments: comments, question: question)', individual)


if __name__ == '__main__':
    unittest.main()
