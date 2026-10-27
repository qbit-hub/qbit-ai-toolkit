#!/usr/bin/env python3
from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import re
import subprocess
import sys
from pathlib import Path
from typing import Any

ALLOWED_STATUSES = {
    "PROPOSED", "IN_PROGRESS", "IMPLEMENTED", "VALIDATED", "APPROVED", "MERGED",
    "DEPLOYED", "SUPERSEDED", "STALE", "BLOCKED", "UNKNOWN",
}
WORKSTREAM_STATUSES = {"PROPOSED", "IN_PROGRESS", "BLOCKED", "COMPLETED", "CANCELLED", "SUPERSEDED"}
WORK_ITEM_STATUSES = {"PENDING", "IN_PROGRESS", "BLOCKED", "COMPLETED", "CANCELLED", "SUPERSEDED"}
TERMINAL_WORKSTREAM_STATUSES = {"COMPLETED", "CANCELLED", "SUPERSEDED"}
TERMINAL_WORK_ITEM_STATUSES = {"COMPLETED", "CANCELLED", "SUPERSEDED"}
ACTIVE_CHECKPOINT_STATUSES = {"PROPOSED", "IN_PROGRESS", "IMPLEMENTED", "BLOCKED"}
WORK_ITEM_TRANSITIONS = {
    "PENDING": {"PENDING", "IN_PROGRESS", "BLOCKED", "CANCELLED", "SUPERSEDED"},
    "IN_PROGRESS": {"IN_PROGRESS", "BLOCKED", "COMPLETED", "CANCELLED", "SUPERSEDED"},
    "BLOCKED": {"BLOCKED", "IN_PROGRESS", "CANCELLED", "SUPERSEDED"},
    "COMPLETED": {"COMPLETED"},
    "CANCELLED": {"CANCELLED"},
    "SUPERSEDED": {"SUPERSEDED"},
}
SAFE_CONTEXT_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")
FORBIDDEN_KEY = re.compile(r"(password|passwd|secret|token|private.?key|cookie|authorization|dsn|api.?key|client.?secret)", re.I)
FORBIDDEN_VALUE = re.compile(r"(-----BEGIN [A-Z ]*PRIVATE KEY-----|\bBearer\s+[A-Za-z0-9._\-+/=]{8,}|glpat-[A-Za-z0-9_\-]{8,}|gh[pousr]_[A-Za-z0-9]{16,}|sk-[A-Za-z0-9]{16,})", re.I)


def run_git(root: Path, args: list[str], allow_failure: bool = False) -> subprocess.CompletedProcess[str]:
    cp = subprocess.run(["git", "-C", str(root), *args], text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    if cp.returncode and not allow_failure:
        raise RuntimeError(f"Git command failed in '{root}': git {' '.join(args)}")
    return cp


def git_state(root: Path) -> dict[str, Any]:
    branch = run_git(root, ["rev-parse", "--abbrev-ref", "HEAD"]).stdout.strip()
    head = run_git(root, ["rev-parse", "HEAD"]).stdout.strip()
    dirty = bool(run_git(root, ["status", "--porcelain"]).stdout.strip())
    upstream_result = run_git(root, ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"], True)
    upstream = None
    ahead = None
    behind = None
    if upstream_result.returncode == 0 and upstream_result.stdout.strip():
        upstream = upstream_result.stdout.strip()
        counts = run_git(root, ["rev-list", "--left-right", "--count", f"HEAD...{upstream}"], True)
        match = re.match(r"^(\d+)\s+(\d+)$", counts.stdout.strip()) if counts.returncode == 0 else None
        if match:
            ahead, behind = int(match.group(1)), int(match.group(2))
    fingerprint_parts = [
        f"head={head}",
        run_git(root, ["status", "--porcelain=v1", "--untracked-files=all"]).stdout.replace("\r\n", "\n"),
    ]
    changed = run_git(root, ["diff", "--name-only", "HEAD", "--"], True)
    untracked = run_git(root, ["ls-files", "--others", "--exclude-standard"], True)
    paths = sorted({line.strip() for line in (changed.stdout + "\n" + untracked.stdout).splitlines() if line.strip()})
    for relative in paths:
        hashed = run_git(root, ["hash-object", "--no-filters", "--", relative], True)
        fingerprint_parts.append(f"{relative}={hashed.stdout.strip() if hashed.returncode == 0 else 'DELETED'}")
    fingerprint = hashlib.sha256("\n".join(fingerprint_parts).encode("utf-8")).hexdigest()
    return {
        "branch": branch,
        "head": head,
        "dirty": dirty,
        "upstream": upstream,
        "ahead": ahead,
        "behind": behind,
        "fingerprint": fingerprint,
    }


def resolve_path(root: Path, value: str) -> Path:
    path = Path(value)
    return path.resolve() if path.is_absolute() else (root / path).resolve()


def require_context_files(context_root: Path) -> None:
    for relative in ("AI_CONTEXT.md", "project/authority.md", "state/current.md", "state/next-action.md", "repositories/repositories.yaml"):
        if not (context_root / relative).is_file():
            raise RuntimeError(f"Central context is missing required file: {relative}")


def parse_registry_scalar(raw: str, label: str) -> str:
    value = raw.strip()
    if " #" in value:
        value = value.split(" #", 1)[0].rstrip()
    if not value:
        raise RuntimeError(f"Repository registry {label} must not be empty.")
    if value.startswith('"'):
        try:
            decoded = json.loads(value)
        except json.JSONDecodeError as exc:
            raise RuntimeError(f"Repository registry {label} has invalid quoted YAML scalar syntax.") from exc
        if not isinstance(decoded, str) or not decoded.strip():
            raise RuntimeError(f"Repository registry {label} must be a non-empty string.")
        return decoded
    if value.startswith("'"):
        if len(value) < 2 or not value.endswith("'"):
            raise RuntimeError(f"Repository registry {label} has invalid quoted YAML scalar syntax.")
        decoded = value[1:-1].replace("''", "'")
        if not decoded.strip():
            raise RuntimeError(f"Repository registry {label} must be a non-empty string.")
        return decoded
    return value


def load_repository_registry(context_root: Path) -> dict[str, Any]:
    registry_path = context_root / "repositories" / "repositories.yaml"
    try:
        lines = registry_path.read_text(encoding="utf-8-sig").splitlines()
    except UnicodeDecodeError as exc:
        raise RuntimeError("Repository registry must be UTF-8 text.") from exc

    project: str | None = None
    repositories: dict[str, dict[str, str | None]] = {}
    saw_repositories = False
    in_repositories = False
    current_repository: str | None = None
    current_fields: dict[str, str] = {}
    ignored_top_level_block = False
    ignored_repository_metadata = False

    def finish_repository() -> None:
        nonlocal current_repository, current_fields
        if current_repository is None:
            return
        role = current_fields.get("role")
        if role is None or not role.strip():
            raise RuntimeError(f"Repository registry entry '{current_repository}' is missing required role.")
        repositories[current_repository] = {"role": role, "path": current_fields.get("path")}
        current_repository = None
        current_fields = {}

    for line_number, original in enumerate(lines, start=1):
        if "\t" in original:
            raise RuntimeError(f"Repository registry uses unsupported tab indentation at line {line_number}.")
        stripped = original.strip()
        if not stripped or stripped.startswith("#"):
            continue
        indent = len(original) - len(original.lstrip(" "))
        if indent % 2 != 0:
            raise RuntimeError(f"Repository registry uses unsupported indentation at line {line_number}.")

        if ignored_top_level_block:
            if indent > 0:
                continue
            ignored_top_level_block = False

        if in_repositories and ignored_repository_metadata:
            if indent > 4:
                continue
            ignored_repository_metadata = False

        if in_repositories and not original.startswith(" "):
            finish_repository()
            in_repositories = False

        if in_repositories:
            repo_match = re.fullmatch(r"  ([A-Za-z0-9][A-Za-z0-9._-]{0,127}):\s*", original)
            if repo_match:
                finish_repository()
                repo_id = repo_match.group(1)
                if repo_id in repositories:
                    raise RuntimeError(f"Repository registry contains duplicate repository id '{repo_id}'.")
                current_repository = repo_id
                current_fields = {}
                continue

            field_match = re.fullmatch(r"    (path|role):\s*(.*)", original)
            if field_match and current_repository is not None:
                field, raw_value = field_match.groups()
                if field in current_fields:
                    raise RuntimeError(f"Repository registry entry '{current_repository}' contains duplicate field '{field}'.")
                current_fields[field] = parse_registry_scalar(raw_value, f"{current_repository}.{field}")
                continue

            metadata_match = re.fullmatch(r"    ([A-Za-z0-9_][A-Za-z0-9_.-]*):\s*(.*)", original)
            if metadata_match and current_repository is not None:
                field, raw_value = metadata_match.groups()
                if raw_value.strip():
                    parse_registry_scalar(raw_value, f"{current_repository}.{field}")
                else:
                    ignored_repository_metadata = True
                continue

            raise RuntimeError(f"Repository registry has unsupported structure at line {line_number}.")

        top_match = re.fullmatch(r"([A-Za-z0-9_][A-Za-z0-9_.-]*):\s*(.*)", original)
        if not top_match:
            raise RuntimeError(f"Repository registry has unsupported top-level syntax at line {line_number}.")
        key, raw_value = top_match.groups()
        if key == "project":
            if project is not None:
                raise RuntimeError("Repository registry contains duplicate project field.")
            project = parse_registry_scalar(raw_value, "project")
        elif key == "repositories":
            if saw_repositories:
                raise RuntimeError("Repository registry contains duplicate repositories field.")
            saw_repositories = True
            compact = raw_value.strip()
            if compact in {"[]", "{}"}:
                in_repositories = False
            elif compact == "":
                in_repositories = True
            else:
                raise RuntimeError("Repository registry repositories field must be an indented mapping, [] or {}.")
        elif key in {"schema_version", "workspace_root", "context_source_mode", "context_source"}:
            if raw_value.strip():
                parse_registry_scalar(raw_value, key)
        else:
            if raw_value.strip():
                parse_registry_scalar(raw_value, key)
            else:
                ignored_top_level_block = True

    finish_repository()
    if project is None:
        raise RuntimeError("Repository registry is missing required project field.")
    if not saw_repositories:
        raise RuntimeError("Repository registry is missing required repositories field.")
    return {"project": project, "repositories": repositories, "path": "repositories/repositories.yaml"}


def membership_info(context_root: Path, config: dict[str, Any]) -> dict[str, Any]:
    registry = load_repository_registry(context_root)
    configured_project = str(config.get("project") or "")
    repo_id = str(config.get("repository") or "")
    project_matches = configured_project == registry["project"]
    entry = registry["repositories"].get(repo_id) if project_matches else None
    registered = entry is not None
    issue = None
    if not project_matches:
        issue = f"Member project '{configured_project}' does not match central context project '{registry['project']}'."
    elif not registered:
        issue = f"Repository '{repo_id}' is not registered in {registry['path']}."
    return {
        "registered": registered,
        "projectMatches": project_matches,
        "centralProject": registry["project"],
        "role": entry.get("role") if entry else None,
        "path": entry.get("path") if entry else None,
        "registryPath": registry["path"],
        "issue": issue,
    }


def require_registered_member(context_root: Path, config: dict[str, Any]) -> dict[str, Any]:
    membership = membership_info(context_root, config)
    if not membership["projectMatches"] or not membership["registered"]:
        raise RuntimeError(str(membership["issue"]))
    return membership


def read_optional(path: Path) -> str | None:
    return path.read_text(encoding="utf-8-sig") if path.is_file() else None


def write_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes((json.dumps(value, ensure_ascii=False, indent=2) + "\n").encode("utf-8"))


def write_text(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(text.replace("\r\n", "\n").replace("\r", "\n").encode("utf-8"))


def runtime_bundle(
    member_root: Path,
    context_root: Path,
    config: dict[str, Any],
    freshness: str,
    membership: dict[str, Any] | None = None,
) -> dict[str, Any]:
    member_state = git_state(member_root)
    context_state = git_state(context_root)
    membership = membership or membership_info(context_root, config)
    generated = dt.datetime.now().astimezone().isoformat()
    runtime = {
        "schemaVersion": 1,
        "generatedAt": generated,
        "project": str(config["project"]),
        "repository": str(config["repository"]),
        "member": {
            "root": str(member_root),
            "branch": member_state["branch"],
            "head": member_state["head"],
            "dirty": member_state["dirty"],
            "upstream": member_state["upstream"],
            "ahead": member_state["ahead"],
            "behind": member_state["behind"],
            "fingerprint": member_state["fingerprint"],
        },
        "context": {
            "root": str(context_root),
            "remote": str(config["context"]["remote"]),
            "branch": context_state["branch"],
            "head": context_state["head"],
            "dirty": context_state["dirty"],
            "freshness": freshness,
        },
        "membership": membership,
    }
    repo_id = str(config["repository"])
    repository_manifest = read_json_optional(context_root / f"manifests/repositories/{repo_id}.json")
    continuity_meta = repository_manifest.get("continuity") if repository_manifest and isinstance(repository_manifest.get("continuity"), dict) else None
    workstream: dict[str, Any] | None = None
    if continuity_meta and continuity_meta.get("workstreamPath"):
        workstream = read_json_optional(context_root / str(continuity_meta["workstreamPath"]))
    validation_summary = validation_runtime_summary(context_root, repo_id, member_state)
    runtime["continuity"] = {
        "mode": continuity_meta.get("mode") if continuity_meta else "legacy",
        "workstreamId": continuity_meta.get("workstreamId") if continuity_meta else None,
        "workstreamStatus": continuity_meta.get("workstreamStatus") if continuity_meta else None,
        "currentItemId": continuity_meta.get("currentItemId") if continuity_meta else None,
        "workstreamPath": continuity_meta.get("workstreamPath") if continuity_meta else None,
        "validation": validation_summary,
    }
    bridge = member_root / ".ai-bridge"
    bridge.mkdir(parents=True, exist_ok=True)
    write_json(bridge / "context-runtime.json", runtime)
    lines = [
        "# Runtime AI Context", "", f"Generated: {generated}", f"Repository: {runtime['repository']}",
        f"Repository HEAD: {member_state['head']}", f"Repository branch: {member_state['branch']}",
        f"Repository dirty: {member_state['dirty']}", f"Context HEAD: {context_state['head']}",
        f"Context freshness: {freshness}",
        f"Member registered: {membership['registered']}",
        f"Member role: {membership['role'] or 'none'}", "",
        "> This bundle is generated runtime evidence. Canonical implementation sources still outrank AI context.",
    ]
    inputs = [
        ("Central Entry Point", "AI_CONTEXT.md"), ("Authority", "project/authority.md"),
        ("Current Project State", "state/current.md"), ("Next Action", "state/next-action.md"),
        ("Open Questions", "state/open-questions.md"), ("Pending Decisions", "state/pending-decisions.md"),
        ("Repository Map", "repositories/repositories.yaml"),
    ]
    inputs.extend([
        ("Latest Repository State", f"state/repositories/{repo_id}.md"),
        ("Latest Repository Handoff", f"handoffs/repositories/{repo_id}.md"),
        ("Repository Provenance", f"manifests/repositories/{repo_id}.json"),
    ])
    for title, relative in inputs:
        text = read_optional(context_root / relative)
        if text is not None:
            lines.extend(["", f"## {title}", "", f"Source: `{relative}`", "", text.rstrip()])
    if workstream is not None:
        lines.extend(["", "## Active Workstream", "", f"Source: `{runtime['continuity']['workstreamPath']}`", "", render_workstream_markdown(workstream).rstrip()])
    lines.extend([
        "",
        "## Validation Freshness",
        "",
        f"Source: `{validation_summary['path']}`",
        "",
        f"Entries: {validation_summary['entries']}",
        f"Fresh for current worktree: {validation_summary['freshEntries']}",
        f"Stale for current worktree: {validation_summary['staleEntries']}",
    ])
    most_recent_validation = validation_summary.get("mostRecent")
    if isinstance(most_recent_validation, dict):
        lines.extend([
            f"Latest validation: `{most_recent_validation.get('id')}` / `{most_recent_validation.get('result')}` - {most_recent_validation.get('summary')}",
        ])
    write_text(bridge / "context-runtime.md", "\n".join(lines) + "\n")
    return runtime


def remote_repository_name(remote: str) -> str | None:
    value = remote.rstrip("/\\")
    if not value:
        return None
    name = re.split(r"[/\\]", value)[-1]
    return name[:-4] if name.endswith(".git") else name


def normalize_remote_identity(remote: str) -> str:
    value = remote.strip().replace("\\", "/").rstrip("/")
    if value.endswith(".git"):
        value = value[:-4]
    scp_match = re.match(r"^[^@/\s]+@([^:]+):(.+)$", value)
    if scp_match:
        return f"{scp_match.group(1).lower()}/{scp_match.group(2).lstrip('/')}"
    url_match = re.match(r"^[A-Za-z][A-Za-z0-9+.-]*://(?:[^@/]+@)?([^/]+)/(.+)$", value)
    if url_match:
        return f"{url_match.group(1).lower()}/{url_match.group(2).lstrip('/')}"
    return value


def repository_has_remote_identity(repository_root: Path, expected_remote: str) -> bool:
    expected = normalize_remote_identity(expected_remote)
    if not expected:
        return False
    remotes = run_git(repository_root, ["remote"], True)
    if remotes.returncode != 0:
        return False
    for remote_name in (line.strip() for line in remotes.stdout.splitlines() if line.strip()):
        urls = run_git(repository_root, ["remote", "get-url", "--all", remote_name], True)
        if urls.returncode != 0:
            continue
        for url in (line.strip() for line in urls.stdout.splitlines() if line.strip()):
            if normalize_remote_identity(url) == expected:
                return True
    return False


def resolve_registered_local_path(member_root: Path, context_root: Path, configured_path: str | None, repo_id: str) -> Path:
    if configured_path:
        candidate = Path(configured_path)
        if candidate.is_absolute():
            return candidate.resolve()
        from_context = (context_root / candidate).resolve()
        if from_context.exists():
            return from_context
        if candidate.name:
            return (member_root.parent / candidate.name).resolve()
    return (member_root.parent / repo_id).resolve()


def audit_membership(member_root: Path, context_root: Path, config: dict[str, Any]) -> dict[str, Any]:
    registry = load_repository_registry(context_root)
    configured_project = str(config.get("project") or "")
    if configured_project != registry["project"]:
        raise RuntimeError(f"Member project '{configured_project}' does not match central context project '{registry['project']}'.")

    registered_results: list[dict[str, Any]] = []
    registered_names = set(registry["repositories"])
    for repo_id, entry in sorted(registry["repositories"].items()):
        local_path = resolve_registered_local_path(member_root, context_root, entry.get("path"), repo_id)
        result: dict[str, Any] = {
            "repository": repo_id,
            "role": entry.get("role"),
            "configuredPath": entry.get("path"),
            "localPath": str(local_path),
            "status": "ok",
            "issues": [],
        }
        if not local_path.exists():
            result["status"] = "missing-local-path"
            result["issues"].append("Registered repository local path is missing.")
        elif not (local_path / ".git").exists():
            result["status"] = "not-git-repository"
            result["issues"].append("Registered local path is not a Git repository/worktree.")
        else:
            member_config_path = local_path / ".ai" / "context" / "config.json"
            if not member_config_path.is_file():
                result["status"] = "missing-context-config"
                result["issues"].append("Registered repository is missing .ai/context/config.json.")
            else:
                try:
                    member_config = json.loads(member_config_path.read_text(encoding="utf-8-sig"))
                except Exception:
                    result["status"] = "invalid-context-config"
                    result["issues"].append("Member context config is invalid JSON.")
                else:
                    if str(member_config.get("project") or "") != registry["project"]:
                        result["issues"].append("Member context project does not match central project.")
                    if str(member_config.get("repository") or "") != repo_id:
                        result["issues"].append("Member context repository id does not match registry id.")
                    if result["issues"]:
                        result["status"] = "mismatched-context-config"
        registered_results.append(result)

    context_remote = str((config.get("context") or {}).get("remote") or "")
    context_repo_name = remote_repository_name(context_remote)
    candidates: list[dict[str, Any]] = []
    workspace_root = member_root.parent.resolve()
    for candidate in sorted((path for path in workspace_root.iterdir() if path.is_dir()), key=lambda path: path.name.lower()):
        if candidate.name in registered_names or candidate.name == context_repo_name:
            continue
        if not (candidate / ".git").exists():
            continue
        if repository_has_remote_identity(candidate, context_remote):
            continue
        looks_managed = (
            (candidate / "AI_CONTEXT.md").is_file()
            or (candidate / ".ai" / "context").exists()
            or candidate.name.startswith(f"{registry['project']}-")
        )
        if not looks_managed:
            continue
        candidates.append({
            "repository": candidate.name,
            "localPath": str(candidate.resolve()),
            "reason": "Sibling Git repository resembles a project member but is not registered.",
        })

    return {
        "schemaVersion": 1,
        "project": registry["project"],
        "registryPath": registry["path"],
        "workspaceRoot": str(workspace_root),
        "registered": registered_results,
        "unregisteredCandidates": candidates,
        "summary": {
            "registered": len(registered_results),
            "healthy": sum(1 for item in registered_results if item["status"] == "ok"),
            "issues": sum(1 for item in registered_results if item["status"] != "ok"),
            "candidates": len(candidates),
        },
    }


def validate_context_id(value: Any, label: str) -> str:
    text = str(value or "").strip()
    if not SAFE_CONTEXT_ID.fullmatch(text):
        raise RuntimeError(f"{label} must use a stable alphanumeric/dot/underscore/hyphen identifier.")
    return text


def require_string_list(value: Any, label: str) -> list[str]:
    if not isinstance(value, list) or any(not isinstance(item, str) or not item.strip() for item in value):
        raise RuntimeError(f"{label} must be an array of non-empty strings.")
    if len(set(value)) != len(value):
        raise RuntimeError(f"{label} must not contain duplicate values.")
    return value


def validate_workstream(workstream: dict[str, Any], expected_repository: str, checkpoint_next_action: str) -> None:
    required = ("id", "title", "status", "objective", "repositories", "cursor", "items")
    for field in required:
        if field not in workstream:
            raise RuntimeError(f"Continuity workstream is missing required field: {field}")
    workstream_id = validate_context_id(workstream["id"], "Workstream id")
    if not str(workstream["title"]).strip() or not str(workstream["objective"]).strip():
        raise RuntimeError("Continuity workstream title/objective must not be empty.")
    status = str(workstream["status"])
    if status not in WORKSTREAM_STATUSES:
        raise RuntimeError("Continuity workstream status is not allowed.")

    repositories = workstream["repositories"]
    if not isinstance(repositories, list) or not repositories:
        raise RuntimeError("Continuity workstream repositories must be a non-empty array.")
    repository_ids: list[str] = []
    for entry in repositories:
        if not isinstance(entry, dict):
            raise RuntimeError("Continuity workstream repository entries must be objects.")
        repository_ids.append(validate_context_id(entry.get("repository"), "Workstream repository"))
        if not str(entry.get("role") or "").strip():
            raise RuntimeError("Continuity workstream repository role must not be empty.")
    if len(set(repository_ids)) != len(repository_ids):
        raise RuntimeError("Continuity workstream repositories must not contain duplicates.")
    if expected_repository not in repository_ids:
        raise RuntimeError("Tracked workstream must include the active repository in repositories[].")

    items = workstream["items"]
    if not isinstance(items, list):
        raise RuntimeError("Continuity workstream items must be an array.")
    item_map: dict[str, dict[str, Any]] = {}
    for item in items:
        if not isinstance(item, dict):
            raise RuntimeError("Continuity work items must be objects.")
        for field in ("id", "title", "status", "priority", "scope", "acceptanceCriteria", "dependsOn", "blockedBy", "validationRequirements", "notes"):
            if field not in item:
                raise RuntimeError(f"Continuity work item is missing required field: {field}")
        item_id = validate_context_id(item["id"], "Work item id")
        if item_id in item_map:
            raise RuntimeError(f"Duplicate continuity work item id: {item_id}")
        if not str(item["title"]).strip():
            raise RuntimeError(f"Work item {item_id} title must not be empty.")
        if str(item["status"]) not in WORK_ITEM_STATUSES:
            raise RuntimeError(f"Work item {item_id} status is not allowed.")
        if str(item["priority"]) not in {"CRITICAL", "HIGH", "MEDIUM", "LOW"}:
            raise RuntimeError(f"Work item {item_id} priority is not allowed.")
        for field in ("scope", "acceptanceCriteria", "dependsOn", "blockedBy", "validationRequirements", "notes"):
            require_string_list(item[field], f"Work item {item_id} {field}")
        item_map[item_id] = item

    for item_id, item in item_map.items():
        for reference in [*item["dependsOn"], *item["blockedBy"]]:
            if reference not in item_map:
                raise RuntimeError(f"Work item {item_id} references unknown work item: {reference}")
            if reference == item_id:
                raise RuntimeError(f"Work item {item_id} must not depend on or block itself.")
        if str(item["status"]) == "BLOCKED" and not item["blockedBy"]:
            raise RuntimeError(f"Blocked work item {item_id} must declare blockedBy item ids.")

    visiting: set[str] = set()
    visited: set[str] = set()
    def visit(item_id: str) -> None:
        if item_id in visited:
            return
        if item_id in visiting:
            raise RuntimeError(f"Workstream {workstream_id} contains a dependency cycle at {item_id}.")
        visiting.add(item_id)
        for dependency in item_map[item_id]["dependsOn"]:
            visit(dependency)
        visiting.remove(item_id)
        visited.add(item_id)
    for item_id in item_map:
        visit(item_id)

    cursor = workstream["cursor"]
    if not isinstance(cursor, dict):
        raise RuntimeError("Continuity workstream cursor must be an object.")
    for field in ("currentItemId", "lastCompletedItemId", "phase", "lastCompletedAction", "nextAction"):
        if field not in cursor:
            raise RuntimeError(f"Continuity cursor is missing required field: {field}")
    if not str(cursor["nextAction"] or "").strip():
        raise RuntimeError("Continuity cursor nextAction must not be empty.")
    if str(cursor["nextAction"]).strip() != checkpoint_next_action.strip():
        raise RuntimeError("Continuity cursor nextAction must match checkpoint nextAction exactly.")
    current_item = cursor["currentItemId"]
    if current_item is not None:
        current_item = validate_context_id(current_item, "Continuity cursor currentItemId")
        if current_item not in item_map:
            raise RuntimeError("Continuity cursor currentItemId does not reference a work item.")
        if str(item_map[current_item]["status"]) not in {"IN_PROGRESS", "BLOCKED"}:
            raise RuntimeError("Continuity cursor currentItemId must reference an IN_PROGRESS or BLOCKED item.")
    last_completed = cursor["lastCompletedItemId"]
    if last_completed is not None:
        last_completed = validate_context_id(last_completed, "Continuity cursor lastCompletedItemId")
        if last_completed not in item_map or str(item_map[last_completed]["status"]) != "COMPLETED":
            raise RuntimeError("Continuity cursor lastCompletedItemId must reference a COMPLETED item.")

    unresolved = [item for item in items if str(item["status"]) not in TERMINAL_WORK_ITEM_STATUSES]
    if status in {"IN_PROGRESS", "BLOCKED"} and unresolved and current_item is None:
        raise RuntimeError("Active/blocked workstream with unresolved items must declare cursor.currentItemId.")
    if status in TERMINAL_WORKSTREAM_STATUSES:
        if unresolved:
            raise RuntimeError("Terminal workstream cannot retain unresolved work items.")
        if current_item is not None:
            raise RuntimeError("Terminal workstream cursor.currentItemId must be null.")


def validate_validation_entries(entries: Any, expected_repository: str) -> None:
    if not isinstance(entries, list):
        raise RuntimeError("Continuity validationLedger must be an array.")
    seen: set[str] = set()
    for entry in entries:
        if not isinstance(entry, dict):
            raise RuntimeError("Continuity validation entries must be objects.")
        for field in ("id", "kind", "result", "repository", "scope", "summary", "timestamp", "command", "evidenceRefs"):
            if field not in entry:
                raise RuntimeError(f"Continuity validation entry is missing required field: {field}")
        entry_id = validate_context_id(entry["id"], "Validation entry id")
        if entry_id in seen:
            raise RuntimeError(f"Duplicate continuity validation entry id: {entry_id}")
        seen.add(entry_id)
        if validate_context_id(entry["repository"], "Validation repository") != expected_repository:
            raise RuntimeError("Checkpoint may only append validation ledger entries for the active repository.")
        if str(entry["result"]) not in {"PASS", "FAIL", "INCONCLUSIVE", "SKIPPED"}:
            raise RuntimeError(f"Validation entry {entry_id} result is not allowed.")
        for field in ("kind", "scope", "summary", "timestamp"):
            if not str(entry[field] or "").strip():
                raise RuntimeError(f"Validation entry {entry_id} {field} must not be empty.")
        if entry["command"] is not None and not isinstance(entry["command"], str):
            raise RuntimeError(f"Validation entry {entry_id} command must be a string or null.")
        require_string_list(entry["evidenceRefs"], f"Validation entry {entry_id} evidenceRefs")


def validate_checkpoint(checkpoint: dict[str, Any], expected_repository: str) -> None:
    for field in ("schemaVersion", "repository", "scope", "status", "objective", "nextAction"):
        if field not in checkpoint:
            raise RuntimeError(f"Checkpoint is missing required field: {field}")
        if field != "schemaVersion" and not str(checkpoint[field]).strip():
            raise RuntimeError(f"Checkpoint field must not be empty: {field}")
    version = int(checkpoint["schemaVersion"])
    if version not in {1, 2}:
        raise RuntimeError("Unsupported checkpoint schemaVersion.")
    if str(checkpoint["repository"]) != expected_repository:
        raise RuntimeError("Checkpoint repository does not match the active repository config.")
    if str(checkpoint["status"]) not in ALLOWED_STATUSES:
        raise RuntimeError("Checkpoint status is not allowed.")
    for field in ("confirmedFindings", "decisions", "rejectedApproaches", "validation", "openQuestions"):
        value = checkpoint.get(field)
        if not isinstance(value, list):
            raise RuntimeError(f"Checkpoint field must be an array: {field}")
    if version == 1:
        if "continuity" in checkpoint:
            raise RuntimeError("schemaVersion 1 checkpoints must not include continuity; use schemaVersion 2.")
        return
    continuity = checkpoint.get("continuity")
    if not isinstance(continuity, dict):
        raise RuntimeError("schemaVersion 2 checkpoint requires continuity object.")
    mode = str(continuity.get("mode") or "")
    if mode not in {"snapshot", "tracked"}:
        raise RuntimeError("Continuity mode must be snapshot or tracked.")
    validate_validation_entries(continuity.get("validationLedger"), expected_repository)
    workstream = continuity.get("workstream")
    if mode == "snapshot":
        if workstream is not None:
            raise RuntimeError("Snapshot continuity mode must use workstream: null.")
        if str(checkpoint["status"]) in ACTIVE_CHECKPOINT_STATUSES:
            raise RuntimeError("Active checkpoint statuses require tracked continuity mode.")
    else:
        if not isinstance(workstream, dict):
            raise RuntimeError("Tracked continuity mode requires a workstream object.")
        validate_workstream(workstream, expected_repository, str(checkpoint["nextAction"]))


def read_json_optional(path: Path) -> dict[str, Any] | None:
    if not path.is_file():
        return None
    value = json.loads(path.read_text(encoding="utf-8-sig"))
    if not isinstance(value, dict):
        raise RuntimeError(f"Context JSON record must be an object: {path}")
    return value


def unresolved_workstream(workstream: dict[str, Any]) -> bool:
    return str(workstream.get("status")) not in TERMINAL_WORKSTREAM_STATUSES and any(
        str(item.get("status")) not in TERMINAL_WORK_ITEM_STATUSES for item in workstream.get("items", [])
    )


def reject_reviewed_legacy_on_posix(context_root: Path, repository: str) -> None:
    # Python does not yet implement scoped independent-root enrollment. Never
    # overwrite protected legacy summaries through its older repository writer.
    if not SAFE_CONTEXT_ID.fullmatch(repository):
        raise RuntimeError("CONTEXT_UNSYNCED: invalid reconciliation repository identity.")
    relative = f"references/continuity-reconciliations/{repository}.json"
    path = context_root / relative
    committed = run_git(context_root, ["cat-file", "-e", f"HEAD:{relative}"], True)
    if path.exists() or path.is_symlink() or committed.returncode == 0:
        raise RuntimeError("CONTEXT_UNSYNCED: reviewed independent-root enrollment requires the native Windows lifecycle; POSIX legacy writes are disabled for this repository.")


def previous_continuity(context_root: Path, repository: str) -> tuple[dict[str, Any] | None, dict[str, Any] | None]:
    manifest = read_json_optional(context_root / f"manifests/repositories/{repository}.json")
    if not manifest or not isinstance(manifest.get("continuity"), dict):
        return manifest, None
    relative = manifest["continuity"].get("workstreamPath")
    if not relative:
        return manifest, None
    return manifest, read_json_optional(context_root / str(relative))


def validate_continuity_transition(context_root: Path, checkpoint: dict[str, Any], repository: str) -> None:
    if int(checkpoint["schemaVersion"]) == 2:
        ledger = load_validation_ledger(context_root, repository)
        existing_validation_ids = {str(entry.get("id")) for entry in ledger["entries"] if isinstance(entry, dict)}
        duplicate_validation_ids = sorted(
            str(entry["id"]) for entry in checkpoint["continuity"]["validationLedger"] if str(entry["id"]) in existing_validation_ids
        )
        if duplicate_validation_ids:
            raise RuntimeError("Validation ledger entry ids are immutable and already exist: " + ", ".join(duplicate_validation_ids))
    _manifest, previous = previous_continuity(context_root, repository)
    if previous is None:
        return
    if int(checkpoint["schemaVersion"]) == 1:
        if unresolved_workstream(previous):
            raise RuntimeError("Legacy schemaVersion 1 checkpoint would lose an active tracked workstream; use schemaVersion 2 and carry every work item forward.")
        return
    continuity = checkpoint["continuity"]
    current = continuity.get("workstream")
    if current is None:
        if unresolved_workstream(previous):
            raise RuntimeError("Snapshot checkpoint would lose an active tracked workstream; close or supersede its work items explicitly first.")
        return
    if str(current["id"]) != str(previous.get("id")):
        if unresolved_workstream(previous):
            raise RuntimeError("Cannot switch workstream ids while the previous tracked workstream still has unresolved items.")
        return

    previous_status = str(previous.get("status"))
    current_status = str(current.get("status"))
    if previous_status in TERMINAL_WORKSTREAM_STATUSES and current_status != previous_status:
        raise RuntimeError("Terminal workstream status is immutable; start a new workstream instead of reopening it.")
    previous_items = {str(item["id"]): item for item in previous.get("items", [])}
    current_items = {str(item["id"]): item for item in current.get("items", [])}
    missing = sorted(set(previous_items) - set(current_items))
    if missing:
        raise RuntimeError("Checkpoint would lose existing work items: " + ", ".join(missing))
    for item_id, previous_item in previous_items.items():
        before = str(previous_item.get("status"))
        after = str(current_items[item_id].get("status"))
        if after not in WORK_ITEM_TRANSITIONS.get(before, set()):
            raise RuntimeError(f"Invalid work item status transition for {item_id}: {before} -> {after}")


def workstream_relative_path(workstream: dict[str, Any]) -> str:
    bucket = "archive" if str(workstream["status"]) in TERMINAL_WORKSTREAM_STATUSES else "active"
    return f"workstreams/{bucket}/{workstream['id']}.json"


def validation_ledger_relative_path(repository: str) -> str:
    return f"validation/repositories/{repository}.json"


def render_workstream_markdown(workstream: dict[str, Any]) -> str:
    cursor = workstream.get("cursor") or {}
    lines = [
        f"# Workstream - {workstream.get('title', workstream.get('id', 'unknown'))}",
        "",
        f"ID: `{workstream.get('id')}`",
        f"Status: `{workstream.get('status')}`",
        f"Current item: `{cursor.get('currentItemId') or 'none'}`",
        f"Last completed item: `{cursor.get('lastCompletedItemId') or 'none'}`",
        f"Phase: `{cursor.get('phase') or 'unspecified'}`",
        "",
        "## Objective",
        "",
        str(workstream.get("objective") or ""),
        "",
        "## Execution Cursor",
        "",
        f"Last completed action: {cursor.get('lastCompletedAction') or 'None.'}",
        f"Next action: {cursor.get('nextAction') or 'None.'}",
        "",
        "## Work Items",
        "",
    ]
    items = workstream.get("items") or []
    if not items:
        lines.append("- None.")
    for item in items:
        dependencies = ", ".join(item.get("dependsOn") or []) or "none"
        blockers = ", ".join(item.get("blockedBy") or []) or "none"
        lines.extend([
            f"### {item.get('id')} - {item.get('title')}",
            "",
            f"Status: `{item.get('status')}` | Priority: `{item.get('priority')}`",
            f"Depends on: {dependencies}",
            f"Blocked by: {blockers}",
            "",
            "Acceptance criteria:",
            bullets(item.get("acceptanceCriteria") or []),
            "",
            "Validation requirements:",
            bullets(item.get("validationRequirements") or []),
            "",
        ])
    return "\n".join(lines).rstrip() + "\n"


def load_validation_ledger(context_root: Path, repository: str) -> dict[str, Any]:
    path = context_root / validation_ledger_relative_path(repository)
    value = read_json_optional(path)
    if value is None:
        return {"schemaVersion": 2, "repository": repository, "entries": []}
    if int(value.get("schemaVersion", 0)) != 2 or str(value.get("repository")) != repository or not isinstance(value.get("entries"), list):
        raise RuntimeError(f"Validation ledger is invalid for repository {repository}.")
    return value


def validation_runtime_summary(context_root: Path, repository: str, member_state: dict[str, Any]) -> dict[str, Any]:
    ledger = load_validation_ledger(context_root, repository)
    entries = ledger["entries"]
    fresh = 0
    stale = 0
    for entry in entries:
        valid_for = entry.get("validFor") if isinstance(entry, dict) else None
        if isinstance(valid_for, dict) and str(valid_for.get("fingerprint")) == member_state["fingerprint"]:
            fresh += 1
        else:
            stale += 1
    most_recent = entries[-1] if entries else None
    return {
        "path": validation_ledger_relative_path(repository),
        "entries": len(entries),
        "freshEntries": fresh,
        "staleEntries": stale,
        "mostRecent": most_recent,
    }


def persist_continuity(
    context_root: Path,
    checkpoint: dict[str, Any],
    member_state: dict[str, Any],
    generated: str,
    session_rel: str,
) -> tuple[dict[str, Any] | None, list[str]]:
    if int(checkpoint["schemaVersion"]) != 2:
        return None, []
    repository = str(checkpoint["repository"])
    continuity = checkpoint["continuity"]
    ledger_rel = validation_ledger_relative_path(repository)
    ledger = load_validation_ledger(context_root, repository)
    existing_ids = {str(entry.get("id")) for entry in ledger["entries"] if isinstance(entry, dict)}
    for source in continuity["validationLedger"]:
        entry_id = str(source["id"])
        if entry_id in existing_ids:
            raise RuntimeError(f"Validation ledger entry id already exists and is immutable: {entry_id}")
        stored = dict(source)
        stored["recordedAt"] = generated
        stored["validFor"] = {
            "head": member_state["head"],
            "dirty": member_state["dirty"],
            "fingerprint": member_state["fingerprint"],
        }
        ledger["entries"].append(stored)
        existing_ids.add(entry_id)
    ledger["updatedAt"] = generated
    write_json(context_root / ledger_rel, ledger)
    paths = [ledger_rel]

    workstream = continuity.get("workstream")
    workstream_rel: str | None = None
    previous_manifest, _previous_workstream = previous_continuity(context_root, repository)
    previous_rel = None
    if previous_manifest and isinstance(previous_manifest.get("continuity"), dict):
        previous_rel = previous_manifest["continuity"].get("workstreamPath")
    if workstream is not None:
        workstream_rel = workstream_relative_path(workstream)
        stored_workstream = dict(workstream)
        stored_workstream["schemaVersion"] = 2
        stored_workstream["updatedAt"] = generated
        stored_workstream["lastCheckpoint"] = {
            "repository": repository,
            "branch": member_state["branch"],
            "head": member_state["head"],
            "dirty": member_state["dirty"],
            "fingerprint": member_state["fingerprint"],
            "session": session_rel,
        }
        write_json(context_root / workstream_rel, stored_workstream)
        paths.append(workstream_rel)
    if previous_rel and previous_rel != workstream_rel:
        previous_path = context_root / str(previous_rel)
        if previous_path.is_file():
            previous_path.unlink()
            paths.append(str(previous_rel))

    metadata = {
        "schemaVersion": 2,
        "mode": str(continuity["mode"]),
        "workstreamId": str(workstream["id"]) if workstream is not None else None,
        "workstreamStatus": str(workstream["status"]) if workstream is not None else None,
        "workstreamPath": workstream_rel,
        "currentItemId": (workstream.get("cursor") or {}).get("currentItemId") if workstream is not None else None,
        "validationLedgerPath": ledger_rel,
    }
    return metadata, paths


def validate_no_secrets(value: Any, path: str = "$") -> None:
    if value is None:
        return
    if isinstance(value, str):
        if FORBIDDEN_VALUE.search(value):
            raise RuntimeError(f"Checkpoint contains secret-like material at {path}.")
        return
    if isinstance(value, dict):
        for key, child in value.items():
            if FORBIDDEN_KEY.search(str(key)):
                raise RuntimeError(f"Checkpoint contains a forbidden credential-like field at {path}.")
            validate_no_secrets(child, f"{path}.{key}")
        return
    if isinstance(value, (list, tuple)):
        for index, child in enumerate(value):
            validate_no_secrets(child, f"{path}[{index}]")


def bullets(items: list[Any]) -> str:
    if not items:
        return "- None."
    return "\n".join("- " + str(item).strip() for item in items)


def slug(value: str) -> str:
    result = re.sub(r"[^a-z0-9._-]+", "-", value.strip().lower()).strip("-") or "checkpoint"
    return result[:64].rstrip("-") or "checkpoint"


def checkpoint_markdown(checkpoint: dict[str, Any], member_state: dict[str, Any], generated: str) -> str:
    lines = [
        "---", f"date: {generated}", f"status: {checkpoint['status']}", f"repository: {checkpoint['repository']}",
        f"branch: {member_state['branch']}", f"commit: {member_state['head']}", f"dirty: {str(member_state['dirty']).lower()}",
        f"worktreeFingerprint: {member_state['fingerprint']}", "---", "",
        "# Objective", "", str(checkpoint["objective"]), "", "# Confirmed Findings", "", bullets(checkpoint["confirmedFindings"]), "",
        "# Decisions", "", bullets(checkpoint["decisions"]), "", "# Rejected Approaches", "", bullets(checkpoint["rejectedApproaches"]), "",
        "# Validation", "", bullets(checkpoint["validation"]), "", "# Open Questions", "", bullets(checkpoint["openQuestions"]), "",
    ]
    if int(checkpoint["schemaVersion"]) == 2:
        continuity = checkpoint["continuity"]
        lines.extend(["# Continuity", "", f"Mode: `{continuity['mode']}`", ""])
        if continuity.get("workstream") is not None:
            lines.extend([render_workstream_markdown(continuity["workstream"]).rstrip(), ""])
        if continuity["validationLedger"]:
            lines.extend(["Validation ledger entries added by this checkpoint:", ""])
            for entry in continuity["validationLedger"]:
                lines.append(f"- `{entry['id']}` `{entry['result']}` - {entry['summary']}")
            lines.append("")
    lines.extend(["# Next Action", "", str(checkpoint["nextAction"]), ""])
    return "\n".join(lines)


def git_is_ancestor(context_root: Path, ancestor: str, descendant: str) -> bool:
    return run_git(context_root, ["merge-base", "--is-ancestor", ancestor, descendant], True).returncode == 0


def synchronize_checkpoint_push(context_root: Path, expected_branch: str) -> None:
    pushed = run_git(context_root, ["push", "origin", f"HEAD:{expected_branch}"], True)
    if pushed.returncode == 0:
        return

    run_git(context_root, ["fetch", "origin", expected_branch])
    remote_ref = f"origin/{expected_branch}"
    remote_is_ancestor = git_is_ancestor(context_root, remote_ref, "HEAD")
    local_is_ancestor = git_is_ancestor(context_root, "HEAD", remote_ref)

    if remote_is_ancestor and not local_is_ancestor:
        retried = run_git(context_root, ["push", "origin", f"HEAD:{expected_branch}"], True)
        if retried.returncode != 0:
            raise RuntimeError("Context push was rejected even though remote history is an ancestor of the local checkpoint; publication was not confirmed.")
        return

    if local_is_ancestor:
        run_git(context_root, ["merge", "--ff-only", remote_ref])
        return

    raise RuntimeError("Context push was rejected because local and remote context histories diverged. Automatic merge, rebase, reset, and force-push are forbidden; both histories were preserved.")


def do_checkpoint(member_root: Path, context_root: Path, config: dict[str, Any], expected_branch: str, offline: bool = False) -> None:
    reject_reviewed_legacy_on_posix(context_root, str(config["repository"]))
    context_state = git_state(context_root)
    checkpoint_freshness = "OFFLINE_IMPORTED_CONTEXT" if offline else "CURRENT_OR_FETCHED"
    if context_state["dirty"]:
        raise RuntimeError("Automated checkpoint refused because the central context cache has pre-existing uncommitted changes.")
    require_registered_member(context_root, config)
    checkpoint_path = member_root / ".ai-bridge" / "context-checkpoint.json"
    if not checkpoint_path.is_file():
        raise RuntimeError("No context checkpoint file exists at .ai-bridge/context-checkpoint.json.")
    checkpoint = json.loads(checkpoint_path.read_text(encoding="utf-8-sig"))
    repo_id = str(config["repository"])
    validate_checkpoint(checkpoint, repo_id)
    validate_no_secrets(checkpoint)
    validate_continuity_transition(context_root, checkpoint, repo_id)
    member_state = git_state(member_root)
    now = dt.datetime.now().astimezone()
    generated = now.isoformat()
    session_rel = f"sessions/{now:%Y}/{now:%m}/{now:%Y-%m-%d-%H%M%S}-{slug(repo_id)}-{slug(str(checkpoint['scope']))}.md"
    state_rel = f"state/repositories/{repo_id}.md"
    handoff_rel = f"handoffs/repositories/{repo_id}.md"
    manifest_rel = f"manifests/repositories/{repo_id}.json"
    continuity_meta, continuity_paths = persist_continuity(context_root, checkpoint, member_state, generated, session_rel)
    write_text(context_root / session_rel, checkpoint_markdown(checkpoint, member_state, generated))

    continuity_lines: list[str] = []
    if continuity_meta is not None:
        continuity_lines = [
            "## Continuity", "", f"Mode: `{continuity_meta['mode']}`",
            f"Workstream: `{continuity_meta['workstreamId'] or 'none'}`",
            f"Workstream status: `{continuity_meta['workstreamStatus'] or 'none'}`",
            f"Current item: `{continuity_meta['currentItemId'] or 'none'}`",
            f"Workstream record: `{continuity_meta['workstreamPath'] or 'none'}`",
            f"Validation ledger: `{continuity_meta['validationLedgerPath']}`", "",
        ]
    state_lines = [
        f"# Repository State - {repo_id}", "", f"Updated: {generated}", f"Status: `{checkpoint['status']}`",
        f"Branch: `{member_state['branch']}`", f"Commit: `{member_state['head']}`", f"Dirty: `{member_state['dirty']}`",
        f"Worktree fingerprint: `{member_state['fingerprint']}`", "",
        "## Objective", "", str(checkpoint["objective"]), "", "## Confirmed Findings", "", bullets(checkpoint["confirmedFindings"]), "",
        *continuity_lines,
        "## Open Questions", "", bullets(checkpoint["openQuestions"]), "", "## Next Action", "", str(checkpoint["nextAction"]), "",
        f"Latest session: `{session_rel}`", "",
    ]
    write_text(context_root / state_rel, "\n".join(state_lines))
    handoff_lines = [
        f"# Repository Handoff - {repo_id}", "", f"Updated: {generated}", f"Status: `{checkpoint['status']}`", "",
        "## Validation", "", bullets(checkpoint["validation"]), "", "## Decisions", "", bullets(checkpoint["decisions"]), "",
        "## Rejected Approaches", "", bullets(checkpoint["rejectedApproaches"]), "",
        *continuity_lines,
        "## Next Action", "", str(checkpoint["nextAction"]), "", f"Session: `{session_rel}`", "",
    ]
    write_text(context_root / handoff_rel, "\n".join(handoff_lines))
    manifest = {
        "schemaVersion": 1,
        "generatedAt": generated,
        "repository": repo_id,
        "branch": member_state["branch"],
        "commit": member_state["head"],
        "dirty": member_state["dirty"],
        "worktreeFingerprint": member_state["fingerprint"],
        "upstream": member_state["upstream"],
        "ahead": member_state["ahead"],
        "behind": member_state["behind"],
        "status": str(checkpoint["status"]),
        "scope": str(checkpoint["scope"]),
        "session": session_rel,
    }
    if continuity_meta is not None:
        manifest["continuity"] = continuity_meta
    write_json(context_root / manifest_rel, manifest)
    paths = list(dict.fromkeys([session_rel, state_rel, handoff_rel, manifest_rel, *continuity_paths]))
    run_git(context_root, ["add", "--", *paths])
    run_git(context_root, ["diff", "--cached", "--check"])
    staged = run_git(context_root, ["diff", "--cached", "--name-only"]).stdout.strip()
    if not staged:
        checkpoint_path.unlink(missing_ok=True)
        runtime_bundle(member_root, context_root, config, checkpoint_freshness)
        print("AI context checkpoint produced no changes.")
        return
    message = f"chore(context): checkpoint {repo_id} {slug(str(checkpoint['scope']))}"
    run_git(context_root, ["commit", "-m", message, "--", *paths])
    if not offline and bool((config.get("behavior") or {}).get("pushContext")):
        synchronize_checkpoint_push(context_root, expected_branch)
    checkpoint_path.unlink(missing_ok=True)
    runtime = runtime_bundle(member_root, context_root, config, checkpoint_freshness)
    print(f"AI context checkpoint committed: {runtime['context']['head']}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--action", required=True, choices=("start", "status", "checkpoint", "audit"))
    parser.add_argument("--repository-root", required=True)
    parser.add_argument("--offline", action="store_true")
    parser.add_argument("--config-path", required=True)
    args = parser.parse_args()
    member_root = Path(args.repository_root).resolve()
    config_path = Path(args.config_path).resolve()
    if not config_path.is_file():
        raise RuntimeError(f"Context config not found: {config_path}")
    config = json.loads(config_path.read_text(encoding="utf-8-sig"))
    if int(config.get("schemaVersion", 0)) != 1:
        raise RuntimeError("Unsupported context config schemaVersion.")
    cache_value = Path(str(config["context"]["cachePath"]))
    if cache_value.is_absolute():
        raise RuntimeError("AI context cachePath must be repository-relative.")
    context_root = (member_root / cache_value).resolve()
    try:
        relative_cache = context_root.relative_to(member_root)
    except ValueError as exc:
        raise RuntimeError("AI context cachePath must remain inside the member repository.") from exc
    if not relative_cache.parts:
        raise RuntimeError("AI context cachePath must remain inside the member repository.")
    if not (context_root / ".git").exists():
        raise RuntimeError("Central context cache is not a Git repository. Run the member context launcher first.")
    reject_reviewed_legacy_on_posix(context_root, str(config["repository"]))
    require_context_files(context_root)
    state = git_state(context_root)
    expected_branch = str(config["context"]["branch"])
    if state["branch"] != expected_branch:
        raise RuntimeError(f"Central context cache must be on branch '{expected_branch}'.")
    if state["dirty"]:
        freshness = "DIRTY_LOCAL_CONTEXT"
    elif args.offline:
        freshness = "OFFLINE_IMPORTED_CONTEXT"
    elif state["ahead"] is not None and state["behind"] is not None and state["ahead"] > 0 and state["behind"] > 0:
        freshness = "DIVERGED_LOCAL_CONTEXT"
    elif state["behind"] is not None and state["behind"] > 0:
        freshness = "STALE_LOCAL_CONTEXT"
    else:
        freshness = "CURRENT_OR_FETCHED"
    if args.action == "audit":
        print(json.dumps(audit_membership(member_root, context_root, config), ensure_ascii=False, indent=2))
        return 0
    if args.action == "status":
        membership = membership_info(context_root, config)
        print(json.dumps(runtime_bundle(member_root, context_root, config, freshness, membership), ensure_ascii=False, indent=2))
        return 0 if membership["projectMatches"] and membership["registered"] else 12
    if args.action == "start":
        membership = require_registered_member(context_root, config)
        runtime = runtime_bundle(member_root, context_root, config, freshness, membership)
        print(f"AI context ready: {runtime['repository']} @ {runtime['context']['head']} [{freshness}]")
        return 0
    do_checkpoint(member_root, context_root, config, expected_branch, offline=args.offline)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(str(exc), file=sys.stderr)
        raise SystemExit(12)
