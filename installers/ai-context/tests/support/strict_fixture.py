"""Disposable installed repositories; no network or host configuration writes."""
from __future__ import annotations

import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

INSTALLER = Path(__file__).resolve().parents[2]
TOOLKIT = INSTALLER.parents[1]
TEMP = TOOLKIT / ".ai-bridge" / "strict-tests"
TEMP.mkdir(parents=True, exist_ok=True)
sys.dont_write_bytecode = True


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


strict = load("context_strict", INSTALLER / "templates/common/central/tooling/context_strict.py")
lifecycle = load("strict_test_lifecycle", INSTALLER / "templates/common/central/tooling/context-lifecycle.py")


class Fixture:
    def __init__(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="installed-", dir=TEMP)
        self.root = Path(self.temporary.name).resolve()
        self.remote = self.root / "context.git"
        self.central = self.root / "central"
        self.member = self.root / "member"
        self.git(self.root, "init", "--bare", str(self.remote))
        for path in (self.central, self.member):
            path.mkdir()
            self.git(path, "init", "-b", "main")
            self.git(path, "config", "user.name", "Fixture")
            self.git(path, "config", "user.email", "fixture@example.invalid")
            self.git(path, "config", "core.autocrlf", "false")
            (path / "README.md").write_text("# Fixture\n", encoding="utf-8")
            self.commit(path, "bootstrap")
        self.git(self.central, "remote", "add", "origin", str(self.remote))
        self.install(self.central, "central", "demo-context")
        (self.central / "repositories/repositories.yaml").write_text(
            "project: demo\nrepositories:\n  demo-member:\n    path: ../member\n    role: member\n", encoding="utf-8")
        self.commit(self.central, "central installer")
        self.git(self.central, "push", "-u", "origin", "main")
        self.install(self.member, "member", "demo-member")
        self.commit(self.member, "member installer")
        self.config = strict.read_json(self.member, ".ai/context/config.json")
        self.cache = self.member / self.config["context"]["cachePath"]
        self.start()
        self.git(self.cache, "config", "user.name", "Fixture")
        self.git(self.cache, "config", "user.email", "fixture@example.invalid")
        self.git(self.cache, "config", "core.autocrlf", "false")

    @staticmethod
    def run(args, check=True, **kwargs):
        env = dict(os.environ, GIT_TERMINAL_PROMPT="0", GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM="1",
                   PYTHONDONTWRITEBYTECODE="1")
        cp = subprocess.run([str(v) for v in args], stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            text=True, encoding="utf-8", env=env, **kwargs)
        if check and cp.returncode:
            raise AssertionError(f"fixture command exit {cp.returncode}: {cp.stdout}")
        return cp

    def git(self, root, *args, check=True):
        return self.run(["git", "-c", "core.longpaths=true", "-C", root, *args], check=check).stdout.strip()

    def commit(self, root, message):
        self.git(root, "add", ".")
        self.git(root, "commit", "-m", message)

    def install(self, target, mode, repository, operation="install", *extra):
        return self.run([sys.executable, "-B", INSTALLER / "lib/installer.py", "--operation", operation,
                         "--mode", mode, "--target", target, "--project-id", "demo", "--repository-id", repository,
                         "--context-remote", self.remote, "--context-branch", "main", *extra])

    def launcher(self, action, member=None, check=True):
        member = member or self.member
        return self.run([sys.executable, "-B", member / ".ai/context/context.py", action], check=check)

    def start(self, member=None):
        return self.launcher("start", member)

    def checkpoint(self, payload=None):
        self.write_payload(payload or self.payload())
        return self.launcher("checkpoint")

    def write_payload(self, payload):
        strict.atomic_write(self.member / ".ai-bridge/context-checkpoint.json", strict.json_bytes(payload))

    @staticmethod
    def payload(tracked=True, workstream="strict-feature", validation_id="validation-1"):
        import datetime as dt
        cp = {"schemaVersion": 2, "repository": "demo-member", "scope": "strict-posix", "status": "IN_PROGRESS" if tracked else "VALIDATED",
              "objective": "Prove installed strict publication", "confirmedFindings": ["local Git fixture"],
              "decisions": ["preserve ownership"], "rejectedApproaches": [], "validation": ["automated fixture"],
              "openQuestions": [], "nextAction": "Continue at exact cursor.",
              "continuity": {"mode": "tracked" if tracked else "snapshot", "workstream": None,
                             "validationLedger": [{"id": validation_id, "kind": "integration", "result": "PASS", "repository": "demo-member",
                                                   "scope": "strict-posix", "summary": "Executed local fixture", "timestamp": dt.datetime.now(dt.timezone.utc).isoformat(),
                                                   "command": "local fixture", "evidenceRefs": []}]}}
        if tracked:
            cp["continuity"]["workstream"] = {
                "id": workstream, "title": "Strict fixture", "status": "IN_PROGRESS", "objective": "Preserve continuation",
                "repositories": [{"repository": "demo-member", "role": "owner"}],
                "cursor": {"currentItemId": "TASK-1", "lastCompletedItemId": None, "phase": "implementation",
                           "lastCompletedAction": "Validated fixture", "nextAction": cp["nextAction"]},
                "items": [{"id": "TASK-1", "title": "Implement", "status": "IN_PROGRESS", "priority": "HIGH", "scope": ["fixture"],
                           "acceptanceCriteria": ["strict verify passes"], "dependsOn": [], "blockedBy": [],
                           "validationRequirements": ["real Git publication"], "notes": []}]}
        return cp

    def manifest(self, member=None):
        member = member or self.member
        config = strict.read_json(member, ".ai/context/config.json")
        cache = member / config["context"]["cachePath"]
        paths = strict.receipt_paths("demo-member", member)
        return strict.read_json(cache, paths["manifest"])

    def publish_tamper(self, relative, mutate):
        path = self.cache / relative
        value = json.loads(path.read_text(encoding="utf-8"))
        mutate(value)
        strict.atomic_write(path, strict.json_bytes(value))
        self.commit(self.cache, "negative evidence fixture")
        self.git(self.cache, "push", "origin", "main")
        self.launcher("start", check=False)

    def sibling(self):
        sibling = self.root / "sibling"
        self.git(self.member, "worktree", "add", "-b", "sibling", str(sibling))
        return sibling

    def close(self):
        self.temporary.cleanup()
