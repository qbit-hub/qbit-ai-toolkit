# {{PROJECT_DISPLAY_NAME}} AI Context

This repository stores long-lived, curated AI continuity for the `{{PROJECT_ID}}` project. It is coordination evidence, not implementation authority.

## Load order

1. `project/authority.md`
2. `state/current.md`
3. owning Manifest selected by a successful lifecycle Start; Windows scoped receipts use `manifests/worktrees/<repository>/<worktreeId>.json`
4. active workstream under `workstreams/active/` when referenced by the manifest
5. repository validation ledger under `validation/repositories/` when present
6. `state/next-action.md`
7. `repositories/repositories.yaml`
8. relevant canonical repository source/tests/contracts/migrations/docs
9. current Git state and worktree fingerprint
10. owning state/handoff/session records from the selected Manifest/runtime `receiptPaths`, when relevant
11. derived semantic or graph evidence only when needed

Do not treat this repository as a substitute for current implementation evidence. When context conflicts with a canonical owner for a claim type, the canonical owner wins and the context must be marked stale or refreshed.

On Windows, repository-level Manifest/state/handoff files are latest-writer compatibility summaries, not authority for another Worktree. Use a legacy receipt only when its explicit owning root matches and the lifecycle accepts that binding. Missing owning records must not be replaced with a sibling's cursor or decisions. A deliberate relocated continuation uses the supported export/import/reconnect protocol and preserves the original provenance; an ordinary clone does not acquire another Worktree's mutable ownership.
