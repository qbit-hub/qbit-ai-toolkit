---
id: index
title: CodexPro
sidebar_label: Overview
---

# CodexPro

CodexPro is an open-source bridge used to expose a local development workspace to ChatGPT through MCP while keeping repository tooling, sandboxed Bash execution, and optional direct host execution as separate capability paths.

The documentation in this section is deployment-neutral. Public docs use placeholders for usernames, workspace roots, connector names, package locations, hostnames, tunnel IDs, and credentials instead of copying values from a specific machine or project.

## Available guides

- [Windows setup guide](./windows-setup.md) — configure the Qbit-patched Windows deployment, including optional OpenAI Secure MCP Tunnel, Cloudflare, and ngrok exposure.
- [Linux setup guide](./linux-setup.md) — install and operate CodexPro on Linux, configure local or public HTTPS access, validate repository boundaries, and run safely in interactive or headless environments.
- [macOS setup guide](./macos-setup.md) — install and operate CodexPro on macOS with explicit shell/PATH, privacy, architecture, tunnel, and repository-scope guidance.

## Package-manager boundary

CodexPro is distributed as an npm package, but the setup is not tied to Bun. Use any compatible package manager that installs the required CodexPro version and exposes the codexpro executable on PATH. Package-manager storage layout is an installation detail, not part of the CodexPro architecture.

## Important security boundary

Sandboxed Bash and direct host execution are distinct capabilities:

- Bash should remain bounded by the selected repository/workspace.
- Direct host execution, when available and enabled, runs with the current OS user's authority and therefore requires a stricter approval and credential model.

Treat token-bearing connector URLs, OpenAI Runtime API keys, and provider account credentials as secrets. Use the narrowest practical workspace root and enable only the capabilities required by the workflow.

## Windows multi-provider launcher

The Windows installer publishes a dispatcher plus provider launchers:

- Start-CodexPro.ps1 — selects the configured default provider or routes --openai, --cf, and --ngrok;
- Start-CodexPro.openai.ps1 — OpenAI Secure MCP Tunnel on local port 8788;
- Start-CodexPro.cloudflare.ps1 — Cloudflare named tunnel on local port 8787;
- Start-CodexPro.ngrok.ps1 — ngrok on local port 8789.

One, two, or all three providers may be configured. The installer never requires all three.

Cloudflare and ngrok use CodexPro query-token Server URLs and ChatGPT Authentication None / No Authentication. OpenAI Secure MCP Tunnel uses the OpenAI tunnel integration and does not expose a custom token-bearing Server URL.

This repository publishes the Windows-only installer.codexpro asset under installers/codexpro/. It provisions the pinned CodexPro 0.29.0 deployment while keeping the low-level package patch as a version-specific internal implementation detail.
