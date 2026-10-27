param([switch]$SkipCentralLifecycleTests,[string]$HookPath='')
Set-StrictMode -Version 2
$ErrorActionPreference='Stop'
$InstallerRoot=(Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$Install=Join-Path $InstallerRoot 'install.ps1'
$TempRoot=Join-Path ([IO.Path]::GetTempPath()) ('ai-context-installer-e2e-' + [Guid]::NewGuid().ToString('N'))
$powerShellHost=(Get-Process -Id $PID).Path
$Assertions=0
New-Item -ItemType Directory -Force -Path $TempRoot|Out-Null
function Assert([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message};$script:Assertions++}
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
  WriteUtf8 (Join-Path $Central 'repositories/repositories.yaml') "project: demo`nrepositories:`n  demo-api:`n    path: ../member`n    role: application-member`n  demo-reader:`n    path: ../reader`n    role: independent-consumer`n"
  &git -C $Central add --all;&git -C $Central -c user.name=Test -c user.email=test@example.invalid commit -q -m 'install context';&git -C $Central push -q -u origin main
  Assert ($LASTEXITCODE -eq 0) 'central context push failed'
  $CentralTests=Join-Path $Central 'tests/context-lifecycle.tests.ps1'
  if (-not $SkipCentralLifecycleTests) {
    &$powerShellHost -NoProfile -ExecutionPolicy Bypass -File $CentralTests
    Assert ($LASTEXITCODE -eq 0) 'installed central lifecycle regression suite failed'
  }
  $InitialHead=(&git --git-dir $Bare rev-parse refs/heads/main).Trim()

  $Member=Join-Path $TempRoot 'member';InitRepo $Member
  &$powerShellHost -NoProfile -ExecutionPolicy Bypass -File $Install -Operation install -Mode member -Target $Member -ProjectId demo -RepositoryId demo-api -ContextRemote $Bare -ContextBranch main|Out-Null
  Assert ($LASTEXITCODE -eq 0) 'member installer failed'
  $Launcher=Join-Path $Member '.ai/context/context.ps1'
  $SyncGate=Join-Path $Member '.ai/context/context-sync-gate.ps1'
  Assert (Test-Path -LiteralPath $SyncGate -PathType Leaf) 'installed sync gate missing'
  &$powerShellHost -NoProfile -ExecutionPolicy Bypass -File $Launcher start|Out-Null
  Assert ($LASTEXITCODE -eq 0) 'member context start failed'
  & $powerShellHost -NoProfile -ExecutionPolicy Bypass -File $SyncGate -MemberPath $Member -Mode Start | Out-Null
  Assert ($LASTEXITCODE -eq 0) 'member sync gate Start did not prove remote freshness'
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
  & $powerShellHost -NoProfile -ExecutionPolicy Bypass -File $SyncGate -MemberPath $Member -Mode Status | Out-Null
  Assert ($LASTEXITCODE -eq 0) 'sync gate did not verify published remote health'
  $PreviousErrorActionPreference=$ErrorActionPreference; $ErrorActionPreference='Continue'
  try {
    & $powerShellHost -NoProfile -ExecutionPolicy Bypass -File $SyncGate -MemberPath $Member -Mode Checkpoint 2>$null | Out-Null
    $DeniedCheckpointExit=$LASTEXITCODE
  } finally { $ErrorActionPreference=$PreviousErrorActionPreference }
  Assert ($DeniedCheckpointExit -eq 3) 'sync gate accepted missing/legacy checkpoint as v2 publication'
  # Exercise an ACTUAL installed Continuity v2 publication through the strict
  # gate, not just a simulated stub in the smaller sync-gate fixture.
  $Snapshot=$Checkpoint|ConvertFrom-Json
  $Snapshot.schemaVersion=2
  $Snapshot|Add-Member -NotePropertyName continuity -NotePropertyValue ([pscustomobject]@{mode='snapshot';workstream=$null;validationLedger=@()})
  $Snapshot.scope='installed-v2-sync-gate'
  $Snapshot.nextAction='Review the next real member milestone.'
  WriteUtf8 (Join-Path $Member 'controlled-source.txt') 'source changed after Start'
  WriteUtf8 (Join-Path $Member '.ai-bridge/context-checkpoint.json') (($Snapshot|ConvertTo-Json -Depth 12)+"`n")
  & $powerShellHost -NoProfile -ExecutionPolicy Bypass -File $SyncGate -MemberPath $Member -Mode Checkpoint | Out-Null
  Assert ($LASTEXITCODE -eq 0) 'real installed Continuity v2 strict checkpoint/manifest/session receipt failed'
  $ManifestFile=Join-Path $Cache 'manifests/repositories/demo-api.json'
  $Manifest=Get-Content -LiteralPath $ManifestFile -Raw|ConvertFrom-Json
  Assert ($Manifest.continuity.mode -eq 'snapshot') 'v2 checkpoint did not publish snapshot manifest'
  $PublishedHead=(&git --git-dir $Bare rev-parse refs/heads/main).Trim()
  Assert ($PublishedHead -eq (&git -C $Cache rev-parse HEAD).Trim()) 'v2 strict checkpoint remote HEAD mismatch'
  $NextTrackedAction='Complete remote checkpoint receipt audit.'
  $Tracked=@{
    schemaVersion=2;repository='demo-api';scope='e2e-tracked-context';status='IN_PROGRESS'
    objective='Verify the published Workstream and current task cursor are not dropped.'
    confirmedFindings=@('Snapshot v2 checkpoint was validated.');decisions=@()
    rejectedApproaches=@();validation=@('The installed central engine committed a Snapshot v2 receipt.')
    openQuestions=@();nextAction=$NextTrackedAction
    continuity=@{
      mode='tracked';validationLedger=@()
      workstream=@{
        id='context-workstream-e2e';title='Context tracked publication';status='IN_PROGRESS'
        objective='Carry an active task across member context sessions.'
        repositories=@(@{repository='demo-api';role='implementation-owner'})
        cursor=@{
          currentItemId='WS-1';lastCompletedItemId=$null;phase='validation'
          lastCompletedAction=$null;nextAction=$NextTrackedAction
        }
        items=@(@{
          id='WS-1';title='Verify tracked checkpoint';status='IN_PROGRESS'
          priority='HIGH';scope=@('context-checkpoint-gate')
          acceptanceCriteria=@('The current cursor matches the published source.')
          dependsOn=@();blockedBy=@();validationRequirements=@('installed-e2e');notes=@()
        })
      }
    }
  }
  WriteUtf8 (Join-Path $Member '.ai-bridge/context-checkpoint.json') (($Tracked|ConvertTo-Json -Depth 20)+"`n")
  & $powerShellHost -NoProfile -ExecutionPolicy Bypass -File $SyncGate -MemberPath $Member -Mode Checkpoint | Out-Null
  Assert ($LASTEXITCODE -eq 0) 'real tracked v2 strict checkpoint/Workstream cursor receipt failed'
  $TrackedManifest=Get-Content -LiteralPath $ManifestFile -Raw | ConvertFrom-Json
  Assert ($TrackedManifest.continuity.workstreamId -eq 'context-workstream-e2e') 'tracked manifest lost workstream identity'
  $TrackedWorkstream=Get-Content -LiteralPath (Join-Path $Cache 'workstreams/active/context-workstream-e2e.json') -Raw | ConvertFrom-Json
  Assert ($TrackedWorkstream.cursor.currentItemId -eq 'WS-1' -and $TrackedWorkstream.cursor.nextAction -eq $NextTrackedAction) 'published tracked cursor was not preserved'
  # A separate, independently registered member must be able to fetch the
  # published Context commit and recover the first member's tracked cursor.
  $Reader=Join-Path $TempRoot 'reader';InitRepo $Reader
  &$powerShellHost -NoProfile -ExecutionPolicy Bypass -File $Install -Operation install -Mode member -Target $Reader -ProjectId demo -RepositoryId demo-reader -ContextRemote $Bare -ContextBranch main|Out-Null
  Assert ($LASTEXITCODE -eq 0) 'independent reader member install failed'
  $ReaderGate=Join-Path $Reader '.ai/context/context-sync-gate.ps1'
  & $powerShellHost -NoProfile -ExecutionPolicy Bypass -File $ReaderGate -MemberPath $Reader -Mode Start | Out-Null
  Assert ($LASTEXITCODE -eq 0) 'independent member could not start from published central Context'
  $ReaderCache=Join-Path $Reader '.ai/context/cache/project-context'
  $ReaderHead=(&git -C $ReaderCache rev-parse HEAD).Trim()
  Assert ($ReaderHead -eq (&git --git-dir $Bare rev-parse refs/heads/main).Trim()) 'independent reader did not fetch the published remote HEAD'
  $RestoredManifest=Get-Content -LiteralPath (Join-Path $ReaderCache 'manifests/repositories/demo-api.json') -Raw|ConvertFrom-Json
  $RestoredWorkstream=Get-Content -LiteralPath (Join-Path $ReaderCache 'workstreams/active/context-workstream-e2e.json') -Raw|ConvertFrom-Json
  Assert ($RestoredManifest.continuity.workstreamId -eq 'context-workstream-e2e' -and
    $RestoredWorkstream.cursor.currentItemId -eq 'WS-1' -and
    $RestoredWorkstream.cursor.nextAction -eq $NextTrackedAction -and
    $RestoredWorkstream.lastCheckpoint.session -eq $RestoredManifest.session) 'independent member failed to reconstruct tracked workstream and checkpoint session'
  # Use the actual installed lifecycle/gate through the project hook, in an
  # isolated host. Direct invocation tests interface behavior, not Codex Trust.
  $HookSource=$HookPath
  if($HookSource -and -not (Test-Path -LiteralPath $HookSource -PathType Leaf)){throw 'Requested HookPath is missing'}
  if($HookSource){
    $HostRoot=Join-Path $TempRoot 'hook-host'
    $Hook=Join-Path $HostRoot '.codex/hooks/context-sync-hook.ps1'
    WriteUtf8 $Hook ([IO.File]::ReadAllText($HookSource))
    WriteUtf8 (Join-Path $HostRoot 'templates/member/context-sync-gate.ps1') ([IO.File]::ReadAllText($SyncGate))
    WriteUtf8 (Join-Path $HostRoot '.codex/.runtime/active-member.json') (@{path=$Member}|ConvertTo-Json)
    $inputStart=@{hook_event_name='SessionStart';session_id='installed-e2e';permission_mode='default';cwd=$HostRoot}|ConvertTo-Json -Compress
    $startReply=$inputStart|& $powerShellHost -NoProfile -ExecutionPolicy Bypass -File $Hook
    Assert ($LASTEXITCODE -eq 0) 'actual installed hook Start failed'
    Assert ((($startReply -join "`n")|ConvertFrom-Json).continue -eq $true) 'actual hook Start blocked'
  }
  WriteUtf8 (Join-Path $Member 'controlled-source.txt') 'changed without fresh checkpoint'
  $priorPreference=$ErrorActionPreference;$ErrorActionPreference='Continue'
  try {& $powerShellHost -NoProfile -ExecutionPolicy Bypass -File $SyncGate -MemberPath $Member -Mode Verify 2>$null|Out-Null;$denied=$LASTEXITCODE}finally{$ErrorActionPreference=$priorPreference}
  Assert ($denied -eq 3) 'closeout accepted mutated existing untracked source'
  if($HookSource){
    $inputStop=@{hook_event_name='Stop';session_id='installed-e2e';permission_mode='default';cwd=$HostRoot}|ConvertTo-Json -Compress
    $reply=$inputStop|& $powerShellHost -NoProfile -ExecutionPolicy Bypass -File $Hook
    Assert (($reply -join "`n") -match '"decision"\s*:\s*"block"') 'actual hook Stop accepted uncheckpointed source'
  }
  WriteUtf8 (Join-Path $Member '.ai-bridge/context-checkpoint.json') (($Tracked|ConvertTo-Json -Depth 20)+"`n")
  & $powerShellHost -NoProfile -ExecutionPolicy Bypass -File $SyncGate -MemberPath $Member -Mode Checkpoint|Out-Null
  Assert ($LASTEXITCODE -eq 0) 'authorized repaired checkpoint did not publish'
  & $powerShellHost -NoProfile -ExecutionPolicy Bypass -File $SyncGate -MemberPath $Member -Mode Verify|Out-Null
  Assert ($LASTEXITCODE -eq 0) 'closeout did not pass after verified publication'
  if($HookSource){
    $reply=$inputStop|& $powerShellHost -NoProfile -ExecutionPolicy Bypass -File $Hook
    Assert ((($reply -join "`n")|ConvertFrom-Json).continue -eq $true) ('actual hook Stop rejected valid publication: '+($reply -join "`n"))
  }
  & git -C $Central pull --ff-only -q origin main
  Assert ($LASTEXITCODE -eq 0) 'remote drift fixture local writer pull failed'
  & git -C $Central commit --allow-empty -q -m 'advance central independently'
  Assert ($LASTEXITCODE -eq 0) 'remote drift fixture commit failed'
  & git -C $Central push -q origin main
  Assert ($LASTEXITCODE -eq 0) 'remote drift fixture push failed'
  $PreviousErrorActionPreference=$ErrorActionPreference; $ErrorActionPreference='Continue'
  try {
    & $powerShellHost -NoProfile -ExecutionPolicy Bypass -File $SyncGate -MemberPath $Member -Mode Verify 2>$null | Out-Null
    $DeniedStaleExit=$LASTEXITCODE
  } finally { $ErrorActionPreference=$PreviousErrorActionPreference }
  Assert ($DeniedStaleExit -eq 3) 'sync gate incorrectly accepted stale cache'
  Write-Host "PASS installed E2E scenario: assertions=$Assertions failed=0 skipped=0; Snapshot/Tracked/independent recovery/source drift/repair/real hook invocation"
} finally {Remove-Item -LiteralPath $TempRoot -Recurse -Force -ErrorAction SilentlyContinue}
