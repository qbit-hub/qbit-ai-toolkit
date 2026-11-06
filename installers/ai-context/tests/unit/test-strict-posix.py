#!/usr/bin/env python3
"""Contract tests independent of launcher presentation."""
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "support"))
from strict_fixture import Fixture, TEMP, strict, lifecycle


class StrictContractTests(unittest.TestCase):
    def test_verify_requires_committed_payload_path_and_matching_digest(self):
        # Exercise real Git objects without installing launchers or running an
        # online lifecycle. Only cache health is outside this unit's boundary.
        with tempfile.TemporaryDirectory(dir=TEMP) as temp:
            root = Path(temp).resolve()
            cache, member = root / "cache", root / "member"
            cache.mkdir()
            member.mkdir()
            def git(*args):
                return Fixture.run(["git", "-C", cache, *args]).stdout.strip()
            git("init", "-b", "main")
            git("config", "user.name", "Fixture")
            git("config", "user.email", "fixture@example.invalid")
            git("config", "core.autocrlf", "false")
            (cache / "README.md").write_bytes(b"unit fixture\n")
            git("add", ".")
            git("commit", "-m", "base")
            base = git("rev-parse", "HEAD")
            config = {"project": "demo", "repository": "demo-member"}
            state = {"head": "1" * 40, "branch": "main", "dirty": False, "fingerprint": "2" * 64}
            checkpoint = Fixture.payload()
            data = strict.json_bytes(checkpoint)
            paths = strict.receipt_paths(config["repository"], member)
            files = strict.publication_files(lifecycle, member, cache, config, base, checkpoint, data, state,
                                             "a" * 32, dt.datetime.now(dt.timezone.utc).isoformat())
            manifest = strict.decode_json(files[paths["manifest"]])
            payload_path = manifest["checkpointPayloadPath"]

            def verify(mutate=lambda value: None, payload=data):
                for relative, content in files.items():
                    target = cache / relative
                    target.parent.mkdir(parents=True, exist_ok=True)
                    target.write_bytes(content)
                forged = dict(manifest)
                mutate(forged)
                (cache / paths["manifest"]).write_bytes(strict.json_bytes(forged))
                if payload is None:
                    (cache / payload_path).unlink()
                else:
                    (cache / payload_path).write_bytes(payload)
                git("add", "--all")
                # Every variant is a new committed publication against the same
                # base, so rejection cannot be caused by historical Session reuse.
                revision = git("commit-tree", git("write-tree"), "-p", base, "-m", "publication fixture")
                with patch.object(strict, "cache_health", return_value=revision):
                    return strict.verify_published(lifecycle, member, cache, config, state)

            self.assertEqual(verify(), manifest)
            for value in (None, "", False, [], {}, "../forged.json", payload_path.replace("a" * 32, "b" * 32)):
                with self.subTest(path=value), self.assertRaisesRegex(RuntimeError, "checkpoint payload path"):
                    verify(lambda m: m.update(checkpointPayloadPath=value))
            with self.subTest(path="absent"), self.assertRaisesRegex(RuntimeError, "checkpoint payload path"):
                verify(lambda m: m.pop("checkpointPayloadPath"))
            with self.subTest(payload="uncommitted"), self.assertRaisesRegex(RuntimeError, "checkpoint payload path"):
                verify(payload=None)
            with self.subTest(payload="tampered"), self.assertRaisesRegex(RuntimeError, "payload digest mismatch"):
                verify(payload=data + b"\n")
            # A forged digest mirrored in the Session still must bind payload bytes.
            forged_session = manifest["session"]
            files[forged_session] = files[forged_session].replace(manifest["checkpointPayloadSha256"].encode(), b"0" * 64)
            with self.subTest(digest="forged"), self.assertRaisesRegex(RuntimeError, "payload digest mismatch"):
                verify(lambda m: m.update(checkpointPayloadSha256="0" * 64))

    def test_windows_root_identity_matches_windows_contract(self):
        expected = "wt-" + hashlib.sha256(b"c:/work/member").hexdigest()[:32]
        for value in ("C:\\work\\Member\\", "c:/work/member", "C:/WORK/member/"):
            self.assertEqual(strict.receipt_paths("demo", value)["worktreeId"], expected)

    def test_windows_produced_artifact_contract_fixture(self):
        fixture = Path(__file__).resolve().parents[1] / "fixtures/windows-strict-v2.json"
        value = json.loads(fixture.read_text(encoding="utf-8"))
        # This is a frozen Windows-produced sample. Pin its producer identity;
        # later legitimate runtime fixes must not change historical provenance.
        self.assertEqual(value["provenance"], {
            "producer": "unmodified Windows context-lifecycle.ps1 / context-continuity.ps1",
            "toolkitSource": "55354cb37ef0ee289a5db2dd868a274bce0501b5",
            "lifecycleSha256": "303c7bf66c499575e1f7f78b963604c1bc5dae89fda5ec2f63e4ff2bffab35b5",
            "continuitySha256": "36b65a374db534fee1c7fc3a63947fbffb5121a9a94df8d9120f92505bf6819a",
            "normalization": "Only temporary root and derived worktree paths/ID replaced with C:/fixture/member. Other producer fields preserved. Raw fixture and run evidence retained in ignored .ai-bridge during implementation.",
        })
        manifest, ws, ledger = value["manifest"], value["workstream"], value["ledger"]
        paths = strict.receipt_paths(manifest["repository"], manifest["memberWorktree"])
        self.assertEqual(manifest["worktreeId"], paths["worktreeId"])
        self.assertEqual(manifest["receiptPaths"], {k: paths[k] for k in ("manifest", "state", "handoff")})
        strict.owner(ws["lastCheckpoint"], manifest["repository"], manifest["memberWorktree"], paths)
        self.assertEqual(ws["lastCheckpoint"]["session"], manifest["session"])
        self.assertEqual(ws["lastCheckpoint"]["fingerprint"], manifest["worktreeFingerprint"])
        self.assertEqual(strict.workstream_path(manifest["continuity"]), "workstreams/active/strict-feature.json")
        self.assertEqual(ledger["entries"][0]["validFor"]["worktreeId"], paths["worktreeId"])

    def test_posix_root_case_and_root_directory_preserved(self):
        self.assertNotEqual(strict.receipt_paths("demo", "/work/Member"), strict.receipt_paths("demo", "/work/member"))
        self.assertEqual(strict.normalize_root("/"), "/")
        self.assertEqual(strict.normalize_root("/work/member/"), "/work/member")

    def test_root_and_repository_must_be_explicit(self):
        for repository, root in (("../bad", "/work"), ("demo", "relative"), ("demo", "")):
            with self.subTest(repository=repository, root=root), self.assertRaises(RuntimeError):
                strict.receipt_paths(repository, root)

    def test_freshness_rejects_old_future_and_naive_dates(self):
        now = dt.datetime.now(dt.timezone.utc)
        strict.fresh(now.isoformat(), now)
        strict.fresh((now - dt.timedelta(minutes=120)).isoformat(), now)
        for value in (now - dt.timedelta(minutes=120, seconds=1), now + dt.timedelta(microseconds=1), now.replace(tzinfo=None)):
            with self.subTest(value=value), self.assertRaises(RuntimeError):
                strict.fresh(value.isoformat(), now)

    def test_payload_schema_and_unknown_fields_fail_closed(self):
        good = Fixture.payload()
        strict.validate_payload(lifecycle, strict.json_bytes(good), "demo-member")
        for mutate in (lambda v: v.update(schemaVersion=1), lambda v: v.update(schemaVersion=True),
                       lambda v: v.update(repository="foreign"), lambda v: v.update(extra="ignored"),
                       lambda v: v.update(decisions=[{}]), lambda v: v["continuity"].update(extra="ignored"),
                       lambda v: v["continuity"].update(mode="snapshot"),
                       lambda v: v["continuity"]["workstream"]["items"].clear(),
                       lambda v: v["continuity"]["validationLedger"][0].update(timestamp="2999-01-01T00:00:00Z")):
            value = json.loads(json.dumps(good))
            mutate(value)
            with self.subTest(value=value), self.assertRaises((RuntimeError, ValueError)):
                strict.validate_payload(lifecycle, strict.json_bytes(value), "demo-member")

    def test_duplicate_json_keys_and_secret_values_rejected(self):
        with self.assertRaisesRegex(RuntimeError, "duplicate JSON"):
            strict.decode_json(b'{"schemaVersion":2,"schemaVersion":1}')
        value = Fixture.payload()
        value["decisions"] = ["Bearer " + "x" * 20]
        with self.assertRaisesRegex(RuntimeError, "secret-like"):
            strict.validate_payload(lifecycle, strict.json_bytes(value), "demo-member")

    def test_managed_path_rejects_traversal_absolute_and_links(self):
        with tempfile.TemporaryDirectory(dir=TEMP) as temp:
            root = Path(temp)
            for relative in ("../escape", "/absolute", "x/../escape", "x//y", "x\\y", ".git/../escape", "C:/escape"):
                with self.subTest(relative=relative), self.assertRaises(RuntimeError):
                    strict.safe_path(root, relative)
            # Required natively in CI; Windows may lack symlink privilege.
            if os.name != "nt":
                (root / "link").symlink_to(root, target_is_directory=True)
                with self.assertRaisesRegex(RuntimeError, "link"):
                    strict.safe_path(root, "link/file")

    def test_raw_fingerprint_matches_independently_assembled_windows_fields(self):
        with tempfile.TemporaryDirectory(dir=TEMP) as temp:
            root = Path(temp).resolve()
            run = Fixture.run
            def git(*args):
                return run(["git", "-C", root, *args]).stdout
            git("init", "-b", "main")
            git("config", "user.name", "Fixture")
            git("config", "user.email", "fixture@example.invalid")
            git("config", "core.autocrlf", "false")
            (root / "source").write_bytes(b"before\n")
            git("add", ".")
            git("commit", "-m", "fixture")
            clean = strict.source_state(root)
            # Index-only changes and same-status source edits both affect it.
            (root / "source").write_bytes(b"after\n")
            dirty = strict.source_state(root)
            (root / "source").write_bytes(b"again\n")
            self.assertNotEqual(clean["fingerprint"], dirty["fingerprint"])
            self.assertNotEqual(dirty["fingerprint"], strict.source_state(root)["fingerprint"])
            git("add", "source")
            staged = strict.source_state(root)
            name = "unicode space \u03bb\U0001f600.txt"
            (root / name).write_bytes(b"new\n")
            parts = ["fingerprint-v2", "head=" + git("rev-parse", "HEAD").strip(),
                     git("status", "--porcelain=v1", "-z", "--untracked-files=all"), git("ls-files", "--stage", "-z")]
            for path in sorted(["source", name], key=lambda s: s.encode("utf-16-be")):
                parts.extend([path, git("hash-object", "--no-filters", "--", path).strip()])
            expected = hashlib.sha256("".join(f"{len(p.encode('utf-16-le')) // 2}:{p}" for p in parts).encode()).hexdigest()
            self.assertEqual(strict.source_state(root)["fingerprint"], expected)
            self.assertNotEqual(staged["fingerprint"], expected)
            (root / "nested").mkdir()
            with self.assertRaisesRegex(RuntimeError, "actual Git"):
                strict.actual_root(root / "nested")


if __name__ == "__main__":
    unittest.main(verbosity=2)
