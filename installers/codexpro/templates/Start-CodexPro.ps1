$ErrorActionPreference = 'Stop'

$ConfigFile = Join-Path $PSScriptRoot 'deployment.json'
if (-not (Test-Path -LiteralPath $ConfigFile -PathType Leaf)) {
    throw "CodexPro deployment configuration not found: $ConfigFile"
}
$Config = Get-Content -LiteralPath $ConfigFile -Raw | ConvertFrom-Json

[string[]]$ConfiguredTunnels = @()
if ($Config.tunnels) {
    $ConfiguredTunnels = @($Config.tunnels | ForEach-Object { ([string]$_).ToLowerInvariant() })
}
elseif ($Config.hostname) {
    $ConfiguredTunnels = @('cloudflare')
}
if ($ConfiguredTunnels.Count -eq 0) {
    throw 'No CodexPro tunnel provider is configured.'
}

$DefaultTunnel = if ($Config.defaultTunnel) {
    ([string]$Config.defaultTunnel).ToLowerInvariant()
}
else {
    $ConfiguredTunnels[0]
}

$Mode = $DefaultTunnel
$ModeSet = $false
$Root = (Get-Location).Path
$RootSet = $false
$HostExecMode = ''
$TunnelProtocol = ''
$NgrokHostname = $null

function Set-Mode {
    param([Parameter(Mandatory)][string]$Value)

    if ($script:ModeSet -and $script:Mode -ne $Value) {
        throw 'Choose only one mode: --openai, --cf, or --ngrok.'
    }
    $script:Mode = $Value
    $script:ModeSet = $true
}

for ($i = 0; $i -lt $args.Count; $i++) {
    $Argument = [string]$args[$i]

    if ($Argument -eq '--openai') { Set-Mode 'openai'; continue }
    if ($Argument -eq '--cf') { Set-Mode 'cloudflare'; continue }
    if ($Argument -eq '--ngrok') { Set-Mode 'ngrok'; continue }

    if ($Argument -in @('-h', '--help')) {
        @"
Usage:
  cpx [root]
  cpx [root] --openai
  cpx [root] --cf
  cpx [root] --ngrok

Configured: $($ConfiguredTunnels -join ', ')
Default:    $DefaultTunnel

Options:
  --root <path>
  --host-exec-mode <off|on-request|full-access>
  --tunnel-protocol <auto|quic|http2>      Cloudflare only
  --ngrok-hostname <hostname>              ngrok only
  -h, --help
"@ | Write-Host
        return
    }

    if ($Argument -eq '--root') {
        if ($i + 1 -ge $args.Count) { throw '--root requires a path.' }
        $i++
        $Root = [string]$args[$i]
        $RootSet = $true
        continue
    }

    if ($Argument -eq '--host-exec-mode') {
        if ($i + 1 -ge $args.Count) { throw '--host-exec-mode requires a value.' }
        $i++
        $HostExecMode = [string]$args[$i]
        if ($HostExecMode -notin @('off', 'on-request', 'full-access')) {
            throw "Invalid host execution mode: $HostExecMode"
        }
        continue
    }

    if ($Argument -eq '--tunnel-protocol') {
        if ($i + 1 -ge $args.Count) { throw '--tunnel-protocol requires a value.' }
        $i++
        $TunnelProtocol = [string]$args[$i]
        if ($TunnelProtocol -notin @('auto', 'quic', 'http2')) {
            throw "Invalid tunnel protocol: $TunnelProtocol"
        }
        continue
    }

    if ($Argument -eq '--ngrok-hostname') {
        if ($i + 1 -ge $args.Count) { throw '--ngrok-hostname requires a hostname.' }
        $i++
        $NgrokHostname = [string]$args[$i]
        continue
    }

    if ($Argument.StartsWith('-')) {
        throw "Unknown cpx option: $Argument"
    }

    if ($RootSet) {
        throw "Unexpected positional argument: $Argument"
    }

    $Root = $Argument
    $RootSet = $true
}

if ($Mode -notin $ConfiguredTunnels) {
    throw "CodexPro tunnel provider '$Mode' is not configured. Configured providers: $($ConfiguredTunnels -join ', ')."
}

switch ($Mode) {
    'openai' {
        $Launcher = Join-Path $PSScriptRoot 'Start-CodexPro.openai.ps1'
        $Parameters = @{ Root = $Root }
        if ($HostExecMode) { $Parameters.HostExecMode = $HostExecMode }
        & $Launcher @Parameters
        return
    }
    'cloudflare' {
        $Launcher = Join-Path $PSScriptRoot 'Start-CodexPro.cloudflare.ps1'
        $Parameters = @{ Root = $Root }
        if ($HostExecMode) { $Parameters.HostExecMode = $HostExecMode }
        if ($TunnelProtocol) { $Parameters.TunnelProtocol = $TunnelProtocol }
        & $Launcher @Parameters
        return
    }
    'ngrok' {
        $Launcher = Join-Path $PSScriptRoot 'Start-CodexPro.ngrok.ps1'
        $Parameters = @{ Root = $Root }
        if ($HostExecMode) { $Parameters.HostExecMode = $HostExecMode }
        if ($NgrokHostname) { $Parameters.Hostname = $NgrokHostname }
        & $Launcher @Parameters
        return
    }
    default {
        throw "Unsupported CodexPro tunnel provider: $Mode"
    }
}
