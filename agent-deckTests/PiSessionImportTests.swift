import XCTest
@testable import agent_deck

/// Unit tests for Pi session import: path auto-register filters, catalog tree filter,
/// and store-level reference import (no disk ownership / de-dupe).
///
/// Paths are synthetic (`/workspace/...`) or derived from `FileManager` /
/// `NSTemporaryDirectory` so the suite is portable across machines and CI users.
@MainActor
final class PiSessionImportTests: XCTestCase {

    // MARK: - Auto-register path policy

    /// Home, root, and temp/scratch paths must not become Deck projects on import.
    func testShouldAutoRegisterRejectsHomeTempAndScratch() {
        let viewModel = AppViewModel()
        let home = FileManager.default.homeDirectoryForCurrentUser
            .resolvingSymlinksInPath().standardizedFileURL.path
        let tempRoot = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath().standardizedFileURL.path

        XCTAssertFalse(viewModel.shouldAutoRegisterImportedProject(at: "/"))
        XCTAssertFalse(viewModel.shouldAutoRegisterImportedProject(at: ""))
        XCTAssertFalse(viewModel.shouldAutoRegisterImportedProject(at: home))
        XCTAssertFalse(viewModel.shouldAutoRegisterImportedProject(at: "/tmp/foo"))
        XCTAssertFalse(viewModel.shouldAutoRegisterImportedProject(at: "/private/tmp/bar"))
        XCTAssertFalse(viewModel.shouldAutoRegisterImportedProject(at: "/var/folders/xx/session"))
        XCTAssertFalse(viewModel.shouldAutoRegisterImportedProject(at: "/private/var/tmp/x"))
        // Host temp dir often resolves under /var/folders — also reject explicit join.
        XCTAssertFalse(
            viewModel.shouldAutoRegisterImportedProject(at: tempRoot + "/pi-import-scratch")
        )
        XCTAssertFalse(
            viewModel.shouldAutoRegisterImportedProject(
                at: home + "/Library/Application Support/Pi Deck/General Chats/abc"
            )
        )
        XCTAssertFalse(
            viewModel.shouldAutoRegisterImportedProject(
                at: home + "/Library/Application Support/Agent Deck/General Chats/abc"
            )
        )
    }

    /// Normal project directories under the user tree remain eligible for auto-add.
    func testShouldAutoRegisterAcceptsNormalProjectPath() {
        let viewModel = AppViewModel()
        let home = FileManager.default.homeDirectoryForCurrentUser
            .resolvingSymlinksInPath().standardizedFileURL.path
        XCTAssertTrue(
            viewModel.shouldAutoRegisterImportedProject(
                at: home + "/Documents/Projects/example-app"
            )
        )
        // Portable absolute project-like path (no host username).
        XCTAssertTrue(
            viewModel.shouldAutoRegisterImportedProject(
                at: "/opt/src/shared-demo-repo"
            )
        )
    }

    // MARK: - Catalog tree / filter (pure)

    /// Directory tree aggregates session counts by cwd prefix and buckets missing cwd as Unknown.
    func testDirectoryTreeCountsAndUnknownBucket() {
        let now = Date()
        // Synthetic tree roots — not a real host path.
        let appCwd = "/workspace/code/app"
        let otherCwd = "/workspace/other"
        let candidates = [
            makeCandidate(path: "/tmp/sessions/a.jsonl", cwd: appCwd, at: now),
            makeCandidate(path: "/tmp/sessions/b.jsonl", cwd: appCwd, at: now),
            makeCandidate(path: "/tmp/sessions/c.jsonl", cwd: otherCwd, at: now),
            makeCandidate(path: "/tmp/sessions/d.jsonl", cwd: nil, at: now)
        ]

        let roots = PiNativeSessionCatalog.directoryTree(from: candidates)
        XCTAssertEqual(roots.count, 2) // workspace + Unknown

        let workspace = roots.first { $0.name == "workspace" }
        XCTAssertNotNil(workspace)
        XCTAssertEqual(workspace?.sessionCount, 3)
        XCTAssertEqual(workspace?.pathPrefix, "/workspace")

        let unknown = roots.first { $0.pathPrefix == PiNativeSessionCatalog.unknownTreeID }
        XCTAssertEqual(unknown?.sessionCount, 1)
    }

    /// Filtering by pathPrefix keeps descendants; unknown filter isolates missing cwd.
    func testFilterCandidatesByTreeSelection() {
        let now = Date()
        let appCwd = "/workspace/code/app"
        let otherCwd = "/workspace/other"
        let candidates = [
            makeCandidate(path: "session-a", cwd: appCwd, at: now),
            makeCandidate(path: "session-b", cwd: otherCwd, at: now),
            makeCandidate(path: "session-c", cwd: nil, at: now)
        ]

        let underCode = PiNativeSessionCatalog.filterCandidates(
            candidates,
            selectedTreeID: "/workspace/code"
        )
        XCTAssertEqual(underCode.map(\.filePath), ["session-a"])

        let unknownOnly = PiNativeSessionCatalog.filterCandidates(
            candidates,
            selectedTreeID: PiNativeSessionCatalog.unknownTreeID
        )
        XCTAssertEqual(unknownOnly.map(\.filePath), ["session-c"])

        let all = PiNativeSessionCatalog.filterCandidates(
            candidates,
            selectedTreeID: PiNativeSessionCatalog.allTreeID
        )
        XCTAssertEqual(all.count, 3)
    }

    // MARK: - Store import ownership

    /// Imported sessions bind `piSessionFile` without adding it to `ownedPiSessionFiles`.
    func testImportedSessionDoesNotOwnPiFile() throws {
        let store = PiAgentSessionStore(fileURL: PiTestSupport.temporaryStateFile())
        let project = try PiTestSupport.makeProject()
        let filePath = FileManager.default.temporaryDirectory
            .appendingPathComponent("pi-import-tests-\(UUID().uuidString).jsonl")
            .path

        let record = store.createSessionFromImportedPiFile(
            filePath: filePath,
            title: "Imported",
            projectPath: project.path,
            projectName: project.name,
            repository: nil,
            piSessionId: "sess-1",
            kind: .project
        )

        let standardized = URL(fileURLWithPath: filePath)
            .resolvingSymlinksInPath().standardizedFileURL.path
        XCTAssertEqual(record.piSessionFile, standardized)
        XCTAssertFalse(record.ownedPiSessionFiles.contains(standardized))
        XCTAssertTrue(record.ownedPiSessionFiles.isEmpty)
        XCTAssertEqual(store.selectedSessionID, record.id)
        XCTAssertTrue(store.boundPiSessionFilePaths.contains(standardized))
    }

    /// Re-importing the same path returns the existing session instead of duplicating.
    func testImportSamePathDedupes() throws {
        let store = PiAgentSessionStore(fileURL: PiTestSupport.temporaryStateFile())
        let project = try PiTestSupport.makeProject()
        let filePath = FileManager.default.temporaryDirectory
            .appendingPathComponent("pi-import-tests-\(UUID().uuidString).jsonl")
            .path

        let first = store.createSessionFromImportedPiFile(
            filePath: filePath,
            title: "First",
            projectPath: project.path,
            projectName: project.name,
            repository: nil,
            piSessionId: "sess-1",
            kind: .project
        )
        let second = store.createSessionFromImportedPiFile(
            filePath: filePath,
            title: "Second",
            projectPath: project.path,
            projectName: project.name,
            repository: nil,
            piSessionId: "sess-1",
            kind: .project
        )

        XCTAssertEqual(first.id, second.id)
        XCTAssertEqual(store.sessions.filter { $0.piSessionFile != nil }.count, 1)
    }

    /// Default `recordPiSessionFile` owns the path; import path with `ownsFile: false` does not.
    func testRecordPiSessionFileOwnershipFlag() throws {
        var owned = try PiTestSupport.makeParentSession(piSessionFile: nil)
        owned.ownedPiSessionFiles = []
        owned.recordPiSessionFile("/sessions/owned.jsonl", ownsFile: true)
        XCTAssertEqual(owned.piSessionFile, "/sessions/owned.jsonl")
        XCTAssertTrue(owned.ownedPiSessionFiles.contains("/sessions/owned.jsonl"))

        var imported = try PiTestSupport.makeParentSession(piSessionFile: nil)
        imported.ownedPiSessionFiles = []
        imported.recordPiSessionFile("/sessions/imported.jsonl", ownsFile: false)
        XCTAssertEqual(imported.piSessionFile, "/sessions/imported.jsonl")
        XCTAssertFalse(imported.ownedPiSessionFiles.contains("/sessions/imported.jsonl"))
    }

    // MARK: - Helpers

    /// Builds a minimal catalog candidate for pure tree/filter tests.
    ///
    /// - Parameters:
    ///   - path: Fake session file path (identity; need not exist on disk).
    ///   - cwd: Optional working directory from session header.
    ///   - at: Timestamp for modified/created.
    /// - Returns: Candidate suitable for catalog pure functions.
    private func makeCandidate(path: String, cwd: String?, at: Date) -> PiNativeSessionCandidate {
        PiNativeSessionCandidate(
            filePath: path,
            piSessionId: nil,
            cwd: cwd,
            createdAt: at,
            modifiedAt: at,
            displayTitle: path,
            previewText: cwd ?? "",
            messageCount: 1
        )
    }
}
