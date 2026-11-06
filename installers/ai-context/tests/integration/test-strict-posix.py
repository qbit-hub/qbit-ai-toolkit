#!/usr/bin/env python3
"""Real installed launcher, local Git remotes, negative provenance and recovery."""
import contextlib
import datetime as dt
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "support"))
from strict_fixture import Fixture, strict, lifecycle


class InstalledStrictTests(unittest.TestCase):
    def setUp(self):
        self.f = Fixture()
        self.addCleanup(self.f.close)

    def reject(self, action="verify", member=None):
        result = self.f.launcher(action, member=member, check=False)
        self.assertEqual(result.returncode, 3, result.stdout)
        self.assertIn("CONTEXT_UNSYNCED:", result.stdout)
        return result.stdout

    def runtime(self):
        return strict.read_json(self.f.member, ".ai-bridge/context-runtime.json")

    def test_installed_checkpoint_verify_and_independent_clone(self):
        self.f.checkpoint()
        self.assertIn("CONTEXT_SYNC_OK", self.f.launcher("verify").stdout)
        manifest = self.f.manifest()
        clone = self.f.root / "independent"
        self.f.git(self.f.root, "clone", "--branch", "main", str(self.f.remote), str(clone))
        paths = strict.receipt_paths("demo-member", self.f.member)
        self.assertEqual(strict.read_json(clone, paths["manifest"]), manifest)
        self.assertEqual(strict.read_json(clone, manifest["continuity"]["workstreamPath"])["cursor"]["currentItemId"], "TASK-1")
        self.assertFalse((self.f.member / ".ai-bridge/context-checkpoint.json").exists())
        self.assertIn("Owning Workstream", (self.f.member / ".ai-bridge/context-runtime.md").read_text(encoding="utf-8"))
        self.assertEqual(self.runtime()["continuity"]["attestation"], "strict-v2-publication-integrity")

    @unittest.skipIf(os.name == "nt", "POSIX cache locking regression")
    def test_start_and_checkpoint_reject_lock_after_refresh_without_runtime_pollution(self):
        # Pause the installed Start after its cache refresh has released the
        # lock, then acquire the real OS lock in another process. This targets
        # the former refresh-to-render gap, rather than the earlier refresh
        # lock acquisition.
        cache = self.f.cache
        bridge = self.f.member / ".ai-bridge"
        runtime_paths = (bridge / "context-runtime.json", bridge / "context-runtime.md")
        runtime_before = tuple(path.read_bytes() for path in runtime_paths)
        cache_head = self.f.git(cache, "rev-parse", "HEAD")
        remote_head = self.f.git(self.f.root, "ls-remote", str(self.f.remote), "refs/heads/main").split()[0]
        payload_path = bridge / "context-checkpoint.json"
        payload = self.f.payload(validation_id="locked-checkpoint")
        self.f.write_payload(payload)
        payload_before = payload_path.read_bytes()
        control = self.f.root / "lock-control"
        control.mkdir()
        start_release_marker = control / "release-start"
        holder_release_marker = control / "release-lock-holder"
        refresh_marker = control / "refresh-complete"
        holder_marker = control / "cache-lock-held"
        real_git = shutil.which("git")
        self.assertIsNotNone(real_git)
        wrapper_dir = control / "bin"
        wrapper_dir.mkdir()
        wrapper = wrapper_dir / "git"
        wrapper.write_text(
            "#!" + sys.executable + "\n"
            "import os, sys\n"
            f"real = {real_git!r}\n"
            f"cache = {str(cache)!r}\n"
            f"release = {str(start_release_marker)!r}\n"
            f"done = {str(refresh_marker)!r}\n"
            "args = sys.argv[1:]\n"
            "if '-C' in args and args[args.index('-C') + 1] == cache and 'ls-remote' in args and not os.path.exists(done):\n"
            "    open(done, 'x').close()\n"
            "    import time\n"
            "    deadline = time.monotonic() + 30\n"
            "    while not os.path.exists(release):\n"
            "        if time.monotonic() >= deadline: raise SystemExit('timed out waiting for test release')\n"
            "        time.sleep(0.01)\n"
            "os.execv(real, [real, *args])\n",
            encoding="utf-8",
        )
        wrapper.chmod(0o755)
        env = dict(os.environ, PATH=str(wrapper_dir) + os.pathsep + os.environ.get("PATH", ""),
                   GIT_TERMINAL_PROMPT="0", GIT_CONFIG_GLOBAL=os.devnull,
                   GIT_CONFIG_NOSYSTEM="1", PYTHONDONTWRITEBYTECODE="1")
        start = subprocess.Popen(
            [sys.executable, "-B", str(self.f.member / ".ai/context/context.py"), "start"],
            cwd=self.f.member, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            text=True, encoding="utf-8",
        )
        holder = None
        def wait_for(path, process, label):
            deadline = time.monotonic() + 20
            while time.monotonic() < deadline:
                if path.exists():
                    return
                if process.poll() is not None:
                    output, _ = process.communicate()
                    self.fail(f"{label} exited before signaling ({process.returncode}): {output}")
                time.sleep(0.01)
            self.fail(f"timed out waiting for {label} marker")

        try:
            wait_for(refresh_marker, start, "Start refresh")
            holder_code = (
                "import pathlib, sys, time\n"
                "sys.path.insert(0, sys.argv[1])\n"
                "import context_strict\n"
                "with context_strict.cache_lock(pathlib.Path(sys.argv[2])):\n"
                "    pathlib.Path(sys.argv[3]).touch()\n"
                "    deadline = time.monotonic() + 30\n"
                "    while not pathlib.Path(sys.argv[4]).exists():\n"
                "        if time.monotonic() >= deadline: raise SystemExit('timed out waiting for test release')\n"
                "        time.sleep(0.01)\n"
            )
            holder = subprocess.Popen(
                [sys.executable, "-B", "-c", holder_code,
                 str(self.f.cache / "tooling"), str(cache), str(holder_marker), str(holder_release_marker)],
                cwd=self.f.member, env=env, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT, text=True, encoding="utf-8",
            )
            wait_for(holder_marker, holder, "cache lock holder")
            self.assertIsNone(holder.poll(), "cache lock holder exited before Start resumed")
            start_release_marker.touch()
            start_output, _ = start.communicate(timeout=20)
            self.assertEqual(start.returncode, 3, start_output)
            self.assertIn("CONTEXT_UNSYNCED:", start_output)
            self.assertIsNone(holder.poll(), "cache lock holder exited before failed Start was observed")
            self.assertEqual(tuple(path.read_bytes() for path in runtime_paths), runtime_before)

            self.assertIsNone(holder.poll(), "cache lock holder exited before Checkpoint began")
            checkpoint = self.f.launcher("checkpoint", check=False)
            self.assertEqual(checkpoint.returncode, 3, checkpoint.stdout)
            self.assertIn("CONTEXT_UNSYNCED:", checkpoint.stdout)
            self.assertIsNone(holder.poll(), "cache lock holder exited before failed Checkpoint was observed")
            self.assertEqual(payload_path.read_bytes(), payload_before)
            self.assertFalse((bridge / "context-checkpoint-pending.json").exists())
            self.assertEqual(self.f.git(cache, "rev-parse", "HEAD"), cache_head)
            self.assertEqual(self.f.git(self.f.root, "ls-remote", str(self.f.remote), "refs/heads/main").split()[0], remote_head)
            self.assertEqual(tuple(path.read_bytes() for path in runtime_paths), runtime_before)
            holder_release_marker.touch()
            holder_output, _ = holder.communicate(timeout=20)
            self.assertEqual(holder.returncode, 0, holder_output)
        finally:
            # Always unblock fixture children before stopping them, then drain
            # and close their pipes even when an assertion or timeout failed.
            start_release_marker.touch()
            holder_release_marker.touch()
            for child in (start, holder):
                if child is None:
                    continue
                try:
                    child.communicate(timeout=5)
                except subprocess.TimeoutExpired:
                    child.terminate()
                    try:
                        child.communicate(timeout=5)
                    except subprocess.TimeoutExpired:
                        child.kill()
                        child.communicate(timeout=5)
                finally:
                    for pipe in (child.stdout, child.stderr):
                        if pipe is not None and not pipe.closed:
                            pipe.close()

        # A real checkpoint followed by Start and Verify proves the checkpoint
        # path invokes the already-locked renderer without recursively locking.
        self.f.launcher("checkpoint")
        self.f.launcher("start")
        self.assertIn("CONTEXT_SYNC_OK", self.f.launcher("verify").stdout)

    def test_start_attests_each_published_receipt_component_before_rendering(self):
        for kind in ("state", "handoff", "manifest", "workstream", "payload", "ledger", "session"):
            with self.subTest(component=kind):
                f = Fixture()
                self.addCleanup(f.close)
                f.checkpoint()
                manifest = f.manifest()
                paths = strict.receipt_paths("demo-member", f.member)
                runtime_paths = (f.member / ".ai-bridge/context-runtime.json", f.member / ".ai-bridge/context-runtime.md")
                before = tuple(path.read_bytes() for path in runtime_paths)
                marker = "FORGED-START-" + kind.upper()
                if kind in {"state", "handoff"}:
                    target = f.cache / paths[kind]
                    target.write_bytes(target.read_bytes() + ("\n" + marker + "\n").encode())
                elif kind == "manifest":
                    value = strict.read_json(f.cache, paths["manifest"])
                    value["scope"] = marker
                    strict.atomic_write(f.cache / paths["manifest"], strict.json_bytes(value))
                elif kind == "workstream":
                    relative = manifest["continuity"]["workstreamPath"]
                    value = strict.read_json(f.cache, relative)
                    value["cursor"]["nextAction"] = marker
                    strict.atomic_write(f.cache / relative, strict.json_bytes(value))
                elif kind == "payload":
                    relative = manifest["checkpointPayloadPath"]
                    value = strict.read_json(f.cache, relative)
                    value["objective"] = marker
                    strict.atomic_write(f.cache / relative, strict.json_bytes(value))
                elif kind == "ledger":
                    relative = "validation/repositories/demo-member.json"
                    value = strict.read_json(f.cache, relative)
                    value["entries"][0]["summary"] = marker
                    strict.atomic_write(f.cache / relative, strict.json_bytes(value))
                else:
                    target = f.cache / manifest["session"]
                    target.write_bytes(target.read_bytes() + ("\n" + marker + "\n").encode())
                f.commit(f.cache, "tamper published " + kind)
                f.git(f.cache, "push", "origin", "main")
                result = f.launcher("start", check=False)
                self.assertEqual(result.returncode, 3, result.stdout)
                self.assertIn("CONTEXT_UNSYNCED:", result.stdout)
                self.assertEqual(tuple(path.read_bytes() for path in runtime_paths), before)
                self.assertNotIn(marker.encode(), b"".join(path.read_bytes() for path in runtime_paths))

    def test_start_rejects_removal_of_strict_payload_path_as_downgrade(self):
        self.f.checkpoint()
        names = ("context-runtime.json", "context-runtime.md")
        before = tuple((self.f.member / ".ai-bridge" / name).read_bytes() for name in names)
        manifest_path = strict.receipt_paths("demo-member", self.f.member)["manifest"]
        manifest = self.f.manifest()
        manifest.pop("checkpointPayloadPath")
        strict.atomic_write(self.f.cache / manifest_path, strict.json_bytes(manifest))
        self.f.commit(self.f.cache, "attempt strict receipt downgrade")
        self.f.git(self.f.cache, "push", "origin", "main")
        result = self.f.launcher("start", check=False)
        self.assertEqual(result.returncode, 3, result.stdout)
        self.assertIn("strict checkpoint cannot be downgraded", result.stdout)
        self.assertEqual(tuple((self.f.member / ".ai-bridge" / name).read_bytes() for name in names), before)

    def test_start_attests_old_publication_without_claiming_current_verification(self):
        f = self.f
        checkpoint = f.payload()
        data = strict.json_bytes(checkpoint)
        state = strict.source_state(f.member)
        base = f.git(f.cache, "rev-parse", "HEAD")
        generated = (dt.datetime.now(dt.timezone.utc) - dt.timedelta(hours=3)).isoformat()
        files = strict.publication_files(lifecycle, f.member, f.cache, f.config, base, checkpoint, data,
                                         state, "c" * 32, generated)
        for relative, content in files.items():
            strict.atomic_write(f.cache / relative, content)
        f.commit(f.cache, "valid historical strict checkpoint")
        f.git(f.cache, "push", "origin", "main")
        result = f.launcher("start", check=False)
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertEqual(self.runtime()["continuity"]["attestation"], "strict-v2-publication-integrity")
        self.assertIn("Owning Workstream", (f.member / ".ai-bridge/context-runtime.md").read_text(encoding="utf-8"))
        self.assertIn("stale or future", self.reject("verify"))

    def test_start_accepts_pending_decisions_without_claiming_verification(self):
        self.f.checkpoint()
        self.f.write_payload(self.f.payload(validation_id="pending-next-decision"))
        result = self.f.launcher("start", check=False)
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertEqual(self.runtime()["continuity"]["attestation"], "strict-v2-publication-integrity")
        self.assertIn("unpublished decisions or payload remain pending", self.reject("verify"))

    def test_start_without_receipt_bootstraps_without_owning_continuation(self):
        self.assertEqual(self.runtime()["continuity"]["attestation"], "no-strict-receipt")
        self.assertEqual(self.runtime()["continuity"]["mode"], "none")
        self.assertNotIn("Owning Workstream", (self.f.member / ".ai-bridge/context-runtime.md").read_text(encoding="utf-8"))

    def test_status_is_read_only_health_and_not_milestone(self):
        bridge = self.f.member / ".ai-bridge"
        before = {p.name: (p.read_bytes(), p.stat().st_mtime_ns) for p in bridge.iterdir() if p.is_file()}
        self.assertIn("CONTEXT_STATUS_OK", self.f.launcher("status").stdout)
        after = {p.name: (p.read_bytes(), p.stat().st_mtime_ns) for p in bridge.iterdir() if p.is_file()}
        self.assertEqual(before, after)
        self.reject("verify")

    def test_installed_launchers_ignore_malformed_caller_git_directory(self):
        self.f.checkpoint()
        caller = self.f.root / "unrelated-caller"
        caller.mkdir()
        pointer = caller / ".git"
        pointer.write_bytes(b"gitdir: missing\n")
        ambient = self.f.run(["git", "check-ref-format", "--branch", "main"], cwd=caller, check=False)
        self.assertNotEqual(ambient.returncode, 0, ambient.stdout)
        launcher = self.f.member / ".ai/context/context.py"
        for action, marker in (("status", "CONTEXT_STATUS_OK"), ("start", "CONTEXT_SYNC_OK"), ("verify", "CONTEXT_SYNC_OK")):
            with self.subTest(action=action):
                result = self.f.run([sys.executable, "-B", launcher, action], cwd=caller, check=False)
                self.assertEqual(result.returncode, 0, result.stdout)
                self.assertIn(marker, result.stdout)
        self.assertEqual(pointer.read_bytes(), b"gitdir: missing\n")
        self.assertEqual(sorted(p.name for p in caller.iterdir()), [".git"])

    def test_invalid_central_branch_rejected_independently_of_caller_git(self):
        config_path = self.f.member / ".ai/context/config.json"
        config = strict.read_json(self.f.member, ".ai/context/config.json")
        config["context"]["branch"] = "invalid..branch"
        strict.atomic_write(config_path, strict.json_bytes(config))
        caller = self.f.root / "unrelated-caller"
        caller.mkdir()
        (caller / ".git").write_bytes(b"gitdir: missing\n")
        launcher = self.f.member / ".ai/context/context.py"
        # The healthy member CWD proves rejection comes from branch syntax,
        # rather than the unrelated malformed Git pointer.
        for cwd in (self.f.member, caller):
            for action in ("status", "start", "verify"):
                with self.subTest(cwd=cwd.name, action=action):
                    result = self.f.run([sys.executable, "-B", launcher, action], cwd=cwd, check=False)
                    self.assertEqual(result.returncode, 3, result.stdout)
                    self.assertIn("CONTEXT_UNSYNCED: invalid central branch", result.stdout)

    def test_shared_module_managed_hash_repair_uninstall_and_modes(self):
        f = self.f
        installer = Path(__file__).resolve().parents[2] / "lib/installer.py"
        module = f.member / ".ai/context/context_strict.py"
        original = module.read_bytes()
        state = strict.read_json(f.member, ".qbit/toolkit/installed/ai-context.json")
        self.assertIn(".ai/context/context_strict.py", [v["path"] for v in state["managedFiles"]])
        module.write_bytes(original + b"\n# modified owned asset\n")
        args = [sys.executable, "-B", installer, "--target", f.member]
        self.assertEqual(f.run([*args, "--operation", "verify"], check=False).returncode, 5)
        f.install(f.member, "member", "demo-member", "update", "--owned-modified", "replace")
        self.assertEqual(module.read_bytes(), original)
        if os.name != "nt":
            launcher = f.member / ".ai/context/context.sh"
            self.assertEqual(launcher.stat().st_mode & 0o111, 0o111)
            launcher.chmod(0o644)
            self.assertEqual(f.run([*args, "--operation", "verify"], check=False).returncode, 5)
            f.install(f.member, "member", "demo-member", "update")
            self.assertEqual(launcher.stat().st_mode & 0o111, 0o111)
        f.run([*args, "--operation", "verify"])
        readme = (f.member / "README.md").read_bytes()
        f.run([*args, "--operation", "uninstall"])
        self.assertFalse(module.exists())
        self.assertEqual((f.member / "README.md").read_bytes(), readme)

    def test_siblings_cannot_borrow_receipts_or_take_workstream(self):
        self.f.checkpoint()
        original = self.f.manifest()
        sibling = self.f.sibling()
        self.f.start(sibling)
        self.reject(member=sibling)
        config = strict.read_json(sibling, ".ai/context/config.json")
        cache = sibling / config["context"]["cachePath"]
        self.f.git(cache, "config", "user.name", "Fixture")
        self.f.git(cache, "config", "user.email", "fixture@example.invalid")
        self.f.git(cache, "config", "core.autocrlf", "false")
        cp = self.f.payload(validation_id="sibling-takeover")
        strict.atomic_write(sibling / ".ai-bridge/context-checkpoint.json", strict.json_bytes(cp))
        self.assertIn("foreign Worktree", self.reject("checkpoint", sibling))
        self.assertEqual(self.f.manifest(), original)
        cp["continuity"]["workstream"]["id"] = "sibling-feature"
        strict.atomic_write(sibling / ".ai-bridge/context-checkpoint.json", strict.json_bytes(cp))
        self.f.launcher("checkpoint", member=sibling)
        self.f.start()
        self.f.launcher("verify")
        self.assertEqual(self.f.manifest(), original)
        self.assertNotIn("sibling-feature", (self.f.member / ".ai-bridge/context-runtime.md").read_text(encoding="utf-8"))

    def test_tampered_manifest_owner_rejected(self):
        self.f.checkpoint()
        paths = strict.receipt_paths("demo-member", self.f.member)
        self.f.publish_tamper(paths["manifest"], lambda m: m.update(memberWorktree=str(self.f.root / "foreign")))
        self.reject()

    def test_missing_or_empty_payload_path_rejected(self):
        self.f.checkpoint()
        self.assertIn("CONTEXT_SYNC_OK", self.f.launcher("verify").stdout)
        paths = strict.receipt_paths("demo-member", self.f.member)
        # These subsequent publications model a remote writer, not a pending
        # local operation. Retire the fixture's completed local journal.
        (self.f.member / ".ai-bridge/context-checkpoint-pending.json").unlink()
        for index, missing in enumerate((True, False), 1):
            with self.subTest(payload_path="omitted" if missing else "empty"):
                # A manifest-only follow-up commit would fail the earlier
                # receipt/Session checks and never exercise payload validation.
                checkpoint = self.f.payload(validation_id=f"payload-path-{index}")
                data = strict.json_bytes(checkpoint)
                base = self.f.git(self.f.cache, "rev-parse", "HEAD")
                files = strict.publication_files(
                    lifecycle, self.f.member, self.f.cache, self.f.config, base, checkpoint, data,
                    strict.source_state(self.f.member), f"{index:032x}", dt.datetime.now(dt.timezone.utc).isoformat())
                for relative, content in files.items():
                    strict.atomic_write(self.f.cache / relative, content)
                def mutate(manifest):
                    if missing:
                        manifest.pop("checkpointPayloadPath")
                    else:
                        manifest["checkpointPayloadPath"] = ""
                self.f.publish_tamper(paths["manifest"], mutate)
                with self.assertRaisesRegex(RuntimeError, "invalid checkpoint payload path or reuse"):
                    strict.verify_published(lifecycle, self.f.member, self.f.cache, self.f.config)

    def test_payload_tamper_and_pending_decisions_rejected(self):
        self.f.checkpoint()
        cp = self.f.payload(validation_id="unpublished")
        self.f.write_payload(cp)
        self.assertIn("unpublished", self.reject())
        (self.f.member / ".ai-bridge/context-checkpoint.json").unlink()
        manifest = self.f.manifest()
        self.f.publish_tamper(manifest["checkpointPayloadPath"], lambda v: v.update(objective="tampered"))
        self.reject()

    def test_published_stale_future_and_wrong_sha_rejected(self):
        self.f.checkpoint()
        paths = strict.receipt_paths("demo-member", self.f.member)
        for generated in ((dt.datetime.now(dt.timezone.utc) - dt.timedelta(minutes=121)).isoformat(),
                          (dt.datetime.now(dt.timezone.utc) + dt.timedelta(minutes=1)).isoformat()):
            self.f.publish_tamper(paths["manifest"], lambda v: v.update(generatedAt=generated))
            result = self.f.launcher("start", check=False)
            self.assertEqual(result.returncode, 3, result.stdout)
            self.assertIn("CONTEXT_UNSYNCED:", result.stdout)
        self.f.publish_tamper(paths["manifest"], lambda v: v.update(generatedAt=dt.datetime.now(dt.timezone.utc).isoformat(), commit="0" * 40))
        result = self.f.launcher("start", check=False)
        self.assertEqual(result.returncode, 3, result.stdout)
        self.assertIn("CONTEXT_UNSYNCED:", result.stdout)

    def test_current_source_drift_after_published_checkpoint_rejected(self):
        self.f.checkpoint()
        (self.f.member / "README.md").write_text("changed current source\n", encoding="utf-8")
        started = self.f.start()
        self.assertIn("CONTEXT_SYNC_OK", started.stdout)
        self.assertTrue(self.runtime()["member"]["dirty"])
        self.assertEqual(self.runtime()["continuity"]["attestation"], "strict-v2-publication-integrity")
        self.assertIn("source differs", self.reject())

    def test_hidden_index_source_cannot_claim_freshness(self):
        self.f.git(self.f.member, "update-index", "--assume-unchanged", "README.md")
        (self.f.member / "README.md").write_text("hidden change\n", encoding="utf-8")
        self.assertIn("hidden", self.reject("start"))

    def test_historical_session_cannot_be_republished_as_new_receipt(self):
        self.f.checkpoint()
        paths = strict.receipt_paths("demo-member", self.f.member)
        for key in ("manifest", "state", "handoff"):
            path = self.f.cache / paths[key]
            path.write_bytes(path.read_bytes() + b"\n")
        self.f.commit(self.f.cache, "forged reuse of original Session")
        self.f.git(self.f.cache, "push", "origin", "main")
        before = (self.f.member / ".ai-bridge/context-runtime.md").read_bytes()
        result = self.f.launcher("start", check=False)
        self.assertEqual(result.returncode, 3, result.stdout)
        self.assertIn("CONTEXT_UNSYNCED:", result.stdout)
        self.assertEqual((self.f.member / ".ai-bridge/context-runtime.md").read_bytes(), before)

    def test_ledger_rewrite_rejected(self):
        self.f.checkpoint()
        self.f.publish_tamper("validation/repositories/demo-member.json", lambda v: v["entries"][0].update(summary="rewritten"))
        with self.assertRaisesRegex(RuntimeError, "ledger prefix"):
            strict.verify_published(lifecycle, self.f.member, self.f.cache, self.f.config)

    def test_ledger_delete_truncate_duplicate_and_redirect_rejected(self):
        self.f.checkpoint()
        path = self.f.cache / "validation/repositories/demo-member.json"
        original = path.read_bytes()
        # Validate independent published history for each hostile revision.
        for index, mutate in enumerate((lambda v: v.update(entries=[]), lambda v: v["entries"].append(dict(v["entries"][0])))):
            value = json.loads(original)
            mutate(value)
            strict.atomic_write(path, strict.json_bytes(value))
            self.f.commit(self.f.cache, "hostile ledger fixture")
            self.f.git(self.f.cache, "push", "origin", "main")
            self.f.launcher("start", check=False)
            expected = "ledger prefix" if index == 0 else "duplicate immutable validation id"
            with self.assertRaisesRegex(RuntimeError, expected):
                strict.verify_published(lifecycle, self.f.member, self.f.cache, self.f.config)
        path.unlink()
        self.f.commit(self.f.cache, "missing ledger fixture")
        self.f.git(self.f.cache, "push", "origin", "main")
        result = self.f.launcher("start", check=False)
        self.assertEqual(result.returncode, 3, result.stdout)
        with self.assertRaisesRegex(RuntimeError, "ledger prefix"):
            strict.verify_published(lifecycle, self.f.member, self.f.cache, self.f.config)

    def test_stale_future_and_source_runtime_rejected(self):
        path = self.f.member / ".ai-bridge/context-runtime.json"
        original = path.read_bytes()
        for generated in ((dt.datetime.now(dt.timezone.utc) - dt.timedelta(minutes=121)).isoformat(),
                          (dt.datetime.now(dt.timezone.utc) + dt.timedelta(seconds=5)).isoformat()):
            runtime = json.loads(original)
            runtime["generatedAt"] = generated
            strict.atomic_write(path, strict.json_bytes(runtime))
            self.reject("status")
        strict.atomic_write(path, original)
        (self.f.member / "README.md").write_text("changed source\n", encoding="utf-8")
        self.reject("status")
        self.f.start()
        self.reject("verify")

    def test_remote_advance_and_divergence_preserve_both_histories(self):
        local_head = self.f.git(self.f.cache, "rev-parse", "HEAD")
        (self.f.central / "remote-writer.md").write_text("remote\n")
        self.f.commit(self.f.central, "concurrent remote writer")
        self.f.git(self.f.central, "push", "origin", "main")
        self.reject("status")
        self.f.start()
        (self.f.cache / "local-writer.md").write_text("local\n")
        self.f.commit(self.f.cache, "local divergence fixture")
        divergent = self.f.git(self.f.cache, "rev-parse", "HEAD")
        self.reject("start")
        self.assertEqual(self.f.git(self.f.cache, "rev-parse", "HEAD"), divergent)
        self.assertNotEqual(local_head, divergent)

    def test_offline_strict_verify_rejected_without_altering_marker(self):
        marker = self.f.member / ".ai-bridge/context-offline.json"
        marker.write_text('{"offline":"preserved"}', encoding="utf-8")
        before = marker.read_bytes()
        self.reject()
        self.assertEqual(marker.read_bytes(), before)

    def test_source_payload_and_journal_race_preserved(self):
        self.f.write_payload(self.f.payload())
        real_git = strict.git
        def rejected_push(root, *args, **kwargs):
            if args and args[0] == "push":
                raise RuntimeError("fixture rejected push")
            return real_git(root, *args, **kwargs)
        with patch.object(strict, "git", rejected_push), self.assertRaisesRegex(RuntimeError, "rejected push"):
            strict.checkpoint(lifecycle, self.f.member, self.f.cache, self.f.config)
        journal_path = self.f.member / ".ai-bridge/context-checkpoint-pending.json"
        journal = journal_path.read_bytes()
        payload_path = self.f.member / ".ai-bridge/context-checkpoint.json"
        original_payload = payload_path.read_bytes()
        payload_path.write_bytes(original_payload + b" ")
        self.reject("checkpoint")
        self.assertEqual(journal_path.read_bytes(), journal)
        payload_path.write_bytes(original_payload)
        value = json.loads(journal)
        value["contextRoot"] = str(self.f.root / "foreign")
        strict.atomic_write(journal_path, strict.json_bytes(value))
        self.reject("checkpoint")
        strict.atomic_write(journal_path, journal)
        self.f.launcher("checkpoint")
        self.f.launcher("verify")

    def test_failed_commit_retry_and_post_commit_retry_create_one_session(self):
        self.f.write_payload(self.f.payload())
        real_git = strict.git
        for failure in ("commit", "push"):
            def fail(root, *args, **kwargs):
                if args and args[0] == failure:
                    raise RuntimeError("fixture interrupted " + failure)
                return real_git(root, *args, **kwargs)
            with patch.object(strict, "git", fail), self.assertRaisesRegex(RuntimeError, "interrupted"):
                strict.checkpoint(lifecycle, self.f.member, self.f.cache, self.f.config)
        self.f.launcher("checkpoint")
        before = self.f.git(self.f.cache, "rev-parse", "HEAD")
        manifest = self.f.manifest()
        payload = strict.committed(self.f.cache, "HEAD", manifest["checkpointPayloadPath"])
        strict.atomic_write(self.f.member / ".ai-bridge/context-checkpoint.json", payload)
        self.f.launcher("checkpoint")
        self.assertEqual(self.f.git(self.f.cache, "rev-parse", "HEAD"), before)
        sessions = self.f.git(self.f.cache, "ls-tree", "-r", "--name-only", "HEAD", "--", "sessions").splitlines()
        self.assertEqual(len([p for p in sessions if "demo-member-" in p]), 1)

    def test_concurrent_local_writer_lock_preserves_payload(self):
        self.f.write_payload(self.f.payload())
        payload = self.f.member / ".ai-bridge/context-checkpoint.json"
        before = payload.read_bytes()
        with strict.cache_lock(self.f.cache):
            self.assertIn("concurrent context writer", self.reject("checkpoint"))
        self.assertEqual(payload.read_bytes(), before)
        self.f.launcher("checkpoint")

    def test_unknown_owner_workstream_and_lost_own_manifest_rejected(self):
        self.f.checkpoint()
        paths = strict.receipt_paths("demo-member", self.f.member)
        (self.f.cache / paths["manifest"]).unlink()
        self.f.commit(self.f.cache, "missing own Manifest fixture")
        self.f.git(self.f.cache, "push", "origin", "main")
        result = self.f.launcher("start", check=False)
        self.assertEqual(result.returncode, 3)
        self.assertIn("strict checkpoint cannot be downgraded", result.stdout)
        self.assertTrue((self.f.cache / paths["state"]).exists())

    def test_snapshot_and_archive_preserve_completed_workstream(self):
        self.f.checkpoint()
        cp = self.f.payload(validation_id="complete-1")
        ws = cp["continuity"]["workstream"]
        ws["status"] = "COMPLETED"
        ws["items"][0]["status"] = "COMPLETED"
        ws["cursor"].update(currentItemId=None, lastCompletedItemId="TASK-1")
        cp["status"] = "VALIDATED"
        self.f.checkpoint(cp)
        archive = self.f.cache / "workstreams/archive/strict-feature.json"
        original = archive.read_bytes()
        self.f.checkpoint(self.f.payload(tracked=False, validation_id="snapshot-1"))
        self.assertEqual(archive.read_bytes(), original)
        self.f.launcher("verify")
        cp = self.f.payload(validation_id="reopen-1")
        self.f.write_payload(cp)
        self.reject("checkpoint")

    def seed_legacy(self, reviewed=True):
        f = self.f
        ws = f.payload()["continuity"]["workstream"]
        ws["id"] = "unknown-owner-history"
        ws["status"] = "PROPOSED"
        ws["cursor"]["currentItemId"] = None
        ws["items"][0]["status"] = "PENDING"
        session = "sessions/2026/10/original-history.md"
        ws["lastCheckpoint"] = {"repository": "demo-member", "session": session}
        records = {
            "manifests/repositories/demo-member.json": strict.json_bytes({"schemaVersion": 1, "repository": "demo-member", "session": session,
                "continuity": {"mode": "tracked", "workstreamId": ws["id"], "workstreamStatus": "PROPOSED", "workstreamPath": "workstreams/active/unknown-owner-history.json"}}),
            "state/repositories/demo-member.md": b"# Unbound original state\nApproved historical decision.\n",
            "handoffs/repositories/demo-member.md": b"# Unbound original handoff\nPending historical intent.\n",
            "workstreams/active/unknown-owner-history.json": strict.json_bytes(ws),
            session: b"# Original historical session\n",
            "validation/repositories/demo-member.json": strict.json_bytes({"schemaVersion": 2, "repository": "demo-member", "entries": [{"id": "historical-validation", "summary": "unknown root historical only"}]})}
        for relative, content in records.items():
            strict.atomic_write(f.cache / relative, content)
        f.commit(f.cache, "legacy provenance fixture")
        base = f.git(f.cache, "rev-parse", "HEAD")
        if reviewed:
            protected = [{"path": p, "blob": strict.blob(f.cache, base, p)} for p in records if "/repositories/" in p and not p.startswith("validation/")]
            review = {"schemaVersion": 1, "kind": "independent-root-enrollment", "project": "demo", "repository": "demo-member",
                      "contextRemote": str(f.remote), "baseCommit": base,
                      "review": {"decision": "preserve-unbound-and-enroll-independent-roots", "authority": "fixture owner review", "provenance": ["explicit fixture decision"]},
                      "legacy": protected, "workstream": {"id": ws["id"], "sourceCommit": base, "path": "workstreams/active/unknown-owner-history.json",
                                                           "blob": strict.blob(f.cache, base, "workstreams/active/unknown-owner-history.json"), "disposition": "preserved-unbound-proposed"},
                      "enrollments": [{"memberWorktree": str(f.member), "worktreeId": strict.receipt_paths("demo-member", f.member)["worktreeId"],
                                       "scope": "strict-posix", "workstreamId": "strict-feature"}]}
            strict.atomic_write(f.cache / "references/continuity-reconciliations/demo-member.json", strict.json_bytes(review))
            f.commit(f.cache, "explicit independent root review fixture")
        f.git(f.cache, "push", "origin", "main")
        return records

    def test_reviewed_independent_enrollment_preserves_unknown_history(self):
        records = self.seed_legacy()
        self.f.start()
        self.f.checkpoint()
        self.f.launcher("verify")
        for relative, content in records.items():
            if not relative.startswith("validation/"):
                self.assertEqual((self.f.cache / relative).read_bytes(), content)
        ledger = strict.read_json(self.f.cache, "validation/repositories/demo-member.json")
        self.assertEqual(ledger["entries"][0]["id"], "historical-validation")
        self.assertIn("legacyPreservation", self.f.manifest())

    def test_unreviewed_legacy_cannot_be_silently_converted(self):
        records = self.seed_legacy(reviewed=False)
        self.reject("start")
        for relative, content in records.items():
            self.assertEqual((self.f.cache / relative).read_bytes(), content)

    def test_changed_review_or_protected_legacy_rejected(self):
        self.seed_legacy()
        self.f.start()
        review = self.f.cache / "references/continuity-reconciliations/demo-member.json"
        value = json.loads(review.read_bytes())
        value["review"]["authority"] = "replaced authority"
        strict.atomic_write(review, strict.json_bytes(value))
        self.f.commit(self.f.cache, "hostile replacement of review fixture")
        self.f.git(self.f.cache, "push", "origin", "main")
        self.assertIn("review record replaced", self.reject("start"))

    def test_protected_legacy_working_bytes_cannot_hide_in_index(self):
        self.seed_legacy()
        self.f.start()
        relative = "state/repositories/demo-member.md"
        self.f.git(self.f.cache, "update-index", "--assume-unchanged", relative)
        (self.f.cache / relative).write_text("changed hidden historical decision\n", encoding="utf-8")
        self.assertIn("hidden", self.reject("start"))

    def test_review_scope_and_global_unknown_id_are_not_takeover_permission(self):
        self.seed_legacy()
        self.f.start()
        cp = self.f.payload(workstream="unknown-owner-history")
        self.f.write_payload(cp)
        self.assertIn("reviewed independent enrollment", self.reject("checkpoint"))
        cp = self.f.payload()
        cp["scope"] = "wrong-scope"
        self.f.write_payload(cp)
        self.reject("checkpoint")

    def test_commit_success_journal_save_failure_is_recoverable(self):
        self.f.write_payload(self.f.payload())
        original = strict.atomic_write
        def fail(path, data):
            if path.name == "context-checkpoint-pending.json" and json.loads(data).get("stage") == "committed":
                raise RuntimeError("fixture journal save interrupted")
            return original(path, data)
        with patch.object(strict, "atomic_write", fail), self.assertRaisesRegex(RuntimeError, "save interrupted"):
            strict.checkpoint(lifecycle, self.f.member, self.f.cache, self.f.config)
        before = self.f.git(self.f.cache, "rev-parse", "HEAD")
        self.f.launcher("checkpoint")
        self.assertEqual(self.f.git(self.f.cache, "rev-parse", "HEAD"), before)
        self.f.launcher("verify")


if __name__ == "__main__":
    unittest.main(verbosity=2)
