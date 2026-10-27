# AI Context Lifecycle installer

`installer.ai-context` installs the zero-touch AI context lifecycle as a versioned toolkit asset. The current stable release is `1.2.9` for this source revision (following version `1.2.8`); this source-level designation does not prove that a canonical branch has been merged, deployed, or independently accepted; Continuity v2 is supported on Windows, Linux, and macOS in two modes:

- `member`: installs repository launchers/config plus managed lifecycle blocks in `AGENTS.md`, `AI_CONTEXT.md`, `.gitignore`, and `.ai-bridge/.gitignore`.
- `central`: installs the canonical lifecycle engines, member launcher templates, checkpoint schema, regression suites, and automation documentation. It seeds project continuity files only when absent; seeded continuity becomes project-owned immediately and is never overwritten or removed by installer update/uninstall.

The installer never runs application dependency installation and never performs `git add`, `git commit`, `git reset`, `git clean`, or `git stash` in the target repository. The lifecycle checkpoint engine performs scoped Git add/commit/push only inside the dedicated central context cache when a validated checkpoint explicitly requests that workflow.

## Platform requirements

- Windows: PowerShell 5.1+ and Git.
- Linux/macOS: Bash, Git, and Python 3.10+ from the host environment.

Both Windows and POSIX launchers/tooling are provisioned by either installer host so a managed repository remains portable after cloning on another supported platform.

The canonical architecture and operating contract for Continuity v2 is documented in [`../../docs/ai-tooling/continuity-v2.md`](../../docs/ai-tooling/continuity-v2.md). Checkpoint schema versions, member config schema versions, and offline-transfer manifest schema versions are independent namespaces: Continuity v2 means substantive checkpoints use checkpoint `schemaVersion: 2`; member config and transfer manifest formats intentionally remain at their own schema version `1` until those formats change.

## Member install

Windows:

```powershell
.\installers\ai-context\install.ps1 `
  -Operation install `
  -Mode member `
  -Target C:\work\service `
  -ProjectId example `
  -RepositoryId example-service `
  -ContextRemote https://github.com/example/example-ai-context.git `
  -ContextBranch main
```

Linux/macOS:

```bash
bash installers/ai-context/install.sh \
  --operation install \
  --mode member \
  --target /work/service \
  --project-id example \
  --repository-id example-service \
  --context-remote https://github.com/example/example-ai-context.git \
  --context-branch main
```

## Central install

Run against an existing Git work-tree root for the dedicated context repository.

Windows:

```powershell
.\installers\ai-context\install.ps1 `
  -Operation install `
  -Mode central `
  -Target C:\work\example-ai-context `
  -ProjectId example `
  -ProjectDisplayName Example `
  -RepositoryId example-ai-context `
  -ContextRemote https://github.com/example/example-ai-context.git `
  -ContextBranch main
```

Linux/macOS:

```bash
bash installers/ai-context/install.sh \
  --operation install \
  --mode central \
  --target /work/example-ai-context \
  --project-id example \
  --project-display-name Example \
  --repository-id example-ai-context \
  --context-remote https://github.com/example/example-ai-context.git \
  --context-branch main
```

## Operations

- `plan`: read-only conflict/action plan.
- `install`: fresh install or idempotent repeated install.
- `update`: requires ownership state and updates only installer-owned files/blocks.
- `verify`: read-only hash/block verification.
- `uninstall`: removes only installer-owned files/blocks; project-owned central seed files are preserved.

PowerShell uses `-OwnedModified replace`, `-AdoptMatching`, and `-MigrateLegacy`; POSIX uses the equivalent `--owned-modified replace`, `--adopt-matching`, and `--migrate-legacy` switches.

The replace policy permits replacing a modified installer-owned file/block after writing a recovery copy under ignored `.qbit-toolkit/ai-context/backups/`. It never overrides an unowned conflict. Matching adoption explicitly adopts byte-/block-identical pre-existing generated content into installer ownership.

Legacy migration is explicit and fail-closed. It accepts only the recognized pre-installer lifecycle sections plus a semantically equivalent member `config.json`; unknown or modified legacy content remains a conflict. During migration, repository-specific `AI_CONTEXT.md` role text is preserved while the lifecycle/authority tail becomes an installer-managed block.

State is written last to `.qbit/toolkit/installed/ai-context.json`. Mutations snapshot touched files and restore byte-exact content if a write fails. Managed paths reject path traversal and symlink/reparse-point escapes.

## Strict Windows synchronization gate (prepared 1.2.9)

After a reviewed member installation/update, the Windows gate is installed at `.ai/context/context-sync-gate.ps1` and referenced by the managed agent instructions:

```powershell
# Executed from the owning member repository root before substantive work:
powershell -NoProfile -ExecutionPolicy Bypass -File .ai/context/context-sync-gate.ps1 -MemberPath . -Mode Start

# Current-source checkpoint verification for local build and pre-merge gates:
powershell -NoProfile -ExecutionPolicy Bypass -File .ai/context/context-sync-gate.ps1 -MemberPath . -Mode Verify

# Executed after writing a validated Continuity v2 checkpoint payload:
powershell -NoProfile -ExecutionPolicy Bypass -File .ai/context/context-sync-gate.ps1 -MemberPath . -Mode Checkpoint
```

Start requires fresh runtime/member identity, canonical cache origin, clean cache and live remote equality. `Status` probes existing runtime/cache/remote health without mutation and emits `CONTEXT_STATUS_OK`; it does not accept a milestone. `Verify` regenerates current source evidence through lifecycle status and requires an exact published Continuity v2 checkpoint: owning Manifest/state/new Session publication commit, operation ID, complete payload digest, source HEAD/branch/dirty/fingerprint/Worktree identity, and Tracked cursor/session consistency. It refreshes ignored cache/runtime state and can fetch/fast-forward a clean cache; it does not stage or write member source.

`Checkpoint` publishes and verifies that same chain. An exact interrupted/completed operation can safely replay without duplicate sessions or an extra commit. A new operation creates a unique GUID Session and fails closed on unrelated publication, stale evidence, source/payload races, forged journal scope or conflicting writers. Failure exits **3 / CONTEXT_UNSYNCED**, preserving source, payload, journal and Git histories. Old fingerprints become historical after `fingerprint-v2`; obtain a fresh reviewed checkpoint after upgrade.

Windows receipts belong to a repository and normalized owning Worktree root. The scoped Manifest, state and handoff under `manifests/worktrees/`, `state/worktrees/` and `handoffs/worktrees/` remain authoritative after a sibling publishes; repository-level files are compatibility summaries. Missing own receipts cannot erase unresolved continuation. Workstream owner and Session must agree, and Verify preserves the immutable published validation-ledger prefix while allowing another Worktree to append entries.

Explicit Windows offline export/import uses transfer manifest schema `2` to validate the original scoped receipt, bundle, source HEAD/branch/fingerprint and target identity. It carries the original cursor into the imported runtime, then records transfer provenance in the new checkpoint rather than rewriting the original scoped records. Ordinary clones cannot take over another Worktree's mutable Workstream. POSIX transfer manifests remain at schema `1`; strict Windows isolation and transfer parity are not claimed for POSIX. Managed-text integrity normalizes UTF-8 BOM and line endings according to the installer; payload digests and source fingerprints remain byte-sensitive.

The [operating and recovery contract](docs/continuity-guarantee.md) documents installation, strict closeout, interrupted publication, independent recovery and preservation boundaries.
**Important limits:** this is a fail-closed **command gate**, not an automatically invoked OS/Codex Desktop hook. An agent can still skip commands until the installed host's workflow enforces them. The strict gate is Windows-only in this candidate; POSIX uses the existing lifecycle but does not yet have equivalent strict remote-head evidence. Do not claim guaranteed cross-platform or all-member rollout until those separate acceptance gates pass.

## Runtime lifecycle

Member agents select the launcher for the active host:

```text
Windows      .ai/context/context.ps1 start|status|checkpoint|audit|export|import|reconnect
Linux/macOS  bash .ai/context/context.sh start|status|checkpoint|audit|export|import|reconnect
```

The POSIX launcher uses only Python's standard library plus Git. Cache refresh is non-destructive: dirty context caches are never overwritten, diverged caches are not reset, and dirty caches refuse automatic origin migration/checkpointing. New substantive checkpoints use schema v2 tracked continuity with stable work-item IDs, execution cursor, dependencies, acceptance criteria, and structured validation ledger entries. The lifecycle rejects silent work-item loss, invalid status transitions, dependency cycles, duplicate validation IDs, and snapshot/downgrade attempts that would erase unresolved work. Validation evidence is bound to a deterministic member worktree fingerprint and is reported stale after relevant source changes. Secret-like material is rejected before central continuity files are written.

`repositories/repositories.yaml` is the explicit central membership registry. A member's configured `project` must match the central registry project and its `repository` ID must exist in that registry with a non-empty `role`. `start` and `checkpoint` fail closed for unregistered members; `status` still emits runtime evidence but returns an unhealthy exit status and includes membership diagnostics. The read-only `audit` action reconciles registry entries with nearby Git worktrees, reporting missing/mismatched registered repositories and plausible unregistered sibling repositories without modifying the registry, member repositories, or central history.

Online checkpoint publication uses ancestry checks rather than automatic history rewriting. A normal push is attempted first; after a rejection the lifecycle fetches the configured branch and only retries/fast-forwards when one side is already an ancestor of the other. Independent local and remote advances fail closed with both histories preserved. The checkpoint path never auto-merges, rebases, resets, or force-pushes divergent context history.

`export` creates an ignored `.ai-bridge/context-transfer/` package containing a verified Git bundle plus a manifest with project/repository identity, source provenance, continuity summary, byte length, and SHA-256. Export requires a clean context cache and scans all tracked context files for unsupported file types, symlink/reparse escapes, non-UTF-8 content, and secret-like material. `import` verifies the manifest, bundle size/hash, Git bundle integrity, configured repository/branch identity, and exact source HEAD before creating or accepting a local context cache. An imported cache runs `start` and `checkpoint` without network access and reports freshness as `OFFLINE_IMPORTED_CONTEXT`; offline checkpoints commit locally and never attempt a push.

When connectivity returns, `reconnect` is the only supported automatic exit from imported offline mode. If the remote context branch is an ancestor of the local offline history, reconnect performs a normal non-force push. If the local history is an ancestor of the remote, it fast-forwards locally. If both sides advanced independently, reconnect fails closed and preserves both histories plus the offline marker; it never auto-merges, rebases, resets, or force-pushes divergent continuity.

## Security and authority

Context remotes must not embed credentials. Windows runtime Git uses the normal credential chain first and may retry failed private `github.com` operations through `gh auth git-credential` when GitHub CLI is available. POSIX runtime Git delegates authentication to normal Git credential helpers and does not persist credentials in state or configuration.

AI context remains coordination evidence, never implementation authority. Central project continuity is deliberately outside installer ownership after bootstrap.
