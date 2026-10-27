# Reviewed independent-root enrollment

An unknown historical owning root must not be guessed from a branch, source commit or fingerprint. A reviewed independent-root enrollment admits a named current root to publish its own new scoped continuity; it neither adopts the old Workstream nor supplies a checkpoint receipt. Without a valid committed review, the unbound-active-legacy guard continues to reject Start and Checkpoint.

The project owner may publish `references/continuity-reconciliations/<repository>.json` through an explicitly reviewed canonical Context change. It has these exact fields:

| Field | Contract |
| --- | --- |
| `schemaVersion`, `kind` | `1`, `independent-root-enrollment` (a separate schema namespace) |
| `project`, `repository`, `contextRemote` | Exact member project/repository and configured canonical origin |
| `baseCommit` | Existing ancestor commit containing the three original unbound records |
| `review` | Exact `decision: preserve-unbound-and-enroll-independent-roots`, nonempty `authority`, nonempty string array `provenance` |
| `legacy` | Exactly three `{path, blob}` entries: derived repository manifest, state and handoff paths; exact original Git blobs |
| `workstream` | `{id, sourceCommit, path, blob, disposition}` with ancestor Git provenance and the exact currently preserved global record |
| `enrollments` | Explicit `{memberWorktree, worktreeId, scope, workstreamId}` entries; absolute roots, existing root-ID algorithm, distinct new initial scope/Workstream |

Only two historical dispositions are supported. `historical-contributor-superseded` requires an exact terminal archive with every item terminal and no current cursor; its publishing repository may differ from that of an earlier contributor summary. `preserved-unbound-proposed` requires an unchanged PROPOSED Workstream owned by the same repository/session with all items PENDING. This does not resume that proposal or authorize implementation. Other unresolved legacy cases still require a separate ownership reconciliation.

The first-addition review blob is immutable. Its provenance commits must precede the review and remain in current history. Protected legacy blobs must match both the recorded base and current tree. Unsafe paths, reparse points, unknown keys, duplicate roots/targets, changed review bytes, mismatched protected files and missing scoped receipts with surviving owning records fail closed. A new root's first checkpoint must use the exact admitted v2 tracked scope and new Workstream ID. The old global ID and all existing ownership/terminal-transition guards remain enforced.

Runtime JSON exposes `continuity.legacyEvidence` separately from the owning scoped Workstream, before and after publication. Markdown labels that evidence as an unknown-root historical/pending intention, never a current receipt or fresh validation. Checkpoint keeps the original manifest/state/handoff and global Workstream untouched on every publication, including sibling checkpoints. The journal retains the ordinary nine required paths for a tracked checkpoint: three protected legacy entries remain unchanged, while only the new Session, scoped triple, ledger and new Workstream change. Journal and scoped Manifest bind the immutable review/protected-blob proof; replay and native Verify independently validate it. Start alone cannot satisfy Verify or the host's checkpoint requirement.

The POSIX lifecycle currently rejects any repository with a committed or local reconciliation record before lifecycle writes. It does not implement Windows independent-root enrollment; this explicit unsupported-platform boundary prevents the older repository-summary writer from overwriting protected evidence. Ordinary repositories without a reconciliation record retain their existing POSIX behavior.

Installer version remains `1.2.9` for this correction. Record the exact canonical Git commit and source hashes to distinguish corrected assets; a shared version string does not establish byte parity, a completed rollout, or publication. No release tag or checkpoint/member-config schema change is implied.

