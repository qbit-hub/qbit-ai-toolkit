#!/usr/bin/env bash
set -euo pipefail
installer_root=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)
install="$installer_root/install.sh"
verify="$installer_root/verify.sh"
uninstall="$installer_root/uninstall.sh"
temp_root=$(mktemp -d)
trap 'rm -rf "$temp_root"' EXIT
passed=0
failed=0

new_repo() {
  local name=$1 repo="$temp_root/$1"
  git init -b main "$repo" >/dev/null
  git -C "$repo" config user.name Test
  git -C "$repo" config user.email test@example.invalid
  printf '# %s\n' "$name" >"$repo/README.md"
  git -C "$repo" add README.md
  git -C "$repo" commit -m init >/dev/null
  printf '%s\n' "$repo"
}
render() {
  local src=$1 dst=$2
  python3 - "$src" "$dst" <<'PY'
import pathlib,sys
src=pathlib.Path(sys.argv[1]).read_text(encoding='utf-8-sig')
values={
 'PROJECT_ID':'demo','PROJECT_DISPLAY_NAME':'Demo','REPOSITORY_ID':'demo-api','CONTEXT_REPOSITORY_ID':'demo-ai-context',
 'CONTEXT_REMOTE':'https://example.invalid/demo-ai-context.git','CONTEXT_BRANCH':'main',
 'PROJECT_ID_JSON':'demo','REPOSITORY_ID_JSON':'demo-api','CONTEXT_REMOTE_JSON':'https://example.invalid/demo-ai-context.git','CONTEXT_BRANCH_JSON':'main',
}
for k,v in values.items(): src=src.replace('{{'+k+'}}',v)
pathlib.Path(sys.argv[2]).write_text(src,encoding='utf-8')
PY
}
run_test() { local name=$1; shift; if "$@"; then passed=$((passed+1)); printf 'PASS %s\n' "$name"; else failed=$((failed+1)); printf 'FAIL %s\n' "$name" >&2; fi; }

t_fresh_header() {
  local repo state; repo=$(new_repo fresh-header)
  bash "$install" --operation install --mode member --target "$repo" --project-id demo --project-display-name Demo --repository-id demo-api --context-remote https://example.invalid/demo-ai-context.git --format json >/dev/null
  grep -q '^# Demo AI Context Entry Point' "$repo/AI_CONTEXT.md"
  grep -q '`demo-api` is a member repository' "$repo/AI_CONTEXT.md"
  state="$repo/.qbit/toolkit/installed/ai-context.json"
  python3 - "$state" <<'PY'
import json,pathlib,sys
p=pathlib.Path(sys.argv[1]); d=json.loads(p.read_text()); d['installerVersion']='1.0.2'; p.write_text(json.dumps(d,indent=2)+'\n')
PY
  bash "$install" --operation update --target "$repo" --format json >/dev/null
  [[ "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["installerVersion"])' "$state")" == 1.2.6 ]]
  bash "$uninstall" --target "$repo" --format json >/dev/null
  grep -q '^# Demo AI Context Entry Point' "$repo/AI_CONTEXT.md"
  ! grep -q '<!-- qbit-toolkit:ai-context:start -->' "$repo/AI_CONTEXT.md"
}

t_legacy_migration() {
  local repo code; repo=$(new_repo legacy-member)
  mkdir -p "$repo/.ai/context" "$repo/.ai-bridge"
  cp "$installer_root/templates/common/member/context.ps1" "$repo/.ai/context/context.ps1"
  cp "$installer_root/templates/common/member/context.gitignore" "$repo/.ai/context/.gitignore"
  render "$installer_root/templates/common/member/config.json.tpl" "$repo/.ai/context/config.json"
  python3 - "$repo/.ai/context/config.json" <<'PY'
import json,pathlib,sys
p=pathlib.Path(sys.argv[1]); p.write_text(json.dumps(json.loads(p.read_text()),indent=4)+'\n')
PY
  render "$installer_root/templates/common/member/legacy-agents-section.md.tpl" "$repo/legacy-agents"
  render "$installer_root/templates/common/member/legacy-ai-context-tail.md.tpl" "$repo/legacy-entry"
  { printf '# Product rules\n\n'; cat "$repo/legacy-agents"; } >"$repo/AGENTS.md"
  { printf '# Demo AI Context Entry Point\n\n## Repository role\n\nCUSTOM ROLE MUST SURVIVE\n\n'; cat "$repo/legacy-entry"; } >"$repo/AI_CONTEXT.md"
  cp "$installer_root/templates/common/member/bridge.gitignore" "$repo/.ai-bridge/.gitignore"
  printf '# Existing bridge docs\n' >"$repo/.ai-bridge/README.md"
  set +e
  bash "$install" --operation plan --mode member --target "$repo" --project-id demo --project-display-name Demo --repository-id demo-api --context-remote https://example.invalid/demo-ai-context.git --context-branch main --adopt-matching --format json >/dev/null
  code=$?
  set -e
  [[ $code -eq 4 ]]
  bash "$install" --operation install --mode member --target "$repo" --project-id demo --project-display-name Demo --repository-id demo-api --context-remote https://example.invalid/demo-ai-context.git --context-branch main --adopt-matching --migrate-legacy --format json >/dev/null
  [[ $(grep -c '^## AI context lifecycle$' "$repo/AGENTS.md") -eq 1 ]]
  [[ $(grep -c '^## Zero-touch lifecycle$' "$repo/AI_CONTEXT.md") -eq 1 ]]
  grep -q 'CUSTOM ROLE MUST SURVIVE' "$repo/AI_CONTEXT.md"
  grep -q '<!-- qbit-toolkit:ai-context:start -->' "$repo/AGENTS.md"
  [[ -f "$repo/.ai/context/context.sh" && -f "$repo/.ai/context/context.py" ]]
  bash "$verify" --target "$repo" --format json >/dev/null
}

t_modified_rejected() {
  local repo code; repo=$(new_repo legacy-modified)
  mkdir -p "$repo/.ai/context"
  cp "$installer_root/templates/common/member/context.ps1" "$repo/.ai/context/context.ps1"
  cp "$installer_root/templates/common/member/context.gitignore" "$repo/.ai/context/.gitignore"
  render "$installer_root/templates/common/member/config.json.tpl" "$repo/.ai/context/config.json"
  render "$installer_root/templates/common/member/legacy-agents-section.md.tpl" "$repo/AGENTS.md"
  printf '\nCUSTOM MODIFIED LEGACY TEXT\n' >>"$repo/AGENTS.md"
  set +e
  bash "$install" --operation plan --mode member --target "$repo" --project-id demo --project-display-name Demo --repository-id demo-api --context-remote https://example.invalid/demo-ai-context.git --adopt-matching --migrate-legacy --format json >/dev/null
  code=$?
  set -e
  [[ $code -eq 4 ]]
}

run_test 'fresh member seed survives uninstall and version-only update reaches 1.2.6' t_fresh_header
run_test 'legacy manual member rollout migrates only with explicit flag' t_legacy_migration
run_test 'modified legacy lifecycle is rejected' t_modified_rejected
if (( failed > 0 )); then printf 'FAIL %d legacy migration test(s) failed; %d passed.\n' "$failed" "$passed" >&2; exit 1; fi
printf 'PASS all %d POSIX legacy migration integration tests\n' "$passed"
