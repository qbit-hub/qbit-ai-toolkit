# Changelog

## 1.2.7

- Make PowerShell installer-generated dates and backup/state timestamps explicitly Gregorian and culture-invariant, including hosts using `fa-IR` or other non-Gregorian calendars.
- Add a regression test that forces `fa-IR` culture and verifies bootstrap and installer-state timestamps still use the Gregorian calendar.

## 1.2.6

- Fix PowerShell 7 checkpoint secret scanning so JSON scalar value types such as auto-materialized `DateTime` timestamps are treated as leaves instead of recursively walking self-referential properties.
- Run installed Windows lifecycle regression launchers with the same PowerShell host as the parent suite so PowerShell 7 behavior is covered rather than silently falling back to Windows PowerShell 5.1.
- Add regression coverage for the value-type leaf guard while preserving fail-closed secret detection for string and object payloads.

## 1.2.5

- Exclude sibling clones of the configured central context remote from read-only fleet audit candidates even when their local directory name differs from the remote repository name.
- Canonicalize common HTTPS/SSH/SCP-style Git remote identities without network access so central-repository exclusion remains deterministic and read-only.
- Add Windows and POSIX regression coverage proving a differently named local clone of the central context remote is not reported as an unregistered member candidate.

## 1.2.4

- Restore backward compatibility with project-owned repository registry metadata used by existing Continuity fleets, including top-level blocks such as `excluded_directories` and repository metadata such as `authority`, `publish`, and `notes`.
- Keep membership semantics fail-closed for the canonical `project`, repository IDs, `path`, and required `role` fields while structurally validating and ignoring unrelated project-owned metadata.
- Add rich-registry compatibility fixtures to Python unit and Windows/POSIX installed-layout lifecycle coverage so legacy fleet registry shapes remain supported.

## 1.2.3

- Enforce `repositories/repositories.yaml` as the explicit Continuity membership registry so unregistered members cannot silently start or checkpoint as healthy project members.
- Add a read-only `audit` lifecycle action that reports missing/mismatched registered repositories and plausible unregistered sibling repositories without mutating project-owned registry state or Git history.
- Replace online checkpoint auto-rebase fallback with ancestry-based fail-closed synchronization that preserves divergent histories and forbids automatic merge, rebase, reset, or force-push.
- Add Windows/POSIX unit, integration, and real Git E2E coverage for membership enforcement, read-only fleet audit, and concurrent divergent checkpoint writers.
- Keep toolkit root launchers, canonical Continuity documentation, generated central operations guidance, and repository validation contracts synchronized with the new lifecycle surface.

## 1.2.2

- Align the toolkit's own agent/checkpoint policy and canonical documentation with Continuity v2 so new substantive checkpoints use schema v2 tracked continuity instead of the legacy schema v1 compatibility path.
- Synchronize the toolkit's repository-local Windows/POSIX context launchers with the canonical member runtime, including `export`, `import`, `reconnect`, cache path hardening, and offline continuation behavior.
- Add a first-class Continuity v2 architecture/operations guide, explicitly distinguish checkpoint schema v2 from the independent member-config and transfer-manifest schema v1 namespaces, and make the installer README report the current release correctly.
- Add repository validation coverage that fails when Continuity v2 policy, documentation, root runtime scripts, managed runtime action surfaces, or installer version references drift out of sync.

## 1.2.1

- Fix offline export on real installed central-context repositories by keeping canonical secret-rejection fixtures semantically equivalent while avoiding literal secret-like tokens in the tracked test source itself.
- Extend lifecycle regression fixtures so offline export scans the canonical PowerShell/POSIX lifecycle test files, preventing recurrence of this false-positive release defect.

## 1.2.0

- Add Continuity v2 tracked workstreams with stable work-item IDs, execution cursor, repository roles, dependencies/blockers, acceptance criteria, validation requirements, and archived terminal workstreams.
- Enforce fail-closed continuity invariants including silent work-item loss prevention, invalid status transitions, dependency-cycle rejection, duplicate validation-ID rejection, and protection against legacy/snapshot checkpoints erasing unresolved tracked work.
- Bind structured validation ledger entries to repository HEAD plus deterministic worktree fingerprints and report stale evidence after member source changes.
- Add offline context `export`, `import`, and `reconnect` workflows with Git-bundle integrity checks, SHA-256/size verification, repository/branch/source-HEAD binding, tracked-context secret scanning, and safe no-network checkpoint continuation.
- Reject divergent offline/remote writers during reconnect without automatic merge, rebase, reset, or force-push; remove offline mode only after successful synchronization.
- Add Windows, POSIX, and native WSL/Linux lifecycle coverage for offline round-trip, tamper/conflict rejection, reconnect behavior, and cross-platform deterministic installer ownership state.

## 1.1.2

- Canonicalize UTF-8 managed-file ownership hashes across BOM and LF/CRLF/CR line-ending differences so Git checkout normalization does not create false ownership conflicts.
- Preserve fail-closed behavior for semantic managed-file modifications while allowing verify/update after line-ending-only checkout changes.
- Add Windows and POSIX unit/integration regression coverage for cross-platform managed-file hashing.

## 1.1.1

- Add native Ubuntu/macOS GitHub Actions validation for the POSIX installer lifecycle.
- Make POSIX integration fixtures compatible with macOS Bash 3.2 by removing `mapfile` and using portable SHA-256 helpers.
- Make checkpoint verification clones explicitly target `main` so bare-remote default HEAD differences do not produce false failures on Linux/macOS.

## 1.1.0

- Add real Linux/macOS installer parity through Bash entrypoints backed by a Python 3.10+ standard-library engine.
- Provision both Windows and POSIX member launchers (`context.ps1`, `context.sh`, and `context.py`) and both central lifecycle engines so managed repositories remain portable across supported hosts.
- Add POSIX start/status/checkpoint behavior with safe cache refresh, dirty/diverged-cache refusal, secret-aware checkpoint validation, scoped context commits, and optional Git push through the normal credential chain.
- Make managed member lifecycle instructions platform-aware without changing authority or checkpoint semantics.
- Add POSIX unit, installer integration, legacy migration, installed central lifecycle, end-to-end, and cross-platform ownership-state parity coverage.
- Reject absolute, traversal, symlink, and reparse-point context cache paths so runtime cache operations remain inside the member repository.
- Report clean-but-diverged caches as `DIVERGED_LOCAL_CONTEXT` (and behind-only caches as `STALE_LOCAL_CONTEXT`) instead of incorrectly labeling them current.

## 1.0.2

- Refresh ownership state when the installed payload is unchanged but the recorded installer version is older.
- Exclude generated AI context cache and transient `.ai-bridge` runtime files from toolkit repository hygiene validation.
- Add regression coverage for version-only ownership-state upgrades and runtime-path validator exclusions.

## 1.0.1

- Add explicit `-MigrateLegacy` support for the pre-installer manual rollout shape.
- Canonicalize semantically equivalent legacy member config JSON during migration.
- Convert recognized legacy `AGENTS.md`, `AI_CONTEXT.md`, and `.ai-bridge/.gitignore` content into managed blocks without duplicating policy text.
- Keep the member `AI_CONTEXT.md` repository-role header project-owned while managing only the zero-touch lifecycle/authority tail.
- Preserve unknown or modified legacy content as a conflict; migration remains opt-in and fail-closed.

## 1.0.0

- Add Windows member/central AI Context lifecycle installation.
- Add ownership state, managed-block updates, conflict detection, explicit matching adoption, byte-exact rollback, and recovery backups for replaced owned content.
- Add canonical zero-touch member launcher with safe GitHub CLI credential fallback and clean-only origin migration.
- Add central checkpoint lifecycle, schema, regression suite, typed authority bootstrap, and project-owned continuity seed structure.
- Preserve central continuity data during installer update and uninstall.
