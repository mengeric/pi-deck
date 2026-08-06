import AppKit
import Combine
import SwiftUI

// MARK: - Active session column layout

extension PiAgentScreen {
    var activeSessionPaneBoundary: some View {
        // Width is imposed by the parent percentage split — do not demand a
        // fixed minWidth here (that used to overflow when Review maximized).
        Color.clear
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .overlay(alignment: .topLeading) {
                activeSessionColumn
            }
            .clipped()
    }

    /// Drag handle between sessions rail and transcript (adjusts % fraction).
    ///
    /// - Parameter totalWidth: Full chat-column width used to convert dx → Δfraction.
    @ViewBuilder
    func sessionsSplitHandle(totalWidth: CGFloat) -> some View {
        ZStack {
            Rectangle().fill(Color.clear)
            RoundedRectangle(cornerRadius: 1, style: .continuous)
                .fill(AppTheme.hairlineStroke.opacity(sessionsFractionDragOrigin != nil ? 0.95 : 0.55))
                .frame(width: 1)
        }
        .contentShape(Rectangle())
        .onHover { hovering in
            if hovering || sessionsFractionDragOrigin != nil {
                NSCursor.resizeLeftRight.set()
            } else {
                NSCursor.arrow.set()
            }
        }
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .local)
                .onChanged { value in
                    if sessionsFractionDragOrigin == nil {
                        sessionsFractionDragOrigin = sessionsColumnFraction
                    }
                    let origin = sessionsFractionDragOrigin ?? sessionsColumnFraction
                    let span = max(1, totalWidth)
                    let next = origin + (value.translation.width / span)
                    sessionsColumnFraction = PiAgentSessionsSplit.clamped(next)
                }
                .onEnded { _ in
                    sessionsFractionDragOrigin = nil
                    NSCursor.arrow.set()
                    PiAgentSessionsSplit.saveFraction(sessionsColumnFraction)
                }
        )
        .accessibilityLabel("Resize sessions column")
    }
}

// MARK: - Sessions | transcript percentage split

/// Percentage-based width policy for the in-chat sessions rail.
///
/// All sizes are fractions of the chat column (0…1), not fixed points, so Review
/// maximize / window resize never leaves a fixed-width rail overflowing.
enum PiAgentSessionsSplit {
    /// Defaults key for the user-adjusted sessions fraction.
    static let defaultsKey = "piDeck.sessionsColumnFraction"
    /// Default share of chat width for the sessions list (~28%).
    static let defaultFraction: CGFloat = 0.28
    /// Narrowest sessions share (still usable labels).
    static let minFraction: CGFloat = 0.18
    /// Widest sessions share before transcript becomes cramped.
    static let maxFraction: CGFloat = 0.38
    /// Drag handle width in points (fixed chrome, not a % of content).
    static let handleWidth: CGFloat = 8

    /// Clamps a raw fraction into the allowed band.
    ///
    /// - Parameter value: Proposed sessions width fraction of the chat column.
    /// - Returns: Fraction in `[minFraction, maxFraction]`.
    /// - Throws: Never.
    static func clamped(_ value: CGFloat) -> CGFloat {
        min(maxFraction, max(minFraction, value))
    }

    /// Loads the persisted fraction, or the default if unset / invalid.
    ///
    /// - Returns: Clamped sessions width fraction.
    /// - Throws: Never.
    static func loadFraction() -> CGFloat {
        let raw = UserDefaults.standard.double(forKey: defaultsKey)
        guard raw > 0.01, raw < 0.99 else { return defaultFraction }
        return clamped(CGFloat(raw))
    }

    /// Persists the sessions width fraction.
    ///
    /// - Parameter value: Fraction to store (will be clamped).
    /// - Throws: Never.
    static func saveFraction(_ value: CGFloat) {
        UserDefaults.standard.set(Double(clamped(value)), forKey: defaultsKey)
    }
}

extension PiAgentScreen {
    var activeSessionColumn: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .bottomTrailing) {
                transcript
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.horizontal, TranscriptFloatingControlGeometry.transcriptHorizontalPadding)
                    // Suppress the edge-fade `.mask` while a splitter drag is
                    // active: its gradient smears into a full-column blur mask
                    // until the table re-lays out to the settled width.
                    .transcriptEdgeFade(enabled: !isColumnResizing)

                // NOTE: the old opaque "settle cover" (spinner shown over the
                // transcript on every session switch) is gone. The switch is now
                // correct on its first frame — the coordinator holds the previous
                // transcript until the new one is decoded, then measures the
                // visible rows synchronously before pinning — so hiding the table
                // behind a spinner only ADDED a flash of loading state per click.

                // Sits ON TOP of the edge fade (added after it) so the pill
                // itself is never faded out. Isolated in its own view that observes
                // `transcriptPinnedState` so toggling the pill never re-evaluates this
                // screen's body (and never re-runs the transcript items build).
                JumpToLatestOverlay(pinnedState: transcriptPinnedState) {
                    requestTranscriptBottomScroll()
                }
            }
            PiAgentProcessingIndicatorBar(message: stabilizedProcessingMessage)

            Divider()

            VStack(spacing: 12) {
                // Shown for project drafts, including subagents-off — the card
                // renders dimmed with its switch so agents can be turned back
                // on right here instead of from the Agents screen. General Chat
                // never exposes Deck-agent delegation.
                if let session = store.selectedSession,
                   !session.isNoProject,
                   session.status == .draft,
                   store.activeLoopRun(for: session.id) == nil {
#if DEBUG
                    PiAgentSessionSubagentPickerCard(
                        viewModel: viewModel,
                        session: session,
                        stressExpansionRequest: isPickerStressRequested ? pickerStressExpansionRequest : nil,
                        stressRowSource: isPickerStressRequested ? pickerStressRowSource : nil,
                        stressAcknowledgements: isPickerStressRequested ? pickerStressAcknowledgements : nil
                    )
                    .id(session.id)
#else
                    PiAgentSessionSubagentPickerCard(viewModel: viewModel, session: session)
                        .id(session.id)
#endif
                }

                if let request = store.selectedUIRequest {
                    PiAgentUIRequestInlineNotice(
                        request: request,
                        onRespond: { isUIRequestSheetPresented = true },
                        onCancel: { viewModel.cancelPiAgentUIRequest(request) }
                    )
                } else if let request = selectedPendingSupervisorRequest {
                    PiSubagentSupervisorRequestInlineNotice(
                        request: request,
                        onRespond: { isSupervisorRequestSheetPresented = true },
                        onCancel: { viewModel.cancelSubagentSupervisorRequest(request.id, parentSessionID: request.parentSessionID) }
                    )
                }

                PiAgentComposerPanel(
                    viewModel: viewModel,
                    store: store,
                    selectedSessionID: store.selectedSessionID,
                    onWillSend: beginTranscriptAutoScrollTurn,
                    onDidSend: requestTranscriptBottomScroll,
                    sendFly: composerSendFly
                )
                .equatable()
            }
            .padding(18)
        }
        // Fly chip overlays the whole column so it can rise into the transcript.
        .overlay(alignment: .bottomTrailing) {
            if let payload = composerSendFly.payload {
                ComposerSendFlyBubble(payload: payload, progress: composerSendFly.progress)
                    .padding(.trailing, 36)
                    .padding(.bottom, 120)
                    .allowsHitTesting(false)
            }
        }
    }

    @ViewBuilder
    var sessionHeader: some View {
        if let session = store.selectedSession {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    AppLabelTag(text: session.kind.rawValue, color: sessionKindTagColor(session.kind))
                    if session.isAgentBound, let agentName = session.agentName, !agentName.isEmpty {
                        HStack(spacing: 4) {
                            Image(systemName: "sparkles.rectangle.stack")
                                .font(AppTheme.Font.caption2.weight(.semibold))
                            Text(LanguageStore.shared.t("agent.chatWith", agentName))
                                .font(AppTheme.Font.footnote.weight(.semibold))
                        }
                        .foregroundStyle(AppTheme.brandAccent)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule(style: .continuous).fill(AppTheme.brandAccent.opacity(0.12)))
                    }
                    AppLabelTag(text: effectiveStatus(for: session), color: effectiveStatusColor(for: session))
                    Text(session.updatedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(AppTheme.Font.footnote)
                        .foregroundStyle(AppTheme.mutedText)
                    Spacer(minLength: 0)
                }
                Text(session.displayTitle)
                    .font(.title3.bold())
                    .fontWidth(.expanded)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)

                if let error = session.lastError {
                    Text(error)
                        .font(AppTheme.Font.footnote)
                        .foregroundStyle(.red)
                }
            }
        } else {
            AppCard(title: LanguageStore.shared.t("agent.noSessionTitle")) {
                Text(LanguageStore.shared.t("agent.noSessionBody"))
                    .foregroundStyle(AppTheme.mutedText)
            }
        }
    }

    var transcript: some View {
        // `PiAgentTranscriptHost` is the ONLY view that observes `transcriptCache`,
        // so the ~30Hz streaming pulse re-renders the transcript table alone and no
        // longer invalidates this screen's session list / composer. `makeItems` is
        // re-run inside the host on each pulse; it reads the live cache + parent
        // references (store/viewModel), so the items stay correct even though the
        // parent struct it captured isn't re-evaluated between pulses.
        PiAgentTranscriptHost(
            cache: transcriptCache,
            sessionID: store.selectedSession?.id,
            isTranscriptLoading: { [store] in store.isSelectedTranscriptLoading },
            bottomScrollRequest: transcriptBottomScrollRequest,
            makeItems: { appKitTranscriptItems },
            onPinnedToBottomChange: { isPinnedToBottom in
                transcriptPinnedState.isPinned = isPinnedToBottom
            },
            onNearTopLoadEarlier: {
                // Only page while older threads remain behind the window.
                guard transcriptTimelineSnapshot.recentWindowArchive != nil else { return }
                loadEarlierTranscriptPage()
            },
            onBenchAdvanceSession: { viewModel.selectNextPiAgentSession() },
            benchSessionCount: { viewModel.scopedPiAgentSessionsInOrder().count }
        )
        .onChange(of: selectedSessionProcessingMessage) { _, message in
            updateStabilizedProcessingMessage(message)
            guard message != nil, transcriptPinnedState.isPinned else { return }
            requestTranscriptBottomScroll()
        }
        .perfScene("PiAgentTranscript")
    }

}
