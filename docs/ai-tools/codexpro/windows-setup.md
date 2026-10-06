---
id: windows-setup
title: CodexPro on Windows — Setup Guide
sidebar_label: Windows setup
---

# CodexPro on Windows — Setup Guide

This guide documents a reusable Windows deployment, not a snapshot of a specific developer machine, project, hostname, tunnel, account, or package-manager layout.

Use placeholders such as `<WORKSPACE_PATH>`, `<PUBLIC_HOSTNAME>`, `<NGROK_HOSTNAME>`, and `<CONNECTOR_NAME>`. Never copy another deployment's username, tunnel ID, Runtime API key, ngrok credential, MCP token, or private path into canonical documentation.

## Supported exposure providers

The Qbit Windows installer can configure any one, any two, or all three of these providers:

| Provider | Local MCP | Remote authentication | External account state |
|---|---:|---|---|
| OpenAI Secure MCP Tunnel | `127.0.0.1:8788` | OpenAI tunnel runtime | existing tunnel ID + Runtime API key |
| Cloudflare named tunnel | `127.0.0.1:8787` | CodexPro query token | Cloudflare login/tunnel/DNS |
| ngrok | `127.0.0.1:8789` | CodexPro query token | user-owned ngrok config + stable hostname |

The installer never requires all three providers. Every local listener remains loopback-only; the selected provider owns remote exposure.

## Version policy

The Qbit Windows customization is pinned to **CodexPro `0.29.0`** because the workspace-sandbox and direct-host extensions patch that exact build. Do not apply this patch to another CodexPro version without review and revalidation.

Common version checks:

```powershell
pwsh --version
git --version
codex --version
codexpro --version
```

Run provider-specific checks only for providers you use:

```powershell
cloudflared --version
ngrok version
```

## Recommended installation

Use the versioned installer under `installers/codexpro/`.

### OpenAI only

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\installers\codexpro\install.ps1 `
  -WorkspaceRoot '<WORKSPACE_PATH>' `
  -Tunnels openai `
  -DefaultTunnel openai
```

### Cloudflare only

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\installers\codexpro\install.ps1 `
  -WorkspaceRoot '<WORKSPACE_PATH>' `
  -Tunnels cloudflare `
  -Hostname '<PUBLIC_HOSTNAME>' `
  -TunnelName '<TUNNEL_NAME>'
```

### ngrok only

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\installers\codexpro\install.ps1 `
  -WorkspaceRoot '<WORKSPACE_PATH>' `
  -Tunnels ngrok `
  -NgrokHostname '<NGROK_HOSTNAME>'
```

### Multiple providers

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\installers\codexpro\install.ps1 `
  -WorkspaceRoot '<WORKSPACE_PATH>' `
  -Tunnels @('openai', 'cloudflare', 'ngrok') `
  -DefaultTunnel openai `
  -Hostname '<PUBLIC_HOSTNAME>' `
  -TunnelName '<TUNNEL_NAME>' `
  -NgrokHostname '<NGROK_HOSTNAME>'
```

If `-Tunnels` is omitted, the installer preserves version-1.0.0 compatibility by selecting **Cloudflare only**. In that compatibility mode, `-Hostname` is required exactly as before.

If `-DefaultTunnel` is omitted, the first selected provider is used. Duplicate providers and a default provider that was not selected are rejected.

## Common prerequisites

Every selected configuration requires:

1. PowerShell 7;
2. Git for Windows with Git Bash;
3. a supported JavaScript package manager;
4. Codex CLI with a valid authenticated session;
5. CodexPro `0.29.0`.

Bun is not required. The installer records the resolved package path instead of assuming a Bun-specific global layout.

## Provider prerequisites

### OpenAI Secure MCP Tunnel

OpenAI mode expects an **already provisioned OpenAI tunnel** and an existing Runtime API key.

Conventional defaults are:

```text
tunnel-client executable: $HOME\.tunnel-client\bin\tunnel-client.exe
tunnel id file:           $HOME\.tunnel-client\codexpro\tunnel-id.txt
runtime key file:         $HOME\.tunnel-client\secrets\runtime.key
profile directory:        $HOME\.config\tunnel-client
runtime alias/profile:    codexpro-laptop
```

All paths and names are configurable installer inputs.

The attach/reuse flow uses the existing tunnel ID and Runtime API key:

```text
tunnel-client runtimes connect --alias <ALIAS> --profile <PROFILE> --profile-dir <PROFILE_DIR> --tunnel-id <EXISTING_TUNNEL_ID> --mcp-server-url http://127.0.0.1:8788/mcp --runtime-api-key file:<RUNTIME_KEY_FILE>
```

This path does **not** require `OPENAI_ADMIN_KEY` and does not create a new tunnel. The installer stores only paths and non-secret metadata; it never copies Runtime API key contents into `deployment.json` or normal logs.

OpenAI mode runs CodexPro locally with `--tunnel none --no-auth` because the OpenAI tunnel boundary owns remote authentication.

### Cloudflare named tunnel

Cloudflare mode uses local MCP port `8787`. When selected, `-Hostname` is required and `-TunnelName` defaults to `codexpro-local`.

If `cloudflared` is missing, the installer may install it with winget. `-CloudflaredPath` may be used to provide an existing executable explicitly.

Unless `-SkipTunnelSetup` is supplied, the installer uses the normal Cloudflare login/create/route flow. `-SkipTunnelSetup` is a Cloudflare-only compatibility switch and is rejected when Cloudflare is not selected.

HTTP/2 remains the default Cloudflare transport; `auto` and `quic` are explicit alternatives.

### ngrok

ngrok mode uses local MCP port `8789`. `-NgrokHostname` is required and should identify a stable hostname/dev-domain controlled by the user.

If ngrok is missing, the installer may install `Ngrok.Ngrok` through winget. `-NgrokExecutable` can override the CLI path.

The default config path is:

```text
$HOME\.config\ngrok\ngrok.yml
```

The installer validates it with `ngrok config check --config <CONFIG_PATH>`. It does not ask for, copy, or persist the ngrok auth token.

The ngrok free-browser warning is not MCP authentication and must never replace the CodexPro token.

## Runtime dispatcher

The installer places a raw-argument dispatcher in the CodexPro state directory and installs a small `cpx` function in the PowerShell profile unless `-SkipProfileUpdate` is used.

From a project directory:

```powershell
cd <WORKSPACE_PATH>

cpx
cpx --openai
cpx --cf
cpx --ngrok
```

Plain `cpx` starts the configured default provider. When no root is supplied, the current PowerShell location becomes the workspace root.

Explicit roots are also supported:

```powershell
cpx D:\Projects --cf
cpx D:\Projects --ngrok
cpx --root D:\Projects --openai
```

Useful runtime overrides:

```powershell
cpx --openai --host-exec-mode off
cpx --cf --tunnel-protocol auto
cpx --ngrok --ngrok-hostname <NGROK_HOSTNAME>
```

The dispatcher rejects conflicting provider flags and providers that were not configured.

## ChatGPT connector configuration

### OpenAI Secure MCP Tunnel

Do not invent a custom token-bearing Server URL for OpenAI mode. The secure tunnel is registered through OpenAI's tunnel integration.

The local endpoint is:

```text
http://127.0.0.1:8788/mcp
```

That loopback URL is not a public ChatGPT connector URL.

### Cloudflare and ngrok

Cloudflare and ngrok use CodexPro query-token authentication:

```text
https://<HOSTNAME>/mcp?codexpro_token=<SECRET>
```

In the ChatGPT custom MCP UI use:

| Field | Value |
|---|---|
| Server URL | complete token-bearing URL |
| Authentication | None / No Authentication |
| Permissions | only actions required by the workflow |

The URL is a secret because it contains the credential. Provider launchers attempt to copy the full URL to the clipboard without printing the token. The explicit `Get-CodexProConnectorUrl.ps1` helper may print it when the operator deliberately invokes it.

## Installed state

```text
$HOME\.codexpro\
├── backups\
├── deployment.json
├── http-token
├── Start-CodexPro.ps1
├── Start-CodexPro.openai.ps1
├── Start-CodexPro.cloudflare.ps1
├── Start-CodexPro.ngrok.ps1
└── Get-CodexProConnectorUrl.ps1
```

`http-token` is required only when Cloudflare or ngrok is selected.

`deployment.json` uses schema version 2 for multi-provider state. It records selected providers, the default provider, executable/config paths, local ports, and other non-secret runtime metadata.

## Security boundaries

### Workspace Bash

```text
ChatGPT -> CodexPro bash -> Codex workspace sandbox -> Git Bash
```

A permissive Bash command policy does not imply filesystem access outside the selected root. Test containment explicitly.

### Direct host execution

`host_exec` and `open_app` are distinct from workspace Bash. Use absolute executable paths, direct argv passing, narrow environment inheritance, and the intended `HostExecMode`. `full-access` does not bypass Windows UAC.

ChatGPT connector permissions are a separate authorization gate.

### Provider secrets

Never place any of these in repository files, prompts, normal logs, or public documentation:

- CodexPro MCP token;
- token-bearing connector URL;
- OpenAI Runtime API key;
- ngrok auth token;
- provider cookies or private keys.

The installer stores provider secret **paths** where required, not secret contents.

## Verification

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\installers\codexpro\verify.ps1
```

The verifier checks common CodexPro/package/patch/profile state and then only the dependencies required by selected providers.

- Cloudflare: executable, hostname/tunnel configuration, and named-tunnel existence when installer provisioning was enabled.
- ngrok: executable, hostname, config path, and `ngrok config check` without starting a public tunnel.
- OpenAI: tunnel-client, tunnel-ID/runtime-key files, profile inputs, and non-empty files without printing secret contents. The runtime does not need to already be online.

## Uninstall

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\installers\codexpro\uninstall.ps1
```

Default uninstall restores or removes installer-managed launchers/profile state and restores the package patch backup when safe.

External provider state is preserved by default:

- OpenAI tunnel registration, tunnel-client config, tunnel ID, and Runtime API key remain untouched;
- ngrok account configuration and hostname ownership remain untouched;
- Cloudflare tunnel state remains untouched unless `-RemoveTunnel` is explicitly requested.

`-RemoveTunnel` is Cloudflare-specific. It does not delete OpenAI or ngrok resources.

## Troubleshooting

### OpenAI runtime is locally healthy but ChatGPT is disconnected

Inspect `tunnel-client runtimes status <alias> --json` and `remote_error` separately. Local health/ready endpoints do not prove control-plane polling is healthy. Reattach with the existing Runtime API key flow; do not introduce `OPENAI_ADMIN_KEY` merely to restart an already-provisioned runtime.

### Cloudflare works locally but not publicly

Check hostname ownership, DNS route, named-tunnel state, transport, and query-token authentication independently.

### ngrok does not start

Run `ngrok config check --config <CONFIG_PATH>` and confirm the stable hostname belongs to the account. Do not weaken MCP authentication to bypass the browser warning.

### Network middleware changes tunnel behavior

VPN, TUN, proxy, filtering, and routing software can affect providers differently. Diagnose the route per provider and environment. Reusable installer code intentionally contains no Hiddify-, SOCKS-, or VPN-product-specific assumptions.

## Acceptance checklist

- [ ] CodexPro `0.29.0` is installed and patched for the exact supported build.
- [ ] Only intended tunnel providers are selected.
- [ ] The default provider is one of the selected providers.
- [ ] Unselected providers do not introduce required dependencies.
- [ ] Local MCP endpoints bind only to loopback.
- [ ] OpenAI mode uses an existing tunnel ID and Runtime API key, not an admin key.
- [ ] Cloudflare/ngrok token-bearing URLs are treated as secrets.
- [ ] ChatGPT Authentication is None / No Authentication for Cloudflare/ngrok custom URLs.
- [ ] ngrok account credentials remain outside installer state.
- [ ] Cloudflare transport is explicit; HTTP/2 remains the Windows default.
- [ ] `cpx` uses the current directory when no root is provided.
- [ ] `cwd=..` cannot escape the selected workspace.
- [ ] Direct host execution uses the intended approval mode.
- [ ] Uninstall preserves external provider state by default.
- [ ] A disposable end-to-end connector test passes for each provider actually used.

## Documentation rule

Canonical docs describe contracts and placeholders, not a developer's machine. Never publish a real username, private hostname, real tunnel ID, Runtime API key, token-bearing URL, ngrok credential, or package-manager-specific personal path as a universal value.
