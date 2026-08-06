import AppKit
import SwiftUI

// MARK: - Public SwiftUI host

/// Top-level workspace: AppKit `NSSplitView` owns live column geometry.
///
/// Contract:
/// - Sidebar / chat / trailing strip are three arranged subviews (never removed).
/// - The trailing **activity rail is always visible** (fixed width when Review body
///   is collapsed). Expand/collapse only changes Review *body* width.
/// - Collapse of Review body uses a narrow rail width via `setPosition`, **not**
///   `isHidden` (hidden arranged subviews make NSSplitView drop panes permanently).
/// - Initial positions are applied when the split first receives a real width
///   (SwiftUI often mounts the representable at 0×0).
/// - Fractions persist via `ThreeColumnLayout`.
/// - Below `threeColumnMinHost`, the trailing strip is a SwiftUI overlay (rail
///   always; full body width when expanded).
struct ThreeColumnWorkspaceHost<Sidebar: View, Main: View, Panel: View>: View {
    var isSidebarVisible: Bool = true
    /// Whether the Review *body* is open (rail is always shown).
    var isReviewExpanded: Bool
    @Binding var sidebarFraction: CGFloat
    @Binding var reviewFraction: CGFloat
    /// Bumps only when a pane's SwiftUI *root* must be replaced (sidebar item,
    /// warning badges, panel chrome). Must NOT include transcript/streaming
    /// revisions — those update via `@ObservedObject` inside the installed roots.
    var paneRootEpoch: Int = 0
    @ViewBuilder var sidebar: () -> Sidebar
    @ViewBuilder var main: () -> Main
    @ViewBuilder var panel: () -> Panel

    @State private var hostWidth: CGFloat = 0

    private var currentHost: CGFloat {
        hostWidth > 1 ? hostWidth : 1400
    }

    /// Wide enough to dock the trailing strip as a real split pane.
    private var dockTrailingInSplit: Bool {
        currentHost >= ThreeColumnLayout.threeColumnMinHost
    }

    /// Narrow windows: trailing strip as overlay (rail always, body when expanded).
    private var showTrailingOverlay: Bool {
        !dockTrailingInSplit
    }

    var body: some View {
        ZStack(alignment: .trailing) {
            WorkspaceNSSplitRepresentable(
                isSidebarVisible: isSidebarVisible,
                isTrailingDocked: dockTrailingInSplit,
                isReviewExpanded: isReviewExpanded,
                paneRootEpoch: paneRootEpoch,
                sidebarFraction: $sidebarFraction,
                reviewFraction: $reviewFraction,
                sidebar: {
                    sidebar()
                        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                },
                main: {
                    main()
                        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                },
                panel: {
                    panel()
                        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if showTrailingOverlay {
                panel()
                    .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
                    .frame(width: overlayTrailingWidth)
                    .background(AppTheme.windowBackground)
                    .overlay(alignment: .leading) {
                        Rectangle()
                            .fill(AppTheme.hairlineStroke.opacity(0.85))
                            .frame(width: 1)
                            .allowsHitTesting(false)
                    }
                    .shadow(color: .black.opacity(isReviewExpanded ? 0.28 : 0.12), radius: isReviewExpanded ? 18 : 6, x: -4, y: 0)
                    .zIndex(40)
            }
        }
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear { hostWidth = geo.size.width }
                    .onChange(of: geo.size.width) { _, w in hostWidth = w }
            }
        )
        .onAppear {
            sidebarFraction = ThreeColumnLayout.clampedSidebar(sidebarFraction)
            reviewFraction = ThreeColumnLayout.clampedReview(reviewFraction)
        }
    }

    /// Overlay width: full review when expanded, fixed rail when collapsed.
    private var overlayTrailingWidth: CGFloat {
        guard isReviewExpanded else {
            return ThreeColumnLayout.trailingRailWidth
        }
        let h = max(1, currentHost)
        let f = min(
            ThreeColumnLayout.overlayReviewMaxFraction,
            max(ThreeColumnLayout.overlayReviewMinFraction, reviewFraction)
        )
        return min(h * 0.92, max(h * ThreeColumnLayout.overlayReviewMinFraction, h * f))
    }
}

// MARK: - Coordination

@MainActor
protocol WorkspaceSplitCoordinating: AnyObject {
    func userDidEndLiveResize()
    /// Called from `layout` when the split gains a real width for the first time
    /// (or after a large host resize).
    func splitViewBoundsDidChange(to width: CGFloat)
}

// MARK: - NSSplitView bridge

private struct WorkspaceNSSplitRepresentable<Sidebar: View, Main: View, Panel: View>: NSViewRepresentable {
    var isSidebarVisible: Bool
    /// Trailing strip docked as a split pane (wide host).
    var isTrailingDocked: Bool
    /// Review body open (false → strip is rail-only width).
    var isReviewExpanded: Bool
    var paneRootEpoch: Int
    @Binding var sidebarFraction: CGFloat
    @Binding var reviewFraction: CGFloat
    @ViewBuilder var sidebar: () -> Sidebar
    @ViewBuilder var main: () -> Main
    @ViewBuilder var panel: () -> Panel

    func makeCoordinator() -> Coordinator {
        Coordinator(sidebarFraction: $sidebarFraction, reviewFraction: $reviewFraction)
    }

    func makeNSView(context: Context) -> WorkspaceSplitView {
        let split = WorkspaceSplitView(frame: .zero)
        split.workspaceCoordinator = context.coordinator
        context.coordinator.splitView = split

        let sideHost = NSHostingView(rootView: AnyView(sidebar()))
        let mainHost = NSHostingView(rootView: AnyView(main()))
        let panelHost = NSHostingView(rootView: AnyView(panel()))

        for host in [sideHost, mainHost, panelHost] {
            // Critical: allow panes to shrink; never let content dictate column width.
            host.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            host.setContentHuggingPriority(.defaultLow, for: .horizontal)
            host.translatesAutoresizingMaskIntoConstraints = true
        }

        context.coordinator.sidebarHost = sideHost
        context.coordinator.mainHost = mainHost
        context.coordinator.panelHost = panelHost

        split.isVertical = true
        split.dividerStyle = .thin
        split.delegate = context.coordinator
        // Do not autosave AppKit positions — fractions are the source of truth.
        split.autosaveName = nil

        split.addArrangedSubview(sideHost)
        split.addArrangedSubview(mainHost)
        split.addArrangedSubview(panelHost)

        // Rails hold; chat absorbs.
        split.setHoldingPriority(NSLayoutConstraint.Priority(rawValue: 270), forSubviewAt: 0)
        split.setHoldingPriority(NSLayoutConstraint.Priority(rawValue: 1), forSubviewAt: 1)
        split.setHoldingPriority(NSLayoutConstraint.Priority(rawValue: 260), forSubviewAt: 2)

        context.coordinator.lastSidebarVisible = isSidebarVisible
        context.coordinator.lastTrailingDocked = isTrailingDocked
        context.coordinator.lastReviewExpanded = isReviewExpanded
        context.coordinator.installedPaneRootEpoch = paneRootEpoch
        // Real positions applied on first non-zero layout (see splitViewBoundsDidChange).
        return split
    }

    func updateNSView(_ nsView: WorkspaceSplitView, context: Context) {
        context.coordinator.sidebarFraction = $sidebarFraction
        context.coordinator.reviewFraction = $reviewFraction

        // CRITICAL: do not reassign `rootView` on every SwiftUI pass. Parent body
        // re-evaluates on unrelated `@Published` noise (and used to rebuild all
        // three hosting trees ~stream cadence). Data updates flow through
        // ObservedObject inside the installed roots; only replace roots when
        // `paneRootEpoch` changes (navigation / chrome).
        if context.coordinator.installedPaneRootEpoch != paneRootEpoch {
            context.coordinator.sidebarHost?.rootView = AnyView(sidebar())
            context.coordinator.mainHost?.rootView = AnyView(main())
            context.coordinator.panelHost?.rootView = AnyView(panel())
            context.coordinator.installedPaneRootEpoch = paneRootEpoch
        }

        let visChanged =
            context.coordinator.lastSidebarVisible != isSidebarVisible
            || context.coordinator.lastTrailingDocked != isTrailingDocked
            || context.coordinator.lastReviewExpanded != isReviewExpanded

        context.coordinator.lastSidebarVisible = isSidebarVisible
        context.coordinator.lastTrailingDocked = isTrailingDocked
        context.coordinator.lastReviewExpanded = isReviewExpanded

        if visChanged {
            context.coordinator.needsReapplyPositions = true
            context.coordinator.applyPositionsIfPossible(force: true)
        } else if !context.coordinator.isUserDragging {
            // External fraction edits (load on appear).
            context.coordinator.applyPositionsIfPossible(force: false)
        }
    }

    // MARK: Coordinator

    @MainActor
    final class Coordinator: NSObject, NSSplitViewDelegate, WorkspaceSplitCoordinating {
        var sidebarFraction: Binding<CGFloat>
        var reviewFraction: Binding<CGFloat>
        weak var splitView: WorkspaceSplitView?
        var sidebarHost: NSHostingView<AnyView>?
        var mainHost: NSHostingView<AnyView>?
        var panelHost: NSHostingView<AnyView>?

        var lastSidebarVisible = true
        /// Trailing strip is a docked split pane (wide host).
        var lastTrailingDocked = false
        /// Review body open (false → rail-only strip width).
        var lastReviewExpanded = false
        var isUserDragging = false
        var needsReapplyPositions = true
        /// Last `paneRootEpoch` applied to the three `NSHostingView`s.
        var installedPaneRootEpoch: Int = .min

        private var suppressFractionWrite = false
        private var lastAppliedSideF: CGFloat = -1
        private var lastAppliedRevF: CGFloat = -1
        private var lastLayoutWidth: CGFloat = 0

        init(sidebarFraction: Binding<CGFloat>, reviewFraction: Binding<CGFloat>) {
            self.sidebarFraction = sidebarFraction
            self.reviewFraction = reviewFraction
        }

        func splitViewBoundsDidChange(to width: CGFloat) {
            let grewFromZero = lastLayoutWidth < 40 && width >= 40
            let largeResize = abs(width - lastLayoutWidth) > 24
            lastLayoutWidth = width
            guard grewFromZero || largeResize || needsReapplyPositions else { return }
            // Defer out of `layout` — setPosition during layout can recurse.
            DispatchQueue.main.async { [weak self] in
                self?.applyPositionsIfPossible(force: true)
            }
        }

        func applyPositionsIfPossible(force: Bool) {
            guard let split = splitView else { return }
            let total = split.bounds.width
            guard total >= 40 else { return }

            let sideF = ThreeColumnLayout.clampedSidebar(sidebarFraction.wrappedValue)
            let revF = ThreeColumnLayout.clampedReview(reviewFraction.wrappedValue)

            if !force,
               !needsReapplyPositions,
               abs(sideF - lastAppliedSideF) < 0.002,
               abs(revF - lastAppliedRevF) < 0.002 {
                return
            }

            suppressFractionWrite = true
            defer { suppressFractionWrite = false }

            // Content budget ignores two thin dividers always present.
            let content = max(1, total - 2 * split.dividerThickness)

            var sideW: CGFloat = lastSidebarVisible ? max(160, content * sideF) : 0
            if lastSidebarVisible {
                sideW = min(sideW, content * ThreeColumnLayout.sidebarMax)
                sideW = max(sideW, content * ThreeColumnLayout.sidebarMin)
            }

            // Trailing strip always keeps at least the fixed rail width when docked.
            // Expanded Review uses the user fraction; collapsed is rail-only.
            var revW: CGFloat = 0
            if lastTrailingDocked {
                if lastReviewExpanded {
                    revW = max(280, content * revF)
                    revW = min(revW, content * ThreeColumnLayout.reviewMax)
                    revW = max(revW, content * ThreeColumnLayout.reviewMin)
                    // Ensure room for body + rail chrome.
                    revW = max(revW, ThreeColumnLayout.trailingRailWidth + 160)
                } else {
                    revW = ThreeColumnLayout.trailingRailWidth
                }
            }

            // Protect chat residual.
            let maxRails = content * (1 - ThreeColumnLayout.chatMinFraction)
            if sideW + revW > maxRails, sideW + revW > 0 {
                let scale = maxRails / (sideW + revW)
                sideW *= scale
                revW *= scale
            }

            let mainW = max(1, content - sideW - revW)

            // setPosition: distance from leading edge to the divider.
            // Divider 0 after sidebar.
            split.setPosition(sideW, ofDividerAt: 0)
            // Divider 1 after main → start of review.
            let pos1 = sideW + split.dividerThickness + mainW
            split.setPosition(pos1, ofDividerAt: 1)

            lastAppliedSideF = sideF
            lastAppliedRevF = revF
            needsReapplyPositions = false

            // Ensure hosts are visible (never leave isHidden stuck true from older builds).
            sidebarHost?.isHidden = false
            mainHost?.isHidden = false
            panelHost?.isHidden = false

            postChatWidth(final: true)
        }

        // MARK: NSSplitViewDelegate

        func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool {
            // Collapse only by our setPosition(0), not interactive double-click collapse.
            return false
        }

        func splitView(
            _ splitView: NSSplitView,
            constrainMinCoordinate proposedMinimumPosition: CGFloat,
            ofSubviewAt dividerIndex: Int
        ) -> CGFloat {
            let total = max(1, splitView.bounds.width)
            if dividerIndex == 0 {
                // Allow full collapse when sidebar hidden; soft floor when visible.
                return lastSidebarVisible ? total * 0.10 : 0
            }
            // Min main width ≈ chatMin when trailing strip is docked.
            if lastTrailingDocked {
                let side = sidebarHost?.frame.width ?? 0
                return side + total * ThreeColumnLayout.chatMinFraction * 0.5
            }
            return total - 1
        }

        func splitView(
            _ splitView: NSSplitView,
            constrainMaxCoordinate proposedMaximumPosition: CGFloat,
            ofSubviewAt dividerIndex: Int
        ) -> CGFloat {
            let total = max(1, splitView.bounds.width)
            if dividerIndex == 0 {
                return lastSidebarVisible ? total * ThreeColumnLayout.sidebarMax : 0
            }
            if lastTrailingDocked {
                if lastReviewExpanded {
                    return total - total * ThreeColumnLayout.reviewMin * 0.5
                }
                // Collapsed: lock strip to rail width (divider cannot steal chat).
                return total - ThreeColumnLayout.trailingRailWidth - splitView.dividerThickness
            }
            return total
        }

        func splitView(
            _ splitView: NSSplitView,
            shouldAdjustSizeOfSubview view: NSView
        ) -> Bool {
            // Prefer adjusting the chat pane when the host resizes.
            return view === mainHost
        }

        func splitViewWillResizeSubviews(_ notification: Notification) {
            if !isUserDragging, !suppressFractionWrite {
                isUserDragging = true
                postResizeActive(true)
            }
        }

        func splitViewDidResizeSubviews(_ notification: Notification) {
            guard let split = splitView else { return }
            if suppressFractionWrite {
                postChatWidth(final: true)
                return
            }
            writeFractionsFromSplit(split)
            postChatWidth(final: !isUserDragging)
        }

        func userDidEndLiveResize() {
            guard isUserDragging else { return }
            isUserDragging = false
            if let split = splitView {
                writeFractionsFromSplit(split)
                ThreeColumnLayout.saveSidebarFraction(sidebarFraction.wrappedValue)
                ThreeColumnLayout.saveReviewFraction(reviewFraction.wrappedValue)
            }
            postResizeActive(false)
            postChatWidth(final: true)
        }

        private func writeFractionsFromSplit(_ split: NSSplitView) {
            let total = max(1, split.bounds.width)
            let sideW = sidebarHost?.frame.width ?? 0
            let revW = panelHost?.frame.width ?? 0
            let content = max(1, total - 2 * split.dividerThickness)

            if lastSidebarVisible, sideW > 8 {
                let f = ThreeColumnLayout.clampedSidebar(sideW / content)
                if abs(f - sidebarFraction.wrappedValue) > 0.001 {
                    sidebarFraction.wrappedValue = f
                    lastAppliedSideF = f
                }
            }
            // Only persist fraction while the Review body is expanded (rail-only width is fixed).
            if lastTrailingDocked, lastReviewExpanded, revW > ThreeColumnLayout.trailingRailWidth + 40 {
                let f = ThreeColumnLayout.clampedReview(revW / content)
                if abs(f - reviewFraction.wrappedValue) > 0.001 {
                    reviewFraction.wrappedValue = f
                    lastAppliedRevF = f
                }
            }
        }

        private func postChatWidth(final: Bool) {
            let width = max(1, mainHost?.frame.width ?? 0)
            guard width > 1 else { return }
            NotificationCenter.default.post(
                name: .transcriptColumnLiveResizeWidth,
                object: nil,
                userInfo: [
                    "width": width,
                    "final": final
                ]
            )
        }

        private func postResizeActive(_ active: Bool) {
            NotificationCenter.default.post(
                name: .transcriptColumnResizeActive,
                object: nil,
                userInfo: ["active": active]
            )
        }
    }
}

// MARK: - NSSplitView subclass

final class WorkspaceSplitView: NSSplitView {
    weak var workspaceCoordinator: (any WorkspaceSplitCoordinating)?

    override var dividerThickness: CGFloat { 1 }

    override func drawDivider(in rect: NSRect) {
        NSColor(AppTheme.hairlineStroke).withAlphaComponent(0.75).setFill()
        rect.fill()
    }

    override func layout() {
        super.layout()
        workspaceCoordinator?.splitViewBoundsDidChange(to: bounds.width)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            workspaceCoordinator?.splitViewBoundsDidChange(to: bounds.width)
        }
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        workspaceCoordinator?.userDidEndLiveResize()
    }
}
