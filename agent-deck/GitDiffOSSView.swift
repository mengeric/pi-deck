import SwiftUI
import gitdiff

/// Phase 0 OSS diff surface for Review: wraps `gitdiff.DiffRenderer`.
///
/// - Parameters:
///   - diffText: Raw unified / full-file `git diff` text from `GitRepositoryService`.
///
/// Defaults can be overridden with UserDefaults:
/// - `pi.deck.reviewUseGitdiff` (Bool, default `true`): when `false`, callers should use legacy `FullFileDiffView`.
struct GitDiffOSSView: View {
    /// Unified diff text produced by git (may include multi-file headers).
    let diffText: String

    @Environment(\.colorScheme) private var colorScheme

    /// UserDefaults key: prefer open-source `gitdiff` renderer in Review (default true).
    static let useGitdiffDefaultsKey = "pi.deck.reviewUseGitdiff"

    /// Whether Review should use the OSS renderer.
    ///
    /// - Returns: `true` when key is unset or true; `false` only when explicitly disabled.
    static var prefersGitdiffRenderer: Bool {
        if UserDefaults.standard.object(forKey: useGitdiffDefaultsKey) == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: useGitdiffDefaultsKey)
    }

    var body: some View {
        DiffRenderer(diffText: diffText)
            .diffTheme(resolvedTheme)
            // Review already shows the path in the file path bar — hide redundant file headers.
            .diffFileHeaders(false)
            .diffHunkHeaders(true)
            .diffLineNumberStyle(.dual)
            .diffFont(size: 12, design: .monospaced)
            .diffWordWrap(false)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(AppTheme.textContentFill)
    }

    /// Theme mapped for current color scheme; tinted toward Deck diff colors.
    private var resolvedTheme: DiffTheme {
        colorScheme == .dark ? Self.deckDarkTheme : Self.deckLightTheme
    }

    /// Light theme using Deck add/remove accents where possible.
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
