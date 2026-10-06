[CmdletBinding()]
param(
    [string]$WorkspaceRoot = '',
    [string]$Hostname = 'codexpro.test.example.com',
    [string]$TunnelName = 'codexpro-test'
)

$ErrorActionPreference = 'Stop'
$InstallerRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
if (-not $WorkspaceRoot) {
    $WorkspaceRoot = (Resolve-Path -LiteralPath (Join-Path $InstallerRoot '..\..')).Path
}
elseif (-not (Test-Path -LiteralPath $WorkspaceRoot -PathType Container)) {
    throw "WorkspaceRoot does not exist: $WorkspaceRoot"
}
else {
    $WorkspaceRoot = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
}

$InstallScript = Join-Path $InstallerRoot 'install.ps1'
$UninstallScript = Join-Path $InstallerRoot 'uninstall.ps1'
$TempRoot = Join-Path $env:TEMP ("qbit-codexpro-installer-test-" + [guid]::NewGuid().ToString('N'))
$CodexProBefore = Get-Command codexpro -ErrorAction SilentlyContinue | Select-Object -First 1
$CodexProBeforePath = if ($CodexProBefore) { $CodexProBefore.Source } else { $null }
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$ActiveStates = New-Object System.Collections.Generic.List[string]

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Assert-ThrowsLike {
    param(
        [Parameter(Mandatory)][scriptblock]$Action,
        [Parameter(Mandatory)][string]$Pattern,
        [Parameter(Mandatory)][string]$Message
    )
    try {
        & $Action
    }
    catch {
        if ($_.Exception.Message -like $Pattern) { return }
        throw "$Message Unexpected error: $($_.Exception.Message)"
    }
    throw $Message
}

function New-FakeCommand {
    param([Parameter(Mandatory)][string]$Path)
    [IO.File]::WriteAllText($Path, ("@echo off" + [Environment]::NewLine + "exit /b 0" + [Environment]::NewLine), $Utf8NoBom)
}

function New-FakeTunnelClient {
    param([Parameter(Mandatory)][string]$Path)
    $Json = '{"process_running":true,"running":true,"runtime_state":"ready","remote_error":""}'
    [IO.File]::WriteAllText($Path, ("@echo off" + [Environment]::NewLine + "echo " + $Json + [Environment]::NewLine + "exit /b 0" + [Environment]::NewLine), $Utf8NoBom)
}

function Set-Clipboard {
    [CmdletBinding()]
    param([Parameter(ValueFromPipeline = $true)]$Value)
    process { }
}

function Invoke-Cleanup {
    foreach ($StateDir in @($ActiveStates)) {
        if (Test-Path -LiteralPath (Join-Path $StateDir 'deployment.json') -PathType Leaf) {
            try {
                & $UninstallScript -StateDir $StateDir | Out-Null
            }
            catch {
                Write-Warning "Cleanup uninstall failed for ${StateDir}: $($_.Exception.Message)"
            }
        }
    }
}

New-Item -ItemType Directory -Path $TempRoot -Force | Out-Null

try {
    Assert-ThrowsLike -Pattern '*Duplicate tunnel provider selection*' -Message 'Duplicate provider selection was accepted.' -Action {
        & $InstallScript -WorkspaceRoot $WorkspaceRoot -Tunnels @('openai', 'openai') -DefaultTunnel openai -StateDir (Join-Path $TempRoot 'invalid-duplicate') -SkipCodexLogin | Out-Null
    }
    Assert-ThrowsLike -Pattern "*Default tunnel 'ngrok' is not selected*" -Message 'An unselected default provider was accepted.' -Action {
        & $InstallScript -WorkspaceRoot $WorkspaceRoot -Tunnels @('openai') -DefaultTunnel ngrok -StateDir (Join-Path $TempRoot 'invalid-default') -SkipCodexLogin | Out-Null
    }
    Assert-ThrowsLike -Pattern '*SkipTunnelSetup is a Cloudflare-only compatibility switch*' -Message 'Cloudflare-only SkipTunnelSetup was accepted for OpenAI-only selection.' -Action {
        & $InstallScript -WorkspaceRoot $WorkspaceRoot -Tunnels @('openai') -SkipTunnelSetup -StateDir (Join-Path $TempRoot 'invalid-skip') -SkipCodexLogin | Out-Null
    }

    $CloudflareState = Join-Path $TempRoot 'cloudflare-state'
    $CloudflareProfile = Join-Path $TempRoot 'cloudflare-profile\Microsoft.PowerShell_profile.ps1'
    $FakeCloudflared = Join-Path $TempRoot 'cloudflared.cmd'
    $Sentinel = '# QBIT_CODEXPRO_TEST_PROFILE_SENTINEL'
    New-FakeCommand -Path $FakeCloudflared
    New-Item -ItemType Directory -Path (Split-Path -Parent $CloudflareProfile) -Force | Out-Null
    [IO.File]::WriteAllText($CloudflareProfile, ($Sentinel + [Environment]::NewLine), $Utf8NoBom)

    $CloudflareInstall = @{
        WorkspaceRoot = $WorkspaceRoot
        Hostname = $Hostname
        TunnelName = $TunnelName
        CloudflaredPath = $FakeCloudflared
        StateDir = $CloudflareState
        ProfilePath = $CloudflareProfile
        SkipTunnelSetup = $true
        SkipCodexLogin = $true
    }
    & $InstallScript @CloudflareInstall | Out-Host
    $ActiveStates.Add($CloudflareState) | Out-Null

    $CloudflareDeploymentPath = Join-Path $CloudflareState 'deployment.json'
    $CloudflareDeployment = Get-Content -LiteralPath $CloudflareDeploymentPath -Raw | ConvertFrom-Json
    Assert-True ([int]$CloudflareDeployment.schemaVersion -eq 2) 'Cloudflare deployment did not use schemaVersion 2.'
    Assert-True (@($CloudflareDeployment.tunnels).Count -eq 1 -and [string]$CloudflareDeployment.tunnels[0] -eq 'cloudflare') 'Backward-compatible install did not select only Cloudflare.'
    Assert-True ([string]$CloudflareDeployment.defaultTunnel -eq 'cloudflare') 'Backward-compatible default tunnel is not Cloudflare.'
    Assert-True ([string]$CloudflareDeployment.providers.cloudflare.hostname -eq $Hostname) 'Cloudflare provider hostname was not recorded.'
    Assert-True ([string]$CloudflareDeployment.providers.cloudflare.executable -eq (Resolve-Path -LiteralPath $FakeCloudflared).Path) 'Configured cloudflared path was not recorded.'

    $ExpectedAssets = @(
        'Start-CodexPro.ps1',
        'Start-CodexPro.openai.ps1',
        'Start-CodexPro.cloudflare.ps1',
        'Start-CodexPro.ngrok.ps1',
        'Get-CodexProConnectorUrl.ps1'
    )
    foreach ($Asset in $ExpectedAssets) {
        Assert-True (Test-Path -LiteralPath (Join-Path $CloudflareState $Asset) -PathType Leaf) "Managed asset was not installed: $Asset"
    }

    $UrlHelper = Join-Path $CloudflareState 'Get-CodexProConnectorUrl.ps1'
    $ConnectorUrl = (& $UrlHelper -Mode cloudflare | Select-Object -Last 1).Trim()
    $ConnectorUri = [Uri]$ConnectorUrl
    $QueryParts = $ConnectorUri.Query.TrimStart('?').Split('=', 2)
    Assert-True ($ConnectorUri.Scheme -eq 'https' -and $ConnectorUri.Host -eq $Hostname -and $ConnectorUri.AbsolutePath -eq '/mcp') 'Cloudflare connector URL helper produced an unexpected endpoint.'
    Assert-True ($QueryParts.Count -eq 2 -and $QueryParts[0] -eq 'codexpro_token' -and $QueryParts[1] -match '^[0-9a-f]{64}$') 'Cloudflare connector URL helper did not include a valid credential.'

    $ProfileText = [IO.File]::ReadAllText($CloudflareProfile)
    Assert-True ($ProfileText.Contains($Sentinel)) 'Existing PowerShell profile content was lost during install.'
    Assert-True ($ProfileText.Contains('# >>> qbit codexpro >>>')) 'Managed cpx block start marker was not installed.'
    Assert-True ($ProfileText.Contains('# <<< qbit codexpro <<<')) 'Managed cpx block end marker was not installed.'
    Assert-True ($ProfileText.Contains('& $launcher @args')) 'Managed cpx helper does not forward raw arguments.'

    $CapturePath = Join-Path $TempRoot 'cpx-capture.txt'
    $CloudflareLauncher = Join-Path $CloudflareState 'Start-CodexPro.cloudflare.ps1'
    $CaptureStub = @'
[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$Root = (Get-Location).Path,
    [string]$HostExecMode = '',
    [string]$TunnelProtocol = ''
)
[IO.File]::WriteAllText($env:QBIT_CPX_CAPTURE, ($Root + [Environment]::NewLine + $HostExecMode + [Environment]::NewLine + $TunnelProtocol))
'@
    [IO.File]::WriteAllText($CloudflareLauncher, $CaptureStub, $Utf8NoBom)

    $Pwsh = Get-Command pwsh -ErrorAction Stop | Select-Object -First 1
    $EscapedProfilePath = $CloudflareProfile.Replace("'", "''")
    $EscapedWorkspaceRoot = $WorkspaceRoot.Replace("'", "''")
    $EscapedCapturePath = $CapturePath.Replace("'", "''")
    $ChildScript = ". '$EscapedProfilePath'; " +
        "$" + "env:QBIT_CPX_CAPTURE = '$EscapedCapturePath'; " +
        "Set-Location -LiteralPath '$EscapedWorkspaceRoot'; " +
        "cpx --cf --host-exec-mode off --tunnel-protocol auto"
    & $Pwsh.Source -NoProfile -Command $ChildScript
    if ($LASTEXITCODE -ne 0) {
        throw "Managed cpx dispatcher test failed with exit code $LASTEXITCODE."
    }
    $Captured = [IO.File]::ReadAllLines($CapturePath)
    Assert-True ($Captured[0] -eq $WorkspaceRoot) 'cpx did not use Get-Location as the default workspace root.'
    Assert-True ($Captured[1] -eq 'off') 'cpx did not forward --host-exec-mode.'
    Assert-True ($Captured[2] -eq 'auto') 'cpx did not forward --tunnel-protocol.'

    & $UninstallScript -StateDir $CloudflareState | Out-Host
    $ActiveStates.Remove($CloudflareState) | Out-Null
    $AfterProfile = [IO.File]::ReadAllText($CloudflareProfile)
    Assert-True ($AfterProfile.Contains($Sentinel)) 'Existing PowerShell profile content was lost during uninstall.'
    Assert-True (-not $AfterProfile.Contains('# >>> qbit codexpro >>>')) 'Managed cpx block remained after uninstall.'
    foreach ($Asset in $ExpectedAssets) {
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $CloudflareState $Asset) -PathType Leaf)) "Managed asset remained after uninstall: $Asset"
    }

    $OpenAIState = Join-Path $TempRoot 'openai-state'
    $OpenAITunnelClient = Join-Path $TempRoot 'tunnel-client.cmd'
    $OpenAITunnelId = Join-Path $TempRoot 'tunnel-id.txt'
    $OpenAIRuntimeKey = Join-Path $TempRoot 'runtime.key'
    $OpenAIProfileDir = Join-Path $TempRoot 'openai-profile'
    New-Item -ItemType Directory -Path $OpenAIProfileDir -Force | Out-Null
    New-FakeTunnelClient -Path $OpenAITunnelClient
    [IO.File]::WriteAllText($OpenAITunnelId, 'tunnel_test_fixture', $Utf8NoBom)
    [IO.File]::WriteAllText($OpenAIRuntimeKey, 'runtime-key-fixture', $Utf8NoBom)

    $OpenAIInstall = @{
        WorkspaceRoot = $WorkspaceRoot
        Tunnels = @('openai')
        DefaultTunnel = 'openai'
        TunnelClientExecutable = $OpenAITunnelClient
        OpenAITunnelIdFile = $OpenAITunnelId
        OpenAIRuntimeKeyFile = $OpenAIRuntimeKey
        OpenAIProfileDir = $OpenAIProfileDir
        OpenAITunnelAlias = 'codexpro-test'
        OpenAITunnelProfile = 'codexpro-test'
        StateDir = $OpenAIState
        SkipProfileUpdate = $true
        SkipCodexLogin = $true
    }
    & $InstallScript @OpenAIInstall | Out-Host
    $ActiveStates.Add($OpenAIState) | Out-Null

    $OpenAIDeployment = Get-Content -LiteralPath (Join-Path $OpenAIState 'deployment.json') -Raw | ConvertFrom-Json
    Assert-True ([string]$OpenAIDeployment.defaultTunnel -eq 'openai') 'OpenAI-only default provider was not recorded.'
    Assert-True ($null -ne $OpenAIDeployment.providers.openai) 'OpenAI provider state is missing.'
    Assert-True ([string]$OpenAIDeployment.cloudflaredExecutable -eq '') 'OpenAI-only install recorded a Cloudflare dependency.'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $OpenAIState 'http-token') -PathType Leaf)) 'OpenAI-only install created an unnecessary HTTP MCP token.'
    & $UninstallScript -StateDir $OpenAIState | Out-Host
    $ActiveStates.Remove($OpenAIState) | Out-Null

    $NgrokState = Join-Path $TempRoot 'ngrok-state'
    $FakeNgrok = Join-Path $TempRoot 'ngrok.cmd'
    $FakeNgrokConfig = Join-Path $TempRoot 'ngrok.yml'
    New-FakeCommand -Path $FakeNgrok
    [IO.File]::WriteAllText($FakeNgrokConfig, 'version: 3', $Utf8NoBom)

    $NgrokInstall = @{
        WorkspaceRoot = $WorkspaceRoot
        Tunnels = @('ngrok')
        DefaultTunnel = 'ngrok'
        NgrokHostname = 'codexpro-test.ngrok-free.app'
        NgrokExecutable = $FakeNgrok
        NgrokConfigPath = $FakeNgrokConfig
        StateDir = $NgrokState
        SkipProfileUpdate = $true
        SkipCodexLogin = $true
    }
    & $InstallScript @NgrokInstall | Out-Host
    $ActiveStates.Add($NgrokState) | Out-Null

    $NgrokDeployment = Get-Content -LiteralPath (Join-Path $NgrokState 'deployment.json') -Raw | ConvertFrom-Json
    Assert-True ([string]$NgrokDeployment.defaultTunnel -eq 'ngrok') 'ngrok-only default provider was not recorded.'
    Assert-True ($null -ne $NgrokDeployment.providers.ngrok) 'ngrok provider state is missing.'
    Assert-True ([string]$NgrokDeployment.cloudflaredExecutable -eq '') 'ngrok-only install recorded a Cloudflare dependency.'
    Assert-True (Test-Path -LiteralPath (Join-Path $NgrokState 'http-token') -PathType Leaf) 'ngrok-only install did not create the required HTTP MCP token.'

    $NgrokUrl = (& (Join-Path $NgrokState 'Get-CodexProConnectorUrl.ps1') -Mode ngrok | Select-Object -Last 1).Trim()
    Assert-True (([Uri]$NgrokUrl).Host -eq 'codexpro-test.ngrok-free.app') 'ngrok connector URL helper used the wrong hostname.'
    Assert-ThrowsLike -Pattern '*OpenAI Secure MCP Tunnel does not use a custom token-bearing Server URL*' -Message 'Connector helper invented an OpenAI custom URL.' -Action {
        & (Join-Path $NgrokState 'Get-CodexProConnectorUrl.ps1') -Mode openai | Out-Null
    }

    & $UninstallScript -StateDir $NgrokState | Out-Host
    $ActiveStates.Remove($NgrokState) | Out-Null

    # Two-provider lifecycle proves optional composition without Cloudflare.
    $TwoProviderState = Join-Path $TempRoot 'two-provider-state'
    $TwoProviderInstall = @{
        WorkspaceRoot = $WorkspaceRoot
        Tunnels = @('openai', 'ngrok')
        DefaultTunnel = 'ngrok'
        TunnelClientExecutable = $OpenAITunnelClient
        OpenAITunnelIdFile = $OpenAITunnelId
        OpenAIRuntimeKeyFile = $OpenAIRuntimeKey
        OpenAIProfileDir = $OpenAIProfileDir
        OpenAITunnelAlias = 'codexpro-test'
        OpenAITunnelProfile = 'codexpro-test'
        NgrokHostname = 'codexpro-test.ngrok-free.app'
        NgrokExecutable = $FakeNgrok
        NgrokConfigPath = $FakeNgrokConfig
        StateDir = $TwoProviderState
        SkipProfileUpdate = $true
        SkipCodexLogin = $true
    }
    & $InstallScript @TwoProviderInstall | Out-Host
    $ActiveStates.Add($TwoProviderState) | Out-Null

    $TwoProviderDeployment = Get-Content -LiteralPath (Join-Path $TwoProviderState 'deployment.json') -Raw | ConvertFrom-Json
    Assert-True (@($TwoProviderDeployment.tunnels).Count -eq 2) 'Two-provider selection was not preserved.'
    Assert-True ('openai' -in @($TwoProviderDeployment.tunnels) -and 'ngrok' -in @($TwoProviderDeployment.tunnels)) 'Two-provider state does not contain OpenAI and ngrok.'
    Assert-True ([string]$TwoProviderDeployment.defaultTunnel -eq 'ngrok') 'Two-provider default provider was not preserved.'
    Assert-True ([string]$TwoProviderDeployment.cloudflaredExecutable -eq '') 'Two-provider install unexpectedly required Cloudflare.'

    & $UninstallScript -StateDir $TwoProviderState | Out-Host
    $ActiveStates.Remove($TwoProviderState) | Out-Null

    # Three-provider lifecycle proves all providers can coexist without making all three mandatory.
    $AllProviderState = Join-Path $TempRoot 'all-provider-state'
    $AllProviderInstall = @{
        WorkspaceRoot = $WorkspaceRoot
        Tunnels = @('openai', 'cloudflare', 'ngrok')
        DefaultTunnel = 'openai'
        Hostname = $Hostname
        TunnelName = $TunnelName
        CloudflaredPath = $FakeCloudflared
        TunnelClientExecutable = $OpenAITunnelClient
        OpenAITunnelIdFile = $OpenAITunnelId
        OpenAIRuntimeKeyFile = $OpenAIRuntimeKey
        OpenAIProfileDir = $OpenAIProfileDir
        OpenAITunnelAlias = 'codexpro-test'
        OpenAITunnelProfile = 'codexpro-test'
        NgrokHostname = 'codexpro-test.ngrok-free.app'
        NgrokExecutable = $FakeNgrok
        NgrokConfigPath = $FakeNgrokConfig
        StateDir = $AllProviderState
        SkipTunnelSetup = $true
        SkipProfileUpdate = $true
        SkipCodexLogin = $true
    }
    & $InstallScript @AllProviderInstall | Out-Host
    $ActiveStates.Add($AllProviderState) | Out-Null

    $AllProviderDeployment = Get-Content -LiteralPath (Join-Path $AllProviderState 'deployment.json') -Raw | ConvertFrom-Json
    Assert-True (@($AllProviderDeployment.tunnels).Count -eq 3) 'Three-provider selection was not preserved.'
    Assert-True ('openai' -in @($AllProviderDeployment.tunnels) -and 'cloudflare' -in @($AllProviderDeployment.tunnels) -and 'ngrok' -in @($AllProviderDeployment.tunnels)) 'Three-provider state does not contain every selected provider.'
    Assert-True ([string]$AllProviderDeployment.defaultTunnel -eq 'openai') 'Three-provider default provider was not preserved.'
    Assert-True ([int]$AllProviderDeployment.providers.openai.localPort -eq 8788) 'OpenAI local port is not 8788.'
    Assert-True ([int]$AllProviderDeployment.providers.cloudflare.localPort -eq 8787) 'Cloudflare local port is not 8787.'
    Assert-True ([int]$AllProviderDeployment.providers.ngrok.localPort -eq 8789) 'ngrok local port is not 8789.'

    # Execute every real provider launcher against safe fake executables. This catches
    # runtime binding/argument bugs without opening a public tunnel.
    $FakeCodexPro = Join-Path $TempRoot 'codexpro-fake.cmd'
    New-FakeCommand -Path $FakeCodexPro
    $AllProviderDeployment.codexProExecutable = $FakeCodexPro
    $AllProviderDeployment | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $AllProviderState 'deployment.json') -Encoding utf8NoBOM

    & (Join-Path $AllProviderState 'Start-CodexPro.openai.ps1') -Root $WorkspaceRoot 6>$null
    Assert-True ($LASTEXITCODE -eq 0) 'OpenAI provider launcher failed against the safe executable fixture.'
    & (Join-Path $AllProviderState 'Start-CodexPro.cloudflare.ps1') -Root $WorkspaceRoot 6>$null
    Assert-True ($LASTEXITCODE -eq 0) 'Cloudflare provider launcher failed against the safe executable fixture.'
    & (Join-Path $AllProviderState 'Start-CodexPro.ngrok.ps1') -Root $WorkspaceRoot 6>$null
    Assert-True ($LASTEXITCODE -eq 0) 'ngrok provider launcher failed against the safe executable fixture.'

    & $UninstallScript -StateDir $AllProviderState | Out-Host
    $ActiveStates.Remove($AllProviderState) | Out-Null

    if ($CodexProBeforePath) {
        $CodexProAfter = Get-Command codexpro -ErrorAction Stop | Select-Object -First 1
        Assert-True ($CodexProAfter.Source -eq $CodexProBeforePath) 'A pre-existing CodexPro installation was changed or removed by the isolated lifecycle test.'
    }

    [pscustomobject]@{
        status = 'ok'
        installer = 'installer.codexpro'
        cloudflareBackwardCompatibility = $true
        multiProviderStateValidated = $true
        cpxDispatcherValidated = $true
        currentDirectoryRootValidated = $true
        openAIOnlyDependencyGating = $true
        ngrokOnlyDependencyGating = $true
        providerLaunchersExecuted = $true
        uninstallManagedAssetsValidated = $true
        preExistingCodexProPreserved = [bool]$CodexProBeforePath
    } | ConvertTo-Json -Compress
}
finally {
    Invoke-Cleanup
    Remove-Item -LiteralPath $TempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
