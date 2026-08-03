import Foundation

// MARK: - Pi native session discovery (import)

/// One on-disk Pi coding-agent session file that can be imported into Deck.
///
/// - Parameters: N/A (value type). Fields document disk metadata for the import UI.
nonisolated struct PiNativeSessionCandidate: Identifiable, Hashable, Sendable {
    /// Stable identity for lists (`filePath`).
    var id: String { filePath }
    /// Absolute path to the `.jsonl` session file.
    let filePath: String
    /// Header `id` when present.
    let piSessionId: String?
    /// Header `cwd` when present (working directory of the Pi session).
    let cwd: String?
    /// Header or filename timestamp when parseable.
    let createdAt: Date?
    /// File modification time for sorting.
    let modifiedAt: Date
    /// Short UI title (first user line, else session id / file name).
    let displayTitle: String
    /// Preview of the first user message body when found.
    let previewText: String?
    /// Approximate user+assistant message count from a capped scan.
    let messageCount: Int
}

/// A node in the import sidebar directory tree (built from session `cwd` paths).
///
/// - Parameters: N/A (value type). `pathPrefix` is the absolute directory used to filter.
nonisolated struct PiNativeSessionTreeNode: Identifiable, Hashable, Sendable {
    /// Absolute path prefix (or synthetic id for buckets like "unknown").
    let id: String
    /// Last path component for the row label.
    let name: String
    /// Absolute directory path used as a filter prefix (`cwd` starts with this).
    let pathPrefix: String
    /// Child directories, sorted by name.
    var children: [PiNativeSessionTreeNode]
    /// Number of session files under this node (including descendants).
    var sessionCount: Int
}

/// Enumerates and lightly parses Pi session JSONL under `~/.pi/agent/sessions`.
enum PiNativeSessionCatalog {
    /// Synthetic tree id for sessions with no usable `cwd`.
    nonisolated static let unknownTreeID = "__pi_session_import_unknown__"
    /// Synthetic tree id for "show all".
    nonisolated static let allTreeID = "__pi_session_import_all__"
    /// Maximum bytes read when probing a candidate for title/messages.
    nonisolated private static let probeByteLimit = 256 * 1024
    /// Maximum lines scanned inside the probe window.
    nonisolated private static let probeLineLimit = 400

    /// Default Pi sessions root (`$PI_CODING_AGENT_DIR/sessions` or `~/.pi/agent/sessions`).
    ///
    /// - Returns: Directory URL for native session trees.
    nonisolated static func sessionsRootURL() -> URL {
        if let env = ProcessInfo.processInfo.environment["PI_CODING_AGENT_DIR"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !env.isEmpty {
            return URL(fileURLWithPath: env, isDirectory: true)
                .appendingPathComponent("sessions", isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".pi/agent/sessions", isDirectory: true)
    }

    /// Lists importable Pi session files, newest first.
    ///
    /// - Parameters:
    ///   - root: Optional override of the sessions directory.
    ///   - excludePaths: Absolute paths already bound in Deck (skipped or marked by caller).
    ///   - cwdFilter: When non-nil, only keep candidates whose header cwd matches after standardization.
    /// - Returns: Candidates sorted by `modifiedAt` descending.
    nonisolated static func listCandidates(
        root: URL? = nil,
        excludePaths: Set<String> = [],
        cwdFilter: String? = nil
    ) -> [PiNativeSessionCandidate] {
        let fm = FileManager.default
        let rootURL = (root ?? sessionsRootURL()).resolvingSymlinksInPath().standardizedFileURL
        guard let enumerator = fm.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        let filterCwd = cwdFilter.map { standardizedPath($0) }
        var results: [PiNativeSessionCandidate] = []
        results.reserveCapacity(64)

        for case let url as URL in enumerator {
            guard url.pathExtension.lowercased() == "jsonl" else { continue }
            let path = url.resolvingSymlinksInPath().standardizedFileURL.path
            if excludePaths.contains(path) { continue }
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]),
                  values.isRegularFile == true else { continue }
            let size = values.fileSize ?? 0
            // Skip empty placeholders / ghost sessions.
            if size < 8 { continue }
            let modified = values.contentModificationDate ?? .distantPast
            if let candidate = probe(path: path, modifiedAt: modified) {
                if let filterCwd {
                    let candidateCwd = candidate.cwd.map { standardizedPath($0) }
                    guard candidateCwd == filterCwd else { continue }
                }
                results.append(candidate)
            }
        }

        results.sort { lhs, rhs in
            if lhs.modifiedAt != rhs.modifiedAt { return lhs.modifiedAt > rhs.modifiedAt }
            return lhs.filePath > rhs.filePath
        }
        return results
    }

    /// Builds a single candidate from an absolute path (file picker / open panel).
    ///
    /// - Parameter path: Absolute path to a `.jsonl` file.
    /// - Returns: Candidate or `nil` if unreadable / not a session-like file.
    nonisolated static func candidate(at path: String) -> PiNativeSessionCandidate? {
        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
        guard url.pathExtension.lowercased() == "jsonl" else { return nil }
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? .distantPast
        return probe(path: url.path, modifiedAt: modified)
    }

    /// Reads a capped prefix of the JSONL and extracts header + first user preview.
    ///
    /// - Parameters:
    ///   - path: Absolute session file path.
    ///   - modifiedAt: File mtime for the candidate.
    /// - Returns: Candidate when at least one JSON object can be decoded.
    nonisolated private static func probe(path: String, modifiedAt: Date) -> PiNativeSessionCandidate? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let data: Data
        do {
            if #available(macOS 10.15.4, *) {
                data = try handle.read(upToCount: probeByteLimit) ?? Data()
            } else {
                data = handle.readData(ofLength: probeByteLimit)
            }
        } catch {
            return nil
        }
        guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return nil }

        let decoder = JSONDecoder()
        var piSessionId: String?
        var cwd: String?
        var createdAt: Date?
        var firstUser: String?
        var messageCount = 0
        var sawAnyObject = false

        for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: true).enumerated() {
            if index >= probeLineLimit { break }
            guard let lineData = line.data(using: .utf8),
                  let object = try? decoder.decode(JSONValue.self, from: lineData) else { continue }
            sawAnyObject = true
            let type = object["type"]?.stringValue
            if type == "session" {
                piSessionId = object["id"]?.stringValue ?? piSessionId
                cwd = object["cwd"]?.stringValue ?? cwd
                if let ts = object["timestamp"]?.stringValue {
                    createdAt = parseISO8601(ts) ?? createdAt
                }
            }
            // Message envelopes: either top-level role or nested `message`.
            let message = object["message"] ?? object
            if let role = message["role"]?.stringValue {
                if role == "user" || role == "assistant" {
                    messageCount += 1
                }
                if role == "user", firstUser == nil {
                    let body = extractUserText(from: message)
                    if !body.isEmpty { firstUser = body }
                }
            }
        }

        guard sawAnyObject else { return nil }

        let fileName = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        let preview = firstUser.map { collapseWhitespace($0) }
        let title: String = {
            if let preview, !preview.isEmpty {
                return String(preview.prefix(80))
            }
            if let piSessionId, !piSessionId.isEmpty {
                return "Pi · \(piSessionId.prefix(8))"
            }
            return fileName
        }()

        return PiNativeSessionCandidate(
            filePath: path,
            piSessionId: piSessionId,
            cwd: cwd,
            createdAt: createdAt,
            modifiedAt: modifiedAt,
            displayTitle: title,
            previewText: preview,
            messageCount: messageCount
        )
    }

    /// Extracts plain text from a user message JSON value.
    nonisolated private static func extractUserText(from message: JSONValue) -> String {
        if let content = message["content"]?.stringValue, !content.isEmpty {
            return content
        }
        guard case let .array(blocks) = message["content"] else { return "" }
        var parts: [String] = []
        for block in blocks {
            if let t = block["text"]?.stringValue, !t.isEmpty {
                parts.append(t)
            } else if block["type"]?.stringValue == "text", let t = block["text"]?.stringValue {
                parts.append(t)
            }
        }
        return parts.joined(separator: "\n")
    }

    nonisolated private static func collapseWhitespace(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated private static func parseISO8601(_ raw: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFraction.date(from: raw) { return d }
        let basic = ISO8601DateFormatter()
        basic.formatOptions = [.withInternetDateTime]
        return basic.date(from: raw)
    }

    /// Standardizes a filesystem path for cwd comparison.
    nonisolated static func standardizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// Builds a directory tree from candidates' `cwd` values for sidebar filtering.
    ///
    /// - Parameter candidates: Session files already probed from disk.
    /// - Returns: Root children (not including the synthetic "All" row).
    nonisolated static func directoryTree(from candidates: [PiNativeSessionCandidate]) -> [PiNativeSessionTreeNode] {
        // pathPrefix -> (name, count, child names)
        var counts: [String: Int] = [:]
        var childNames: [String: Set<String>] = [:]
        var nameByPrefix: [String: String] = ["/": "/"]
        var unknownCount = 0

        for candidate in candidates {
            guard let rawCwd = candidate.cwd?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !rawCwd.isEmpty else {
                unknownCount += 1
                continue
            }
            let cwd = standardizedPath(rawCwd)
            let components = URL(fileURLWithPath: cwd).pathComponents.filter { $0 != "/" }
            guard !components.isEmpty else {
                unknownCount += 1
                continue
            }

            var built = ""
            var parent = "/"
            for component in components {
                built += "/" + component
                nameByPrefix[built] = component
                counts[built, default: 0] += 1
                childNames[parent, default: []].insert(component)
                parent = built
            }
        }

        func build(prefix: String) -> PiNativeSessionTreeNode {
            let name = nameByPrefix[prefix] ?? URL(fileURLWithPath: prefix).lastPathComponent
            let childComponents = (childNames[prefix] ?? []).sorted {
                $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
            }
            let kids: [PiNativeSessionTreeNode] = childComponents.map { component in
                let childPrefix = prefix == "/" ? "/" + component : prefix + "/" + component
                return build(prefix: childPrefix)
            }
            return PiNativeSessionTreeNode(
                id: prefix,
                name: name,
                pathPrefix: prefix,
                children: kids,
                sessionCount: counts[prefix] ?? kids.reduce(0) { $0 + $1.sessionCount }
            )
        }

        let topNames = (childNames["/"] ?? []).sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
        var roots = topNames.map { build(prefix: "/" + $0) }

        if unknownCount > 0 {
            roots.append(
                PiNativeSessionTreeNode(
                    id: unknownTreeID,
                    name: "Unknown",
                    pathPrefix: unknownTreeID,
                    children: [],
                    sessionCount: unknownCount
                )
            )
        }
        return roots
    }

    /// Filters candidates by a selected tree node (path prefix or unknown bucket).
    ///
    /// - Parameters:
    ///   - candidates: Full candidate list.
    ///   - selectedTreeID: `allTreeID`, `unknownTreeID`, or an absolute directory path.
    /// - Returns: Candidates matching the selection.
    nonisolated static func filterCandidates(
        _ candidates: [PiNativeSessionCandidate],
        selectedTreeID: String?
    ) -> [PiNativeSessionCandidate] {
        guard let selectedTreeID, !selectedTreeID.isEmpty, selectedTreeID != allTreeID else {
            return candidates
        }
        if selectedTreeID == unknownTreeID {
            return candidates.filter {
                guard let cwd = $0.cwd?.trimmingCharacters(in: .whitespacesAndNewlines), !cwd.isEmpty else {
                    return true
                }
                return false
            }
        }
        let prefix = selectedTreeID.hasSuffix("/") ? String(selectedTreeID.dropLast()) : selectedTreeID
        return candidates.filter { candidate in
            guard let cwdRaw = candidate.cwd, !cwdRaw.isEmpty else { return false }
            let cwd = standardizedPath(cwdRaw)
            return cwd == prefix || cwd.hasPrefix(prefix + "/")
        }
    }
}
