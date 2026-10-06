[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Root = (Get-Location).Path,

    [ValidateSet('', 'off', 'on-request', 'full-access')]
    [string]$HostExecMode = '',

    [string]$Hostname
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
if (-not (Test-Path -LiteralPath $TokenFile -PathType Leaf)) {
    throw "CodexPro MCP token not found: $TokenFile"
}

$Config = Get-Content -LiteralPath $ConfigFile -Raw | ConvertFrom-Json
[string[]]$ConfiguredTunnels = if ($Config.tunnels) {
    @($Config.tunnels | ForEach-Object { ([string]$_).ToLowerInvariant() })
}
else {
    @()
}
if ('ngrok' -notin $ConfiguredTunnels -or -not $Config.providers -or -not $Config.providers.ngrok) {
    throw 'ngrok is not configured for this CodexPro deployment.'
}

$Provider = $Config.providers.ngrok
$EffectiveHostname = if ($Hostname) { $Hostname } else { [string]$Provider.hostname }
$NgrokExecutable = [string]$Provider.executable
$NgrokConfig = [string]$Provider.configPath
$McpPort = if ($Provider.localPort) { [int]$Provider.localPort } else { 8789 }
$EffectiveHostExecMode = if ($HostExecMode) { $HostExecMode } else { [string]$Config.hostExecMode }

if ([string]::IsNullOrWhiteSpace($EffectiveHostname)) { throw 'ngrok hostname is not configured.' }
if ($EffectiveHostExecMode -notin @('off', 'on-request', 'full-access')) { throw "Invalid host execution mode: $EffectiveHostExecMode" }
if (-not (Test-Path -LiteralPath $NgrokExecutable -PathType Leaf)) { throw "ngrok executable is unavailable: $NgrokExecutable" }
if (-not (Test-Path -LiteralPath $NgrokConfig -PathType Leaf)) { throw "ngrok configuration is unavailable: $NgrokConfig" }

& $NgrokExecutable config check --config $NgrokConfig *> $null
if ($LASTEXITCODE -ne 0) { throw "ngrok configuration is invalid: $NgrokConfig" }

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
    (Split-Path -Parent $NgrokExecutable)
) | Where-Object { $_ } | Select-Object -Unique

$PreviousPath = $env:PATH
$PreviousBashSandbox = $env:CODEXPRO_BASH_SANDBOX
$PreviousBashExecutable = $env:CODEXPRO_BASH_EXECUTABLE
$PreviousHostExecMode = $env:CODEXPRO_HOST_EXEC_MODE

$env:PATH = (($PathDirs + @($PreviousPath)) -join ';')
$env:CODEXPRO_BASH_SANDBOX = 'workspace'
$env:CODEXPRO_BASH_EXECUTABLE = [string]$Config.gitBash
$env:CODEXPRO_HOST_EXEC_MODE = $EffectiveHostExecMode

$QueryKey = 'codexpro_' + 'token'
$ConnectorUrl = "https://$EffectiveHostname/mcp?$QueryKey=$([uri]::EscapeDataString($McpToken))"
$ClipboardCopied = $false
try {
    Set-Clipboard -Value $ConnectorUrl -ErrorAction Stop
    $ClipboardCopied = $true
}
catch {
    Write-Warning 'Could not copy the secret connector URL to the clipboard. Use Get-CodexProConnectorUrl.ps1 explicitly if needed.'
}

Write-Host "CodexPro workspace: $ResolvedRoot"
Write-Host 'Exposure:           ngrok'
Write-Host "Local MCP:          http://127.0.0.1:$McpPort/mcp"
Write-Host "Public MCP:         https://$EffectiveHostname/mcp"
Write-Host 'Authentication:     query token'
if ($ClipboardCopied) { Write-Host 'Connector URL:       copied to clipboard (token hidden)' }
Write-Host ''

$CodexProArgs = @(
    'start',
    '--no-profile',
    '--root', $ResolvedRoot,
    '--tunnel', 'ngrok',
    '--hostname', $EffectiveHostname,
    '--host', '127.0.0.1',
    '--port', "$McpPort",
    '--token', $McpToken,
    '--ngrok', $NgrokExecutable,
    '--ngrok-config', $NgrokConfig,
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
    $env:PATH = $PreviousPath
}
