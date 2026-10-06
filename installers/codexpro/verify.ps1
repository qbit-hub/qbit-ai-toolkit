[CmdletBinding()]
param(
    [string]$StateDir = (Join-Path $HOME '.codexpro'),
    [switch]$SkipTunnelCheck
)

$ErrorActionPreference = 'Stop'
$ExpectedCodexProVersion = '0.29.0'
$Errors = New-Object System.Collections.Generic.List[string]
$Warnings = New-Object System.Collections.Generic.List[string]
$Checks = New-Object System.Collections.Generic.List[object]

function Add-Check {
    param([string]$Name, [bool]$Passed, [string]$Detail)
    $Checks.Add([pscustomobject]@{ name = $Name; passed = $Passed; detail = $Detail }) | Out-Null
    if (-not $Passed) { $Errors.Add("${Name}: $Detail") | Out-Null }
}

function Test-LeafPath {
    param([string]$Path)
    return -not [string]::IsNullOrWhiteSpace($Path) -and (Test-Path -LiteralPath $Path -PathType Leaf)
}

if ($env:OS -ne 'Windows_NT') {
    throw 'installer.codexpro verification is Windows-only.'
}

$DeploymentPath = Join-Path $StateDir 'deployment.json'
$TokenPath = Join-Path $StateDir 'http-token'
if (-not (Test-Path -LiteralPath $DeploymentPath -PathType Leaf)) {
    throw "CodexPro deployment state not found: $DeploymentPath"
}

$Deployment = Get-Content -LiteralPath $DeploymentPath -Raw | ConvertFrom-Json
$SchemaVersion = if ($Deployment.schemaVersion) { [int]$Deployment.schemaVersion } else { 1 }
[string[]]$SelectedTunnels = if ($Deployment.tunnels) {
    @($Deployment.tunnels | ForEach-Object { ([string]$_).ToLowerInvariant() })
}
elseif ($Deployment.hostname) {
    @('cloudflare')
}
else {
    @()
}
$DefaultTunnel = if ($Deployment.defaultTunnel) {
    ([string]$Deployment.defaultTunnel).ToLowerInvariant()
}
elseif ($SelectedTunnels.Count -gt 0) {
    $SelectedTunnels[0]
}
else {
    ''
}

Add-Check 'installer ownership' ($Deployment.installerId -eq 'installer.codexpro') "installerId=$($Deployment.installerId)"
Add-Check 'workspace root' (Test-Path -LiteralPath ([string]$Deployment.workspaceRoot) -PathType Container) ([string]$Deployment.workspaceRoot)
Add-Check 'tunnel selection' ($SelectedTunnels.Count -gt 0) (($SelectedTunnels -join ', '))
Add-Check 'default tunnel' ($DefaultTunnel -in $SelectedTunnels) $DefaultTunnel

$ManagedAssets = if ($SchemaVersion -ge 2 -and $Deployment.managedAssets) {
    @($Deployment.managedAssets | ForEach-Object { [string]$_ })
}
else {
    @('Start-CodexPro.ps1', 'Get-CodexProConnectorUrl.ps1')
}
foreach ($AssetName in $ManagedAssets) {
    $AssetPath = Join-Path $StateDir $AssetName
    Add-Check "managed asset: $AssetName" (Test-Path -LiteralPath $AssetPath -PathType Leaf) $AssetPath
}

$NeedsHttpToken = ('cloudflare' -in $SelectedTunnels) -or ('ngrok' -in $SelectedTunnels)
if ($NeedsHttpToken) {
    $TokenValid = $false
    if (Test-Path -LiteralPath $TokenPath -PathType Leaf) {
        $Token = [IO.File]::ReadAllText($TokenPath).Trim()
        $TokenValid = $Token.Length -eq 64 -and $Token -match '^[0-9a-f]{64}$'
    }
    Add-Check 'MCP token' $TokenValid '64-character lowercase hexadecimal token present; value not displayed'
}
else {
    Add-Check 'MCP token not required' (-not (Test-Path -LiteralPath $TokenPath -PathType Leaf) -or [bool]$Deployment.tokenWasPresentBefore) 'OpenAI-only deployment does not require a CodexPro HTTP token'
}

$PackageDir = [string]$Deployment.packageDir
$PackageJson = Join-Path $PackageDir 'package.json'
$PackageVersionOk = $false
if (Test-Path -LiteralPath $PackageJson -PathType Leaf) {
    $Package = Get-Content -LiteralPath $PackageJson -Raw | ConvertFrom-Json
    $PackageVersionOk = $Package.name -eq 'codexpro' -and $Package.version -eq $ExpectedCodexProVersion
}
Add-Check 'CodexPro package version' $PackageVersionOk "$PackageDir (expected $ExpectedCodexProVersion)"

$MarkerChecks = @(
    @{ Name = 'workspace Bash sandbox'; Path = Join-Path $PackageDir 'dist\bashOps.js'; Marker = 'function sandboxInvocation(config, workspace, cwd, command)' },
    @{ Name = 'Windows environment allowlist'; Path = Join-Path $PackageDir 'dist\bashOps.js'; Marker = 'env.USERPROFILE = userProfile;' },
    @{ Name = 'host execution config'; Path = Join-Path $PackageDir 'dist\config.js'; Marker = 'CODEXPRO_HOST_EXEC_MODE' },
    @{ Name = 'host_exec registration'; Path = Join-Path $PackageDir 'dist\server.js'; Marker = 'registerCodexTool(config, server, "host_exec"' },
    @{ Name = 'open_app registration'; Path = Join-Path $PackageDir 'dist\server.js'; Marker = 'registerCodexTool(config, server, "open_app"' },
    @{ Name = 'host execution implementation'; Path = Join-Path $PackageDir 'dist\hostOps.js'; Marker = 'function requestLocalApproval(request)' }
)
foreach ($Check in $MarkerChecks) {
    $Passed = Test-Path -LiteralPath $Check.Path -PathType Leaf
    if ($Passed) {
        $Passed = [IO.File]::ReadAllText($Check.Path).Contains($Check.Marker)
    }
    Add-Check $Check.Name $Passed $Check.Path
}

foreach ($PathCheck in @(
    @{ Name = 'Git executable'; Path = [string]$Deployment.gitExecutable },
    @{ Name = 'Git Bash'; Path = [string]$Deployment.gitBash },
    @{ Name = 'Codex CLI'; Path = [string]$Deployment.codexExecutable },
    @{ Name = 'CodexPro executable'; Path = [string]$Deployment.codexProExecutable }
)) {
    Add-Check $PathCheck.Name (Test-LeafPath $PathCheck.Path) $PathCheck.Path
}

$CodexPath = [string]$Deployment.codexExecutable
$CodexLoggedIn = $false
if (Test-LeafPath $CodexPath) {
    & $CodexPath login status *> $null
    $CodexLoggedIn = $LASTEXITCODE -eq 0
}
Add-Check 'Codex CLI authentication' $CodexLoggedIn 'codex login status'

if ([bool]$Deployment.profileManaged) {
    $ProfilePath = [string]$Deployment.profilePath
    $ProfileOk = $false
    if (Test-Path -LiteralPath $ProfilePath -PathType Leaf) {
        $ProfileText = [IO.File]::ReadAllText($ProfilePath)
        $ProfileOk =
            $ProfileText.Contains('# >>> qbit codexpro >>>') -and
            $ProfileText.Contains('# <<< qbit codexpro <<<') -and
            $ProfileText.Contains('& $launcher @args')
    }
    Add-Check 'PowerShell cpx helper' $ProfileOk $ProfilePath
}

if ('cloudflare' -in $SelectedTunnels) {
    $Provider = if ($Deployment.providers -and $Deployment.providers.cloudflare) { $Deployment.providers.cloudflare } else { $null }
    $Hostname = if ($Provider -and $Provider.hostname) { [string]$Provider.hostname } else { [string]$Deployment.hostname }
    $TunnelName = if ($Provider -and $Provider.tunnelName) { [string]$Provider.tunnelName } else { [string]$Deployment.tunnelName }
    $Cloudflared = if ($Provider -and $Provider.executable) { [string]$Provider.executable } else { [string]$Deployment.cloudflaredExecutable }
    $TunnelProtocol = if ($Provider -and $Provider.tunnelProtocol) { [string]$Provider.tunnelProtocol } else { [string]$Deployment.tunnelProtocol }
    $Provisioned = if ($Provider -and $null -ne $Provider.provisioned) { [bool]$Provider.provisioned } else { [bool]$Deployment.tunnelConfigured }

    Add-Check 'Cloudflare hostname' (-not [string]::IsNullOrWhiteSpace($Hostname)) $Hostname
    Add-Check 'Cloudflare tunnel name' (-not [string]::IsNullOrWhiteSpace($TunnelName)) $TunnelName
    Add-Check 'Cloudflare transport' ($TunnelProtocol -in @('auto', 'quic', 'http2')) $TunnelProtocol
    Add-Check 'cloudflared' (Test-LeafPath $Cloudflared) $Cloudflared

    if ($Provisioned -and -not $SkipTunnelCheck) {
        $TunnelOk = $false
        if (Test-LeafPath $Cloudflared) {
            $Json = & $Cloudflared tunnel list --output json 2>$null
            if ($LASTEXITCODE -eq 0 -and $Json) {
                try {
                    $Tunnels = @(($Json -join [Environment]::NewLine) | ConvertFrom-Json)
                    $TunnelOk = $null -ne ($Tunnels | Where-Object { $_.name -eq $TunnelName } | Select-Object -First 1)
                }
                catch {
                    $Warnings.Add('cloudflared tunnel list returned output that could not be parsed as JSON.') | Out-Null
                }
            }
        }
        Add-Check 'Cloudflare named tunnel' $TunnelOk $TunnelName
    }
}

if ('ngrok' -in $SelectedTunnels) {
    $Provider = if ($Deployment.providers) { $Deployment.providers.ngrok } else { $null }
    $Hostname = if ($Provider) { [string]$Provider.hostname } else { '' }
    $NgrokExecutable = if ($Provider) { [string]$Provider.executable } else { '' }
    $NgrokConfigPath = if ($Provider) { [string]$Provider.configPath } else { '' }

    Add-Check 'ngrok hostname' (-not [string]::IsNullOrWhiteSpace($Hostname)) $Hostname
    Add-Check 'ngrok executable' (Test-LeafPath $NgrokExecutable) $NgrokExecutable
    Add-Check 'ngrok config' (Test-LeafPath $NgrokConfigPath) $NgrokConfigPath

    $NgrokConfigOk = $false
    if ((Test-LeafPath $NgrokExecutable) -and (Test-LeafPath $NgrokConfigPath)) {
        & $NgrokExecutable config check --config $NgrokConfigPath *> $null
        $NgrokConfigOk = $LASTEXITCODE -eq 0
    }
    Add-Check 'ngrok config validation' $NgrokConfigOk 'ngrok config check succeeded; credential contents not displayed'
}

if ('openai' -in $SelectedTunnels) {
    $Provider = if ($Deployment.providers) { $Deployment.providers.openai } else { $null }
    $TunnelClient = if ($Provider) { [string]$Provider.tunnelClient } else { '' }
    $TunnelIdFile = if ($Provider) { [string]$Provider.tunnelIdFile } else { '' }
    $RuntimeKeyFile = if ($Provider) { [string]$Provider.runtimeKeyFile } else { '' }
    $Alias = if ($Provider) { [string]$Provider.alias } else { '' }
    $Profile = if ($Provider) { [string]$Provider.profile } else { '' }
    $ProfileDir = if ($Provider) { [string]$Provider.profileDir } else { '' }

    Add-Check 'OpenAI tunnel-client' (Test-LeafPath $TunnelClient) $TunnelClient
    Add-Check 'OpenAI tunnel id file' (Test-LeafPath $TunnelIdFile) $TunnelIdFile
    Add-Check 'OpenAI runtime key file' (Test-LeafPath $RuntimeKeyFile) 'runtime key file present; value not displayed'
    Add-Check 'OpenAI tunnel alias' (-not [string]::IsNullOrWhiteSpace($Alias)) $Alias
    Add-Check 'OpenAI tunnel profile' (-not [string]::IsNullOrWhiteSpace($Profile)) $Profile
    Add-Check 'OpenAI profile directory' (-not [string]::IsNullOrWhiteSpace($ProfileDir) -and (Test-Path -LiteralPath $ProfileDir -PathType Container)) $ProfileDir

    if (Test-LeafPath $TunnelIdFile) {
        $TunnelIdPresent = -not [string]::IsNullOrWhiteSpace([IO.File]::ReadAllText($TunnelIdFile).Trim())
        Add-Check 'OpenAI tunnel id' $TunnelIdPresent 'tunnel id present; value not displayed'
    }
    if (Test-LeafPath $RuntimeKeyFile) {
        Add-Check 'OpenAI runtime key' ((Get-Item -LiteralPath $RuntimeKeyFile).Length -gt 0) 'runtime key present; value not displayed'
    }
}

$Result = [pscustomobject]@{
    status = if ($Errors.Count -eq 0) { 'ok' } else { 'error' }
    installer = 'installer.codexpro'
    stateDir = $StateDir
    tunnels = $SelectedTunnels
    defaultTunnel = $DefaultTunnel
    checks = $Checks
    warnings = $Warnings
    errors = $Errors
}
$Result | ConvertTo-Json -Depth 7

if ($Errors.Count -gt 0) {
    throw "CodexPro verification failed: $($Errors -join '; ')"
}
