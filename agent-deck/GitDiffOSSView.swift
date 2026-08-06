import AppKit
import SwiftUI
import gitdiff
import Highlightr

/// Review diff surface: **gitdiff** parses unified diff; **Highlightr** colors code.
///
/// `gitdiff` has **no** syntax-highlight plugin — its `DiffRenderer` only tints
/// add/remove/context. We keep the parser (`UnifiedDiffParser`) and render lines
/// ourselves with Highlightr (highlight.js) per file language.
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

    private let gutterWidth: CGFloat = 44
    private let markerWidth: CGFloat = 14
    private let lineMinHeight: CGFloat = 18

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
                    }
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(minWidth: 520, alignment: .topLeading)
                    .padding(.vertical, 6)
                }
            }
        }
        .background(AppTheme.textContentFill)
        .task(id: diffText) {
            isParsing = true
            let parsed = (try? await UnifiedDiffParser().parse(diffText)) ?? []
            files = parsed
            isParsing = false
            DiffSyntaxHighlighter.shared.prepareTheme(colorScheme: colorScheme)
        }
        .onChange(of: colorScheme) { _, scheme in
            DiffSyntaxHighlighter.shared.prepareTheme(colorScheme: scheme)
        }
    }

    @ViewBuilder
    private func fileBlock(_ file: DiffFile) -> some View {
        let language = DiffSyntaxHighlighter.languageID(
            forPath: filePath ?? file.displayName
        )
        VStack(alignment: .leading, spacing: 0) {
            ForEach(file.hunks) { hunk in
                Text(hunk.header)
                    .font(AppTheme.Font.caption2.weight(.medium).monospaced())
                    .foregroundStyle(AppTheme.mutedText)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(AppTheme.contentSubtleFill.opacity(0.85))

                ForEach(hunk.lines) { line in
                    lineRow(line, language: language)
                }
            }
        }
    }

    /// Renders one diff line with gutter, marker, and syntax-colored content.
    ///
    /// - Parameters:
    ///   - line: Parsed `gitdiff` line model.
    ///   - language: highlight.js language id, or `nil` for plain text.
    /// - Returns: A single-row HStack for the diff surface.
    private func lineRow(_ line: DiffLine, language: String?) -> some View {
        let gutter = line.newLineNumber ?? line.oldLineNumber
        let display = line.content.replacingOccurrences(of: "\t", with: "    ")
        let highlighted = DiffSyntaxHighlighter.shared.attributedLine(
            display.isEmpty ? " " : display,
            language: language,
            colorScheme: colorScheme
        )

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

            Text(highlighted)
                .font(AppTheme.Font.code)
                .textSelection(.enabled)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
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

/// Thread-safe-ish helper around Highlightr for per-line code coloring in diffs.
///
/// Highlightr wraps highlight.js; call ``prepareTheme(colorScheme:)`` when the
/// system appearance changes so token colors match light/dark Deck chrome.
final class DiffSyntaxHighlighter {
    /// Shared instance (Highlightr is relatively expensive to construct).
    static let shared = DiffSyntaxHighlighter()

    private let highlightr: Highlightr?
    private var preparedScheme: ColorScheme?

    private init() {
        highlightr = Highlightr()
        // Prefer plain code font; SwiftUI Text still applies AppTheme.Font.code.
        highlightr?.theme.codeFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    }

    /// Switches highlight.js theme for light/dark.
    ///
    /// - Parameter colorScheme: Current SwiftUI color scheme.
    func prepareTheme(colorScheme: ColorScheme) {
        guard preparedScheme != colorScheme else { return }
        preparedScheme = colorScheme
        // Built-in themes shipped with Highlightr assets.
        let name = colorScheme == .dark ? "atom-one-dark" : "xcode"
        _ = highlightr?.setTheme(to: name)
        highlightr?.theme.codeFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
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

    /// Highlights a single source line.
    ///
    /// - Parameters:
    ///   - line: Line body without `+`/`-` marker.
    ///   - language: highlight.js language id, or `nil`.
    ///   - colorScheme: Ensures theme is prepared before highlighting.
    /// - Returns: SwiftUI `AttributedString` for `Text`.
    func attributedLine(_ line: String, language: String?, colorScheme: ColorScheme) -> AttributedString {
        prepareTheme(colorScheme: colorScheme)
        guard let highlightr,
              let language,
              let ns = highlightr.highlight(line, as: language) else {
            var plain = AttributedString(line)
            plain.foregroundColor = Color.primary.opacity(0.88)
            return plain
        }
        // Drop background from theme so our add/remove row fill shows through.
        let mutable = NSMutableAttributedString(attributedString: ns)
        mutable.removeAttribute(.backgroundColor, range: NSRange(location: 0, length: mutable.length))
        return AttributedString(mutable)
    }
}
