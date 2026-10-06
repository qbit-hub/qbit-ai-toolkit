# CodexPro Windows Deployment Installer

installer.codexpro provisions the Qbit CodexPro Windows deployment used by ChatGPT MCP connections. It is pinned to **CodexPro 0.29.0** because the Windows workspace-sandbox and direct-host extensions modify that exact build.

The installer supports three independent exposure providers:

- **OpenAI Secure MCP Tunnel**
- **Cloudflare named tunnel**
- **ngrok**

You may configure one, two, or all three. Installing all three is never required.

## Provider selection

Use **-Tunnels** to select providers and **-DefaultTunnel** to choose what plain **cpx** starts.

~~~powershell
# OpenAI only
& .\install.ps1 -WorkspaceRoot 'D:\Projects\ExampleProject' -Tunnels openai -DefaultTunnel openai

# Cloudflare only
& .\install.ps1 -WorkspaceRoot 'D:\Projects\ExampleProject' -Tunnels cloudflare -Hostname 'codexpro.example.com' -TunnelName 'codexpro-local'

# ngrok only
& .\install.ps1 -WorkspaceRoot 'D:\Projects\ExampleProject' -Tunnels ngrok -NgrokHostname 'example.ngrok-free.app'

# All three; OpenAI is the default
& .\install.ps1 -WorkspaceRoot 'D:\Projects\ExampleProject' -Tunnels @('openai', 'cloudflare', 'ngrok') -DefaultTunnel openai -Hostname 'codexpro.example.com' -TunnelName 'codexpro-local' -NgrokHostname 'example.ngrok-free.app'
~~~

For backward compatibility, omitting **-Tunnels** selects **Cloudflare only**. Existing invocations that provide WorkspaceRoot, Hostname, and optionally TunnelName therefore keep their previous meaning.

If **-DefaultTunnel** is omitted, the first selected provider becomes the default. Duplicate providers, an empty provider list, and a default provider that was not selected are rejected.

## What the installer owns

The PowerShell installer:

1. validates Windows and the requested workspace;
2. ensures Git for Windows/Git Bash, a supported JavaScript package manager, Codex CLI, and CodexPro 0.29.0 are available;
3. verifies Codex CLI authentication and starts interactive login when required;
4. applies the version-specific CodexPro workspace-sandbox/environment patch and the host_exec / open_app extension;
5. installs a dispatcher plus provider launchers and a managed cpx PowerShell helper;
6. writes provider-aware schema-v2 deployment state;
7. installs or validates only dependencies required by selected providers;
8. creates the CodexPro HTTP MCP token only when Cloudflare or ngrok is selected;
9. runs verify.ps1 before reporting success.

The installer does **not** create a ChatGPT connector in the ChatGPT UI.

## Provider-specific behavior

### OpenAI Secure MCP Tunnel

OpenAI mode uses local MCP port **8788** and runs CodexPro with tunnel none and no-auth. Authentication and remote exposure are owned by OpenAI Secure MCP Tunnel.

The installer expects an **existing provisioned tunnel** and an existing Runtime API key. It does not require OPENAI_ADMIN_KEY and does not create or delete an OpenAI tunnel.

Default conventional inputs are:

~~~text
tunnel-client:    $HOME\.tunnel-client\bin\tunnel-client.exe
tunnel id file:   $HOME\.tunnel-client\codexpro\tunnel-id.txt
runtime key file: $HOME\.tunnel-client\secrets\runtime.key
profile dir:      $HOME\.config\tunnel-client
alias/profile:    codexpro-laptop
~~~

All are configurable. The runtime launcher attaches to the existing tunnel using tunnel-client runtimes connect with the tunnel ID file, Runtime API key file, profile, alias, and local MCP URL http://127.0.0.1:8788/mcp. Runtime-key contents are never copied into deployment.json.

### Cloudflare

Cloudflare mode uses local MCP port **8787**.

Hostname is required only when Cloudflare is selected. TunnelName defaults to codexpro-local and TunnelProtocol defaults to http2.

If cloudflared is missing, the installer may install it with winget. **-CloudflaredPath** can supply an existing executable explicitly.

Unless **-SkipTunnelSetup** is used, the installer authenticates cloudflared when needed, creates or reuses the named tunnel, and routes the supplied hostname. SkipTunnelSetup is a **Cloudflare-only compatibility switch**.

Cloudflare uses CodexPro query-token authentication:

~~~text
https://<PUBLIC_HOSTNAME>/mcp?codexpro_token=<SECRET>
~~~

In ChatGPT choose **Authentication: None / No Authentication** because the credential is already carried in the URL.

### ngrok

ngrok mode uses local MCP port **8789**.

NgrokHostname is required when ngrok is selected. Use a stable ngrok hostname/dev-domain.

If the ngrok CLI is missing, the installer may install Ngrok.Ngrok with winget. **-NgrokExecutable** can override the executable.

The installer does **not** collect or store an ngrok auth token. ngrok account state remains external. By default it validates:

~~~text
$HOME\.config\ngrok\ngrok.yml
~~~

Override that with **-NgrokConfigPath** when necessary.

ngrok uses the same CodexPro query-token URL model:

~~~text
https://<NGROK_HOSTNAME>/mcp?codexpro_token=<SECRET>
~~~

In ChatGPT choose **Authentication: None / No Authentication**.

The ngrok free-browser warning is not MCP authentication and must not replace the CodexPro token.

## Common parameters

Important options:

- **-Tunnels openai|cloudflare|ngrok** — one or more providers;
- **-DefaultTunnel openai|cloudflare|ngrok** — must be selected;
- **-HostExecMode off|on-request|full-access** — default on-request;
- **-TunnelProtocol auto|quic|http2** — Cloudflare only; default http2;
- **-PackageManager auto|bun|npm|pnpm** — default auto;
- **-Hostname** and **-TunnelName** — Cloudflare inputs;
- **-CloudflaredPath** — optional explicit Cloudflare executable;
- **-NgrokHostname**, **-NgrokExecutable**, **-NgrokConfigPath** — ngrok inputs;
- **-TunnelClientExecutable**, **-OpenAITunnelIdFile**, **-OpenAIRuntimeKeyFile**, **-OpenAITunnelAlias**, **-OpenAITunnelProfile**, **-OpenAIProfileDir** — OpenAI runtime inputs;
- **-ProfilePath** and **-SkipProfileUpdate** — PowerShell profile behavior;
- **-SkipCodexLogin** — require an already-authenticated Codex CLI;
- **-Force** — allow reviewed replacement of conflicting installer-owned state. It does not migrate a different CodexPro version.

## cpx dispatcher

The managed profile helper forwards arguments directly to the dispatcher.

~~~powershell
cd D:\Projects\ExampleProject

cpx             # configured default provider
cpx --openai
cpx --cf
cpx --ngrok

cpx D:\Projects --cf
cpx D:\Projects --ngrok
cpx --root D:\Projects --openai
~~~

When no root is supplied, cpx uses the current PowerShell location. Selecting a provider that was not configured fails before attempting to start it.

Runtime overrides include:

~~~powershell
cpx --cf --tunnel-protocol auto
cpx --ngrok --ngrok-hostname example.ngrok-free.app
cpx --openai --host-exec-mode off
~~~

## Installed state

~~~text
~\.codexpro\
├── backups\
├── deployment.json
├── http-token                         # only needed for Cloudflare/ngrok
├── Start-CodexPro.ps1                 # dispatcher
├── Start-CodexPro.openai.ps1
├── Start-CodexPro.cloudflare.ps1
├── Start-CodexPro.ngrok.ps1
└── Get-CodexProConnectorUrl.ps1
~~~

deployment.json uses schema version 2 for multi-provider state. It records provider paths and non-secret configuration, never Runtime API key contents, ngrok credentials, or the MCP token itself.

## Connector URL helper

For Cloudflare or ngrok, the explicit helper may print the secret URL:

~~~powershell
& "$HOME\.codexpro\Get-CodexProConnectorUrl.ps1" -Mode cloudflare
& "$HOME\.codexpro\Get-CodexProConnectorUrl.ps1" -Mode ngrok
~~~

Routine installer, launcher, and verifier output does not print the token.

OpenAI Secure MCP Tunnel deliberately has no custom token-bearing Server URL. Mode openai is rejected; connect it through OpenAI tunnel integration.

## Verification

~~~powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\verify.ps1
~~~

Verification is provider-aware:

- common CodexPro version, patch, Git Bash, Codex CLI, and managed assets are always checked;
- the HTTP MCP token is checked only for Cloudflare/ngrok;
- Cloudflare checks cloudflared, hostname/tunnel configuration, and the named tunnel when provisioning was enabled;
- ngrok checks the executable, stable hostname, config path, and ngrok config check;
- OpenAI checks tunnel-client and referenced tunnel-id/runtime-key/profile inputs without printing secret contents.

## Uninstall

~~~powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\uninstall.ps1
~~~

Default uninstall removes or restores installer-managed launcher/profile/state assets and restores the CodexPro package backup when safe.

External provider state is preserved:

- OpenAI tunnel registration, tunnel ID, Runtime API key, and tunnel-client configuration are not deleted;
- ngrok account configuration and domain ownership are not deleted;
- Cloudflare tunnel deletion remains opt-in with **-RemoveTunnel**.

RemoveTunnel applies only to a configured Cloudflare named tunnel.

## Security model

- Every local MCP listener is loopback-only.
- Bash remains bounded by the selected workspace.
- Direct host execution is a separate privileged capability.
- ChatGPT connector permissions are a separate authorization gate.
- Token-bearing URLs are secrets.
- Provider credentials remain outside repository files and normal logs.
- No proxy, VPN, or Hiddify-specific routing behavior is assumed by reusable installer code.
- Shared host dependencies are preserved during uninstall.

## Platform boundary

Version 1.1.0 remains Windows-only because the custom host-execution approval flow and pinned package patch target Windows. POSIX entrypoints intentionally report the unsupported-platform boundary.
