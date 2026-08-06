import AppKit
import SwiftUI

// MARK: - Trailing inspector multi-tool shell

/// Tools available in the trailing inspector (right column).
///
/// Rail interaction:
/// - **Not expanded** → toolbar / open path expands Review (`toggleTrailingInspector`).
/// - **Expanded + click active tool** → collapses the whole trailing column.
/// - **Expanded + click other tool** → switches body (future multi-tool).
enum TrailingInspectorTool: String, CaseIterable, Identifiable, Hashable {
    /// Git changes + OSS diff preview.
    case review

    var id: String { rawValue }

    /// SF Symbol for the vertical activity rail (git-branded).
    var systemImage: String {
        switch self {
        case .review: return "arrow.triangle.branch"
        }
    }

    /// Localization key for accessibility / tooltip.
    var l10nKey: String {
        switch self {
        case .review: return "inspector.tool.review"
        }
    }

    /// UserDefaults key for last selected tool.
    static let defaultsKey = "pi.deck.trailingInspectorTool"

    /// Loads last selection; falls back to `.review`.
    ///
    /// - Returns: Persisted tool or `.review` when missing/unknown (e.g. removed Memory).
    static func load() -> TrailingInspectorTool {
        if let raw = UserDefaults.standard.string(forKey: defaultsKey),
           let tool = TrailingInspectorTool(rawValue: raw) {
            return tool
        }
        return .review
    }

    /// Persists selection for next launch.
    ///
    /// - Parameter tool: Tool to remember.
    static func save(_ tool: TrailingInspectorTool) {
        UserDefaults.standard.set(tool.rawValue, forKey: defaultsKey)
    }
}

/// Host for the trailing column: `[ body | icon rail ]`.
///
/// - Parameter viewModel: Shared app model (git, session, selected tool).
struct TrailingInspectorHost: View {
    @Bindable var viewModel: AppViewModel
    @ObservedObject private var languageStore = LanguageStore.shared

    private let railWidth: CGFloat = 40

    var body: some View {
        HStack(spacing: 0) {
            toolBody
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Rectangle()
                .fill(AppTheme.hairlineStroke.opacity(0.55))
                .frame(width: 1)
                .padding(.vertical, 6)

            toolRail
                .frame(width: railWidth)
                .padding(.vertical, 8)
        }
        .background(AppTheme.windowBackground)
        .onAppear {
            // Migrate away from removed tools (e.g. former `.memory`).
            if TrailingInspectorTool(rawValue: UserDefaults.standard.string(forKey: TrailingInspectorTool.defaultsKey) ?? "") == nil {
                viewModel.trailingInspectorTool = .review
                TrailingInspectorTool.save(.review)
            }
            if viewModel.trailingInspectorTool != .review {
                viewModel.trailingInspectorTool = .review
                TrailingInspectorTool.save(.review)
            }
            viewModel.prepareRepoChangesForSelectedPiAgentSession(force: false)
        }
        .onChange(of: viewModel.trailingInspectorTool) { _, tool in
            TrailingInspectorTool.save(tool)
            if tool == .review {
                viewModel.prepareRepoChangesForSelectedPiAgentSession(force: false)
            }
        }
    }

    @ViewBuilder
    private var toolBody: some View {
        switch viewModel.trailingInspectorTool {
        case .review:
            PiAgentRepoReviewPanel(viewModel: viewModel)
        }
    }

    private var toolRail: some View {
        VStack(spacing: 6) {
            ForEach(TrailingInspectorTool.allCases) { tool in
                railButton(tool)
            }
            Spacer(minLength: 0)
            // Explicit hide control — same glyph as toolbar “Review”.
            collapseRailButton
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(languageStore.t("inspector.rail.a11y"))
    }

    /// Hides the trailing inspector column (Review closed).
    private var collapseRailButton: some View {
        Button {
            viewModel.collapseTrailingInspector()
        } label: {
            Image(systemName: "sidebar.trailing")
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(AppTheme.mutedText)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.clear)
                )
        }
        .buttonStyle(.plain)
        .help(languageStore.t("inspector.rail.hide"))
        .accessibilityLabel(languageStore.t("inspector.rail.hide"))
    }

    /// Builds one rail icon button for a tool.
    ///
    /// Clicking the **already-selected** tool while expanded **collapses** the
    /// trailing column (toggle). Clicking another tool switches the body.
    ///
    /// - Parameter tool: Target tool.
    /// - Returns: Styled circular icon control.
    private func railButton(_ tool: TrailingInspectorTool) -> some View {
        let selected = viewModel.trailingInspectorTool == tool
            && viewModel.isTrailingInspectorExpanded
        return Button {
            selectOrToggle(tool)
        } label: {
            Group {
                if tool == .review, NSImage(named: "branch") != nil {
                    Image("branch")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 15, height: 15)
                } else {
                    Image(systemName: tool.systemImage)
                        .font(.system(size: 14, weight: selected ? .semibold : .regular))
                }
            }
            .foregroundStyle(selected ? Color.accentColor : AppTheme.mutedText)
            .frame(width: 28, height: 28)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(selected ? Color.accentColor.opacity(0.14) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(
                        selected ? Color.accentColor.opacity(0.35) : Color.clear,
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(.plain)
        .help(languageStore.t(tool.l10nKey))
        .accessibilityLabel(languageStore.t(tool.l10nKey))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityHint(languageStore.t("inspector.rail.toggleHint"))
    }

    /// Selects a tool, or collapses when the active expanded tool is clicked again.
    ///
    /// - Parameter tool: Rail tool that was activated.
    private func selectOrToggle(_ tool: TrailingInspectorTool) {
        if viewModel.isTrailingInspectorExpanded,
           viewModel.trailingInspectorTool == tool {
            // Shown → hide.
            viewModel.collapseTrailingInspector()
            return
        }
        // Not expanded, or switching tools → expand + select.
        withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) {
            viewModel.trailingInspectorTool = tool
            TrailingInspectorTool.save(tool)
            if !viewModel.isTrailingInspectorExpanded {
                viewModel.openRepoChangesForSelectedPiAgentSession()
            } else if tool == .review {
                viewModel.prepareRepoChangesForSelectedPiAgentSession(force: false)
            }
        }
    }
}
