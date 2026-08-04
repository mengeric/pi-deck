import XCTest
@testable import agent_deck

/// Unit tests for composer plain-Return / IME duplicate-Return policy.
///
/// Guards the regression where a 280ms blanket swallow after any composition
/// forced users to press Enter twice to send.
final class ComposerReturnSendPolicyTests: XCTestCase {

    // MARK: - Guard window size

    /// Duplicate-Return shield stays short (IME burst only), not the legacy 280ms.
    func testDuplicateReturnGuardIsTightNotLegacy() {
        XCTAssertEqual(ComposerReturnSendPolicy.duplicateReturnGuard, 0.06, accuracy: 0.000_1)
        XCTAssertLessThan(
            ComposerReturnSendPolicy.duplicateReturnGuard,
            ComposerReturnSendPolicy.legacyOverbroadReturnGuard
        )
        XCTAssertEqual(ComposerReturnSendPolicy.legacyOverbroadReturnGuard, 0.28, accuracy: 0.000_1)
    }

    // MARK: - Arming

    /// Return that ends IME composition arms a short swallow deadline.
    func testArmSwallowWhenCompositionEndsOnReturn() {
        let now: TimeInterval = 100
        let deadline = ComposerReturnSendPolicy.armedSwallowDeadline(
            compositionEnded: true,
            endedOnPlainReturn: true,
            now: now
        )
        XCTAssertEqual(deadline, now + ComposerReturnSendPolicy.duplicateReturnGuard, accuracy: 0.000_1)
    }

    /// Space / number / letter commit does not arm the shield.
    func testNoArmWhenCompositionEndsWithoutReturn() {
        let deadline = ComposerReturnSendPolicy.armedSwallowDeadline(
            compositionEnded: true,
            endedOnPlainReturn: false,
            now: 50
        )
        XCTAssertEqual(deadline, 0)
    }

    /// No arm when composition did not end.
    func testNoArmWhenStillComposing() {
        let deadline = ComposerReturnSendPolicy.armedSwallowDeadline(
            compositionEnded: false,
            endedOnPlainReturn: true,
            now: 50
        )
        XCTAssertEqual(deadline, 0)
    }

    /// `unmarkText` must never arm swallow (regression: second Enter required).
    func testUnmarkTextDoesNotArmSwallow() {
        XCTAssertFalse(ComposerReturnSendPolicy.shouldArmSwallowOnUnmarkText())
    }

    // MARK: - Swallow decision

    /// Within the armed window, plain Return is swallowed once.
    func testSwallowWhileInsideArmedWindow() {
        let now: TimeInterval = 10
        let until = now + ComposerReturnSendPolicy.duplicateReturnGuard
        XCTAssertTrue(
            ComposerReturnSendPolicy.shouldSwallowPlainReturn(now: now + 0.01, swallowUntilUptime: until)
        )
        XCTAssertTrue(
            ComposerReturnSendPolicy.shouldSwallowPlainReturn(now: now + 0.059, swallowUntilUptime: until)
        )
    }

    /// After the window expires, Return sends (no second-Enter tax).
    func testNoSwallowAfterWindowExpires() {
        let now: TimeInterval = 10
        let until = now + ComposerReturnSendPolicy.duplicateReturnGuard
        XCTAssertFalse(
            ComposerReturnSendPolicy.shouldSwallowPlainReturn(
                now: now + ComposerReturnSendPolicy.duplicateReturnGuard,
                swallowUntilUptime: until
            )
        )
        XCTAssertFalse(
            ComposerReturnSendPolicy.shouldSwallowPlainReturn(now: now + 0.2, swallowUntilUptime: until)
        )
    }

    /// Inactive deadline (`0`) never swallows.
    func testNoSwallowWhenDeadlineInactive() {
        XCTAssertFalse(ComposerReturnSendPolicy.shouldSwallowPlainReturn(now: 999, swallowUntilUptime: 0))
    }

    /// Legacy 280ms window would still block intentional send — document the bug.
    func testLegacyWindowWouldStillBlockIntentionalSend() {
        let confirmAt: TimeInterval = 0
        let intentionalSendAt: TimeInterval = 0.15 // typical gap after IME confirm
        let legacyUntil = confirmAt + ComposerReturnSendPolicy.legacyOverbroadReturnGuard
        let tightUntil = confirmAt + ComposerReturnSendPolicy.duplicateReturnGuard

        XCTAssertTrue(
            ComposerReturnSendPolicy.shouldSwallowPlainReturn(now: intentionalSendAt, swallowUntilUptime: legacyUntil),
            "Legacy 280ms guard incorrectly blocks send at 150ms"
        )
        XCTAssertFalse(
            ComposerReturnSendPolicy.shouldSwallowPlainReturn(now: intentionalSendAt, swallowUntilUptime: tightUntil),
            "Tight 60ms guard must allow intentional send at 150ms"
        )
    }

    // MARK: - Pre-send text flush

    /// Send always prefers the live editor string.
    func testTextForSendUsesEditorNotStaleBinding() {
        let binding = ""
        let editor = "hello world"
        XCTAssertEqual(
            ComposerReturnSendPolicy.textForSend(bindingText: binding, editorText: editor),
            editor
        )
        XCTAssertEqual(
            ComposerReturnSendPolicy.textForSend(bindingText: "stale", editorText: "fresh"),
            "fresh"
        )
    }

    /// Sync is required when binding lags the editor.
    func testNeedsSyncWhenBindingStale() {
        XCTAssertTrue(
            ComposerReturnSendPolicy.needsSyncBeforeSend(bindingText: "", editorText: "typed")
        )
        XCTAssertTrue(
            ComposerReturnSendPolicy.needsSyncBeforeSend(bindingText: "old", editorText: "new")
        )
        XCTAssertFalse(
            ComposerReturnSendPolicy.needsSyncBeforeSend(bindingText: "same", editorText: "same")
        )
    }

    /// End-to-end scenario: Return-confirm → quick duplicate swallow → later send OK.
    func testScenarioReturnConfirmThenSend() {
        let t0: TimeInterval = 1_000
        let deadline = ComposerReturnSendPolicy.armedSwallowDeadline(
            compositionEnded: true,
            endedOnPlainReturn: true,
            now: t0
        )

        // IME injects a second Return 20ms later — swallow.
        XCTAssertTrue(
            ComposerReturnSendPolicy.shouldSwallowPlainReturn(now: t0 + 0.02, swallowUntilUptime: deadline)
        )

        // User presses Enter 100ms later to send — must not swallow.
        XCTAssertFalse(
            ComposerReturnSendPolicy.shouldSwallowPlainReturn(now: t0 + 0.10, swallowUntilUptime: deadline)
        )

        // Binding empty, editor has message — flush before send.
        let binding = ""
        let editor = "继续实现"
        XCTAssertTrue(ComposerReturnSendPolicy.needsSyncBeforeSend(bindingText: binding, editorText: editor))
        XCTAssertEqual(
            ComposerReturnSendPolicy.textForSend(bindingText: binding, editorText: editor),
            "继续实现"
        )
    }

    /// Space-commit then Enter sends immediately (no armed window).
    func testScenarioSpaceCommitThenEnterSends() {
        let t0: TimeInterval = 50
        let deadline = ComposerReturnSendPolicy.armedSwallowDeadline(
            compositionEnded: true,
            endedOnPlainReturn: false,
            now: t0
        )
        XCTAssertEqual(deadline, 0)
        XCTAssertFalse(
            ComposerReturnSendPolicy.shouldSwallowPlainReturn(now: t0 + 0.01, swallowUntilUptime: deadline)
        )
    }
}
