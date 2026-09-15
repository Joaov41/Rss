import pathlib
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
CONTENT_VIEW = (ROOT / "RSSReaderApp/Views/ContentView.swift").read_text()


class CompactSummaryDialogRegressionTests(unittest.TestCase):
    def test_compact_layout_uses_a_width_safe_sheet(self):
        self.assertIn("private struct CompactSummaryReliabilitySheet", CONTENT_VIEW)
        self.assertIn("compactReliabilityWarningBinding", CONTENT_VIEW)
        self.assertIn("horizontalSizeClass == .compact", CONTENT_VIEW)
        self.assertIn(".sheet(isPresented: compactReliabilityWarningBinding)", CONTENT_VIEW)
        self.assertIn(".frame(maxWidth: 520, alignment: .leading)", CONTENT_VIEW)
        self.assertGreaterEqual(
            CONTENT_VIEW.count(".fixedSize(horizontal: false, vertical: true)"),
            2,
        )

    def test_regular_layout_keeps_the_existing_system_alert(self):
        self.assertIn("regularReliabilityWarningBinding", CONTENT_VIEW)
        self.assertIn("horizontalSizeClass != .compact", CONTENT_VIEW)
        self.assertIn(
            '.alert("Less Reliable Answer", isPresented: regularReliabilityWarningBinding)',
            CONTENT_VIEW,
        )

    def test_all_existing_choices_are_still_available(self):
        self.assertGreaterEqual(CONTENT_VIEW.count('Button("Generate Overall Summary")'), 2)
        self.assertGreaterEqual(CONTENT_VIEW.count('Button("Continue with Saved Summaries")'), 2)
        self.assertGreaterEqual(CONTENT_VIEW.count('Button("Cancel", role: .cancel)'), 2)


if __name__ == "__main__":
    unittest.main()
