#!/usr/bin/env python3
from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import re
import shutil
import subprocess
import sys
import urllib.parse
from dataclasses import dataclass
from pathlib import Path
from typing import Any

INSTALLER_ID = "installer.ai-context"
INSTALLER_VERSION = "1.2.6"
STATE_PATH = ".qbit/toolkit/installed/ai-context.json"
BLOCK_BEGIN = "<!-- qbit-toolkit:ai-context:start -->"
BLOCK_END = "<!-- qbit-toolkit:ai-context:end -->"
GITIGNORE_BEGIN = "# qbit-toolkit:ai-context:start"
GITIGNORE_END = "# qbit-toolkit:ai-context:end"
ROOT = Path(__file__).resolve().parent.parent
TOOLKIT_ROOT = ROOT.parent.parent.resolve()


class InstallerError(Exception):
    def __init__(self, message: str, code: int = 12):
        super().__init__(message)
        self.code = code


@dataclass
class Block:
    begin: str
    end: str
    content: str


@dataclass
class Spec:
    files: dict[str, str]
    blocks: dict[str, Block]
    seeds: dict[str, str]
    legacy_blocks: dict[str, str]


@dataclass
class Action:
    kind: str
    action: str
    path: str


def run_git(root: Path, args: list[str], allow_failure: bool = False) -> subprocess.CompletedProcess[str]:
    cp = subprocess.run(["git", "-C", str(root), *args], text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    if cp.returncode and not allow_failure:
        raise InstallerError(f"Git command failed: git {' '.join(args)}")
    return cp


def canonical_target(value: str) -> Path:
    if not value:
        raise InstallerError("Target is required.", 2)
    target = Path(value).expanduser().resolve()
    if not target.is_dir():
        raise InstallerError(f"Target directory does not exist: {value}", 2)
    if target == Path(target.anchor):
        raise InstallerError("Refusing to target a filesystem root.", 2)
    if target == Path.home().resolve():
        raise InstallerError("Refusing to target the user home root.", 2)
    if target == TOOLKIT_ROOT:
        raise InstallerError("Refusing to install the AI Context asset into qbit-ai-toolkit itself.", 2)
    if shutil.which("git") is None:
        raise InstallerError("Git is required.", 2)
    inside = run_git(target, ["rev-parse", "--is-inside-work-tree"], True)
    if inside.returncode or inside.stdout.strip() != "true":
        raise InstallerError("Target must be a Git work tree.", 2)
    top = Path(run_git(target, ["rev-parse", "--show-toplevel"]).stdout.strip()).resolve()
    if top != target:
        raise InstallerError(f"Target must be the Git work tree root. Git root is: {top}", 2)
    return target


def safe_id(value: str, name: str) -> str:
    if not value or len(value) > 100 or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", value):
        raise InstallerError(f"{name} must match ^[A-Za-z0-9][A-Za-z0-9._-]*$ and be at most 100 characters.", 2)
    return value


def safe_display(value: str) -> str:
    if not value or len(value) > 160 or any(ord(c) < 32 or ord(c) == 127 for c in value):
        raise InstallerError("ProjectDisplayName is required and must be at most 160 characters without control characters.", 2)
    return value


def safe_branch(value: str) -> str:
    if not value or len(value) > 200 or value.startswith("-") or ".." in value or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._/-]*", value):
        raise InstallerError("ContextBranch is invalid.", 2)
    return value


def safe_remote(value: str) -> str:
    if not value or len(value) > 2048 or "\r" in value or "\n" in value:
        raise InstallerError("ContextRemote is invalid.", 2)
    if re.match(r"^[A-Za-z][A-Za-z0-9+.-]*://", value):
        parsed = urllib.parse.urlsplit(value)
        if parsed.scheme not in ("http", "https") or not parsed.netloc:
            raise InstallerError("ContextRemote URL must use http or https.", 2)
        if parsed.username is not None or parsed.password is not None:
            raise InstallerError("ContextRemote must not embed credentials.", 2)
    return value


def normalized(text: str) -> str:
    return text.replace("\r\n", "\n").replace("\r", "\n")


def sha_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def text_hash(text: str) -> str:
    return sha_bytes(normalized(text).encode("utf-8"))


def file_hash(path: Path) -> str:
    try:
        text = path.read_text(encoding="utf-8-sig")
    except UnicodeDecodeError as exc:
        raise InstallerError(f"Managed text file is not valid UTF-8: {path}", 5) from exc
    return text_hash(text)


def safe_path(root: Path, relative: str) -> Path:
    if not relative or relative.startswith("/") or "\\" in relative or any(part == ".." for part in relative.split("/")) or not re.fullmatch(r"[A-Za-z0-9._/-]+", relative):
        raise InstallerError(f"Unsafe relative path: {relative}", 5)
    current = root
    for segment in relative.split("/"):
        current = current / segment
        if current.is_symlink():
            raise InstallerError(f"Unsafe symlink target path: {relative}", 5)
    candidate = root.joinpath(*relative.split("/"))
    try:
        candidate.parent.resolve().relative_to(root.resolve())
    except ValueError as exc:
        raise InstallerError(f"Path escapes target root: {relative}", 5) from exc
    return candidate


def read_template(relative: str) -> str:
    path = ROOT / relative
    if not path.is_file():
        raise InstallerError(f"Installer template is missing: {relative}")
    return normalized(path.read_text(encoding="utf-8-sig"))


def render(relative: str, values: dict[str, str]) -> str:
    text = read_template(relative)
    for key, value in values.items():
        text = text.replace("{{" + key + "}}", value)
    match = re.search(r"\{\{[A-Z0-9_]+\}\}", text)
    if match:
        raise InstallerError(f"Unresolved template placeholder in {relative}: {match.group(0)}")
    return text if text.endswith("\n") else text + "\n"


def json_string(value: str) -> str:
    return json.dumps(value, ensure_ascii=False)[1:-1]


def values(project: str, display: str, repository: str, context_repo: str, remote: str, branch: str) -> dict[str, str]:
    return {
        "PROJECT_ID": project,
        "PROJECT_DISPLAY_NAME": display,
        "REPOSITORY_ID": repository,
        "CONTEXT_REPOSITORY_ID": context_repo,
        "CONTEXT_REMOTE": remote,
        "CONTEXT_BRANCH": branch,
        "PROJECT_ID_JSON": json_string(project),
        "REPOSITORY_ID_JSON": json_string(repository),
        "CONTEXT_REMOTE_JSON": json_string(remote),
        "CONTEXT_BRANCH_JSON": json_string(branch),
        "PROJECT_ID_YAML": "'" + project.replace("'", "''") + "'",
        "CONTEXT_REMOTE_YAML": "'" + remote.replace("'", "''") + "'",
        "BOOTSTRAP_DATE": dt.date.today().isoformat(),
    }


def new_spec(mode: str, v: dict[str, str]) -> Spec:
    files: dict[str, str] = {}
    blocks = {".gitignore": Block(GITIGNORE_BEGIN, GITIGNORE_END, ".qbit-toolkit/ai-context/backups/\n.qbit-toolkit/ai-context/transactions/\n")}
    seeds: dict[str, str] = {}
    legacy_blocks: dict[str, str] = {}
    if mode == "member":
        for rel in ("context.ps1", "context.sh", "context.py", "context-transfer.ps1"):
            files[f".ai/context/{rel}"] = read_template(f"templates/common/member/{rel}")
        files[".ai/context/config.json"] = render("templates/common/member/config.json.tpl", v)
        files[".ai/context/.gitignore"] = read_template("templates/common/member/context.gitignore")
        blocks["AGENTS.md"] = Block(BLOCK_BEGIN, BLOCK_END, render("templates/common/member/agents-block.md.tpl", v))
        blocks["AI_CONTEXT.md"] = Block(BLOCK_BEGIN, BLOCK_END, render("templates/common/member/AI_CONTEXT.md.tpl", v))
        blocks[".ai-bridge/.gitignore"] = Block(GITIGNORE_BEGIN, GITIGNORE_END, read_template("templates/common/member/bridge.gitignore"))
        seeds["AI_CONTEXT.md"] = render("templates/common/member/AI_CONTEXT-header.md.tpl", v)
        seeds[".ai-bridge/README.md"] = read_template("templates/common/member/bridge.README.md")
        legacy_blocks["AGENTS.md"] = render("templates/common/member/legacy-agents-section.md.tpl", v)
        legacy_blocks["AI_CONTEXT.md"] = render("templates/common/member/legacy-ai-context-tail.md.tpl", v)
        legacy_blocks[".ai-bridge/.gitignore"] = read_template("templates/common/member/bridge.gitignore")
    else:
        files["tooling/context-lifecycle.ps1"] = read_template("templates/common/central/tooling/context-lifecycle.ps1")
        files["tooling/context-continuity.ps1"] = read_template("templates/common/central/tooling/context-continuity.ps1")
        files["tooling/context-lifecycle.py"] = read_template("templates/common/central/tooling/context-lifecycle.py")
        for rel in ("context.ps1", "context.sh", "context.py", "context-transfer.ps1"):
            files[f"templates/member/{rel}"] = read_template(f"templates/common/member/{rel}")
        files["tests/context-lifecycle.tests.ps1"] = read_template("templates/common/central/tests/context-lifecycle.tests.ps1")
        files["tests/context-lifecycle.tests.sh"] = read_template("templates/common/central/tests/context-lifecycle.tests.sh")
        files["schemas/checkpoint.schema.json"] = read_template("templates/common/central/schemas/checkpoint.schema.json")
        files["docs/context-automation.md"] = render("templates/common/central/docs/context-automation.md.tpl", v)
        blocks["AGENTS.md"] = Block(BLOCK_BEGIN, BLOCK_END, render("templates/common/central/agents-block.md.tpl", v))
        seed_map = {
            "AI_CONTEXT.md": "templates/common/central/AI_CONTEXT.md.tpl",
            "README.md": "templates/common/central/README.md.tpl",
            "project/authority.md": "templates/common/central/project/authority.md.tpl",
            "project/overview.md": "templates/common/central/project/overview.md.tpl",
            "project/constraints.md": "templates/common/central/project/constraints.md.tpl",
            "project/terminology.md": "templates/common/central/project/terminology.md.tpl",
            "state/current.md": "templates/common/central/state/current.md.tpl",
            "state/next-action.md": "templates/common/central/state/next-action.md.tpl",
            "state/open-questions.md": "templates/common/central/state/open-questions.md.tpl",
            "state/pending-decisions.md": "templates/common/central/state/pending-decisions.md.tpl",
            "state/repositories/README.md": "templates/common/central/state/repositories/README.md.tpl",
            "handoffs/latest.md": "templates/common/central/handoffs/latest.md.tpl",
            "handoffs/repositories/README.md": "templates/common/central/handoffs/repositories/README.md.tpl",
            "manifests/repository-state.yaml": "templates/common/central/manifests/repository-state.yaml.tpl",
            "manifests/repositories/README.md": "templates/common/central/manifests/repositories/README.md.tpl",
            "repositories/repositories.yaml": "templates/common/central/repositories/repositories.yaml.tpl",
            "references/README.md": "templates/common/central/references/README.md.tpl",
            "sessions/README.md": "templates/common/central/sessions/README.md.tpl",
        }
        seeds = {dst: render(src, v) for dst, src in seed_map.items()}
    return Spec(files, blocks, seeds, legacy_blocks)


def read_doc(path: Path) -> tuple[str, str, bool, bytes] | None:
    if not path.is_file():
        return None
    raw = path.read_bytes()
    bom = raw.startswith(b"\xef\xbb\xbf")
    body = raw[3:] if bom else raw
    try:
        text = body.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise InstallerError(f"Managed text file is not valid UTF-8: {path}", 5) from exc
    return text, "\r\n" if "\r\n" in text else "\n", bom, raw


def write_doc(path: Path, text: str, newline: str = "\n", bom: bool = False) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    body = normalized(text).replace("\n", newline).encode("utf-8")
    path.write_bytes((b"\xef\xbb\xbf" if bom else b"") + body)


def write_utf8(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(normalized(text).encode("utf-8"))


def block_info(path: Path, block: Block) -> dict[str, Any]:
    doc = read_doc(path)
    if doc is None:
        return {"status": "absent-file"}
    text, _, _, _ = doc
    starts = [m.start() for m in re.finditer(re.escape(block.begin), text)]
    ends = [m.start() for m in re.finditer(re.escape(block.end), text)]
    if not starts and not ends:
        return {"status": "absent-block", "doc": doc}
    if len(starts) != 1 or len(ends) != 1 or ends[0] < starts[0]:
        return {"status": "malformed", "doc": doc}
    inner_start = starts[0] + len(block.begin)
    inner = text[inner_start:ends[0]].strip("\r\n")
    return {"status": "present", "hash": text_hash(inner), "doc": doc, "start": starts[0], "end": ends[0] + len(block.end)}


def set_block(path: Path, block: Block) -> None:
    info = block_info(path, block)
    if info["status"] == "malformed":
        raise InstallerError(f"Managed block markers are malformed in {path}", 4)
    if info.get("doc"):
        text, newline, bom, _ = info["doc"]
    else:
        text, newline, bom = "", "\n", False
    body = normalized(block.content).strip("\n").replace("\n", newline)
    rendered = block.begin + newline + body + newline + block.end
    if info["status"] == "present":
        text = text[: info["start"]] + rendered + text[info["end"] :]
    elif not text:
        text = rendered + newline
    else:
        if not text.endswith(("\n", "\r")):
            text += newline
        text += newline + rendered + newline
    write_doc(path, text, newline, bom)


def remove_block(path: Path, block: Block) -> None:
    info = block_info(path, block)
    if info["status"] in ("absent-file", "absent-block"):
        return
    if info["status"] != "present":
        raise InstallerError(f"Managed block markers are malformed in {path}", 4)
    text, newline, bom, _ = info["doc"]
    before = text[: info["start"]].rstrip("\r\n")
    after = text[info["end"] :].lstrip("\r\n")
    if not before and not after:
        path.unlink(missing_ok=True)
        return
    out = after if not before else before + newline if not after else before + newline + newline + after
    write_doc(path, out, newline, bom)


def read_state(root: Path) -> dict[str, Any] | None:
    path = safe_path(root, STATE_PATH)
    if not path.is_file():
        return None
    try:
        state = json.loads(path.read_text(encoding="utf-8-sig"))
    except Exception as exc:
        raise InstallerError("AI Context ownership state is invalid JSON.", 5) from exc
    required = ("schemaVersion", "installerId", "installerVersion", "mode", "projectId", "repositoryId", "contextRemote", "contextBranch", "managedFiles", "managedBlocks", "seededFiles", "stateFile")
    if any(key not in state for key in required):
        raise InstallerError("AI Context ownership state is incomplete.", 5)
    if state["schemaVersion"] != "1.0" or state["installerId"] != INSTALLER_ID or state["stateFile"] != STATE_PATH:
        raise InstallerError("AI Context ownership state identity is invalid.", 5)
    return state


def json_equivalent(path: Path, expected: str) -> bool:
    try:
        return json.loads(path.read_text(encoding="utf-8-sig")) == json.loads(expected)
    except Exception:
        return False


def legacy_trailing(path: Path, content: str) -> bool:
    if not path.is_file():
        return False
    return normalized(path.read_text(encoding="utf-8-sig")).rstrip("\r\n").endswith(normalized(content).strip("\n"))


def legacy_marker(path: Path, content: str) -> bool:
    if not path.is_file():
        return False
    first = normalized(content).split("\n", 1)[0]
    return bool(first and first in normalized(path.read_text(encoding="utf-8-sig")))


def remove_legacy(path: Path, content: str) -> None:
    doc = read_doc(path)
    if doc is None:
        raise InstallerError(f"Legacy migration target is missing: {path}", 4)
    text, newline, bom, _ = doc
    current = normalized(text).rstrip("\r\n")
    needle = normalized(content).strip("\n")
    if not current.endswith(needle):
        raise InstallerError(f"Legacy migration content no longer matches: {path}", 4)
    prefix = current[: -len(needle)].rstrip("\r\n") if needle else current
    write_doc(path, "" if not prefix else prefix + "\n", newline, bom)


def make_plan(root: Path, spec: Spec, state: dict[str, Any] | None, owned_modified: str, adopt: bool, migrate: bool) -> tuple[list[Action], list[str]]:
    actions: list[Action] = []
    conflicts: list[str] = []
    old_files = {item["path"]: item["sha256"] for item in (state or {}).get("managedFiles", [])}
    old_blocks = {item["path"]: item for item in (state or {}).get("managedBlocks", [])}
    for rel in sorted(spec.files):
        path = safe_path(root, rel)
        expected = sha_bytes(normalized(spec.files[rel]).encode("utf-8"))
        exists = path.is_file()
        current = file_hash(path) if exists else None
        if rel not in old_files:
            if not exists:
                actions.append(Action("file", "create", rel))
            elif current == expected and adopt:
                actions.append(Action("file", "adopt", rel))
            elif current == expected:
                conflicts.append(f"Matching unowned file requires --adopt-matching: {rel}")
            elif migrate and rel == ".ai/context/config.json" and json_equivalent(path, spec.files[rel]):
                actions.append(Action("file", "migrate", rel))
            else:
                conflicts.append(f"Unowned file conflict at {rel}")
            continue
        if not exists:
            actions.append(Action("file", "create", rel))
        elif current == expected:
            pass
        elif current == old_files[rel]:
            actions.append(Action("file", "update", rel))
        elif owned_modified == "replace":
            actions.append(Action("file", "replace", rel))
        else:
            conflicts.append(f"Installer-owned file was modified: {rel}")
    for rel in sorted(spec.blocks):
        path = safe_path(root, rel)
        block = spec.blocks[rel]
        expected = text_hash(block.content.strip("\r\n"))
        info = block_info(path, block)
        if rel not in old_blocks:
            if info["status"] in ("absent-file", "absent-block"):
                if rel in spec.legacy_blocks and legacy_trailing(path, spec.legacy_blocks[rel]):
                    if migrate:
                        actions.append(Action("block", "migrate", rel))
                    else:
                        conflicts.append(f"Recognized legacy content requires --migrate-legacy: {rel}")
                elif rel in spec.legacy_blocks and legacy_marker(path, spec.legacy_blocks[rel]):
                    conflicts.append(f"Legacy-like content is modified or unrecognized at {rel}")
                else:
                    actions.append(Action("block", "create", rel))
            elif info["status"] == "present" and info["hash"] == expected and adopt:
                actions.append(Action("block", "adopt", rel))
            elif info["status"] == "present" and info["hash"] == expected:
                conflicts.append(f"Matching unowned managed block requires --adopt-matching: {rel}")
            elif info["status"] == "malformed":
                conflicts.append(f"Managed block markers are malformed in {rel}")
            else:
                conflicts.append(f"Unowned managed block conflict at {rel}")
            continue
        old = old_blocks[rel]
        if info["status"] != "present":
            conflicts.append(f"Previously managed block is missing or malformed in {rel}")
        elif info["hash"] == expected:
            pass
        elif info["hash"] == old["sha256"]:
            actions.append(Action("block", "update", rel))
        elif owned_modified == "replace":
            actions.append(Action("block", "replace", rel))
        else:
            conflicts.append(f"Installer-owned managed block was modified: {rel}")
    for rel in sorted(spec.seeds):
        if not safe_path(root, rel).exists():
            actions.append(Action("seed", "create", rel))
    return actions, conflicts


def backup(root: Path, rel: str) -> None:
    source = safe_path(root, rel)
    if not source.is_file():
        return
    stamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
    dest = safe_path(root, f".qbit-toolkit/ai-context/backups/{stamp}/{rel}")
    dest.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, dest)


def make_state(mode: str, project: str, repository: str, remote: str, branch: str, spec: Spec, seeded: list[str]) -> dict[str, Any]:
    return {
        "schemaVersion": "1.0",
        "installerId": INSTALLER_ID,
        "installerVersion": INSTALLER_VERSION,
        "mode": mode,
        "projectId": project,
        "repositoryId": repository,
        "contextRemote": remote,
        "contextBranch": branch,
        "installedAtUtc": dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "managedFiles": [{"path": path, "sha256": sha_bytes(normalized(spec.files[path]).encode("utf-8"))} for path in sorted(spec.files)],
        "managedBlocks": [{"path": path, "begin": spec.blocks[path].begin, "end": spec.blocks[path].end, "sha256": text_hash(spec.blocks[path].content.strip("\r\n"))} for path in sorted(spec.blocks)],
        "seededFiles": sorted(set(seeded)),
        "stateFile": STATE_PATH,
    }


def mutate(root: Path, spec: Spec, state: dict[str, Any] | None, actions: list[Action], mode: str, project: str, repository: str, remote: str, branch: str) -> None:
    snapshots: dict[Path, bytes | None] = {}
    seeded = list((state or {}).get("seededFiles", []))

    def snapshot(path: Path) -> None:
        if path not in snapshots:
            snapshots[path] = path.read_bytes() if path.is_file() else None

    try:
        priority = {"seed": 0, "file": 1, "block": 2}
        for item in sorted(actions, key=lambda action: (priority[action.kind], action.path)):
            path = safe_path(root, item.path)
            if item.kind == "file":
                if item.action == "adopt":
                    continue
                snapshot(path)
                if item.action == "replace":
                    backup(root, item.path)
                write_utf8(path, spec.files[item.path])
            elif item.kind == "block":
                if item.action == "adopt":
                    continue
                snapshot(path)
                if item.action == "replace":
                    backup(root, item.path)
                if item.action == "migrate":
                    remove_legacy(path, spec.legacy_blocks[item.path])
                set_block(path, spec.blocks[item.path])
            else:
                snapshot(path)
                write_utf8(path, spec.seeds[item.path])
                if item.path not in seeded:
                    seeded.append(item.path)
        state_path = safe_path(root, STATE_PATH)
        snapshot(state_path)
        state_path.parent.mkdir(parents=True, exist_ok=True)
        state_path.write_bytes((json.dumps(make_state(mode, project, repository, remote, branch, spec, seeded), ensure_ascii=False, indent=2) + "\n").encode("utf-8"))
    except Exception:
        for path, data in reversed(list(snapshots.items())):
            if data is None:
                if path.is_file():
                    path.unlink()
            else:
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(data)
        raise


def verify(root: Path) -> dict[str, Any]:
    state = read_state(root)
    if state is None:
        raise InstallerError("AI Context ownership state is missing.", 5)
    errors: list[str] = []
    for item in state["managedFiles"]:
        path = safe_path(root, item["path"])
        if not path.is_file():
            errors.append(f"Missing managed file: {item['path']}")
        elif file_hash(path) != item["sha256"]:
            errors.append(f"Managed file hash mismatch: {item['path']}")
    for item in state["managedBlocks"]:
        path = safe_path(root, item["path"])
        info = block_info(path, Block(item["begin"], item["end"], ""))
        if info["status"] != "present":
            errors.append(f"Missing or malformed managed block: {item['path']}")
        elif info["hash"] != item["sha256"]:
            errors.append(f"Managed block hash mismatch: {item['path']}")
    if errors:
        raise InstallerError("AI Context verification failed:\n - " + "\n - ".join(errors), 5)
    return state


def uninstall(root: Path, owned_modified: str) -> None:
    state = read_state(root)
    if state is None:
        raise InstallerError("AI Context ownership state is missing.", 5)
    conflicts: list[str] = []
    for item in state["managedFiles"]:
        path = safe_path(root, item["path"])
        if path.is_file() and file_hash(path) != item["sha256"] and owned_modified != "replace":
            conflicts.append(f"Modified managed file: {item['path']}")
    for item in state["managedBlocks"]:
        path = safe_path(root, item["path"])
        info = block_info(path, Block(item["begin"], item["end"], ""))
        if info["status"] == "present" and info["hash"] != item["sha256"] and owned_modified != "replace":
            conflicts.append(f"Modified managed block: {item['path']}")
        elif info["status"] == "malformed" and owned_modified != "replace":
            conflicts.append(f"Malformed managed block: {item['path']}")
    if conflicts:
        raise InstallerError("Uninstall conflicts:\n - " + "\n - ".join(conflicts), 4)
    snapshots: dict[Path, bytes | None] = {}

    def snapshot(path: Path) -> None:
        if path not in snapshots:
            snapshots[path] = path.read_bytes() if path.is_file() else None

    try:
        for item in state["managedFiles"]:
            path = safe_path(root, item["path"])
            if path.is_file():
                snapshot(path)
                if file_hash(path) != item["sha256"]:
                    backup(root, item["path"])
                path.unlink()
        for item in state["managedBlocks"]:
            path = safe_path(root, item["path"])
            if path.is_file():
                snapshot(path)
                info = block_info(path, Block(item["begin"], item["end"], ""))
                if info["status"] == "present" and info["hash"] != item["sha256"]:
                    backup(root, item["path"])
                remove_block(path, Block(item["begin"], item["end"], ""))
        state_path = safe_path(root, STATE_PATH)
        snapshot(state_path)
        state_path.unlink(missing_ok=True)
    except Exception:
        for path, data in reversed(list(snapshots.items())):
            if data is None:
                if path.is_file():
                    path.unlink()
            else:
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(data)
        raise


def emit(payload: dict[str, Any], output_format: str) -> None:
    if output_format == "json":
        print(json.dumps(payload, ensure_ascii=False, separators=(",", ":")))
        return
    if payload["success"]:
        print(f"AI Context {payload['operation']} succeeded for {payload['target']}.")
        for item in payload["actions"]:
            print("  " + item)
        for warning in payload["warnings"]:
            print("WARNING: " + warning, file=sys.stderr)
    else:
        print(payload.get("error", "AI Context operation failed."), file=sys.stderr)
        for conflict in payload["conflicts"]:
            print("  " + conflict, file=sys.stderr)


def payload(operation: str, target: str, mode: str, success: bool, code: int, actions: list[str] | None = None, conflicts: list[str] | None = None, warnings: list[str] | None = None, error: str | None = None) -> dict[str, Any]:
    result: dict[str, Any] = {
        "schema_version": "1.0",
        "installer_version": INSTALLER_VERSION,
        "operation": operation,
        "target": target,
        "mode": mode,
        "success": success,
        "exit_code": code,
        "actions": actions or [],
        "conflicts": conflicts or [],
        "warnings": warnings or [],
    }
    if error is not None:
        result["error"] = error
    return result


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    parser.add_argument("--operation", choices=("plan", "install", "update", "verify", "uninstall"), default="install")
    parser.add_argument("--target", required=True)
    parser.add_argument("--mode", choices=("member", "central"))
    parser.add_argument("--project-id", default="")
    parser.add_argument("--project-display-name", default="")
    parser.add_argument("--repository-id", default="")
    parser.add_argument("--context-repository-id", default="")
    parser.add_argument("--context-remote", default="")
    parser.add_argument("--context-branch", default="")
    parser.add_argument("--owned-modified", choices=("fail", "replace"), default="fail")
    parser.add_argument("--adopt-matching", action="store_true")
    parser.add_argument("--migrate-legacy", action="store_true")
    parser.add_argument("--format", choices=("text", "json"), default="text")
    return parser


def main() -> int:
    ns = build_parser().parse_args()
    try:
        root = canonical_target(ns.target)
        state = read_state(root)
        if ns.operation == "verify":
            verified = verify(root)
            out = payload("verify", str(root), verified["mode"], True, 0)
        elif ns.operation == "uninstall":
            uninstall(root, ns.owned_modified)
            out = payload("uninstall", str(root), state["mode"] if state else "", True, 0, ["remove managed AI Context assets"], warnings=["Project-owned seed files are intentionally preserved."])
        else:
            if ns.operation == "update" and state is None:
                raise InstallerError("Update requires an existing AI Context ownership state.", 5)
            mode = ns.mode or (state["mode"] if state else "member")
            if state and mode != state["mode"]:
                raise InstallerError("Mode is immutable for an existing AI Context installation.", 2)
            project = safe_id(ns.project_id or (state["projectId"] if state else ""), "ProjectId")
            if state and project != state["projectId"]:
                raise InstallerError("ProjectId is immutable for an existing AI Context installation.", 2)
            repository = safe_id(ns.repository_id or (state["repositoryId"] if state else root.name), "RepositoryId")
            if state and repository != state["repositoryId"]:
                raise InstallerError("RepositoryId is immutable for an existing AI Context installation.", 2)
            display = safe_display(ns.project_display_name or project)
            branch = safe_branch(ns.context_branch or (state["contextBranch"] if state else "main"))
            remote = ns.context_remote or (state["contextRemote"] if state else "")
            if not remote and mode == "central":
                origin = run_git(root, ["remote", "get-url", "origin"], True)
                if origin.returncode == 0:
                    remote = origin.stdout.strip()
            remote = safe_remote(remote)
            context_repo = ns.context_repository_id
            if not context_repo:
                match = re.search(r"/([^/]+?)(?:\.git)?/?$", remote)
                context_repo = match.group(1) if match else (repository if mode == "central" else f"{project}-ai-context")
            context_repo = safe_id(context_repo, "ContextRepositoryId")
            spec = new_spec(mode, values(project, display, repository, context_repo, remote, branch))
            actions, conflicts = make_plan(root, spec, state, ns.owned_modified, ns.adopt_matching, ns.migrate_legacy)
            action_text = [f"{item.action} {item.path}" for item in actions]
            if ns.operation == "plan":
                code = 0 if not conflicts else 4
                out = payload("plan", str(root), mode, code == 0, code, action_text, conflicts)
                emit(out, ns.format)
                return code
            if conflicts:
                raise InstallerError("Conflicts: " + "; ".join(conflicts), 4)
            needs_refresh = state is not None and state.get("installerVersion") != INSTALLER_VERSION
            if state is not None and not actions and not needs_refresh:
                verify(root)
            else:
                mutate(root, spec, state, actions, mode, project, repository, remote, branch)
                verify(root)
            out = payload(ns.operation, str(root), mode, True, 0, action_text)
        emit(out, ns.format)
        return 0
    except InstallerError as exc:
        out = payload(ns.operation, ns.target, ns.mode or "", False, exc.code, conflicts=[str(exc)] if exc.code == 4 else [], error=str(exc))
        emit(out, ns.format)
        return exc.code
    except Exception as exc:
        out = payload(ns.operation, ns.target, ns.mode or "", False, 12, error=str(exc))
        emit(out, ns.format)
        return 12


if __name__ == "__main__":
    raise SystemExit(main())
