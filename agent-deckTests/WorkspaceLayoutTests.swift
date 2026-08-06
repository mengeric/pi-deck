import XCTest
@testable import agent_deck

/// Pure-layout contract for the single-source three-column workspace.
///
/// Invariants under test:
/// - Docked column widths + handles sum to host (within 1pt)
/// - No negative widths
/// - Review docks only when host ≥ threeColumnMinHost and review is open
/// - Soft band mins never re-break the sum after a scale pass
final class WorkspaceLayoutTests: XCTestCase {

    /// Verifies docked three-column widths plus handles fill the host.
    func testThreeColumnWidthsSumToHost() {
        let host: CGFloat = 1440
        let r = ThreeColumnLayout.resolved(
            host: host,
            sidebarVisible: true,
            reviewExpanded: true,
            sidebarFraction: 0.20,
            reviewFraction: 0.36
        )
        XCTAssertEqual(r.mode, .threeColumn)
        let sum = r.sidebarWidth + r.sidebarHandleWidth + r.chatWidth + r.reviewHandleWidth + r.reviewWidth
        XCTAssertEqual(sum, host, accuracy: 1.0)
        XCTAssertGreaterThan(r.sidebarWidth, 0)
        XCTAssertGreaterThan(r.chatWidth, 0)
        XCTAssertGreaterThan(r.reviewWidth, 0)
        XCTAssertEqual(r.overlayReviewWidth, 0, accuracy: 0.01)
    }

    /// Verifies Review becomes overlay below the three-column breakpoint so chat is not stolen.
    func testReviewOverlayModeBelowBreakpoint() {
        let host: CGFloat = 1000
        let r = ThreeColumnLayout.resolved(
            host: host,
            sidebarVisible: true,
            reviewExpanded: true,
            sidebarFraction: 0.22,
            reviewFraction: 0.40
        )
        XCTAssertEqual(r.mode, .reviewOverlay)
        XCTAssertEqual(r.reviewWidth, 0, accuracy: 0.01)
        XCTAssertEqual(r.reviewHandleWidth, 0, accuracy: 0.01)
        XCTAssertGreaterThan(r.overlayReviewWidth, 0)
        let docked = r.sidebarWidth + r.sidebarHandleWidth + r.chatWidth
        XCTAssertEqual(docked, host, accuracy: 1.0)
    }

    /// Verifies aggressive fractions scale without re-applying soft min floors that steal chat.
    func testFitDoesNotReapplySoftMinAfterScale() {
        let fitted = ThreeColumnLayout.fit(
            host: 1200,
            sidebarVisible: true,
            reviewExpanded: true,
            sidebarFraction: 0.28,
            reviewFraction: 0.52
        )
        // Max panels share = 1 − chatMinFraction (0.70); 0.28+0.52=0.80 must scale down.
        let maxPanels = 1 - ThreeColumnLayout.chatMinFraction
        XCTAssertLessThanOrEqual(fitted.sidebar + fitted.review, maxPanels + 0.001)
        let r = ThreeColumnLayout.resolved(
            host: 1200,
            sidebarVisible: true,
            reviewExpanded: true,
            sidebarFraction: fitted.sidebar,
            reviewFraction: fitted.review
        )
        let content = 1200 - r.sidebarHandleWidth - r.reviewHandleWidth
        XCTAssertGreaterThanOrEqual(r.chatWidth / content, ThreeColumnLayout.chatMinFraction - 0.02)
    }

    /// Verifies hidden sidebar yields full residual chat (plus no handles).
    func testHiddenSidebarGivesChatResidual() {
        let host: CGFloat = 1200
        let r = ThreeColumnLayout.resolved(
            host: host,
            sidebarVisible: false,
            reviewExpanded: false,
            sidebarFraction: 0.20,
            reviewFraction: 0.36
        )
        XCTAssertEqual(r.sidebarWidth, 0, accuracy: 0.01)
        XCTAssertEqual(r.sidebarHandleWidth, 0, accuracy: 0.01)
        XCTAssertEqual(r.chatWidth, host, accuracy: 1.0)
    }

    /// Verifies closed review on a wide host still uses overlay mode classification
    /// when review is not expanded (docked width zero).
    func testClosedReviewOnWideHost() {
        let host: CGFloat = 1600
        let r = ThreeColumnLayout.resolved(
            host: host,
            sidebarVisible: true,
            reviewExpanded: false,
            sidebarFraction: 0.20,
            reviewFraction: 0.36
        )
        XCTAssertEqual(r.mode, .reviewOverlay)
        XCTAssertEqual(r.reviewWidth, 0, accuracy: 0.01)
        XCTAssertEqual(r.overlayReviewWidth, 0, accuracy: 0.01)
        let sum = r.sidebarWidth + r.sidebarHandleWidth + r.chatWidth
        XCTAssertEqual(sum, host, accuracy: 1.0)
    }
}
