import Foundation

/// Product-level diagram quality policy injected into every parent Pi RPC session
/// via `--append-system-prompt`.
///
/// This is **not** an optional user skill. Toy Mermaid chains and ASCII/tree
/// pseudo-diagrams are banned in Pi Deck chat; the model must use renderable
/// Mermaid (or SVG) when a diagram is warranted.
enum PiDeckDiagramPolicyPrompt {
    /// Human-readable feature name for Settings / docs.
    nonisolated static let featureName = "Diagram quality policy"

    /// Stable skill/catalog name when the same guidance is also shipped as a
    /// bundled skill for discoverability (`bundled-skills/professional-mermaid`).
    nonisolated static let bundledSkillName = "professional-mermaid"

    /// Whether product diagram policy should be appended for this session kind.
    ///
    /// - Parameter isHelperSession: Title / commit helpers and other non-chat Pi
    ///   launches that must not receive chat chrome policies.
    /// - Returns: `true` for normal Coding Agent parent sessions (including
    ///   no-project and 1:1 bound-agent chats).
    nonisolated static func shouldAppend(isHelperSession: Bool) -> Bool {
        !isHelperSession
    }

    /// Full append-system-prompt body for parent sessions.
    nonisolated static var appendSystemPromptText: String {
        """
        # \(AppBrand.displayName) diagram policy (mandatory)

        You are answering inside \(AppBrand.displayName), which **natively renders** fenced Mermaid and SVG. Diagram quality is part of the product answer.

        ## Hard bans — never emit in this session

        1. **Toy Mermaid**: only 2–4 nodes, single chain `A --> B --> C`, generic labels (`Start`/`End`/`Process`), or a diagram simpler than the prose next to it.
        2. **Fake diagrams**: nested bullet/indent trees with `→` / `←` arrows inside plain or code fences; ASCII box art when Mermaid can express the same topology.
        3. **Unclosed fences**: every Mermaid/SVG block must be a complete closed fence so the UI mounts a diagram, not a code card.

        If you drafted a tree like:

        ```text
        Service
          → Gateway
            → Meter
            → LLM
        ```

        **delete it** and replace with a proper ```mermaid fence before sending.

        ## When you must draw Mermaid

        Use Mermaid when any of these hold:
        - ≥2 systems, trust domains, or network zones
        - multi-hop call order matters
        - failure / retry / auth / debit branches exist
        - comparing ≥2 deployment options

        Prefer: `sequenceDiagram` (call order), `flowchart TB` + `subgraph` (topology), `stateDiagram-v2`, `erDiagram`.

        ## Quality bar

        - Real service/role names on nodes (not only A/B)
        - `subgraph` for Client / Cloud / Intranet / trust zones when relevant
        - Edge labels for protocol or purpose; show at least one alternate path when the topic mentions failure or fallback
        - One dense diagram beats three toy ones
        - Optional last line only: `%% mermaid-hash: <8 hex>` (renderers use the last hash)

        ## Allowed non-diagram alternatives

        Single-hop facts → prose or a **table**, not a 2-node Mermaid.

        Staff-engineer bar: would this diagram belong on a design-review slide? If no, rewrite.
        """
    }
}
