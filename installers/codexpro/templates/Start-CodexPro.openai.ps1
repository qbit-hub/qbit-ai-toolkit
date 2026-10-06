[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Root = (Get-Location).Path,

    [ValidateSet('', 'off', 'on-request', 'full-access')]
    [string]$HostExecMode = ''
)

$ErrorActionPreference = 'Stop'
$ConfigFile = Join-Path $PSScriptRoot 'deployment.json'

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
else {
    @()
}
if ('openai' -notin $ConfiguredTunnels -or -not $Config.providers -or -not $Config.providers.openai) {
    throw 'OpenAI Secure MCP Tunnel is not configured for this CodexPro deployment.'
}

$Provider = $Config.providers.openai
$TunnelClient = [string]$Provider.tunnelClient
$TunnelIdFile = [string]$Provider.tunnelIdFile
$RuntimeKeyFile = [string]$Provider.runtimeKeyFile
$TunnelAlias = [string]$Provider.alias
$TunnelProfile = [string]$Provider.profile
$ProfileDir = [string]$Provider.profileDir
$McpPort = if ($Provider.localPort) { [int]$Provider.localPort } else { 8788 }
$EffectiveHostExecMode = if ($HostExecMode) { $HostExecMode } else { [string]$Config.hostExecMode }

if ($EffectiveHostExecMode -notin @('off', 'on-request', 'full-access')) {
    throw "Invalid host execution mode: $EffectiveHostExecMode"
}
foreach ($Required in @($TunnelClient, $TunnelIdFile, $RuntimeKeyFile)) {
    if ([string]::IsNullOrWhiteSpace($Required) -or -not (Test-Path -LiteralPath $Required -PathType Leaf)) {
        throw "Required OpenAI tunnel asset is unavailable: $Required"
    }
}
if ([string]::IsNullOrWhiteSpace($TunnelAlias)) { throw 'OpenAI tunnel alias is not configured.' }
if ([string]::IsNullOrWhiteSpace($TunnelProfile)) { throw 'OpenAI tunnel runtime profile is not configured.' }
if ([string]::IsNullOrWhiteSpace($ProfileDir) -or -not (Test-Path -LiteralPath $ProfileDir -PathType Container)) { throw "OpenAI tunnel profile directory is unavailable: $ProfileDir" }

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

$TunnelId = [IO.File]::ReadAllText($TunnelIdFile).Trim()
if ([string]::IsNullOrWhiteSpace($TunnelId)) {
    throw "OpenAI tunnel id file is empty: $TunnelIdFile"
}
if ((Get-Item -LiteralPath $RuntimeKeyFile).Length -le 0) {
    throw "OpenAI runtime key file is empty: $RuntimeKeyFile"
}

function Get-RuntimeStatus {
    $Raw = & $TunnelClient runtimes status $TunnelAlias --json 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $Raw) { return $null }
    try {
        return (($Raw -join [Environment]::NewLine) | ConvertFrom-Json)
    }
    catch {
        return $null
    }
}

function Test-RuntimeReady {
    param($Status)

    if (-not $Status) { return $false }
    $Running = ([bool]$Status.process_running) -or ([bool]$Status.running)
    return $Running -and
        ([string]$Status.runtime_state -eq 'ready') -and
        [string]::IsNullOrWhiteSpace([string]$Status.remote_error)
}

$RuntimeStatus = Get-RuntimeStatus
if (-not (Test-RuntimeReady $RuntimeStatus)) {
    Write-Host 'Starting OpenAI tunnel runtime...'
    $RuntimeArgs = @(
        'runtimes', 'connect',
        '--alias', $TunnelAlias,
        '--profile', $TunnelProfile,
        '--profile-dir', $ProfileDir,
        '--tunnel-id', $TunnelId,
        '--mcp-server-url', "http://127.0.0.1:$McpPort/mcp",
        '--runtime-api-key', ('file:' + $RuntimeKeyFile),
        '--json'
    )
    & $TunnelClient @RuntimeArgs | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "OpenAI tunnel runtime connect failed with exit code $LASTEXITCODE."
    }

    for ($Attempt = 0; $Attempt -lt 5; $Attempt++) {
        $RuntimeStatus = Get-RuntimeStatus
        if (Test-RuntimeReady $RuntimeStatus) { break }
        Start-Sleep -Seconds 1
    }
}

if (-not (Test-RuntimeReady $RuntimeStatus)) {
    $RemoteError = if ($RuntimeStatus) { [string]$RuntimeStatus.remote_error } else { 'status unavailable' }
    throw "OpenAI tunnel runtime is not remotely ready. $RemoteError"
}

$ResolvedRoot = (Resolve-Path -LiteralPath $Root).Path
$PathDirs = @(
    (Split-Path -Parent ([string]$Config.gitBash))
    (Split-Path -Parent ([string]$Config.codexExecutable))
    (Split-Path -Parent ([string]$Config.codexProExecutable))
    (Split-Path -Parent $TunnelClient)
) | Where-Object { $_ } | Select-Object -Unique

$PreviousPath = $env:PATH
$PreviousBashSandbox = $env:CODEXPRO_BASH_SANDBOX
$PreviousBashExecutable = $env:CODEXPRO_BASH_EXECUTABLE
$PreviousHostExecMode = $env:CODEXPRO_HOST_EXEC_MODE

$env:PATH = (($PathDirs + @($PreviousPath)) -join ';')
$env:CODEXPRO_BASH_SANDBOX = 'workspace'
$env:CODEXPRO_BASH_EXECUTABLE = [string]$Config.gitBash
$env:CODEXPRO_HOST_EXEC_MODE = $EffectiveHostExecMode

Write-Host "CodexPro workspace: $ResolvedRoot"
Write-Host 'Exposure:           OpenAI Secure MCP Tunnel'
Write-Host "Local MCP:          http://127.0.0.1:$McpPort/mcp"
Write-Host "Tunnel:             $TunnelAlias"
Write-Host ''

$CodexProArgs = @(
    'start',
    '--no-profile',
    '--root', $ResolvedRoot,
    '--tunnel', 'none',
    '--host', '127.0.0.1',
    '--port', "$McpPort",
    '--no-auth',
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
