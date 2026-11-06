# AI Context Automation

Member repositories run the repository-owned launcher for the active host automatically before substantive Codex work: `.ai/context/context.ps1 start` on Windows or `bash .ai/context/context.sh start` on Linux/macOS. The launcher ensures the central context cache exists, verifies its configured origin/branch, safely refreshes a clean cache, and generates `.ai-bridge/context-runtime.md` plus JSON runtime evidence.

## Continuity v2

New substantive checkpoints use checkpoint `schemaVersion: 2`. The ordinary mode is `continuity.mode: tracked`, which persists a first-class workstream containing stable work-item IDs, repository roles, dependencies/blockers, acceptance criteria, validation requirements, and an execution cursor with the exact current item, last completed item/action, phase, and next action. `continuity.mode: snapshot` is only for checkpoints that have no unresolved tracked workstream.

The lifecycle is fail-closed against continuity loss. An unresolved work item cannot disappear from a subsequent checkpoint, a terminal item/workstream cannot be silently reopened, dependency cycles are rejected, blocked items must identify blockers, and an active workstream cannot be replaced by a different workstream ID until it has been explicitly completed/cancelled/superseded. Completed workstreams move from `workstreams/active/` to `workstreams/archive/` rather than being discarded.

Validation evidence is stored in append-only repository ledgers under `validation/repositories/`. Every validation entry has an immutable ID and is bound to the member repository HEAD plus a deterministic worktree fingerprint. `start` reports how many ledger entries are fresh or stale for the current worktree; stale evidence remains historical evidence and must not be treated as current validation.

`schemaVersion: 1` checkpoints remain accepted only at the legacy entrypoint for backward compatibility when no unresolved v2 workstream would be lost. The strict POSIX online entrypoint requires schema v2.

## POSIX strict online gate

Install/update central and member assets together. `bash .ai/context/context.sh start` refreshes a clean cache and requires live configured remote/branch SHA equality. `status` checks existing runtime and source health without rewriting evidence. `verify` requires a prior healthy Start, regenerates current source evidence and independently verifies the owning checkpoint publication. Runtime and checkpoint timestamps must be no more than 120 minutes old and cannot be future dated. Unhealthy evidence exits 3 with `CONTEXT_UNSYNCED`.

Online `checkpoint` requires `behavior.pushContext: true`, a complete schema-v2 payload and exact source identity. It publishes Worktree-scoped Manifest/state/handoff records under `manifests/worktrees/`, `state/worktrees/` and `handoffs/worktrees/`, a new Session, byte-exact payload under `checkpoints/worktrees/`, Workstream and append-only validation ledger in one commit. Runtime receipt paths are derived from the actual owning Git root. POSIX roots preserve case; Windows roots retain Windows path normalization. Foreign Worktree receipts and globally owned Workstream IDs cannot be borrowed.

An OS-released cache lock and ignored atomic retry journal preserve interrupted operations. Retry `checkpoint` with the original payload and source; prepared/committed/completed exact retries do not create duplicate Sessions. Never delete a pending journal or reset/rebase/merge a divergent cache as automatic recovery. Preserve the cache, payload and journal for explicit review if any byte, source, owner, branch or remote changed.

Historical repository-level receipts and unknown-owner Workstreams remain protected. Explicit independent-root enrollment uses the Windows reviewed-reconciliation contract, preserves its original blobs, and admits a distinct scope/Workstream. POSIX offline export/import/reconnect remain schema-1 portability and cannot pass strict online Verify. Legacy 1.2.9 launchers continue to use the legacy central entrypoint.

## Membership and reconciliation

`repositories/repositories.yaml` is the explicit project membership registry. Every managed member must use the same project ID as the central context and must have its repository ID registered with a non-empty role. `start` and `checkpoint` fail closed for unregistered members. Strict POSIX `status` is read-only and fails on unhealthy membership; the legacy central status action can still generate diagnostics.

Use `audit` for read-only reconciliation. It compares registered entries with nearby Git worktrees and reports missing or mismatched registered repositories plus plausible unregistered sibling repositories. It never adds registry entries, rewrites member configuration, commits, or pushes.

## Checkpoint lifecycle

After a substantive validated milestone, the agent writes `.ai-bridge/context-checkpoint.json` and runs the `checkpoint` action. The central lifecycle validates membership, shape/status/continuity invariants, rejects secret-like material, derives Git provenance and the worktree fingerprint, writes repository-scoped state/handoff/session records, persists workstream and validation records, commits only the scoped context paths, and pushes when enabled.

Online push synchronization is ancestry-based. After a rejected push the lifecycle fetches the configured branch. If the remote branch is already an ancestor of the local checkpoint it may retry the normal non-force push; if local history is an ancestor of the remote branch it only fast-forwards locally. If both sides advanced independently, checkpoint publication fails closed and preserves both histories. It never auto-merges, rebases, resets, or force-pushes divergent context history.

## Offline portability

Use offline transfer only when the central context remote will not be available to the receiving workspace or machine. Run `export` while the central context cache is clean. The launcher writes an ignored `.ai-bridge/context-transfer/manifest.json` and `context.bundle`. Export scans every tracked central-context file and rejects non-regular Git entries, symlink/reparse entries, repository escapes, non-UTF-8 text, and secret-like content. The manifest binds the package to project/repository identity, configured context branch, source member/context Git provenance, bundle size, SHA-256, and the current continuity cursor summary.

On the receiving repository, copy the complete `context-transfer` directory into `.ai-bridge/` and run `import`. Import verifies the exact manifest shape, project/repository/branch identity, byte length, SHA-256, Git bundle integrity, and source context HEAD before creating or accepting the context cache. After a successful import, `start`, `status`, and `checkpoint` run without remote access and runtime freshness is `OFFLINE_IMPORTED_CONTEXT`. Offline checkpoints remain normal local context commits but deliberately skip remote push.

When the configured central remote becomes reachable again, run `reconnect`. If remote history is an ancestor of the locally advanced offline history, reconnect performs a normal non-force push. If local history is an ancestor of remote history, reconnect fast-forwards locally. If both histories advanced independently, reconnect rejects the operation and preserves both histories and the offline marker for explicit human reconciliation; it never auto-merges, rebases, resets, or force-pushes. Only a successful synchronization removes the offline marker and returns ordinary `start` behavior.

Network Git operations use the host's normal Git credential chain. The Windows PowerShell launcher may additionally retry failed private `github.com` operations through `gh auth git-credential` when GitHub CLI is available. The POSIX launcher deliberately delegates authentication to Git credential helpers and does not persist credentials. Strict POSIX refuses origin changes; explicitly review/reconcile a changed remote rather than silently migrating its publication authority. The legacy portability flow retains its existing origin behavior.

Windows/PowerShell and Linux/macOS through Bash plus Python 3.10+ are supported. Both launcher/tooling variants are installed so a managed repository remains portable after cloning on another supported host.
