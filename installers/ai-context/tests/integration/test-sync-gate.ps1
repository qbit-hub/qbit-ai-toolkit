Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$gate=Join-Path $PSScriptRoot '../../scripts/Invoke-ContextSyncGate.ps1'
$root=Join-Path ([IO.Path]::GetTempPath()) ('qbit-gate-'+[guid]::NewGuid().ToString('N'))
$passed=0
function Run-Gate([string]$mode,[int]$timeout=30) {
  $previous=$ErrorActionPreference
  $ErrorActionPreference='Continue'
  try {
    $output=@(& powershell -NoProfile -ExecutionPolicy Bypass -File $gate -MemberPath $member -Mode $mode -TimeoutSeconds $timeout 2>&1)
    $code=$LASTEXITCODE
    return [pscustomobject]@{ Code=$code; Output=($output -join [Environment]::NewLine) }
  } finally { $ErrorActionPreference=$previous }
}
function Assert([bool]$condition,[string]$note){if(-not $condition){throw "FAIL $note"};$script:passed++}
try{
  New-Item -ItemType Directory -Force $root|Out-Null
  $bare=Join-Path $root 'central.git'
  &git init --bare -q --initial-branch=main $bare
  $seed=Join-Path $root 'seed'
  New-Item -ItemType Directory -Force $seed|Out-Null
  &git -C $seed init -q -b main
  &git -C $seed config user.email 'fixture@example.invalid'
  &git -C $seed config user.name 'Fixture'
  [IO.File]::WriteAllText((Join-Path $seed 'INIT.txt'),'fixture')
  &git -C $seed add INIT.txt
  &git -C $seed commit -q -m init
  &git -C $seed remote add origin $bare
  &git -C $seed push -q origin main
  $member=Join-Path $root 'member'
  New-Item -ItemType Directory -Force $member|Out-Null
  &git -C $member init -q -b main
  &git -C $member config user.email 'fixture@example.invalid'
  &git -C $member config user.name 'Fixture'
  [IO.File]::WriteAllText((Join-Path $member 'INIT.txt'),'fixture')
  &git -C $member add INIT.txt
  &git -C $member commit -q -m init
  $ctx=Join-Path $member '.ai/context'
  $bridge=Join-Path $member '.ai-bridge'
  New-Item -ItemType Directory -Force $ctx,$bridge|Out-Null
  $cache=Join-Path $ctx 'cache/project-context'
  &git clone -q --branch main $bare $cache
  &git -C $cache config user.email 'fixture@example.invalid'
  &git -C $cache config user.name 'Fixture'
  &git -C $cache config core.autocrlf false
  $conf=@{schemaVersion=1;project='qbit';repository='qbit-test-gate';context=@{remote=$bare;branch='main';cachePath='.ai/context/cache/project-context'}}
  [IO.File]::WriteAllText((Join-Path $ctx 'config.json'),($conf|ConvertTo-Json -Depth 6))
  $launcher=@'
param([string]$Action='start')
$ErrorActionPreference='Stop'
$root=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$cfg=Get-Content (Join-Path $root '.ai/context/config.json') -Raw|ConvertFrom-Json
$cache=Join-Path $root $cfg.context.cachePath
if(Test-Path -LiteralPath (Join-Path $root '.ai-bridge/hang.flag')){Start-Sleep -Seconds 30}
function SourceFingerprint {
  $sha=[System.Security.Cryptography.SHA256]::Create()
  $stream=[System.IO.File]::OpenRead((Join-Path $root 'INIT.txt'))
  try{return ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-','').ToLowerInvariant()}
  finally{$stream.Dispose();$sha.Dispose()}
}
if($Action -eq 'checkpoint'){
  $cp=Get-Content (Join-Path $root '.ai-bridge/context-checkpoint.json') -Raw|ConvertFrom-Json
  if(Test-Path -LiteralPath (Join-Path $root '.ai-bridge/other-only.flag')) {
    $other=Join-Path $cache 'state/other.md'
    New-Item -ItemType Directory -Force (Split-Path $other -Parent)|Out-Null
    [IO.File]::WriteAllText($other,('other repo '+[Guid]::NewGuid().ToString('N')))
    &git -C $cache add state/other.md
  } else {
    $session='sessions/2026/10/fixture-'+[Guid]::NewGuid().ToString('N')+'.md'
    $reuse=Test-Path -LiteralPath (Join-Path $root '.ai-bridge/reuse-session.flag')
    $record=Join-Path $cache 'state/repositories/qbit-test-gate.md'
    $manifestFile=Join-Path $cache 'manifests/repositories/qbit-test-gate.json'
    if($reuse){$session=(Get-Content $manifestFile -Raw|ConvertFrom-Json).session}
    foreach($p in @($record,$manifestFile,(Join-Path $cache $session))) {
      New-Item -ItemType Directory -Force (Split-Path $p -Parent)|Out-Null
    }
    if(-not $reuse){[IO.File]::WriteAllText((Join-Path $cache $session),'fixture session')}
    [IO.File]::WriteAllText($record,("Latest session: "+$session+"; Next: "+$cp.nextAction+"; nonce: "+[Guid]::NewGuid().ToString('N')))
    $head=(&git -C $root rev-parse HEAD).Trim()
    $capturedFingerprint=(SourceFingerprint)
    $ledgerPath='validation/repositories/qbit-test-gate.json'
    $ledgerFile=Join-Path $cache $ledgerPath
    New-Item -ItemType Directory -Force (Split-Path $ledgerFile -Parent)|Out-Null
    [IO.File]::WriteAllText($ledgerFile,(@{schemaVersion=2;repository='qbit-test-gate';entries=@()}|ConvertTo-Json -Depth 8))
    $continuity=@{schemaVersion=2;mode=$cp.continuity.mode;workstreamId=$null;workstreamStatus=$null;currentItemId=$null;workstreamPath=$null;validationLedgerPath=$ledgerPath}
    if($cp.continuity.mode -eq 'tracked') {
      $ws=$cp.continuity.workstream
      $continuity.workstreamId=$ws.id
      $continuity.workstreamStatus=$ws.status
      $continuity.currentItemId=$ws.cursor.currentItemId
      $continuity.workstreamPath=('workstreams/active/'+$ws.id+'.json')
      $file=Join-Path $cache $continuity.workstreamPath
      New-Item -ItemType Directory -Force (Split-Path $file -Parent)|Out-Null
      $cursorNext=$cp.nextAction
      if(Test-Path (Join-Path $root '.ai-bridge/wrong-workstream.flag')){$cursorNext='WRONG NEXT ACTION'}
      $data=@{id=$ws.id;status=$ws.status;lastCheckpoint=@{session=$session};cursor=@{currentItemId=$ws.cursor.currentItemId;nextAction=$cursorNext}}
      [IO.File]::WriteAllText($file,($data|ConvertTo-Json -Depth 8))
    }
    $scope=$cp.scope
    if(Test-Path (Join-Path $root '.ai-bridge/wrong-manifest.flag')){$scope='WRONG-SCOPE'}
    $manifest=@{schemaVersion=1;generatedAt=[DateTime]::UtcNow.ToString('o');project='qbit';repository='qbit-test-gate';branch='main';dirty=$false;memberWorktree=$root;checkpointId=[Guid]::NewGuid().ToString('N');checkpointPayloadSha256=(Get-FileHash -LiteralPath (Join-Path $root '.ai-bridge/context-checkpoint.json') -Algorithm SHA256).Hash;worktreeFingerprint=$capturedFingerprint;commit=$head;scope=$scope;status=$cp.status;session=$session;continuity=$continuity}
    [IO.File]::WriteAllText($manifestFile,($manifest|ConvertTo-Json -Depth 8))
    if(-not $reuse){[IO.File]::WriteAllText((Join-Path $cache $session),('Checkpoint ID: '+$manifest.checkpointId+"`nCheckpoint payload SHA256: "+$manifest.checkpointPayloadSha256))}
    &git -C $cache add state/repositories/qbit-test-gate.md manifests/repositories/qbit-test-gate.json $session $ledgerPath
    if($continuity.workstreamPath){&git -C $cache add $continuity.workstreamPath}
  }
  &git -C $cache commit -q -m fixture-checkpoint
  &git -C $cache push -q origin main
  if(Test-Path (Join-Path $root '.ai-bridge/late-source-mutation.flag')) {
    [IO.File]::WriteAllText((Join-Path $root 'INIT.txt'),'changed after checkpoint publication')
  }
}
$mh=(&git -C $root rev-parse HEAD).Trim()
$ch=(&git -C $cache rev-parse HEAD).Trim()
$fp=(SourceFingerprint)
$obj=@{schemaVersion=1;generatedAt=([DateTime]::UtcNow.ToString('o'));project='qbit';repository='qbit-test-gate';member=@{root=$root;head=$mh;branch='main';dirty=$false;fingerprint=$fp};context=@{root=$cache;head=$ch;freshness='CURRENT_OR_FETCHED'};membership=@{registered=$true;projectMatches=$true}}
[IO.File]::WriteAllText((Join-Path $root '.ai-bridge/context-runtime.json'),($obj|ConvertTo-Json -Depth 8))
[IO.File]::WriteAllText((Join-Path $root '.ai-bridge/context-runtime.md'),'fixture runtime')
'@
  [IO.File]::WriteAllText((Join-Path $ctx 'context.ps1'),$launcher)
  $missing=Run-Gate 'Verify'
  Assert ($missing.Code -eq 3) 'missing start evidence blocks'
  $started=Run-Gate 'Start'
  Assert ($started.Code -eq 0) ('Start verifies current remote: '+$started.Output)
  $verified=Run-Gate 'Verify'
  Assert ($verified.Code -eq 3) 'Verify requires a published checkpoint, even when remote matches'
  $payload=@{schemaVersion=2;repository='qbit-test-gate';scope='sync-gate-fixture';status='COMPLETED';nextAction='Review next validated item';continuity=@{mode='snapshot';workstream=$null}}
  [IO.File]::WriteAllText((Join-Path $bridge 'context-checkpoint.json'),($payload|ConvertTo-Json -Depth 5))
  $published=Run-Gate 'Checkpoint'
  Assert ($published.Code -eq 0) ('Checkpoint publishes and verifies: '+$published.Output)
  $verified=Run-Gate 'Verify'
  Assert ($verified.Code -eq 0) ('Verify validates current published source: '+$verified.Output)
  [IO.File]::WriteAllText((Join-Path $member 'INIT.txt'),'changed without new source commit')
  $mutated=Run-Gate 'Verify'
  Assert ($mutated.Code -eq 3) 'Verify rejects content changes with unchanged source HEAD'
  [IO.File]::WriteAllText((Join-Path $member 'INIT.txt'),'fixture')
  $originalPayload=[IO.File]::ReadAllText((Join-Path $bridge 'context-checkpoint.json'))
  [IO.File]::WriteAllText((Join-Path $bridge 'context-checkpoint.json'),($originalPayload+' '))
  Assert ((Run-Gate 'Verify').Code -eq 3) 'Verify rejects unpublished ignored checkpoint decisions'
  [IO.File]::WriteAllText((Join-Path $bridge 'context-checkpoint.json'),$originalPayload)
  $rtPath=Join-Path $bridge 'context-runtime.json'
  $originalRuntime=[IO.File]::ReadAllText($rtPath)
  $badRuntime=$originalRuntime|ConvertFrom-Json;$badRuntime.generatedAt='2000-01-01T00:00:00Z'
  [IO.File]::WriteAllText($rtPath,($badRuntime|ConvertTo-Json -Depth 8))
  Assert ((Run-Gate 'Status').Code -eq 3) 'touching runtime cannot revive expired embedded evidence'
  [IO.File]::WriteAllText($rtPath,$originalRuntime)
  [IO.File]::WriteAllText((Join-Path $bridge 'hang.flag'),'test timeout')
  $clock=[Diagnostics.Stopwatch]::StartNew();$hung=Run-Gate 'Verify' 2;$clock.Stop()
  Assert ($hung.Code -eq 3 -and $clock.Elapsed.TotalSeconds -lt 12) 'bounded verification kills stalled launcher tree'
  Remove-Item -LiteralPath (Join-Path $bridge 'hang.flag')
  $configPath=Join-Path $ctx 'config.json';$configText=[IO.File]::ReadAllText($configPath)
  [IO.File]::WriteAllText($configPath,'{INVALID_PRIVATE_SENTINEL')
  $redacted=Run-Gate 'Verify'
  Assert ($redacted.Code -eq 3 -and $redacted.Output -notmatch 'INVALID_PRIVATE_SENTINEL') 'malformed configuration errors redact content'
  [IO.File]::WriteAllText($configPath,$configText)
  $relativeConfig=$configText|ConvertFrom-Json;$relativeConfig.context.remote='../central.git'
  [IO.File]::WriteAllText($configPath,($relativeConfig|ConvertTo-Json -Depth 6))
  Assert ((Run-Gate 'Verify').Code -eq 0) 'relative configured remote resolves against member Worktree'
  [IO.File]::WriteAllText($configPath,$configText)
  $recordPath=Join-Path $cache 'state/repositories/qbit-test-gate.md'
  [IO.File]::AppendAllText($recordPath,'; unverified later state change')
  &git -C $cache add state/repositories/qbit-test-gate.md
  &git -C $cache commit -q -m 'state-only unrelated mutation'
  &git -C $cache push -q origin main
  # Refresh only runtime via Start; the later state-only change is committed but
  # has no Manifest publication and must never close the owning milestone.
  Assert ((Run-Gate 'Start').Code -eq 0) 'state-only mutation fixture has live remote health'
  Assert ((Run-Gate 'Verify').Code -eq 3) 'later state mutation cannot reuse an older Manifest receipt'
  [IO.File]::WriteAllText((Join-Path $bridge 'other-only.flag'),'fixture unrelated central state change')
  $wrongMember=Run-Gate 'Checkpoint'
  Assert ($wrongMember.Code -eq 3) 'unrelated published Context commit must NOT count as current member checkpoint'
  Remove-Item -LiteralPath (Join-Path $bridge 'other-only.flag')
  [IO.File]::WriteAllText((Join-Path $bridge 'wrong-manifest.flag'),'misattribute published checkpoint')
  $wrongManifest=Run-Gate 'Checkpoint'
  Assert ($wrongManifest.Code -eq 3) 'member manifest scope mismatch must reject even with a changed state and newly added session'
  Remove-Item -LiteralPath (Join-Path $bridge 'wrong-manifest.flag')
  $tracked=@{
    schemaVersion=2;repository='qbit-test-gate';scope='tracked-fixture';status='IN_PROGRESS'
    nextAction='Complete task WS-42'
    continuity=@{
      mode='tracked';workstream=@{
        id='workstream-fixture';status='IN_PROGRESS'
        cursor=@{currentItemId='WS-42';nextAction='Complete task WS-42'}
      }
    }
  }
  [IO.File]::WriteAllText((Join-Path $bridge 'context-checkpoint.json'),($tracked|ConvertTo-Json -Depth 8))
  $trackedSuccess=Run-Gate 'Checkpoint'
  Assert ($trackedSuccess.Code -eq 0) ('valid tracked workstream and cursor must publish: '+$trackedSuccess.Output)
  [IO.File]::WriteAllText((Join-Path $bridge 'late-source-mutation.flag'),'mutate tracked file after publishing')
  $lateEdit=Run-Gate 'Checkpoint'
  Assert ($lateEdit.Code -eq 3) 'source changed after published checkpoint must fail fresh native fingerprint receipt'
  Remove-Item -LiteralPath (Join-Path $bridge 'late-source-mutation.flag')
  [IO.File]::WriteAllText((Join-Path $member 'INIT.txt'),'fixture')
  [IO.File]::WriteAllText((Join-Path $bridge 'wrong-workstream.flag'),'publish wrong cursor')
  $wrongWorkstream=Run-Gate 'Checkpoint'
  Assert ($wrongWorkstream.Code -eq 3) 'changed state and manifest with wrong published Workstream cursor must fail'
  Remove-Item -LiteralPath (Join-Path $bridge 'wrong-workstream.flag')
  [IO.File]::WriteAllText((Join-Path $bridge 'reuse-session.flag'),'replay previously published session')
  $reusedSession=Run-Gate 'Checkpoint'
  Assert ($reusedSession.Code -eq 3) 'replayed previously published session must not satisfy a new checkpoint receipt'
  Remove-Item -LiteralPath (Join-Path $bridge 'reuse-session.flag')
  [IO.File]::WriteAllText((Join-Path $bridge 'context-checkpoint.json'),'{"schemaVersion":1,"repository":"qbit-test-gate"}')
  $legacy=Run-Gate 'Checkpoint'
  Assert ($legacy.Code -eq 3) 'legacy checkpoint rejected'
  &git -C $seed pull -q --ff-only origin main
  &git -C $seed commit --allow-empty -q -m 'remote advanced'
  &git -C $seed push -q origin main
  $drift=Run-Gate 'Verify'
  Assert ($drift.Code -eq 3) 'remote divergence detected'
  Write-Host "PASS $passed/$passed Context sync gate integration tests; failed=0 skipped=0"
} finally {
  if($env:QBIT_TEST_KEEP -eq '1'){Write-Host "Fixture retained: $root"}
  elseif(Test-Path -LiteralPath $root){Remove-Item -LiteralPath $root -Recurse -Force}
}
