Set-StrictMode -Version 2
$ErrorActionPreference='Stop'
$InstallerRoot=(Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$Install=Join-Path $InstallerRoot 'install.ps1'
$Verify=Join-Path $InstallerRoot 'verify.ps1'
$Uninstall=Join-Path $InstallerRoot 'uninstall.ps1'
. (Join-Path $InstallerRoot 'lib/installer.ps1')
$TempRoot=Join-Path ([IO.Path]::GetTempPath()) ('ai-context-legacy-it-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $TempRoot|Out-Null
$Passed=0
$Failed=0

function Assert([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message}}
function WriteUtf8([string]$Path,[string]$Text){$Parent=Split-Path -Parent $Path;if(-not(Test-Path $Parent)){New-Item -ItemType Directory -Force -Path $Parent|Out-Null};[IO.File]::WriteAllText($Path,$Text,[Text.UTF8Encoding]::new($false))}
function ReadUtf8([string]$Path){return [IO.File]::ReadAllText($Path,[Text.Encoding]::UTF8).Replace("`r`n","`n").Replace("`r","`n")}
function Sha([string]$Path){$S=[Security.Cryptography.SHA256]::Create();$F=[IO.File]::OpenRead($Path);try{return -join($S.ComputeHash($F)|ForEach-Object{$_.ToString('x2')})}finally{$F.Dispose();$S.Dispose()}}
function NewRepo([string]$Name){$Path=Join-Path $TempRoot $Name;New-Item -ItemType Directory -Force -Path $Path|Out-Null;& git -C $Path init -q -b main;if($LASTEXITCODE){throw 'git init failed'};WriteUtf8 (Join-Path $Path 'README.md') "# $Name`n";& git -C $Path add README.md;& git -C $Path -c user.name=Test -c user.email=test@example.invalid commit -q -m init;return $Path}
function RunJson([string[]]$Arguments){$Output=@(& powershell -NoProfile -ExecutionPolicy Bypass -File $Install @Arguments -Format json 2>&1);$Code=$LASTEXITCODE;$Text=$Output-join "`n";$Json=$null;if($Text){try{$Json=$Text|ConvertFrom-Json}catch{}};return [pscustomobject]@{Code=$Code;Text=$Text;Json=$Json}}
function Test([string]$Name,[scriptblock]$Body){try{&$Body;$script:Passed++;Write-Host "PASS $Name"}catch{$script:Failed++;Write-Host "FAIL ${Name}: $($_.Exception.Message)"}}

try {
  Test 'fresh member seeds project-owned AI_CONTEXT header and uninstall preserves it' {
    $Repo=NewRepo 'fresh-header'
    $Base=@('-Mode','member','-Target',$Repo,'-ProjectId','demo','-ProjectDisplayName','Demo','-RepositoryId','demo-api','-ContextRemote','https://github.com/example/demo-ai-context.git')
    $Installed=RunJson (@('-Operation','install')+$Base);Assert ($Installed.Code -eq 0 -and $Installed.Json.success) 'fresh member install failed'
    $EntryPath=Join-Path $Repo 'AI_CONTEXT.md';$Entry=ReadUtf8 $EntryPath
    Assert ($Entry.StartsWith('# Demo AI Context Entry Point')) 'project-owned AI_CONTEXT header was not seeded'
    Assert ($Entry.Contains('`demo-api` is a member repository')) 'repository role seed is missing'
    Assert ($Entry.Contains($Script:BlockBegin)) 'managed lifecycle block is missing'
    $StatePath=Join-Path $Repo '.qbit/toolkit/installed/ai-context.json';$State=ReadUtf8 $StatePath|ConvertFrom-Json;$State.installerVersion='1.0.0';WriteUtf8 $StatePath (($State|ConvertTo-Json -Depth 8)+"`n")
    $Updated=RunJson @('-Operation','update','-Target',$Repo);Assert ($Updated.Code -eq 0) 'version-only state update failed';$UpdatedState=ReadUtf8 $StatePath|ConvertFrom-Json;Assert ([string]$UpdatedState.installerVersion -eq '1.2.8') 'version-only update did not refresh ownership state'
    $UninstallOutput=@(& powershell -NoProfile -ExecutionPolicy Bypass -File $Uninstall -Target $Repo -Format json 2>&1);Assert ($LASTEXITCODE -eq 0) "uninstall failed: $($UninstallOutput-join ' ')"
    $After=ReadUtf8 $EntryPath;Assert ($After.StartsWith('# Demo AI Context Entry Point')) 'project-owned AI_CONTEXT header was removed by uninstall';Assert (-not $After.Contains($Script:BlockBegin)) 'managed lifecycle block remained after uninstall'
  }

  Test 'legacy manual member rollout migrates only with explicit flag' {
    $Repo=NewRepo 'legacy-member'
    $Remote='https://github.com/example/demo-ai-context.git'
    $Variables=Get-Variables 'demo' 'Demo' 'demo-api' 'demo-ai-context' $Remote 'main'
    $Spec=New-Spec 'member' $Variables
    New-Item -ItemType Directory -Force -Path (Join-Path $Repo '.ai/context'),(Join-Path $Repo '.ai-bridge')|Out-Null
    WriteUtf8 (Join-Path $Repo '.ai/context/context.ps1') ([string]$Spec.Files['.ai/context/context.ps1'])
    WriteUtf8 (Join-Path $Repo '.ai/context/.gitignore') ([string]$Spec.Files['.ai/context/.gitignore'])
    $LegacyConfig=(([string]$Spec.Files['.ai/context/config.json']|ConvertFrom-Json)|ConvertTo-Json -Depth 8);WriteUtf8 (Join-Path $Repo '.ai/context/config.json') ($LegacyConfig+"`n")
    WriteUtf8 (Join-Path $Repo 'AGENTS.md') ("# Product rules`n`n"+[string]$Spec.LegacyBlocks['AGENTS.md'])
    WriteUtf8 (Join-Path $Repo 'AI_CONTEXT.md') ("# Demo AI Context Entry Point`n`n## Repository role`n`nCUSTOM ROLE MUST SURVIVE`n`n"+[string]$Spec.LegacyBlocks['AI_CONTEXT.md'])
    WriteUtf8 (Join-Path $Repo '.ai-bridge/.gitignore') ([string]$Spec.LegacyBlocks['.ai-bridge/.gitignore'])
    WriteUtf8 (Join-Path $Repo '.ai-bridge/README.md') "# Existing bridge docs`n"
    $Base=@('-Mode','member','-Target',$Repo,'-ProjectId','demo','-ProjectDisplayName','Demo','-RepositoryId','demo-api','-ContextRemote',$Remote,'-ContextBranch','main','-AdoptMatching')
    $BeforeAgents=Sha (Join-Path $Repo 'AGENTS.md')
    $Blocked=RunJson (@('-Operation','plan')+$Base);Assert ($Blocked.Code -eq 4 -and -not $Blocked.Json.success) 'legacy rollout was accepted without -MigrateLegacy';Assert ((Sha (Join-Path $Repo 'AGENTS.md')) -eq $BeforeAgents) 'blocked legacy plan mutated AGENTS.md'
    $Planned=RunJson (@('-Operation','plan','-MigrateLegacy')+$Base);Assert ($Planned.Code -eq 0 -and $Planned.Json.success) 'legacy migration plan failed'
    $Installed=RunJson (@('-Operation','install','-MigrateLegacy')+$Base);Assert ($Installed.Code -eq 0 -and $Installed.Json.success) 'legacy migration install failed'
    Assert ((ReadUtf8 (Join-Path $Repo '.ai/context/config.json')) -eq ([string]$Spec.Files['.ai/context/config.json'])) 'legacy config was not canonicalized'
    $Agents=ReadUtf8 (Join-Path $Repo 'AGENTS.md');Assert ($Agents.Contains('# Product rules')) 'product AGENTS content was lost';Assert ([regex]::Matches($Agents,[regex]::Escape('## AI context lifecycle')).Count -eq 1) 'legacy AGENTS lifecycle was duplicated';Assert ($Agents.Contains($Script:BlockBegin)) 'AGENTS managed marker missing after migration'
    $Entry=ReadUtf8 (Join-Path $Repo 'AI_CONTEXT.md');Assert ($Entry.Contains('CUSTOM ROLE MUST SURVIVE')) 'repository role was lost';Assert ([regex]::Matches($Entry,[regex]::Escape('## Zero-touch lifecycle')).Count -eq 1) 'AI_CONTEXT lifecycle was duplicated';Assert ($Entry.Contains($Script:BlockBegin)) 'AI_CONTEXT managed marker missing after migration'
    $BridgeIgnore=ReadUtf8 (Join-Path $Repo '.ai-bridge/.gitignore');Assert ($BridgeIgnore.Contains($Script:GitignoreBegin)) 'bridge ignore was not migrated into a managed block'
    $VerifyOutput=@(& powershell -NoProfile -ExecutionPolicy Bypass -File $Verify -Target $Repo -Format json 2>&1);Assert ($LASTEXITCODE -eq 0) "migrated member verify failed: $($VerifyOutput-join ' ')"
  }

  Test 'modified legacy lifecycle is rejected instead of duplicated or erased' {
    $Repo=NewRepo 'legacy-modified'
    $Remote='https://github.com/example/demo-ai-context.git'
    $Variables=Get-Variables 'demo' 'Demo' 'demo-api' 'demo-ai-context' $Remote 'main';$Spec=New-Spec 'member' $Variables
    New-Item -ItemType Directory -Force -Path (Join-Path $Repo '.ai/context')|Out-Null
    WriteUtf8 (Join-Path $Repo '.ai/context/context.ps1') ([string]$Spec.Files['.ai/context/context.ps1'])
    WriteUtf8 (Join-Path $Repo '.ai/context/.gitignore') ([string]$Spec.Files['.ai/context/.gitignore'])
    WriteUtf8 (Join-Path $Repo '.ai/context/config.json') ([string]$Spec.Files['.ai/context/config.json'])
    WriteUtf8 (Join-Path $Repo 'AGENTS.md') (([string]$Spec.LegacyBlocks['AGENTS.md']).Replace('Serena and Graphify remain derived evidence tools','CUSTOM MODIFIED LEGACY TEXT'))
    $Base=@('-Operation','plan','-Mode','member','-Target',$Repo,'-ProjectId','demo','-ProjectDisplayName','Demo','-RepositoryId','demo-api','-ContextRemote',$Remote,'-AdoptMatching','-MigrateLegacy')
    $Before=Sha (Join-Path $Repo 'AGENTS.md');$Result=RunJson $Base
    Assert ($Result.Code -eq 4 -and -not $Result.Json.success) 'modified legacy lifecycle was accepted';Assert ((Sha (Join-Path $Repo 'AGENTS.md')) -eq $Before) 'modified legacy content was changed by failed migration'
  }
} finally {
  Remove-Item -LiteralPath $TempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

if($Failed -gt 0){throw "$Failed legacy migration integration test(s) failed; $Passed passed."}
Write-Host "PASS all $Passed AI Context legacy migration integration tests"
