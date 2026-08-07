import AppKit
import CryptoKit
import WebKit

// MARK: - Source codec (mermaid-hash + clean body)

/// Parses fenced diagram bodies used in agent transcripts and markdown cards.
///
/// When multiple `%% mermaid-hash:` lines exist, **the last one wins**. All hash
/// lines are stripped before rendering.
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

    /// Normalizes an SVG fence body.
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
    /// Locates bundled mermaid.min.js.
    static func scriptURL() -> URL? {
        Bundle.main.url(forResource: "mermaid.min", withExtension: "js", subdirectory: "DiagramVendor")
            ?? Bundle.main.url(forResource: "mermaid.min", withExtension: "js")
    }

    static func scriptSource() -> String? {
        guard let url = scriptURL() else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }
}

// MARK: - Click-to-zoom panel

/// Floating panel that shows a diagram full-size (click mermaid/svg block to open).
@MainActor
enum DiagramZoomPresenter {
    private static var retained: DiagramZoomWindowController?

    /// Presents SVG (preferred) or re-renders mermaid source in a large panel.
    ///
    /// - Parameters:
    ///   - svg: Cached SVG markup when available.
    ///   - mermaidSource: Clean mermaid body for live re-render if `svg` is nil.
    ///   - title: Panel title.
    ///   - dark: Appearance bit.
    ///   - anchor: View to center relative to (usually the diagram block).
    static func present(
        svg: String?,
        mermaidSource: String? = nil,
        title: String,
        dark: Bool,
        relativeTo anchor: NSView
    ) {
        let controller = DiagramZoomWindowController(
            svg: svg,
            mermaidSource: mermaidSource,
            title: title,
            dark: dark
        )
        retained = controller
        controller.onClose = { retained = nil }
        controller.show(relativeTo: anchor)
    }
}

/// Window controller for the diagram zoom panel.
@MainActor
final class DiagramZoomWindowController: NSObject, NSWindowDelegate {
    var onClose: (() -> Void)?
    private let panel: NSPanel
    private let webView: WKWebView
    private let svg: String?
    private let mermaidSource: String?
    private let dark: Bool

    /// - Parameters:
    ///   - svg: Pre-rendered SVG when available.
    ///   - mermaidSource: Fallback mermaid source to render inside the panel.
    ///   - title: Window title.
    ///   - dark: Dark appearance for theme tokens.
    init(svg: String?, mermaidSource: String?, title: String, dark: Bool) {
        self.svg = svg
        self.mermaidSource = mermaidSource
        self.dark = dark

        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        let size = NSSize(
            width: min(max(screen.width * 0.85, 640), screen.width - 40),
            height: min(max(screen.height * 0.8, 480), screen.height - 40)
        )
        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = title
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = dark ? NSColor(calibratedWhite: 0.12, alpha: 1) : .windowBackgroundColor

        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        webView.translatesAutoresizingMaskIntoConstraints = false

        let root = NSView(frame: .zero)
        root.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            webView.topAnchor.constraint(equalTo: root.topAnchor),
            webView.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])
        panel.contentView = root
        super.init()
        panel.delegate = self
        loadContent()
    }

    /// Shows the panel centered on the same screen as `anchor`.
    ///
    /// - Parameter anchor: Source diagram view.
    func show(relativeTo anchor: NSView) {
        if let screen = anchor.window?.screen ?? NSScreen.main {
            let vf = screen.visibleFrame
            let size = panel.frame.size
            let origin = NSPoint(
                x: vf.midX - size.width / 2,
                y: vf.midY - size.height / 2
            )
            panel.setFrame(NSRect(origin: origin, size: size), display: true)
        }
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }

    private func loadContent() {
        if let svg, !svg.isEmpty {
            webView.loadHTMLString(Self.htmlDocument(bodyInner: svg, dark: dark, padded: true), baseURL: nil)
            return
        }
        if let mermaidSource, let js = MermaidBundle.scriptSource() {
            let theme = dark ? "dark" : "default"
            let payload = DiagramSourceCodec.jsStringLiteral(mermaidSource)
            let html = """
            <!DOCTYPE html><html><head><meta charset="utf-8">
            <style>
              html,body{margin:0;padding:24px;background:\(dark ? "#1e1e1e" : "#fafafa");
                color:\(dark ? "#e5e5e5" : "#1a1a1a");}
              svg{max-width:100%;height:auto;display:block;margin:0 auto;}
            </style>
            <script>\(js)</script>
            </head><body><div id="host"></div>
            <script>
            (async function(){
              mermaid.initialize({startOnLoad:false,securityLevel:'loose',theme:'\(theme)',
                flowchart:{useMaxWidth:true,htmlLabels:true},
                sequence:{useMaxWidth:true}});
              const out = await mermaid.render('z'+Date.now(), \(payload));
              document.getElementById('host').innerHTML = out.svg;
              document.querySelectorAll('svg').forEach(s=>{
                s.style.width='100%'; s.style.maxWidth='100%'; s.style.height='auto';
                s.removeAttribute('height');
              });
            })();
            </script></body></html>
            """
            webView.loadHTMLString(html, baseURL: MermaidBundle.scriptURL()?.deletingLastPathComponent())
            return
        }
        webView.loadHTMLString(Self.htmlDocument(bodyInner: "<p>No diagram</p>", dark: dark, padded: true), baseURL: nil)
    }

    private static func htmlDocument(bodyInner: String, dark: Bool, padded: Bool) -> String {
        let pad = padded ? "24px" : "0"
        return """
        <!DOCTYPE html><html><head><meta charset="utf-8">
        <style>
          html,body{margin:0;padding:\(pad);background:\(dark ? "#1e1e1e" : "#fafafa");}
          svg{max-width:100%;height:auto;display:block;margin:0 auto;}
        </style></head><body>\(bodyInner)</body></html>
        """
    }
}

// MARK: - In-place Mermaid block

/// Renders a mermaid fence inside the transcript; click or ↗ to zoom.
final class MermaidBlockView: NSView, WKNavigationDelegate, WKScriptMessageHandler {
    private var webView: WKWebView?
    private let header = NSView()
    private let status = NSTextField(labelWithString: "")
    private let zoomButton = NSButton()
    private let fallback = NSTextView()
    private var heightConstraint: NSLayoutConstraint!
    private var lastRaw = ""
    private var pendingKey = ""
    private var pendingDark = false
    private var loadGeneration = 0
    /// Last successful SVG for click-to-zoom without re-render.
    private var lastSVG: String?
    private var lastDiagramBody = ""

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.35).cgColor

        // Stack gravityAreas hugs intrinsic width — keep hugging minimal so the
        // block stretches to the markdown column (avoids tiny right-rail cards).
        setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1), for: .horizontal)

        header.translatesAutoresizingMaskIntoConstraints = false
        status.translatesAutoresizingMaskIntoConstraints = false
        status.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        status.setContentHuggingPriority(.defaultLow, for: .horizontal)

        zoomButton.translatesAutoresizingMaskIntoConstraints = false
        zoomButton.isBordered = false
        zoomButton.bezelStyle = .inline
        zoomButton.imagePosition = .imageOnly
        zoomButton.focusRingType = .none
        zoomButton.contentTintColor = .secondaryLabelColor
        let cfg = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
        zoomButton.image = NSImage(systemSymbolName: "arrow.up.left.and.arrow.down.right", accessibilityDescription: "Zoom")?
            .withSymbolConfiguration(cfg)
        zoomButton.toolTip = LanguageStore.shared.t("diagram.zoomHint")
        zoomButton.target = self
        zoomButton.action = #selector(zoomTapped)
        zoomButton.setContentHuggingPriority(.required, for: .horizontal)

        fallback.translatesAutoresizingMaskIntoConstraints = false
        fallback.isEditable = false
        fallback.isSelectable = true
        fallback.drawsBackground = false
        fallback.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        fallback.textColor = .labelColor
        fallback.isHidden = true

        header.addSubview(status)
        header.addSubview(zoomButton)
        addSubview(header)
        addSubview(fallback)

        heightConstraint = heightAnchor.constraint(equalToConstant: 200)
        heightConstraint.priority = .defaultHigh

        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            header.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            header.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            header.heightAnchor.constraint(equalToConstant: 18),

            status.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            status.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            status.trailingAnchor.constraint(lessThanOrEqualTo: zoomButton.leadingAnchor, constant: -8),

            zoomButton.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            zoomButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            zoomButton.widthAnchor.constraint(equalToConstant: 20),
            zoomButton.heightAnchor.constraint(equalToConstant: 18),

            fallback.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            fallback.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            fallback.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 4),
            fallback.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            heightConstraint
        ])

        let click = NSClickGestureRecognizer(target: self, action: #selector(zoomTapped))
        addGestureRecognizer(click)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "deckMermaid")
    }

    override var intrinsicContentSize: NSSize {
        // Width must stay flexible so NSStackView (.gravityAreas) can stretch us.
        NSSize(width: NSView.noIntrinsicMetric, height: heightConstraint.constant)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    /// Configures the block from a mermaid fence body.
    ///
    /// - Parameter raw: Fence body (may include `%% mermaid-hash:` lines).
    func configure(raw: String) {
        guard raw != lastRaw else { return }
        lastRaw = raw
        loadGeneration &+= 1
        let gen = loadGeneration
        lastSVG = nil

        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let (key, body) = DiagramSourceCodec.mermaidKeyAndBody(from: raw)
        pendingKey = key
        pendingDark = dark
        lastDiagramBody = body

        fallback.isHidden = true
        status.stringValue = LanguageStore.shared.t("diagram.mermaid")
        zoomButton.isEnabled = true

        if let cached = DiagramSVGCache.svg(kind: "mermaid", key: key, dark: dark) {
            lastSVG = cached
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
        let js = MermaidBundle.scriptSource() ?? ""
        // useMaxWidth so sequence/flowchart fill the bubble instead of a tiny fixed SVG.
        let html = """
        <!DOCTYPE html>
        <html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
          html,body{margin:0;padding:8px 10px 12px;background:transparent;
            color:\(dark ? "#e5e5e5" : "#1a1a1a");
            font-family:-apple-system,BlinkMacSystemFont,sans-serif;
            overflow:hidden;}
          #err{color:#f97316;font-size:12px;white-space:pre-wrap;}
          #host{width:100%;}
          #host svg{width:100% !important;max-width:100% !important;height:auto !important;display:block;}
        </style>
        <script>\(js)</script>
        </head><body>
        <div id="err"></div>
        <div id="host"></div>
        <script>
        (async function() {
          try {
            if (typeof mermaid === 'undefined') throw new Error('mermaid global missing');
            mermaid.initialize({
              startOnLoad: false,
              securityLevel: 'loose',
              theme: '\(theme)',
              fontFamily: '-apple-system, BlinkMacSystemFont, sans-serif',
              flowchart: { useMaxWidth: true, htmlLabels: true },
              sequence: { useMaxWidth: true },
              er: { useMaxWidth: true },
              gantt: { useMaxWidth: true }
            });
            const src = \(payload);
            const id = 'm' + Date.now();
            const out = await mermaid.render(id, src);
            const host = document.getElementById('host');
            host.innerHTML = out.svg;
            document.querySelectorAll('#host svg').forEach(s => {
              s.style.width = '100%';
              s.style.maxWidth = '100%';
              s.style.height = 'auto';
              s.removeAttribute('height');
              if (!s.getAttribute('viewBox') && s.getAttribute('width') && s.getAttribute('height')) {
                /* keep viewBox if mermaid provided one */
              }
              s.setAttribute('width', '100%');
            });
            const h = Math.ceil(Math.max(
              document.body.scrollHeight,
              document.documentElement.scrollHeight,
              host.scrollHeight,
              64
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

    @objc private func zoomTapped() {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        DiagramZoomPresenter.present(
            svg: lastSVG,
            mermaidSource: lastDiagramBody.isEmpty ? nil : lastDiagramBody,
            title: LanguageStore.shared.t("diagram.zoomTitle"),
            dark: dark,
            relativeTo: self
        )
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
        view.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        view.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        addSubview(view)
        webView = view
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: leadingAnchor),
            view.trailingAnchor.constraint(equalTo: trailingAnchor),
            view.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 2),
            view.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    private func showStaticSVG(_ svg: String, generation: Int) {
        guard generation == loadGeneration else { return }
        installWebViewIfNeeded()
        webView?.isHidden = false
        fallback.isHidden = true
        status.stringValue = LanguageStore.shared.t("diagram.mermaid")
        let dark = pendingDark
        let html = """
        <!DOCTYPE html><html><head><meta charset="utf-8">
        <style>
          html,body{margin:0;padding:8px 10px 12px;background:transparent;overflow:hidden;}
          svg{width:100% !important;max-width:100% !important;height:auto !important;display:block;}
        </style></head>
        <body>\(svg)</body></html>
        """
        _ = dark
        webView?.loadHTMLString(html, baseURL: nil)
    }

    private func showFallback(body: String, error: String) {
        webView?.isHidden = true
        fallback.isHidden = false
        status.stringValue = error
        fallback.string = body
        heightConstraint.constant = max(120, CGFloat(body.split(separator: "\n").count * 16 + 48))
        invalidateIntrinsicContentSize()
        notifyHeightChange()
    }

    private func applyHeight(_ raw: CGFloat) {
        // Prefer a readable in-bubble height; user can zoom for full detail.
        let h = min(max(raw + 28, 120), 480)
        heightConstraint.constant = h
        invalidateIntrinsicContentSize()
        notifyHeightChange()
    }

    private func notifyHeightChange() {
        var view: NSView? = self
        while let current = view {
            current.invalidateIntrinsicContentSize()
            current.needsLayout = true
            view = current.superview
        }
        window?.contentView?.needsLayout = true
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        webView.evaluateJavaScript(
            """
            (function(){
              document.querySelectorAll('svg').forEach(s=>{
                s.style.width='100%'; s.style.maxWidth='100%'; s.style.height='auto';
              });
              return Math.ceil(Math.max(document.body.scrollHeight, document.documentElement.scrollHeight, 64));
            })()
            """
        ) { [weak self] result, _ in
            let h = (result as? CGFloat) ?? (result as? Double).map { CGFloat($0) } ?? 160
            DispatchQueue.main.async { self?.applyHeight(h) }
        }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "deckMermaid" else { return }
        guard let body = message.body as? [String: Any] else { return }
        let height = (body["height"] as? CGFloat)
            ?? (body["height"] as? Double).map { CGFloat($0) }
            ?? 160
        if body["ok"] as? Bool == true, let svg = body["svg"] as? String, !svg.isEmpty {
            lastSVG = svg
            DiagramSVGCache.store(svg: svg, kind: "mermaid", key: pendingKey, dark: pendingDark)
            status.stringValue = LanguageStore.shared.t("diagram.mermaid")
            applyHeight(height)
        } else {
            let err = (body["error"] as? String) ?? LanguageStore.shared.t("diagram.renderFailed")
            showFallback(body: lastDiagramBody, error: err)
        }
    }
}

// MARK: - SVG fence block

/// SVG fence with full-width layout and click-to-zoom.
final class SVGFenceBlockView: NSView, WKNavigationDelegate {
    private let webView: WKWebView
    private let header = NSView()
    private let status = NSTextField(labelWithString: "")
    private let zoomButton = NSButton()
    private let fallback = NSTextView()
    private var heightConstraint: NSLayoutConstraint!
    private var lastRaw = ""
    private var lastSVG: String?

    override init(frame frameRect: NSRect) {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        webView = WKWebView(frame: .zero, configuration: config)
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1), for: .horizontal)

        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.navigationDelegate = self
        webView.setValue(false, forKey: "drawsBackground")
        webView.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)

        header.translatesAutoresizingMaskIntoConstraints = false
        status.translatesAutoresizingMaskIntoConstraints = false
        status.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        status.textColor = .secondaryLabelColor
        status.stringValue = "SVG"

        zoomButton.translatesAutoresizingMaskIntoConstraints = false
        zoomButton.isBordered = false
        zoomButton.bezelStyle = .inline
        zoomButton.imagePosition = .imageOnly
        zoomButton.focusRingType = .none
        zoomButton.contentTintColor = .secondaryLabelColor
        let cfg = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
        zoomButton.image = NSImage(systemSymbolName: "arrow.up.left.and.arrow.down.right", accessibilityDescription: "Zoom")?
            .withSymbolConfiguration(cfg)
        zoomButton.toolTip = LanguageStore.shared.t("diagram.zoomHint")
        zoomButton.target = self
        zoomButton.action = #selector(zoomTapped)

        fallback.translatesAutoresizingMaskIntoConstraints = false
        fallback.isEditable = false
        fallback.isSelectable = true
        fallback.drawsBackground = false
        fallback.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        fallback.isHidden = true

        header.addSubview(status)
        header.addSubview(zoomButton)
        addSubview(header)
        addSubview(webView)
        addSubview(fallback)

        heightConstraint = heightAnchor.constraint(equalToConstant: 160)
        heightConstraint.priority = .defaultHigh
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            header.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            header.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            header.heightAnchor.constraint(equalToConstant: 18),
            status.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            status.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            zoomButton.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            zoomButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            zoomButton.widthAnchor.constraint(equalToConstant: 20),
            zoomButton.heightAnchor.constraint(equalToConstant: 18),
            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor),
            webView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 2),
            webView.bottomAnchor.constraint(equalTo: bottomAnchor),
            fallback.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            fallback.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            fallback.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 4),
            fallback.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            heightConstraint
        ])
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor

        let click = NSClickGestureRecognizer(target: self, action: #selector(zoomTapped))
        addGestureRecognizer(click)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: heightConstraint.constant)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    /// - Parameter raw: Fence body for an `svg` code fence.
    func configure(raw: String) {
        guard raw != lastRaw else { return }
        lastRaw = raw
        let svg = DiagramSourceCodec.normalizedSVG(from: raw)
        let key = DiagramSourceCodec.shortDigest(svg)
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        if svg.lowercased().contains("<svg") {
            lastSVG = svg
            DiagramSVGCache.store(svg: svg, kind: "svg", key: key, dark: dark)
            fallback.isHidden = true
            webView.isHidden = false
            let html = """
            <!DOCTYPE html><html><head><meta charset="utf-8">
            <style>
              html,body{margin:0;padding:8px 10px;background:transparent;overflow:hidden;}
              svg{width:100% !important;max-width:100% !important;height:auto !important;display:block;}
            </style></head>
            <body>\(svg)</body></html>
            """
            webView.loadHTMLString(html, baseURL: nil)
        } else {
            lastSVG = nil
            webView.isHidden = true
            fallback.isHidden = false
            fallback.string = raw
            heightConstraint.constant = 120
        }
    }

    @objc private func zoomTapped() {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        DiagramZoomPresenter.present(
            svg: lastSVG,
            mermaidSource: nil,
            title: "SVG",
            dark: dark,
            relativeTo: self
        )
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        webView.evaluateJavaScript(
            "Math.ceil(Math.max(document.body.scrollHeight, document.documentElement.scrollHeight, 64))"
        ) { [weak self] result, _ in
            let h = (result as? CGFloat) ?? (result as? Double).map { CGFloat($0) } ?? 120
            DispatchQueue.main.async {
                guard let self else { return }
                self.heightConstraint.constant = min(max(h + 28, 80), 480)
                self.invalidateIntrinsicContentSize()
                self.window?.contentView?.needsLayout = true
            }
        }
    }
}

// MARK: - Compatibility hook

enum MermaidDiagramEngine {
    @MainActor
    static func releaseEngine() {}

    @MainActor
    static var isEngineLoaded: Bool { false }
}
