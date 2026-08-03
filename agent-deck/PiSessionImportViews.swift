import SwiftUI

// MARK: - Import Pi session sheet

/// Sheet listing on-disk Pi sessions for import into Deck.
struct PiSessionImportSheet: View {
    var viewModel: AppViewModel
    /// Optional project scope for cwd filtering (nil = all sessions).
    var preferredProject: DiscoveredProject?
    var onDismiss: () -> Void

    @State private var candidates: [PiNativeSessionCandidate] = []
    @State private var isLoading = true
    @State private var searchText = ""
    @State private var filterToPreferredProject = false
    @State private var importError: String?

    private var boundPaths: Set<String> {
        viewModel.piAgentSessionStore.boundPiSessionFilePaths
    }

    private var filtered: [PiNativeSessionCandidate] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return candidates }
        return candidates.filter { c in
            c.displayTitle.localizedCaseInsensitiveContains(q)
                || (c.cwd?.localizedCaseInsensitiveContains(q) ?? false)
                || c.filePath.localizedCaseInsensitiveContains(q)
                || (c.previewText?.localizedCaseInsensitiveContains(q) ?? false)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(LanguageStore.shared.t("session.import.title"))
                    .font(AppTheme.Font.title)
                Spacer()
                Button(LanguageStore.shared.t("common.cancel")) { onDismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

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

            if let importError {
                Text(importError)
                    .font(AppTheme.Font.footnote)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
            }

            if isLoading {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filtered.isEmpty {
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

            Divider()
            Text(LanguageStore.shared.t("session.import.footer"))
                .font(AppTheme.Font.caption)
                .foregroundStyle(AppTheme.mutedText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
        }
        .frame(minWidth: 520, idealWidth: 560, minHeight: 420, idealHeight: 520)
        .task { reload() }
    }

    /// Reloads the candidate list off the main actor probe path.
    private func reload() {
        isLoading = true
        importError = nil
        let projectPath = (filterToPreferredProject ? preferredProject?.path : nil)
        Task.detached {
            let list = PiNativeSessionCatalog.listCandidates(cwdFilter: projectPath)
            await MainActor.run {
                candidates = list
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
