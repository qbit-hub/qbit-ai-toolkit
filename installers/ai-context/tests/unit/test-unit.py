#!/usr/bin/env python3
from __future__ import annotations

import importlib.util
import json
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("ai_context_installer", ROOT / "lib" / "installer.py")
assert SPEC and SPEC.loader
installer = importlib.util.module_from_spec(SPEC)
import sys
sys.modules[SPEC.name] = installer
SPEC.loader.exec_module(installer)

LIFECYCLE_SPEC = importlib.util.spec_from_file_location(
    "ai_context_lifecycle",
    ROOT / "templates" / "common" / "central" / "tooling" / "context-lifecycle.py",
)
assert LIFECYCLE_SPEC and LIFECYCLE_SPEC.loader
lifecycle = importlib.util.module_from_spec(LIFECYCLE_SPEC)
sys.modules[LIFECYCLE_SPEC.name] = lifecycle
LIFECYCLE_SPEC.loader.exec_module(lifecycle)


class AiContextPosixUnitTests(unittest.TestCase):
    def test_safe_id_and_branch_validation(self) -> None:
        self.assertEqual(installer.safe_id("demo-api", "RepositoryId"), "demo-api")
        with self.assertRaises(installer.InstallerError):
            installer.safe_id("../bad", "RepositoryId")
        self.assertEqual(installer.safe_branch("feature/demo-1",), "feature/demo-1")
        with self.assertRaises(installer.InstallerError):
            installer.safe_branch("../main")

    def test_remote_rejects_credentials_and_unsupported_url_scheme(self) -> None:
        self.assertEqual(installer.safe_remote("https://github.com/example/context.git"), "https://github.com/example/context.git")
        with self.assertRaises(installer.InstallerError):
            installer.safe_remote("https://token@github.com/example/context.git")
        with self.assertRaises(installer.InstallerError):
            installer.safe_remote("ssh://git@example.com/context.git")

    def test_safe_path_rejects_traversal_and_symlink(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp).resolve()
            with self.assertRaises(installer.InstallerError):
                installer.safe_path(root, "../escape")
            target = root / "outside"
            target.mkdir()
            link = root / "link"
            try:
                link.symlink_to(target, target_is_directory=True)
            except (OSError, NotImplementedError):
                self.skipTest("symlink creation unavailable on this host")
            with self.assertRaises(installer.InstallerError):
                installer.safe_path(root, "link/file.txt")

    def test_managed_block_round_trip_preserves_outside_content(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "AGENTS.md"
            path.write_bytes(b"# User rules\n")
            block = installer.Block(installer.BLOCK_BEGIN, installer.BLOCK_END, "## Managed\n\nRule.\n")
            installer.set_block(path, block)
            info = installer.block_info(path, block)
            self.assertEqual(info["status"], "present")
            self.assertEqual(info["hash"], installer.text_hash("## Managed\n\nRule."))
            installer.remove_block(path, block)
            self.assertEqual(path.read_bytes(), b"# User rules\n")

    def test_managed_file_hash_normalizes_utf8_bom_and_line_endings(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            lf = root / "lf.txt"
            crlf = root / "crlf.txt"
            bom = root / "bom.txt"
            lf.write_bytes(b"alpha\nbeta\n")
            crlf.write_bytes(b"alpha\r\nbeta\r\n")
            bom.write_bytes(b"\xef\xbb\xbfalpha\r\nbeta\r\n")
            expected = installer.text_hash("alpha\nbeta\n")
            self.assertEqual(installer.file_hash(lf), expected)
            self.assertEqual(installer.file_hash(crlf), expected)
            self.assertEqual(installer.file_hash(bom), expected)

    def test_state_identity_is_fail_closed(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp).resolve()
            state_path = root / installer.STATE_PATH
            state_path.parent.mkdir(parents=True)
            state_path.write_text(json.dumps({"schemaVersion": "1.0", "installerId": "wrong"}), encoding="utf-8")
            with self.assertRaises(installer.InstallerError) as caught:
                installer.read_state(root)
            self.assertEqual(caught.exception.code, 5)

    def test_member_spec_contains_both_platform_launchers(self) -> None:
        values = installer.values("demo", "Demo", "demo-api", "demo-ai-context", "https://example.invalid/context.git", "main")
        spec = installer.new_spec("member", values)
        self.assertIn(".ai/context/context.ps1", spec.files)
        self.assertIn(".ai/context/context.sh", spec.files)
        self.assertIn(".ai/context/context.py", spec.files)
        self.assertIn(".ai/context/context_strict.py", spec.files)
        self.assertIn("AGENTS.md", spec.blocks)

    def test_central_spec_contains_both_platform_lifecycle_tooling(self) -> None:
        values = installer.values("demo", "Demo", "demo-ai-context", "demo-ai-context", "https://example.invalid/context.git", "main")
        spec = installer.new_spec("central", values)
        self.assertIn("tooling/context-lifecycle.ps1", spec.files)
        self.assertIn("tooling/context-lifecycle.py", spec.files)
        self.assertEqual(spec.files["tooling/context_strict.py"], spec.files["templates/member/context_strict.py"])
        self.assertIn("tests/context-lifecycle.tests.ps1", spec.files)
        self.assertIn("tests/context-lifecycle.tests.sh", spec.files)

    def test_repository_registry_membership_is_explicit_and_fail_closed(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            registry = root / "repositories" / "repositories.yaml"
            registry.parent.mkdir(parents=True)
            registry.write_text(
                "project: demo\n"
                "repositories:\n"
                "  demo-api:\n"
                "    path: ../demo-api\n"
                "    role: application-member\n",
                encoding="utf-8",
            )
            config = {"project": "demo", "repository": "demo-api"}
            info = lifecycle.membership_info(root, config)
            self.assertTrue(info["registered"])
            self.assertTrue(info["projectMatches"])
            self.assertEqual(info["role"], "application-member")
            self.assertEqual(info["path"], "../demo-api")

            missing = lifecycle.membership_info(root, {"project": "demo", "repository": "demo-worker"})
            self.assertFalse(missing["registered"])
            self.assertIn("not registered", str(missing["issue"]))
            with self.assertRaisesRegex(RuntimeError, "not registered"):
                lifecycle.require_registered_member(root, {"project": "demo", "repository": "demo-worker"})

    def test_repository_registry_rejects_member_without_role(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            registry = root / "repositories" / "repositories.yaml"
            registry.parent.mkdir(parents=True)
            registry.write_text("project: demo\nrepositories:\n  demo-api:\n    path: ../demo-api\n", encoding="utf-8")
            with self.assertRaisesRegex(RuntimeError, "missing required role"):
                lifecycle.load_repository_registry(root)

    def test_repository_registry_preserves_membership_with_project_owned_metadata(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            registry = root / "repositories" / "repositories.yaml"
            registry.parent.mkdir(parents=True)
            registry.write_text(
                "project: demo\n"
                "workspace_root: D:/Projects/Demo\n"
                "excluded_directories:\n"
                "  - Docs\n"
                "  - worktrees\n"
                "repositories:\n"
                "  demo-api:\n"
                "    path: ../demo-api\n"
                "    role: application-member\n"
                "    authority:\n"
                "      - implementation\n"
                "      - tests\n"
                "    publish: false\n"
                "    notes: Project-owned metadata remains outside membership semantics.\n",
                encoding="utf-8",
            )
            parsed = lifecycle.load_repository_registry(root)
            self.assertEqual(parsed["project"], "demo")
            self.assertEqual(parsed["repositories"], {"demo-api": {"role": "application-member", "path": "../demo-api"}})

    def test_rendered_lifecycle_exposes_audit_and_forbids_automatic_rebase(self) -> None:
        values = installer.values("demo", "Demo", "demo-ai-context", "demo-ai-context", "https://example.invalid/context.git", "main")
        central = installer.new_spec("central", values)
        powershell = central.files["tooling/context-lifecycle.ps1"]
        python = central.files["tooling/context-lifecycle.py"]
        self.assertIn("'audit'", powershell)
        self.assertIn('"audit"', python)
        self.assertNotIn("@('rebase'", powershell)
        self.assertNotIn('["rebase",', python)


if __name__ == "__main__":
    unittest.main(verbosity=2)
