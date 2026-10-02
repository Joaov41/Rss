"""Execute the actual selection gate with lightweight view fixtures on macOS.

These are state tests, not a substitute for physical UIKit gesture testing.
The real UIKit implementation is separately compiled by the app build.
"""
import pathlib
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]


@unittest.skipUnless(sys.platform == 'darwin' and shutil.which('swiftc'), 'requires macOS Swift')
class SelectedTextBackStateTests(unittest.TestCase):
    def test_actual_selection_gate(self):
        source = (ROOT / 'Views/AskAIUtilities.swift').read_text()
        source = source.split('final class AskAITextView:', 1)[1]
        fields = 'private static weak var currentTextTouchView:' + source.split(
            'private static weak var currentTextTouchView:', 1
        )[1].split('private var textSelectionIntentRecognizer:', 1)[0]
        lifecycle = 'override func didMoveToWindow()' + source.split(
            'override func didMoveToWindow()', 1
        )[1].split('func prepareForDisplay(', 1)[0]
        methods = 'private func beginTextTouch(' + source.split(
            'private func beginTextTouch(', 1
        )[1].split('func cachedSizeThatFits(', 1)[0]
        handler = 'private func handleAskAISelection(' + source.split(
            'private func handleAskAISelection(', 1
        )[1].split('private func installAskAIMenuItem()', 1)[0]
        fixtures = '''
import Foundation
import CoreGraphics
class UIView: NSObject {
    var window: UIView?
    var superview: UIView?
    var bounds = CGRect(x: 0, y: 0, width: 500, height: 500)
    var convertedBounds = CGRect(x: 0, y: 0, width: 100, height: 100)
    var isHidden = false
    var alpha = 1.0
    func convert(_ rect: CGRect, to: UIView) -> CGRect { convertedBounds }
    func didMoveToWindow() {}
}
class UITextView: UIView {
    var isSelectable = true
    var selectedRange = NSRange(location: 0, length: 0)
    var text = ""
    var resigned = false
    @discardableResult func resignFirstResponder() -> Bool { resigned = true; return true }
}
enum AskAISelectionAction: Equatable { case standard, web }
class UITouch {
    enum TouchType { case direct, indirectPointer }
    var type: TouchType = .direct
}
final class AskAITextView: UITextView {
    var onAskAISelection: ((AskAISelectionAction, String, String) -> Void)?
'''
        hooks = '''
    private var textSelectionGestureResetWorkItem: DispatchWorkItem?
    func installAskAIMenuItem() {}
    func installTextSelectionIntentObserver() {}
    func simulateBegin(_ touch: UITouch) { beginTextTouch(touch) }
    func simulateEnd() { endTextTouch() }
    func simulateAskAI(_ action: AskAISelectionAction) { handleAskAISelection(action: action) }
}
let window = UIView()
func makeTextView() -> AskAITextView {
    let view = AskAITextView()
    view.window = window
    view.superview = window
    view.didMoveToWindow()
    return view
}
let view = makeTextView()
precondition(!AskAITextView.didActiveTextTouchChangeSelection, "ordinary swipe must remain enabled")
view.selectedRange = NSRange(location: 2, length: 5)
precondition(AskAITextView.didActiveTextTouchChangeSelection, "existing selection with no touch callback must block Back")
// Selection handles may be outside the text view: no observer event required.
RunLoop.current.run(until: Date().addingTimeInterval(0.18))
precondition(AskAITextView.didActiveTextTouchChangeSelection, "selection must outlive touch-reset delay")
view.simulateBegin(UITouch())
view.selectedRange = NSRange(location: 0, length: 0)
precondition(AskAITextView.didActiveTextTouchChangeSelection, "selection at drag start must survive transient clearing")
view.simulateEnd()
RunLoop.current.run(until: Date().addingTimeInterval(0.18))
precondition(!AskAITextView.didActiveTextTouchChangeSelection, "deselection must restore normal Back")
view.simulateBegin(UITouch())
precondition(!AskAITextView.didActiveTextTouchChangeSelection, "ordinary direct touch must not block Back")
view.selectedRange = NSRange(location: 1, length: 3)
view.textViewDidChangeSelection(view)
precondition(AskAITextView.didActiveTextTouchChangeSelection, "new selection must block Back")
view.simulateEnd()
RunLoop.current.run(until: Date().addingTimeInterval(0.18))
precondition(AskAITextView.didActiveTextTouchChangeSelection, "new selection must persist beyond end/reset")
view.selectedRange = NSRange(location: 0, length: 0)
let pointer = UITouch()
pointer.type = .indirectPointer
view.simulateBegin(pointer)
precondition(AskAITextView.didActiveTextTouchChangeSelection, "pointer selection intent must remain protected")
view.simulateEnd()
RunLoop.current.run(until: Date().addingTimeInterval(0.18))
view.selectedRange = NSRange(location: 1, length: 3)
window.isHidden = true
precondition(!AskAITextView.didActiveTextTouchChangeSelection, "hidden selected view must not block Back")
window.isHidden = false
window.alpha = 0
precondition(!AskAITextView.didActiveTextTouchChangeSelection, "transparent selected parent must not block Back")
window.alpha = 1
view.convertedBounds.origin.x = 1000
precondition(!AskAITextView.didActiveTextTouchChangeSelection, "offscreen selected view must not block Back")
view.convertedBounds.origin.x = 0
view.window = nil
view.didMoveToWindow()
precondition(!AskAITextView.didActiveTextTouchChangeSelection, "detached selected view must not block Back")
weak var weakView: AskAITextView?
autoreleasepool {
    let temporary = makeTextView()
    temporary.selectedRange = NSRange(location: 0, length: 4)
    weakView = temporary
    precondition(AskAITextView.didActiveTextTouchChangeSelection)
}
precondition(weakView == nil, "registry must not retain views")
precondition(!AskAITextView.didActiveTextTouchChangeSelection)
let actionView = makeTextView()
actionView.text = "The song title Sliver as Silver is discussed in these comments."
for action in [AskAISelectionAction.standard, .web] {
    actionView.selectedRange = (actionView.text as NSString).range(of: "Sliver as Silver")
    actionView.resigned = false
    actionView.simulateBegin(action == .web ? pointer : UITouch())
    precondition(AskAITextView.didActiveTextTouchChangeSelection)
    var calls = 0
    actionView.onAskAISelection = { receivedAction, selected, context in
        calls += 1
        precondition(receivedAction == action)
        precondition(selected == "Sliver as Silver", "selected text must be captured before clearing")
        precondition(context == actionView.text, "context must not change")
        precondition(actionView.selectedRange.length == 0)
        precondition(actionView.resigned)
        precondition(!AskAITextView.didActiveTextTouchChangeSelection, "Back must be unblocked before presenting Ask AI")
    }
    actionView.simulateAskAI(action)
    precondition(calls == 1)
    RunLoop.current.run(until: Date().addingTimeInterval(0.18))
    precondition(!AskAITextView.didActiveTextTouchChangeSelection, "old touch cleanup must not restore the block")
}
print("PASS: selection state, handle coverage, deselection, touch/pointer and view lifecycle")
'''
        with tempfile.TemporaryDirectory(prefix='rss-selection-state-') as temp:
            path = pathlib.Path(temp)
            swift = path / 'StateCheck.swift'
            swift.write_text(fixtures + fields + lifecycle + methods + handler + hooks)
            result = subprocess.run(
                ['swiftc', '-module-cache-path', str(path / 'cache'), str(swift), '-o', str(path / 'check')],
                capture_output=True, text=True, timeout=90,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            result = subprocess.run([str(path / 'check')], capture_output=True, text=True, timeout=15)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn('PASS: selection state', result.stdout)


if __name__ == '__main__':
    unittest.main()
