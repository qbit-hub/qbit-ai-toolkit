[CmdletBinding()]
param(
    [ValidateSet('', 'cloudflare', 'ngrok', 'openai')]
    [string]$Mode = ''
)

$ErrorActionPreference = 'Stop'
$ConfigFile = Join-Path $PSScriptRoot 'deployment.json'
$TokenFile = Join-Path $PSScriptRoot 'http-token'

if (-not (Test-Path -LiteralPath $ConfigFile -PathType Leaf)) {
    throw "CodexPro deployment configuration not found: $ConfigFile"
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

if (-not $Mode) {
    $Candidate = if ($Config.defaultTunnel) {
        ([string]$Config.defaultTunnel).ToLowerInvariant()
    }
    else {
        $ConfiguredTunnels[0]
    }

    if ($Candidate -in @('cloudflare', 'ngrok')) {
        $Mode = $Candidate
    }
    else {
        $TokenProviders = @($ConfiguredTunnels | Where-Object { $_ -in @('cloudflare', 'ngrok') })
        if ($TokenProviders.Count -eq 1) {
            $Mode = $TokenProviders[0]
        }
        else {
            throw 'OpenAI Secure MCP Tunnel does not use a custom token-bearing Server URL. Specify -Mode cloudflare or -Mode ngrok for a configured custom URL provider.'
        }
    }
}

if ($Mode -eq 'openai') {
    throw 'OpenAI Secure MCP Tunnel does not use a custom token-bearing Server URL. Connect it through the OpenAI tunnel integration.'
}
if ($Mode -notin $ConfiguredTunnels) {
    throw "CodexPro tunnel provider '$Mode' is not configured."
}
if (-not (Test-Path -LiteralPath $TokenFile -PathType Leaf)) {
    throw "CodexPro MCP token not found: $TokenFile"
}

$Hostname = switch ($Mode) {
    'cloudflare' {
        if ($Config.providers -and $Config.providers.cloudflare) {
            [string]$Config.providers.cloudflare.hostname
        }
        else {
            [string]$Config.hostname
        }
    }
    'ngrok' {
        [string]$Config.providers.ngrok.hostname
    }
}

if ([string]::IsNullOrWhiteSpace($Hostname)) {
    throw "No hostname is configured for $Mode."
}

$Token = [IO.File]::ReadAllText($TokenFile).Trim()
if ($Token.Length -ne 64 -or $Token -notmatch '^[0-9a-f]{64}$') {
    throw 'CodexPro MCP token is invalid.'
}

$QueryKey = 'codexpro_' + 'token'
"https://$Hostname/mcp?$QueryKey=$([uri]::EscapeDataString($Token))"
