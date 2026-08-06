import SwiftUI
import gitdiff

/// Review diff surface backed by open-source `gitdiff.DiffRenderer`.
///
/// - Parameters:
///   - diffText: Raw unified / full-file `git diff` text from `GitRepositoryService`.
///
/// Visual defaults match Deck chrome: single gutter (compact like the old
/// in-house view), hunk headers on, file headers off (path bar owns the name).
struct GitDiffOSSView: View {
    /// Unified diff text produced by git (may include multi-file headers).
    let diffText: String

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        DiffRenderer(diffText: diffText)
            .diffTheme(resolvedTheme)
            .diffFileHeaders(false)
            .diffHunkHeaders(true)
            // Single gutter reads closer to Deck's previous FullFileDiffView.
            .diffLineNumberStyle(.single)
            .diffFont(size: 12, design: .monospaced)
            .diffWordWrap(false)
            .diffLineSpacing(.compact)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(AppTheme.textContentFill)
    }

    /// Theme mapped for current color scheme using Deck add/remove accents.
    private var resolvedTheme: DiffTheme {
        colorScheme == .dark ? Self.deckDarkTheme : Self.deckLightTheme
    }

    /// Light theme using Deck add/remove accents.
    private static let deckLightTheme = DiffTheme(
        addedBackground: AppTheme.diffAdded.opacity(0.14),
        addedText: Color.primary,
        removedBackground: AppTheme.diffRemoved.opacity(0.14),
        removedText: Color.primary.opacity(0.92),
        contextBackground: Color.clear,
        contextText: Color.primary.opacity(0.86),
        lineNumberBackground: AppTheme.contentSubtleFill.opacity(0.55),
        lineNumberText: AppTheme.mutedText,
        headerBackground: AppTheme.contentSubtleFill,
        headerText: AppTheme.mutedText,
        fileHeaderBackground: AppTheme.contentSubtleFill,
        fileHeaderText: Color.primary
    )

    /// Dark theme using Deck add/remove accents.
    private static let deckDarkTheme = DiffTheme(
        addedBackground: AppTheme.diffAdded.opacity(0.16),
        addedText: Color.primary,
        removedBackground: AppTheme.diffRemoved.opacity(0.16),
        removedText: Color.primary.opacity(0.92),
        contextBackground: Color.clear,
        contextText: Color.primary.opacity(0.86),
        lineNumberBackground: AppTheme.contentSubtleFill.opacity(0.55),
        lineNumberText: AppTheme.mutedText,
        headerBackground: AppTheme.contentSubtleFill,
        headerText: AppTheme.mutedText,
        fileHeaderBackground: AppTheme.contentSubtleFill,
        fileHeaderText: Color.primary
    )
}
