import AppKit
import Foundation
import UniformTypeIdentifiers

// MARK: - Import Pi native sessions

extension AppViewModel {
    /// Loads Pi session files under `~/.pi/agent/sessions` for the import sheet.
    ///
    /// - Parameters:
    ///   - projectPath: When non-nil, only candidates whose session `cwd` matches this project.
    /// - Returns: Candidates newest-first (already excludes nothing — UI greys out bound paths).
    func loadPiSessionImportCandidates(projectPath: String? = nil) -> [PiNativeSessionCandidate] {
        let cwdFilter = projectPath.flatMap { path -> String? in
            let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return PiNativeSessionCatalog.listCandidates(
            excludePaths: [],
            cwdFilter: cwdFilter
        )
    }

    /// Whether a candidate path is already bound to a Deck session.
    ///
    /// - Parameter path: Absolute Pi session file path.
    /// - Returns: `true` when some session's `piSessionFile` resolves to the same path.
    func isPiSessionPathAlreadyImported(_ path: String) -> Bool {
        let standardized = PiNativeSessionCatalog.standardizedPath(path)
        return piAgentSessionStore.boundPiSessionFilePaths.contains(standardized)
    }

    /// Opens an `NSOpenPanel` for a single `.jsonl` Pi session file and imports it.
    ///
    /// - Parameter preferredProject: Optional project to attach when cwd cannot be matched.
    func importPiSessionFromOpenPanel(preferredProject: DiscoveredProject? = nil) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json]
        // Also accept bare .jsonl via UTType dynamic / extension filter.
        panel.allowsOtherFileTypes = true
        panel.message = LanguageStore.shared.t("session.import.panelMessage")
        panel.directoryURL = PiNativeSessionCatalog.sessionsRootURL()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        _ = importPiNativeSession(path: url.path, preferredProject: preferredProject)
    }

    /// Imports a Pi native session JSONL into the Deck session list and rebuilds transcript.
    ///
    /// - Parameters:
    ///   - path: Absolute path to the session file.
    ///   - preferredProject: Forces project binding when set; otherwise uses header `cwd` match.
    /// - Returns: The Deck session record (existing or newly created), or `nil` on failure.
    @discardableResult
    func importPiNativeSession(path: String, preferredProject: DiscoveredProject? = nil) -> PiAgentSessionRecord? {
        let standardized = PiNativeSessionCatalog.standardizedPath(path)
        guard FileManager.default.isReadableFile(atPath: standardized) else {
            piAgentSessionStore.lastError = LanguageStore.shared.t("session.import.errorUnreadable")
            return nil
        }
        guard let candidate = PiNativeSessionCatalog.candidate(at: standardized) else {
            piAgentSessionStore.lastError = LanguageStore.shared.t("session.import.errorInvalid")
            return nil
        }

        if let existing = piAgentSessionStore.sessions.first(where: {
            guard let bound = $0.piSessionFile else { return false }
            return PiNativeSessionCatalog.standardizedPath(bound) == standardized
        }) {
            selectedSidebarItem = .agent
            expandCodingAgentPanel()
            uncollapseSessionGroup(existing)
            selectPiAgentSession(existing.id)
            rehydratePiAgentTranscriptIfNeeded(existing.id)
            return existing
        }

        let project: DiscoveredProject? = {
            if let preferredProject { return preferredProject }
            guard let cwd = candidate.cwd, !cwd.isEmpty else { return nil }
            let std = PiNativeSessionCatalog.standardizedPath(cwd)
            return discoveredProjects.first {
                PiNativeSessionCatalog.standardizedPath($0.path) == std
            } ?? projectByPath[std]
        }()

        let title = candidate.displayTitle
        let record: PiAgentSessionRecord
        if let project {
            record = piAgentSessionStore.createSessionFromImportedPiFile(
                filePath: standardized,
                title: title,
                projectPath: project.path,
                projectName: project.name,
                repository: project.gitHubRemote?.nameWithOwner,
                piSessionId: candidate.piSessionId,
                kind: .project
            )
        } else {
            record = piAgentSessionStore.createSessionFromImportedPiFile(
                filePath: standardized,
                title: title,
                projectPath: "",
                projectName: PiAgentSessionRecord.noProjectDisplayName,
                repository: nil,
                piSessionId: candidate.piSessionId,
                kind: .project
            )
        }

        selectedSidebarItem = .agent
        expandCodingAgentPanel()
        uncollapseSessionGroup(record)
        selectPiAgentSession(record.id)
        // Force a full rebuild from Pi's file (empty local transcript).
        piAgentRunner.rehydrateTranscriptFromSessionFileIfNeeded(record)
        return record
    }
}
