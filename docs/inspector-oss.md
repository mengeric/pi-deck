# Trailing inspector — open-source plan (Phase 0)

## Decision

| Layer | Choice | SPM? |
|-------|--------|------|
| Outer split (chat \| inspector) | Keep `ThreeColumnWorkspaceHost` / NSSplitView | No |
| Icon rail | Thin in-house (Phase 1) | No |
| **Diff body** | **[tornikegomareli/gitdiff](https://github.com/tornikegomareli/gitdiff)** `DiffRenderer` | **Yes** (`gitdiff` ≥ 0.1.0, MIT) |

## Phase 0 status

- Package linked to target `agent-deck`.
- Review preview uses `GitDiffOSSView` by default.
- Legacy `FullFileDiffView` remains in tree; force via:

```bash
defaults write works.earendil.pi-deck pi.deck.reviewUseGitdiff -bool false
# re-enable OSS:
defaults write works.earendil.pi-deck pi.deck.reviewUseGitdiff -bool true
```

## Acceptance checklist

- [x] macOS build succeeds with `gitdiff`
- [ ] Unstaged/staged single-file unified diff renders
- [ ] Dark mode colors readable
- [ ] Large context (`-U1000000`) does not hang UI
- [ ] Empty / “no diff” messages still usable

## Fallback order

1. `gitdiff` (current)
2. MagicDiffView / PierreDiffsSwift if Phase 0 fails
3. Keep legacy FullFileDiffView

## Non-goals (Phase 0)

- Multi-tool rail
- Deleting FullFileDiffBuilder
- Replacing GitRepositoryService
