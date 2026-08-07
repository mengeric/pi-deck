import AppKit
import CryptoKit
import WebKit

// MARK: - Source codec (mermaid-hash + clean body)

/// Parses fenced diagram bodies used in agent transcripts and markdown cards.
///
/// Supports optional cache fingerprints:
/// ```text
/// %% mermaid-hash: e0739422
/// flowchart LR
///   A --> B
/// ```
/// When multiple hash lines exist, **the last one wins**. All hash lines are
/// stripped before rendering.
enum DiagramSourceCodec {
    private static let hashLine = try! NSRegularExpression(
        pattern: #"^\s*%%\s*mermaid-hash:\s*([0-9a-fA-F]+)\s*$"#,
        options: [.anchorsMatchLines]
    )

    /// Splits a mermaid fence body into cache key + render source.
    ///
    /// - Parameter raw: Raw fence body (may include hash comments).
    /// - Returns: `cacheKey` (last hash or content digest) and `diagramSource` for mermaid.js.
    static func mermaidKeyAndBody(from raw: String) -> (cacheKey: String, diagramSource: String) {
        let normalized = raw.replacingOccurrences(of: "\r\n", with: "\n")
        var lastHash: String?
        var body: [String] = []
        for line in normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            if let match = hashLine.firstMatch(in: line, options: [], range: range),
               match.numberOfRanges >= 2,
               let hr = Range(match.range(at: 1), in: line) {
                lastHash = String(line[hr]).lowercased()
                continue
            }
            body.append(line)
        }
        // Drop leading/trailing blank lines so digest is stable.
        while body.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { body.removeFirst() }
        while body.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { body.removeLast() }
        let diagramSource = body.joined(separator: "\n")
        let cacheKey = lastHash ?? shortDigest(diagramSource)
        return (cacheKey, diagramSource)
    }

    /// Normalizes an SVG fence body (trim, ensure root element when possible).
    ///
    /// - Parameter raw: Fence body labeled `svg`.
    /// - Returns: SVG markup suitable for WebKit display.
    static func normalizedSVG(from raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Allow accidental ```xml wrappers that only contain an <svg>…
        if !s.lowercased().contains("<svg"), s.contains("<SVG") {
            s = s.replacingOccurrences(of: "<SVG", with: "<svg").replacingOccurrences(of: "</SVG>", with: "</svg>")
        }
        return s
    }

    /// Short stable digest for cache keys when authors omit `mermaid-hash`.
    ///
    /// - Parameter text: Diagram source without hash lines.
    /// - Returns: 8-character hex prefix of SHA256.
    static func shortDigest(_ text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.prefix(4).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Disk / memory SVG cache

/// Caches rendered SVG strings keyed by diagram identity + theme.
///
/// Used so scrolling back over a mermaid block does not re-enter mermaid.js / JSC.
@MainActor
enum DiagramSVGCache {
    private static var memory: [String: String] = [:]
    private static var order: [String] = []
    private static let memoryLimit = 64

    private static var directory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("PiDeck/DiagramSVG", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Looks up a cached SVG document.
    ///
    /// - Parameters:
    ///   - kind: `"mermaid"` or `"svg"`.
    ///   - key: Hash / digest.
    ///   - dark: Appearance bit.
    /// - Returns: SVG markup when present.
    static func svg(kind: String, key: String, dark: Bool) -> String? {
        let id = cacheID(kind: kind, key: key, dark: dark)
        if let hit = memory[id] { return hit }
        let url = directory.appendingPathComponent(id + ".svg")
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8),
              !text.isEmpty else { return nil }
        storeMemory(id: id, svg: text)
        return text
    }

    /// Persists SVG markup for a diagram key.
    ///
    /// - Parameters:
    ///   - svg: Rendered SVG document.
    ///   - kind: `"mermaid"` or `"svg"`.
    ///   - key: Hash / digest.
    ///   - dark: Appearance bit.
    static func store(svg: String, kind: String, key: String, dark: Bool) {
        let id = cacheID(kind: kind, key: key, dark: dark)
        storeMemory(id: id, svg: svg)
        let url = directory.appendingPathComponent(id + ".svg")
        try? svg.data(using: .utf8)?.write(to: url, options: .atomic)
    }

    private static func cacheID(kind: String, key: String, dark: Bool) -> String {
        "\(kind)_\(key)_\(dark ? "d" : "l")"
    }

    private static func storeMemory(id: String, svg: String) {
        if memory[id] == nil {
            order.append(id)
        }
        memory[id] = svg
        while order.count > memoryLimit {
            let drop = order.removeFirst()
            memory[drop] = nil
        }
    }
}

// MARK: - Mermaid engine (lazy WK + bundled mermaid.min.js)

/// Renders mermaid source to SVG via a single pooled `WKWebView`.
///
/// The engine is created on first use and can be released with ``releaseEngine()``
/// to drop JavaScriptCore after idle (same spirit as Highlightr Phase A).
@MainActor
final class MermaidDiagramEngine: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    static let shared = MermaidDiagramEngine()

    private var webView: WKWebView?
    /// Keeps a hidden window so WK actually runs JS (off-hierarchy views can stall).
    private var hostWindow: NSWindow?
    private var pending: CheckedContinuation<String, Error>?
    private var generation = 0
    private var isDocumentReady = false
    private var readyWaiters: [CheckedContinuation<Void, Never>] = []

    private override init() { super.init() }

    /// Whether the pooled WebView (and mermaid.js) is currently loaded.
    var isEngineLoaded: Bool { webView != nil }

    /// Releases the WebView so JSC/WebKit can be reclaimed.
    func releaseEngine() {
        generation &+= 1
        if let pending {
            self.pending = nil
            pending.resume(throwing: CancellationError())
        }
        readyWaiters.removeAll()
        isDocumentReady = false
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "mermaidDone")
        webView?.navigationDelegate = nil
        webView?.stopLoading()
        webView = nil
        hostWindow?.contentView = nil
        hostWindow?.close()
        hostWindow = nil
    }

    /// Renders mermaid source to an SVG document string.
    ///
    /// - Parameters:
    ///   - source: Clean mermaid body (no hash comments).
    ///   - dark: Prefer dark theme tokens.
    /// - Returns: SVG markup.
    /// - Throws: When mermaid.js is missing, render fails, or the call is cancelled.
    func renderSVG(source: String, dark: Bool) async throws -> String {
        let (key, body) = DiagramSourceCodec.mermaidKeyAndBody(from: source)
        if let cached = DiagramSVGCache.svg(kind: "mermaid", key: key, dark: dark) {
            return cached
        }
        let engine = try ensureWebView()
        try await waitUntilDocumentReady(timeoutSeconds: 4)
        // Extra beat after didFinish — mermaid.min.js is large and may still parse.
        try? await Task.sleep(nanoseconds: 50_000_000)
        generation &+= 1
        let token = generation
        let svg: String = try await withCheckedThrowingContinuation { cont in
            if let previous = pending {
                pending = nil
                previous.resume(throwing: CancellationError())
            }
            pending = cont
            let payload = Self.jsStringLiteral(body)
            let theme = dark ? "dark" : "default"
            let js = """
            (async function() {
              try {
                if (typeof mermaid === 'undefined') {
                  window.webkit.messageHandlers.mermaidDone.postMessage({
                    ok: false, error: 'mermaid global missing'
                  });
                  return;
                }
                mermaid.initialize({
                  startOnLoad: false,
                  securityLevel: 'strict',
                  theme: '\(theme)',
                  fontFamily: '-apple-system, BlinkMacSystemFont, sans-serif'
                });
                const id = 'mmd_' + Date.now();
                const out = await mermaid.render(id, \(payload));
                window.webkit.messageHandlers.mermaidDone.postMessage({ ok: true, svg: out.svg });
              } catch (e) {
                window.webkit.messageHandlers.mermaidDone.postMessage({
                  ok: false,
                  error: String(e && e.message ? e.message : e)
                });
              }
            })();
            """
            engine.evaluateJavaScript(js) { [weak self] _, error in
                guard let self else { return }
                if let error {
                    Task { @MainActor in
                        guard self.generation == token else { return }
                        if let pending = self.pending {
                            self.pending = nil
                            pending.resume(throwing: error)
                        }
                    }
                }
            }
        }
        guard generation == token else { throw CancellationError() }
        DiagramSVGCache.store(svg: svg, kind: "mermaid", key: key, dark: dark)
        return svg
    }

    private func ensureWebView() throws -> WKWebView {
        if let webView { return webView }
        guard let jsURL = Bundle.main.url(forResource: "mermaid.min", withExtension: "js", subdirectory: "DiagramVendor")
                ?? Bundle.main.url(forResource: "mermaid.min", withExtension: "js") else {
            throw DiagramRenderError.mermaidJSMissing
        }
        let js = try String(contentsOf: jsURL, encoding: .utf8)
        let controller = WKUserContentController()
        controller.add(self, name: "mermaidDone")
        let config = WKWebViewConfiguration()
        config.userContentController = controller
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 32, height: 32), configuration: config)
        view.navigationDelegate = self
        view.setValue(false, forKey: "drawsBackground")
        // Must live in a window or JS evaluation / didFinish can stall on macOS.
        let window = NSWindow(
            contentRect: NSRect(x: -10_000, y: -10_000, width: 32, height: 32),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.contentView = view
        window.orderBack(nil)
        hostWindow = window
        isDocumentReady = false
        webView = view
        let html = """
        <!DOCTYPE html><html><head><meta charset="utf-8">
        <script>\(js)</script>
        </head><body></body></html>
        """
        view.loadHTMLString(html, baseURL: jsURL.deletingLastPathComponent())
        return view
    }

    /// Waits for the engine document to finish loading, or fails after `timeoutSeconds`.
    private func waitUntilDocumentReady(timeoutSeconds: Double) async throws {
        if isDocumentReady { return }
        let timeoutNanos = UInt64(timeoutSeconds * 1_000_000_000)
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            if self.isDocumentReady {
                cont.resume()
                return
            }
            self.readyWaiters.append(cont)
            DispatchQueue.main.asyncAfter(deadline: .now() + timeoutSeconds) { [weak self] in
                guard let self, !self.isDocumentReady else { return }
                // Unblock waiters so render can surface a clear error instead of hanging.
                let waiters = self.readyWaiters
                self.readyWaiters.removeAll()
                for w in waiters { w.resume() }
            }
        }
        if !isDocumentReady {
            // Consume the sleep deadline without unused-variable noise.
            _ = timeoutNanos
            throw DiagramRenderError.mermaidFailed("Timed out loading mermaid engine")
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isDocumentReady = true
        let waiters = readyWaiters
        readyWaiters.removeAll()
        for w in waiters { w.resume() }
    }

    /// - Note: First render after cold load waits for document ready.
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "mermaidDone" else { return }
        guard let pending else { return }
        self.pending = nil
        guard let body = message.body as? [String: Any] else {
            pending.resume(throwing: DiagramRenderError.invalidBridgePayload)
            return
        }
        if body["ok"] as? Bool == true, let svg = body["svg"] as? String, !svg.isEmpty {
            pending.resume(returning: svg)
        } else {
            let err = (body["error"] as? String) ?? "Mermaid render failed"
            pending.resume(throwing: DiagramRenderError.mermaidFailed(err))
        }
    }

    private static func jsStringLiteral(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
        return "'\(escaped)'"
    }
}

/// Errors from diagram rendering.
enum DiagramRenderError: LocalizedError {
    case mermaidJSMissing
    case mermaidFailed(String)
    case invalidBridgePayload
    case emptySVG

    var errorDescription: String? {
        // Keep nonisolated (LocalizedError); UI maps keys via LanguageStore where shown.
        switch self {
        case .mermaidJSMissing:
            return "mermaid.min.js is missing from the app bundle"
        case .mermaidFailed(let message):
            return message
        case .invalidBridgePayload, .emptySVG:
            return "Diagram render failed"
        }
    }
}

// MARK: - Native block views

/// Displays static SVG markup in a non-interactive WebView (no mermaid.js).
final class StaticSVGBlockView: NSView, WKNavigationDelegate {
    private let webView: WKWebView
    private var heightConstraint: NSLayoutConstraint!
    private var lastSVG: String = ""

    /// - Parameter preferredMinHeight: Initial height before content measures.
    override init(frame frameRect: NSRect) {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        webView = WKWebView(frame: .zero, configuration: config)
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.navigationDelegate = self
        webView.setValue(false, forKey: "drawsBackground")
        webView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        addSubview(webView)
        heightConstraint = heightAnchor.constraint(equalToConstant: 120)
        heightConstraint.priority = .defaultHigh
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor),
            webView.topAnchor.constraint(equalTo: topAnchor),
            webView.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightConstraint
        ])
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Loads SVG markup and measures intrinsic height via JS.
    ///
    /// - Parameter svg: Full SVG document or fragment.
    func setSVG(_ svg: String) {
        let trimmed = svg.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != lastSVG else { return }
        lastSVG = trimmed
        let html = """
        <!DOCTYPE html><html><head><meta charset="utf-8">
        <style>
          html,body{margin:0;padding:8px;background:transparent;overflow:hidden;}
          svg{max-width:100%;height:auto;display:block;}
        </style></head><body>\(trimmed)</body></html>
        """
        webView.loadHTMLString(html, baseURL: nil)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        webView.evaluateJavaScript(
            "Math.ceil(Math.max(document.body.scrollHeight, document.documentElement.scrollHeight))"
        ) { [weak self] result, _ in
            guard let self else { return }
            let h = (result as? CGFloat) ?? (result as? Double).map { CGFloat($0) } ?? 120
            let clamped = min(max(h + 4, 48), 720)
            DispatchQueue.main.async {
                self.heightConstraint.constant = clamped
                self.invalidateIntrinsicContentSize()
                self.window?.contentView?.needsLayout = true
            }
        }
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: heightConstraint.constant)
    }
}

/// Mermaid fence block: cache → engine → static SVG view; falls back to mono source.
final class MermaidBlockView: NSView {
    private let svgView = StaticSVGBlockView(frame: .zero)
    private let fallback = NSTextView()
    private let status = NSTextField(labelWithString: "")
    private var workItem: DispatchWorkItem?
    private var lastRaw = ""

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        svgView.translatesAutoresizingMaskIntoConstraints = false
        status.translatesAutoresizingMaskIntoConstraints = false
        status.font = NSFont.systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail

        fallback.isEditable = false
        fallback.isSelectable = true
        fallback.drawsBackground = false
        fallback.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        fallback.textColor = .labelColor
        fallback.translatesAutoresizingMaskIntoConstraints = false

        addSubview(status)
        addSubview(svgView)
        addSubview(fallback)
        fallback.isHidden = true
        svgView.isHidden = true

        NSLayoutConstraint.activate([
            status.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            status.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            status.topAnchor.constraint(equalTo: topAnchor, constant: 2),

            svgView.leadingAnchor.constraint(equalTo: leadingAnchor),
            svgView.trailingAnchor.constraint(equalTo: trailingAnchor),
            svgView.topAnchor.constraint(equalTo: status.bottomAnchor, constant: 4),
            svgView.bottomAnchor.constraint(equalTo: bottomAnchor),

            fallback.leadingAnchor.constraint(equalTo: leadingAnchor),
            fallback.trailingAnchor.constraint(equalTo: trailingAnchor),
            fallback.topAnchor.constraint(equalTo: status.bottomAnchor, constant: 4),
            fallback.bottomAnchor.constraint(equalTo: bottomAnchor),
            fallback.heightAnchor.constraint(greaterThanOrEqualToConstant: 48)
        ])
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Configures the block from a mermaid fence body.
    ///
    /// - Parameter raw: Fence body (may include `%% mermaid-hash:` lines).
    func configure(raw: String) {
        guard raw != lastRaw else { return }
        lastRaw = raw
        workItem?.cancel()
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let (key, body) = DiagramSourceCodec.mermaidKeyAndBody(from: raw)
        status.stringValue = LanguageStore.shared.t("diagram.mermaid")
        if let cached = DiagramSVGCache.svg(kind: "mermaid", key: key, dark: dark) {
            showSVG(cached)
            return
        }
        status.stringValue = LanguageStore.shared.t("diagram.rendering")
        svgView.isHidden = true
        fallback.isHidden = true
        let item = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self, self.lastRaw == raw else { return }
                // Allow WK document + mermaid.min.js to finish loading on cold start.
                try? await Task.sleep(nanoseconds: 80_000_000)
                do {
                    let svg = try await MermaidDiagramEngine.shared.renderSVG(source: raw, dark: dark)
                    guard self.lastRaw == raw else { return }
                    self.showSVG(svg)
                } catch is CancellationError {
                    return
                } catch {
                    guard self.lastRaw == raw else { return }
                    self.showFallback(body: body, error: error.localizedDescription)
                }
            }
        }
        workItem = item
        DispatchQueue.main.async(execute: item)
    }

    private func showSVG(_ svg: String) {
        status.stringValue = LanguageStore.shared.t("diagram.mermaid")
        fallback.isHidden = true
        svgView.isHidden = false
        svgView.setSVG(svg)
    }

    private func showFallback(body: String, error: String) {
        status.stringValue = error
        svgView.isHidden = true
        fallback.isHidden = false
        fallback.string = body
    }
}

/// SVG fence block (raw SVG markup).
final class SVGFenceBlockView: NSView {
    private let svgView = StaticSVGBlockView(frame: .zero)
    private let fallback = NSTextView()
    private var lastRaw = ""

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        svgView.translatesAutoresizingMaskIntoConstraints = false
        fallback.translatesAutoresizingMaskIntoConstraints = false
        fallback.isEditable = false
        fallback.isSelectable = true
        fallback.drawsBackground = false
        fallback.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        addSubview(svgView)
        addSubview(fallback)
        fallback.isHidden = true
        NSLayoutConstraint.activate([
            svgView.leadingAnchor.constraint(equalTo: leadingAnchor),
            svgView.trailingAnchor.constraint(equalTo: trailingAnchor),
            svgView.topAnchor.constraint(equalTo: topAnchor),
            svgView.bottomAnchor.constraint(equalTo: bottomAnchor),
            fallback.leadingAnchor.constraint(equalTo: leadingAnchor),
            fallback.trailingAnchor.constraint(equalTo: trailingAnchor),
            fallback.topAnchor.constraint(equalTo: topAnchor),
            fallback.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 48)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// - Parameter raw: Fence body for ` ```svg `.
    func configure(raw: String) {
        guard raw != lastRaw else { return }
        lastRaw = raw
        let svg = DiagramSourceCodec.normalizedSVG(from: raw)
        let key = DiagramSourceCodec.shortDigest(svg)
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        if svg.lowercased().contains("<svg") {
            DiagramSVGCache.store(svg: svg, kind: "svg", key: key, dark: dark)
            fallback.isHidden = true
            svgView.isHidden = false
            svgView.setSVG(svg)
        } else {
            svgView.isHidden = true
            fallback.isHidden = false
            fallback.string = raw
        }
    }
}
