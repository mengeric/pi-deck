import AppKit
import SwiftUI

// MARK: - Trailing inspector multi-tool shell

/// Tools available in the trailing inspector (right column).
///
/// The vertical icon rail is **hidden while the inspector is expanded** (only one
/// tool remains after Memory was removed; rail would only waste space).
enum TrailingInspectorTool: String, CaseIterable, Identifiable, Hashable {
    /// Git changes + OSS diff preview.
    case review

    var id: String { rawValue }

    /// SF Symbol for chrome (path bar / future rail).
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
    /// - Returns: Persisted tool or `.review` when missing/unknown.
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

/// Host for the trailing column body (no icon rail while expanded).
///
/// - Parameter viewModel: Shared app model (git, session, selected tool).
struct TrailingInspectorHost: View {
    @Bindable var viewModel: AppViewModel

    var body: some View {
        toolBody
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(AppTheme.windowBackground)
            .onAppear {
                // Migrate away from removed tools (e.g. former `.memory`).
                if TrailingInspectorTool(rawValue: UserDefaults.standard.string(forKey: TrailingInspectorTool.defaultsKey) ?? "") == nil {
                    viewModel.trailingInspectorTool = .review
                    TrailingInspectorTool.save(.review)
                }
                // Expanded Review always shows the review body.
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
}
