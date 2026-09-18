Set-StrictMode -Version 2
$ErrorActionPreference='Stop'
$InstallerRoot=(Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$Install=Join-Path $InstallerRoot 'install.ps1'
$TempRoot=Join-Path ([IO.Path]::GetTempPath()) ('ai-context-installer-e2e-' + [Guid]::NewGuid().ToString('N'))
$powerShellHost=(Get-Process -Id $PID).Path
New-Item -ItemType Directory -Force -Path $TempRoot|Out-Null
function Assert([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message}}
function WriteUtf8([string]$Path,[string]$Text){$Parent=Split-Path -Parent $Path;if(-not(Test-Path $Parent)){New-Item -ItemType Directory -Force -Path $Parent|Out-Null};[IO.File]::WriteAllText($Path,$Text,[Text.UTF8Encoding]::new($false))}
function InitRepo([string]$Path){New-Item -ItemType Directory -Force -Path $Path|Out-Null;&git -C $Path init -q -b main;if($LASTEXITCODE){throw 'git init failed'};WriteUtf8 (Join-Path $Path 'BOOTSTRAP.md') "bootstrap`n";&git -C $Path add BOOTSTRAP.md;&git -C $Path -c user.name=Test -c user.email=test@example.invalid commit -q -m bootstrap}
try{
  $Bare=Join-Path $TempRoot 'context.git';&git init --bare -q --initial-branch=main $Bare;if($LASTEXITCODE){throw 'bare init failed'}
  $Central=Join-Path $TempRoot 'central';InitRepo $Central;&git -C $Central remote add origin $Bare
  &$powerShellHost -NoProfile -ExecutionPolicy Bypass -File $Install -Operation install -Mode central -Target $Central -ProjectId demo -ProjectDisplayName Demo -RepositoryId demo-ai-context -ContextRemote $Bare -ContextBranch main|Out-Null
  Assert ($LASTEXITCODE -eq 0) 'central installer failed'
  $CentralStateText=Get-Content (Join-Path $Central '.qbit/toolkit/installed/ai-context.json') -Raw
  $ExpectedUtcYear=[DateTime]::UtcNow.Year.ToString('0000',[Globalization.CultureInfo]::InvariantCulture)
  Assert ($CentralStateText -match ('"installedAtUtc"\s*:\s*"' + [regex]::Escape($ExpectedUtcYear) + '-')) 'central installer state timestamp is not serialized as Gregorian UTC'
  WriteUtf8 (Join-Path $Central 'repositories/repositories.yaml') "project: demo`nrepositories:`n  demo-api:`n    path: ../member`n    role: application-member`n"
  &git -C $Central add --all;&git -C $Central -c user.name=Test -c user.email=test@example.invalid commit -q -m 'install context';&git -C $Central push -q -u origin main
  Assert ($LASTEXITCODE -eq 0) 'central context push failed'
  $CentralTests=Join-Path $Central 'tests/context-lifecycle.tests.ps1'
  &$powerShellHost -NoProfile -ExecutionPolicy Bypass -File $CentralTests
  Assert ($LASTEXITCODE -eq 0) 'installed central lifecycle regression suite failed'
  $InitialHead=(&git --git-dir $Bare rev-parse refs/heads/main).Trim()

  $Member=Join-Path $TempRoot 'member';InitRepo $Member
  &$powerShellHost -NoProfile -ExecutionPolicy Bypass -File $Install -Operation install -Mode member -Target $Member -ProjectId demo -RepositoryId demo-api -ContextRemote $Bare -ContextBranch main|Out-Null
  Assert ($LASTEXITCODE -eq 0) 'member installer failed'
  $Launcher=Join-Path $Member '.ai/context/context.ps1'
  &$powerShellHost -NoProfile -ExecutionPolicy Bypass -File $Launcher start|Out-Null
  Assert ($LASTEXITCODE -eq 0) 'member context start failed'
  $Runtime=Join-Path $Member '.ai-bridge/context-runtime.json';Assert (Test-Path $Runtime) 'runtime context was not generated'
  $Cache=Join-Path $Member '.ai/context/cache/project-context';&git -C $Cache config user.name 'AI Context E2E';&git -C $Cache config user.email 'ai-context-e2e@example.invalid'
  $Checkpoint=@{
    schemaVersion=1;repository='demo-api';scope='installer-e2e';status='VALIDATED';objective='Validate installer-generated zero-touch context lifecycle.'
    confirmedFindings=@('Central and member assets were installed from installer.ai-context.');decisions=@();rejectedApproaches=@();validation=@('Start completed and runtime bundle exists.');openQuestions=@();nextAction='Continue.'
  }|ConvertTo-Json -Depth 5
  WriteUtf8 (Join-Path $Member '.ai-bridge/context-checkpoint.json') ($Checkpoint+"`n")
  &$powerShellHost -NoProfile -ExecutionPolicy Bypass -File $Launcher checkpoint|Out-Null
  Assert ($LASTEXITCODE -eq 0) 'member checkpoint failed'
  $FinalHead=(&git --git-dir $Bare rev-parse refs/heads/main).Trim();Assert ($FinalHead -ne $InitialHead) 'checkpoint did not advance context remote'
  $Generated=(&git --git-dir $Bare ls-tree -r --name-only refs/heads/main -- state/repositories/demo-api.md).Trim();Assert ($Generated -eq 'state/repositories/demo-api.md') 'checkpoint repository state was not pushed'
  Write-Host 'PASS AI Context installer end-to-end central/member/start/checkpoint flow'
} finally {Remove-Item -LiteralPath $TempRoot -Recurse -Force -ErrorAction SilentlyContinue}
