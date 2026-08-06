import AppKit
import SwiftUI

// MARK: - Public SwiftUI host

/// Top-level workspace: **AppKit `NSSplitView` owns live column geometry**.
///
/// Replaces the hand-rolled SwiftUI `HStack` + `DragGesture` host:
/// - System split keeps panes painted while the sash moves (no black overlays).
/// - Holding priorities + thickness constraints replace hard min-width fights.
/// - SwiftUI children only fill their pane; they never assign absolute column widths.
///
/// Fractions still load/save via `ThreeColumnLayout`. Narrow hosts open Review as
/// a trailing overlay instead of a third split pane.
struct ThreeColumnWorkspaceHost<Sidebar: View, Main: View, Panel: View>: View {
    var isSidebarVisible: Bool = true
    var isReviewExpanded: Bool
    @Binding var sidebarFraction: CGFloat
    @Binding var reviewFraction: CGFloat
    @ViewBuilder var sidebar: () -> Sidebar
    @ViewBuilder var main: () -> Main
    @ViewBuilder var panel: () -> Panel

    @State private var hostWidth: CGFloat = 0

    private var currentHost: CGFloat {
        hostWidth > 1 ? hostWidth : 1400
    }

    private var dockReviewInSplit: Bool {
        isReviewExpanded && currentHost >= ThreeColumnLayout.threeColumnMinHost
    }

    private var showReviewOverlay: Bool {
        isReviewExpanded && !dockReviewInSplit
    }

    var body: some View {
        ZStack(alignment: .trailing) {
            WorkspaceNSSplitRepresentable(
                isSidebarVisible: isSidebarVisible,
                isReviewDocked: dockReviewInSplit,
                sidebarFraction: $sidebarFraction,
                reviewFraction: $reviewFraction,
                sidebar: { sidebar().frame(maxWidth: .infinity, maxHeight: .infinity) },
                main: { main().frame(maxWidth: .infinity, maxHeight: .infinity) },
                panel: { panel().frame(maxWidth: .infinity, maxHeight: .infinity) }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if showReviewOverlay {
                panel()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .frame(width: overlayReviewWidth)
                    .background(AppTheme.windowBackground)
                    .overlay(alignment: .leading) {
                        Rectangle()
                            .fill(AppTheme.hairlineStroke.opacity(0.85))
                            .frame(width: 1)
                            .allowsHitTesting(false)
                    }
                    .shadow(color: .black.opacity(0.28), radius: 18, x: -4, y: 0)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
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
        .onChange(of: isReviewExpanded) { _, _ in
            postChatWidthFromFractions(final: true)
        }
        .onChange(of: isSidebarVisible) { _, _ in
            postChatWidthFromFractions(final: true)
        }
        .onChange(of: hostWidth) { _, _ in
            postChatWidthFromFractions(final: true)
        }
        .onAppear {
            sidebarFraction = ThreeColumnLayout.clampedSidebar(sidebarFraction)
            reviewFraction = ThreeColumnLayout.clampedReview(reviewFraction)
            postChatWidthFromFractions(final: true)
        }
    }

    private var overlayReviewWidth: CGFloat {
        let h = max(1, currentHost)
        let f = min(
            ThreeColumnLayout.overlayReviewMaxFraction,
            max(ThreeColumnLayout.overlayReviewMinFraction, reviewFraction)
        )
        return min(h * 0.92, max(h * ThreeColumnLayout.overlayReviewMinFraction, h * f))
    }

    private func postChatWidthFromFractions(final: Bool) {
        let r = ThreeColumnLayout.resolved(
            host: currentHost,
            sidebarVisible: isSidebarVisible,
            reviewExpanded: isReviewExpanded,
            sidebarFraction: sidebarFraction,
            reviewFraction: reviewFraction
        )
        NotificationCenter.default.post(
            name: .transcriptColumnLiveResizeWidth,
            object: nil,
            userInfo: [
                "width": max(1, r.chatWidth),
                "final": final
            ]
        )
    }
}

// MARK: - Split coordination protocol

@MainActor
protocol WorkspaceSplitCoordinating: AnyObject {
    func userDidEndLiveResize()
}

// MARK: - NSSplitView bridge

private struct WorkspaceNSSplitRepresentable<Sidebar: View, Main: View, Panel: View>: NSViewRepresentable {
    var isSidebarVisible: Bool
    var isReviewDocked: Bool
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
            host.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            host.setContentHuggingPriority(.defaultLow, for: .horizontal)
        }

        context.coordinator.sidebarHost = sideHost
        context.coordinator.mainHost = mainHost
        context.coordinator.panelHost = panelHost

        split.isVertical = true
        split.dividerStyle = .thin
        split.delegate = context.coordinator

        split.addArrangedSubview(sideHost)
        split.addArrangedSubview(mainHost)
        split.addArrangedSubview(panelHost)

        // Chat is flexible; rails prefer their thickness.
        split.setHoldingPriority(NSLayoutConstraint.Priority(rawValue: 260), forSubviewAt: 0)
        split.setHoldingPriority(NSLayoutConstraint.Priority(rawValue: 1), forSubviewAt: 1)
        split.setHoldingPriority(NSLayoutConstraint.Priority(rawValue: 250), forSubviewAt: 2)

        context.coordinator.applyVisibility(
            sidebarVisible: isSidebarVisible,
            reviewDocked: isReviewDocked,
            animated: false
        )
        context.coordinator.applyFractionsFromBindings(force: true)
        return split
    }

    func updateNSView(_ nsView: WorkspaceSplitView, context: Context) {
        context.coordinator.sidebarFraction = $sidebarFraction
        context.coordinator.reviewFraction = $reviewFraction

        context.coordinator.sidebarHost?.rootView = AnyView(sidebar())
        context.coordinator.mainHost?.rootView = AnyView(main())
        context.coordinator.panelHost?.rootView = AnyView(panel())

        let visChanged =
            context.coordinator.lastSidebarVisible != isSidebarVisible
            || context.coordinator.lastReviewDocked != isReviewDocked

        if visChanged {
            context.coordinator.applyVisibility(
                sidebarVisible: isSidebarVisible,
                reviewDocked: isReviewDocked,
                animated: true
            )
            context.coordinator.applyFractionsFromBindings(force: true)
        } else if !context.coordinator.isUserDragging {
            context.coordinator.applyFractionsFromBindings(force: false)
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
        var lastReviewDocked = false
        var isUserDragging = false
        private var suppressFractionWrite = false
        private var lastAppliedSideF: CGFloat = -1
        private var lastAppliedRevF: CGFloat = -1

        init(sidebarFraction: Binding<CGFloat>, reviewFraction: Binding<CGFloat>) {
            self.sidebarFraction = sidebarFraction
            self.reviewFraction = reviewFraction
        }

        func applyVisibility(sidebarVisible: Bool, reviewDocked: Bool, animated: Bool) {
            lastSidebarVisible = sidebarVisible
            lastReviewDocked = reviewDocked
            guard let split = splitView else { return }

            let apply = {
                split.isSidebarCollapsed = !sidebarVisible
                split.isReviewCollapsed = !reviewDocked
                self.sidebarHost?.isHidden = !sidebarVisible
                self.panelHost?.isHidden = !reviewDocked
                split.needsLayout = true
                split.layoutSubtreeIfNeeded()
            }
            if animated {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.18
                    ctx.allowsImplicitAnimation = true
                    apply()
                }
            } else {
                apply()
            }
            postResizeActive(false)
            postChatWidth(final: true)
        }

        func applyFractionsFromBindings(force: Bool) {
            guard let split = splitView else { return }
            let total = split.bounds.width
            guard total > 40 else { return }

            let sideF = ThreeColumnLayout.clampedSidebar(sidebarFraction.wrappedValue)
            let revF = ThreeColumnLayout.clampedReview(reviewFraction.wrappedValue)

            if !force,
               abs(sideF - lastAppliedSideF) < 0.002,
               abs(revF - lastAppliedRevF) < 0.002 {
                return
            }

            suppressFractionWrite = true
            defer { suppressFractionWrite = false }

            let dividerCount =
                (lastSidebarVisible ? 1 : 0) + (lastReviewDocked ? 1 : 0)
            let content = max(1, total - CGFloat(dividerCount) * split.dividerThickness)

            var sideW: CGFloat = lastSidebarVisible ? content * sideF : 0
            var revW: CGFloat = lastReviewDocked ? content * revF : 0
            if lastSidebarVisible && lastReviewDocked {
                let maxRails = content * (1 - ThreeColumnLayout.chatMinFraction)
                let used = sideW + revW
                if used > maxRails, used > 0 {
                    let scale = maxRails / used
                    sideW *= scale
                    revW *= scale
                }
            } else if lastSidebarVisible {
                sideW = min(sideW, content * (1 - ThreeColumnLayout.chatMinFraction))
            }
            let mainW = max(1, content - sideW - revW)

            // Divider 0 sits after sidebar.
            split.setPosition(lastSidebarVisible ? sideW : 0, ofDividerAt: 0)
            // Divider 1 sits after main (before review).
            let pos1: CGFloat
            if lastReviewDocked {
                pos1 = (lastSidebarVisible ? sideW + split.dividerThickness : 0) + mainW
            } else {
                pos1 = total
            }
            if split.arrangedSubviews.count > 2 {
                split.setPosition(pos1, ofDividerAt: 1)
            }

            lastAppliedSideF = sideF
            lastAppliedRevF = revF
            if force {
                postChatWidth(final: true)
            }
        }

        func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool {
            subview === sidebarHost || subview === panelHost
        }

        func splitView(
            _ splitView: NSSplitView,
            constrainMinCoordinate proposedMinimumPosition: CGFloat,
            ofSubviewAt dividerIndex: Int
        ) -> CGFloat {
            let total = max(1, splitView.bounds.width)
            if dividerIndex == 0 {
                return lastSidebarVisible ? total * 0.08 : 0
            }
            // Main must keep some room; review max ≈ 52%.
            return lastReviewDocked ? total * (1 - ThreeColumnLayout.reviewMax) : proposedMinimumPosition
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
            // Review min soft floor when docked.
            return lastReviewDocked
                ? total * (1 - ThreeColumnLayout.reviewMin * 0.45)
                : proposedMaximumPosition
        }

        func splitViewWillResizeSubviews(_ notification: Notification) {
            if !isUserDragging {
                isUserDragging = true
                postResizeActive(true)
            }
        }

        func splitViewDidResizeSubviews(_ notification: Notification) {
            guard let split = splitView, !suppressFractionWrite else {
                postChatWidth(final: !isUserDragging)
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
            let sideW = (sidebarHost?.isHidden == true) ? 0 : (sidebarHost?.frame.width ?? 0)
            let revW = (panelHost?.isHidden == true) ? 0 : (panelHost?.frame.width ?? 0)
            let dividers = CGFloat(max(0, split.arrangedSubviews.count - 1)) * split.dividerThickness
            let content = max(1, total - dividers)

            if lastSidebarVisible, sideW > 1 {
                let f = ThreeColumnLayout.clampedSidebar(sideW / content)
                if abs(f - sidebarFraction.wrappedValue) > 0.001 {
                    sidebarFraction.wrappedValue = f
                    lastAppliedSideF = f
                }
            }
            if lastReviewDocked, revW > 1 {
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

/// Thin hairline dividers + live-resize end detection.
final class WorkspaceSplitView: NSSplitView {
    weak var workspaceCoordinator: (any WorkspaceSplitCoordinating)?

    var isSidebarCollapsed = false
    var isReviewCollapsed = true

    override var dividerThickness: CGFloat { 1 }

    override func drawDivider(in rect: NSRect) {
        let color = NSColor(AppTheme.hairlineStroke).withAlphaComponent(0.7)
        color.setFill()
        rect.fill()
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        // Divider tracking is synchronous; when mouseDown returns, drag ended.
        workspaceCoordinator?.userDidEndLiveResize()
    }
}
