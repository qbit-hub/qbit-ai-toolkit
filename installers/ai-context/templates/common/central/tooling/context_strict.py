"""Online Continuity v2 contract shared by the POSIX member and central engine.

No third party dependencies. Offline schema-1 portability stays in the legacy
engine. All published paths are derived here, never supplied by a Manifest or
retry journal. Git history, rather than runtime JSON, is publication authority.
"""
from __future__ import annotations

import contextlib
import datetime as dt
import hashlib
import json
import ntpath
import os
import posixpath
import re
import subprocess
import uuid
from pathlib import Path, PurePosixPath

ID = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,127}\Z")
SHA = re.compile(r"(?:[0-9a-f]{40}|[0-9a-f]{64})\Z")
TERMINAL = {"COMPLETED", "CANCELLED", "SUPERSEDED"}
MAX_AGE = 120
JOURNAL_KEYS = {"schemaVersion", "repository", "memberWorktree", "worktreeId", "contextRoot", "contextRemote", "contextBranch",
                "payloadSha256", "memberState", "baseCommit", "checkpointId", "generatedAt", "stage", "publicationCommit"}


def require(condition, message):
    if not condition:
        raise RuntimeError("CONTEXT_UNSYNCED: " + message)


def git(root, *args, check=True, raw=False):
    cp = subprocess.run(["git", "-c", "core.longpaths=true", "-C", str(root), *args], stdout=subprocess.PIPE,
                        stderr=subprocess.PIPE)
    require(not check or cp.returncode == 0, "Git operation failed; preserve local evidence")
    return cp.stdout if raw else cp.stdout.decode("utf-8", errors="strict").replace("\r\n", "\n").strip()


def exists_at(root, revision, relative):
    return bool(git(root, "ls-tree", revision, "--", relative))


def safe_path(root, relative):
    require(isinstance(relative, str) and relative and "\\" not in relative,
            "invalid managed path")
    parts = PurePosixPath(relative).parts
    require(not relative.startswith("/") and all(p not in {".", ".."} and ":" not in p for p in parts)
            and "/".join(parts) == relative, "unsafe managed path")
    current = Path(root)
    for part in parts:
        current = current / part
        require(not current.is_symlink(), "managed path traverses a link")
        if hasattr(os.path, "isjunction"):
            require(not os.path.isjunction(current), "managed path traverses a junction")
        # Windows junctions must also fail on Python 3.10, before isjunction.
        if current.exists() and os.name == "nt":
            require(not current.lstat().st_file_attributes & 0x400, "managed path traverses a reparse point")
    return current


def actual_root(root):
    path = Path(os.path.abspath(root))
    require(path == path.resolve(), "owning root traverses a link")
    require(normalize_root(str(path)) == normalize_root(git(path, "rev-parse", "--show-toplevel")),
            "must target the actual Git worktree root")
    return path


def normalize_root(value):
    require(isinstance(value, str) and bool(value), "owning root missing")
    if re.match(r"^[A-Za-z]:[/\\]", value) or value.startswith("\\\\"):
        return ntpath.normpath(value).replace("\\", "/").rstrip("/").lower()
    require(value.startswith("/"), "owning root must be absolute")
    return posixpath.normpath(value).rstrip("/") or "/"


def receipt_paths(repository, root):
    require(isinstance(repository, str) and ID.fullmatch(repository), "invalid repository id")
    worktree = "wt-" + hashlib.sha256(normalize_root(str(root)).encode()).hexdigest()[:32]
    return {"worktreeId": worktree,
            "manifest": f"manifests/worktrees/{repository}/{worktree}.json",
            "state": f"state/worktrees/{repository}/{worktree}.md",
            "handoff": f"handoffs/worktrees/{repository}/{worktree}.md"}


def source_state(root):
    visible_index(root)
    head = git(root, "rev-parse", "HEAD")
    require(SHA.fullmatch(head), "invalid source SHA")
    status = git(root, "status", "--porcelain=v1", "-z", "--untracked-files=all", raw=True).decode("utf-8")
    index = git(root, "ls-files", "--stage", "-z", raw=True).decode("utf-8")
    changed = git(root, "diff", "--name-only", "-z", "HEAD", "--", raw=True)
    untracked = git(root, "ls-files", "-z", "--others", "--exclude-standard", raw=True)
    # .NET Ordinal sorts UTF-16 code units and prefixes .NET string lengths.
    paths = sorted(set(p.decode("utf-8") for p in (changed + untracked).split(b"\0") if p),
                   key=lambda p: p.encode("utf-16-be"))
    parts = ["fingerprint-v2", "head=" + head, status, index]
    for relative in paths:
        path = safe_path(root, relative)
        require(not path.exists() or path.is_file(), "changed source is not a regular file")
        value = git(root, "hash-object", "--no-filters", "--", relative) if path.is_file() else "DELETED"
        require(value == "DELETED" or SHA.fullmatch(value), "source hash failed")
        parts.extend([relative, value])
    payload = "".join(str(len(p.encode("utf-16-le")) // 2) + ":" + p for p in parts)
    return {"head": head, "branch": git(root, "rev-parse", "--abbrev-ref", "HEAD"),
            "dirty": bool(status), "fingerprint": hashlib.sha256(payload.encode("utf-8")).hexdigest()}


def json_bytes(value):
    return (json.dumps(value, ensure_ascii=False, indent=2) + "\n").encode("utf-8")


def decode_json(data):
    def pairs(items):
        result = {}
        for key, value in items:
            require(key not in result, "duplicate JSON key")
            result[key] = value
        return result
    value = json.loads(data.decode("utf-8-sig"), object_pairs_hook=pairs)
    require(isinstance(value, dict), "JSON record must be an object")
    return value


def read_json(root, relative):
    return decode_json(safe_path(root, relative).read_bytes())


def committed(root, revision, relative):
    safe_path(root, relative)
    entry = git(root, "ls-tree", revision, "--", relative)
    require(entry.startswith(("100644 blob ", "100755 blob ")) and "\n" not in entry,
            "committed evidence missing or not a regular file")
    return git(root, "show", revision + ":" + relative, raw=True)


def blob(root, revision, relative):
    committed(root, revision, relative)
    return git(root, "rev-parse", revision + ":" + relative)


def fresh(timestamp, now=None):
    value = dt.datetime.fromisoformat(timestamp.replace("Z", "+00:00"))
    require(value.tzinfo is not None, "timestamp requires timezone")
    age = ((now or dt.datetime.now(dt.timezone.utc)) - value).total_seconds()
    require(0 <= age <= MAX_AGE * 60, "evidence stale or future dated")


def remote_identity(value, member):
    require(isinstance(value, str) and value and not value.startswith("-"), "invalid central remote")
    require(not re.match(r"^[A-Za-z][A-Za-z0-9+.-]*://[^/]*@", value), "remote embeds credentials")
    if re.match(r"^[A-Za-z][A-Za-z0-9+.-]*://", value) or re.match(r"^[^/\\\s]+@[^:]+:", value):
        return value.rstrip("/")
    path = Path(value)
    return str((member / path).resolve() if not path.is_absolute() else path.resolve())


def configuration(member, config):
    actual_root(member)
    require(type(config.get("schemaVersion")) is int and config["schemaVersion"] == 1,
            "unsupported config")
    for key in ("project", "repository"):
        require(isinstance(config.get(key), str) and ID.fullmatch(config[key]), "invalid config identity")
    context = config["context"]
    branch = context["branch"]
    require(isinstance(branch, str) and branch and not branch.startswith("-"), "invalid central branch")
    cp = subprocess.run(["git", "check-ref-format", "--branch", branch], cwd=member,
                        stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    require(cp.returncode == 0, "invalid central branch")
    cache = safe_path(member, context["cachePath"])
    require(context["cachePath"] not in {".git", ".ai-bridge"} and not context["cachePath"].startswith(".git/"), "unsafe cache path")
    safe_path(member, ".ai-bridge/context-runtime.json")
    return cache, remote_identity(context["remote"], member), branch


def remote_head(cache, remote, branch):
    ref = "refs/heads/" + branch
    lines = git(cache, "ls-remote", "--exit-code", "--", remote, ref).splitlines()
    require(len(lines) == 1 and lines[0].split()[-1] == ref and SHA.fullmatch(lines[0].split()[0]),
            "central remote head unavailable")
    return lines[0].split()[0]


def cache_health(member, cache, config, online=True):
    expected, remote, branch = configuration(member, config)
    require(cache == expected, "wrong context cache")
    actual_root(cache)
    visible_index(cache)
    require(git(cache, "rev-parse", "--abbrev-ref", "HEAD") == branch, "wrong central branch")
    require(remote_identity(git(cache, "remote", "get-url", "origin"), member) == remote, "wrong central origin")
    require(not git(cache, "status", "--porcelain", "--untracked-files=all"), "context cache dirty")
    head = git(cache, "rev-parse", "HEAD")
    if online:
        require(not safe_path(member, ".ai-bridge/context-offline.json").exists(), "offline context cannot pass strict online gate")
        require(head == remote_head(cache, remote, branch), "central published SHA differs from cache")
    return head


def visible_index(root):
    entries = git(root, "ls-files", "-v", "-z", raw=True).split(b"\0")
    require(all(not e or (not e[:1].islower() and e[:1] != b"S") for e in entries),
            "hidden assume-unchanged or skip-worktree index entries cannot prove current source")


def refresh(member, cache, config):
    _, remote, branch = configuration(member, config)
    require(not safe_path(member, ".ai-bridge/context-offline.json").exists(), "offline context requires reconnect")
    if not cache.exists():
        cache.parent.mkdir(parents=True, exist_ok=True)
        git(member, "clone", "--branch", branch, "--single-branch", "--", remote, str(cache))
    else:
        with cache_lock(cache):
            cache_health(member, cache, config, online=False)
            git(cache, "fetch", "origin", "refs/heads/" + branch)
            target = git(cache, "rev-parse", "FETCH_HEAD")
            require(ancestor(cache, "HEAD", target), "context divergence; automatic recovery refused")
            git(cache, "merge", "--ff-only", target)
    return cache_health(member, cache, config)


def ancestor(root, before, after):
    cp = subprocess.run(["git", "-C", str(root), "merge-base", "--is-ancestor", before, after],
                        stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    return cp.returncode == 0


def assert_runtime(member, cache, config, lifecycle):
    head = cache_health(member, cache, config)
    lifecycle.require_registered_member(cache, config)
    state = source_state(member)
    rt = read_json(member, ".ai-bridge/context-runtime.json")
    require(rt.get("schemaVersion") == 1 and rt.get("project") == config["project"] and
            rt.get("repository") == config["repository"], "runtime identity mismatch")
    fresh(rt["generatedAt"])
    for relative in (".ai-bridge/context-runtime.json", ".ai-bridge/context-runtime.md"):
        path = safe_path(member, relative)
        require(path.is_file() and path.stat().st_size > 0, "runtime missing")
        fresh(dt.datetime.fromtimestamp(path.stat().st_mtime, dt.timezone.utc).isoformat())
    require(normalize_root(rt["member"]["root"]) == normalize_root(str(member)) and
            all(rt["member"].get(k) == v for k, v in state.items()), "runtime source differs from current owning source")
    require(rt["context"]["head"] == head and rt["context"]["branch"] == config["context"]["branch"] and
            normalize_root(rt["context"]["root"]) == normalize_root(str(cache)) and
            rt["context"]["freshness"] == "CURRENT_OR_FETCHED" and rt["context"]["dirty"] is False and
            rt["membership"]["registered"] is True and rt["membership"]["projectMatches"] is True,
            "runtime central evidence unhealthy")
    return state


def owner(record, repository, member, paths):
    require(record.get("repository") == repository and
            normalize_root(record.get("memberWorktree")) == normalize_root(str(member)) and
            record.get("worktreeId") == paths["worktreeId"], "foreign Worktree owner")


def ledger(root, revision, repository):
    relative = f"validation/repositories/{repository}.json"
    value = decode_json(committed(root, revision, relative)) if exists_at(root, revision, relative) else {
        "schemaVersion": 2, "repository": repository, "entries": []}
    require(value.get("schemaVersion") == 2 and value.get("repository") == repository and
            isinstance(value.get("entries"), list), "invalid validation ledger")
    ids = []
    for entry in value["entries"]:
        require(isinstance(entry, dict) and isinstance(entry.get("id"), str) and ID.fullmatch(entry["id"]), "invalid ledger identity")
        ids.append(entry["id"])
    require(len(ids) == len(set(ids)), "duplicate immutable validation id")
    return value


def workstream_path(meta):
    require(ID.fullmatch(meta.get("workstreamId") or ""), "invalid workstream id")
    bucket = "archive" if meta.get("workstreamStatus") in TERMINAL else "active"
    relative = f"workstreams/{bucket}/{meta['workstreamId']}.json"
    require(meta.get("workstreamPath") == relative, "workstream canonical path mismatch")
    return relative


def previous(root, revision, repository, member, paths, review=None):
    manifest = None
    if exists_at(root, revision, paths["manifest"]):
        manifest = decode_json(committed(root, revision, paths["manifest"]))
        owner(manifest, repository, member, paths)
        require(manifest.get("receiptPaths") == {k: paths[k] for k in ("manifest", "state", "handoff")}, "receipt paths mismatch")
    else:
        for key in ("state", "handoff"):
            require(not exists_at(root, revision, paths[key]), "owning Manifest missing while continuity remains")
        for line in git(root, "ls-tree", "-r", "--name-only", revision, "--", "workstreams/active").splitlines():
            ws = decode_json(committed(root, revision, line))
            bound = ws.get("lastCheckpoint") or {}
            require(not (bound.get("repository") == repository and
                         (bound.get("worktreeId") == paths["worktreeId"] or
                          (bound.get("memberWorktree") and normalize_root(bound["memberWorktree"]) == normalize_root(str(member))))),
                    "owning Manifest missing while active Workstream remains")
        relative = f"manifests/repositories/{repository}.json"
        if exists_at(root, revision, relative):
            legacy = decode_json(committed(root, revision, relative))
            if legacy.get("memberWorktree"):
                if normalize_root(legacy["memberWorktree"]) == normalize_root(str(member)):
                    require("worktreeId" not in legacy and "receiptPaths" not in legacy, "summary cannot replace missing scoped receipt")
                    manifest = legacy
            elif (legacy.get("continuity") or {}).get("mode") == "tracked":
                require(review and review["enrollment"], "unbound legacy continuation requires reviewed reconciliation")
    if manifest is None or not (manifest.get("continuity") or {}).get("workstreamId"):
        return manifest, None
    meta = manifest["continuity"]
    ws = decode_json(committed(root, revision, workstream_path(meta)))
    require(ws.get("id") == meta["workstreamId"] and ws.get("status") == meta["workstreamStatus"], "previous Workstream mismatch")
    bound = ws.get("lastCheckpoint") or {}
    require(bound.get("repository") == repository and bound.get("session") == manifest.get("session"), "previous Workstream Session mismatch")
    if "memberWorktree" in bound:
        owner(bound, repository, member, paths)
    return manifest, ws


def transition(lifecycle, root, revision, checkpoint, repository, member, paths, review):
    old_manifest, old = previous(root, revision, repository, member, paths, review)
    current = checkpoint["continuity"]["workstream"]
    existing = ledger(root, revision, repository)
    ids = {entry["id"] for entry in existing["entries"]}
    require(not ids.intersection(e["id"] for e in checkpoint["continuity"]["validationLedger"]), "immutable validation id already published")
    if old_manifest is None and review:
        enrollment = review["enrollment"]
        require(enrollment and current and checkpoint["scope"] == enrollment["scope"] and
                current["id"] == enrollment["workstreamId"], "checkpoint differs from reviewed independent enrollment")
    if current:
        found = []
        for bucket in ("active", "archive"):
            relative = f"workstreams/{bucket}/{current['id']}.json"
            if not exists_at(root, revision, relative):
                continue
            ws = decode_json(committed(root, revision, relative))
            require(lifecycle.workstream_relative_path(ws) == relative, "global workstream path mismatch")
            bound = ws.get("lastCheckpoint") or {}
            require(bound.get("repository") == repository, "global Workstream owned by another repository")
            if "memberWorktree" in bound:
                owner(bound, repository, member, paths)
            else:
                require(old_manifest and bound.get("session") == old_manifest.get("session"), "global Workstream owner is unbound")
            found.append(ws)
        require(len(found) <= 1, "Workstream exists in active and archive")
        if found:
            require(not old or old["id"] == current["id"] or not lifecycle.unresolved_workstream(old), "cannot switch unresolved Workstream")
            old = found[0]
    if old:
        if not current or old["id"] != current["id"]:
            require(not lifecycle.unresolved_workstream(old), "cannot discard unresolved Workstream")
        else:
            require(old["status"] not in TERMINAL or old["status"] == current["status"], "terminal Workstream cannot reopen")
            items = {item["id"]: item for item in current["items"]}
            for item in old["items"]:
                require(item["id"] in items and items[item["id"]]["status"] in lifecycle.WORK_ITEM_TRANSITIONS[item["status"]],
                        "lost work item or invalid transition")
    return existing, old_manifest


def legacy_review(root, repository, member, config):
    """Validate the Windows independent-root enrollment contract, without migration."""
    relative = f"references/continuity-reconciliations/{repository}.json"
    path = safe_path(root, relative)
    if not exists_at(root, "HEAD", relative):
        require(not path.exists(), "reconciliation must be committed before enrollment")
        return None
    record = decode_json(committed(root, "HEAD", relative))
    def working_blob(path, expected):
        require(safe_path(root, path).is_file() and
                (git(root, "hash-object", "--no-filters", "--", path) == expected or
                 git(root, "hash-object", "--", path) == expected), "protected legacy working bytes changed")
    working_blob(relative, blob(root, "HEAD", relative))
    def keys(value, expected):
        require(isinstance(value, dict) and set(value) == set(expected.split()), "invalid reconciliation shape")
    keys(record, "schemaVersion kind project repository contextRemote baseCommit review legacy workstream enrollments")
    require(record["schemaVersion"] == 1 and record["kind"] == "independent-root-enrollment" and
            record["repository"] == repository and record["project"] == config["project"] and
            record["contextRemote"] == config["context"]["remote"] == git(root, "remote", "get-url", "origin"), "reconciliation identity mismatch")
    review = record["review"]
    keys(review, "decision authority provenance")
    require(review["decision"] == "preserve-unbound-and-enroll-independent-roots" and
            isinstance(review["authority"], str) and review["authority"].strip() and
            isinstance(review["provenance"], list) and review["provenance"] and
            all(isinstance(s, str) and s.strip() for s in review["provenance"]), "explicit review provenance missing")
    added = git(root, "log", "--reverse", "--format=%H", "--diff-filter=A", "HEAD", "--", relative).splitlines()
    require(len(added) == 1 and blob(root, added[0], relative) == blob(root, "HEAD", relative), "review record replaced")
    review_commit = added[0]
    require(SHA.fullmatch(record["baseCommit"]) and record["baseCommit"] != review_commit and ancestor(root, record["baseCommit"], review_commit), "invalid review base")
    protected = record["legacy"]
    expected = {f"{folder}/repositories/{repository}.{suffix}" for folder, suffix in (("manifests", "json"), ("state", "md"), ("handoffs", "md"))}
    require(isinstance(protected, list) and len(protected) == 3, "three protected legacy records required")
    require({entry.get("path") for entry in protected} == expected, "protected legacy paths mismatch")
    for entry in protected:
        keys(entry, "path blob")
        require(blob(root, record["baseCommit"], entry["path"]) == blob(root, "HEAD", entry["path"]) == entry["blob"], "protected legacy changed")
        working_blob(entry["path"], entry["blob"])
    legacy = decode_json(committed(root, "HEAD", f"manifests/repositories/{repository}.json"))
    require(legacy.get("repository") == repository and not {"memberWorktree", "worktreeId", "receiptPaths"}.intersection(legacy) and
            legacy["continuity"]["mode"] == "tracked", "legacy is not unbound tracked evidence")
    ws_ref = record["workstream"]
    keys(ws_ref, "id sourceCommit path blob disposition")
    require(ID.fullmatch(ws_ref["id"]) and ws_ref["id"] == legacy["continuity"]["workstreamId"] and
            ws_ref["path"] in {f"workstreams/{b}/{ws_ref['id']}.json" for b in ("active", "archive")} and
            SHA.fullmatch(ws_ref["sourceCommit"]) and ancestor(root, ws_ref["sourceCommit"], review_commit), "invalid legacy Workstream provenance")
    require(blob(root, ws_ref["sourceCommit"], ws_ref["path"]) == blob(root, "HEAD", ws_ref["path"]) == ws_ref["blob"], "legacy Workstream changed")
    working_blob(ws_ref["path"], ws_ref["blob"])
    ws = decode_json(committed(root, "HEAD", ws_ref["path"]))
    bound = ws["lastCheckpoint"]
    require(ws["id"] == ws_ref["id"] and not {"memberWorktree", "worktreeId"}.intersection(bound), "legacy Workstream already bound")
    if ws["status"] in TERMINAL:
        require(ws_ref["disposition"] == "historical-contributor-superseded" and ws_ref["path"].startswith("workstreams/archive/") and
                ws["cursor"]["currentItemId"] is None and all(i["status"] in TERMINAL for i in ws["items"]), "invalid historical supersession")
    else:
        require(ws_ref["disposition"] == "preserved-unbound-proposed" and ws["status"] == "PROPOSED" and
                ws_ref["path"].startswith("workstreams/active/") and bound["repository"] == repository and
                bound["session"] == legacy["session"] and all(i["status"] == "PENDING" for i in ws["items"]), "legacy unresolved work not eligible for independent enrollment")
    enrollments = record["enrollments"]
    require(isinstance(enrollments, list) and enrollments, "reviewed roots missing")
    ids, targets, enrollment = set(), set(), None
    for entry in enrollments:
        keys(entry, "memberWorktree worktreeId scope workstreamId")
        wid = receipt_paths(repository, entry["memberWorktree"])["worktreeId"]
        require(entry["worktreeId"] == wid and wid not in ids and entry["workstreamId"] not in targets and
                ID.fullmatch(entry["scope"]) and ID.fullmatch(entry["workstreamId"]) and entry["workstreamId"] != ws["id"], "invalid or duplicate enrolled scope")
        ids.add(wid)
        targets.add(entry["workstreamId"])
        if wid == receipt_paths(repository, member)["worktreeId"]:
            enrollment = entry
    proof = {"reviewPath": relative, "reviewBlob": blob(root, "HEAD", relative), "reviewCommit": review_commit,
             "baseCommit": record["baseCommit"], "files": sorted(protected, key=lambda e: e["path"]),
             "workstreamPath": ws_ref["path"], "workstreamBlob": ws_ref["blob"]}
    return {"proof": proof, "enrollment": enrollment, "workstream": ws}


def validate_payload(lifecycle, data, repository):
    checkpoint = decode_json(data)
    required = {"schemaVersion", "repository", "scope", "status", "objective", "confirmedFindings",
                "decisions", "rejectedApproaches", "validation", "openQuestions", "nextAction", "continuity"}
    require(set(checkpoint) == required and type(checkpoint["schemaVersion"]) is int and
            checkpoint["schemaVersion"] == 2, "strict checkpoint requires schema v2 and complete contract")
    for field in ("repository", "scope", "status", "objective", "nextAction"):
        require(isinstance(checkpoint[field], str) and checkpoint[field].strip(), "checkpoint string required")
    for field in ("confirmedFindings", "decisions", "rejectedApproaches", "validation", "openQuestions"):
        require(isinstance(checkpoint[field], list) and all(isinstance(v, str) for v in checkpoint[field]), "checkpoint requires string arrays")
    continuity = checkpoint["continuity"]
    require(isinstance(continuity, dict) and set(continuity) == {"mode", "workstream", "validationLedger"}, "invalid continuity shape")
    lifecycle.validate_checkpoint(checkpoint, repository)
    lifecycle.validate_no_secrets(checkpoint)
    def text(value, nullable=False):
        require((nullable and value is None) or isinstance(value, str), "contract string required")
    def strings(values):
        require(isinstance(values, list) and all(isinstance(v, str) and v for v in values) and
                len(values) == len(set(values)), "contract requires distinct nonempty strings")
    ws = continuity["workstream"]
    if ws:
        require(set(ws) == {"id", "title", "status", "objective", "repositories", "cursor", "items"}, "invalid Workstream shape")
        for key in ("id", "title", "status", "objective"):
            text(ws[key])
        for entry in ws["repositories"]:
            require(set(entry) == {"repository", "role"}, "invalid Workstream repository shape")
            text(entry["role"])
        require(set(ws["cursor"]) == {"currentItemId", "lastCompletedItemId", "phase", "lastCompletedAction", "nextAction"}, "invalid cursor shape")
        for key, value in ws["cursor"].items():
            text(value, nullable=key != "nextAction")
        for item in ws["items"]:
            require(set(item) == {"id", "title", "status", "priority", "scope", "acceptanceCriteria", "dependsOn", "blockedBy", "validationRequirements", "notes"}, "invalid work item shape")
            for key in ("id", "title", "status", "priority"):
                text(item[key])
            for key in ("scope", "acceptanceCriteria", "dependsOn", "blockedBy", "validationRequirements", "notes"):
                strings(item[key])
    for entry in continuity["validationLedger"]:
        require(set(entry) == {"id", "kind", "result", "repository", "scope", "summary", "timestamp", "command", "evidenceRefs"}, "invalid validation entry shape")
        for key in ("id", "kind", "result", "repository", "scope", "summary", "timestamp", "command"):
            text(entry[key], nullable=key == "command")
        strings(entry["evidenceRefs"])
        value = dt.datetime.fromisoformat(entry["timestamp"].replace("Z", "+00:00"))
        require(value.tzinfo is not None and value <= dt.datetime.now(dt.timezone.utc), "validation timestamp invalid or future")
    return checkpoint


def publication_files(lifecycle, member, cache, config, base, checkpoint, data, state, operation, generated):
    repository = config["repository"]
    paths = receipt_paths(repository, member)
    review = legacy_review(cache, repository, member, config)
    existing, old_manifest = transition(lifecycle, cache, base, checkpoint, repository, member, paths, review)
    timestamp = dt.datetime.fromisoformat(generated)
    session = f"sessions/{timestamp:%Y}/{timestamp:%m}/{timestamp:%Y-%m-%d-%H%M%S}-{repository}-{operation}.md"
    payload_path = f"checkpoints/worktrees/{repository}/{paths['worktreeId']}/{operation}.json"
    require(not exists_at(cache, base, session) and not exists_at(cache, base, payload_path), "historical Session or payload reuse")
    binding = {"repository": repository, "memberWorktree": str(member), "worktreeId": paths["worktreeId"],
               "branch": state["branch"], "head": state["head"], "dirty": state["dirty"],
               "fingerprint": state["fingerprint"], "session": session}
    for entry in checkpoint["continuity"]["validationLedger"]:
        stored = dict(entry)
        stored["recordedAt"] = generated
        stored["validFor"] = {k: binding[k] for k in ("head", "dirty", "fingerprint", "memberWorktree", "worktreeId")}
        existing["entries"].append(stored)
    existing["updatedAt"] = generated
    ledger_path = f"validation/repositories/{repository}.json"
    files = {session: (lifecycle.checkpoint_markdown(checkpoint, state, generated) +
                       f"\nCheckpoint ID: {operation}\nCheckpoint payload SHA256: {hashlib.sha256(data).hexdigest()}\n").encode(),
             payload_path: data, ledger_path: json_bytes(existing)}
    workstream = checkpoint["continuity"]["workstream"]
    ws_path = None
    if workstream is not None:
        ws_path = lifecycle.workstream_relative_path(workstream)
        stored = dict(workstream, schemaVersion=2, updatedAt=generated, lastCheckpoint=binding)
        files[ws_path] = json_bytes(stored)
        old_path = (old_manifest or {}).get("continuity", {}).get("workstreamPath")
        if old_path and old_path != ws_path and old_manifest["continuity"]["workstreamId"] == workstream["id"]:
            files[old_path] = None
    meta = {"schemaVersion": 2, "mode": checkpoint["continuity"]["mode"],
            "workstreamId": workstream["id"] if workstream else None,
            "workstreamStatus": workstream["status"] if workstream else None,
            "workstreamPath": ws_path,
            "currentItemId": workstream["cursor"]["currentItemId"] if workstream else None,
            "validationLedgerPath": ledger_path}
    manifest = {"schemaVersion": 1, "project": config["project"], "repository": repository,
                "generatedAt": generated, "memberWorktree": str(member), "worktreeId": paths["worktreeId"],
                "receiptPaths": {k: paths[k] for k in ("manifest", "state", "handoff")},
                "branch": state["branch"], "commit": state["head"], "dirty": state["dirty"],
                "worktreeFingerprint": state["fingerprint"], "checkpointId": operation,
                "checkpointPayloadSha256": hashlib.sha256(data).hexdigest(), "checkpointPayloadPath": payload_path,
                "scope": checkpoint["scope"], "status": checkpoint["status"], "session": session, "continuity": meta}
    if review:
        manifest["legacyPreservation"] = review["proof"]
    files[paths["manifest"]] = json_bytes(manifest)
    text = (f"# Worktree continuity — {repository}\n\nUpdated: {generated}\n"
            f"Worktree: {member}\nWorktree ID: {paths['worktreeId']}\n"
            f"Status: {checkpoint['status']}\nSession: {session}\n\n" +
            lifecycle.checkpoint_markdown(checkpoint, state, generated))
    files[paths["state"]] = text.encode()
    files[paths["handoff"]] = ("# Owning handoff\n\n" + text).encode()
    # Repository-level records are historical inputs. Strict POSIX never rewrites
    # them, including a sibling's Windows compatibility summary.
    return files


def verify_published(lifecycle, member, cache, config, state=None, attestation_only=False):
    current_state = state or (None if attestation_only else source_state(member))
    repository = config["repository"]
    paths = receipt_paths(repository, member)
    head = cache_health(member, cache, config)
    manifest = decode_json(committed(cache, head, paths["manifest"]))
    owner(manifest, repository, member, paths)
    require(manifest.get("schemaVersion") == 1 and manifest.get("project") == config["project"] and
            manifest.get("receiptPaths") == {k: paths[k] for k in ("manifest", "state", "handoff")}, "Manifest identity mismatch")
    published_state = {"head": manifest.get("commit"), "branch": manifest.get("branch"),
                       "dirty": manifest.get("dirty"), "fingerprint": manifest.get("worktreeFingerprint")}
    require(SHA.fullmatch(published_state["head"] or "") and isinstance(published_state["branch"], str) and
            bool(published_state["branch"]) and type(published_state["dirty"]) is bool and
            re.fullmatch(r"[0-9a-f]{64}", published_state["fingerprint"] or ""), "invalid published source identity")
    if attestation_only:
        # Start authenticates what was published without claiming that the
        # member still has that source state or that the receipt is recent.
        # Verify and Checkpoint retain both freshness gates below.
        generated = dt.datetime.fromisoformat(manifest["generatedAt"].replace("Z", "+00:00"))
        require(generated.tzinfo is not None and generated <= dt.datetime.now(dt.timezone.utc),
                "publication timestamp invalid or future dated")
    else:
        for field, source in (("commit", "head"), ("branch", "branch"), ("dirty", "dirty"), ("worktreeFingerprint", "fingerprint")):
            require(manifest.get(field) == current_state[source], "published Manifest source differs from current source")
        fresh(manifest["generatedAt"])
    require(re.fullmatch(r"[0-9a-f]{32}", manifest.get("checkpointId", "")) and
            re.fullmatch(r"[0-9a-f]{64}", manifest.get("checkpointPayloadSha256", "")), "missing checkpoint identity or digest")
    meta = manifest.get("continuity") or {}
    require(meta.get("schemaVersion") == 2 and meta.get("mode") in {"tracked", "snapshot"}, "Continuity v2 required")
    publication = git(cache, "log", "-1", "--format=%H", head, "--", paths["manifest"])
    parents = git(cache, "rev-list", "--parents", "-n", "1", publication).split()
    require(len(parents) == 2, "checkpoint requires one publication parent")
    base = parents[1]
    changed = set(git(cache, "diff-tree", "--no-renames", "--no-commit-id", "--name-only", "-r", publication).splitlines())
    session = manifest["session"]
    require(re.fullmatch(r"sessions/[0-9]{4}/[0-9]{2}/[A-Za-z0-9._-]+\.md", session), "invalid Session path")
    bound = [paths[k] for k in ("manifest", "state", "handoff")] + [session]
    require(set(bound).issubset(changed) and not exists_at(cache, base, session), "receipts and new Session must share publication")
    additions = git(cache, "log", "--reverse", "--format=%H", "--diff-filter=A", head, "--", session).splitlines()
    require(additions == [publication], "historical Session reused")
    review = legacy_review(cache, repository, member, config)
    require(manifest.get("legacyPreservation") == (review["proof"] if review else None), "legacy preservation proof mismatch")
    if review:
        proof = review["proof"]
        require(ancestor(cache, proof["reviewCommit"], publication), "review not prior to publication")
        for entry in proof["files"] + [{"path": proof["workstreamPath"], "blob": proof["workstreamBlob"]},
                                       {"path": proof["reviewPath"], "blob": proof["reviewBlob"]}]:
            require(blob(cache, publication, entry["path"]) == entry["blob"], "publication changed protected legacy")
    ledger_path = f"validation/repositories/{repository}.json"
    require(meta.get("validationLedgerPath") == ledger_path and ledger_path in changed, "validation ledger missing from publication")
    old = ledger(cache, base, repository)["entries"]
    published = ledger(cache, publication, repository)["entries"]
    current = ledger(cache, head, repository)["entries"]
    require(published[:len(old)] == old and current[:len(published)] == published and
            len(published) >= len(old) and len(current) >= len(published), "validation ledger prefix changed")
    session_text = committed(cache, publication, session).decode("utf-8-sig")
    require("Checkpoint ID: " + manifest["checkpointId"] in session_text and
            "Checkpoint payload SHA256: " + manifest["checkpointPayloadSha256"] in session_text,
            "Session payload identity mismatch")
    if meta["mode"] == "tracked":
        ws_path = workstream_path(meta)
        require(ws_path in changed, "Workstream not in publication")
        bound.append(ws_path)
        ws = decode_json(committed(cache, publication, ws_path))
        owner(ws.get("lastCheckpoint") or {}, repository, member, paths)
        require(ws["id"] == meta["workstreamId"] and ws["status"] == meta["workstreamStatus"] and
                ws["cursor"]["currentItemId"] == meta["currentItemId"] and
                ws["lastCheckpoint"]["session"] == session, "Workstream cursor or Session mismatch")
        lifecycle.validate_workstream(ws, repository, ws["cursor"]["nextAction"])
    else:
        require(all(meta.get(k) is None for k in ("workstreamId", "workstreamStatus", "workstreamPath", "currentItemId")), "snapshot contains active Workstream")
    payload_path = manifest.get("checkpointPayloadPath")
    expected_path = f"checkpoints/worktrees/{repository}/{paths['worktreeId']}/{manifest['checkpointId']}.json"
    require(payload_path == expected_path and payload_path in changed and not exists_at(cache, base, payload_path), "invalid checkpoint payload path or reuse")
    data = committed(cache, publication, payload_path)
    require(hashlib.sha256(data).hexdigest() == manifest["checkpointPayloadSha256"], "published payload digest mismatch")
    checkpoint = validate_payload(lifecycle, data, repository)
    expected = publication_files(lifecycle, member, cache, config, base, checkpoint, data, published_state,
                                 manifest["checkpointId"], manifest["generatedAt"])
    require(changed == set(expected), "publication includes unrelated or incomplete paths")
    for relative, content in expected.items():
        require((not exists_at(cache, publication, relative)) if content is None else
                committed(cache, publication, relative) == content, "publication bytes differ from payload contract")
    bound.append(payload_path)
    for relative in bound:
        require(blob(cache, publication, relative) == blob(cache, head, relative), "owning evidence changed after publication")
    for key in ("state", "handoff"):
        text = committed(cache, publication, paths[key]).decode("utf-8-sig")
        require(session in text, "owning record Session mismatch")
        if meta["mode"] == "tracked":
            require(ws["cursor"]["nextAction"] in text, "owning record cursor mismatch")
    pending = safe_path(member, ".ai-bridge/context-checkpoint.json")
    if pending.exists() and not attestation_only:
        require(hashlib.sha256(pending.read_bytes()).hexdigest() == manifest["checkpointPayloadSha256"], "unpublished decisions or payload remain pending")
    journal = safe_path(member, ".ai-bridge/context-checkpoint-pending.json")
    if journal.exists() and not attestation_only:
        value = decode_json(journal.read_bytes())
        require(value.get("stage") == "complete" and value.get("checkpointId") == manifest["checkpointId"] and
                value.get("payloadSha256") == manifest["checkpointPayloadSha256"] and value.get("publicationCommit") == publication,
                "incomplete or mismatched checkpoint journal")
        owner(value, repository, member, paths)
        require(set(value) == JOURNAL_KEYS and value["schemaVersion"] == 2 and value["contextRoot"] == str(cache) and
                value["contextRemote"] == remote_identity(config["context"]["remote"], member) and
                value["contextBranch"] == config["context"]["branch"] and value["baseCommit"] == base and
                value["generatedAt"] == manifest["generatedAt"] and value["memberState"] == current_state,
                "journal context or source mismatch")
    return manifest


@contextlib.contextmanager
def cache_lock(cache):
    git_dir = Path(git(cache, "rev-parse", "--absolute-git-dir"))
    path = safe_path(git_dir, "qbit-context-strict.lock")
    with path.open("a+b") as handle:
        handle.seek(0)
        if os.name == "nt":
            import msvcrt
            if path.stat().st_size == 0:
                handle.write(b"0")
                handle.flush()
            handle.seek(0)
            try:
                msvcrt.locking(handle.fileno(), msvcrt.LK_NBLCK, 1)
            except OSError as exc:
                raise RuntimeError("CONTEXT_UNSYNCED: concurrent context writer; retry with journal preserved") from exc
        else:
            import fcntl
            try:
                fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except OSError as exc:
                raise RuntimeError("CONTEXT_UNSYNCED: concurrent context writer; retry with journal preserved") from exc
        try:
            yield
        finally:
            handle.seek(0)
            if os.name == "nt":
                msvcrt.locking(handle.fileno(), msvcrt.LK_UNLCK, 1)
            else:
                fcntl.flock(handle, fcntl.LOCK_UN)


def atomic_write(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + ".tmp-" + uuid.uuid4().hex)
    try:
        with temporary.open("xb") as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def checkpoint(lifecycle, member, cache, config):
    require((config.get("behavior") or {}).get("pushContext") is True, "strict checkpoint requires online publication")
    repository = config["repository"]
    paths = receipt_paths(repository, member)
    payload = safe_path(member, ".ai-bridge/context-checkpoint.json")
    data = payload.read_bytes()
    cp = validate_payload(lifecycle, data, repository)
    journal_path = safe_path(member, ".ai-bridge/context-checkpoint-pending.json")
    with cache_lock(cache):
        state = source_state(member)
        _, remote, branch = configuration(member, config)
        actual_root(cache)
        visible_index(cache)
        require(git(cache, "rev-parse", "--abbrev-ref", "HEAD") == branch and
                remote_identity(git(cache, "remote", "get-url", "origin"), member) == remote,
                "retry cache origin or branch differs from config")
        require(not safe_path(member, ".ai-bridge/context-offline.json").exists(), "offline context cannot publish strict online checkpoint")
        lifecycle.require_registered_member(cache, config)
        if journal_path.exists():
            journal = decode_json(journal_path.read_bytes())
            if journal.get("stage") == "complete" and journal.get("payloadSha256") != hashlib.sha256(data).hexdigest():
                # A completed operation is replaceable only when its own
                # immutable Manifest still proves the exact journal identity.
                require(journal.get("publicationCommit") and ancestor(cache, journal["publicationCommit"], "HEAD"), "completed journal publication absent")
                # Validate the old journal identity below before replacing it.
                owner(journal, repository, member, paths)
                require(set(journal) == JOURNAL_KEYS and journal["schemaVersion"] == 2 and
                        journal.get("contextRemote") == remote and journal.get("contextBranch") == branch and
                        journal.get("contextRoot") == str(cache), "completed journal context mismatch")
                receipt = decode_json(committed(cache, journal["publicationCommit"], paths["manifest"]))
                owner(receipt, repository, member, paths)
                require(receipt["checkpointId"] == journal.get("checkpointId") and
                        receipt["checkpointPayloadSha256"] == journal.get("payloadSha256") and
                        receipt["generatedAt"] == journal.get("generatedAt") and
                        journal["memberState"] == {"head": receipt["commit"], "branch": receipt["branch"], "dirty": receipt["dirty"], "fingerprint": receipt["worktreeFingerprint"]} and
                        git(cache, "rev-parse", journal["publicationCommit"] + "^") == journal["baseCommit"] and
                        git(cache, "log", "-1", "--format=%H", "HEAD", "--", paths["manifest"]) == journal["publicationCommit"],
                        "completed journal differs from latest owning publication")
                journal = None
        else:
            journal = None
        if journal is None:
            assert_runtime(member, cache, config, lifecycle)
            base = git(cache, "rev-parse", "HEAD")
            journal = {"schemaVersion": 2, "repository": repository, "memberWorktree": str(member),
                       "worktreeId": paths["worktreeId"], "contextRoot": str(cache), "contextRemote": remote,
                       "contextBranch": branch, "payloadSha256": hashlib.sha256(data).hexdigest(),
                       "memberState": state, "baseCommit": base, "checkpointId": uuid.uuid4().hex,
                       "generatedAt": dt.datetime.now(dt.timezone.utc).isoformat(), "stage": "prepared", "publicationCommit": None}
        owner(journal, repository, member, paths)
        require(set(journal) == JOURNAL_KEYS and
                journal["schemaVersion"] == 2 and journal["contextRoot"] == str(cache) and journal["contextRemote"] == remote and
                journal["contextBranch"] == branch and journal["payloadSha256"] == hashlib.sha256(data).hexdigest() and
                journal["memberState"] == state and journal["stage"] in {"prepared", "committed", "complete"} and
                SHA.fullmatch(journal["baseCommit"]) and re.fullmatch(r"[0-9a-f]{32}", journal["checkpointId"]), "retry journal scope/source/payload mismatch")
        fresh(journal["generatedAt"])
        base = journal["baseCommit"]
        files = publication_files(lifecycle, member, cache, config, base, cp, data, state, journal["checkpointId"], journal["generatedAt"])
        current = git(cache, "rev-parse", "HEAD")
        if current == base:
            require(journal["stage"] == "prepared" and journal["publicationCommit"] is None and remote_head(cache, remote, branch) == base,
                    "remote advanced or journal publication missing; preserve for reconciliation")
            # Each pre-existing byte/index entry must be either its base or its
            # exact deterministic pending value. Never adopt unrelated changes.
            dirty = git(cache, "-c", "status.renames=false", "status", "--porcelain=v1", "-z", "--untracked-files=all", raw=True)
            for record in dirty.split(b"\0"):
                if record:
                    require(record[3:].decode("utf-8") in files and not record[:2].strip().startswith((b"R", b"C")), "unrelated dirty cache while retrying")
            for relative, content in files.items():
                path = safe_path(cache, relative)
                before = committed(cache, base, relative) if exists_at(cache, base, relative) else None
                actual = path.read_bytes() if path.exists() else None
                require(actual in (before, content) or
                        (actual is not None and before is not None and actual.replace(b"\r\n", b"\n") == before.replace(b"\r\n", b"\n")),
                        "pending checkpoint bytes were modified")
                indexed = git(cache, "ls-files", "--stage", "--", relative)
                if indexed:
                    require(indexed.startswith(("100644 ", "100755 ")), "pending index has nonregular entry")
                    staged = git(cache, "show", ":" + relative, raw=True)
                    # Git may normalize CRLF in text, while the operation writes LF.
                    require(staged.replace(b"\r\n", b"\n") in tuple(v.replace(b"\r\n", b"\n") for v in (before, content) if v is not None), "pending index changed")
            atomic_write(journal_path, json_bytes(journal))
            for relative, content in files.items():
                path = safe_path(cache, relative)
                if content is None:
                    path.unlink(missing_ok=True)
                else:
                    atomic_write(path, content)
            require(source_state(member) == state and payload.read_bytes() == data, "source or payload changed during capture")
            # Store the exact payload bytes even when the host enables autocrlf.
            add_paths = [relative for relative, content in sorted(files.items()) if content is not None or
                         git(cache, "ls-files", "--", relative)]
            git(cache, "-c", "core.autocrlf=false", "add", "--", *add_paths)
            git(cache, "diff", "--cached", "--check")
            staged_paths = set(git(cache, "diff", "--no-renames", "--cached", "--name-only").splitlines())
            require(staged_paths == set(files), "unrelated or incomplete index before checkpoint commit")
            require(source_state(member) == state and payload.read_bytes() == data, "source or payload changed before commit")
            git(cache, "commit", "-m", f"chore(context): checkpoint {repository} {journal['checkpointId']}")
            current = git(cache, "rev-parse", "HEAD")
        # A crash after commit but before journal update is recoverable only if
        # the single-parent exact operation is independently reconstructed.
        publication = journal["publicationCommit"] or current
        require(SHA.fullmatch(publication) and git(cache, "rev-list", "--parents", "-n", "1", publication).split() == [publication, base] and
                ancestor(cache, publication, current), "retry publication ancestry mismatch")
        changed = set(git(cache, "diff-tree", "--no-renames", "--no-commit-id", "--name-only", "-r", publication).splitlines())
        require(changed == set(files), "incomplete or unrelated checkpoint commit")
        for relative, content in files.items():
            require((not exists_at(cache, publication, relative)) if content is None else committed(cache, publication, relative) == content,
                    "retry publication content mismatch")
        require(not git(cache, "status", "--porcelain", "--untracked-files=all"), "dirty committed checkpoint")
        journal.update(stage="committed", publicationCommit=publication)
        atomic_write(journal_path, json_bytes(journal))
        live = remote_head(cache, remote, branch)
        if live == base:
            require(current == publication, "unrelated local commits cannot be pushed")
            git(cache, "push", "origin", f"{publication}:refs/heads/{branch}")
        elif live != current:
            # No merge/rebase/reset or retry that replaces somebody else's work.
            require(ancestor(cache, publication, live), "concurrent remote writer diverged; journal preserved")
            git(cache, "fetch", "origin", "refs/heads/" + branch)
            require(ancestor(cache, current, "FETCH_HEAD"), "remote divergence during retry")
            git(cache, "merge", "--ff-only", "FETCH_HEAD")
        journal["stage"] = "complete"
        atomic_write(journal_path, json_bytes(journal))
        require(source_state(member) == state and payload.read_bytes() == data, "source or payload changed during publication")
        verify_published(lifecycle, member, cache, config, state)
        payload.unlink()
        _write_runtime_locked(lifecycle, member, cache, config)


def write_runtime(lifecycle, member, cache, config):
    with cache_lock(cache):
        return _write_runtime_locked(lifecycle, member, cache, config)


def _write_runtime_locked(lifecycle, member, cache, config):
    cache_health(member, cache, config)
    paths = receipt_paths(config["repository"], member)
    review = legacy_review(cache, config["repository"], member, config)
    manifest_history = git(cache, "log", "--format=%H", "--diff-filter=AMRT", "HEAD", "--", paths["manifest"]).splitlines()
    strict_history = []
    for revision in manifest_history:
        if not exists_at(cache, revision, paths["manifest"]):
            continue
        prior = decode_json(committed(cache, revision, paths["manifest"]))
        if "checkpointPayloadPath" in prior:
            strict_history.append(revision)
    if exists_at(cache, "HEAD", paths["manifest"]):
        candidate = decode_json(committed(cache, "HEAD", paths["manifest"]))
        if "checkpointPayloadPath" in candidate:
            # A strict receipt remains strict for its entire history. Removing
            # fields cannot downgrade an unauthenticated publication to legacy.
            require("checkpointPayloadPath" in candidate, "strict checkpoint cannot be downgraded")
            verify_published(lifecycle, member, cache, config, attestation_only=True)
            attestation = "strict-v2-publication-integrity"
        else:
            require(not strict_history, "strict checkpoint cannot be downgraded")
            # Preserve supported historical scoped records as explicitly
            # unverified evidence; never present their cursor as trusted.
            attestation = "unverified-historical"
    else:
        require(not strict_history, "strict checkpoint cannot be downgraded")
        # Validate first-Start and reviewed unknown-owner compatibility rules
        # before the legacy renderer writes anything into the member bridge.
        previous(cache, "HEAD", config["repository"], member, paths, review)
        attestation = "no-strict-receipt"
    runtime = lifecycle.runtime_bundle(member, cache, config, "CURRENT_OR_FETCHED", strict=True)
    # runtime_bundle supplies presentation and registry information; the shared
    # source contract and owning receipt replace its legacy summary selection.
    runtime["member"].update(source_state(member))
    manifest, ws = previous(cache, "HEAD", config["repository"], member, paths, review)
    if attestation == "unverified-historical":
        meta = {"mode": "unverified-historical", "workstreamId": None, "workstreamStatus": None,
                "workstreamPath": None, "currentItemId": None}
    else:
        meta = dict((manifest or {}).get("continuity") or {"mode": "none"})
    meta.update(worktreeId=paths["worktreeId"], receiptPaths={k: paths[k] for k in ("manifest", "state", "handoff")})
    meta["attestation"] = attestation
    value = ledger(cache, "HEAD", config["repository"])
    fresh_rows = [e for e in value["entries"] if (e.get("validFor") or {}).get("fingerprint") == runtime["member"]["fingerprint"] and
                  (e.get("validFor") or {}).get("worktreeId") == paths["worktreeId"]]
    meta["validation"] = {"path": f"validation/repositories/{config['repository']}.json", "entries": len(value["entries"]),
                          "freshEntries": len(fresh_rows), "staleEntries": len(value["entries"]) - len(fresh_rows)}
    if review:
        meta["legacyEvidence"] = {"historicalOwnerRoot": "UNKNOWN", "receipt": False, "proof": review["proof"]}
    runtime["continuity"] = meta
    atomic_write(safe_path(member, ".ai-bridge/context-runtime.json"), json_bytes(runtime))
    # Remove repository-latest sections from the legacy renderer. They may be a
    # sibling's cursor. Only the independently selected owner is continuation.
    markdown = safe_path(member, ".ai-bridge/context-runtime.md")
    text = markdown.read_text(encoding="utf-8")
    headings = ("Latest Repository State", "Latest Repository Handoff", "Repository Provenance",
                "Active Workstream", "Validation Freshness")
    pattern = r"\n## (?:" + "|".join(re.escape(heading) for heading in headings) + r")\n"
    text = re.split(pattern, text, maxsplit=1)[0]
    for key in ("state", "handoff", "manifest"):
        if manifest and attestation != "unverified-historical":
            relative = paths[key] if exists_at(cache, "HEAD", paths["manifest"]) else f"{ {'manifest': 'manifests', 'state': 'state', 'handoff': 'handoffs'}[key]}/repositories/{config['repository']}.{ 'json' if key == 'manifest' else 'md'}"
            text += f"\n## Owning {key}\n\nSource: `{relative}`\n\n" + committed(cache, "HEAD", relative).decode("utf-8-sig")
    if ws and attestation != "unverified-historical":
        text += "\n## Owning Workstream\n\n" + lifecycle.render_workstream_markdown(ws)
    elif ws:
        text += "\n## Unverified historical Workstream metadata\n\n" + json.dumps({"id": ws.get("id"), "status": ws.get("status")}, ensure_ascii=False) + "\n"
    if review:
        text += "\n## Preserved unknown-owner historical evidence\n\n" + json.dumps(review, ensure_ascii=False, indent=2) + "\n"
    text += "\n## Owning validation freshness\n\n" + json.dumps(meta["validation"]) + "\n"
    atomic_write(markdown, text.encode("utf-8"))
    return runtime
