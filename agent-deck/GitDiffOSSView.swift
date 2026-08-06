import AppKit
import Combine
import SwiftUI
import gitdiff
import Highlightr

/// Review diff surface: **gitdiff** parses unified diff; optional **Highlightr** coloring.
///
/// Performance rules for large files:
/// - Parse off the main actor.
/// - Skip syntax highlight above ``highlightLineBudget`` lines (Highlightr is highlight.js).
/// - Lazy line stacks; no `fixedSize(horizontal:)` measuring the whole file.
/// - Soft cap on first paint with “Show more” growth.
///
/// - Parameters:
///   - diffText: Raw `git diff` text from `GitRepositoryService`.
///   - filePath: Optional path for language detection (extension → highlight.js id).
struct GitDiffOSSView: View {
    /// Unified diff text produced by git.
    let diffText: String
    /// Repository-relative path of the selected file (for syntax language).
    var filePath: String? = nil

    @Environment(\.colorScheme) private var colorScheme
    @State private var files: [DiffFile] = []
    @State private var isParsing = true
    @State private var totalLineCount = 0
    @State private var enableHighlight = false
    /// How many content lines to mount (grows via “Show more”).
    @State private var visibleLineBudget = GitDiffOSSView.initialLineBudget

    private let gutterWidth: CGFloat = 44
    private let markerWidth: CGFloat = 14
    private let lineMinHeight: CGFloat = 17

    /// First paint line budget (keeps scroll smooth on multi-kLOC diffs).
    static let initialLineBudget = 400
    /// Lines added each time the user expands.
    static let lineBudgetStep = 600
    /// Above this, Highlightr is disabled (too expensive per-line).
    static let highlightLineBudget = 350
    /// Character length above which highlight is also skipped.
    static let highlightCharBudget = 80_000

    var body: some View {
        Group {
            if isParsing && files.isEmpty {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if files.isEmpty {
                Text(LanguageStore.shared.t("review.selectFileBody"))
                    .font(AppTheme.Font.caption)
                    .foregroundStyle(AppTheme.mutedText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView([.vertical, .horizontal], showsIndicators: true) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(files) { file in
                            fileBlock(file)
                        }
                        if totalLineCount > visibleLineBudget {
                            moreButton
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(.vertical, 6)
                }
            }
        }
        .background(AppTheme.textContentFill)
        .task(id: diffText) {
            await reload(diffText: diffText)
        }
        .onChange(of: colorScheme) { _, scheme in
            guard enableHighlight else { return }
            DiffSyntaxHighlighter.shared.prepareTheme(colorScheme: scheme)
        }
    }

    private var moreButton: some View {
        Button {
            visibleLineBudget += Self.lineBudgetStep
        } label: {
            Text(LanguageStore.shared.t(
                "review.diff.showMore",
                min(Self.lineBudgetStep, totalLineCount - visibleLineBudget),
                totalLineCount - visibleLineBudget
            ))
            .font(AppTheme.Font.caption.weight(.semibold))
            .foregroundStyle(Color.accentColor)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
        }
        .buttonStyle(.plain)
        .background(AppTheme.contentSubtleFill.opacity(0.6))
    }

    /// Parses `diffText` off-main and resets budgets for a new selection.
    ///
    /// - Parameter diffText: Unified diff payload.
    private func reload(diffText: String) async {
        isParsing = true
        files = []
        visibleLineBudget = Self.initialLineBudget
        let text = diffText
        let charCount = text.utf8.count
        let parsed: [DiffFile] = await Task.detached(priority: .userInitiated) {
            (try? await UnifiedDiffParser().parse(text)) ?? []
        }.value
        let lines = parsed.reduce(0) { partial, file in
            partial + file.hunks.reduce(0) { $0 + $1.lines.count }
        }
        totalLineCount = lines
        enableHighlight = lines <= Self.highlightLineBudget && charCount <= Self.highlightCharBudget
        if enableHighlight {
            DiffSyntaxHighlighter.shared.prepareTheme(colorScheme: colorScheme)
        }
        files = parsed
        isParsing = false
    }

    @ViewBuilder
    private func fileBlock(_ file: DiffFile) -> some View {
        let language = enableHighlight
            ? DiffSyntaxHighlighter.languageID(forPath: filePath ?? file.displayName)
            : nil
        let slices = Self.budgetedHunks(file.hunks, budget: visibleLineBudget)

        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(slices) { slice in
                Text(slice.header)
                    .font(AppTheme.Font.caption2.weight(.medium).monospaced())
                    .foregroundStyle(AppTheme.mutedText)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(AppTheme.contentSubtleFill.opacity(0.85))

                ForEach(slice.lines) { line in
                    lineRow(line, language: language)
                }
            }
        }
    }

    /// Applies a soft line budget across hunks for progressive rendering.
    ///
    /// - Parameters:
    ///   - hunks: Parsed hunks for one file.
    ///   - budget: Max content lines to include.
    /// - Returns: Slices with headers and truncated line arrays.
    private static func budgetedHunks(_ hunks: [DiffHunk], budget: Int) -> [BudgetedHunk] {
        var left = budget
        var out: [BudgetedHunk] = []
        out.reserveCapacity(hunks.count)
        for hunk in hunks {
            if left <= 0 { break }
            let take = min(left, hunk.lines.count)
            out.append(BudgetedHunk(
                id: hunk.id,
                header: hunk.header,
                lines: Array(hunk.lines.prefix(take))
            ))
            left -= take
        }
        return out
    }

    /// One hunk slice after applying the visible-line budget.
    private struct BudgetedHunk: Identifiable {
        let id: UUID
        let header: String
        let lines: [DiffLine]
    }

    /// Renders one diff line with gutter, marker, and optional syntax color.
    ///
    /// - Parameters:
    ///   - line: Parsed `gitdiff` line model.
    ///   - language: highlight.js language id, or `nil` for plain monochrome.
    /// - Returns: A single-row HStack for the diff surface.
    private func lineRow(_ line: DiffLine, language: String?) -> some View {
        let gutter = line.newLineNumber ?? line.oldLineNumber
        let display = line.content.isEmpty ? " " : line.content.replacingOccurrences(of: "\t", with: "    ")

        return HStack(alignment: .firstTextBaseline, spacing: 0) {
            Rectangle()
                .fill(railColor(line.type))
                .frame(width: 3)

            Text(gutter.map(String.init) ?? "")
                .font(AppTheme.Font.code)
                .monospacedDigit()
                .foregroundStyle(gutterColor(line.type))
                .frame(width: gutterWidth - 3, alignment: .trailing)
                .padding(.trailing, 6)

            Rectangle()
                .fill(AppTheme.hairlineStroke.opacity(0.45))
                .frame(width: 1)
                .padding(.vertical, 1)

            Text(linePrefix(line.type))
                .font(AppTheme.Font.code.weight(.semibold))
                .foregroundStyle(markerColor(line.type))
                .frame(width: markerWidth, alignment: .center)

            Group {
                if let language, enableHighlight {
                    Text(DiffSyntaxHighlighter.shared.attributedLine(
                        display,
                        language: language,
                        colorScheme: colorScheme
                    ))
                } else {
                    Text(display)
                        .foregroundStyle(Color.primary.opacity(0.88))
                }
            }
            .font(AppTheme.Font.code)
            .textSelection(.enabled)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, 14)
        }
        .frame(minHeight: lineMinHeight, alignment: .center)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(lineBackground(line.type))
    }

    private func linePrefix(_ type: DiffLine.LineType) -> String {
        switch type {
        case .context, .header: return " "
        case .added: return "+"
        case .removed: return "−"
        }
    }

    private func railColor(_ type: DiffLine.LineType) -> Color {
        switch type {
        case .context, .header: return .clear
        case .added: return AppTheme.diffAdded.opacity(0.95)
        case .removed: return AppTheme.diffRemoved.opacity(0.95)
        }
    }

    private func markerColor(_ type: DiffLine.LineType) -> Color {
        switch type {
        case .context, .header: return AppTheme.mutedText.opacity(0.35)
        case .added: return AppTheme.diffAdded
        case .removed: return AppTheme.diffRemoved
        }
    }

    private func gutterColor(_ type: DiffLine.LineType) -> Color {
        switch type {
        case .context, .header: return AppTheme.mutedText.opacity(0.55)
        case .added: return AppTheme.diffAdded.opacity(0.85)
        case .removed: return AppTheme.diffRemoved.opacity(0.85)
        }
    }

    private func lineBackground(_ type: DiffLine.LineType) -> Color {
        switch type {
        case .context, .header: return .clear
        case .added: return AppTheme.diffAdded.opacity(0.12)
        case .removed: return AppTheme.diffRemoved.opacity(0.12)
        }
    }
}

// MARK: - Highlightr bridge

/// Helper around Highlightr for per-line code coloring in small/medium diffs.
///
/// Highlightr wraps highlight.js; call ``prepareTheme(colorScheme:)`` when the
/// system appearance changes so token colors match light/dark Deck chrome.
final class DiffSyntaxHighlighter {
    /// Shared instance (Highlightr is relatively expensive to construct).
    static let shared = DiffSyntaxHighlighter()

    private let highlightr: Highlightr?
    private var preparedScheme: ColorScheme?
    /// Tiny LRU for identical line+language strings within one scroll session.
    private var lineCache: [String: AttributedString] = [:]
    private var lineCacheOrder: [String] = []
    private let lineCacheLimit = 512

    private init() {
        highlightr = Highlightr()
        highlightr?.theme.codeFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    }

    /// Switches highlight.js theme for light/dark and clears the line cache.
    ///
    /// - Parameter colorScheme: Current SwiftUI color scheme.
    func prepareTheme(colorScheme: ColorScheme) {
        guard preparedScheme != colorScheme else { return }
        preparedScheme = colorScheme
        let name = colorScheme == .dark ? "atom-one-dark" : "xcode"
        _ = highlightr?.setTheme(to: name)
        highlightr?.theme.codeFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        lineCache.removeAll(keepingCapacity: true)
        lineCacheOrder.removeAll(keepingCapacity: true)
    }

    /// Maps a file path extension to a highlight.js language id.
    ///
    /// - Parameter path: Absolute or relative path (uses last path component).
    /// - Returns: Language id, or `nil` when unknown (plain monochrome).
    static func languageID(forPath path: String) -> String? {
        let ext = (path as NSString).pathExtension.lowercased()
        switch ext {
        case "swift": return "swift"
        case "ts", "tsx": return "typescript"
        case "js", "jsx", "mjs", "cjs": return "javascript"
        case "py": return "python"
        case "go": return "go"
        case "rs": return "rust"
        case "rb": return "ruby"
        case "java": return "java"
        case "kt", "kts": return "kotlin"
        case "c", "h": return "c"
        case "cpp", "cc", "cxx", "hpp", "hh": return "cpp"
        case "m", "mm": return "objectivec"
        case "cs": return "csharp"
        case "sh", "bash", "zsh": return "bash"
        case "json": return "json"
        case "yml", "yaml": return "yaml"
        case "md", "markdown": return "markdown"
        case "html", "htm": return "xml"
        case "css", "scss": return "css"
        case "sql": return "sql"
        case "toml": return "ini"
        case "xml", "plist": return "xml"
        default: return nil
        }
    }

    /// Highlights a single source line (with a small LRU cache).
    ///
    /// - Parameters:
    ///   - line: Line body without `+`/`-` marker.
    ///   - language: highlight.js language id, or `nil`.
    ///   - colorScheme: Ensures theme is prepared before highlighting.
    /// - Returns: SwiftUI `AttributedString` for `Text`.
    func attributedLine(_ line: String, language: String?, colorScheme: ColorScheme) -> AttributedString {
        prepareTheme(colorScheme: colorScheme)
        guard let highlightr, let language else {
            var plain = AttributedString(line)
            plain.foregroundColor = Color.primary.opacity(0.88)
            return plain
        }
        let key = language + "\u{1e}" + line
        if let hit = lineCache[key] { return hit }

        guard let ns = highlightr.highlight(line, as: language) else {
            var plain = AttributedString(line)
            plain.foregroundColor = Color.primary.opacity(0.88)
            return plain
        }
        let mutable = NSMutableAttributedString(attributedString: ns)
        mutable.removeAttribute(.backgroundColor, range: NSRange(location: 0, length: mutable.length))
        let value = AttributedString(mutable)
        lineCache[key] = value
        lineCacheOrder.append(key)
        if lineCacheOrder.count > lineCacheLimit {
            let drop = lineCacheOrder.removeFirst()
            lineCache[drop] = nil
        }
        return value
    }
}
