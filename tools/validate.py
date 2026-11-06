#!/usr/bin/env python3
"""Validate qbit-ai-toolkit metadata and repository hygiene.

This validator intentionally uses only the Python standard library. It does not
perform full JSON Schema validation; instead it implements explicit structural
checks for the current catalog and installer manifest contracts. The JSON Schema
files remain authoritative for future consumers with schema validators.
"""
from __future__ import annotations

import ast
import json
import hashlib
import os
import re
import subprocess
import sys
import tomllib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
VALID_CONSUMERS = {"cli", "console", "shared"}
VALID_KINDS = {"installer", "prompt", "docker-compose-template", "dockerfile-template", "repository-template", "ci-template", "agent-skill", "agent-policy", "script"}
SEMVER = re.compile(r"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:[-+][0-9A-Za-z.-]+)?$")
PLACEHOLDER = re.compile(r"\{\{[A-Z0-9_]+\}\}")
SECRET = re.compile(r"(sk-[A-Za-z0-9_-]{20,}|xox[baprs]-[A-Za-z0-9-]+|-----BEGIN [A-Z ]*PRIVATE KEY-----|AKIA[0-9A-Z]{16})")
REFERENCE_NAME = "hen" + "kel"
QBIT_NAME = "q" + "bit"
ABS_PATH = re.compile(
    r"(D:\\Projects\\" + REFERENCE_NAME
    + r"|D:\\Projects\\" + QBIT_NAME
    + r"|C:\\" + "Users" + r"\\[^\\]+\\|/" + "Users" + r"/[^/]+/|/" + "home" + r"/[^/]+/)",
    re.IGNORECASE,
)
FLOATING = re.compile(r"(:" + "lat" + r"est\b|['\"]" + "lat" + r"est['\"]|==\s*" + "lat" + r"est\b)", re.IGNORECASE)
BROWSER_INSTALL = re.compile(r"(install-browser|playwright\s+install|--with-deps|chromium|chrome)", re.IGNORECASE)
ROOT_DEP_INSTALL = re.compile(r"(pnpm\s+install|yarn\s+install|bun\s+install|npm\s+install)", re.IGNORECASE)
ROOT_CARGO_OPERATION = re.compile(r"cargo\s+(build|fetch|install)", re.IGNORECASE)
SERENA_TOOLS = ["get_symbols_overview", "find_symbol", "find_referencing_symbols", "find_implementations", "find_declaration", "get_diagnostics_for_file", "get_diagnostics_for_symbol", "replace_symbol_body", "insert_after_symbol", "insert_before_symbol", "rename_symbol", "safe_delete_symbol"]
SENTRY_TOOLS = ["find_organizations", "find_projects", "get_sentry_resource", "search_events", "search_issues"]
CONTEXT7_TOOLS = ["resolve-library-id", "query-docs"]
ALLOW_ABSOLUTE_EXAMPLES = {"D:\\Projects\\Example\\Backend", "/projects/example/backend"}
ABSOLUTE_PATH_DOCUMENTATION_PREFIXES = (
    "docs/ai-tools/codexpro/",
    "website/i18n/fa/docusaurus-plugin-content-docs/current/ai-tools/codexpro/",
)
AI_INDEX_ENTRY = "100644 a748023e65eac08492156379097aadfdde8ea686 0\t.gitignore"
# The Toolkit is not an installer target. Its self-bootstrap runtime stays at a
# reviewed release while the canonical installer templates develop independently.
# Upgrade this pin only after explicitly reviewing the root runtime upgrade;
# never derive trusted hashes from the working tree or installed-state files.
AI_CONTEXT_SELF_BOOTSTRAP_VERSION = "1.2.9"
AI_CONTEXT_SELF_BOOTSTRAP_SHA256 = {
    "context.ps1": "567a3b106ba8a5b4c0dc210fbee3fd916b1af032f6202db749c6de9b3f8907fd",
    "context.py": "ad48c5105f738827c9a106183195076e4065b170bdeb19af75f99cc714d411e2",
    "context.sh": "6138e0013de4d2c538240348891507a4927bcdbaf71b7da04116ca9a344b9e67",
    "context-transfer.ps1": "36c4a1646ba5d2547af825bab7fea9076a20ad921b51cc648a3f743058c178f3",
}
AI_GLOBAL_KEYS = {
    "language_backend", "line_ending", "gui_log_window", "web_dashboard", "web_dashboard_open_on_launch",
    "web_dashboard_interface", "web_dashboard_listen_address", "jetbrains_plugin_server_address", "log_level",
    "trace_lsp_communication", "ls_specific_settings", "ignored_paths", "read_only_memory_patterns",
    "ignored_memory_patterns", "tool_timeout", "excluded_tools", "included_optional_tools", "fixed_tools",
    "base_modes", "default_modes", "default_max_tool_answer_chars", "token_count_estimator", "symbol_info_budget",
    "project_serena_folder_location", "projects",
}
AI_PROJECT_KEYS = {
    "project_name", "languages", "encoding", "line_ending", "language_backend",
    "ignore_all_files_in_gitignore", "ls_specific_settings", "additional_workspace_folders", "ignored_paths",
    "read_only", "excluded_tools", "included_optional_tools", "fixed_tools", "default_modes", "added_modes",
    "initial_prompt", "symbol_info_budget", "read_only_memory_patterns", "ignored_memory_patterns",
}

errors: list[str] = []

def error(message: str) -> None:
    errors.append(message)


def rel(path: Path) -> str:
    return path.relative_to(ROOT).as_posix()


def read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def _yaml_scalar(value: str):
    value = value.strip()
    if value in {"", "null", "~"}:
        return None
    if value in {"true", "false"}:
        return value == "true"
    if value in {"{}", "[]"}:
        return {} if value == "{}" else []
    if value.startswith(('"', "'")):
        if value[0] == '"':
            return json.loads(value)
        if not value.endswith("'"):
            raise ValueError(f"unterminated YAML scalar: {value}")
        return value[1:-1].replace("''", "'")
    if re.fullmatch(r"-?[0-9]+", value):
        return int(value)
    return value


def parse_simple_yaml(text: str):
    """Parse the repository's deterministic block-style YAML subset."""
    tokens: list[tuple[int, str]] = []
    raw_lines = text.splitlines()
    index = 0
    while index < len(raw_lines):
        raw = raw_lines[index]
        index += 1
        if not raw.strip() or raw.lstrip().startswith("#"):
            continue
        if "\t" in raw[: len(raw) - len(raw.lstrip())]:
            raise ValueError("tabs are forbidden in YAML indentation")
        indent = len(raw) - len(raw.lstrip(" "))
        content = raw[indent:]
        if content.endswith(": >-") or content.endswith(": |-"):
            key, marker = content.rsplit(" ", 1)
            folded: list[str] = []
            while index < len(raw_lines):
                candidate = raw_lines[index]
                candidate_indent = len(candidate) - len(candidate.lstrip(" "))
                if candidate.strip() and candidate_indent <= indent:
                    break
                index += 1
                if candidate.strip():
                    folded.append(candidate.strip())
            content = key + " " + json.dumps((" " if marker == ">-" else "\n").join(folded))
        tokens.append((indent, content))
    if not tokens:
        return None

    def parse_block(position: int, indent: int):
        is_list = tokens[position][1].startswith("- ") or tokens[position][1] == "-"
        container = [] if is_list else {}
        while position < len(tokens):
            current_indent, content = tokens[position]
            if current_indent < indent:
                break
            if current_indent != indent:
                raise ValueError(f"unexpected YAML indentation near: {content}")
            if is_list:
                if not content.startswith("-"):
                    break
                remainder = content[1:].strip()
                if not remainder:
                    if position + 1 >= len(tokens) or tokens[position + 1][0] <= indent:
                        container.append(None); position += 1; continue
                    value, position = parse_block(position + 1, tokens[position + 1][0])
                    container.append(value); continue
                mapping_match = re.match(r"^([^:]+):(?:\s+(.*)|$)", remainder)
                if mapping_match:
                    key = mapping_match.group(1)
                    raw_value = mapping_match.group(2) or ""
                    item = {key.strip(): _yaml_scalar(raw_value)}
                    position += 1
                    if position < len(tokens) and tokens[position][0] > indent:
                        extra, position = parse_block(position, tokens[position][0])
                        if not isinstance(extra, dict):
                            raise ValueError("YAML list mapping continuation must be a mapping")
                        item.update(extra)
                    container.append(item); continue
                container.append(_yaml_scalar(remainder)); position += 1; continue
            if content.startswith("-") or ":" not in content:
                raise ValueError(f"expected YAML mapping entry: {content}")
            key, raw_value = content.split(":", 1)
            key = key.strip(); raw_value = raw_value.strip()
            position += 1
            if not raw_value and position < len(tokens) and tokens[position][0] > indent:
                value, position = parse_block(position, tokens[position][0])
            else:
                value = _yaml_scalar(raw_value)
            if key in container:
                raise ValueError(f"duplicate YAML key: {key}")
            container[key] = value
        return container, position

    parsed, final = parse_block(0, tokens[0][0])
    if final != len(tokens):
        raise ValueError("unparsed YAML content")
    return parsed


def all_files() -> list[Path]:
    excluded_dirs = {".git", ".idea", "__pycache__", "node_modules", ".docusaurus"}
    excluded_suffixes = {".pyc", ".pyo"}
    files: list[Path] = []
    for current_root, dirs, filenames in os.walk(ROOT):
        current = Path(current_root)
        relative_dir = current.relative_to(ROOT)
        dirs[:] = [
            name
            for name in dirs
            if name not in excluded_dirs
            and not (relative_dir == Path("website") and name in {"build", ".cache-loader", ".bun-tmp", "playwright-report", "test-results", "coverage"})
            and not (relative_dir == Path(".ai/context") and name == "cache")
        ]
        for filename in filenames:
            path = current / filename
            relative_path = path.relative_to(ROOT)
            if relative_path.parts and relative_path.parts[0] == ".ai-bridge" and filename not in {"README.md", ".gitignore"}:
                continue
            if path.suffix not in excluded_suffixes:
                files.append(path)
    return files


def parse_json_files() -> None:
    for path in all_files():
        if path.suffix == ".json":
            try:
                json.loads(read_text(path))
            except Exception as exc:  # noqa: BLE001
                error(f"Invalid JSON in {rel(path)}: {exc}")


def validate_catalog() -> None:
    catalog_path = ROOT / "catalog.json"
    try:
        catalog = json.loads(read_text(catalog_path))
    except Exception as exc:  # noqa: BLE001
        error(f"Cannot parse catalog.json: {exc}")
        return
    for key in ["$schema", "schemaVersion", "name", "assets"]:
        if key not in catalog:
            error(f"catalog.json missing {key}")
    if catalog.get("schemaVersion") != "1.0":
        error("catalog.json schemaVersion must be 1.0")
    ids: set[str] = set()
    for asset in catalog.get("assets", []):
        asset_id = asset.get("id")
        if asset_id in ids:
            error(f"Duplicate asset id: {asset_id}")
        ids.add(asset_id)
        for key in ["id", "kind", "version", "path", "consumers", "status", "description"]:
            if key not in asset:
                error(f"Asset {asset_id} missing {key}")
        if asset.get("kind") not in VALID_KINDS:
            error(f"Asset {asset_id} has invalid kind")
        if not SEMVER.match(str(asset.get("version", ""))):
            error(f"Asset {asset_id} has invalid semantic version")
        consumers = set(asset.get("consumers", []))
        if not consumers or not consumers <= VALID_CONSUMERS:
            error(f"Asset {asset_id} has invalid consumers")
        asset_path = ROOT / asset.get("path", "")
        if not asset_path.exists():
            error(f"Asset path does not exist: {asset.get('path')}")
        if asset.get("kind") == "installer":
            validate_installer_asset(asset, asset_path)


def validate_installer_asset(asset: dict, asset_path: Path) -> None:
    manifest_path = asset_path / "manifest.json"
    version_path = asset_path / "VERSION"
    if not manifest_path.exists():
        error(f"Installer missing manifest: {rel(asset_path)}")
        return
    manifest = json.loads(read_text(manifest_path))
    version = read_text(version_path).strip() if version_path.exists() else ""
    if manifest.get("version") != version:
        error(f"Manifest version does not equal VERSION in {rel(asset_path)}")
    if asset.get("version") != manifest.get("version"):
        error(f"Catalog version does not equal manifest version for {asset.get('id')}")
    if manifest.get("id") != asset.get("id"):
        error(f"Catalog id does not equal manifest id for {asset.get('id')}")
    if set(manifest.get("consumers", [])) - VALID_CONSUMERS:
        error(f"Manifest consumers invalid for {asset.get('id')}")
    for profile in manifest.get("supportedProfiles", []):
        if not (asset_path / "templates" / "profiles" / profile).exists():
            error(f"Supported profile has no template directory: {profile}")
    if asset.get("id") == "installer.codex-ai-tooling" and "rust" not in manifest.get("supportedProfiles", []):
        error(f"Codex AI Tooling installer manifest must declare rust supported profile: {rel(asset_path)}")
    for group in ["entrypoints", "verifiers", "uninstallers"]:
        for entry in manifest.get(group, {}).values():
            if not (asset_path / entry).exists():
                error(f"Declared {group} file is missing: {entry}")


def validate_content_hygiene() -> None:
    for path in all_files():
        data = path.read_bytes()
        name = rel(path)
        try:
            text = data.decode("utf-8")
        except UnicodeDecodeError:
            continue
        if data and not data.endswith(b"\n"):
            error(f"Missing final newline: {name}")
        if b"\r\n" in data:
            error(f"CRLF line ending found: {name}")
        lower = text.lower()
        if REFERENCE_NAME in lower:
            error(f"Hardcoded reference-project value found: {name}")
        if SECRET.search(text):
            error(f"Real-looking secret found: {name}")
        if FLOATING.search(text):
            error(f"Floating version selector found: {name}")
        if ABS_PATH.search(text) and not name.startswith(ABSOLUTE_PATH_DOCUMENTATION_PREFIXES):
            cleaned = text
            for allowed in ALLOW_ABSOLUTE_EXAMPLES:
                cleaned = cleaned.replace(allowed, "")
            if ABS_PATH.search(cleaned):
                error(f"Forbidden absolute path found: {name}")
        if PLACEHOLDER.search(text):
            if not ("/templates/" in name or name in {"installers/codex-ai-tooling/README.md", "docs/asset-contract.md", "website/i18n/fa/docusaurus-plugin-content-docs/current/asset-contract.md", "installers/codex-ai-tooling/install.sh"}):
                error(f"Unresolved placeholder outside template documentation: {name}")


def validate_installer_policies() -> None:
    installer = ROOT / "installers" / "codex-ai-tooling"
    malformed_placeholder = re.compile(r"(?<![\{\$])\{[A-Z][A-Z0-9_]+\}(?!\})")
    for template in (installer / "templates").rglob("*"):
        if template.is_file():
            text = read_text(template)
            if malformed_placeholder.search(text):
                error(f"Malformed single-brace placeholder in template: {rel(template)}")
    for path in installer.glob("templates/common/.ai/scripts/doctor.*"):
        # The doctor builds its forbidden pattern dynamically. It must not contain
        # literal command strings that would self-match during runtime checks.
        text = read_text(path)
        if "install-browser" in text or "playwright install" in text or "chromium" in text or "chrome" in text:
            error(f"Doctor template contains literal browser-install token: {rel(path)}")
    for path in installer.glob("templates/common/.ai/scripts/bootstrap.*"):
        text = read_text(path)
        if BROWSER_INSTALL.search(text):
            error(f"Bootstrap template contains browser installation command: {rel(path)}")
        if ROOT_DEP_INSTALL.search(text):
            error(f"Bootstrap template contains root dependency installation command: {rel(path)}")
        if ROOT_CARGO_OPERATION.search(text):
            error(f"Bootstrap template contains target-root Cargo operation: {rel(path)}")
    for path in installer.glob("templates/common/.ai/scripts/doctor.*"):
        text = read_text(path)
        if ROOT_CARGO_OPERATION.search(text):
            error(f"Doctor template contains target-root Cargo operation: {rel(path)}")
    for fragment in [installer / "fragments" / "gitignore.txt", installer / "fragments" / "gitattributes.txt"]:
        text = read_text(fragment)
        if text.count("qbit-toolkit:codex-ai-tooling") != 0:
            error(f"Managed marker must not be embedded in fragment body: {rel(fragment)}")
    agents_fragment = installer / "fragments" / "agents.md"
    if not agents_fragment.exists():
        error("AGENTS managed-block fragment is missing")
    else:
        text = read_text(agents_fragment)
        if "<!-- >>> qbit-toolkit:codex-ai-tooling -->" in text or "<!-- <<< qbit-toolkit:codex-ai-tooling -->" in text:
            error("AGENTS managed markers must not be embedded in fragment body")
    for profile_agents in installer.glob("templates/profiles/*/AGENTS.md"):
        error(f"AGENTS.md must not be profile-owned as a whole file: {rel(profile_agents)}")
    versions = read_text(installer / "templates/common/.ai/tooling/versions.env")
    if "RUST_TOOLCHAIN_VERSION=1.85.0" not in versions:
        error("versions.env must pin RUST_TOOLCHAIN_VERSION=1.85.0")
    if not re.search(r"^RUST_BASE_IMAGE=rust:1\.85\.0-slim-bookworm@sha256:[0-9a-f]{64}$", versions, re.MULTILINE):
        error("versions.env must pin RUST_BASE_IMAGE with exact digest")
    for config in installer.glob("templates/profiles/*/.codex/config.toml"):
        text = read_text(config)
        if re.search(r"mcp_servers\.(graphify|playwright)", text):
            error(f"Graphify or Playwright configured as MCP server: {rel(config)}")
        if re.search(r"update_issue|execute_sentry_tool|analyze_issue_with_seer", text):
            error(f"Write-capable Sentry tool exposed: {rel(config)}")
        check_tool_array(text, "serena", SERENA_TOOLS, config)
        check_tool_array(text, "sentry", SENTRY_TOOLS, config)
        check_tool_array(text, "context7", CONTEXT7_TOOLS, config)
    rust_serena = installer / "templates/profiles/rust/.serena/project.yml"
    if not rust_serena.exists():
        error("Rust profile Serena project template is missing")
    else:
        text = read_text(rust_serena)
        if not re.search(r"(?m)^-\s*rust\s*$", text):
            error("Rust profile Serena project must declare rust language")
        if "{{" + "RUST_TOOLCHAIN_VERSION" + "}}" not in text:
            error("Rust profile Serena project must reference RUST_TOOLCHAIN_VERSION")
    rust_docker = installer / "templates/profiles/rust/.ai/tooling/Dockerfile"
    if not rust_docker.exists():
        error("Rust profile Dockerfile is missing")
    else:
        text = read_text(rust_docker)
        if "rustup component add rust-analyzer" not in text or "RUST_TOOLCHAIN_VERSION" not in text:
            error("Rust profile Dockerfile must install rust-analyzer for the pinned rustup toolchain")


def validate_ai_context_continuity_v2() -> None:
    installer = ROOT / "installers" / "ai-context"
    required_paths = {
        "version": installer / "VERSION",
        "readme": installer / "README.md",
        "changelog": installer / "CHANGELOG.md",
        "member_agents": installer / "templates" / "common" / "member" / "agents-block.md.tpl",
        "member_ps": installer / "templates" / "common" / "member" / "context.ps1",
        "member_py": installer / "templates" / "common" / "member" / "context.py",
        "member_sh": installer / "templates" / "common" / "member" / "context.sh",
        "member_transfer": installer / "templates" / "common" / "member" / "context-transfer.ps1",
        "central_docs": installer / "templates" / "common" / "central" / "docs" / "context-automation.md.tpl",
        "checkpoint_schema": installer / "templates" / "common" / "central" / "schemas" / "checkpoint.schema.json",
        "continuity_ps": installer / "templates" / "common" / "central" / "tooling" / "context-continuity.ps1",
        "continuity_py": installer / "templates" / "common" / "central" / "tooling" / "context-lifecycle.py",
        "root_agents": ROOT / "AGENTS.md",
        "root_context": ROOT / "AI_CONTEXT.md",
        "root_ps": ROOT / ".ai" / "context" / "context.ps1",
        "root_py": ROOT / ".ai" / "context" / "context.py",
        "root_sh": ROOT / ".ai" / "context" / "context.sh",
        "root_transfer": ROOT / ".ai" / "context" / "context-transfer.ps1",
        "canonical_docs": ROOT / "docs" / "ai-tooling" / "continuity-v2.md",
    }
    missing = [rel(path) for path in required_paths.values() if not path.exists()]
    if missing:
        for name in missing:
            error(f"Continuity v2 contract file is missing: {name}")
        return

    version = read_text(required_paths["version"]).strip()
    readme = read_text(required_paths["readme"])
    changelog = read_text(required_paths["changelog"])
    root_agents = read_text(required_paths["root_agents"])
    root_context = read_text(required_paths["root_context"])
    member_agents = read_text(required_paths["member_agents"])
    member_ps = read_text(required_paths["member_ps"])
    member_py = read_text(required_paths["member_py"])
    central_docs = read_text(required_paths["central_docs"])
    canonical_docs = read_text(required_paths["canonical_docs"])
    checkpoint_schema = json.loads(read_text(required_paths["checkpoint_schema"]))
    continuity_ps = read_text(required_paths["continuity_ps"])
    continuity_py = read_text(required_paths["continuity_py"])

    for root_key, template_key in (
        ("root_ps", "member_ps"),
        ("root_py", "member_py"),
        ("root_sh", "member_sh"),
        ("root_transfer", "member_transfer"),
    ):
        root_path = required_paths[root_key]
        root_bytes = root_path.read_bytes()
        if hashlib.sha256(root_bytes).hexdigest() != AI_CONTEXT_SELF_BOOTSTRAP_SHA256[root_path.name]:
            error(f"Toolkit root AI Context runtime drifted from canonical template for self-bootstrap {AI_CONTEXT_SELF_BOOTSTRAP_VERSION}: {rel(root_path)}")
        if version == AI_CONTEXT_SELF_BOOTSTRAP_VERSION and root_bytes != required_paths[template_key].read_bytes():
            error(f"AI Context template differs from pinned self-bootstrap {version}: {rel(required_paths[template_key])}")

    if f"current stable release is `{version}`" not in readme:
        error("AI Context README stable release does not match VERSION")
    if f"## {version}" not in changelog:
        error("AI Context changelog is missing the current VERSION section")
    if f"current stable release is `{version}`" not in canonical_docs:
        error("Continuity v2 canonical docs stable release does not match VERSION")

    required_policy_tokens = (
        "`schemaVersion: 2`",
        "`continuity.mode: tracked`",
        "`continuity.mode: snapshot`",
        "`continuity.validationLedger[]`",
        "`export`, `import`, and `reconnect`",
    )
    for token in required_policy_tokens:
        if token not in root_agents:
            error(f"Toolkit AGENTS Continuity v2 policy missing: {token}")
        if token not in member_agents:
            error(f"Managed member AGENTS Continuity v2 policy missing: {token}")
    if "checkpoint JSON must use `schemaVersion: 1`" in root_agents:
        error("Toolkit AGENTS still requires legacy checkpoint schemaVersion 1")
    for token in ("Continuity v2 (`schemaVersion: 2`)", "tracked workstream", "worktree fingerprint", "`export`, `import`, and `reconnect`"):
        if token not in root_context:
            error(f"Toolkit AI_CONTEXT Continuity v2 entry point missing: {token}")

    for token in (
        "`nextAction` is a pointer into durable structured work",
        "Several files use a field named `schemaVersion`, but they are independent contracts",
        "silent disappearance of unresolved work-item IDs",
        "OFFLINE_IMPORTED_CONTEXT",
        "Reconnect never auto-merges, rebases, resets, or force-pushes",
    ):
        if token not in canonical_docs:
            error(f"Continuity v2 canonical docs contract missing: {token}")

    for token in ("## Continuity v2", "schemaVersion: 2", "workstreams/archive/", "validation/repositories/", "## Membership and reconciliation", "`audit`", "never auto-merges, rebases, resets, or force-pushes", "## Offline portability"):
        if token not in central_docs:
            error(f"Generated central Continuity v2 documentation missing: {token}")

    ps_actions = "[ValidateSet('start', 'status', 'checkpoint', 'audit', 'export', 'import', 'reconnect')]"
    if ps_actions not in member_ps:
        error("PowerShell member launcher Continuity v2 action surface is incomplete")
    py_actions = ('{"start", "status", "checkpoint", "audit", "export", "import", "reconnect"}'
                  if version == AI_CONTEXT_SELF_BOOTSTRAP_VERSION else
                  '{"start", "status", "verify", "checkpoint", "audit", "export", "import", "reconnect"}')
    if py_actions not in member_py:
        error("Python/POSIX member launcher Continuity v2 action surface is incomplete")

    schema_versions = checkpoint_schema.get("properties", {}).get("schemaVersion", {}).get("enum", [])
    if set(schema_versions) != {1, 2}:
        error("Checkpoint schema must accept legacy v1 and Continuity v2 only")
    for token in ("schemaVersion 1 checkpoints must not include continuity", "schemaVersion 2 checkpoint requires continuity object"):
        if token not in continuity_ps or token not in continuity_py:
            error(f"Central lifecycle checkpoint compatibility contract missing: {token}")


def check_tool_array(text: str, server: str, expected: list[str], path: Path) -> None:
    match = re.search(rf"(?ms)\[mcp_servers\.{server}\].*?enabled_tools\s*=\s*\[(.*?)\]", text)
    if not match:
        error(f"Missing enabled_tools for {server}: {rel(path)}")
        return
    tools = re.findall(r'"([^"]+)"', match.group(1))
    if sorted(tools) != sorted(expected):
        error(f"Unexpected {server} allowlist in {rel(path)}: {tools}")


def validate_runtime_artifact_download(dockerfile: str, downloader: str) -> None:
    helper_copy = "COPY .ai/tooling/build-download.py /tmp/qbit-download.py"
    lock_copy = "COPY .ai/tooling/serena-artifacts.lock /tmp/artifacts.lock"
    following_copy = "COPY --from=language-servers /usr/local/bin/node /usr/local/bin/node"
    run_anchor = "RUN python - <<'PY'\n"
    heredoc_end = "\nPY\n"

    helper_copy_position = dockerfile.find(helper_copy)
    lock_position = dockerfile.find(lock_copy)
    following_position = dockerfile.find(following_copy)
    if (
        helper_copy_position < 0
        or lock_position < 0
        or following_position < 0
        or helper_copy_position >= lock_position
        or lock_position >= following_position
    ):
        error("Runtime artifact downloader helper must be copied before use")
        return

    run_position = dockerfile.find(run_anchor, lock_position + len(lock_copy), following_position)
    if run_position < 0:
        error("Runtime artifact Python heredoc is missing")
        return
    source_start = run_position + len(run_anchor)
    source_end = dockerfile.find(heredoc_end, source_start, following_position)
    if source_end < 0:
        error("Runtime artifact Python heredoc boundary is invalid")
        return
    artifact_source = dockerfile[source_start:source_end]

    try:
        artifact_tree = ast.parse(artifact_source)
        downloader_tree = ast.parse(downloader)
    except SyntaxError as exc:
        error(f"Runtime artifact downloader Python is invalid: {exc}")
        return

    direct_reads = [
        node for node in ast.walk(artifact_tree)
        if isinstance(node, ast.Call)
        and isinstance(node.func, ast.Attribute)
        and node.func.attr == "read"
        and isinstance(node.func.value, ast.Call)
        and (
            isinstance(node.func.value.func, ast.Name)
            and node.func.value.func.id == "urlopen"
        )
    ]
    if direct_reads:
        error("Runtime artifact heredoc must not use direct urlopen(...).read()")

    download_calls = [
        node for node in ast.walk(artifact_tree)
        if isinstance(node, ast.Call)
        and isinstance(node.func, ast.Attribute)
        and isinstance(node.func.value, ast.Name)
        and node.func.value.id == "downloader"
        and node.func.attr == "download_verified_artifact"
    ]
    extraction_calls = [
        node for node in ast.walk(artifact_tree)
        if isinstance(node, ast.Call)
        and isinstance(node.func, ast.Attribute)
        and node.func.attr in {"extract_tar_safely", "extract_zip_safely"}
    ]
    lock_loops = [
        node for node in ast.walk(artifact_tree)
        if isinstance(node, ast.For) and "/tmp/artifacts.lock" in ast.unparse(node.iter)
    ]
    helper_loaded = any(
        isinstance(node, ast.Constant) and node.value == "/tmp/qbit-download.py"
        for node in ast.walk(artifact_tree)
    )
    if not helper_loaded or len(download_calls) != 1 or len(lock_loops) != 1:
        error("Runtime artifact heredoc must load and invoke build-download.py")
    elif download_calls[0] not in list(ast.walk(lock_loops[0])):
        error("Every pinned runtime artifact must use the verified downloader loop")

    if not extraction_calls:
        error("Runtime artifact heredoc must perform checked extraction")
    elif not download_calls or max(call.lineno for call in download_calls) >= min(call.lineno for call in extraction_calls):
        error("Runtime artifact extraction must follow all verified downloads")

    pyright_assignments = [
        node for node in ast.walk(artifact_tree)
        if isinstance(node, ast.Assign)
        and any(isinstance(target, ast.Name) and target.id == "pyright" for target in node.targets)
        and isinstance(node.value, ast.BinOp)
        and isinstance(node.value.op, ast.Div)
        and isinstance(node.value.left, ast.Name)
        and node.value.left.id == "static"
        and isinstance(node.value.right, ast.Constant)
        and node.value.right.value == "PyrightServer"
    ]
    pyright_mkdir = [
        node for node in ast.walk(artifact_tree)
        if isinstance(node, ast.Call)
        and isinstance(node.func, ast.Attribute)
        and isinstance(node.func.value, ast.Name)
        and node.func.value.id == "pyright"
        and node.func.attr == "mkdir"
        and any(
            keyword.arg == "parents"
            and isinstance(keyword.value, ast.Constant)
            and keyword.value.value is True
            for keyword in node.keywords
        )
    ]
    if len(pyright_assignments) != 1 or len(pyright_mkdir) != 1:
        error("Runtime image must seed the Serena PyrightServer resource directory")

    for call in extraction_calls:
        verified_argument = (
            bool(call.args)
            and isinstance(call.args[0], ast.Call)
            and isinstance(call.args[0].func, ast.Attribute)
            and call.args[0].func.attr == "read_bytes"
            and isinstance(call.args[0].func.value, ast.Subscript)
            and isinstance(call.args[0].func.value.value, ast.Name)
            and call.args[0].func.value.value.id == "artifacts"
        )
        if not verified_argument:
            error("Runtime artifact extraction must consume only verified artifact paths")
            break

    parent_by_child = {
        child: parent
        for parent in ast.walk(artifact_tree)
        for child in ast.iter_child_nodes(parent)
    }
    for call in download_calls:
        ancestor = parent_by_child.get(call)
        while ancestor is not None and not isinstance(ancestor, ast.For):
            if isinstance(ancestor, ast.Try):
                error("Verified runtime artifact failures must propagate before extraction")
                break
            ancestor = parent_by_child.get(ancestor)

    helper_functions = [
        node for node in downloader_tree.body
        if isinstance(node, ast.FunctionDef) and node.name == "download_verified_artifact"
    ]
    if len(helper_functions) != 1:
        error("Verified artifact downloader function is missing")
        return
    helper_function = helper_functions[0]
    hash_lines = [
        node.lineno for node in ast.walk(helper_function)
        if isinstance(node, ast.Call)
        and isinstance(node.func, ast.Name)
        and node.func.id == "_sha256"
    ]
    replace_lines = [
        node.lineno for node in ast.walk(helper_function)
        if isinstance(node, ast.Call)
        and isinstance(node.func, ast.Attribute)
        and isinstance(node.func.value, ast.Name)
        and node.func.value.id == "os"
        and node.func.attr == "replace"
    ]
    if not hash_lines or not replace_lines or max(hash_lines) >= min(replace_lines):
        error("SHA-256 verification must precede atomic artifact publication")


def validate_debian_artifact_download(dockerfile: str, lock_bytes: bytes) -> None:
    """Validate the immutable Debian artifact fetch/install boundary."""
    helper_copy = "COPY .ai/tooling/build-download.py /tmp/qbit-download.py"
    lock_copy = "COPY .ai/tooling/debian-trixie-amd64.lock /tmp/debian.lock"
    following_copy = "COPY .ai/tooling/runtime-entrypoint.py /tmp/qbit-runtime.py"
    run_anchor = "RUN python - <<'PY'\n"
    heredoc_end = "\nPY\n"

    if hashlib.sha256(lock_bytes).hexdigest() != "10fefc8a8d8f5159ef3dd353fcb4e792d9a16d1ddfe19d7aa81f682446d2c40f":
        error("Immutable Debian snapshot lock mismatch")
    lock_lines = lock_bytes.decode("utf-8").splitlines()
    if (
        len(lock_lines) != 8
        or lock_lines[0] != "# snapshot=20260720T000000Z architecture=amd64"
        or any(len(line.split()) != 5 for line in lock_lines[1:])
    ):
        error("Debian snapshot lock must contain exactly seven pinned amd64 artifacts")

    helper_position = dockerfile.find(helper_copy)
    lock_position = dockerfile.find(lock_copy)
    following_position = dockerfile.find(following_copy)
    if (
        helper_position < 0
        or lock_position < 0
        or following_position < 0
        or helper_position >= lock_position
        or lock_position >= following_position
    ):
        error("Debian artifact downloader helper must be copied before use")
        return

    run_position = dockerfile.find(run_anchor, lock_position + len(lock_copy), following_position)
    if run_position < 0:
        error("Debian artifact Python heredoc is missing")
        return
    source_start = run_position + len(run_anchor)
    source_end = dockerfile.find(heredoc_end, source_start, following_position)
    if source_end < 0:
        error("Debian artifact Python heredoc boundary is invalid")
        return
    source = dockerfile[source_start:source_end]
    try:
        tree = ast.parse(source)
    except SyntaxError as exc:
        error(f"Debian artifact downloader Python is invalid: {exc}")
        return

    direct_reads = [
        node for node in ast.walk(tree)
        if isinstance(node, ast.Call)
        and isinstance(node.func, ast.Attribute)
        and node.func.attr == "read"
        and isinstance(node.func.value, ast.Call)
        and isinstance(node.func.value.func, ast.Name)
        and node.func.value.func.id == "urlopen"
    ]
    if direct_reads:
        error("Debian artifact heredoc must not use direct urlopen(...).read()")

    helper_loaded = any(
        isinstance(node, ast.Constant) and node.value == "/tmp/qbit-download.py"
        for node in ast.walk(tree)
    )
    lock_loops = [
        node for node in ast.walk(tree)
        if isinstance(node, ast.For) and "/tmp/debian.lock" in ast.unparse(node.iter)
    ]
    download_calls = [
        node for node in ast.walk(tree)
        if isinstance(node, ast.Call)
        and isinstance(node.func, ast.Attribute)
        and isinstance(node.func.value, ast.Name)
        and node.func.value.id == "downloader"
        and node.func.attr == "download_verified_artifact"
    ]
    if not helper_loaded or len(lock_loops) != 1 or len(download_calls) != 1:
        error("Every pinned Debian artifact must use build-download.py")
        return
    lock_loop = lock_loops[0]
    download_call = download_calls[0]
    if download_call not in list(ast.walk(lock_loop)):
        error("Every pinned Debian artifact must use the verified downloader loop")

    destination_assignments = [
        node for node in ast.walk(lock_loop)
        if isinstance(node, ast.Assign)
        and any(isinstance(target, ast.Name) and target.id == "destination" for target in node.targets)
        and ast.unparse(node.value) == "downloads / Path(pool_path).name"
    ]
    valid_arguments = (
        len(download_call.args) == 3
        and isinstance(download_call.args[0], ast.Name)
        and download_call.args[0].id == "url"
        and isinstance(download_call.args[1], ast.Name)
        and download_call.args[1].id == "expected"
        and isinstance(download_call.args[2], ast.Name)
        and download_call.args[2].id == "destination"
        and bool(destination_assignments)
    )
    if not valid_arguments:
        error("Debian verified downloader must receive the pinned URL, hash, and deterministic destination")

    parents = {
        child: parent
        for parent in ast.walk(tree)
        for child in ast.iter_child_nodes(parent)
    }
    append_call = parents.get(download_call)
    if not (
        isinstance(append_call, ast.Call)
        and isinstance(append_call.func, ast.Attribute)
        and isinstance(append_call.func.value, ast.Name)
        and append_call.func.value.id == "verified_archives"
        and append_call.func.attr == "append"
    ):
        error("Debian installation set must contain only verified artifact paths")

    ancestor = parents.get(download_call)
    while ancestor is not None:
        if isinstance(ancestor, ast.Try) and ancestor.handlers:
            error("Debian artifact download failures must propagate before installation")
            break
        ancestor = parents.get(ancestor)

    dpkg_calls = [
        node for node in ast.walk(tree)
        if isinstance(node, ast.Call)
        and isinstance(node.func, ast.Attribute)
        and isinstance(node.func.value, ast.Name)
        and node.func.value.id == "subprocess"
        and node.func.attr == "run"
        and node.args
        and isinstance(node.args[0], ast.List)
        and any(isinstance(item, ast.Constant) and item.value == "dpkg" for item in node.args[0].elts)
    ]
    if len(dpkg_calls) != 1:
        error("Debian artifacts must be installed by one checked dpkg invocation")
        return
    dpkg_call = dpkg_calls[0]
    check_enabled = any(
        keyword.arg == "check" and isinstance(keyword.value, ast.Constant) and keyword.value.value is True
        for keyword in dpkg_call.keywords
    )
    if (
        dpkg_call.lineno <= (lock_loop.end_lineno or lock_loop.lineno)
        or "verified_archives" not in ast.unparse(dpkg_call.args[0])
        or not check_enabled
    ):
        error("All Debian artifacts must be verified before checked installation")


def validate_prompt_templates_runtime(runtime: str) -> None:
    try:
        tree = ast.parse(runtime)
    except SyntaxError as exc:
        error(f"Runtime entrypoint Python is invalid: {exc}")
        return

    functions = {
        node.name: node
        for node in tree.body
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef))
    }
    helper = functions.get("ensure_prompt_templates")
    prepare = functions.get("prepare_serena")
    main = functions.get("main")
    if not isinstance(helper, ast.FunctionDef) or not isinstance(prepare, ast.FunctionDef) or not isinstance(main, ast.FunctionDef):
        error("Secure prompt_templates initialization functions are missing")
        return

    def is_os_call(node: ast.AST, name: str) -> bool:
        return (
            isinstance(node, ast.Call)
            and isinstance(node.func, ast.Attribute)
            and isinstance(node.func.value, ast.Name)
            and node.func.value.id == "os"
            and node.func.attr == name
        )

    module_assignments = {
        target.id: node.value
        for node in tree.body
        if isinstance(node, ast.Assign)
        for target in node.targets
        if isinstance(target, ast.Name)
    }
    helper_assignments = {
        target.id: node.value
        for node in ast.walk(helper)
        if isinstance(node, ast.Assign)
        for target in node.targets
        if isinstance(target, ast.Name)
    }

    def resolve_name(node: ast.AST, seen: set[str] | None = None) -> ast.AST:
        seen = set() if seen is None else seen
        if isinstance(node, ast.Name) and node.id not in seen:
            value = helper_assignments.get(node.id, module_assignments.get(node.id))
            if value is not None:
                return resolve_name(value, seen | {node.id})
        return node

    def has_safe_getattr(node: ast.AST, attribute: str, seen: set[str] | None = None) -> bool:
        seen = set() if seen is None else seen
        for child in ast.walk(node):
            if (
                isinstance(child, ast.Call)
                and isinstance(child.func, ast.Name)
                and child.func.id == "getattr"
                and len(child.args) == 3
                and isinstance(child.args[0], ast.Name)
                and child.args[0].id == "os"
                and isinstance(child.args[1], ast.Constant)
                and child.args[1].value == attribute
                and isinstance(child.args[2], ast.Constant)
                and child.args[2].value == 0
            ):
                return True
            if isinstance(child, ast.Name) and child.id not in seen:
                value = helper_assignments.get(child.id, module_assignments.get(child.id))
                if value is not None and has_safe_getattr(value, attribute, seen | {child.id}):
                    return True
        return False

    def is_prompt_target(node: ast.AST) -> bool:
        value = resolve_name(node)
        return (
            isinstance(value, ast.BinOp)
            and isinstance(value.op, ast.Div)
            and isinstance(value.left, ast.Name)
            and value.left.id == "state_root"
            and isinstance(value.right, ast.Constant)
            and value.right.value == "prompt_templates"
        )

    open_assignments = [
        node for node in ast.walk(helper)
        if isinstance(node, ast.Assign)
        and len(node.targets) == 1
        and isinstance(node.targets[0], ast.Name)
        and is_os_call(node.value, "open")
    ]
    if len(open_assignments) != 1:
        error("Secure prompt_templates initialization must open exactly one directory descriptor")
        return
    open_assignment = open_assignments[0]
    descriptor = open_assignment.targets[0].id
    open_call = open_assignment.value
    if len(open_call.args) < 2 or not is_prompt_target(open_call.args[0]):
        error("Secure prompt_templates os.open must use the exact validated prompt_templates path")
    else:
        flags = resolve_name(open_call.args[1])
        if not has_safe_getattr(flags, "O_DIRECTORY"):
            error("Secure prompt_templates flags require portable O_DIRECTORY protection")
        if not has_safe_getattr(flags, "O_NOFOLLOW"):
            error("Secure prompt_templates flags require portable O_NOFOLLOW protection")

    fchown_calls = [
        node for node in ast.walk(helper)
        if is_os_call(node, "fchown")
        and len(node.args) == 3
        and isinstance(node.args[0], ast.Name) and node.args[0].id == descriptor
        and isinstance(node.args[1], ast.Name) and node.args[1].id == "uid"
        and isinstance(node.args[2], ast.Name) and node.args[2].id == "gid"
    ]
    if len(fchown_calls) != 1:
        error("Secure prompt_templates descriptor must be fchown'ed to runtime UID/GID")
    fchmod_calls = [
        node for node in ast.walk(helper)
        if is_os_call(node, "fchmod")
        and len(node.args) == 2
        and isinstance(node.args[0], ast.Name) and node.args[0].id == descriptor
        and isinstance(node.args[1], ast.Constant) and node.args[1].value == 0o700
    ]
    if len(fchmod_calls) != 1:
        error("Secure prompt_templates descriptor must be fchmod'ed to 0700")

    closed_in_finally = any(
        is_os_call(node, "close")
        and len(node.args) == 1
        and isinstance(node.args[0], ast.Name)
        and node.args[0].id == descriptor
        for try_node in ast.walk(helper)
        if isinstance(try_node, ast.Try)
        for statement in try_node.finalbody
        for node in ast.walk(statement)
    )
    if not closed_in_finally:
        error("Secure prompt_templates descriptor must be closed in finally")

    lstat_target_assignments = [
        node for node in ast.walk(helper)
        if isinstance(node, ast.Assign)
        and len(node.targets) == 1
        and isinstance(node.targets[0], ast.Name)
        and is_os_call(node.value, "lstat")
        and node.value.args
        and is_prompt_target(node.value.args[0])
    ]
    target_info_names = {node.targets[0].id for node in lstat_target_assignments}
    directory_check = any(
        isinstance(node, ast.If)
        and any(
            isinstance(child, ast.Call)
            and isinstance(child.func, ast.Attribute)
            and isinstance(child.func.value, ast.Name)
            and child.func.value.id == "stat"
            and child.func.attr == "S_ISDIR"
            for child in ast.walk(node.test)
        )
        and any(isinstance(child, ast.Name) and child.id in target_info_names for child in ast.walk(node.test))
        and any(isinstance(child, ast.Raise) for statement in node.body for child in ast.walk(statement))
        for node in ast.walk(helper)
    )
    if len(lstat_target_assignments) != 1 or not directory_check:
        error("Secure prompt_templates initialization must reject symlinks and non-directories")

    prepare_calls = [
        node for node in ast.walk(prepare)
        if isinstance(node, ast.Call) and isinstance(node.func, ast.Name) and node.func.id == "ensure_prompt_templates"
        and len(node.args) == 3
        and isinstance(node.args[0], ast.Name) and node.args[0].id == "STATE"
        and isinstance(node.args[1], ast.Name) and node.args[1].id == "uid"
        and isinstance(node.args[2], ast.Name) and node.args[2].id == "gid"
    ]
    prepare_main_calls = [
        node for node in ast.walk(main)
        if isinstance(node, ast.Call) and isinstance(node.func, ast.Name) and node.func.id == "prepare_serena"
    ]
    drop_calls = [
        node for node in ast.walk(main)
        if isinstance(node, ast.Call) and isinstance(node.func, ast.Name) and node.func.id == "drop_privileges"
    ]
    if len(prepare_calls) != 1 or len(prepare_main_calls) != 1 or len(drop_calls) != 1 or prepare_main_calls[0].lineno >= drop_calls[0].lineno:
        error("Secure prompt_templates initialization must occur before privilege drop")

    parents = {
        child: parent
        for parent in ast.walk(tree)
        for child in ast.iter_child_nodes(parent)
    }
    recursive_chown = False
    for call in (node for node in ast.walk(tree) if is_os_call(node, "chown")):
        ancestor = parents.get(call)
        while ancestor is not None:
            if isinstance(ancestor, (ast.For, ast.AsyncFor)) and any(
                name in ast.unparse(ancestor.iter) for name in ("STATE", "state_root")
            ):
                recursive_chown = True
                break
            ancestor = parents.get(ancestor)
    recursive_chown = recursive_chown or any(
        isinstance(node, ast.Constant)
        and isinstance(node.value, str)
        and "chown -R" in node.value
        and "serena-state" in node.value
        for node in ast.walk(tree)
    )
    if recursive_chown:
        error("Recursive chown of Serena state is forbidden")


def validate_ai_tooling() -> None:
    """Validate the root-only Phase 2 contract without Docker or network access."""
    tooling = ROOT / ".ai" / "tooling"
    required = [
        tooling / "Dockerfile", tooling / "compose.yaml", tooling / "runtime-entrypoint.py",
        tooling / "build-download.py", tooling / "graphify-runtime.py", tooling / "mcp_stdio.py",
        tooling / "doctor.py", tooling / "serena_config.yml",
        tooling / "versions.env", tooling / "debian-trixie-amd64.lock",
        tooling / "serena-artifacts.lock", tooling / "python/requirements.in",
        tooling / "python/requirements.lock", tooling / "language-servers/package.json",
        tooling / "language-servers/package-lock.json", ROOT / ".serena/project.yml",
        ROOT / ".serena/codex-single-project.yml", ROOT / ".serena/.gitignore",
    ]
    for path in required:
        if not path.is_file():
            error(f"Missing Phase 2 file: {rel(path)}")
    if any(not path.is_file() for path in required):
        return
    try:
        global_config = parse_simple_yaml(read_text(tooling / "serena_config.yml"))
        project_config = parse_simple_yaml(read_text(ROOT / ".serena/project.yml"))
        context = parse_simple_yaml(read_text(ROOT / ".serena/codex-single-project.yml"))
        compose = parse_simple_yaml(read_text(tooling / "compose.yaml"))
        codex = tomllib.loads(read_text(ROOT / ".codex/config.toml"))
        package = json.loads(read_text(tooling / "language-servers/package-lock.json"))
        package_manifest = json.loads(read_text(tooling / "language-servers/package.json"))
    except Exception as exc:  # noqa: BLE001
        error(f"Cannot parse Phase 2 structured configuration: {exc}")
        return
    if set(global_config) != AI_GLOBAL_KEYS:
        error(f"Incomplete global Serena config key set: {sorted(set(global_config) ^ AI_GLOBAL_KEYS)}")
    expected_global = {
        "language_backend": "LSP", "line_ending": "native", "gui_log_window": False,
        "web_dashboard": False, "web_dashboard_open_on_launch": False, "web_dashboard_interface": None,
        "web_dashboard_listen_address": "127.0.0.1", "jetbrains_plugin_server_address": "127.0.0.1",
        "log_level": 20, "trace_lsp_communication": False, "ls_specific_settings": {}, "ignored_paths": [],
        "read_only_memory_patterns": [], "ignored_memory_patterns": [], "tool_timeout": 240,
        "excluded_tools": [], "included_optional_tools": [], "fixed_tools": [],
        "base_modes": ["interactive", "editing"], "default_modes": None,
        "default_max_tool_answer_chars": 150000, "token_count_estimator": "CHAR_COUNT",
        "symbol_info_budget": 10, "project_serena_folder_location": "/serena-state/projects/qbit-ai-toolkit",
        "projects": ["/workspace"],
    }
    if global_config != expected_global:
        error("Global Serena configuration values do not match the 1.5.3 contract")
    if set(project_config) != AI_PROJECT_KEYS:
        error(f"Incomplete project Serena config key set: {sorted(set(project_config) ^ AI_PROJECT_KEYS)}")
    expected_ls = {
        "powershell": {"pses_version": "4.4.0", "psscriptanalyzer_version": "1.25.0"},
        "python": {"ls_path": "/opt/serena-language-servers/node_modules/.bin/pyright-langserver", "pyright_version": "1.1.403"},
        "bash": {"ls_path": "/opt/serena-language-servers/node_modules/.bin/bash-language-server", "bash_language_server_version": "5.6.0"},
    }
    if project_config.get("languages") != ["powershell", "bash", "python"] or project_config.get("ls_specific_settings") != expected_ls:
        error("Project Serena language-server contract mismatch")
    if (tooling / "serena-runtime.py").exists():
        error("Private Serena runtime adapter is forbidden")
    if set(context.get("fixed_tools", [])) != set(SERENA_TOOLS) or len(context.get("fixed_tools", [])) != len(SERENA_TOOLS):
        error("Serena single-project context tool allowlist mismatch")
    if not context.get("single_project"):
        error("Serena context must enforce single_project")
    for relative, digest in {
        "python/requirements.in": "9cf619d2a81e2ff3cc59d211ed7fb2ae14b058ccb362914a08043352d30e5eb0",
        "python/requirements.lock": "df2ef4ae7599178eddeb53f2e1f378dfecfb668411309c6a5a980e330e83bca1",
    }.items():
        actual = hashlib.sha256((tooling / relative).read_bytes()).hexdigest()
        if actual != digest:
            error(f"Immutable Python lock mismatch: .ai/tooling/{relative}")
    if package.get("lockfileVersion") != 3:
        error("npm lockfileVersion must be 3")
    direct = {"bash-language-server": "5.6.0", "pyright": "1.1.403"}
    if package_manifest.get("dependencies") != direct or package.get("packages", {}).get("", {}).get("dependencies") != direct:
        error("npm direct production dependency set mismatch")
    for path, entry in package.get("packages", {}).items():
        if path and "integrity" not in entry:
            error(f"npm resolved package lacks integrity: {path}")
    combined = "\n".join(read_text(path) for path in (tooling / "runtime-entrypoint.py", tooling / "graphify-runtime.py"))
    forbidden = ["uvx ", "npm install", "Save-Module", "_config_file_path", "add_registered_project"]
    for token in forbidden:
        if token in combined:
            error(f"Forbidden Phase 2 runtime fallback or private API: {token}")
    services = compose.get("services", {})
    if set(services) != {"serena", "graphify", "doctor"}:
        error("Compose must define exactly Serena, Graphify, and Doctor")
    named_volumes = set(compose.get("volumes", {}))
    if named_volumes != {"serena-state", "serena-resources", "graphify-output"}:
        error("Compose named-volume contract mismatch")
    for name, service in services.items():
        if service.get("build", {}).get("context") != ".":
            error(f"Compose build context must remain project root: {name}")
        if service.get("platform") != "linux/amd64":
            error(f"Compose service missing linux/amd64 platform: {name}")
        if service.get("network_mode") != "none" or service.get("read_only") is not True:
            error(f"Compose isolation mismatch: {name}")
        if service.get("cap_drop") != ["ALL"] or service.get("security_opt") != ["no-new-privileges:true"]:
            error(f"Compose capability/security mismatch: {name}")
    graphify_mounts = services.get("graphify", {}).get("volumes", [])
    graphify_output = [mount for mount in graphify_mounts if mount.get("target") == "/graphify-output"]
    if len(graphify_output) != 1 or graphify_output[0].get("type") != "volume" or graphify_output[0].get("source") != "graphify-output" or graphify_output[0].get("read_only") is not False:
        error("Graphify output must be one writable named-volume mount")
    for name, expected_workspace_ro in (("serena", False), ("graphify", True), ("doctor", True)):
        mounts = services.get(name, {}).get("volumes", [])
        workspace = [mount for mount in mounts if mount.get("target") == "/workspace"]
        if len(workspace) != 1 or workspace[0].get("type") != "bind" or workspace[0].get("read_only") is not expected_workspace_ro:
            error(f"Wrong workspace mount mode for {name}")
        elif workspace[0].get("source") != ".":
            error(f"Workspace bind must use project-directory root for {name}")
    doctor_environment = services.get("doctor", {}).get("environment", {})
    if doctor_environment.get("HOME") != "/tmp" or doctor_environment.get("XDG_CACHE_HOME") != "/tmp/cache":
        error("Doctor must use only ephemeral home and cache paths")
    doctor_tmpfs = set(services.get("doctor", {}).get("tmpfs", []))
    required_doctor_tmpfs = {
        "/serena-state/logs:rw,nosuid,nodev,noexec,mode=0700,uid=10001,gid=10001,size=32m",
        "/serena-state/projects/qbit-ai-toolkit/cache:rw,nosuid,nodev,noexec,mode=0700,uid=10001,gid=10001,size=64m",
    }
    if not required_doctor_tmpfs.issubset(doctor_tmpfs):
        error("Doctor private Serena tmpfs mounts must be owned by runtime UID/GID 10001")
    dockerfile = read_text(tooling / "Dockerfile")
    downloader = read_text(tooling / "build-download.py")
    runtime = read_text(tooling / "runtime-entrypoint.py")
    doctor = read_text(tooling / "doctor.py")
    mcp_stdio = read_text(tooling / "mcp_stdio.py")
    expected_frontend = "# syntax=docker/dockerfile:1.7@sha256:a57df69d0ea827fb7266491f2813635de6f17269be881f696fbfdf2d83dda33e"
    if dockerfile.splitlines()[0] != expected_frontend:
        error("Dockerfile frontend must use the immutable 1.7 digest")
    if "python -m pip --retries 10 --timeout 120 install" not in dockerfile or "--require-hashes --no-deps" not in dockerfile:
        error("Docker build must use bounded pip retries/timeouts with immutable hash verification")
    downloader_tokens = (
        "MAX_ATTEMPTS = 6", "TIMEOUT_SECONDS = 120", "CHUNK_SIZE = 1024 * 1024",
        "BACKOFF_CAP_SECONDS = 16.0", 'destination.name + ".part"', '"Range"',
        '"Content-Range"', "status == 200", "http.client.IncompleteRead",
        "ConnectionResetError", "URLError", "TRANSIENT_HTTP_STATUS",
        "hashlib.sha256", "os.replace",
    )
    if any(token not in downloader for token in downloader_tokens):
        error("Verified artifact downloader contract is incomplete")
    validate_runtime_artifact_download(dockerfile, downloader)
    validate_debian_artifact_download(
        dockerfile,
        (tooling / "debian-trixie-amd64.lock").read_bytes(),
    )
    for token in (
        "extract_zip_safely",
        "extract_tar_safely",
        "validate_archive_member_name",
        "duplicated PSES extraction layout",
        'static / "PyrightServer"',
        "required Pyright resource directory missing or unsafe",
    ):
        if token not in dockerfile + runtime:
            error(f"Unsafe or incomplete archive extraction contract: {token}")
    for token in ("install_canonical_file", "O_NOFOLLOW", "src_dir_fd", "dst_dir_fd", "os.fsync(parent_fd)"):
        if token not in runtime:
            error(f"Missing symlink-safe canonical file primitive: {token}")
    validate_prompt_templates_runtime(runtime)
    if (
        ".ai/tooling/mcp_stdio.py /usr/local/libexec/" not in dockerfile
        or '"/usr/local/libexec/mcp_stdio.py"' not in doctor
        or "MCP_STDIO.MCPClient" not in doctor
    ):
        error("Doctor and E2E must use the image-embedded shared MCP stdio client")
    for token in (
        "MAX_MESSAGE_BYTES",
        "Content-Length",
        '.decode("utf-8")',
        '.encode("utf-8")',
        "queue.Queue",
        "timeout=remaining",
        "MCPProtocolError",
        "truncated MCP frame",
        "stderr.read(4096)",
        "process.terminate()",
        "process.kill()",
    ):
        if token not in mcp_stdio:
            error(f"Shared MCP stdio safety contract missing: {token}")
    for token in ("cap_last_cap", "PR_CAPBSET_DROP", "CAP_SETPCAP", "NoNewPrivs", "CapAmb"):
        if token not in runtime:
            error(f"Missing capability-drop check: {token}")
    for check_id in (
        "mcp-construction",
        "mcp-process-start",
        "mcp-initialize-send",
        "mcp-initialize-receive",
        "mcp-initialize-validate",
        "mcp-initialize",
        "mcp-allowlist",
        "resource-manifest",
        "persistent-no-write",
        "powershell-semantic-smoke",
        "bash-semantic-smoke",
        "python-semantic-smoke",
    ):
        if f'"{check_id}"' not in doctor:
            error(f"Doctor validation category missing: {check_id}")
    for token in (
        'except PermissionError:',
        '"<permission-denied>"',
        "successful_mcp_tool_response",
        'results.setdefault(',
        '"mcp-initialize",',
        "def ldd_output(",
        'result.returncode == 1 and "not a dynamic executable" in output',
    ):
        if token not in doctor:
            error(f"Doctor read-only diagnostic contract missing: {token}")
    for script in (ROOT / ".ai/scripts/bootstrap.ps1", ROOT / ".ai/scripts/bootstrap.sh"):
        text = read_text(script)
        for token in ("docker info", "docker compose", "config", "requirements.lock", "node_modules", "ls-files"):
            if token not in text:
                error(f"Bootstrap preflight missing {token}: {rel(script)}")
        for token in ("installers/", "installers\\", "codex-ai-tooling", "qbit-cli", "installer aggregate"):
            if token.lower() in text.lower():
                error(f"Project-local bootstrap depends on installer scope: {rel(script)}")
    posix_launcher = read_text(ROOT / "tests/e2e/test_ai_tooling_docker.sh")
    if "python3" not in posix_launcher or "--host-family posix" not in posix_launcher:
        error("POSIX E2E launcher must use python3 and declare host family")
    server_config = codex.get("mcp_servers", {})
    if set(server_config) != {"context7", "serena"}:
        error("Project Codex config must contain only Context7 and Serena MCP servers")
    serena_mcp = server_config.get("serena", {})
    if set(serena_mcp.get("enabled_tools", [])) != set(SERENA_TOOLS) or serena_mcp.get("default_tools_approval_mode") != "prompt" or serena_mcp.get("tool_timeout_sec") != 45:
        error("Project Serena MCP policy mismatch")
    try:
        index_entry = subprocess.run(["git", "ls-files", "--stage", "--", ".gitignore"], cwd=ROOT, check=True, text=True, capture_output=True).stdout.rstrip("\n")
        if index_entry != AI_INDEX_ENTRY:
            error("Protected .gitignore index entry mismatch")
    except (OSError, subprocess.CalledProcessError) as exc:
        error(f"Cannot inspect protected Git index entry: {exc}")


def main() -> int:
    focused = sys.argv[1:] == ["--focus", "ai-tooling"]
    if sys.argv[1:] and not focused:
        print("usage: validate.py [--focus ai-tooling]", file=sys.stderr)
        return 2
    if focused:
        validate_ai_context_continuity_v2()
        validate_ai_tooling()
    else:
        parse_json_files()
        validate_catalog()
        validate_content_hygiene()
        validate_installer_policies()
        validate_ai_context_continuity_v2()
        validate_ai_tooling()
    if errors:
        for item in errors:
            print(f"ERROR: {item}", file=sys.stderr)
        print(f"Validation failed with {len(errors)} error(s).", file=sys.stderr)
        return 1
    print("Validation passed.")
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
