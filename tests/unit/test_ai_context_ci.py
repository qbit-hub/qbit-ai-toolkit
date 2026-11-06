from __future__ import annotations

import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = REPO_ROOT / ".github" / "workflows" / "ai-context-posix.yml"


class AiContextCiContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.workflow_text = WORKFLOW.read_text(encoding="utf-8")

    def test_native_posix_matrix_and_python_floor_are_explicit(self) -> None:
        self.assertIn("ubuntu-latest", self.workflow_text)
        self.assertIn("macos-latest", self.workflow_text)
        self.assertIn("actions/setup-python@v7", self.workflow_text)
        self.assertIn("python-version: '3.10'", self.workflow_text)
        self.assertIn("Set up Python 3.11 for repository validation", self.workflow_text)
        self.assertIn("python-version: '3.11'", self.workflow_text)
        self.assertIn("actions/checkout@v7", self.workflow_text)

    def test_required_posix_validation_layers_are_ci_gates(self) -> None:
        required_commands = (
            "python installers/ai-context/tests/unit/test-unit.py",
            "python installers/ai-context/tests/unit/test-strict-posix.py",
            "python installers/ai-context/tests/integration/test-strict-posix.py",
            "bash installers/ai-context/tests/integration/test-installer.sh",
            "bash installers/ai-context/tests/integration/test-legacy-migration.sh",
            "bash installers/ai-context/tests/e2e/test-e2e.sh",
            "python -m unittest tests.unit.test_validate tests.unit.test_ai_context_ci",
            "python tools/validate.py",
        )
        for command in required_commands:
            with self.subTest(command=command):
                self.assertIn(command, self.workflow_text)

    def test_workflow_is_scoped_to_ai_context_and_validation_changes(self) -> None:
        required_paths = (
            "'installers/ai-context/**'",
            "'catalog.json'",
            "'tools/validate.py'",
            "'tests/unit/test_validate.py'",
            "'tests/unit/test_ai_context_ci.py'",
            "'.github/workflows/ai-context-posix.yml'",
        )
        for path in required_paths:
            with self.subTest(path=path):
                self.assertIn(path, self.workflow_text)
        self.assertIn("permissions:\n  contents: read", self.workflow_text)

    def test_posix_shell_scripts_avoid_bash4_only_array_helpers(self) -> None:
        shell_files = (REPO_ROOT / "installers" / "ai-context").rglob("*.sh")
        for path in shell_files:
            text = path.read_text(encoding="utf-8")
            with self.subTest(path=path.relative_to(REPO_ROOT).as_posix()):
                self.assertNotIn("mapfile", text)
                self.assertNotIn("readarray", text)


if __name__ == "__main__":
    unittest.main()
