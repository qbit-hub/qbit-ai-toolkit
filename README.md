# Qbit AI Toolkit

Qbit AI Toolkit is the canonical, versioned source for reusable AI-development tooling in the Qbit ecosystem. It contains installers, schemas, templates, prompts, libraries, agent assets, policies, documentation, and validation tooling that can be consumed by Qbit products and other compatible repositories.

> **Documentation website:** [ai-toolkit.qbit.click](https://ai-toolkit.qbit.click)<br/>
> **Persian documentation:** [ai-toolkit.qbit.click/fa/](https://ai-toolkit.qbit.click/fa/)

## Start here

For most users, the documentation website is the best entry point:

- [Qbit AI Toolkit overview](https://ai-toolkit.qbit.click/overview)
- [AI Tools](https://ai-toolkit.qbit.click/ai-tools/)
- [Codex AI Tooling installer guide](https://ai-toolkit.qbit.click/ai-tools/codex-ai-tooling-installer)
- [ChatGPT Web models in Codex](https://ai-toolkit.qbit.click/ai-tools/codex-chatgpt-web)
- [Prompt Engineering](https://ai-toolkit.qbit.click/prompt-engineering/)
- [MCP](https://ai-toolkit.qbit.click/mcp/)
- [Agents & Skills](https://ai-toolkit.qbit.click/agents/)
- [Engineering reference](https://ai-toolkit.qbit.click/engineering/)

The repository keeps canonical Markdown under [`docs/`](docs/). The Docusaurus application under [`website/`](website/) renders that documentation in English and Persian.

## What this repository is

`qbit-ai-toolkit` is a **versioned asset repository**, not an application runtime. It centralizes reusable AI-development capabilities so consumers can depend on explicit, testable contracts instead of duplicating tooling across projects.

```text
qbit-cli            ─┐
qbit-console        ─┼── consumes versioned qbit-ai-toolkit assets
future consumers    ─┘
```

The repository is **type-oriented**, not consumer-folder-oriented. A canonical asset declares which consumers it supports rather than being copied into separate product-specific directories.

## What this repository is not

Qbit AI Toolkit is not:

- the Qbit CLI application;
- the Qbit Console application;
- an application dependency manager;
- a place for product-specific runtime code;
- a user-level Codex configuration repository;
- a store for credentials, generated browser state, or machine-specific configuration.

Product repositories consume Toolkit assets through explicit versioned contracts.

## Current stable assets

The catalog currently publishes two stable installers:

```text
installer.codex-ai-tooling  1.1.3
installer.ai-context        1.2.6
platforms                   Windows, Linux, macOS
```

`installer.codex-ai-tooling` installs repository-owned AI development tooling into an existing Git work tree while preserving application dependencies, project-owned instructions, and Git index state. `installer.ai-context` installs the zero-touch AI Context lifecycle; its current Continuity v2 contract is documented in [`docs/ai-tooling/continuity-v2.md`](docs/ai-tooling/continuity-v2.md).

The installer exposes the lifecycle operations:

```text
plan
install
update
repair
verify
doctor
uninstall
```

PowerShell and POSIX entrypoints are provided for cross-platform operation.

For installation, profiles, lifecycle behavior, update/repair procedures, and troubleshooting, use the dedicated guide:

**[Codex AI Tooling installer — setup and usage](https://ai-toolkit.qbit.click/ai-tools/codex-ai-tooling-installer)**

## AI tooling capabilities

The current installer architecture supports repository-owned AI tooling with explicit capability boundaries, including:

- project-scoped Codex configuration;
- Serena semantic tooling;
- Generic, TypeScript, and Rust semantic profiles;
- scoped Graphify architecture analysis;
- optional Context7 external-documentation routing;
- optional read-only Sentry incident analysis;
- repository-owned Docker/Compose runtime definitions;
- bootstrap, verification, Doctor, repair, and uninstall lifecycle operations;
- deterministic routing policies and reusable agent skills;
- integrity manifests and validation gates.

The detailed implementation model, security boundaries, runtime ownership, MCP protocol rules, and verification patterns are documented on the website:

**[Repository-owned AI tooling implementation guide](https://ai-toolkit.qbit.click/ai-tools/repository-owned-ai-tooling)**

## Additional AI tool guides

The documentation site also covers tools that are useful in AI-assisted development but are not necessarily catalog assets owned by this repository.

For example:

**[Use ChatGPT Web models in Codex](https://ai-toolkit.qbit.click/ai-tools/codex-chatgpt-web)** documents `codex-chatgpt-web`, including browser-only operation, Full Harness, model routing, ChatGPT Web model selection, and current limitations around local tool use.

## Repository structure

```text
qbit-ai-toolkit/
├── catalog.json               # machine-readable asset catalog
├── schemas/                   # catalog and asset schemas
├── installers/                # versioned installer assets
│   └── codex-ai-tooling/
├── prompts/                   # reusable prompt assets
├── libraries/                 # reusable libraries
├── templates/                 # reusable repository/CI/runtime templates
├── agent-assets/              # skills, policies, MCP and agent assets
├── docs/                      # canonical documentation source
├── website/                   # Docusaurus presentation/build layer
├── tests/                     # repository-level tests
└── tools/                     # validation and test runners
```

See the [Toolkit architecture documentation](https://ai-toolkit.qbit.click/architecture) for the repository-level design.

## Catalog contract

[`catalog.json`](catalog.json) is the machine entry point for consumers.

Each catalog asset declares metadata such as:

- stable asset ID;
- asset kind;
- semantic version;
- relative path;
- lifecycle status;
- supported consumers;
- supported platforms;
- entrypoints;
- compatibility metadata;
- optional integrity and release metadata.

The current catalog declares `installer.codex-ai-tooling` `1.1.3` and `installer.ai-context` `1.2.6` as stable installers for Windows, Linux, and macOS.

Schemas live under [`schemas/`](schemas/) and are part of the versioned contract.

## Versioning model

Toolkit assets use semantic versions. A consumer should resolve a specific catalog revision and asset version rather than depending on mutable, floating behavior.

Compatibility changes must be explicit. Existing installer `1.0` on-disk namespaces and managed-block markers remain compatibility identifiers even though the repository itself was renamed from `qbit-toolkit` to `qbit-ai-toolkit`.

See [Versioning](https://ai-toolkit.qbit.click/versioning) for the repository policy.

## Documentation

Documentation is treated as part of the versioned source of truth. Architecture, contracts, operational behavior, security boundaries, and compatibility rules should be documented before a change is considered complete.

The main documentation domains are:

### AI Tools

Operational setup, installers, repository-owned tooling, Codex integrations, and reusable implementation guidance.

[Open AI Tools documentation →](https://ai-toolkit.qbit.click/ai-tools/)

### Prompt Engineering

Prompt fundamentals, patterns, reasoning, orchestration, clarification and verification loops, APIs, context, security, evaluation, templates, and exercises.

[Open Prompt Engineering documentation →](https://ai-toolkit.qbit.click/prompt-engineering/)

### MCP

Model Context Protocol configuration, usage, capability boundaries, and security guidance.

[Open MCP documentation →](https://ai-toolkit.qbit.click/mcp/)

### Agents & Skills

Reusable skills, agent policies, skill authoring, and agent-oriented development guidance.

[Open Agents & Skills documentation →](https://ai-toolkit.qbit.click/agents/)

### Engineering reference

Architecture, conventions, asset contracts, security, validation, and versioning.

[Open Engineering reference →](https://ai-toolkit.qbit.click/engineering/)

## Local documentation development

The documentation website uses Docusaurus and Bun.

Install website dependencies:

```bash
cd website
bun ci
```

Run the English development site:

```bash
bun run start
```

Run the Persian development site:

```bash
bun run start:fa
```

Build both locales for production:

```bash
bun run build
```

For production-like local language-switch testing, use the preview/serve workflow defined in [`website/package.json`](website/package.json).

## Validation

Repository validation is mandatory before review.

Run the canonical validator:

```bash
python tools/validate.py
```

PowerShell and POSIX wrappers are also available:

```powershell
./tools/validate.ps1
```

```bash
./tools/validate.sh
```

Installer-specific tests are split into unit, integration, lifecycle E2E, and Docker-dependent runtime checks. See [`installers/codex-ai-tooling/tests/README.md`](installers/codex-ai-tooling/tests/README.md) for the test matrix and supported runners.

## Contribution rules

Keep contributions focused on reusable, versioned Toolkit assets.

Key rules include:

- use JSON for machine-readable catalogs and manifests;
- keep templates type-oriented and declare consumers in metadata;
- use LF line endings, UTF-8 without BOM, and final newlines;
- pin dependency versions instead of using floating selectors such as `latest`;
- do not commit secrets, credentials, generated browser state, generated Graphify state, or user-specific absolute paths;
- preserve target-project application dependencies unless changing them is an explicit asset contract;
- run repository validation and the relevant installer tests before review.

See [`CONTRIBUTING.md`](CONTRIBUTING.md) for the repository contribution policy.

## Security

Do not open public issues containing secrets, exploit details, or customer data. Security-sensitive reports should follow the Qbit private security process.

Committed files must not contain API keys, OAuth tokens, passwords, private keys, Sentry credentials, Context7 credentials, machine-specific absolute paths, or internal production hostnames.

Installers must remain repository-scoped, avoid global configuration changes, and preserve target-project application dependencies.

See [`SECURITY.md`](SECURITY.md) for the repository security policy and [Security documentation](https://ai-toolkit.qbit.click/security) for engineering guidance.

## Compatibility note

This repository was renamed from `qbit-toolkit` to `qbit-ai-toolkit`.

Existing installer `1.0` compatibility identifiers such as:

```text
.qbit-toolkit/
qbit-toolkit:codex-ai-tooling
```

are intentionally preserved where they are part of an established on-disk or managed-block contract. They must not be renamed implicitly.

## Website

The public documentation site is:

### [https://ai-toolkit.qbit.click](https://ai-toolkit.qbit.click)

Persian documentation:

### [https://ai-toolkit.qbit.click/fa/](https://ai-toolkit.qbit.click/fa/)

The website is the recommended place to browse guides and operational documentation; this repository remains the canonical source for the versioned assets and Markdown documentation behind it.
