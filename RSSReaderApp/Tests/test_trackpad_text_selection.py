import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
VIEW = (ROOT / 'Views/ContentView.swift').read_text()
UTIL = (ROOT / 'Views/AskAIUtilities.swift').read_text()


def section(text, start, end):
    return text.split(start, 1)[1].split(end, 1)[0]


class TrackpadTextSelectionTests(unittest.TestCase):
    def test_pointer_intent_is_detected_at_press_not_selection_notification(self):
        begin = section(UTIL, 'private func beginTextTouch(', 'private func endTextTouch(')
        self.assertIn('isCurrentTextTouchPointer = touch.type == .indirectPointer', begin)
        self.assertIn('didSelectionChangeDuringCurrentTouch = selectedRange.location != NSNotFound && selectedRange.length > 0', begin)
        self.assertIn('Self.currentTextTouchView = self', begin)
        self.assertIn('self?.beginTextTouch(touch)', UTIL)

    def test_direct_touch_checks_existing_selection_and_selection_changes(self):
        gate = section(UTIL, 'static var didActiveTextTouchChangeSelection:', 'private var isTrackingCurrentTextTouch')
        self.assertIn('hasActivePointerTextInteraction', gate)
        self.assertIn('hasSelectedText', gate)
        self.assertIn('currentTextTouchView?.didSelectionChangeDuringCurrentTouch == true', gate)
        self.assertIn('guard !AskAITextView.didActiveTextTouchChangeSelection else { return }', VIEW)

    def test_pointer_gate_resets_without_altering_existing_delay(self):
        end = section(UTIL, 'private func endTextTouch(', 'func textViewDidChangeSelection(')
        self.assertIn('self.isCurrentTextTouchPointer = false', end)
        self.assertIn('Self.currentTextTouchView = nil', end)
        self.assertIn('.now() + 0.15', end)

    def test_scroll_back_never_accepts_clicks_or_direct_touches(self):
        trackpad = section(VIEW, 'class TrackpadGestureView:', '\n#endif')
        touch_filter = section(trackpad, 'shouldReceive touch: UITouch)', 'shouldReceive event: UIEvent)')
        self.assertIn('return false', touch_filter)
        self.assertNotIn('touch.type == .indirectPointer', touch_filter)
        self.assertIn('pan.allowedTouchTypes = []', trackpad)
        self.assertIn('event.type == .scroll && event.buttonMask.isEmpty', trackpad)

    def test_click_selection_blocks_trackpad_at_begin_and_during_pan(self):
        trackpad = section(VIEW, 'class TrackpadGestureView:', '\n#endif')
        self.assertIn('guard isBackSwipeEnabled, !AskAITextView.didActiveTextTouchChangeSelection else { return }', trackpad)
        self.assertIn('guard !AskAITextView.didActiveTextTouchChangeSelection else { return false }', trackpad)
        self.assertIn('return isBackSwipeEnabled', trackpad)
        self.assertIn('accumulatedX > 60', trackpad)
        self.assertIn('pan.allowedScrollTypesMask = [.continuous, .discrete]', trackpad)

    def test_selection_observer_does_not_cancel_other_gestures(self):
        observer = section(UTIL, 'private final class TextSelectionIntentGestureRecognizer:', 'final class AskAITextView:')
        self.assertIn('var onTouchBegan: ((UITouch) -> Void)?', observer)
        self.assertIn('onTouchBegan?(touch)', observer)
        self.assertIn('canPrevent(', observer)
        self.assertIn('canBePrevented(', observer)
        self.assertEqual(observer.count('\n        false\n'), 2)

    def test_live_selection_is_independent_of_touch_observer_lifetime(self):
        gate = section(UTIL, 'static var hasSelectedText:', 'static var hasActivePointerTextInteraction:')
        self.assertIn('attachedTextViews.allObjects.contains', gate)
        self.assertIn('selectedRange.length > 0', gate)
        self.assertNotIn('currentTextTouchView', gate)
        self.assertIn('NSHashTable<AskAITextView>.weakObjects()', UTIL)
        self.assertIn('Self.attachedTextViews.add(self)', UTIL)
        self.assertIn('Self.attachedTextViews.remove(self)', UTIL)
        self.assertIn('!view.isHidden, view.alpha > 0.01', gate)
        self.assertIn('intersects(window.bounds)', gate)

    def test_list_swipe_checks_selection_without_changing_list_identity(self):
        gesture = section(VIEW, 'func anywhereSwipeBack(enabled:', 'func anywhereSwipeBack(perform')
        self.assertEqual(gesture.count('guard !AskAITextView.didActiveTextTouchChangeSelection else { return }'), 2)
        self.assertIn('if enabled {', gesture)
        self.assertNotIn('if enabled &&', gesture)
        self.assertLess(gesture.index('isTracking.wrappedValue = false'), gesture.rindex('guard !AskAITextView.didActiveTextTouchChangeSelection'))


if __name__ == '__main__':
    unittest.main()
