# Changelog

## 1.1.0

- Add optional multi-provider exposure for OpenAI Secure MCP Tunnel, Cloudflare named tunnels, and ngrok.
- Allow one, two, or all three providers to be selected independently with a configurable default provider.
- Add the cpx dispatcher and provider-specific launchers for --openai, --cf, and --ngrok.
- Keep the legacy Cloudflare-only installer invocation compatible when -Tunnels is omitted.
- Gate provider-specific dependencies and credentials so unselected providers are not required.
- Use local ports 8788 for OpenAI, 8787 for Cloudflare, and 8789 for ngrok.
- Preserve OpenAI Runtime API keys, ngrok account configuration, and provider-owned tunnel state during uninstall.
- Add provider-aware verification and integration coverage without provisioning external tunnels during tests.

## 1.0.0

- Add a complete Windows CodexPro deployment installer pinned to CodexPro 0.29.0.
- Install or validate required Git, package-manager, Codex CLI, CodexPro, and cloudflared dependencies.
- Apply the Qbit Windows workspace-sandbox/environment patch and host-execution extension.
- Generate and protect the MCP token, write durable deployment configuration, install the reusable launcher, and add the managed cpx PowerShell helper.
- Provision or reuse a Cloudflare named tunnel and route the requested public hostname.
- Default long-lived Cloudflare transport to HTTP/2 while allowing explicit auto or quic selection.
- Add verification and conservative uninstall/rollback entrypoints.
