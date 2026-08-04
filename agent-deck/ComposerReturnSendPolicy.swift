import Foundation

/// Pure policy for composer plain-Return → send vs swallow after IME.
///
/// Extracted from `DropSafeNSTextView` so unit tests can cover the “need Enter
/// twice” regressions without driving AppKit key events.
///
/// ## Rules
/// 1. While IME has marked text, Return confirms the candidate (not send) — handled in the view.
/// 2. When composition ends **on Return**, arm a short duplicate-Return shield.
/// 3. Composition ending via Space / number / `unmarkText` does **not** arm the shield.
/// 4. Before send, the live editor string must be flushed into the SwiftUI binding
///    (Return does not fire `textDidChange`).
nonisolated enum ComposerReturnSendPolicy {
    /// Window after Return-to-confirm during which a second Return is treated as IME noise.
    nonisolated static let duplicateReturnGuard: TimeInterval = 0.06

    /// Legacy long window that incorrectly blocked intentional send (regression guard).
    ///
    /// Kept only for tests documenting why 0.28s was wrong.
    nonisolated static let legacyOverbroadReturnGuard: TimeInterval = 0.28

    /// Whether a plain Return should be swallowed instead of sending.
    ///
    /// - Parameters:
    ///   - now: Current `ProcessInfo.processInfo.systemUptime` (or test clock).
    ///   - swallowUntilUptime: Deadline armed by `armedSwallowDeadline`; `0` means inactive.
    /// - Returns: `true` when this Return is a duplicate after IME confirm.
    nonisolated static func shouldSwallowPlainReturn(
        now: TimeInterval,
        swallowUntilUptime: TimeInterval
    ) -> Bool {
        guard swallowUntilUptime > 0 else { return false }
        return now < swallowUntilUptime
    }

    /// Computes the swallow deadline after IME composition ends.
    ///
    /// - Parameters:
    ///   - compositionEnded: Whether marked text just cleared.
    ///   - endedOnPlainReturn: Whether the ending key was plain Return (candidate confirm).
    ///   - now: Current uptime.
    /// - Returns: New `swallowUntilUptime` value (`0` = do not arm).
    nonisolated static func armedSwallowDeadline(
        compositionEnded: Bool,
        endedOnPlainReturn: Bool,
        now: TimeInterval
    ) -> TimeInterval {
        guard compositionEnded, endedOnPlainReturn else { return 0 }
        return now + duplicateReturnGuard
    }

    /// Whether `unmarkText` / non-Return composition end should arm the shield.
    ///
    /// - Returns: Always `false` — arming on every unmark forced a second Enter to send.
    nonisolated static func shouldArmSwallowOnUnmarkText() -> Bool {
        false
    }

    /// Binding text to use for send after flushing the AppKit editor.
    ///
    /// - Parameters:
    ///   - bindingText: Current SwiftUI `@Binding` value (may be stale).
    ///   - editorText: Live `NSTextView.string`.
    /// - Returns: Text that `sendComposerMessage` should observe.
    nonisolated static func textForSend(bindingText: String, editorText: String) -> String {
        editorText
    }

    /// Whether the binding needs an update before send.
    ///
    /// - Parameters:
    ///   - bindingText: SwiftUI binding.
    ///   - editorText: Live editor string.
    /// - Returns: `true` when `syncComposerText` must write the editor string.
    nonisolated static func needsSyncBeforeSend(bindingText: String, editorText: String) -> Bool {
        bindingText != editorText
    }
}
