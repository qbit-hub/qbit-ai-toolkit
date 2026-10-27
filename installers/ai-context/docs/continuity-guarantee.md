# Windows continuity verification contract (1.2.9 candidate)

This is a fail-closed milestone contract, not a promise of uninterrupted network access. Windows PowerShell 5.1 and PowerShell 7 are tested hosts. The strict gate and the new journal/fingerprint hardening are Windows implementations; native Linux/macOS equivalence has not been certified. Existing POSIX portability support is not evidence of strict parity.

## Commands

From the checked-out Toolkit repository root, first plan the **explicitly authorized** target installation. Supply the actual member Git worktree root, rather than relying on a hardcoded developer-machine path:

```powershell
$toolkit = (Get-Location).Path
$member = Read-Host 'Absolute path of the authorized member Git worktree'
$installer = Join-Path $toolkit 'installers/ai-context/install.ps1'
& $installer -Operation plan -Mode member -Target $member -ProjectId qbit -RepositoryId '<registered-repository-id>' -ContextRemote 'https://github.com/qbit-hub/qbit-ai-context.git' -ContextBranch main
& $installer -Operation install -Mode member -Target $member -ProjectId qbit -RepositoryId '<registered-repository-id>' -ContextRemote 'https://github.com/qbit-hub/qbit-ai-context.git' -ContextBranch main
& $installer -Operation verify -Target $member
# Existing installations: plan/update instead of install; review every conflict.
& $installer -Operation update -Target $member
```

`-OwnedModified replace` explicitly backs up modified managed assets before replacing them. Never use it for unowned conflicts or to erase project content. Installer state is written last; failed mutation restores the touched bytes. Uninstall preserves seeded project-owned continuity. Both release manifest and VERSION must match the engine release identity before an operation proceeds.

From the member root:

```powershell
$gate = Join-Path $member '.ai/context/context-sync-gate.ps1'
& $gate -MemberPath $member -Mode Start
# Health only: existing runtime/cache/live remote. Does not close a milestone.
& $gate -MemberPath $member -Mode Status
# Write the complete, schema-v2 .ai-bridge/context-checkpoint.json first.
# This commits/pushes CENTRAL Context and requires owner publication authority.
& $gate -MemberPath $member -Mode Checkpoint
# Independent local closeout/build/pre-merge entrypoint, also after a restart:
& $gate -MemberPath $member -Mode Verify
```

Start loads current context and checks membership, runtime, canonical origin and live remote equality. Status is a read-only health probe. Verify requires prior Start evidence, executes lifecycle status to regenerate current source evidence, and verifies the exact published checkpoint. The lifecycle launcher can fetch/fast-forward its **clean** cache during status; ignored runtime evidence is refreshed. Verify is therefore not a side-effect-free probe. Each gate child operation has a bounded timeout (default 30 seconds, configurable with `-TimeoutSeconds`); a hung child tree is terminated and publication is treated as unconfirmed.

Verify returns exit 0 / `CONTEXT_SYNC_OK` only when the current member HEAD, branch, dirty flag, Worktree root and fingerprint match the canonical published Manifest; the Manifest, owning state and newly added Session belong to the same publication commit; the Session binds the operation ID and complete payload digest; and tracked workstream/cursor/session provenance agrees. Later state/Session/Workstream-only rewrites cannot reuse the old Manifest. Pending ignored payload edits also block. Manifest/runtime expiration defaults to 120 minutes; use the explicit bounded `-MaxAgeMinutes` policy when a workflow needs another interval.

Failure is exit 3 / `CONTEXT_UNSYNCED`. A health pass, an unrelated remote advancement, or a touched receipt file is not a completed milestone.

## Fingerprints and historical evidence

`fingerprint-v2` hashes NUL-delimited Git discovery, source HEAD, porcelain state, complete index identity and changed/untracked content with unambiguous length prefixes. It preserves Unicode paths/content and index-only changes. Existing files are hashed in one Git process; batch failure blocks rather than degrading to thousands of subprocesses or marking files deleted. Per-command long-path support avoids changing the user's Git configuration. Older fingerprints remain historical; obtain a new reviewed checkpoint after upgrading, rather than relabeling old validation as current.

## Retry and preservation

The ignored `.ai-bridge/context-checkpoint-pending.json` stores operation identity, exact payload digest, source fingerprint, base commit, expected Session and scoped blob hashes. An exclusive cache lock serializes writers. The journal is replaced atomically and its previous version is preserved. Completed receipts remain available for idempotent replay; they are not central publication authority.

After an interrupted publication, inspect without modifying the pending evidence:

```powershell
Get-Content -Encoding UTF8 -LiteralPath (Join-Path $member '.ai-bridge/context-checkpoint-pending.json') -Raw
git -C (Join-Path $member '.ai/context/cache/project-context') status --short --branch
# For the SAME payload/source and a recoverable prepared/committed operation:
& $gate -MemberPath $member -Mode Checkpoint
& $gate -MemberPath $member -Mode Verify
```

Failed commit, rejected push, commit-before-journal interruption and publication-success/runtime-failure can replay the same logical checkpoint without a duplicate Session. Journal file scope is reconstructed from the owning payload/base Manifest; adding unrelated paths to a journal cannot authorize staging them. Superseded receipts, divergent histories, unrelated dirty files, incomplete `preparing` records, changed pending source and changed pending payload stop for manual review. Keep the whole cache, payload, journal and `.previous` together. Do not delete the journal, reset, clean, stash or force-push to make retry pass. A changed payload during publication is retained; the previously published operation is historical until a reviewed recovery checkpoint is created.

An incomplete preparation deliberately has no automatic destructive reconciliation. Preserve a byte-for-byte copy in the project's approved backup location and review its scoped changes against a fresh independent clone. The Qbit historical `project/recover-member-context-cache.ps1` is restricted to its documented single dirty-handoff case; it is not a general journal recovery command. No automatic tool can safely guess which concurrent unpublished decisions should prevail.

## Independent recovery

Use a fresh, explicitly authorized registered member clone, install the accepted version there, and execute its Start gate. It retrieves central state without the original conversation or private journal. Read the **original owning repository's** records, rather than misattributing them to the reader:

```powershell
$reader = Read-Host 'Absolute path of the authorized independent reader Git worktree'
& (Join-Path $reader '.ai/context/context-sync-gate.ps1') -MemberPath $reader -Mode Start
$cache = Join-Path $reader '.ai/context/cache/project-context'
$owner = '<original-owning-repository-id>'
$manifest = Get-Content -Encoding UTF8 (Join-Path $cache "manifests/repositories/$owner.json") -Raw | ConvertFrom-Json
$manifest | Select-Object repository,memberWorktree,commit,worktreeFingerprint,session,checkpointId
Get-Content -Encoding UTF8 (Join-Path $cache "state/repositories/$owner.md") -Raw
Get-Content -Encoding UTF8 (Join-Path $cache $manifest.session) -Raw
if ($manifest.continuity.workstreamPath) { Get-Content -Encoding UTF8 (Join-Path $cache $manifest.continuity.workstreamPath) -Raw }
Get-Content -Encoding UTF8 (Join-Path $cache 'state/pending-decisions.md') -Raw
```

A new clone can recover coordination, not uncommitted product source. Worktree identity remains the original provenance until the new owner intentionally checkpoints its own source. Published sessions retain decisions/rejected approaches/questions and workstreams retain stable item/cursor IDs. Completed archives survive later snapshots and workstreams.

Workstream IDs are global. Each has one publishing repository owner, recorded in `lastCheckpoint.repository`; repositories listed as collaborators do not gain implicit overwrite authority. A different member cannot replace that ID, even if it has no previous member Manifest. Ownership transfer requires an explicitly reviewed reconciliation; automatic checkpoints fail closed. The existing global terminal record remains transition authority after snapshots or newer cursors, so an old ID cannot be reused to reopen archived work.

## Enforcement boundary

Codex hooks require real user review/trust and only cover the selected owning Worktree. Direct script tests do not establish host activation. Use the independent strict Verify command at each build/closeout/merge entrypoint. Qbit's multi-repository `project/verify-qbit-merge-context.ps1` additionally checks declared scope coverage and trusted gate bytes; functional tests, owner Git approval and branch protection remain separate. Arbitrary tools, disabled hooks, unselected Worktrees and source edits after verification cannot be controlled by this command. No fixture proves GitHub publication or fleet deployment.
