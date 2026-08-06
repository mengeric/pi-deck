import AppKit
import SwiftUI

// MARK: - External editors

struct ExternalCodeEditor: Identifiable, Hashable {
    let id: String
    let name: String
    let bundleIdentifier: String

    private static let preferredDefaultsKey = "piDeck.preferredExternalEditorBundleID"

    /// Known editors, VS Code first so it is the default preference when installed.
    private static let catalog: [(name: String, bundleIDs: [String])] = [
        // Short toolbar label — user expects "VS Code", not a truncated generic string.
        ("VS Code", ["com.microsoft.VSCode", "com.microsoft.VSCodeInsiders"]),
        ("Cursor", ["com.todesktop.230313mzl4w4u92", "com.cursor.Cursor"]),
        ("Windsurf", ["com.exafunction.windsurf"]),
        ("Zed", ["dev.zed.Zed"]),
        ("Sublime Text", ["com.sublimetext.4", "com.sublimetext.3"]),
        ("Xcode", ["com.apple.dt.Xcode"]),
        ("TextEdit", ["com.apple.TextEdit"])
    ]

    /// Preferred installed editor for toolbar labels (VS Code when available).
    static func preferred() -> ExternalCodeEditor? {
        let list = installed()
        guard let id = preferredBundleID() else { return list.first }
        return list.first(where: { $0.bundleIdentifier == id }) ?? list.first
    }

    static func installed() -> [ExternalCodeEditor] {
        var result: [ExternalCodeEditor] = []
        var seen = Set<String>()
        for entry in catalog {
            for bundleID in entry.bundleIDs {
                if NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil,
                   seen.insert(bundleID).inserted {
                    result.append(ExternalCodeEditor(id: bundleID, name: entry.name, bundleIdentifier: bundleID))
                    break
                }
            }
        }
        return result
    }

    static func preferredBundleID() -> String? {
        if let stored = UserDefaults.standard.string(forKey: preferredDefaultsKey),
           NSWorkspace.shared.urlForApplication(withBundleIdentifier: stored) != nil {
            return stored
        }
        // Default: VS Code when present, otherwise first installed known editor.
        let installed = installed()
        if let vscode = installed.first(where: { $0.bundleIdentifier.hasPrefix("com.microsoft.VSCode") }) {
            return vscode.bundleIdentifier
        }
        return installed.first?.bundleIdentifier
    }

    static func rememberPreferred(bundleID: String) {
        UserDefaults.standard.set(bundleID, forKey: preferredDefaultsKey)
    }
}

// MARK: - Top-level three-column workspace (Sidebar | Chat | Review)

// ThreeColumnWorkspaceHost lives in WorkspaceSplitHost.swift (NSSplitView).

// MARK: - Column layout policy lives in WorkspaceLayout.swift

// MARK: - Toolbar toggle (sits next to toolbar search)

struct PiAgentRepoReviewToolbarButton: View {
    var viewModel: AppViewModel
    @ObservedObject private var languageStore = LanguageStore.shared

    var body: some View {
        Button {
            viewModel.toggleTrailingInspector()
        } label: {
            Label(languageStore.t("review.toolbar"), systemImage: "sidebar.trailing")
        }
        .accessibilityLabel(languageStore.t("review.toolbar"))
        .help(languageStore.t("review.toolbarHelp"))
        .disabled(viewModel.piAgentSessionStore.selectedSession == nil)
    }
}

// MARK: - Inspector panel (true trailing column via `.inspector`)

/// Session-scoped Review workbench (git changes body for trailing inspector).
/// Layout:
///   ┌ chrome ─────────────────────────────────────────┐
///   │  [gitdiff OSS preview]         │ [file list]    │
///   └─────────────────────────────────────────────────┘
struct PiAgentRepoReviewPanel: View {
    @Bindable var viewModel: AppViewModel
    @ObservedObject private var languageStore = LanguageStore.shared
    @State private var fileFilter = ""

    var body: some View {
        VStack(spacing: 0) {
            chromeBar
            Divider().opacity(0.55)
            if viewModel.piAgentSessionStore.selectedSession == nil {
                AppEmptyState(
                    languageStore.t("review.noSession"),
                    systemImage: "tray",
                    description: languageStore.t("review.noSessionBody"),
                    layout: .fill
                )
            } else {
                HSplitView {
                    previewColumn
                        .frame(minWidth: 140)
                        .layoutPriority(1)
                    fileListColumn
                        .frame(minWidth: 130, idealWidth: 220, maxWidth: 300)
                }
            }
        }
        .background(AppTheme.windowBackground)
        .onAppear {
            viewModel.prepareRepoChangesForSelectedPiAgentSession(force: true)
        }
        .onChange(of: viewModel.piAgentSessionStore.selectedSession?.id) { _, _ in
            viewModel.prepareRepoChangesForSelectedPiAgentSession(force: true)
        }
    }

    // MARK: Chrome

    private var chromeBar: some View {
        // Single row — branch + diff summary owns the full width, trailing
        // actions always visible and pinned right.
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                if let snapshot = viewModel.repositoryChanges {
                    branchChip(snapshot)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .clipped()

                    if additionHint > 0 || deletionHint > 0 {
                        HStack(spacing: 6) {
                            if additionHint > 0 {
                                Text("+\(additionHint)")
                                    .foregroundStyle(AppTheme.diffAdded)
                                    .lineLimit(1)
                            }
                            if deletionHint > 0 {
                                Text("-\(deletionHint)")
                                    .foregroundStyle(AppTheme.diffRemoved)
                                    .lineLimit(1)
                            }
                        }
                        .font(AppTheme.Font.caption2.weight(.semibold).monospacedDigit())
                        .fixedSize(horizontal: true, vertical: false)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 6) {
                if viewModel.isLoadingRepositoryChanges {
                    AppSpinner().controlSize(.mini)
                }

                AppCircleIconButton(
                    style: .neutral,
                    size: 26,
                    imageScale: .medium,
                    symbolWeight: .semibold,
                    help: languageStore.t("common.refresh")
                ) {
                    viewModel.prepareRepoChangesForSelectedPiAgentSession(force: true)
                } symbol: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(viewModel.isLoadingRepositoryChanges)
                .opacity(viewModel.isLoadingRepositoryChanges ? 0.5 : 1)
            }
            .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func branchChip(_ snapshot: RepositoryChangesSnapshot) -> some View {
        HStack(spacing: 5) {
            Image("branch")
                .font(.system(size: 10, weight: .semibold))
            Text(snapshot.branchName)
                .lineLimit(1)
                .truncationMode(.middle)
            if let upstream = snapshot.upstreamBranch, !upstream.isEmpty {
                Text("→")
                    .foregroundStyle(AppTheme.mutedText)
                Text(upstream)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(AppTheme.mutedText)
            }
        }
        .font(AppTheme.Font.caption2.weight(.medium))
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            Capsule(style: .continuous)
                .strokeBorder(AppTheme.hairlineStroke.opacity(0.55), lineWidth: 1)
        )
    }

    private var additionHint: Int {
        guard let text = viewModel.repositorySelectedDiffText else { return 0 }
        return text.split(separator: "\n").filter { $0.hasPrefix("+") && !$0.hasPrefix("+++") }.count
    }

    private var deletionHint: Int {
        guard let text = viewModel.repositorySelectedDiffText else { return 0 }
        return text.split(separator: "\n").filter { $0.hasPrefix("-") && !$0.hasPrefix("---") }.count
    }

    // MARK: File list

    private var fileListColumn: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(AppTheme.mutedText)
                TextField(languageStore.t("review.filterFiles"), text: $fileFilter)
                    .textFieldStyle(.plain)
                    .font(AppTheme.Font.caption)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(AppTheme.contentSubtleFill.opacity(0.55))
            )
            .padding(.horizontal, 10)
            .padding(.top, 10)
            .padding(.bottom, 6)

            Group {
                if viewModel.isLoadingRepositoryChanges && viewModel.repositoryChanges == nil {
                    loadingBlock(languageStore.t("review.loading"))
                } else if let error = viewModel.repositoryLastError, viewModel.repositoryChanges == nil {
                    Text(error)
                        .font(AppTheme.Font.caption)
                        .foregroundStyle(.orange)
                        .padding(12)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                } else if let snapshot = viewModel.repositoryChanges {
                    if snapshot.totalChangeCount == 0 {
                        Text(languageStore.t("review.clean"))
                            .font(AppTheme.Font.caption)
                            .foregroundStyle(AppTheme.mutedText)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 14) {
                                fileGroup(
                                    languageStore.t("review.section.conflicted", snapshot.conflicted.count),
                                    snapshot.conflicted,
                                    .conflicted
                                )
                                fileGroup(
                                    languageStore.t("review.section.staged", snapshot.staged.count),
                                    snapshot.staged,
                                    .staged
                                )
                                fileGroup(
                                    languageStore.t("review.section.unstaged", snapshot.unstaged.count),
                                    snapshot.unstaged,
                                    .unstaged
                                )
                                fileGroup(
                                    languageStore.t("review.section.untracked", snapshot.untracked.count),
                                    snapshot.untracked,
                                    .untracked
                                )
                            }
                            .padding(.horizontal, 8)
                            .padding(.bottom, 8)
                        }
                    }
                } else {
                    loadingBlock(languageStore.t("review.loading"))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider().opacity(0.5)
            HStack(spacing: 12) {
                Button(languageStore.t("review.stageAll")) { viewModel.stageAllChanges() }
                    .disabled(!(viewModel.repositoryChanges?.canStageAll ?? false))
                Button(languageStore.t("review.unstageAll")) { viewModel.unstageAllChanges() }
                    .disabled(!(viewModel.repositoryChanges?.canUnstageAll ?? false))
                Spacer(minLength: 0)
            }
            .font(AppTheme.Font.caption2.weight(.medium))
            .buttonStyle(.borderless)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(AppTheme.contentSubtleFill.opacity(0.18))
    }

    @ViewBuilder
    private func fileGroup(_ title: String, _ changes: [RepositoryFileChange], _ kind: GitDiffKind) -> some View {
        let filtered = filterChanges(changes)
        if !filtered.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(title.uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.4)
                    .foregroundStyle(AppTheme.mutedText)
                    .padding(.horizontal, 6)
                    .padding(.bottom, 2)

                ForEach(filtered) { change in
                    fileRow(change, kind: kind)
                }
            }
        }
    }

    private func fileRow(_ change: RepositoryFileChange, kind: GitDiffKind) -> some View {
        let selected = viewModel.repositorySelectedDiffFilePath == change.path
        let name = (change.path as NSString).lastPathComponent
        let folder = (change.path as NSString).deletingLastPathComponent
        return Button {
            viewModel.loadDiff(for: change.path, kind: kind)
        } label: {
            HStack(alignment: .center, spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(dotColor(kind))
                    .frame(width: 3, height: 28)

                VStack(alignment: .leading, spacing: 1) {
                    Text(name)
                        .font(AppTheme.Font.caption.weight(selected ? .semibold : .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if !folder.isEmpty && folder != "." {
                        Text(folder)
                            .font(AppTheme.Font.caption2)
                            .foregroundStyle(AppTheme.mutedText)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                }
                Spacer(minLength: 0)
                Text(change.statusSummary.trimmingCharacters(in: .whitespaces))
                    .font(AppTheme.Font.code.weight(.semibold))
                    .foregroundStyle(dotColor(kind).opacity(0.9))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selected ? AppTheme.brandAccent.opacity(0.12) : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .contextMenu {
            if kind != .staged {
                Button(languageStore.t("review.stage")) { viewModel.stage(change.path) }
            }
            if kind == .staged {
                Button(languageStore.t("review.unstage")) { viewModel.unstage(change.path) }
            }
            Divider()
            openEditorControl(for: change.path)
            Button(languageStore.t("review.revealFinder")) {
                viewModel.revealRepositoryFileInFinder(change.path)
            }
        }
        .help(change.path)
    }

    private func filterChanges(_ changes: [RepositoryFileChange]) -> [RepositoryFileChange] {
        let q = fileFilter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return changes }
        return changes.filter { $0.path.lowercased().contains(q) }
    }

    private func dotColor(_ kind: GitDiffKind) -> Color {
        switch kind {
        case .conflicted: return .orange
        case .staged: return AppTheme.diffAdded
        case .unstaged: return AppTheme.brandAccent
        case .untracked: return AppTheme.mutedText
        }
    }

    private func loadingBlock(_ text: String) -> some View {
        HStack(spacing: 8) {
            AppSpinner().controlSize(.small)
            Text(text)
                .font(AppTheme.Font.caption)
                .foregroundStyle(AppTheme.mutedText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func shortKindLabel(_ kind: GitDiffKind) -> String {
        switch kind {
        case .staged: return languageStore.t("review.kind.staged")
        case .unstaged: return languageStore.t("review.kind.unstaged")
        case .untracked: return languageStore.t("review.kind.untracked")
        case .conflicted: return languageStore.t("review.kind.conflicted")
        }
    }

    /// Shows **VS Code** (or preferred editor) as the label — never the long
    /// “在编辑器中打开” string that truncates to “在编…”.
    @ViewBuilder
    private func openEditorControl(for path: String) -> some View {
        let editors = ExternalCodeEditor.installed()
        let preferred = ExternalCodeEditor.preferred()
        let preferredID = preferred?.bundleIdentifier
        let title = preferred?.name ?? "VS Code"

        HStack(spacing: 2) {
            Button(title) {
                if let preferred {
                    viewModel.openRepositoryFile(path, withEditorBundleID: preferred.bundleIdentifier)
                } else if let first = editors.first {
                    viewModel.openRepositoryFile(path, withEditorBundleID: first.bundleIdentifier)
                } else if let url = viewModel.absoluteURLForRepositoryRelativePath(path) {
                    NSWorkspace.shared.open(url)
                }
            }
            .lineLimit(1)
            .fixedSize()
            .help(languageStore.t("review.openIn", title))

            Menu {
                ForEach(editors) { editor in
                    Button {
                        viewModel.openRepositoryFile(path, withEditorBundleID: editor.bundleIdentifier)
                    } label: {
                        if editor.bundleIdentifier == preferredID {
                            Label(editor.name, systemImage: "checkmark")
                        } else {
                            Text(editor.name)
                        }
                    }
                }
                if !editors.isEmpty { Divider() }
                Button(languageStore.t("review.openSystemDefault")) {
                    if let url = viewModel.absoluteURLForRepositoryRelativePath(path) {
                        NSWorkspace.shared.open(url)
                    }
                }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .frame(width: 14, height: 16)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(languageStore.t("review.chooseEditor"))
        }
        .fixedSize()
    }

    // MARK: Preview

    private var previewColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let path = viewModel.repositorySelectedDiffFilePath {
                filePathBar(path)
                Divider().opacity(0.45)
            }

            Group {
                if viewModel.repositorySelectedDiffFilePath == nil {
                    AppEmptyState(
                        languageStore.t("review.selectFile"),
                        systemImage: "doc.text.magnifyingglass",
                        description: languageStore.t("review.selectFileBody"),
                        layout: .fill
                    )
                } else if let text = viewModel.repositorySelectedDiffText {
                    // Phase 0: hard-wire OSS gitdiff (no legacy branch) so we can verify the package path.
                    GitDiffOSSView(diffText: text)
                        .clipShape(Rectangle())
                } else if let error = viewModel.repositoryLastError {
                    Text(error)
                        .font(AppTheme.Font.caption)
                        .foregroundStyle(.orange)
                        .padding(14)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                } else {
                    loadingBlock(languageStore.t("activity.preparingDiff"))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func filePathBar(_ path: String) -> some View {
        let fileName = (path as NSString).lastPathComponent
        return HStack(spacing: 8) {
            Image(systemName: "doc.text")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(AppTheme.mutedText)

            Text(fileName)
                .font(AppTheme.Font.caption.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(1)
                .help(path)

            if let kind = viewModel.repositorySelectedDiffKind {
                Text(shortKindLabel(kind))
                    .font(AppTheme.Font.caption2.weight(.semibold))
                    .foregroundStyle(AppTheme.mutedText)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(
                        Capsule(style: .continuous)
                            .fill(AppTheme.contentSubtleFill.opacity(0.75))
                    )
                    .fixedSize()
            }

            Spacer(minLength: 8)

            // Actions stay on one line — never wrap or truncate mid-label.
            HStack(spacing: 10) {
                if viewModel.repositorySelectedDiffKind != .staged {
                    Button(languageStore.t("review.stage")) { viewModel.stage(path) }
                }
                if viewModel.repositorySelectedDiffKind == .staged {
                    Button(languageStore.t("review.unstage")) { viewModel.unstage(path) }
                }
                openEditorControl(for: path)
                Button(languageStore.t("review.revealFinder")) {
                    viewModel.revealRepositoryFileInFinder(path)
                }
            }
            .font(AppTheme.Font.caption2.weight(.medium))
            .buttonStyle(.borderless)
            .fixedSize(horizontal: true, vertical: false)
            .layoutPriority(2)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
