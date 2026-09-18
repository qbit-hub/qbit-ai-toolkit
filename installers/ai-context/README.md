# AI Context Lifecycle installer

`installer.ai-context` installs the zero-touch AI context lifecycle as a versioned toolkit asset. The current stable release is `1.2.8`; Continuity v2 is supported on Windows, Linux, and macOS in two modes:

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
