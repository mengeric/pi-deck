import Foundation

// MARK: - Single-source workspace layout

// Intentionally Foundation-only (no SwiftUI) so layout math is nonisolated
// under the app target's default MainActor isolation and unit-testable.

/// Pure layout policy for the top-level workspace.
///
/// Rules (hard):
/// 1. Only fixed chrome is handle slots (and optional compact rail).
/// 2. Docked columns are fractions of the **content** budget (host − handles).
/// 3. Soft drag bands guide UX; resolve may go below soft min so widths always sum.
/// 4. Breakpoints change *mode*, never steal width via `max(minPt, …)`.
///
/// `ThreeColumnLayout` keeps its historical name for call-site stability.
/// Pure value types / math — `nonisolated` so unit tests and non-UI callers work.
nonisolated enum ThreeColumnLayout: Sendable {
    /// Defaults keys (fractions 0…1).
    nonisolated static let sidebarFractionKey = "piDeck.sidebarFraction"
    nonisolated static let reviewFractionKey = "piDeck.reviewFraction"
    /// Legacy pt keys — migrated once into fractions when host is known.
    nonisolated static let legacySidebarWidthKey = "piDeck.sidebarWidth"
    nonisolated static let legacyReviewWidthKey = "piDeck.reviewPanelWidth"

    nonisolated static let sidebarDefault: CGFloat = 0.20
    /// Soft drag band (preferred), not a hard floor that can break the sum.
    nonisolated static let sidebarMin: CGFloat = 0.12
    nonisolated static let sidebarMax: CGFloat = 0.28

    nonisolated static let reviewDefault: CGFloat = 0.36
    nonisolated static let reviewMin: CGFloat = 0.18
    nonisolated static let reviewMax: CGFloat = 0.52

    /// Preferred residual chat share when Review is **docked** in three-column mode.
    nonisolated static let chatMinFraction: CGFloat = 0.30

    /// Host width at/above which Review may dock as a third column.
    nonisolated static let threeColumnMinHost: CGFloat = 1100
    /// Host width at/above which the sidebar may remain docked (below → still
    /// docked at a soft fraction; window min is product policy).
    nonisolated static let twoColumnMinHost: CGFloat = 800

    nonisolated static let handleWidth: CGFloat = 10
    nonisolated static let handlePad: CGFloat = 6
    nonisolated static var handleSlot: CGFloat { handleWidth + handlePad * 2 }

    /// Fixed trailing activity rail width (always visible; Review body toggles beside it).
    /// ~⅔ of the previous 44pt strip so icons stay tappable without a wide dead gutter.
    nonisolated static let trailingRailWidth: CGFloat = 30

    /// Overlay Review width as a fraction of host when not docked.
    nonisolated static let overlayReviewMinFraction: CGFloat = 0.28
    nonisolated static let overlayReviewMaxFraction: CGFloat = 0.55

    nonisolated enum Mode: String, Sendable {
        /// Sidebar + chat + review share one HStack.
        case threeColumn
        /// Sidebar + chat only; review is a trailing overlay when open.
        case reviewOverlay
    }

    nonisolated struct Resolved: Sendable {
        var mode: Mode
        var sidebarWidth: CGFloat
        var chatWidth: CGFloat
        /// Docked review width (0 when overlay / closed).
        var reviewWidth: CGFloat
        var sidebarHandleWidth: CGFloat
        var reviewHandleWidth: CGFloat
        /// Overlay panel width when `mode == .reviewOverlay` and review is open.
        var overlayReviewWidth: CGFloat
    }

    nonisolated struct FittedFractions: Sendable {
        var sidebar: CGFloat
        var review: CGFloat
    }

    /// Soft band for persistence / default drag feel.
    nonisolated static func clampedSidebar(_ f: CGFloat) -> CGFloat {
        min(sidebarMax, max(sidebarMin, f))
    }

    nonisolated static func clampedReview(_ f: CGFloat) -> CGFloat {
        min(reviewMax, max(reviewMin, f))
    }

    /// Cap only (no soft min) so resolve can always make the sum fit.
    nonisolated static func cappedSidebar(_ f: CGFloat) -> CGFloat {
        min(sidebarMax, max(0, f))
    }

    nonisolated static func cappedReview(_ f: CGFloat) -> CGFloat {
        min(reviewMax, max(0, f))
    }

    nonisolated static func mode(host: CGFloat, reviewExpanded: Bool) -> Mode {
        let h = max(1, host)
        if reviewExpanded, h >= threeColumnMinHost { return .threeColumn }
        return .reviewOverlay
    }

    /// Fit stored fractions for the current host/mode.
    ///
    /// When Review is docked, scale panels so chat keeps `chatMinFraction` of
    /// the **content** budget. Soft mins are preferred but **not** re-applied
    /// after scaling (that was the steal-from-neighbor bug).
    nonisolated static func fit(
        host: CGFloat,
        sidebarVisible: Bool,
        reviewExpanded: Bool,
        sidebarFraction: CGFloat,
        reviewFraction: CGFloat
    ) -> FittedFractions {
        let m = mode(host: host, reviewExpanded: reviewExpanded)
        let dockReview = reviewExpanded && m == .threeColumn

        var side = sidebarVisible ? cappedSidebar(sidebarFraction) : 0
        var rev = dockReview ? cappedReview(reviewFraction) : cappedReview(reviewFraction)

        // Prefer soft band when there is room (drag UX), without forcing mins
        // that re-break the chat floor after a scale pass.
        if sidebarVisible {
            side = min(sidebarMax, max(sidebarMin, side))
        }
        if dockReview {
            rev = min(reviewMax, max(reviewMin, rev))
        }

        if dockReview {
            let used = (sidebarVisible ? side : 0) + rev
            let maxPanels = max(0, 1 - chatMinFraction)
            if used > maxPanels + 0.0001, used > 0 {
                let scale = maxPanels / used
                if sidebarVisible { side *= scale }
                rev *= scale
                // Cap only — do not re-apply soft min.
                if sidebarVisible { side = cappedSidebar(side) }
                rev = cappedReview(rev)
            }
        } else if sidebarVisible {
            // Overlay mode: only sidebar competes with chat in the HStack.
            let maxSide = max(0, 1 - chatMinFraction)
            side = min(side, maxSide)
            side = cappedSidebar(side)
        }

        return FittedFractions(
            sidebar: sidebarVisible ? side : clampedSidebar(sidebarFraction),
            review: rev
        )
    }

    /// Resolve absolute column widths. **Invariant:**
    /// `sidebar + sidebarHandle + chat + reviewHandle + review == host`
    /// (within 1pt float error) for docked layout; overlay width is separate.
    nonisolated static func resolved(
        host: CGFloat,
        sidebarVisible: Bool,
        reviewExpanded: Bool,
        sidebarFraction: CGFloat,
        reviewFraction: CGFloat
    ) -> Resolved {
        let h = max(1, host)
        let m = mode(host: h, reviewExpanded: reviewExpanded)
        let dockReview = reviewExpanded && m == .threeColumn

        let fitted = fit(
            host: h,
            sidebarVisible: sidebarVisible,
            reviewExpanded: reviewExpanded,
            sidebarFraction: sidebarFraction,
            reviewFraction: reviewFraction
        )

        let sideHandle: CGFloat = sidebarVisible ? handleSlot : 0
        let revHandle: CGFloat = dockReview ? handleSlot : 0
        let content = max(1, h - sideHandle - revHandle)

        let sideShare = sidebarVisible ? fitted.sidebar : 0
        let revShare = dockReview ? fitted.review : 0

        // Fractions apply to the content budget (not full host), so handles
        // never silently steal chat beyond the model.
        var sidebarW = content * sideShare
        var reviewW = content * revShare
        var chatW = content - sidebarW - reviewW

        // Final hard repair: never negative; if float noise, dump into chat.
        if chatW < 1 {
            let deficit = 1 - chatW
            let reducible = sidebarW + reviewW
            if reducible > 0 {
                let scale = max(0, (reducible - deficit) / reducible)
                sidebarW *= scale
                reviewW *= scale
            }
            chatW = max(1, content - sidebarW - reviewW)
        }

        let overlayW: CGFloat
        if reviewExpanded, m == .reviewOverlay {
            let f = min(overlayReviewMaxFraction, max(overlayReviewMinFraction, fitted.review))
            overlayW = min(h * 0.92, max(h * overlayReviewMinFraction, h * f))
        } else {
            overlayW = 0
        }

        return Resolved(
            mode: m,
            sidebarWidth: sidebarVisible ? sidebarW : 0,
            chatWidth: chatW,
            reviewWidth: dockReview ? reviewW : 0,
            sidebarHandleWidth: sideHandle,
            reviewHandleWidth: revHandle,
            overlayReviewWidth: overlayW
        )
    }

    nonisolated static func loadSidebarFraction() -> CGFloat {
        let raw = UserDefaults.standard.double(forKey: sidebarFractionKey)
        if raw > 0.01, raw < 0.99 { return clampedSidebar(CGFloat(raw)) }
        let legacy = UserDefaults.standard.double(forKey: legacySidebarWidthKey)
        if legacy > 40 {
            return clampedSidebar(CGFloat(legacy) / 1440)
        }
        return sidebarDefault
    }

    nonisolated static func loadReviewFraction() -> CGFloat {
        let raw = UserDefaults.standard.double(forKey: reviewFractionKey)
        if raw > 0.01, raw < 0.99 { return clampedReview(CGFloat(raw)) }
        let legacy = UserDefaults.standard.double(forKey: legacyReviewWidthKey)
        if legacy > 40 {
            return clampedReview(CGFloat(legacy) / 1440)
        }
        return reviewDefault
    }

    nonisolated static func saveSidebarFraction(_ f: CGFloat) {
        UserDefaults.standard.set(Double(clampedSidebar(f)), forKey: sidebarFractionKey)
    }

    nonisolated static func saveReviewFraction(_ f: CGFloat) {
        UserDefaults.standard.set(Double(clampedReview(f)), forKey: reviewFractionKey)
    }
}

