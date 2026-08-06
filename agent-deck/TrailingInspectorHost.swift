import SwiftUI

// MARK: - Trailing inspector multi-tool shell

/// Tools available in the trailing inspector (right column).
///
/// Rail is intentionally thin in-house code; body content is per-tool
/// (Review uses open-source `gitdiff`, Memory reuses the project Memory screen).
enum TrailingInspectorTool: String, CaseIterable, Identifiable, Hashable {
    /// Git changes + OSS diff preview.
    case review
    /// Project-scoped Memory browser (read/write durable notes).
    case memory

    var id: String { rawValue }

    /// SF Symbol for the vertical activity rail.
    var systemImage: String {
        switch self {
        case .review: return "sidebar.trailing"
        case .memory: return "brain.head.profile"
        }
    }

    /// Localization key for accessibility / tooltip.
    var l10nKey: String {
        switch self {
        case .review: return "inspector.tool.review"
        case .memory: return "inspector.tool.memory"
        }
    }

    /// UserDefaults key for last selected tool.
    static let defaultsKey = "pi.deck.trailingInspectorTool"

    /// Loads last selection; falls back to `.review`.
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
/// - Parameter viewModel: Shared app model (git, memory, session, selected tool).
struct TrailingInspectorHost: View {
    @Bindable var viewModel: AppViewModel
    @ObservedObject private var languageStore = LanguageStore.shared
    @State private var memorySearchText = ""

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
        case .memory:
            MemoryScreen(
                viewModel: viewModel,
                memoryStore: viewModel.agentMemoryStore,
                searchText: $memorySearchText
            )
        }
    }

    private var toolRail: some View {
        VStack(spacing: 6) {
            ForEach(TrailingInspectorTool.allCases) { tool in
                railButton(tool)
            }
            Spacer(minLength: 0)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(languageStore.t("inspector.rail.a11y"))
    }

    /// Builds one rail icon button for a tool.
    ///
    /// - Parameter tool: Target tool to select when pressed.
    /// - Returns: Styled circular icon control.
    private func railButton(_ tool: TrailingInspectorTool) -> some View {
        let selected = viewModel.trailingInspectorTool == tool
        return Button {
            viewModel.trailingInspectorTool = tool
        } label: {
            Image(systemName: tool.systemImage)
                .font(.system(size: 14, weight: selected ? .semibold : .regular))
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
    }
}
