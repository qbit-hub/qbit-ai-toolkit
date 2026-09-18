---
title: AI Context Continuity v2
sidebar_label: Continuity v2
---

# AI Context Continuity v2

Continuity v2 is the durable project-context model shipped by `installer.ai-context`. The current stable release is `1.2.8`. It is designed for exact continuation of repository work across fresh ChatGPT/Codex sessions, accounts, machines, and temporary offline periods without treating chat history as the source of truth.

## Scope and authority

AI Context stores coordination evidence: current workstream, work items, execution cursor, blockers, acceptance criteria, validation provenance, decisions, rejected approaches, and exact next action. It does not replace repository authority. Source, tests, schemas/migrations, contracts, ADRs, and other canonical owners remain authoritative for implementation claims.

The core continuity rule is:

> `nextAction` is a pointer into durable structured work, not a replacement for the backlog.

An agent must not compress an unresolved tracked workstream into a free-form summary that loses item identity or status.

## Schema namespaces

Several files use a field named `schemaVersion`, but they are independent contracts:

- substantive **checkpoint** payloads use `schemaVersion: 2` for Continuity v2;
- member `.ai/context/config.json` currently uses its own config schema version `1`;
- offline transfer manifests and offline markers currently use their own transfer schema version `1`;
- installer ownership state uses its own installer-state schema contract.

Do not bump config or transfer schema versions merely because checkpoint continuity is v2.

`schemaVersion: 1` checkpoints are accepted only for backward-compatible reads when they cannot erase unresolved v2 tracked work. New substantive checkpoints must use checkpoint schema v2.

## Tracked workstreams

Use `continuity.mode: tracked` whenever work remains resumable. A tracked workstream has a stable workstream ID, title, status, objective, repository roles, execution cursor, and durable work items.

Work-item status values are:

- `PENDING`
- `IN_PROGRESS`
- `BLOCKED`
- `COMPLETED`
- `CANCELLED`
- `SUPERSEDED`

Workstream status values are:

- `PROPOSED`
- `IN_PROGRESS`
- `BLOCKED`
- `COMPLETED`
- `CANCELLED`
- `SUPERSEDED`

Each meaningful work item should carry stable identity plus the information required to resume it correctly: priority, scope, acceptance criteria, dependencies, blockers, validation requirements, and notes/provenance where needed.

The execution cursor records the exact current item, last completed item/action, phase, and next action.

## Snapshot mode

Use `continuity.mode: snapshot` only when there is no unresolved tracked workstream. Snapshot mode is not a shortcut for dropping pending or blocked work.

A terminal workstream must transition its items explicitly. Completed/cancelled/superseded workstreams move from `workstreams/active/` to `workstreams/archive/`; they are not silently discarded.

## Fail-closed continuity invariants

The lifecycle rejects continuity mutations that would make durable state ambiguous or lossy. Among other checks, it rejects:

- silent disappearance of unresolved work-item IDs;
- invalid status transitions or reopening terminal work without an allowed transition;
- dependency cycles;
- blocked items without valid work-item blockers;
- duplicate immutable validation IDs;
- changing an active workstream to a different workstream ID without explicitly terminating the previous one;
- schema v1 or snapshot checkpoints that would erase unresolved v2 work.

When an invariant fails, fix the checkpoint model. Do not reset or rewrite context history merely to make automation pass.

## Validation ledger and freshness

Validation evidence is append-only under `validation/repositories/`. Each entry has an immutable validation ID and records what was actually executed.

The lifecycle binds validation to repository HEAD plus a deterministic worktree fingerprint. After source/worktree changes, previous validation may become stale. Stale evidence remains historical evidence but must not be presented as current validation.

Agents should add ledger entries only for gates actually executed against the relevant repository/worktree.

## Member lifecycle

Managed repositories expose the same lifecycle actions on Windows and POSIX hosts:

```text
start
status
checkpoint
audit
export
import
reconnect
```

Windows:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .ai/context/context.ps1 start
```

Linux/macOS:

```bash
bash .ai/context/context.sh start
```

Before substantive work, run `start` once and read `.ai-bridge/context-runtime.md`. Treat its active workstream, cursor, unresolved work items, validation freshness, and membership diagnostics as the resume contract.

Central membership is explicit. `repositories/repositories.yaml` owns the list of managed repository IDs and their roles. A member config must use the same project ID and a repository ID present in that registry. Unregistered repositories are rejected by `start` and `checkpoint`; `status` still emits diagnostic runtime JSON but exits unhealthy. `audit` is read-only and compares the registry against nearby Git worktrees, reporting missing/mismatched registered repositories plus plausible unregistered siblings without auto-registering or mutating history.

After a substantive validated continuity milestone, write `.ai-bridge/context-checkpoint.json` and run `checkpoint`. Ordinary read-only questions and per-message activity do not require checkpoints. Online checkpoint publication is ancestry-based: after a rejected push the lifecycle fetches the configured branch and only retries or fast-forwards when one side is already an ancestor of the other. Independent advances fail closed with both histories preserved; checkpoint publication never auto-merges, rebases, resets, or force-pushes divergent context history.

## Offline and cross-machine transfer

`export` creates an ignored `.ai-bridge/context-transfer/` directory containing a Git bundle plus a manifest. Export requires a clean context cache and validates tracked central-context content for supported regular files, repository-bound paths, UTF-8 text, and secret-like material.

The manifest binds the transfer to project/repository identity, context branch, source member/context provenance, byte length, SHA-256, and the current continuity cursor summary.

`import` verifies the manifest shape, repository/project/branch identity, bundle size and SHA-256, `git bundle verify`, and exact source context HEAD before accepting the local cache. Imported sessions report `OFFLINE_IMPORTED_CONTEXT`; `start`, `status`, and `checkpoint` remain available without remote access, and offline checkpoints commit locally without pushing.

## Reconnect semantics

`reconnect` is the only supported automatic exit from imported offline mode:

- remote is ancestor of local: normal non-force push;
- local is ancestor of remote: local fast-forward;
- both advanced independently: fail closed and preserve both histories plus the offline marker.

Reconnect never auto-merges, rebases, resets, or force-pushes divergent continuity history.

## Security boundaries

Context must never contain credentials, tokens, cookies, private keys, `.env` values, customer secrets, production secrets, or raw chat transcripts. Transfer export scans tracked context for secret-like material before packaging.

Context remote URLs must not embed credentials. Runtime Git uses the host credential chain. Windows may retry private GitHub operations through `gh auth git-credential`; POSIX uses normal Git credential helpers.

## Repository policy contract

A managed member's `AGENTS.md` must require:

1. automatic context `start` before substantive work;
2. reading `.ai-bridge/context-runtime.md`;
3. checkpoint schema v2 for new substantive continuity;
4. tracked mode while unresolved work exists;
5. explicit preservation of work-item IDs, dependencies, blockers, acceptance criteria, and cursor;
6. fingerprint-aware validation freshness;
7. fail-closed offline reconnect behavior;
8. preservation of unrelated dirty work and prohibition on destructive recovery.

`qbit-ai-toolkit` is the installer source-of-truth and is intentionally not self-installed as a normal consumer, but its root `AGENTS.md` follows the same Continuity v2 checkpoint policy. Its repository-local `.ai/context/` launchers mirror the canonical member runtime and repository validation fails if those scripts drift from the installer templates.

## Release and rollout contract

A Continuity lifecycle release is not complete after editing templates. Before fleet rollout, validate installer metadata, unit tests, Windows/POSIX installer integration, legacy migration, lifecycle behavior, cross-platform parity, and real-member behavior where the change can affect runtime continuity.

Roll out repositories one at a time. On dirty worktrees, stage/commit only installer-owned paths and prove existing product work remains unstaged/untracked. Never use reset, clean, stash, rebase, or force-push to simplify rollout.

## Canonical implementation locations

- installer metadata and entrypoints: `installers/ai-context/`
- member policy template: `installers/ai-context/templates/common/member/agents-block.md.tpl`
- member launchers: `installers/ai-context/templates/common/member/context.ps1`, `context.sh`, and `context.py`
- checkpoint schema: `installers/ai-context/templates/common/central/schemas/checkpoint.schema.json`
- continuity invariants: `installers/ai-context/templates/common/central/tooling/context-continuity.ps1` and `context-lifecycle.py`
- lifecycle regression suites: `installers/ai-context/templates/common/central/tests/`
- generated central operations guide: `installers/ai-context/templates/common/central/docs/context-automation.md.tpl`

When documentation and runtime behavior disagree, fix the drift in the owning source and tests rather than treating documentation as runtime authority.
