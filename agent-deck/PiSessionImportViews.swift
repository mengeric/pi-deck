import SwiftUI

// MARK: - Import Pi session sheet

/// Sheet listing on-disk Pi sessions for import into Deck.
///
/// Layout: left directory tree (cwd hierarchy) filters the right session list.
struct PiSessionImportSheet: View {
    var viewModel: AppViewModel
    /// Optional project scope for cwd filtering (nil = all sessions).
    var preferredProject: DiscoveredProject?
    var onDismiss: () -> Void

    @State private var candidates: [PiNativeSessionCandidate] = []
    @State private var treeRoots: [PiNativeSessionTreeNode] = []
    @State private var isLoading = true
    @State private var searchText = ""
    @State private var filterToPreferredProject = false
    /// `PiNativeSessionCatalog.allTreeID` or a directory path / unknown bucket.
    @State private var selectedTreeID: String = PiNativeSessionCatalog.allTreeID
    @State private var importError: String?

    private var boundPaths: Set<String> {
        viewModel.piAgentSessionStore.boundPiSessionFilePaths
    }

    /// Candidates after tree filter, then text search.
    private var filtered: [PiNativeSessionCandidate] {
        let treeFiltered = PiNativeSessionCatalog.filterCandidates(
            candidates,
            selectedTreeID: selectedTreeID
        )
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return treeFiltered }
        return treeFiltered.filter { c in
            c.displayTitle.localizedCaseInsensitiveContains(q)
                || (c.cwd?.localizedCaseInsensitiveContains(q) ?? false)
                || c.filePath.localizedCaseInsensitiveContains(q)
                || (c.previewText?.localizedCaseInsensitiveContains(q) ?? false)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()
            toolbarBar
            if let importError {
                Text(importError)
                    .font(AppTheme.Font.footnote)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 6)
            }
            contentBody
            Divider()
            Text(LanguageStore.shared.t("session.import.footer"))
                .font(AppTheme.Font.caption)
                .foregroundStyle(AppTheme.mutedText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
        }
        .frame(minWidth: 720, idealWidth: 820, minHeight: 460, idealHeight: 560)
        .task { reload() }
    }

    private var headerBar: some View {
        HStack {
            Text(LanguageStore.shared.t("session.import.title"))
                .font(AppTheme.Font.title)
            Spacer()
            Button(LanguageStore.shared.t("common.cancel")) { onDismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var toolbarBar: some View {
        HStack(spacing: 10) {
            TextField(LanguageStore.shared.t("session.import.search"), text: $searchText)
                .textFieldStyle(.roundedBorder)
            if preferredProject != nil {
                Toggle(isOn: $filterToPreferredProject) {
                    Text(LanguageStore.shared.t("session.import.filterProject"))
                        .font(AppTheme.Font.footnote)
                }
                .toggleStyle(.checkbox)
                .onChange(of: filterToPreferredProject) { _, _ in reload() }
            }
            Button(LanguageStore.shared.t("session.import.chooseFile")) {
                viewModel.importPiSessionFromOpenPanel(preferredProject: preferredProject)
                onDismiss()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var contentBody: some View {
        if isLoading {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if candidates.isEmpty {
            ContentUnavailableView {
                Label(
                    LanguageStore.shared.t("session.import.emptyTitle"),
                    systemImage: "tray"
                )
            } description: {
                Text(LanguageStore.shared.t("session.import.emptyBody"))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            HSplitView {
                directoryTreeSidebar
                    .frame(minWidth: 200, idealWidth: 240, maxWidth: 340)
                sessionListPane
                    .frame(minWidth: 320, maxWidth: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var directoryTreeSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(LanguageStore.shared.t("session.import.treeTitle"))
                .font(AppTheme.Font.caption.weight(.semibold))
                .foregroundStyle(AppTheme.mutedText)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    PiSessionImportTreeAllRow(
                        totalCount: candidates.count,
                        isSelected: selectedTreeID == PiNativeSessionCatalog.allTreeID
                    ) {
                        selectedTreeID = PiNativeSessionCatalog.allTreeID
                    }

                    ForEach(treeRoots) { node in
                        PiSessionImportTreeNodeView(
                            node: node,
                            selectedTreeID: $selectedTreeID,
                            depth: 0
                        )
                    }
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 6)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.55))
    }

    @ViewBuilder
    private var sessionListPane: some View {
        if filtered.isEmpty {
            ContentUnavailableView {
                Label(
                    LanguageStore.shared.t("session.import.emptyFilterTitle"),
                    systemImage: "line.3.horizontal.decrease.circle"
                )
            } description: {
                Text(LanguageStore.shared.t("session.import.emptyFilterBody"))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(filtered) { candidate in
                let already = boundPaths.contains(PiNativeSessionCatalog.standardizedPath(candidate.filePath))
                Button {
                    importCandidate(candidate, alreadyImported: already)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(candidate.displayTitle)
                                .font(AppTheme.Font.body.weight(.semibold))
                                .lineLimit(2)
                                .foregroundStyle(already ? AppTheme.mutedText : Color.primary)
                            Spacer()
                            if already {
                                Text(LanguageStore.shared.t("session.import.already"))
                                    .font(AppTheme.Font.caption)
                                    .foregroundStyle(AppTheme.mutedText)
                            }
                        }
                        if let cwd = candidate.cwd, !cwd.isEmpty {
                            Text(cwd)
                                .font(AppTheme.Font.caption)
                                .foregroundStyle(AppTheme.mutedText)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        HStack(spacing: 8) {
                            Text(candidate.modifiedAt.formatted(date: .abbreviated, time: .shortened))
                            if candidate.messageCount > 0 {
                                Text(LanguageStore.shared.t("session.import.messageCount", candidate.messageCount))
                            }
                        }
                        .font(AppTheme.Font.caption2)
                        .foregroundStyle(AppTheme.mutedText)
                    }
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(candidate.filePath)
            }
            .listStyle(.inset)
        }
    }

    /// Reloads the candidate list and rebuilds the directory tree.
    private func reload() {
        isLoading = true
        importError = nil
        let projectPath = (filterToPreferredProject ? preferredProject?.path : nil)
        Task.detached {
            let list = PiNativeSessionCatalog.listCandidates(cwdFilter: projectPath)
            let tree = PiNativeSessionCatalog.directoryTree(from: list)
            await MainActor.run {
                candidates = list
                treeRoots = tree
                // Keep selection if still meaningful; otherwise reset to All.
                if selectedTreeID != PiNativeSessionCatalog.allTreeID,
                   selectedTreeID != PiNativeSessionCatalog.unknownTreeID,
                   !list.contains(where: {
                       guard let cwd = $0.cwd else { return false }
                       let std = PiNativeSessionCatalog.standardizedPath(cwd)
                       return std == selectedTreeID || std.hasPrefix(selectedTreeID + "/")
                   }) {
                    selectedTreeID = PiNativeSessionCatalog.allTreeID
                }
                isLoading = false
            }
        }
    }

    /// Imports or focuses a candidate session.
    private func importCandidate(_ candidate: PiNativeSessionCandidate, alreadyImported: Bool) {
        if alreadyImported {
            _ = viewModel.importPiNativeSession(path: candidate.filePath, preferredProject: preferredProject)
            onDismiss()
            return
        }
        if viewModel.importPiNativeSession(path: candidate.filePath, preferredProject: preferredProject) != nil {
            onDismiss()
        } else {
            importError = viewModel.piAgentSessionStore.lastError
                ?? LanguageStore.shared.t("session.import.errorInvalid")
        }
    }
}

// MARK: - Tree rows

/// Root “All sessions” row in the import directory tree.
private struct PiSessionImportTreeAllRow: View {
    let totalCount: Int
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 6) {
                Image(systemName: "tray.full")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 14)
                Text(LanguageStore.shared.t("session.import.treeAll"))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text("\(totalCount)")
                    .font(AppTheme.Font.caption2)
                    .foregroundStyle(AppTheme.mutedText)
            }
            .font(AppTheme.Font.footnote.weight(.semibold))
            .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.14) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Recursive directory node: click selects filter; disclosure expands children.
private struct PiSessionImportTreeNodeView: View {
    let node: PiNativeSessionTreeNode
    @Binding var selectedTreeID: String
    let depth: Int

    @State private var isExpanded: Bool = false

    private var isSelected: Bool { selectedTreeID == node.id }

    private var displayName: String {
        if node.id == PiNativeSessionCatalog.unknownTreeID {
            return LanguageStore.shared.t("session.import.treeUnknown")
        }
        return node.name
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 2) {
                if node.children.isEmpty {
                    Color.clear.frame(width: 16, height: 16)
                } else {
                    Button {
                        withAnimation(.snappy(duration: 0.15)) {
                            isExpanded.toggle()
                        }
                    } label: {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(AppTheme.mutedText)
                            .frame(width: 16, height: 16)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }

                Button {
                    selectedTreeID = node.id
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: node.id == PiNativeSessionCatalog.unknownTreeID
                              ? "questionmark.folder"
                              : (isExpanded || node.children.isEmpty ? "folder" : "folder.fill"))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(isSelected ? Color.accentColor : AppTheme.mutedText)
                            .frame(width: 14)
                        Text(displayName)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 4)
                        Text("\(node.sessionCount)")
                            .font(AppTheme.Font.caption2)
                            .foregroundStyle(AppTheme.mutedText)
                    }
                    .font(AppTheme.Font.footnote)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(isSelected ? Color.accentColor.opacity(0.14) : Color.clear)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(node.pathPrefix)
            }
            .padding(.leading, CGFloat(depth) * 12)

            if isExpanded {
                ForEach(node.children) { child in
                    PiSessionImportTreeNodeView(
                        node: child,
                        selectedTreeID: $selectedTreeID,
                        depth: depth + 1
                    )
                }
            }
        }
        .onAppear {
            // Auto-expand first two levels so Users/eric… is usable without hunting.
            if depth < 2, !node.children.isEmpty {
                isExpanded = true
            }
        }
    }
}
