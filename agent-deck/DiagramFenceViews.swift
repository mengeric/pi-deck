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
        let normalized = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
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

    static func jsStringLiteral(_ value: String) -> String {
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

// MARK: - Disk / memory SVG cache

/// Caches rendered SVG strings keyed by diagram identity + theme.
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
        if memory[id] == nil { order.append(id) }
        memory[id] = svg
        while order.count > memoryLimit {
            let drop = order.removeFirst()
            memory[drop] = nil
        }
    }
}

// MARK: - Bundle helper

enum MermaidBundle {
    /// Locates bundled mermaid.min.js (folder sync may place it at Resources root or DiagramVendor/).
    static func scriptURL() -> URL? {
        Bundle.main.url(forResource: "mermaid.min", withExtension: "js", subdirectory: "DiagramVendor")
            ?? Bundle.main.url(forResource: "mermaid.min", withExtension: "js")
    }

    static func scriptSource() -> String? {
        guard let url = scriptURL() else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }
}

// MARK: - In-place Mermaid block (visible WKWebView)

/// Renders a ` ```mermaid ` fence **inside the transcript bubble**.
///
/// Uses an on-screen `WKWebView` (not a headless offscreen engine) so WebKit
/// always runs JS. Successful SVG is cached for instant re-entry.
final class MermaidBlockView: NSView, WKNavigationDelegate, WKScriptMessageHandler {
    private var webView: WKWebView?
    private let status = NSTextField(labelWithString: "")
    private let fallback = NSTextView()
    private var heightConstraint: NSLayoutConstraint!
    private var lastRaw = ""
    private var pendingKey = ""
    private var pendingDark = false
    private var loadGeneration = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.35).cgColor

        status.translatesAutoresizingMaskIntoConstraints = false
        status.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail

        fallback.translatesAutoresizingMaskIntoConstraints = false
        fallback.isEditable = false
        fallback.isSelectable = true
        fallback.drawsBackground = false
        fallback.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        fallback.textColor = .labelColor
        fallback.isHidden = true

        addSubview(status)
        addSubview(fallback)

        heightConstraint = heightAnchor.constraint(equalToConstant: 140)
        heightConstraint.priority = .defaultHigh

        NSLayoutConstraint.activate([
            status.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            status.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            status.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            fallback.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            fallback.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            fallback.topAnchor.constraint(equalTo: status.bottomAnchor, constant: 4),
            fallback.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            heightConstraint
        ])
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "deckMermaid")
    }

    /// Configures the block from a mermaid fence body.
    ///
    /// - Parameter raw: Fence body (may include `%% mermaid-hash:` lines).
    func configure(raw: String) {
        guard raw != lastRaw else { return }
        lastRaw = raw
        loadGeneration &+= 1
        let gen = loadGeneration

        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let (key, body) = DiagramSourceCodec.mermaidKeyAndBody(from: raw)
        pendingKey = key
        pendingDark = dark

        fallback.isHidden = true
        status.isHidden = false
        status.stringValue = LanguageStore.shared.t("diagram.mermaid")

        if let cached = DiagramSVGCache.svg(kind: "mermaid", key: key, dark: dark) {
            showStaticSVG(cached, generation: gen)
            return
        }

        status.stringValue = LanguageStore.shared.t("diagram.rendering")
        guard MermaidBundle.scriptSource() != nil else {
            showFallback(body: body, error: LanguageStore.shared.t("diagram.mermaidMissing"))
            return
        }
        installWebViewIfNeeded()
        guard let webView else { return }

        let theme = dark ? "dark" : "default"
        let payload = DiagramSourceCodec.jsStringLiteral(body)
        // File URL base helps relative loads; script is inlined for reliability.
        let js = MermaidBundle.scriptSource() ?? ""
        let html = """
        <!DOCTYPE html>
        <html><head><meta charset="utf-8">
        <style>
          html,body{margin:0;padding:10px;background:transparent;color: \(dark ? "#e5e5e5" : "#1a1a1a");
            font-family:-apple-system,BlinkMacSystemFont,sans-serif;}
          #err{color:#f97316;font-size:12px;white-space:pre-wrap;}
          .mermaid,.mermaid svg{max-width:100%;height:auto;}
        </style>
        <script>\(js)</script>
        </head><body>
        <div id="err"></div>
        <div id="host" class="mermaid"></div>
        <script>
        (async function() {
          try {
            if (typeof mermaid === 'undefined') throw new Error('mermaid global missing');
            mermaid.initialize({
              startOnLoad: false,
              securityLevel: 'loose',
              theme: '\(theme)',
              fontFamily: '-apple-system, BlinkMacSystemFont, sans-serif'
            });
            const src = \(payload);
            const id = 'm' + Date.now();
            const out = await mermaid.render(id, src);
            document.getElementById('host').innerHTML = out.svg;
            const h = Math.ceil(Math.max(
              document.body.scrollHeight,
              document.documentElement.scrollHeight,
              48
            ));
            window.webkit.messageHandlers.deckMermaid.postMessage({ ok: true, svg: out.svg, height: h });
          } catch (e) {
            const msg = String(e && e.message ? e.message : e);
            document.getElementById('err').textContent = msg;
            window.webkit.messageHandlers.deckMermaid.postMessage({ ok: false, error: msg, height: 80 });
          }
        })();
        </script>
        </body></html>
        """
        webView.isHidden = false
        webView.loadHTMLString(html, baseURL: MermaidBundle.scriptURL()?.deletingLastPathComponent())
    }

    private func installWebViewIfNeeded() {
        if webView != nil { return }
        let controller = WKUserContentController()
        controller.add(self, name: "deckMermaid")
        let config = WKWebViewConfiguration()
        config.userContentController = controller
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        let view = WKWebView(frame: .zero, configuration: config)
        view.translatesAutoresizingMaskIntoConstraints = false
        view.navigationDelegate = self
        view.setValue(false, forKey: "drawsBackground")
        addSubview(view)
        webView = view
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: leadingAnchor),
            view.trailingAnchor.constraint(equalTo: trailingAnchor),
            view.topAnchor.constraint(equalTo: status.bottomAnchor, constant: 2),
            view.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    private func showStaticSVG(_ svg: String, generation: Int) {
        guard generation == loadGeneration else { return }
        installWebViewIfNeeded()
        webView?.isHidden = false
        fallback.isHidden = true
        status.stringValue = LanguageStore.shared.t("diagram.mermaid")
        let html = """
        <!DOCTYPE html><html><head><meta charset="utf-8">
        <style>html,body{margin:0;padding:10px;background:transparent;overflow:hidden;}
        svg{max-width:100%;height:auto;display:block;}</style></head>
        <body>\(svg)</body></html>
        """
        webView?.loadHTMLString(html, baseURL: nil)
        // Height refined in didFinish.
    }

    private func showFallback(body: String, error: String) {
        webView?.isHidden = true
        fallback.isHidden = false
        status.stringValue = error
        fallback.string = body
        heightConstraint.constant = max(120, CGFloat(body.split(separator: "\n").count * 16 + 40))
        invalidateIntrinsicContentSize()
        notifyHeightChange()
    }

    private func applyHeight(_ raw: CGFloat) {
        let h = min(max(raw + 28, 72), 720) // status row + padding
        heightConstraint.constant = h
        invalidateIntrinsicContentSize()
        notifyHeightChange()
    }

    private func notifyHeightChange() {
        // Nudge transcript row to re-measure after async diagram layout.
        var view: NSView? = self
        while let current = view {
            current.invalidateIntrinsicContentSize()
            current.needsLayout = true
            view = current.superview
        }
        window?.contentView?.needsLayout = true
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: heightConstraint.constant)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        webView.evaluateJavaScript(
            "Math.ceil(Math.max(document.body.scrollHeight, document.documentElement.scrollHeight, 48))"
        ) { [weak self] result, _ in
            let h = (result as? CGFloat) ?? (result as? Double).map { CGFloat($0) } ?? 120
            DispatchQueue.main.async {
                self?.applyHeight(h)
            }
        }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "deckMermaid" else { return }
        guard let body = message.body as? [String: Any] else { return }
        let height = (body["height"] as? CGFloat)
            ?? (body["height"] as? Double).map { CGFloat($0) }
            ?? 120
        if body["ok"] as? Bool == true, let svg = body["svg"] as? String, !svg.isEmpty {
            DiagramSVGCache.store(svg: svg, kind: "mermaid", key: pendingKey, dark: pendingDark)
            status.stringValue = LanguageStore.shared.t("diagram.mermaid")
            applyHeight(height)
        } else {
            let err = (body["error"] as? String) ?? LanguageStore.shared.t("diagram.renderFailed")
            let (_, diagramBody) = DiagramSourceCodec.mermaidKeyAndBody(from: lastRaw)
            showFallback(body: diagramBody, error: err)
        }
    }
}

// MARK: - SVG fence block

/// SVG fence block (raw SVG markup) shown via a lightweight WK surface.
final class SVGFenceBlockView: NSView, WKNavigationDelegate {
    private let webView: WKWebView
    private let fallback = NSTextView()
    private var heightConstraint: NSLayoutConstraint!
    private var lastRaw = ""

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
        fallback.translatesAutoresizingMaskIntoConstraints = false
        fallback.isEditable = false
        fallback.isSelectable = true
        fallback.drawsBackground = false
        fallback.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        fallback.isHidden = true
        addSubview(webView)
        addSubview(fallback)
        heightConstraint = heightAnchor.constraint(equalToConstant: 100)
        heightConstraint.priority = .defaultHigh
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor),
            webView.topAnchor.constraint(equalTo: topAnchor),
            webView.bottomAnchor.constraint(equalTo: bottomAnchor),
            fallback.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            fallback.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            fallback.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            fallback.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
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

    /// - Parameter raw: Fence body for an `svg` code fence.
    func configure(raw: String) {
        guard raw != lastRaw else { return }
        lastRaw = raw
        let svg = DiagramSourceCodec.normalizedSVG(from: raw)
        let key = DiagramSourceCodec.shortDigest(svg)
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        if svg.lowercased().contains("<svg") {
            DiagramSVGCache.store(svg: svg, kind: "svg", key: key, dark: dark)
            fallback.isHidden = true
            webView.isHidden = false
            let html = """
            <!DOCTYPE html><html><head><meta charset="utf-8">
            <style>html,body{margin:0;padding:10px;background:transparent;overflow:hidden;}
            svg{max-width:100%;height:auto;display:block;}</style></head>
            <body>\(svg)</body></html>
            """
            webView.loadHTMLString(html, baseURL: nil)
        } else {
            webView.isHidden = true
            fallback.isHidden = false
            fallback.string = raw
            heightConstraint.constant = 120
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        webView.evaluateJavaScript(
            "Math.ceil(Math.max(document.body.scrollHeight, document.documentElement.scrollHeight, 48))"
        ) { [weak self] result, _ in
            let h = (result as? CGFloat) ?? (result as? Double).map { CGFloat($0) } ?? 100
            DispatchQueue.main.async {
                guard let self else { return }
                self.heightConstraint.constant = min(max(h + 8, 48), 720)
                self.invalidateIntrinsicContentSize()
                self.window?.contentView?.needsLayout = true
            }
        }
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: heightConstraint.constant)
    }
}

// MARK: - Optional engine release (memory)

/// Best-effort hook for future “idle release” of diagram WebKit processes.
enum MermaidDiagramEngine {
    @MainActor
    static func releaseEngine() {
        // In-place block webviews are owned by transcript cells; nothing global to drop.
        // Kept so Review collapse / memory Phase A call sites stay source-compatible.
    }

    @MainActor
    static var isEngineLoaded: Bool { false }
}
