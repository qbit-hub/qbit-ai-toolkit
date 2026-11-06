from __future__ import annotations

import importlib.util
import json
import shutil
import tempfile
import unittest
from unittest import mock
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
VALIDATE_PATH = REPO_ROOT / "tools" / "validate.py"

spec = importlib.util.spec_from_file_location("qbit_validate", VALIDATE_PATH)
validate = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(validate)


def write_text(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8", newline="\n")


def write_bytes(path: Path, content: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(content)


class ValidateUnitTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory(prefix="qbit-validate-unit-")
        self.root = Path(self.temp.name)
        self.original_root = validate.ROOT
        validate.ROOT = self.root
        validate.errors = []

    def tearDown(self) -> None:
        validate.ROOT = self.original_root
        validate.errors = []
        self.temp.cleanup()

    def minimal_installer(self, catalog_version: str = "1.0.0", manifest_version: str = "1.0.0", version_file: str = "1.0.0", consumers=None) -> None:
        if consumers is None:
            consumers = ["cli"]
        installer = self.root / "installers" / "codex-ai-tooling"
        for profile in ["generic", "typescript", "rust"]:
            (installer / "templates" / "profiles" / profile).mkdir(parents=True, exist_ok=True)
        for entry in ["install.ps1", "install.sh", "verify.ps1", "verify.sh", "uninstall.ps1", "uninstall.sh"]:
            write_text(installer / entry, "# script\n")
        write_text(installer / "VERSION", version_file + "\n")
        manifest = {
            "id": "installer.codex-ai-tooling",
            "name": "Codex AI Tooling",
            "kind": "installer",
            "version": manifest_version,
            "status": "stable",
            "consumers": consumers,
            "supportedPlatforms": ["windows"],
            "supportedProfiles": ["generic", "typescript", "rust"],
            "defaultProfile": "auto",
            "entrypoints": {"powershell": "install.ps1", "posix": "install.sh"},
            "verifiers": {"powershell": "verify.ps1", "posix": "verify.sh"},
            "uninstallers": {"powershell": "uninstall.ps1", "posix": "uninstall.sh"},
            "description": "test",
        }
        write_text(installer / "manifest.json", json.dumps(manifest) + "\n")
        catalog = {
            "$schema": "./schemas/catalog.schema.json",
            "schemaVersion": "1.0",
            "name": "qbit-ai-toolkit",
            "assets": [{
                "id": "installer.codex-ai-tooling",
                "kind": "installer",
                "version": catalog_version,
                "path": "installers/codex-ai-tooling",
                "consumers": ["cli"],
                "status": "stable",
                "description": "test",
            }],
        }
        write_text(self.root / "catalog.json", json.dumps(catalog) + "\n")

    def copy_ai_fixture(self) -> None:
        def ignore_runtime_context_cache(directory: str, names: list[str]) -> set[str]:
            path = Path(directory)
            if path.name == "context" and "cache" in names:
                return {"cache"}
            return set()

        for directory in (".ai", ".serena", ".codex", "tests/e2e", "installers"):
            shutil.copytree(
                REPO_ROOT / directory,
                self.root / directory,
                dirs_exist_ok=True,
                ignore=ignore_runtime_context_cache if directory == ".ai" else None,
            )
        for file in ("catalog.json",):
            shutil.copy2(REPO_ROOT / file, self.root / file)

    def copy_continuity_fixture(self) -> None:
        for relative in (
            "AGENTS.md",
            "AI_CONTEXT.md",
            ".ai/context/context.ps1",
            ".ai/context/context.py",
            ".ai/context/context.sh",
            ".ai/context/context-transfer.ps1",
            "docs/ai-tooling/continuity-v2.md",
            "installers/ai-context/VERSION",
            "installers/ai-context/README.md",
            "installers/ai-context/CHANGELOG.md",
            "installers/ai-context/templates/common/member/agents-block.md.tpl",
            "installers/ai-context/templates/common/member/context.ps1",
            "installers/ai-context/templates/common/member/context.py",
            "installers/ai-context/templates/common/member/context.sh",
            "installers/ai-context/templates/common/member/context-transfer.ps1",
            "installers/ai-context/templates/common/central/docs/context-automation.md.tpl",
            "installers/ai-context/templates/common/central/schemas/checkpoint.schema.json",
            "installers/ai-context/templates/common/central/tooling/context-continuity.ps1",
            "installers/ai-context/templates/common/central/tooling/context-lifecycle.py",
        ):
            source = REPO_ROOT / relative
            target = self.root / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, target)

    def assert_ai_mutation(self, relative: str, mutate, expected: str) -> None:
        self.copy_ai_fixture()
        path = self.root / relative
        mutate(path)
        validate.validate_ai_tooling()
        self.assertTrue(any(expected in item for item in validate.errors), validate.errors)

    def test_semver_acceptance_and_rejection(self) -> None:
        self.assertRegex("1.0.0", validate.SEMVER)
        self.assertRegex("0.1.2-alpha.1", validate.SEMVER)
        self.assertNotRegex("1", validate.SEMVER)
        self.assertNotRegex("1.0", validate.SEMVER)
        self.assertNotRegex("01.0.0", validate.SEMVER)

    def test_duplicate_asset_id_detection(self) -> None:
        self.minimal_installer()
        catalog = json.loads((self.root / "catalog.json").read_text(encoding="utf-8"))
        catalog["assets"].append(dict(catalog["assets"][0]))
        write_text(self.root / "catalog.json", json.dumps(catalog) + "\n")
        validate.validate_catalog()
        self.assertTrue(any("Duplicate asset id" in item for item in validate.errors))

    def test_missing_catalog_path_detection(self) -> None:
        self.minimal_installer()
        catalog = json.loads((self.root / "catalog.json").read_text(encoding="utf-8"))
        catalog["assets"][0]["path"] = "missing/path"
        write_text(self.root / "catalog.json", json.dumps(catalog) + "\n")
        validate.validate_catalog()
        self.assertTrue(any("Asset path does not exist" in item for item in validate.errors))

    def test_manifest_version_must_match_version_file(self) -> None:
        self.minimal_installer(manifest_version="1.0.0", version_file="1.0.1")
        validate.validate_catalog()
        self.assertTrue(any("Manifest version does not equal VERSION" in item for item in validate.errors))

    def test_catalog_version_must_match_manifest(self) -> None:
        self.minimal_installer(catalog_version="1.0.1", manifest_version="1.0.0")
        validate.validate_catalog()
        self.assertTrue(any("Catalog version does not equal manifest version" in item for item in validate.errors))

    def test_invalid_consumers_detected(self) -> None:
        self.minimal_installer(consumers=["mobile"])
        validate.validate_catalog()
        self.assertTrue(any("Manifest consumers invalid" in item for item in validate.errors))

    def test_non_codex_installer_does_not_require_rust_profile(self) -> None:
        self.minimal_installer()
        manifest_path = self.root / "installers" / "codex-ai-tooling" / "manifest.json"
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        manifest["id"] = "installer.ai-context"
        manifest["supportedProfiles"] = ["generic"]
        manifest["defaultProfile"] = "generic"
        write_text(manifest_path, json.dumps(manifest) + "\n")
        catalog_path = self.root / "catalog.json"
        catalog = json.loads(catalog_path.read_text(encoding="utf-8"))
        catalog["assets"][0]["id"] = "installer.ai-context"
        write_text(catalog_path, json.dumps(catalog) + "\n")
        validate.validate_catalog()
        self.assertFalse(any("rust supported profile" in item for item in validate.errors), validate.errors)

    def test_continuity_v2_contract_accepts_canonical_fixture(self) -> None:
        self.copy_continuity_fixture()
        validate.validate_ai_context_continuity_v2()
        self.assertEqual([], validate.errors)

    def test_continuity_v2_contract_accepts_candidate_with_pinned_self_bootstrap(self) -> None:
        self.copy_continuity_fixture()
        installer = self.root / "installers/ai-context"
        self.assertEqual("1.3.0", (installer / "VERSION").read_text().strip())
        self.assertEqual("1.2.9", validate.AI_CONTEXT_SELF_BOOTSTRAP_VERSION)
        self.assertNotEqual((self.root / ".ai/context/context.py").read_bytes(),
                            (installer / "templates/common/member/context.py").read_bytes())
        validate.validate_ai_context_continuity_v2()
        self.assertEqual([], validate.errors)

    def pin_continuity_fixture_to_self_bootstrap(self) -> None:
        installer = self.root / "installers/ai-context"
        candidate = (installer / "VERSION").read_text().strip()
        pinned = validate.AI_CONTEXT_SELF_BOOTSTRAP_VERSION
        for relative in ("installers/ai-context/VERSION", "installers/ai-context/README.md",
                         "installers/ai-context/CHANGELOG.md", "docs/ai-tooling/continuity-v2.md"):
            path = self.root / relative
            write_text(path, path.read_text(encoding="utf-8").replace(candidate, pinned))
        for name in validate.AI_CONTEXT_SELF_BOOTSTRAP_SHA256:
            shutil.copy2(self.root / ".ai/context" / name, installer / "templates/common/member" / name)

    def test_continuity_v2_contract_accepts_matching_self_bootstrap_release(self) -> None:
        self.copy_continuity_fixture()
        self.pin_continuity_fixture_to_self_bootstrap()
        validate.validate_ai_context_continuity_v2()
        self.assertEqual([], validate.errors)

    def test_continuity_v2_contract_rejects_self_bootstrap_drift_at_both_versions(self) -> None:
        self.copy_continuity_fixture()
        for version in ("1.3.0", "1.2.9"):
            if version == "1.2.9":
                self.pin_continuity_fixture_to_self_bootstrap()
            for name in validate.AI_CONTEXT_SELF_BOOTSTRAP_SHA256:
                with self.subTest(version=version, name=name):
                    path = self.root / ".ai/context" / name
                    original = path.read_bytes()
                    path.write_bytes(original + b"# unauthorized change\n")
                    validate.errors = []
                    validate.validate_ai_context_continuity_v2()
                    self.assertTrue(any("runtime drifted" in item and name in item for item in validate.errors), validate.errors)
                    path.write_bytes(original)

    def test_continuity_v2_contract_rejects_matching_root_and_template_tamper(self) -> None:
        self.copy_continuity_fixture()
        for relative in (".ai/context/context.py", "installers/ai-context/templates/common/member/context.py"):
            path = self.root / relative
            write_text(path, path.read_text(encoding="utf-8") + "# matching unauthorized change\n")
        validate.validate_ai_context_continuity_v2()
        self.assertTrue(any("runtime drifted" in item and "context.py" in item for item in validate.errors), validate.errors)

    def test_continuity_v2_contract_rejects_unreviewed_root_candidate_upgrade(self) -> None:
        self.copy_continuity_fixture()
        shutil.copy2(self.root / "installers/ai-context/templates/common/member/context.py",
                     self.root / ".ai/context/context.py")
        validate.validate_ai_context_continuity_v2()
        self.assertTrue(any("runtime drifted" in item and "context.py" in item for item in validate.errors), validate.errors)

    def test_continuity_v2_contract_rejects_same_version_template_drift(self) -> None:
        self.copy_continuity_fixture()
        self.pin_continuity_fixture_to_self_bootstrap()
        path = self.root / "installers/ai-context/templates/common/member/context.py"
        write_text(path, path.read_text(encoding="utf-8") + "# unauthorized template change\n")
        validate.validate_ai_context_continuity_v2()
        self.assertTrue(any("template differs from pinned self-bootstrap" in item for item in validate.errors), validate.errors)

    def test_continuity_v2_contract_rejects_toolkit_schema_v1_policy_drift(self) -> None:
        self.copy_continuity_fixture()
        path = self.root / "AGENTS.md"
        text = path.read_text(encoding="utf-8").replace("`schemaVersion: 2`", "`schemaVersion: 1`", 1)
        write_text(path, text)
        validate.validate_ai_context_continuity_v2()
        self.assertTrue(any("Toolkit AGENTS Continuity v2 policy missing" in item for item in validate.errors), validate.errors)

    def test_continuity_v2_contract_rejects_incomplete_member_action_surface(self) -> None:
        self.copy_continuity_fixture()
        path = self.root / "installers" / "ai-context" / "templates" / "common" / "member" / "context.ps1"
        text = path.read_text(encoding="utf-8").replace(", 'reconnect'", "", 1)
        write_text(path, text)
        validate.validate_ai_context_continuity_v2()
        self.assertTrue(any("PowerShell member launcher Continuity v2 action surface is incomplete" in item for item in validate.errors), validate.errors)

    def test_continuity_v2_contract_rejects_toolkit_root_runtime_drift(self) -> None:
        self.copy_continuity_fixture()
        path = self.root / ".ai" / "context" / "context.ps1"
        write_text(path, path.read_text(encoding="utf-8") + "# drift\n")
        validate.validate_ai_context_continuity_v2()
        self.assertTrue(any("Toolkit root AI Context runtime drifted from canonical template" in item for item in validate.errors), validate.errors)

    def test_all_files_excludes_ai_context_runtime_artifacts(self) -> None:
        write_text(self.root / ".ai" / "context" / "cache" / "project-context" / "runtime.json", "{}\n")
        write_text(self.root / ".ai-bridge" / "context-runtime.json", "{}\n")
        write_text(self.root / ".ai-bridge" / "README.md", "# Bridge\n")
        write_text(self.root / "source.txt", "source\n")
        names = {path.relative_to(self.root).as_posix() for path in validate.all_files()}
        self.assertNotIn(".ai/context/cache/project-context/runtime.json", names)
        self.assertNotIn(".ai-bridge/context-runtime.json", names)
        self.assertIn(".ai-bridge/README.md", names)
        self.assertIn("source.txt", names)

    def test_all_files_excludes_generated_website_test_artifacts(self) -> None:
        write_text(self.root / "website" / "test-results" / ".last-run.json", "{}")
        write_text(self.root / "website" / "playwright-report" / "index.html", "generated")
        write_text(self.root / "website" / "coverage" / "coverage.json", "{}")
        write_text(self.root / "website" / "docs" / "source.md", "source\n")
        names = {path.relative_to(self.root).as_posix() for path in validate.all_files()}
        self.assertNotIn("website/test-results/.last-run.json", names)
        self.assertNotIn("website/playwright-report/index.html", names)
        self.assertNotIn("website/coverage/coverage.json", names)
        self.assertIn("website/docs/source.md", names)

    def test_unresolved_placeholder_boundaries(self) -> None:
        write_text(self.root / "installers" / "codex-ai-tooling" / "templates" / "common" / "file.txt", "{{" + "PROJECT" + "}}\n")
        write_text(self.root / "website" / "i18n" / "fa" / "docusaurus-plugin-content-docs" / "current" / "asset-contract.md", "`{{" + "PROJECT" + "}}`\n")
        write_text(self.root / "ordinary.txt", "{{" + "PROJECT" + "}}\n")
        validate.validate_content_hygiene()
        self.assertTrue(any("ordinary.txt" in item for item in validate.errors))
        self.assertFalse(any("templates/common/file.txt" in item for item in validate.errors))
        self.assertFalse(any("website/i18n/fa" in item for item in validate.errors))

    def test_forbidden_absolute_path_detection(self) -> None:
        forbidden = "D:\\Projects\\" + "Q" + "bit" + "\\repo\n"
        write_text(self.root / "path.txt", forbidden)
        validate.validate_content_hygiene()
        self.assertTrue(any("Forbidden absolute path" in item for item in validate.errors))

    def test_codexpro_documentation_may_contain_reference_absolute_paths(self) -> None:
        forbidden = "C:\\Users\\example\\.codexpro\\Start-CodexPro.ps1\n"
        write_text(self.root / "docs" / "ai-tools" / "codexpro" / "windows-setup.md", forbidden)
        write_text(
            self.root
            / "website"
            / "i18n"
            / "fa"
            / "docusaurus-plugin-content-docs"
            / "current"
            / "ai-tools"
            / "codexpro"
            / "windows-setup.md",
            forbidden,
        )
        validate.validate_content_hygiene()
        self.assertFalse(any("Forbidden absolute path" in item for item in validate.errors))

    def test_placeholder_is_not_secret_but_secret_is_detected(self) -> None:
        write_text(self.root / "placeholder.txt", "CONTEXT7_API_KEY=\n")
        write_text(self.root / "secret.txt", "sk-" + ("A" * 24) + "\n")
        validate.validate_content_hygiene()
        self.assertTrue(any("secret.txt" in item and "Real-looking secret" in item for item in validate.errors))
        self.assertFalse(any("placeholder.txt" in item and "Real-looking secret" in item for item in validate.errors))

    def test_floating_version_detection(self) -> None:
        write_text(self.root / "Dockerfile", "FROM image:" + "lat" + "est" + "\n")
        validate.validate_content_hygiene()
        self.assertTrue(any("Floating version" in item for item in validate.errors))

    def test_final_newline_detection(self) -> None:
        write_bytes(self.root / "no-newline.txt", b"missing")
        validate.validate_content_hygiene()
        self.assertTrue(any("Missing final newline" in item for item in validate.errors))

    def test_crlf_detection(self) -> None:
        write_bytes(self.root / "crlf.txt", b"a\r\nb\r\n")
        validate.validate_content_hygiene()
        self.assertTrue(any("CRLF" in item for item in validate.errors))

    def test_binary_files_do_not_require_text_hygiene(self) -> None:
        write_bytes(self.root / "icon.ico", b"\x00\xff\x00\x01")
        validate.validate_content_hygiene()
        self.assertFalse(any("icon.ico" in item for item in validate.errors), validate.errors)

    def test_website_generated_and_vendor_trees_are_excluded(self) -> None:
        write_text(self.root / "website" / "node_modules" / "dependency.json", "{invalid\r\n")
        write_text(self.root / "website" / ".docusaurus" / "generated.json", "{invalid")
        write_text(self.root / "website" / "build" / "index.html", "no-final-newline")
        validate.parse_json_files()
        validate.validate_content_hygiene()
        self.assertEqual([], validate.errors)

    def write_policy_fixture(self, config_text: str) -> None:
        base = self.root / "installers" / "codex-ai-tooling"
        write_text(base / "templates" / "profiles" / "generic" / ".codex" / "config.toml", config_text)
        write_text(base / "templates" / "common" / ".ai" / "scripts" / "doctor.ps1", "$Pattern = 'install-' + 'browser'\n")
        write_text(base / "templates" / "common" / ".ai" / "scripts" / "bootstrap.ps1", "Write-Host ok\n")
        write_text(base / "fragments" / "gitignore.txt", "cache/\n")
        write_text(base / "fragments" / "gitattributes.txt", "*.txt text eol=lf\n")
        write_text(base / "fragments" / "agents.md", "AI tooling only.\n")
        write_text(base / "templates" / "common" / ".ai" / "tooling" / "versions.env", "RUST_BASE_IMAGE=rust:1.85.0-slim-bookworm@sha256:" + ("1" * 64) + "\nRUST_TOOLCHAIN_VERSION=1.85.0\n")
        rust_toolchain_placeholder = "{{" + "RUST_TOOLCHAIN_VERSION" + "}}"
        write_text(base / "templates" / "profiles" / "rust" / ".serena" / "project.yml", f"languages:\n- rust\nrust_toolchain_version: \"{rust_toolchain_placeholder}\"\n")
        write_text(base / "templates" / "profiles" / "rust" / ".ai" / "tooling" / "Dockerfile", "ARG RUST_TOOLCHAIN_VERSION\nRUN rustup component add rust-analyzer --toolchain \"${RUST_TOOLCHAIN_VERSION}\"\n")

    def valid_config(self) -> str:
        def array(values):
            return "[" + ", ".join(json.dumps(value) for value in values) + "]"
        return "\n".join([
            "[mcp_servers.serena]",
            "enabled_tools = " + array(validate.SERENA_TOOLS),
            "[mcp_servers.context7]",
            "enabled_tools = " + array(validate.CONTEXT7_TOOLS),
            "[mcp_servers.sentry]",
            "enabled_tools = " + array(validate.SENTRY_TOOLS),
            "",
        ])

    def test_exact_serena_allowlist_validation(self) -> None:
        config = self.valid_config().replace('"safe_delete_symbol"', '"safe_delete_symbol", "extra_tool"')
        self.write_policy_fixture(config)
        validate.validate_installer_policies()
        self.assertTrue(any("Unexpected serena allowlist" in item for item in validate.errors))

    def test_exact_sentry_readonly_allowlist_validation(self) -> None:
        config = self.valid_config().replace('"search_issues"', '"search_issues", "update_issue"')
        self.write_policy_fixture(config)
        validate.validate_installer_policies()
        self.assertTrue(any("Unexpected sentry allowlist" in item or "Write-capable Sentry" in item for item in validate.errors))

    def test_permanent_graphify_playwright_mcp_detection(self) -> None:
        config = self.valid_config() + "[mcp_servers.graphify]\nenabled_tools = []\n"
        self.write_policy_fixture(config)
        validate.validate_installer_policies()
        self.assertTrue(any("Graphify or Playwright" in item for item in validate.errors))

    def test_rust_supported_profile_requires_template(self) -> None:
        self.minimal_installer()
        rust_dir = self.root / "installers" / "codex-ai-tooling" / "templates" / "profiles" / "rust"
        rust_dir.rmdir()
        validate.validate_catalog()
        self.assertTrue(any("Supported profile has no template directory: rust" in item for item in validate.errors))

    def test_root_cargo_operations_detected(self) -> None:
        config = self.valid_config()
        self.write_policy_fixture(config)
        write_text(self.root / "installers" / "codex-ai-tooling" / "templates" / "common" / ".ai" / "scripts" / "bootstrap.sh", "cargo build\n")
        validate.validate_installer_policies()
        self.assertTrue(any("Cargo operation" in item for item in validate.errors))

    def test_rust_version_metadata_consistency(self) -> None:
        config = self.valid_config()
        self.write_policy_fixture(config)
        write_text(self.root / "installers" / "codex-ai-tooling" / "templates" / "common" / ".ai" / "tooling" / "versions.env", "RUST_TOOLCHAIN_VERSION=1.84.0\n")
        validate.validate_installer_policies()
        self.assertTrue(any("RUST_TOOLCHAIN_VERSION=1.85.0" in item or "RUST_BASE_IMAGE" in item for item in validate.errors))

    def test_agents_whole_file_template_is_rejected(self) -> None:
        config = self.valid_config()
        self.write_policy_fixture(config)
        write_text(self.root / "installers" / "codex-ai-tooling" / "templates" / "profiles" / "rust" / "AGENTS.md", "owned whole file\n")
        validate.validate_installer_policies()
        self.assertTrue(any("AGENTS.md must not be profile-owned" in item for item in validate.errors))

    def test_ai_tooling_rejects_project_folder_placeholder(self) -> None:
        self.copy_ai_fixture()
        path = self.root / ".ai/tooling/serena_config.yml"
        write_text(path, path.read_text().replace("/serena-state/projects/qbit-ai-toolkit", "/state/$projectFolderName"))
        validate.validate_ai_tooling()
        self.assertTrue(any("Global Serena configuration values" in item for item in validate.errors))

    def test_ai_rejects_duplicated_pses_layout(self) -> None:
        self.assert_ai_mutation(".ai/tooling/Dockerfile", lambda p: write_text(p, p.read_text().replace("duplicated PSES extraction layout", "layout unchecked")), "archive extraction contract")

    def test_ai_rejects_missing_pyright_resource_directory_seed(self) -> None:
        self.assert_ai_mutation(
            ".ai/tooling/Dockerfile",
            lambda p: write_text(
                p,
                p.read_text().replace(
                    "pyright.mkdir(parents=True, mode=0o755)\n",
                    "",
                    1,
                ),
            ),
            "Serena PyrightServer resource directory",
        )

    def test_ai_rejects_unbounded_pip_download(self) -> None:
        self.assert_ai_mutation(".ai/tooling/Dockerfile", lambda p: write_text(p, p.read_text().replace("--retries 10 ", "")), "bounded pip retries")

    def test_ai_rejects_unpinned_dockerfile_frontend(self) -> None:
        self.assert_ai_mutation(
            ".ai/tooling/Dockerfile",
            lambda p: write_text(
                p,
                p.read_text().replace(
                    "docker/dockerfile:1.7@sha256:a57df69d0ea827fb7266491f2813635de6f17269be881f696fbfdf2d83dda33e",
                    "docker/dockerfile:1.7",
                    1,
                ),
            ),
            "Dockerfile frontend must use the immutable 1.7 digest",
        )

    def test_ai_rejects_incomplete_verified_artifact_downloader(self) -> None:
        self.assert_ai_mutation(
            ".ai/tooling/build-download.py",
            lambda p: write_text(p, p.read_text().replace('"Content-Range"', '"Unchecked-Range"')),
            "Verified artifact downloader contract",
        )

    def test_ai_accepts_verified_debian_and_runtime_artifact_downloads(self) -> None:
        self.copy_ai_fixture()
        dockerfile = (self.root / ".ai/tooling/Dockerfile").read_text()
        self.assertNotIn("urlopen(url).read()", dockerfile)
        self.assertIn(
            "verified_archives.append(\n"
            "            downloader.download_verified_artifact(url, expected, destination)\n"
            "        )",
            dockerfile,
        )
        with mock.patch.object(
            validate.subprocess,
            "run",
            return_value=mock.Mock(stdout=validate.AI_INDEX_ENTRY),
        ):
            validate.validate_ai_tooling()
        self.assertEqual([], validate.errors)

    def test_ai_rejects_debian_single_shot_download(self) -> None:
        def mutate(path: Path) -> None:
            text = path.read_text().replace(
                "        destination = downloads / Path(pool_path).name\n",
                "        destination = downloads / Path(pool_path).name\n"
                "        unverified = urlopen(url).read()\n",
                1,
            )
            write_text(path, text)
        self.assert_ai_mutation(
            ".ai/tooling/Dockerfile",
            mutate,
            "Debian artifact heredoc must not use direct urlopen",
        )

    def test_ai_rejects_debian_downloader_copied_after_use(self) -> None:
        def mutate(path: Path) -> None:
            text = path.read_text().replace(
                "COPY .ai/tooling/build-download.py /tmp/qbit-download.py\n",
                "",
                1,
            )
            text = text.replace(
                "COPY .ai/tooling/runtime-entrypoint.py /tmp/qbit-runtime.py\n",
                "COPY .ai/tooling/build-download.py /tmp/qbit-download.py\n"
                "COPY .ai/tooling/runtime-entrypoint.py /tmp/qbit-runtime.py\n",
                1,
            )
            write_text(path, text)
        self.assert_ai_mutation(
            ".ai/tooling/Dockerfile",
            mutate,
            "Debian artifact downloader helper must be copied before use",
        )

    def test_ai_rejects_unverified_debian_download_call(self) -> None:
        self.assert_ai_mutation(
            ".ai/tooling/Dockerfile",
            lambda p: write_text(
                p,
                p.read_text().replace(
                    "verified_archives.append(\n"
                    "            downloader.download_verified_artifact(url, expected, destination)\n"
                    "        )",
                    "verified_archives.append(\n"
                    "            downloader.unverified_download(url, expected, destination)\n"
                    "        )",
                    1,
                ),
            ),
            "Every pinned Debian artifact must use build-download.py",
        )

    def test_ai_rejects_debian_install_before_all_downloads(self) -> None:
        def mutate(path: Path) -> None:
            install = '    subprocess.run(["dpkg", "-i", *map(str, sorted(verified_archives))], check=True)\n'
            text = path.read_text().replace(install, "", 1)
            text = text.replace("try:\n", install.lstrip() + "try:\n", 1)
            write_text(path, text)
        self.assert_ai_mutation(
            ".ai/tooling/Dockerfile",
            mutate,
            "All Debian artifacts must be verified before checked installation",
        )

    def test_ai_rejects_changed_debian_snapshot_lock(self) -> None:
        self.assert_ai_mutation(
            ".ai/tooling/debian-trixie-amd64.lock",
            lambda p: write_text(
                p,
                p.read_text().replace("20260720T000000Z", "20260721T000000Z", 1),
            ),
            "Immutable Debian snapshot lock mismatch",
        )

    def test_ai_rejects_runtime_artifact_single_shot_download(self) -> None:
        def mutate(path: Path) -> None:
            text = path.read_text().replace(
                "    name, version, url, expected = line.split()\n",
                "    name, version, url, expected = line.split()\n"
                "    unverified = urlopen(url).read()\n",
                1,
            )
            write_text(path, text)
        self.assert_ai_mutation(
            ".ai/tooling/Dockerfile",
            mutate,
            "Runtime artifact heredoc must not use direct urlopen",
        )

    def test_ai_rejects_extraction_before_verified_runtime_downloads(self) -> None:
        def mutate(path: Path) -> None:
            text = path.read_text().replace(
                "artifacts = {}\n",
                'artifacts = {}\n'
                'runtime.extract_tar_safely(Path("/tmp/unverified").read_bytes(), Path("/tmp/bad"), "r:gz")\n',
                1,
            )
            write_text(path, text)
        self.assert_ai_mutation(
            ".ai/tooling/Dockerfile",
            mutate,
            "Runtime artifact extraction must follow all verified downloads",
        )

    def test_ai_rejects_missing_runtime_downloader_copy_or_invocation(self) -> None:
        self.assert_ai_mutation(
            ".ai/tooling/Dockerfile",
            lambda p: write_text(
                p,
                p.read_text().replace(
                    "COPY .ai/tooling/build-download.py /tmp/qbit-download.py\n",
                    "",
                    1,
                ),
            ),
            "Runtime artifact downloader helper must be copied before use",
        )
        self.assert_ai_mutation(
            ".ai/tooling/Dockerfile",
            lambda p: write_text(
                p,
                p.read_text().replace(
                    "artifacts[name] = downloader.download_verified_artifact(",
                    "artifacts[name] = downloader.unverified_download(",
                    1,
                ),
            ),
            "Runtime artifact heredoc must load and invoke build-download.py",
        )

    def test_ai_rejects_graphify_host_bind(self) -> None:
        def mutate(path: Path) -> None:
            text = path.read_text().replace("- type: volume\n        source: graphify-output\n        target: /graphify-output\n        read_only: false", "- type: bind\n        source: ../../graphify-out\n        target: /graphify-output\n        read_only: false", 1)
            write_text(path, text)
        self.assert_ai_mutation(".ai/tooling/compose.yaml", mutate, "writable named-volume")

    def test_ai_rejects_missing_named_volume(self) -> None:
        self.assert_ai_mutation(".ai/tooling/compose.yaml", lambda p: write_text(p, p.read_text().replace("  graphify-output: {}\n", "")), "named-volume contract")

    def test_ai_rejects_missing_platform(self) -> None:
        self.assert_ai_mutation(".ai/tooling/compose.yaml", lambda p: write_text(p, p.read_text().replace("    platform: linux/amd64\n", "", 1)), "missing linux/amd64")

    def test_ai_rejects_persistent_doctor_home(self) -> None:
        self.assert_ai_mutation(
            ".ai/tooling/compose.yaml",
            lambda p: write_text(
                p,
                p.read_text().replace("      HOME: /tmp\n", "      HOME: /workspace\n", 1),
            ),
            "Doctor must use only ephemeral home and cache paths",
        )

    def test_ai_rejects_root_owned_doctor_serena_tmpfs(self) -> None:
        for target in (
            "/serena-state/logs",
            "/serena-state/projects/qbit-ai-toolkit/cache",
        ):
            def mutate(path: Path, target: str = target) -> None:
                text = path.read_text()
                line = next(
                    line for line in text.splitlines()
                    if line.strip().startswith(f"- {target}:")
                )
                write_text(path, text.replace(line, line.replace(",uid=10001,gid=10001", ""), 1))

            self.assert_ai_mutation(
                ".ai/tooling/compose.yaml",
                mutate,
                "Doctor private Serena tmpfs mounts must be owned by runtime UID/GID 10001",
            )

    def test_ai_rejects_wrong_mount_mode(self) -> None:
        def mutate(path: Path) -> None:
            text = path.read_text().replace("source: .\n        target: /workspace\n        read_only: true", "source: .\n        target: /workspace\n        read_only: false", 1)
            write_text(path, text)
        self.assert_ai_mutation(".ai/tooling/compose.yaml", mutate, "Wrong workspace mount mode")

    def test_ai_rejects_workspace_bind_outside_project_directory(self) -> None:
        self.assert_ai_mutation(
            ".ai/tooling/compose.yaml",
            lambda p: write_text(
                p,
                p.read_text().replace("source: .\n        target: /workspace", "source: ../..\n        target: /workspace", 1),
            ),
            "Workspace bind must use project-directory root",
        )

    def test_ai_rejects_changed_compose_build_context(self) -> None:
        self.assert_ai_mutation(
            ".ai/tooling/compose.yaml",
            lambda p: write_text(p, p.read_text().replace("      context: .\n", "      context: ../..\n", 1)),
            "Compose build context must remain project root",
        )

    def test_ai_rejects_weak_doctor(self) -> None:
        self.assert_ai_mutation(".ai/tooling/doctor.py", lambda p: write_text(p, p.read_text().replace('"mcp-allowlist"', '"weak-check"')), "Doctor validation category missing")

    def test_ai_rejects_missing_shared_mcp_stdio_contract(self) -> None:
        self.assert_ai_mutation(
            ".ai/tooling/Dockerfile",
            lambda p: write_text(
                p,
                p.read_text().replace(" .ai/tooling/mcp_stdio.py", "", 1),
            ),
            "shared MCP stdio client",
        )
        self.assert_ai_mutation(
            ".ai/tooling/mcp_stdio.py",
            lambda p: write_text(
                p,
                p.read_text().replace("MAX_MESSAGE_BYTES", "UNBOUNDED"),
            ),
            "Shared MCP stdio safety contract missing",
        )

    def test_ai_rejects_incomplete_global_config(self) -> None:
        self.assert_ai_mutation(".ai/tooling/serena_config.yml", lambda p: write_text(p, p.read_text().replace("token_count_estimator: CHAR_COUNT\n", "")), "Incomplete global Serena config")

    def test_ai_rejects_project_placeholder(self) -> None:
        self.assert_ai_mutation(".ai/tooling/serena_config.yml", lambda p: write_text(p, p.read_text().replace("/serena-state/projects/qbit-ai-toolkit", "/serena-state/projects/$projectFolderName")), "Global Serena configuration values")

    def test_ai_rejects_missing_language_server_path(self) -> None:
        self.assert_ai_mutation(".serena/project.yml", lambda p: write_text(p, p.read_text().replace("/opt/serena-language-servers/node_modules/.bin/pyright-langserver", "/missing/pyright")), "language-server contract")

    def test_ai_rejects_unsafe_archive_extractor(self) -> None:
        self.assert_ai_mutation(".ai/tooling/runtime-entrypoint.py", lambda p: write_text(p, p.read_text().replace("validate_archive_member_name", "unchecked_archive_name")), "archive extraction contract")

    def test_ai_rejects_missing_symlink_safe_copy(self) -> None:
        self.assert_ai_mutation(".ai/tooling/runtime-entrypoint.py", lambda p: write_text(p, p.read_text().replace("src_dir_fd", "unsafe_src")), "symlink-safe canonical file")

    def test_ai_rejects_missing_capability_checks(self) -> None:
        self.assert_ai_mutation(".ai/tooling/runtime-entrypoint.py", lambda p: write_text(p, p.read_text().replace("cap_last_cap", "fixed_cap_range")), "capability-drop check")

    def test_ai_rejects_missing_secure_prompt_templates_initialization(self) -> None:
        self.assert_ai_mutation(
            ".ai/tooling/runtime-entrypoint.py",
            lambda p: write_text(p, p.read_text().replace("        ensure_prompt_templates(STATE, uid, gid)\n", "")),
            "before privilege drop",
        )

    def test_ai_accepts_portable_prompt_templates_descriptor_contract(self) -> None:
        runtime = (REPO_ROOT / ".ai/tooling/runtime-entrypoint.py").read_text(encoding="utf-8")
        validate.validate_prompt_templates_runtime(runtime)
        self.assertEqual([], validate.errors)

    def test_ai_rejects_missing_prompt_templates_o_directory(self) -> None:
        self.assert_ai_mutation(
            ".ai/tooling/runtime-entrypoint.py",
            lambda p: write_text(
                p,
                p.read_text().replace(
                    'flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | O_NOFOLLOW',
                    "flags = os.O_RDONLY | O_NOFOLLOW",
                    1,
                ),
            ),
            "O_DIRECTORY protection",
        )

    def test_ai_rejects_missing_prompt_templates_o_nofollow(self) -> None:
        self.assert_ai_mutation(
            ".ai/tooling/runtime-entrypoint.py",
            lambda p: write_text(p, p.read_text().replace('O_NOFOLLOW = getattr(os, "O_NOFOLLOW", 0)', "O_NOFOLLOW = 0", 1)),
            "O_NOFOLLOW protection",
        )

    def test_ai_rejects_prompt_templates_open_without_secure_flags(self) -> None:
        self.assert_ai_mutation(
            ".ai/tooling/runtime-entrypoint.py",
            lambda p: write_text(p, p.read_text().replace("os.open(target, flags)", "os.open(target, os.O_RDONLY)", 1)),
            "O_DIRECTORY protection",
        )

    def test_ai_rejects_missing_prompt_templates_fchown(self) -> None:
        self.assert_ai_mutation(
            ".ai/tooling/runtime-entrypoint.py",
            lambda p: write_text(p, p.read_text().replace("        os.fchown(directory_fd, uid, gid)\n", "", 1)),
            "fchown'ed to runtime UID/GID",
        )

    def test_ai_rejects_broad_prompt_templates_mode(self) -> None:
        self.assert_ai_mutation(
            ".ai/tooling/runtime-entrypoint.py",
            lambda p: write_text(p, p.read_text().replace("os.fchmod(directory_fd, 0o700)", "os.fchmod(directory_fd, 0o777)")),
            "fchmod'ed to 0700",
        )

    def test_ai_rejects_missing_prompt_templates_fchmod(self) -> None:
        self.assert_ai_mutation(
            ".ai/tooling/runtime-entrypoint.py",
            lambda p: write_text(p, p.read_text().replace("        os.fchmod(directory_fd, 0o700)\n", "", 1)),
            "fchmod'ed to 0700",
        )

    def test_ai_rejects_prompt_templates_descriptor_close_outside_finally(self) -> None:
        def mutate(path: Path) -> None:
            text = path.read_text().replace(
                "        os.fchmod(directory_fd, 0o700)\n    finally:\n        os.close(directory_fd)",
                "        os.fchmod(directory_fd, 0o700)\n    except OSError:\n        os.close(directory_fd)\n        raise",
                1,
            )
            write_text(path, text)
        self.assert_ai_mutation(
            ".ai/tooling/runtime-entrypoint.py",
            mutate,
            "closed in finally",
        )

    def test_ai_rejects_prompt_templates_initialization_after_privilege_drop(self) -> None:
        def mutate(path: Path) -> None:
            text = path.read_text().replace("        ensure_prompt_templates(STATE, uid, gid)\n", "", 1)
            text = text.replace(
                "    drop_privileges(uid, gid)\n",
                "    drop_privileges(uid, gid)\n    ensure_prompt_templates(STATE, uid, gid)\n",
                1,
            )
            write_text(path, text)
        self.assert_ai_mutation(
            ".ai/tooling/runtime-entrypoint.py",
            mutate,
            "before privilege drop",
        )

    def test_ai_rejects_recursive_serena_state_chown(self) -> None:
        def mutate(path: Path) -> None:
            text = path.read_text().replace(
                '    target = state_root / "prompt_templates"\n',
                '    target = state_root / "prompt_templates"\n'
                '    for state_path in state_root.rglob("*"):\n'
                '        os.chown(state_path, uid, gid)\n',
                1,
            )
            write_text(path, text)
        self.assert_ai_mutation(
            ".ai/tooling/runtime-entrypoint.py",
            mutate,
            "Recursive chown of Serena state",
        )

    def test_ai_rejects_missing_bootstrap_preflight(self) -> None:
        self.assert_ai_mutation(".ai/scripts/bootstrap.sh", lambda p: write_text(p, p.read_text().replace("docker info", "echo info")), "Bootstrap preflight missing docker")

    def test_ai_rejects_posix_launcher_using_python(self) -> None:
        self.assert_ai_mutation("tests/e2e/test_ai_tooling_docker.sh", lambda p: write_text(p, p.read_text().replace("python3", "python")), "POSIX E2E launcher")

    def test_ai_rejects_project_local_bootstrap_installer_dependency(self) -> None:
        self.assert_ai_mutation(
            ".ai/scripts/bootstrap.sh",
            lambda p: write_text(p, p.read_text() + "\nsha256sum installers/codex-ai-tooling/README.md\n"),
            "Project-local bootstrap depends on installer scope",
        )


if __name__ == "__main__":
    unittest.main(verbosity=2)
