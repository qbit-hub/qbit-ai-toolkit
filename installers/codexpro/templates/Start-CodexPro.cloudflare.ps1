[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Root = (Get-Location).Path,

    [ValidateSet('', 'off', 'on-request', 'full-access')]
    [string]$HostExecMode = '',

    [ValidateSet('', 'auto', 'quic', 'http2')]
    [string]$TunnelProtocol = ''
)

$ErrorActionPreference = 'Stop'
$ConfigFile = Join-Path $PSScriptRoot 'deployment.json'
$TokenFile = Join-Path $PSScriptRoot 'http-token'

if (-not (Test-Path -LiteralPath $ConfigFile -PathType Leaf)) {
    throw "CodexPro deployment configuration not found: $ConfigFile"
}
if (-not (Test-Path -LiteralPath $Root -PathType Container)) {
    throw "Workspace does not exist: $Root"
}

$Config = Get-Content -LiteralPath $ConfigFile -Raw | ConvertFrom-Json
[string[]]$ConfiguredTunnels = if ($Config.tunnels) {
    @($Config.tunnels | ForEach-Object { ([string]$_).ToLowerInvariant() })
}
elseif ($Config.hostname) {
    @('cloudflare')
}
else {
    @()
}
if ('cloudflare' -notin $ConfiguredTunnels) {
    throw 'Cloudflare is not configured for this CodexPro deployment.'
}

$Provider = if ($Config.providers -and $Config.providers.cloudflare) { $Config.providers.cloudflare } else { $null }
$Hostname = if ($Provider -and $Provider.hostname) { [string]$Provider.hostname } else { [string]$Config.hostname }
$TunnelName = if ($Provider -and $Provider.tunnelName) { [string]$Provider.tunnelName } else { [string]$Config.tunnelName }
$Cloudflared = if ($Provider -and $Provider.executable) { [string]$Provider.executable } else { [string]$Config.cloudflaredExecutable }
$EffectiveTunnelProtocol = if ($TunnelProtocol) {
    $TunnelProtocol
}
elseif ($Provider -and $Provider.tunnelProtocol) {
    [string]$Provider.tunnelProtocol
}
else {
    [string]$Config.tunnelProtocol
}
$EffectiveHostExecMode = if ($HostExecMode) { $HostExecMode } else { [string]$Config.hostExecMode }
$McpPort = if ($Provider -and $Provider.localPort) { [int]$Provider.localPort } else { 8787 }

if ([string]::IsNullOrWhiteSpace($Hostname)) { throw 'Cloudflare hostname is not configured.' }
if ([string]::IsNullOrWhiteSpace($TunnelName)) { throw 'Cloudflare tunnel name is not configured.' }
if ($EffectiveTunnelProtocol -notin @('auto', 'quic', 'http2')) { throw "Invalid Cloudflare tunnel protocol: $EffectiveTunnelProtocol" }
if ($EffectiveHostExecMode -notin @('off', 'on-request', 'full-access')) { throw "Invalid host execution mode: $EffectiveHostExecMode" }
if (-not (Test-Path -LiteralPath $Cloudflared -PathType Leaf)) { throw "cloudflared is unavailable: $Cloudflared" }
if (-not (Test-Path -LiteralPath $TokenFile -PathType Leaf)) { throw "CodexPro MCP token not found: $TokenFile" }

$RequiredPaths = @(
    [string]$Config.packageDir,
    [string]$Config.gitBash,
    [string]$Config.codexExecutable,
    [string]$Config.codexProExecutable
)
foreach ($RequiredPath in $RequiredPaths) {
    if ([string]::IsNullOrWhiteSpace($RequiredPath) -or -not (Test-Path -LiteralPath $RequiredPath)) {
        throw "Required CodexPro deployment path is unavailable: $RequiredPath"
    }
}

$DistDir = Join-Path ([string]$Config.packageDir) 'dist'
$MarkerChecks = @(
    @{ Path = Join-Path $DistDir 'bashOps.js'; Marker = 'function sandboxInvocation(config, workspace, cwd, command)' },
    @{ Path = Join-Path $DistDir 'config.js'; Marker = 'CODEXPRO_HOST_EXEC_MODE' },
    @{ Path = Join-Path $DistDir 'server.js'; Marker = 'registerCodexTool(config, server, "host_exec"' },
    @{ Path = Join-Path $DistDir 'hostOps.js'; Marker = 'function requestLocalApproval(request)' }
)
foreach ($Check in $MarkerChecks) {
    if (-not (Test-Path -LiteralPath $Check.Path -PathType Leaf) -or -not [IO.File]::ReadAllText($Check.Path).Contains($Check.Marker)) {
        throw "Required CodexPro patch marker is missing: $($Check.Path)"
    }
}

$McpToken = [IO.File]::ReadAllText($TokenFile).Trim()
if ($McpToken.Length -ne 64 -or $McpToken -notmatch '^[0-9a-f]{64}$') {
    throw "CodexPro MCP token is invalid: $TokenFile"
}

$ResolvedRoot = (Resolve-Path -LiteralPath $Root).Path
$PathDirs = @(
    (Split-Path -Parent ([string]$Config.gitBash))
    (Split-Path -Parent ([string]$Config.codexExecutable))
    (Split-Path -Parent ([string]$Config.codexProExecutable))
    (Split-Path -Parent $Cloudflared)
) | Where-Object { $_ } | Select-Object -Unique

$PreviousPath = $env:PATH
$PreviousBashSandbox = $env:CODEXPRO_BASH_SANDBOX
$PreviousBashExecutable = $env:CODEXPRO_BASH_EXECUTABLE
$PreviousHostExecMode = $env:CODEXPRO_HOST_EXEC_MODE
$PreviousTunnelTransportProtocol = $env:TUNNEL_TRANSPORT_PROTOCOL

$env:PATH = (($PathDirs + @($PreviousPath)) -join ';')
$env:CODEXPRO_BASH_SANDBOX = 'workspace'
$env:CODEXPRO_BASH_EXECUTABLE = [string]$Config.gitBash
$env:CODEXPRO_HOST_EXEC_MODE = $EffectiveHostExecMode
$env:TUNNEL_TRANSPORT_PROTOCOL = $EffectiveTunnelProtocol

$QueryKey = 'codexpro_' + 'token'
$ConnectorUrl = "https://$Hostname/mcp?$QueryKey=$([uri]::EscapeDataString($McpToken))"
$ClipboardCopied = $false
try {
    Set-Clipboard -Value $ConnectorUrl -ErrorAction Stop
    $ClipboardCopied = $true
}
catch {
    Write-Warning 'Could not copy the secret connector URL to the clipboard. Use Get-CodexProConnectorUrl.ps1 explicitly if needed.'
}

Write-Host "CodexPro workspace: $ResolvedRoot"
Write-Host 'Exposure:           Cloudflare named tunnel'
Write-Host "Local MCP:          http://127.0.0.1:$McpPort/mcp"
Write-Host "Public MCP:         https://$Hostname/mcp"
Write-Host "Tunnel:             $TunnelName"
Write-Host "Transport:          $EffectiveTunnelProtocol"
Write-Host 'Authentication:     query token'
if ($ClipboardCopied) { Write-Host 'Connector URL:       copied to clipboard (token hidden)' }
Write-Host ''

$CodexProArgs = @(
    'start',
    '--no-profile',
    '--root', $ResolvedRoot,
    '--tunnel', 'cloudflare-named',
    '--hostname', $Hostname,
    '--tunnel-name', $TunnelName,
    '--host', '127.0.0.1',
    '--port', "$McpPort",
    '--token', $McpToken,
    '--cloudflared', $Cloudflared,
    '--agent',
    '--tool-mode', 'full',
    '--write', 'workspace',
    '--bash', 'full',
    '--log-requests',
    '--no-copy-url'
)

try {
    & ([string]$Config.codexProExecutable) @CodexProArgs
    if ($LASTEXITCODE -ne 0) { throw "CodexPro exited with code $LASTEXITCODE." }
}
finally {
    $env:CODEXPRO_BASH_EXECUTABLE = $PreviousBashExecutable
    $env:CODEXPRO_BASH_SANDBOX = $PreviousBashSandbox
    $env:CODEXPRO_HOST_EXEC_MODE = $PreviousHostExecMode
    $env:TUNNEL_TRANSPORT_PROTOCOL = $PreviousTunnelTransportProtocol
    $env:PATH = $PreviousPath
}
