---
name: professional-mermaid
description: >
  Pi Deck product skill for architecture, sequence, topology, and comparison
  diagrams. Prefer when the user asks for Mermaid, flowcharts, or architecture
  pictures. Matches the always-on Pi Deck diagram policy: ban toy A→B→C graphs
  and ASCII/tree pseudo-diagrams; require professional Mermaid or SVG.
---

# Professional Mermaid (Pi Deck product)

Pi Deck also injects a mandatory diagram-quality append system prompt on every parent session. This skill expands templates when you need a full diagram.

## Hard bans

- Toy 2–4 node chains without branches or real names
- Nested `→` trees / ASCII boxes pretending to be architecture
- Diagrams weaker than the surrounding prose

## Prefer

| Need | Chart |
|------|--------|
| Call order | `sequenceDiagram` + `alt`/`opt` |
| Topology | `flowchart TB` + `subgraph` zones |
| State | `stateDiagram-v2` |
| Data | `erDiagram` |

## Sequence template

```mermaid
sequenceDiagram
  autonumber
  actor U as Client
  participant Biz as Business API
  participant GW as Cloud Gateway
  participant Meter as Meter
  participant LLM as NewAPI
  U->>Biz: Request
  Biz->>GW: HTTPS
  GW->>Meter: Pre-check
  alt deny
    Meter-->>GW: reject
    GW-->>Biz: error
  else ok
    GW->>LLM: completion
    LLM-->>GW: result
    GW->>Meter: Debit
    GW-->>Biz: result
  end
```

## Topology template

```mermaid
flowchart TB
  subgraph ClientZone["Client"]
    Biz["Business service"]
  end
  subgraph CloudZone["Cloud"]
    GW["Gateway"]
    Meter["Meter"]
  end
  subgraph ModelZone["Model plane"]
    LLM["NewAPI / LLM"]
  end
  Biz -->|HTTPS| GW
  GW --> Meter
  GW --> LLM
```

Close every fence. Optional last line: `%% mermaid-hash: <8 hex>`.
