#!/usr/bin/env bash
set -euo pipefail

here=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
central_root=$(CDPATH= cd -- "$here/.." && pwd -P)
# Exercise the frozen 1.2.9 consumer against the current central legacy engine.
# The new installed strict online contract has separate integration/E2E gates.
member_context_py="$here/fixtures/member-1.2.9/context.py"
member_context_sh="$central_root/templates/member/context.sh"

pass=0
fail=0
log_pass() { pass=$((pass+1)); printf 'PASS %s\n' "$1"; }
log_fail() { fail=$((fail+1)); printf 'FAIL %s\n' "$1" >&2; }
assert_file() { [[ -f "$1" ]] || { printf 'missing file: %s\n' "$1" >&2; return 1; }; }
native_path() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s\n' "$1"; fi; }

git_identity() {
  git -C "$1" config user.name "AI Context Test"
  git -C "$1" config user.email "ai-context-test@local.invalid"
}

seed_central() {
  local repo=$1
  mkdir -p "$repo/project" "$repo/state" "$repo/repositories" "$repo/tooling" "$repo/tests"
  cp "$central_root/tooling/context-lifecycle.py" "$repo/tooling/context-lifecycle.py"
  cp "$here/context-lifecycle.tests.ps1" "$repo/tests/context-lifecycle.tests.ps1"
  cp "$here/context-lifecycle.tests.sh" "$repo/tests/context-lifecycle.tests.sh"
  cat >"$repo/AI_CONTEXT.md" <<'EOF'
# AI Context Entry Point
EOF
  cat >"$repo/project/authority.md" <<'EOF'
# Authority
AI context is coordination evidence, never implementation authority.
EOF
  cat >"$repo/state/current.md" <<'EOF'
# Current
Status: READY
EOF
  cat >"$repo/state/next-action.md" <<'EOF'
# Next Action
Continue validated work.
EOF
  cat >"$repo/repositories/repositories.yaml" <<'EOF'
project: test-project
excluded_directories:
  - Docs
  - worktrees
repositories:
  test-member:
    path: ../member
    role: implementation-owner
    authority:
      - implementation
      - tests
    publish: true
    notes: Project-owned metadata remains outside membership semantics.
EOF
}

make_fixture() {
  local root=$1
  local remote="$root/context.git"
  local remote_config
  remote_config=$(native_path "$remote")
  local central="$root/central"
  local member="$root/member"
  git init --bare "$remote" >/dev/null
  git init -b main "$central" >/dev/null
  git_identity "$central"
  seed_central "$central"
  git -C "$central" add .
  git -C "$central" commit -m seed >/dev/null
  git -C "$central" remote add origin "$remote"
  git -C "$central" push -u origin main >/dev/null
  git init -b main "$member" >/dev/null
  git_identity "$member"
  printf '# member\n' >"$member/README.md"
  mkdir -p "$member/.ai/context" "$member/.ai-bridge"
  cp "$member_context_py" "$member/.ai/context/context.py"
  cp "$member_context_sh" "$member/.ai/context/context.sh"
  printf 'cache/\nruntime/\n' >"$member/.ai/context/.gitignore"
  printf '*\n!.gitignore\n!README.md\n' >"$member/.ai-bridge/.gitignore"
  cat >"$member/.ai/context/config.json" <<EOF
{
  "schemaVersion": 1,
  "project": "test-project",
  "repository": "test-member",
  "context": {"remote": "$remote_config", "branch": "main", "cachePath": ".ai/context/cache/project-context"},
  "behavior": {"ensureOnStart": true, "refreshOnStart": true, "loadOnStart": true, "checkpointAfterValidation": true, "checkpointBeforeHandoff": true, "commitContext": true, "pushContext": true}
}
EOF
  git -C "$member" add README.md .ai/context/config.json .ai/context/context.py .ai/context/context.sh .ai/context/.gitignore .ai-bridge/.gitignore
  git -C "$member" commit -m seed >/dev/null
  printf '%s\n' "$member"
}

write_tracked_checkpoint() {
  local member=$1
  local validation_id=${2:-VAL-1}
  python3 - "$member/.ai-bridge/context-checkpoint.json" "$validation_id" <<'PY'
import json, pathlib, sys
path = pathlib.Path(sys.argv[1])
validation_id = sys.argv[2]
data = {
    "schemaVersion": 2,
    "repository": "test-member",
    "scope": "continuity-v2",
    "status": "IN_PROGRESS",
    "objective": "Preserve the exact active workstream across sessions.",
    "confirmedFindings": ["Structured workstream state is available."],
    "decisions": ["Never drop unresolved work items implicitly."],
    "rejectedApproaches": ["Free-form nextAction as the only continuity state."],
    "validation": ["Continuity fixture prepared."],
    "openQuestions": [],
    "nextAction": "Finish WS-1.",
    "continuity": {
        "mode": "tracked",
        "workstream": {
            "id": "landing-polish",
            "title": "Landing polish backlog",
            "status": "IN_PROGRESS",
            "objective": "Finish the durable landing backlog without losing pending work.",
            "repositories": [
                {"repository": "test-member", "role": "implementation-owner"},
                {"repository": "test-contracts", "role": "contract-reference"},
            ],
            "cursor": {
                "currentItemId": "WS-1",
                "lastCompletedItemId": None,
                "phase": "implementation",
                "lastCompletedAction": None,
                "nextAction": "Finish WS-1.",
            },
            "items": [
                {
                    "id": "WS-1",
                    "title": "Implement structured backlog",
                    "status": "IN_PROGRESS",
                    "priority": "HIGH",
                    "scope": ["tooling/context-lifecycle"],
                    "acceptanceCriteria": ["Workstream survives checkpoint and start."],
                    "dependsOn": [],
                    "blockedBy": [],
                    "validationRequirements": ["lifecycle-e2e"],
                    "notes": [],
                },
                {
                    "id": "WS-2",
                    "title": "Validate offline resume",
                    "status": "PENDING",
                    "priority": "HIGH",
                    "scope": ["tests/context-lifecycle"],
                    "acceptanceCriteria": ["Fresh session can identify the exact next item."],
                    "dependsOn": ["WS-1"],
                    "blockedBy": [],
                    "validationRequirements": ["offline-resume-e2e"],
                    "notes": [],
                },
            ],
        },
        "validationLedger": [
            {
                "id": validation_id,
                "kind": "integration",
                "result": "PASS",
                "repository": "test-member",
                "scope": "continuity-v2",
                "summary": "Initial tracked continuity fixture passed.",
                "timestamp": "2026-08-25T20:00:00+03:30",
                "command": "context checkpoint fixture",
                "evidenceRefs": [],
            }
        ],
    },
}
path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
PY
}

run_test() {
  local name=$1
  shift
  if "$@"; then log_pass "$name"; else log_fail "$name"; fi
}

test_fresh_start() {
  local root member
  root=$(mktemp -d)
  member=$(make_fixture "$root")
  bash "$member/.ai/context/context.sh" start >/dev/null
  git -C "$member/.ai/context/cache/project-context" config user.name "AI Context Test"
  git -C "$member/.ai/context/cache/project-context" config user.email "ai-context-test@local.invalid"
  assert_file "$member/.ai-bridge/context-runtime.md"
  assert_file "$member/.ai-bridge/context-runtime.json"
  [[ -d "$member/.ai/context/cache/project-context/.git" ]]
}

test_status() {
  local root member out
  root=$(mktemp -d)
  member=$(make_fixture "$root")
  bash "$member/.ai/context/context.sh" start >/dev/null
  git -C "$member/.ai/context/cache/project-context" config user.name "AI Context Test"
  git -C "$member/.ai/context/cache/project-context" config user.email "ai-context-test@local.invalid"
  out=$(bash "$member/.ai/context/context.sh" status)
  [[ "$out" == *'"repository": "test-member"'* ]]
}

test_checkpoint() {
  local root member remote_clone
  root=$(mktemp -d)
  member=$(make_fixture "$root")
  bash "$member/.ai/context/context.sh" start >/dev/null
  git -C "$member/.ai/context/cache/project-context" config user.name "AI Context Test"
  git -C "$member/.ai/context/cache/project-context" config user.email "ai-context-test@local.invalid"
  cat >"$member/.ai-bridge/context-checkpoint.json" <<'EOF'
{
  "schemaVersion": 1,
  "repository": "test-member",
  "scope": "posix-e2e",
  "status": "VALIDATED",
  "objective": "Validate POSIX checkpoint lifecycle.",
  "confirmedFindings": ["POSIX lifecycle ran."],
  "decisions": [],
  "rejectedApproaches": [],
  "validation": ["local bare remote"],
  "openQuestions": [],
  "nextAction": "Continue."
}
EOF
  bash "$member/.ai/context/context.sh" checkpoint >/dev/null
  [[ ! -e "$member/.ai-bridge/context-checkpoint.json" ]]
  remote_clone="$root/verify"
  git clone --branch main --single-branch "$root/context.git" "$remote_clone" >/dev/null 2>&1
  assert_file "$remote_clone/state/repositories/test-member.md"
  assert_file "$remote_clone/manifests/repositories/test-member.json"
}

test_invalid_status_rejected() {
  local root member
  root=$(mktemp -d)
  member=$(make_fixture "$root")
  bash "$member/.ai/context/context.sh" start >/dev/null
  git -C "$member/.ai/context/cache/project-context" config user.name "AI Context Test"
  git -C "$member/.ai/context/cache/project-context" config user.email "ai-context-test@local.invalid"
  cat >"$member/.ai-bridge/context-checkpoint.json" <<'EOF'
{"schemaVersion":1,"repository":"test-member","scope":"bad","status":"NOPE","objective":"x","confirmedFindings":[],"decisions":[],"rejectedApproaches":[],"validation":[],"openQuestions":[],"nextAction":"x"}
EOF
  if bash "$member/.ai/context/context.sh" checkpoint >/dev/null 2>&1; then return 1; fi
  [[ -f "$member/.ai-bridge/context-checkpoint.json" ]]
}

test_secret_rejected() {
  local root member
  root=$(mktemp -d)
  member=$(make_fixture "$root")
  bash "$member/.ai/context/context.sh" start >/dev/null
  git -C "$member/.ai/context/cache/project-context" config user.name "AI Context Test"
  git -C "$member/.ai/context/cache/project-context" config user.email "ai-context-test@local.invalid"
  local secret_like
  secret_like='Bear''er abcdefghijklmnop'
  printf '{"schemaVersion":1,"repository":"test-member","scope":"bad","status":"VALIDATED","objective":"%s","confirmedFindings":[],"decisions":[],"rejectedApproaches":[],"validation":[],"openQuestions":[],"nextAction":"x"}\n' "$secret_like" >"$member/.ai-bridge/context-checkpoint.json"
  if bash "$member/.ai/context/context.sh" checkpoint >/dev/null 2>&1; then return 1; fi
  [[ -f "$member/.ai-bridge/context-checkpoint.json" ]]
}

test_dirty_context_checkpoint_refused() {
  local root member cache
  root=$(mktemp -d)
  member=$(make_fixture "$root")
  bash "$member/.ai/context/context.sh" start >/dev/null
  git -C "$member/.ai/context/cache/project-context" config user.name "AI Context Test"
  git -C "$member/.ai/context/cache/project-context" config user.email "ai-context-test@local.invalid"
  cache="$member/.ai/context/cache/project-context"
  printf '\nlocal dirty\n' >>"$cache/state/current.md"
  cat >"$member/.ai-bridge/context-checkpoint.json" <<'EOF'
{"schemaVersion":1,"repository":"test-member","scope":"dirty","status":"VALIDATED","objective":"x","confirmedFindings":[],"decisions":[],"rejectedApproaches":[],"validation":[],"openQuestions":[],"nextAction":"x"}
EOF
  if bash "$member/.ai/context/context.sh" checkpoint >/dev/null 2>&1; then return 1; fi
  grep -q 'local dirty' "$cache/state/current.md"
}

test_fast_forward_clean_cache() {
  local root member cache before after central
  root=$(mktemp -d)
  member=$(make_fixture "$root")
  bash "$member/.ai/context/context.sh" start >/dev/null
  cache="$member/.ai/context/cache/project-context"
  before=$(git -C "$cache" rev-parse HEAD)
  central="$root/central"
  printf '# Current\nRemote advanced.\n' >"$central/state/current.md"
  git -C "$central" add state/current.md
  git -C "$central" commit -m advance >/dev/null
  git -C "$central" push origin main >/dev/null
  bash "$member/.ai/context/context.sh" start >/dev/null
  after=$(git -C "$cache" rev-parse HEAD)
  [[ "$before" != "$after" ]]
}

test_dirty_start_preserved() {
  local root member cache
  root=$(mktemp -d)
  member=$(make_fixture "$root")
  bash "$member/.ai/context/context.sh" start >/dev/null
  cache="$member/.ai/context/cache/project-context"
  printf 'preserve me\n' >"$cache/local-dirty-marker.txt"
  bash "$member/.ai/context/context.sh" start >/dev/null 2>&1
  [[ -f "$cache/local-dirty-marker.txt" ]]
  python3 - "$member/.ai-bridge/context-runtime.json" <<'PY'
import json,pathlib,sys
d=json.loads(pathlib.Path(sys.argv[1]).read_text())
assert d['context']['dirty'] is True
assert d['context']['freshness']=='DIRTY_LOCAL_CONTEXT'
PY
}

test_clean_origin_migration() {
  local root member cache replacement replacement_config actual
  root=$(mktemp -d)
  member=$(make_fixture "$root")
  bash "$member/.ai/context/context.sh" start >/dev/null
  cache="$member/.ai/context/cache/project-context"
  replacement="$root/replacement-context.git"
  git clone --bare "$root/context.git" "$replacement" >/dev/null 2>&1
  replacement_config=$(native_path "$replacement")
  python3 - "$member/.ai/context/config.json" "$replacement_config" <<'PY'
import json,pathlib,sys
p=pathlib.Path(sys.argv[1]); d=json.loads(p.read_text()); d['context']['remote']=sys.argv[2]; p.write_text(json.dumps(d,indent=2)+'\n')
PY
  bash "$member/.ai/context/context.sh" start >/dev/null
  actual=$(git -C "$cache" remote get-url origin)
  python3 - "$actual" "$replacement_config" <<'PY'
from pathlib import Path
import sys
assert Path(sys.argv[1]).resolve() == Path(sys.argv[2]).resolve()
PY
}

test_dirty_origin_migration_refused() {
  local root member cache replacement replacement_config original actual
  root=$(mktemp -d)
  member=$(make_fixture "$root")
  bash "$member/.ai/context/context.sh" start >/dev/null
  cache="$member/.ai/context/cache/project-context"
  original=$(git -C "$cache" remote get-url origin)
  printf 'preserve me\n' >"$cache/local-dirty-marker.txt"
  replacement="$root/replacement-context.git"
  git clone --bare "$root/context.git" "$replacement" >/dev/null 2>&1
  replacement_config=$(native_path "$replacement")
  python3 - "$member/.ai/context/config.json" "$replacement_config" <<'PY'
import json,pathlib,sys
p=pathlib.Path(sys.argv[1]); d=json.loads(p.read_text()); d['context']['remote']=sys.argv[2]; p.write_text(json.dumps(d,indent=2)+'\n')
PY
  if bash "$member/.ai/context/context.sh" start >/dev/null 2>&1; then return 1; fi
  actual=$(git -C "$cache" remote get-url origin)
  [[ "$actual" == "$original" && -f "$cache/local-dirty-marker.txt" ]]
}

test_diverged_cache_reported_read_only() {
  local root member cache central local_head after_head
  root=$(mktemp -d)
  member=$(make_fixture "$root")
  bash "$member/.ai/context/context.sh" start >/dev/null
  cache="$member/.ai/context/cache/project-context"
  git_identity "$cache"
  printf 'local commit\n' >"$cache/local-ahead.md"
  git -C "$cache" add local-ahead.md
  git -C "$cache" commit -m local-ahead >/dev/null
  local_head=$(git -C "$cache" rev-parse HEAD)
  central="$root/central"
  printf '# Current\nRemote divergent commit.\n' >"$central/state/current.md"
  git -C "$central" add state/current.md
  git -C "$central" commit -m remote-diverge >/dev/null
  git -C "$central" push origin main >/dev/null
  bash "$member/.ai/context/context.sh" start >/dev/null 2>&1
  after_head=$(git -C "$cache" rev-parse HEAD)
  [[ "$after_head" == "$local_head" ]]
  python3 - "$member/.ai-bridge/context-runtime.json" <<'PY'
import json,pathlib,sys
d=json.loads(pathlib.Path(sys.argv[1]).read_text())
assert d['context']['freshness']=='DIVERGED_LOCAL_CONTEXT'
assert d['context']['dirty'] is False
PY
}

test_v2_tracked_checkpoint() {
  local root member cache
  root=$(mktemp -d)
  member=$(make_fixture "$root")
  bash "$member/.ai/context/context.sh" start >/dev/null
  cache="$member/.ai/context/cache/project-context"
  git_identity "$cache"
  write_tracked_checkpoint "$member"
  bash "$member/.ai/context/context.sh" checkpoint >/dev/null
  assert_file "$cache/workstreams/active/landing-polish.json"
  assert_file "$cache/validation/repositories/test-member.json"
  bash "$member/.ai/context/context.sh" start >/dev/null
  python3 - "$member/.ai-bridge/context-runtime.json" "$member/.ai-bridge/context-runtime.md" "$cache/manifests/repositories/test-member.json" <<'PY'
import json, pathlib, sys
runtime=json.loads(pathlib.Path(sys.argv[1]).read_text())
text=pathlib.Path(sys.argv[2]).read_text()
manifest=json.loads(pathlib.Path(sys.argv[3]).read_text())
assert runtime['continuity']['workstreamId']=='landing-polish'
assert runtime['continuity']['currentItemId']=='WS-1'
assert runtime['continuity']['validation']['freshEntries']==1
assert manifest['continuity']['workstreamId']=='landing-polish'
assert manifest['continuity']['currentItemId']=='WS-1'
assert 'WS-2 - Validate offline resume' in text
assert 'Workstream survives checkpoint and start.' in text
PY
}

test_v2_item_loss_rejected() {
  local root member cache before after out
  root=$(mktemp -d)
  member=$(make_fixture "$root")
  bash "$member/.ai/context/context.sh" start >/dev/null
  cache="$member/.ai/context/cache/project-context"
  git_identity "$cache"
  write_tracked_checkpoint "$member"
  bash "$member/.ai/context/context.sh" checkpoint >/dev/null
  before=$(git -C "$cache" rev-parse HEAD)
  write_tracked_checkpoint "$member" VAL-2
  python3 - "$member/.ai-bridge/context-checkpoint.json" <<'PY'
import json,pathlib,sys
p=pathlib.Path(sys.argv[1]); d=json.loads(p.read_text())
d['continuity']['workstream']['items']=[item for item in d['continuity']['workstream']['items'] if item['id']!='WS-2']
p.write_text(json.dumps(d,indent=2)+'\n')
PY
  if out=$(bash "$member/.ai/context/context.sh" checkpoint 2>&1); then return 1; fi
  [[ "$out" == *'would lose existing work items: WS-2'* ]]
  after=$(git -C "$cache" rev-parse HEAD)
  [[ "$after" == "$before" ]]
  assert_file "$cache/workstreams/active/landing-polish.json"
}

test_v2_transition() {
  local root member cache
  root=$(mktemp -d)
  member=$(make_fixture "$root")
  bash "$member/.ai/context/context.sh" start >/dev/null
  cache="$member/.ai/context/cache/project-context"
  git_identity "$cache"
  write_tracked_checkpoint "$member"
  bash "$member/.ai/context/context.sh" checkpoint >/dev/null
  write_tracked_checkpoint "$member" VAL-2
  python3 - "$member/.ai-bridge/context-checkpoint.json" <<'PY'
import json,pathlib,sys
p=pathlib.Path(sys.argv[1]); d=json.loads(p.read_text()); w=d['continuity']['workstream']
d['nextAction']='Finish WS-2.'
w['cursor'].update({'currentItemId':'WS-2','lastCompletedItemId':'WS-1','lastCompletedAction':'Implemented structured backlog.','nextAction':'Finish WS-2.'})
w['items'][0]['status']='COMPLETED'; w['items'][1]['status']='IN_PROGRESS'
p.write_text(json.dumps(d,indent=2)+'\n')
PY
  bash "$member/.ai/context/context.sh" checkpoint >/dev/null
  python3 - "$cache/workstreams/active/landing-polish.json" <<'PY'
import json,pathlib,sys
w=json.loads(pathlib.Path(sys.argv[1]).read_text())
assert w['cursor']['currentItemId']=='WS-2'
assert w['items'][0]['status']=='COMPLETED'
assert w['items'][1]['status']=='IN_PROGRESS'
PY
}

test_v2_validation_stale() {
  local root member cache
  root=$(mktemp -d)
  member=$(make_fixture "$root")
  bash "$member/.ai/context/context.sh" start >/dev/null
  cache="$member/.ai/context/cache/project-context"
  git_identity "$cache"
  write_tracked_checkpoint "$member"
  bash "$member/.ai/context/context.sh" checkpoint >/dev/null
  printf '\nproduct drift\n' >>"$member/README.md"
  bash "$member/.ai/context/context.sh" start >/dev/null
  python3 - "$member/.ai-bridge/context-runtime.json" <<'PY'
import json,pathlib,sys
r=json.loads(pathlib.Path(sys.argv[1]).read_text())
assert r['continuity']['validation']['freshEntries']==0
assert r['continuity']['validation']['staleEntries']==1
PY
}

test_v1_cannot_erase_v2() {
  local root member cache out
  root=$(mktemp -d)
  member=$(make_fixture "$root")
  bash "$member/.ai/context/context.sh" start >/dev/null
  cache="$member/.ai/context/cache/project-context"
  git_identity "$cache"
  write_tracked_checkpoint "$member"
  bash "$member/.ai/context/context.sh" checkpoint >/dev/null
  cat >"$member/.ai-bridge/context-checkpoint.json" <<'EOF'
{"schemaVersion":1,"repository":"test-member","scope":"legacy","status":"VALIDATED","objective":"legacy","confirmedFindings":[],"decisions":[],"rejectedApproaches":[],"validation":[],"openQuestions":[],"nextAction":"Continue."}
EOF
  if out=$(bash "$member/.ai/context/context.sh" checkpoint 2>&1); then return 1; fi
  [[ "$out" == *'would lose an active tracked workstream'* ]]
}

test_v2_dependency_cycle_rejected() {
  local root member out
  root=$(mktemp -d)
  member=$(make_fixture "$root")
  bash "$member/.ai/context/context.sh" start >/dev/null
  git_identity "$member/.ai/context/cache/project-context"
  write_tracked_checkpoint "$member"
  python3 - "$member/.ai-bridge/context-checkpoint.json" <<'PY'
import json,pathlib,sys
p=pathlib.Path(sys.argv[1]); d=json.loads(p.read_text())
d['continuity']['workstream']['items'][0]['dependsOn']=['WS-2']
p.write_text(json.dumps(d,indent=2)+'\n')
PY
  if out=$(bash "$member/.ai/context/context.sh" checkpoint 2>&1); then return 1; fi
  [[ "$out" == *'dependency cycle'* ]]
}

test_v2_duplicate_validation_id_rejected() {
  local root member cache out before after
  root=$(mktemp -d)
  member=$(make_fixture "$root")
  bash "$member/.ai/context/context.sh" start >/dev/null
  cache="$member/.ai/context/cache/project-context"
  git_identity "$cache"
  write_tracked_checkpoint "$member"
  bash "$member/.ai/context/context.sh" checkpoint >/dev/null
  before=$(git -C "$cache" rev-parse HEAD)
  write_tracked_checkpoint "$member" VAL-1
  if out=$(bash "$member/.ai/context/context.sh" checkpoint 2>&1); then return 1; fi
  [[ "$out" == *'immutable and already exist: VAL-1'* ]]
  after=$(git -C "$cache" rev-parse HEAD)
  [[ "$after" == "$before" ]]
}

test_v2_snapshot_loss_rejected() {
  local root member cache out
  root=$(mktemp -d)
  member=$(make_fixture "$root")
  bash "$member/.ai/context/context.sh" start >/dev/null
  cache="$member/.ai/context/cache/project-context"
  git_identity "$cache"
  write_tracked_checkpoint "$member"
  bash "$member/.ai/context/context.sh" checkpoint >/dev/null
  cat >"$member/.ai-bridge/context-checkpoint.json" <<'EOF'
{
  "schemaVersion": 2,
  "repository": "test-member",
  "scope": "snapshot-loss",
  "status": "VALIDATED",
  "objective": "Attempt unsafe snapshot.",
  "confirmedFindings": [],
  "decisions": [],
  "rejectedApproaches": [],
  "validation": [],
  "openQuestions": [],
  "nextAction": "Continue.",
  "continuity": {"mode":"snapshot","workstream":null,"validationLedger":[]}
}
EOF
  if out=$(bash "$member/.ai/context/context.sh" checkpoint 2>&1); then return 1; fi
  [[ "$out" == *'Snapshot checkpoint would lose an active tracked workstream'* ]]
}

test_v2_active_to_archive() {
  local root member cache
  root=$(mktemp -d)
  member=$(make_fixture "$root")
  bash "$member/.ai/context/context.sh" start >/dev/null
  cache="$member/.ai/context/cache/project-context"
  git_identity "$cache"
  write_tracked_checkpoint "$member"
  bash "$member/.ai/context/context.sh" checkpoint >/dev/null
  write_tracked_checkpoint "$member" VAL-2
  python3 - "$member/.ai-bridge/context-checkpoint.json" <<'PY'
import json,pathlib,sys
p=pathlib.Path(sys.argv[1]); d=json.loads(p.read_text()); w=d['continuity']['workstream']
d['nextAction']='Finish WS-2.'
w['cursor'].update({'currentItemId':'WS-2','lastCompletedItemId':'WS-1','lastCompletedAction':'Finished WS-1.','nextAction':'Finish WS-2.'})
w['items'][0]['status']='COMPLETED'; w['items'][1]['status']='IN_PROGRESS'
p.write_text(json.dumps(d,indent=2)+'\n')
PY
  bash "$member/.ai/context/context.sh" checkpoint >/dev/null
  write_tracked_checkpoint "$member" VAL-3
  python3 - "$member/.ai-bridge/context-checkpoint.json" <<'PY'
import json,pathlib,sys
p=pathlib.Path(sys.argv[1]); d=json.loads(p.read_text()); w=d['continuity']['workstream']
d['status']='VALIDATED'; d['nextAction']='Workstream complete.'
w['status']='COMPLETED'
w['cursor'].update({'currentItemId':None,'lastCompletedItemId':'WS-2','lastCompletedAction':'Validated offline resume.','nextAction':'Workstream complete.'})
w['items'][0]['status']='COMPLETED'; w['items'][1]['status']='COMPLETED'
p.write_text(json.dumps(d,indent=2)+'\n')
PY
  bash "$member/.ai/context/context.sh" checkpoint >/dev/null
  [[ ! -e "$cache/workstreams/active/landing-polish.json" ]]
  assert_file "$cache/workstreams/archive/landing-polish.json"
  python3 - "$cache/manifests/repositories/test-member.json" <<'PY'
import json,pathlib,sys
m=json.loads(pathlib.Path(sys.argv[1]).read_text())
assert m['continuity']['workstreamStatus']=='COMPLETED'
assert m['continuity']['workstreamPath']=='workstreams/archive/landing-polish.json'
assert m['continuity']['currentItemId'] is None
PY
}

test_offline_transfer_resume_and_checkpoint() {
  local root member_a member_b cache_b transfer source_head imported_head after_checkpoint remote_disabled
  root=$(mktemp -d)
  member_a=$(make_fixture "$root")
  bash "$member_a/.ai/context/context.sh" start >/dev/null
  git_identity "$member_a/.ai/context/cache/project-context"
  write_tracked_checkpoint "$member_a"
  bash "$member_a/.ai/context/context.sh" checkpoint >/dev/null
  source_head=$(git -C "$member_a/.ai/context/cache/project-context" rev-parse HEAD)
  bash "$member_a/.ai/context/context.sh" export >/dev/null
  transfer="$member_a/.ai-bridge/context-transfer"
  assert_file "$transfer/manifest.json"
  assert_file "$transfer/context.bundle"

  member_b="$root/member-b"
  git clone "$member_a" "$member_b" >/dev/null 2>&1
  git_identity "$member_b"
  mkdir -p "$member_b/.ai-bridge"
  cp -R "$transfer" "$member_b/.ai-bridge/context-transfer"
  remote_disabled="$root/context.git.offline"
  mv "$root/context.git" "$remote_disabled"

  bash "$member_b/.ai/context/context.sh" import >/dev/null
  imported_head=$(git -C "$member_b/.ai/context/cache/project-context" rev-parse HEAD)
  [[ "$imported_head" == "$source_head" ]]
  bash "$member_b/.ai/context/context.sh" start >/dev/null
  python3 - "$member_b/.ai-bridge/context-runtime.json" "$member_b/.ai-bridge/context-runtime.md" <<'PY'
import json,pathlib,sys
runtime=json.loads(pathlib.Path(sys.argv[1]).read_text())
text=pathlib.Path(sys.argv[2]).read_text()
assert runtime['context']['freshness']=='OFFLINE_IMPORTED_CONTEXT'
assert runtime['continuity']['workstreamId']=='landing-polish'
assert runtime['continuity']['currentItemId']=='WS-1'
assert 'WS-2 - Validate offline resume' in text
PY

  write_tracked_checkpoint "$member_b" VAL-2
  python3 - "$member_b/.ai-bridge/context-checkpoint.json" <<'PY'
import json,pathlib,sys
p=pathlib.Path(sys.argv[1]); d=json.loads(p.read_text()); w=d['continuity']['workstream']
d['nextAction']='Finish WS-2.'
w['cursor'].update({'currentItemId':'WS-2','lastCompletedItemId':'WS-1','lastCompletedAction':'Finished WS-1 offline.','nextAction':'Finish WS-2.'})
w['items'][0]['status']='COMPLETED'; w['items'][1]['status']='IN_PROGRESS'
p.write_text(json.dumps(d,indent=2)+'\n')
PY
  bash "$member_b/.ai/context/context.sh" checkpoint >/dev/null
  after_checkpoint=$(git -C "$member_b/.ai/context/cache/project-context" rev-parse HEAD)
  [[ "$after_checkpoint" != "$imported_head" ]]
  python3 - "$member_b/.ai-bridge/context-offline.json" "$after_checkpoint" <<'PY'
import json,pathlib,sys
marker=json.loads(pathlib.Path(sys.argv[1]).read_text())
assert marker['kind']=='qbit-ai-context-offline'
assert marker['currentContextHead']==sys.argv[2]
PY
  bash "$member_b/.ai/context/context.sh" start >/dev/null
  python3 - "$member_b/.ai-bridge/context-runtime.json" <<'PY'
import json,pathlib,sys
runtime=json.loads(pathlib.Path(sys.argv[1]).read_text())
assert runtime['context']['freshness']=='OFFLINE_IMPORTED_CONTEXT'
assert runtime['continuity']['currentItemId']=='WS-2'
PY

  mv "$remote_disabled" "$root/context.git"
  bash "$member_b/.ai/context/context.sh" reconnect >/dev/null
  [[ ! -e "$member_b/.ai-bridge/context-offline.json" ]]
  [[ "$(git --git-dir "$root/context.git" rev-parse refs/heads/main)" == "$after_checkpoint" ]]
  bash "$member_b/.ai/context/context.sh" start >/dev/null
  python3 - "$member_b/.ai-bridge/context-runtime.json" <<'PY'
import json,pathlib,sys
runtime=json.loads(pathlib.Path(sys.argv[1]).read_text())
assert runtime['context']['freshness']=='CURRENT_OR_FETCHED'
assert runtime['continuity']['currentItemId']=='WS-2'
PY
}

test_offline_transfer_tamper_rejected() {
  local root member_a member_b transfer out
  root=$(mktemp -d)
  member_a=$(make_fixture "$root")
  bash "$member_a/.ai/context/context.sh" start >/dev/null
  git_identity "$member_a/.ai/context/cache/project-context"
  write_tracked_checkpoint "$member_a"
  bash "$member_a/.ai/context/context.sh" checkpoint >/dev/null
  bash "$member_a/.ai/context/context.sh" export >/dev/null
  transfer="$member_a/.ai-bridge/context-transfer"

  member_b="$root/member-b"
  git clone "$member_a" "$member_b" >/dev/null 2>&1
  git_identity "$member_b"
  mkdir -p "$member_b/.ai-bridge"
  cp -R "$transfer" "$member_b/.ai-bridge/context-transfer"
  printf 'tamper' >>"$member_b/.ai-bridge/context-transfer/context.bundle"
  mv "$root/context.git" "$root/context.git.offline"
  if out=$(bash "$member_b/.ai/context/context.sh" import 2>&1); then return 1; fi
  [[ "$out" == *'bundle size does not match the manifest'* || "$out" == *'bundle SHA-256 does not match the manifest'* ]]
  [[ ! -e "$member_b/.ai/context/cache/project-context/.git" ]]
  [[ ! -e "$member_b/.ai-bridge/context-offline.json" ]]
}

test_offline_transfer_repository_mismatch_rejected() {
  local root member_a member_b transfer out
  root=$(mktemp -d)
  member_a=$(make_fixture "$root")
  bash "$member_a/.ai/context/context.sh" start >/dev/null
  git_identity "$member_a/.ai/context/cache/project-context"
  write_tracked_checkpoint "$member_a"
  bash "$member_a/.ai/context/context.sh" checkpoint >/dev/null
  bash "$member_a/.ai/context/context.sh" export >/dev/null
  transfer="$member_a/.ai-bridge/context-transfer"

  member_b="$root/member-b"
  git clone "$member_a" "$member_b" >/dev/null 2>&1
  git_identity "$member_b"
  mkdir -p "$member_b/.ai-bridge"
  cp -R "$transfer" "$member_b/.ai-bridge/context-transfer"
  python3 - "$member_b/.ai-bridge/context-transfer/manifest.json" <<'PY'
import json,pathlib,sys
p=pathlib.Path(sys.argv[1]); d=json.loads(p.read_text()); d['repository']='other-member'; p.write_text(json.dumps(d,indent=2)+'\n')
PY
  mv "$root/context.git" "$root/context.git.offline"
  if out=$(bash "$member_b/.ai/context/context.sh" import 2>&1); then return 1; fi
  [[ "$out" == *'transfer repository does not match this repository config'* ]]
  [[ ! -e "$member_b/.ai/context/cache/project-context/.git" ]]
}

test_offline_conflict_rejected() {
  local root member cache before after out
  root=$(mktemp -d)
  member=$(make_fixture "$root")
  bash "$member/.ai/context/context.sh" start >/dev/null
  cache="$member/.ai/context/cache/project-context"
  git_identity "$cache"
  write_tracked_checkpoint "$member"
  bash "$member/.ai/context/context.sh" checkpoint >/dev/null
  bash "$member/.ai/context/context.sh" export >/dev/null
  printf 'independent offline writer\n' >"$cache/local-conflict.md"
  git -C "$cache" add local-conflict.md
  git -C "$cache" commit -m 'local conflicting context' >/dev/null
  before=$(git -C "$cache" rev-parse HEAD)
  if out=$(bash "$member/.ai/context/context.sh" import 2>&1); then return 1; fi
  [[ "$out" == *'conflicts with the existing context cache HEAD'* ]]
  after=$(git -C "$cache" rev-parse HEAD)
  [[ "$after" == "$before" ]]
}

test_offline_secret_export_rejected() {
  local root member cache out
  root=$(mktemp -d)
  member=$(make_fixture "$root")
  bash "$member/.ai/context/context.sh" start >/dev/null
  cache="$member/.ai/context/cache/project-context"
  git_identity "$cache"
  local secret_like
  secret_like='Bear''er abcdefghijklmnop'
  printf '%s\n' "$secret_like" >"$cache/secret-fixture.md"
  git -C "$cache" add secret-fixture.md
  git -C "$cache" commit -m 'secret fixture' >/dev/null
  if out=$(bash "$member/.ai/context/context.sh" export 2>&1); then return 1; fi
  [[ "$out" == *'refused secret-like material'*'secret-fixture.md'* ]]
}

test_offline_reconnect_divergence_rejected() {
  local root member_a member_b transfer remote_disabled cache_b local_head remote_writer remote_head out
  root=$(mktemp -d)
  member_a=$(make_fixture "$root")
  bash "$member_a/.ai/context/context.sh" start >/dev/null
  git_identity "$member_a/.ai/context/cache/project-context"
  write_tracked_checkpoint "$member_a"
  bash "$member_a/.ai/context/context.sh" checkpoint >/dev/null
  bash "$member_a/.ai/context/context.sh" export >/dev/null
  transfer="$member_a/.ai-bridge/context-transfer"
  remote_disabled="$root/context.git.offline"
  mv "$root/context.git" "$remote_disabled"

  member_b="$root/member-b-diverged"
  git clone "$member_a" "$member_b" >/dev/null 2>&1
  git_identity "$member_b"
  cp -R "$transfer" "$member_b/.ai-bridge/context-transfer"
  bash "$member_b/.ai/context/context.sh" import >/dev/null
  cache_b="$member_b/.ai/context/cache/project-context"
  git_identity "$cache_b"
  write_tracked_checkpoint "$member_b" VAL-DIVERGED-2
  python3 - "$member_b/.ai-bridge/context-checkpoint.json" <<'PY'
import json,pathlib,sys
p=pathlib.Path(sys.argv[1]); d=json.loads(p.read_text()); w=d['continuity']['workstream']
d['nextAction']='Finish WS-2.'
w['cursor'].update({'currentItemId':'WS-2','lastCompletedItemId':'WS-1','lastCompletedAction':'Finished WS-1 offline.','nextAction':'Finish WS-2.'})
w['items'][0]['status']='COMPLETED'; w['items'][1]['status']='IN_PROGRESS'
p.write_text(json.dumps(d,indent=2)+'\n')
PY
  bash "$member_b/.ai/context/context.sh" checkpoint >/dev/null
  local_head=$(git -C "$cache_b" rev-parse HEAD)

  mv "$remote_disabled" "$root/context.git"
  remote_writer="$root/remote-writer"
  git clone --branch main --single-branch "$root/context.git" "$remote_writer" >/dev/null 2>&1
  git_identity "$remote_writer"
  printf 'remote writer\n' >"$remote_writer/remote-independent.md"
  git -C "$remote_writer" add remote-independent.md
  git -C "$remote_writer" commit -m 'remote independent context' >/dev/null
  git -C "$remote_writer" push origin main >/dev/null
  remote_head=$(git --git-dir "$root/context.git" rev-parse refs/heads/main)

  if out=$(bash "$member_b/.ai/context/context.sh" reconnect 2>&1); then return 1; fi
  [[ "$out" == *'offline reconciliation conflict'* ]]
  [[ "$(git -C "$cache_b" rev-parse HEAD)" == "$local_head" ]]
  [[ "$(git --git-dir "$root/context.git" rev-parse refs/heads/main)" == "$remote_head" ]]
  [[ -f "$member_b/.ai-bridge/context-offline.json" ]]
}

test_unregistered_member_rejected() {
  local root member out
  root=$(mktemp -d)
  member=$(make_fixture "$root")
  cat >"$root/central/repositories/repositories.yaml" <<'EOF'
project: test-project
repositories: {}
EOF
  git -C "$root/central" add repositories/repositories.yaml
  git -C "$root/central" commit -m 'remove member registration' >/dev/null
  git -C "$root/central" push origin main >/dev/null
  if out=$(bash "$member/.ai/context/context.sh" start 2>&1); then return 1; fi
  [[ "$out" == *'not registered'* ]]
  [[ ! -f "$member/.ai-bridge/context-runtime.json" ]]
  if out=$(bash "$member/.ai/context/context.sh" status 2>&1); then return 1; fi
  [[ "$out" == *'"registered": false'* ]]
  cat >"$member/.ai-bridge/context-checkpoint.json" <<'EOF'
{"schemaVersion":1,"repository":"test-member","scope":"unregistered","status":"VALIDATED","objective":"Reject unregistered member.","confirmedFindings":[],"decisions":[],"rejectedApproaches":[],"validation":[],"openQuestions":[],"nextAction":"Register first."}
EOF
  if bash "$member/.ai/context/context.sh" checkpoint >/dev/null 2>&1; then return 1; fi
  [[ -f "$member/.ai-bridge/context-checkpoint.json" ]]
  [[ ! -f "$member/.ai/context/cache/project-context/state/repositories/test-member.md" ]]
}

test_membership_audit_reports_candidate_without_mutation() {
  local root member candidate context_alias before after out
  root=$(mktemp -d)
  member=$(make_fixture "$root")
  candidate="$root/test-project-docs"
  git init -b main "$candidate" >/dev/null
  git_identity "$candidate"
  printf '# Candidate\n' >"$candidate/AI_CONTEXT.md"
  git -C "$candidate" add AI_CONTEXT.md
  git -C "$candidate" commit -m candidate >/dev/null
  context_alias="$root/local-context-alias"
  git clone --branch main --single-branch "$root/context.git" "$context_alias" >/dev/null 2>&1
  before=$(git --git-dir "$root/context.git" rev-parse refs/heads/main)
  out=$(bash "$member/.ai/context/context.sh" audit)
  after=$(git --git-dir "$root/context.git" rev-parse refs/heads/main)
  [[ "$out" == *'"repository": "test-project-docs"'* ]]
  [[ "$out" != *'local-context-alias'* ]]
  [[ "$out" == *'"candidates":'* ]]
  [[ "$before" == "$after" ]]
}

test_online_checkpoint_divergence_rejected_without_rebase() {
  local root member cache remote_writer hook local_head remote_head out writer_path
  root=$(mktemp -d)
  member=$(make_fixture "$root")
  bash "$member/.ai/context/context.sh" start >/dev/null
  cache="$member/.ai/context/cache/project-context"
  git_identity "$cache"
  remote_writer="$root/remote-writer-online"
  git clone --branch main --single-branch "$root/context.git" "$remote_writer" >/dev/null 2>&1
  git_identity "$remote_writer"
  writer_path=$(native_path "$remote_writer")
  hook="$cache/.git/hooks/pre-push"
  cat >"$hook" <<EOF
#!/usr/bin/env bash
rm -f -- "\$0"
printf 'remote race\n' >"$writer_path/online-race-remote.md"
git -C "$writer_path" add online-race-remote.md
git -C "$writer_path" commit -m 'remote online race' >/dev/null
git -C "$writer_path" push origin main >/dev/null
EOF
  chmod +x "$hook"
  cat >"$member/.ai-bridge/context-checkpoint.json" <<'EOF'
{"schemaVersion":1,"repository":"test-member","scope":"online-race","status":"VALIDATED","objective":"Prove online divergence is fail-closed.","confirmedFindings":[],"decisions":[],"rejectedApproaches":[],"validation":[],"openQuestions":[],"nextAction":"Reconcile explicitly."}
EOF
  if out=$(bash "$member/.ai/context/context.sh" checkpoint 2>&1); then return 1; fi
  [[ "$out" == *'histories diverged'* ]]
  [[ -f "$member/.ai-bridge/context-checkpoint.json" ]]
  local_head=$(git -C "$cache" rev-parse HEAD)
  remote_head=$(git --git-dir "$root/context.git" rev-parse refs/heads/main)
  [[ "$local_head" != "$remote_head" ]]
  if git -C "$cache" merge-base --is-ancestor "$local_head" "$remote_head"; then return 1; fi
  if git -C "$cache" merge-base --is-ancestor "$remote_head" "$local_head"; then return 1; fi
  [[ ! -d "$cache/.git/rebase-merge" && ! -d "$cache/.git/rebase-apply" ]]
}

test_cache_escape_rejected() {
  local root member config escaped
  root=$(mktemp -d)
  member=$(make_fixture "$root")
  config="$member/.ai/context/config.json"
  escaped="$root/escaped-cache"
  python3 - "$config" <<'PY'
import json,pathlib,sys
p=pathlib.Path(sys.argv[1])
data=json.loads(p.read_text())
data['context']['cachePath']='../../../escaped-cache'
p.write_text(json.dumps(data,indent=2)+'\n')
PY
  if bash "$member/.ai/context/context.sh" start >/dev/null 2>&1; then return 1; fi
  [[ ! -e "$escaped" ]]
}

run_test 'fresh clone start creates runtime bundle' test_fresh_start
run_test 'status emits repository runtime state' test_status
run_test 'checkpoint commits and pushes scoped context' test_checkpoint
run_test 'invalid checkpoint status is rejected' test_invalid_status_rejected
run_test 'secret-like checkpoint content is rejected' test_secret_rejected
run_test 'dirty context checkpoint is refused without overwrite' test_dirty_context_checkpoint_refused
run_test 'clean stale cache fast-forwards to remote' test_fast_forward_clean_cache
run_test 'dirty start preserves local context and reports dirty freshness' test_dirty_start_preserved
run_test 'clean cache origin migrates safely' test_clean_origin_migration
run_test 'dirty cache refuses origin migration' test_dirty_origin_migration_refused
run_test 'diverged cache is preserved and reported read-only' test_diverged_cache_reported_read_only
run_test 'v2 tracked checkpoint persists workstream validation ledger and runtime cursor' test_v2_tracked_checkpoint
run_test 'v2 checkpoint rejects silent work item loss and preserves durable context' test_v2_item_loss_rejected
run_test 'v2 checkpoint accepts explicit item transition and moves execution cursor' test_v2_transition
run_test 'v2 validation ledger becomes stale when member worktree changes' test_v2_validation_stale
run_test 'legacy v1 checkpoint cannot erase an unresolved v2 workstream' test_v1_cannot_erase_v2
run_test 'v2 dependency cycle is rejected' test_v2_dependency_cycle_rejected
run_test 'v2 duplicate validation ledger id is rejected' test_v2_duplicate_validation_id_rejected
run_test 'v2 snapshot cannot erase an unresolved tracked workstream' test_v2_snapshot_loss_rejected
run_test 'v2 completed workstream moves from active to archive' test_v2_active_to_archive
run_test 'offline transfer resumes exact workstream and checkpoints without network' test_offline_transfer_resume_and_checkpoint
run_test 'offline transfer tamper is rejected before cache creation' test_offline_transfer_tamper_rejected
run_test 'offline transfer repository mismatch is rejected' test_offline_transfer_repository_mismatch_rejected
run_test 'offline import rejects conflicting existing context head without reconciliation' test_offline_conflict_rejected
run_test 'offline export rejects secret-like tracked context material' test_offline_secret_export_rejected
run_test 'offline reconnect rejects divergent local and remote writers without mutation' test_offline_reconnect_divergence_rejected
run_test 'unregistered member start status and checkpoint fail closed' test_unregistered_member_rejected
run_test 'membership audit reports candidates without mutation' test_membership_audit_reports_candidate_without_mutation
run_test 'online checkpoint divergence rejects without rebase' test_online_checkpoint_divergence_rejected_without_rebase
run_test 'cache path escape is rejected before filesystem mutation' test_cache_escape_rejected

if (( fail > 0 )); then
  printf 'FAIL %d/%d context lifecycle tests\n' "$fail" "$((pass+fail))" >&2
  exit 1
fi
printf 'PASS all %d POSIX context lifecycle tests\n' "$pass"
