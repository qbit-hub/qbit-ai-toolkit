#!/usr/bin/env python3
"""The older POSIX writer must not modify reviewed unbound legacy evidence."""
import importlib.util
import pathlib
import subprocess
import tempfile
import unittest


SOURCE = pathlib.Path(__file__).resolve().parents[2] / "templates/common/central/tooling/context-lifecycle.py"
SPEC = importlib.util.spec_from_file_location("reviewed_legacy_posix", SOURCE)
LIFECYCLE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(LIFECYCLE)


class ReviewedLegacyPosixTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="qbit-enroll-posix-")
        self.addCleanup(self.temp.cleanup)
        self.root = pathlib.Path(self.temp.name)
        subprocess.run(["git", "init", "-q", str(self.root)], check=True)
        self.path = self.root / "references/continuity-reconciliations/member.json"

    def test_no_record_preserves_existing_posix_behavior(self):
        LIFECYCLE.reject_reviewed_legacy_on_posix(self.root, "member")

    def test_uncommitted_or_malformed_record_rejects_before_any_checkpoint_write(self):
        self.path.parent.mkdir(parents=True)
        self.path.write_bytes(b"deliberately malformed reviewed record")
        before = self.path.read_bytes()
        with self.assertRaisesRegex(RuntimeError, "POSIX legacy writes are disabled"):
            LIFECYCLE.do_checkpoint(self.root, self.root, {"repository": "member"}, "main")
        self.assertEqual(before, self.path.read_bytes())
        self.assertFalse((self.root / ".ai-bridge").exists())

    def test_committed_record_deleted_locally_still_rejects(self):
        self.path.parent.mkdir(parents=True)
        self.path.write_text("{}", encoding="utf-8")
        subprocess.run(["git", "-C", str(self.root), "add", "."], check=True)
        subprocess.run(["git", "-C", str(self.root), "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-qm", "review fixture"], check=True)
        self.path.unlink()
        with self.assertRaisesRegex(RuntimeError, "native Windows lifecycle"):
            LIFECYCLE.reject_reviewed_legacy_on_posix(self.root, "member")
        self.assertFalse(self.path.exists())

    def test_unsafe_repository_cannot_redirect_record_detection(self):
        with self.assertRaisesRegex(RuntimeError, "invalid reconciliation repository"):
            LIFECYCLE.reject_reviewed_legacy_on_posix(self.root, "../other")


if __name__ == "__main__":
    unittest.main(verbosity=2)
