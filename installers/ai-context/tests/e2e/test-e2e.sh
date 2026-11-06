#!/usr/bin/env bash
set -euo pipefail
installer_root=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)
install="$installer_root/install.sh"
verify="$installer_root/verify.sh"
root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT
remote="$root/context.git"
central="$root/central"
member="$root/member"
verify_clone="$root/verify"

git init --bare "$remote" >/dev/null
git init -b main "$central" >/dev/null
git -C "$central" config user.name Test
git -C "$central" config user.email test@example.invalid
printf '# bootstrap\n' >"$central/bootstrap.md"
git -C "$central" add bootstrap.md
git -C "$central" commit -m bootstrap >/dev/null
git -C "$central" remote add origin "$remote"

bash "$install" --operation install --mode central --target "$central" --project-id demo --project-display-name Demo --repository-id demo-ai-context --context-remote "$remote" --context-branch main --format json >/dev/null
bash "$verify" --target "$central" --format json >/dev/null
cat >"$central/repositories/repositories.yaml" <<'EOF'
project: demo
repositories:
  demo-member:
    path: ../member
    role: application-member
EOF
git -C "$central" add .
git -C "$central" commit -m 'install central context' >/dev/null
git -C "$central" push -u origin main >/dev/null
bash "$central/tests/context-lifecycle.tests.sh"

git init -b main "$member" >/dev/null
git -C "$member" config user.name Test
git -C "$member" config user.email test@example.invalid
printf '# member\n' >"$member/README.md"
git -C "$member" add README.md
git -C "$member" commit -m bootstrap >/dev/null

bash "$install" --operation install --mode member --target "$member" --project-id demo --project-display-name Demo --repository-id demo-member --context-remote "$remote" --context-branch main --format json >/dev/null
bash "$verify" --target "$member" --format json >/dev/null
git -C "$member" add .
git -C "$member" commit -m 'install member context' >/dev/null

bash "$member/.ai/context/context.sh" start >/dev/null
cache="$member/.ai/context/cache/project-context"
git -C "$cache" config user.name Test
git -C "$cache" config user.email test@example.invalid
test -f "$member/.ai-bridge/context-runtime.md"
test -f "$member/.ai-bridge/context-runtime.json"
grep -q 'demo-member' "$member/.ai-bridge/context-runtime.md"
cat >"$member/.ai-bridge/context-checkpoint.json" <<'EOF'
{
  "schemaVersion": 2,
  "repository": "demo-member",
  "scope": "posix-installer-e2e",
  "status": "VALIDATED",
  "objective": "Validate installer-provisioned POSIX lifecycle end to end.",
  "confirmedFindings": ["context.sh start generated runtime context."],
  "decisions": ["Use the POSIX lifecycle without PowerShell."],
  "rejectedApproaches": [],
  "validation": ["local bare Git remote"],
  "openQuestions": [],
  "nextAction": "Keep POSIX parity covered by regression tests.",
  "continuity": {"mode": "snapshot", "workstream": null, "validationLedger": []}
}
EOF
bash "$member/.ai/context/context.sh" checkpoint >/dev/null
bash "$member/.ai/context/context.sh" verify >/dev/null
test ! -e "$member/.ai-bridge/context-checkpoint.json"

git clone --branch main --single-branch "$remote" "$verify_clone" >/dev/null 2>&1
python3 - "$verify_clone" "$member" <<'PY'
import json, pathlib, sys
root=pathlib.Path(sys.argv[1])
import hashlib
member=str(pathlib.Path(sys.argv[2]).resolve())
normalized=member.replace('\\','/').rstrip('/')
if len(normalized)>1 and normalized[1]==':': normalized=normalized.lower()
wid='wt-'+hashlib.sha256(normalized.encode()).hexdigest()[:32]
value=json.loads((root/f'manifests/worktrees/demo-member/{wid}.json').read_text())
assert value['repository']=='demo-member'
assert value['status']=='VALIDATED'
assert value['scope']=='posix-installer-e2e'
assert value['continuity']['mode']=='snapshot'
for path in value['receiptPaths'].values(): assert (root/path).is_file()
assert (root/value['session']).is_file()
PY
# A real linked sibling has no owning receipt and cannot borrow this one.
git -C "$member" worktree add -b foreign "$root/foreign" >/dev/null
bash "$root/foreign/.ai/context/context.sh" start >/dev/null
if bash "$root/foreign/.ai/context/context.sh" verify >/dev/null 2>&1; then
  printf 'FAIL foreign Worktree borrowed a receipt\n' >&2
  exit 1
fi
printf 'PASS POSIX AI Context installer E2E\n'
