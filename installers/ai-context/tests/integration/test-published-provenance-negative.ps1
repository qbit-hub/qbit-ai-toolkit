#requires -Version 5.1
param([string]$FixtureRoot=(Join-Path ([IO.Path]::GetTempPath()) 'qbit-published-provenance'))
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$installerRoot=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$toolkitRoot=(Resolve-Path (Join-Path $installerRoot '../..')).Path
$hostExe=(Get-Command powershell.exe -ErrorAction Stop).Source
$runRoot=Join-Path ([IO.Path]::GetFullPath($FixtureRoot)) ([Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $runRoot|Out-Null
$started=[DateTimeOffset]::UtcNow
$sourceRelativePaths=@('templates/common/member/context.ps1','templates/common/member/context-sync-gate.ps1','templates/common/central/tooling/context-lifecycle.ps1','templates/common/central/tooling/context-continuity.ps1','tests/integration/test-published-provenance-negative.ps1')
$sourceHashesAtStart=@($sourceRelativePaths|ForEach-Object{[ordered]@{path=$_;sha256=(Get-FileHash -LiteralPath (Join-Path $installerRoot $_) -Algorithm SHA256).Hash}})
$passed=0;$failed=0
$results=New-Object 'Collections.Generic.List[object]'
function WriteUtf8([string]$Path,[string]$Value){
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Path)|Out-Null
  [IO.File]::WriteAllText($Path,$Value,[Text.UTF8Encoding]::new($false))
}
function FixtureGit([string]$Root,[string[]]$Arguments){
  $old=$ErrorActionPreference;$ErrorActionPreference='Continue'
  try{$out=@(& git.exe -c core.longpaths=true -C $Root @Arguments 2>&1);$code=$LASTEXITCODE}
  finally{$ErrorActionPreference=$old}
  if($code -ne 0){throw ('Fixture Git failed: '+($Arguments -join ' ')+': '+($out -join "`n"))}
  return ($out -join "`n").Trim()
}
function Run([string]$Script,[string[]]$Arguments){
  $old=$ErrorActionPreference;$ErrorActionPreference='Continue'
  try{$out=@(& $hostExe -NoProfile -ExecutionPolicy Bypass -File $Script @Arguments 2>&1);$code=$LASTEXITCODE}
  finally{$ErrorActionPreference=$old}
  $value=[pscustomobject]@{Code=$code;Text=($out -join "`n")}
  Add-Content -LiteralPath (Join-Path $runRoot 'commands.log') -Encoding UTF8 -Value ($Script+' '+($Arguments -join ' ')+"`nexit="+$code+"`n"+$value.Text)
  return $value
}
function Assert([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message}}
function Case([string]$Name,[scriptblock]$Body){
  & $Body
  $script:passed++
  $results.Add([pscustomobject]@{name=$Name;result='PASS'})
  Write-Output ('PASS '+$Name)
}
function InitRepo([string]$Root){
  New-Item -ItemType Directory -Force -Path $Root|Out-Null
  FixtureGit $Root @('init','-q','-b','main')|Out-Null
  FixtureGit $Root @('config','user.name','Provenance Fixture')|Out-Null
  FixtureGit $Root @('config','user.email','provenance@example.invalid')|Out-Null
  FixtureGit $Root @('config','core.autocrlf','false')|Out-Null
  WriteUtf8 (Join-Path $Root 'source.txt') "committed source`n"
  FixtureGit $Root @('add','source.txt')|Out-Null
  FixtureGit $Root @('commit','-q','-m','bootstrap')|Out-Null
}
function Gate([string]$Mode){return Run $gate @('-MemberPath',$member,'-Mode',$Mode,'-TimeoutSeconds','60')}
function Payload([string]$Scope,[string]$Destination=$payload){
  $entries=@()
  if($Scope -in @('published-baseline','sibling-ledger-append')){
    # Each seed records an actual successful Start already executed by its
    # owning fixture. Subsequent repair checkpoints append no duplicate IDs.
    $entries=@([ordered]@{id=('provenance-start-'+$Scope);kind='integration';result='PASS';repository='provenance-member';scope=$Scope;summary='Actual installed Start accepted this registered fixture.';timestamp=[DateTimeOffset]::UtcNow.ToString('o');command='context-sync-gate.ps1 -Mode Start';evidenceRefs=@('commands.log')})
  }
  $cp=[ordered]@{schemaVersion=2;repository='provenance-member';scope=$Scope;status='VALIDATED';objective='Verify exact published provenance rejects isolated invalid records.';confirmedFindings=@('Actual installed Windows lifecycle with real disposable Git remote.');decisions=@('Fixture-only context; preserve all source bytes and valid publication.');rejectedApproaches=@();validation=@('Published provenance negative integration.');openQuestions=@();nextAction='Inspect the negative acceptance evidence.';continuity=@{mode='snapshot';workstream=$null;validationLedger=$entries}}
  WriteUtf8 $Destination ($cp|ConvertTo-Json -Depth 12)
}
function Publish([string]$Scope){
  $r=Gate 'Start';Assert ($r.Code -eq 0) $r.Text
  Payload $Scope
  $r=Gate 'Checkpoint';Assert ($r.Code -eq 0) $r.Text
  $r=Gate 'Verify';Assert ($r.Code -eq 0) $r.Text
  UpdateReceiptPaths
}
function UpdateReceiptPaths {
  $runtime=Get-Content -LiteralPath (Join-Path $member '.ai-bridge/context-runtime.json') -Raw -Encoding UTF8|ConvertFrom-Json
  if($runtime.continuity.PSObject.Properties.Name -contains 'receiptPaths' -and $null -ne $runtime.continuity.receiptPaths){
    $script:manifestRelative=[string]$runtime.continuity.receiptPaths.manifest
    $script:recordRelative=[string]$runtime.continuity.receiptPaths.state
    $script:handoffRelative=[string]$runtime.continuity.receiptPaths.handoff
    Assert ($manifestRelative -match '^manifests/worktrees/provenance-member/wt-[0-9a-f]{32}\.json$' -and
      $recordRelative -match '^state/worktrees/provenance-member/wt-[0-9a-f]{32}\.md$') 'Runtime did not select canonical authoritative Worktree receipt paths'
  }else{
    $script:manifestRelative='manifests/repositories/provenance-member.json'
    $script:recordRelative='state/repositories/provenance-member.md'
    $script:handoffRelative='handoffs/repositories/provenance-member.md'
  }
}
function WriterCommit([string]$Message){
  FixtureGit $central @('add','--all')|Out-Null
  FixtureGit $central @('commit','-q','-m',$Message)|Out-Null
  FixtureGit $central @('push','-q','origin','main')|Out-Null
}
function TreeReceipt([string]$Root,[string[]]$Additional=@()){
  # This ASCII-named fixture intentionally hashes every selected tracked and
  # untracked file, including existing untracked bytes; porcelain alone cannot
  # detect their mutation. Cache/journal runtime is checked separately.
  $listed=FixtureGit $Root @('-c','core.quotePath=false','ls-files','--cached','--others','--exclude-standard')
  $paths=@(@($listed -split "`r?`n" | Where-Object {$_})+@($Additional)|Sort-Object -Unique)
  $receipt=[ordered]@{}
  foreach($relative in $paths){
    $absolute=Join-Path $Root $relative
    $receipt[$relative]=if(Test-Path -LiteralPath $absolute -PathType Leaf){(Get-FileHash -LiteralPath $absolute -Algorithm SHA256).Hash}else{'ABSENT'}
  }
  return ($receipt|ConvertTo-Json -Compress)
}
function AssertRejected([string]$Expected){
  $durableLocal=@('.ai-bridge/context-checkpoint.json','.ai-bridge/context-checkpoint-pending.json','.ai-bridge/context-checkpoint-pending.json.previous')
  $sourceBytes=TreeReceipt $member $durableLocal
  $cacheBytes=TreeReceipt $cache
  $sourceIndex=FixtureGit $member @('ls-files','--stage')
  $sourceStatus=FixtureGit $member @('status','--porcelain','--untracked-files=all')
  $remote=FixtureGit $bare @('rev-parse','refs/heads/main')
  $cacheHead=FixtureGit $cache @('rev-parse','HEAD')
  $cacheTree=FixtureGit $cache @('status','--porcelain','--untracked-files=all')
  $r=Gate 'Verify'
  Assert ($r.Code -eq 3 -and $r.Text -match 'CONTEXT_UNSYNCED' -and $r.Text -notmatch 'CONTEXT_SYNC_OK') ('Invalid evidence returned success: '+$r.Text)
  Assert ($r.Text -match $Expected) ('Wrong rejection reason: '+$r.Text)
  Assert ((TreeReceipt $member $durableLocal) -ceq $sourceBytes -and
    (FixtureGit $member @('ls-files','--stage')) -ceq $sourceIndex -and
    (FixtureGit $member @('status','--porcelain','--untracked-files=all')) -ceq $sourceStatus) 'Rejected Verify changed source/index/untracked state'
  Assert ((FixtureGit $bare @('rev-parse','refs/heads/main')) -eq $remote -and
    (FixtureGit $cache @('rev-parse','HEAD')) -eq $cacheHead -and
    (TreeReceipt $cache) -ceq $cacheBytes -and
    (FixtureGit $cache @('status','--porcelain','--untracked-files=all')) -ceq $cacheTree) 'Rejected Verify changed valid remote/cache history or bytes'
}
function Tamper([string]$Name,[scriptblock]$Mutation,[string]$Expected){
  FixtureGit $central @('pull','-q','--ff-only','origin','main')|Out-Null
  $script:base=FixtureGit $central @('rev-parse','HEAD')
  $script:manifest=Get-Content -LiteralPath (Join-Path $central $manifestRelative) -Encoding UTF8 -Raw|ConvertFrom-Json
  & $Mutation
  WriterCommit ('negative '+$Name)
  $r=Gate 'Start'
  if($r.Code -ne 0){
    # Some invalid owning records now fail even earlier, before Start writes
    # runtime. Prove that precise native diagnosis, then prove Verify still
    # refuses the stale runtime. Do not mistake a generic failing fixture for
    # validation of the tampered field.
    Assert ($r.Code -eq 3 -and $r.Text -match 'CONTEXT_UNSYNCED') ('Invalid Start returned an unexpected result: '+$r.Text)
    $native=Run (Join-Path $member '.ai/context/context.ps1') @('start')
    $earlyReason=if($Name -eq 'missing Manifest'){'Scoped Worktree Context Manifest is missing'}else{'Worktree Context Manifest owner does not match'}
    Assert ($native.Code -ne 0 -and $native.Text -match $earlyReason) ('Wrong early owning-record rejection: '+$native.Text)
    AssertRejected 'runtime cache HEAD mismatched'
  }else{AssertRejected $Expected}
  # Restore via a new additive commit: preserve the invalid commit for audit.
  FixtureGit $central @('restore',('--source='+$base),'--staged','--worktree','--','manifests','state','handoffs','sessions','validation')|Out-Null
  WriterCommit ('restore valid provenance after '+$Name)
  # A restoration commit is not the original immutable publication receipt.
  # Repair through a new actual checkpoint, never fabricate a passing receipt.
  Publish ('repaired-'+[Guid]::NewGuid().ToString('N'))
}
$exitCode=0
try{
  $bare=Join-Path $runRoot 'context.git';New-Item -ItemType Directory -Force -Path $bare|Out-Null
  FixtureGit $bare @('init','--bare','-q','--initial-branch=main')|Out-Null
  $central=Join-Path $runRoot 'central';InitRepo $central
  $install=Join-Path $installerRoot 'install.ps1'
  $r=Run $install @('-Operation','install','-Mode','central','-Target',$central,'-ProjectId','provenance','-RepositoryId','provenance-context','-ContextRemote',$bare)
  Assert ($r.Code -eq 0) $r.Text
  WriteUtf8 (Join-Path $central 'repositories/repositories.yaml') "project: provenance`nrepositories:`n  provenance-member:`n    role: disposable-registered-owner`n"
  FixtureGit $central @('remote','add','origin',$bare)|Out-Null
  FixtureGit $central @('add','--all')|Out-Null
  FixtureGit $central @('commit','-q','-m','installed central lifecycle')|Out-Null
  FixtureGit $central @('push','-q','-u','origin','main')|Out-Null
  $member=Join-Path $runRoot 'member';InitRepo $member
  $source=Join-Path $member 'source.txt'
  $r=Run $install @('-Operation','install','-Mode','member','-Target',$member,'-ProjectId','provenance','-RepositoryId','provenance-member','-ContextRemote',$bare)
  Assert ($r.Code -eq 0) $r.Text
  $gate=Join-Path $member '.ai/context/context-sync-gate.ps1'
  $payload=Join-Path $member '.ai-bridge/context-checkpoint.json'
  $cache=Join-Path $member '.ai/context/cache/project-context'
  $r=Gate 'Start';Assert ($r.Code -eq 0) $r.Text
  FixtureGit $cache @('config','user.name','Provenance Fixture')|Out-Null
  FixtureGit $cache @('config','user.email','provenance@example.invalid')|Out-Null
  $manifestRelative='manifests/repositories/provenance-member.json'
  $recordRelative='state/repositories/provenance-member.md'
  $ledgerRelative='validation/repositories/provenance-member.json'
  Case 'actual installed Start Checkpoint Verify establishes published baseline' {Publish 'published-baseline'}
  Case 'legitimate sibling validation append preserves owning receipt Verify' {
    $beforeManifest=FixtureGit $bare @('rev-parse',('refs/heads/main:'+$manifestRelative))
    $sibling=Join-Path $runRoot 'sibling'
    FixtureGit $member @('worktree','add','-q','-b','ledger-sibling',$sibling)|Out-Null
    $r=Run $install @('-Operation','install','-Mode','member','-Target',$sibling,'-ProjectId','provenance','-RepositoryId','provenance-member','-ContextRemote',$bare)
    Assert ($r.Code -eq 0) $r.Text
    $siblingGate=Join-Path $sibling '.ai/context/context-sync-gate.ps1'
    $r=Run $siblingGate @('-MemberPath',$sibling,'-Mode','Start','-TimeoutSeconds','60');Assert ($r.Code -eq 0) $r.Text
    $siblingCache=Join-Path $sibling '.ai/context/cache/project-context'
    FixtureGit $siblingCache @('config','user.name','Provenance Fixture')|Out-Null
    FixtureGit $siblingCache @('config','user.email','provenance@example.invalid')|Out-Null
    Payload 'sibling-ledger-append' (Join-Path $sibling '.ai-bridge/context-checkpoint.json')
    $r=Run $siblingGate @('-MemberPath',$sibling,'-Mode','Checkpoint','-TimeoutSeconds','60');Assert ($r.Code -eq 0) $r.Text
    Assert ((FixtureGit $bare @('rev-parse',('refs/heads/main:'+$manifestRelative))) -ceq $beforeManifest) 'Sibling changed the owning authoritative Manifest'
    $ledger=FixtureGit $bare @('show',('refs/heads/main:'+$ledgerRelative))|ConvertFrom-Json
    Assert (@($ledger.entries).Count -eq 2 -and [string]$ledger.entries[1].validFor.memberWorktree -ceq $sibling) 'Actual sibling validation was not appended to the shared ledger'
    $r=Gate 'Start';Assert ($r.Code -eq 0) $r.Text
    $r=Gate 'Verify';Assert ($r.Code -eq 0) $r.Text
  }
  Case 'deleted published validation ledger fails closed' {
    Tamper 'missing validation ledger' {Remove-Item -LiteralPath (Join-Path $central $ledgerRelative)} 'published validation ledger absent or invalid'
  }
  Case 'mutated published validation entry fails closed' {
    Tamper 'changed validation entry' {
      $ledger=Get-Content -LiteralPath (Join-Path $central $ledgerRelative) -Raw -Encoding UTF8|ConvertFrom-Json
      $ledger.entries[0].summary='Changed after its owning publication'
      WriteUtf8 (Join-Path $central $ledgerRelative) ($ledger|ConvertTo-Json -Depth 30)
    } 'validation ledger entries changed after publication'
  }
  Case 'truncated published validation ledger fails closed' {
    Tamper 'truncated validation ledger' {
      $ledger=Get-Content -LiteralPath (Join-Path $central $ledgerRelative) -Raw -Encoding UTF8|ConvertFrom-Json
      Assert (@($ledger.entries).Count -gt 1) 'Truncation fixture needs nonempty published history'
      $ledger.entries=@($ledger.entries|Select-Object -First (@($ledger.entries).Count-1))
      WriteUtf8 (Join-Path $central $ledgerRelative) ($ledger|ConvertTo-Json -Depth 30)
    } 'validation ledger lost previously published entries'
  }
  Case 'duplicate appended validation identity fails closed' {
    Tamper 'duplicate validation identity' {
      $ledger=Get-Content -LiteralPath (Join-Path $central $ledgerRelative) -Raw -Encoding UTF8|ConvertFrom-Json
      $ledger.entries=@($ledger.entries)+@($ledger.entries[0])
      WriteUtf8 (Join-Path $central $ledgerRelative) ($ledger|ConvertTo-Json -Depth 30)
    } 'validation ledger entry identities missing or duplicated'
  }
  Case 'expired Manifest with fresh runtime fails closed' {
    Tamper 'expired Manifest' {$manifest.generatedAt=[DateTimeOffset]::UtcNow.AddDays(-2).ToString('o');WriteUtf8 (Join-Path $central $manifestRelative) ($manifest|ConvertTo-Json -Depth 15)} 'checkpoint expired'
  }
  Case 'wrong owning Manifest repository fails closed' {
    Tamper 'wrong repository' {$manifest.repository='another-member';WriteUtf8 (Join-Path $central $manifestRelative) ($manifest|ConvertTo-Json -Depth 15)} 'Manifest does not represent'
  }
  Case 'wrong owning Worktree identity fails closed' {
    Tamper 'wrong Worktree' {$manifest.memberWorktree=Join-Path $runRoot 'different-member';WriteUtf8 (Join-Path $central $manifestRelative) ($manifest|ConvertTo-Json -Depth 15)} 'Manifest does not represent'
  }
  Case 'altered published fingerprint fails closed' {
    Tamper 'wrong fingerprint' {$manifest.worktreeFingerprint=('0'*64);WriteUtf8 (Join-Path $central $manifestRelative) ($manifest|ConvertTo-Json -Depth 15)} 'Manifest does not represent'
  }
  foreach($kind in @('operation','digest')){
    Case ('newly added Session with wrong '+$kind+' fails closed') {
      Tamper ('wrong Session '+$kind) {
        $oldSession=[string]$manifest.session
        $manifest.session='sessions/2026/10/forged-'+[Guid]::NewGuid().ToString('N')+'.md'
        WriteUtf8 (Join-Path $central $manifestRelative) ($manifest|ConvertTo-Json -Depth 15)
        $state=[IO.File]::ReadAllText((Join-Path $central $recordRelative)).Replace($oldSession,[string]$manifest.session)
        WriteUtf8 (Join-Path $central $recordRelative) $state
        $handoff=[IO.File]::ReadAllText((Join-Path $central $handoffRelative)).Replace($oldSession,[string]$manifest.session)
        WriteUtf8 (Join-Path $central $handoffRelative) $handoff
        $id=if($kind -eq 'operation'){'0'*32}else{[string]$manifest.checkpointId}
        $digest=if($kind -eq 'digest'){'0'*64}else{[string]$manifest.checkpointPayloadSha256}
        WriteUtf8 (Join-Path $central ([string]$manifest.session)) ('Checkpoint ID: '+$id+"`nCheckpoint payload SHA256: "+$digest)
      } 'Session checkpoint identity or payload digest mismatch'
    }
  }
  Case 'deleted owning Manifest fails closed' {
    Tamper 'missing Manifest' {Remove-Item -LiteralPath (Join-Path $central $manifestRelative)} 'Git show verification failed'
  }
  Case 'deleted published Session fails closed' {
    Tamper 'missing Session' {Remove-Item -LiteralPath (Join-Path $central ([string]$manifest.session))} 'Git rev-parse verification failed'
  }
  Case 'changed staged bytes with identical Worktree bytes fail real Verify' {
    WriteUtf8 $source 'staged one';FixtureGit $member @('add','source.txt')|Out-Null;WriteUtf8 $source 'unchanged Worktree'
    Publish 'staged-baseline'
    $beforeStatus=FixtureGit $member @('status','--porcelain')
    WriteUtf8 $source 'staged two';FixtureGit $member @('add','source.txt')|Out-Null;WriteUtf8 $source 'unchanged Worktree'
    Assert ((FixtureGit $member @('status','--porcelain')) -ceq $beforeStatus) 'Index fixture changed porcelain instead of only index identity'
    AssertRejected 'Manifest does not represent'
    Publish 'staged-repair'
  }
  Case 'existing untracked content mutation fails real Verify' {
    $untracked=Join-Path $member 'untracked-decision-reference.txt';WriteUtf8 $untracked 'first bytes'
    Publish 'untracked-baseline'
    WriteUtf8 $untracked 'second bytes'
    AssertRejected 'Manifest does not represent'
    Publish 'untracked-repair'
  }
  Case 'tracked source mutation fails real Verify' {
    WriteUtf8 $source 'changed after publication'
    AssertRejected 'Manifest does not represent'
    Publish 'source-repair'
  }
}catch{
  $failed=1;$exitCode=1
  $results.Add([pscustomobject]@{name='failure';result='FAIL';detail=$_.Exception.Message})
  Write-Output ('FAIL '+$_.Exception.Message)
}finally{
  $hashes=@();foreach($relative in $sourceRelativePaths){
    $hashes += [ordered]@{path=$relative;sha256=(Get-FileHash -LiteralPath (Join-Path $installerRoot $relative) -Algorithm SHA256).Hash}
  }
  $sourceStable=(($sourceHashesAtStart|ConvertTo-Json -Depth 5 -Compress) -ceq ($hashes|ConvertTo-Json -Depth 5 -Compress))
  if(-not $sourceStable){$failed=1;$exitCode=1;$results.Add([pscustomobject]@{name='source stability';result='FAIL';detail='Installer or regression source changed during execution; this run is not final acceptance.'})}
  $installedHashes=@()
  foreach($mapping in @(@('templates/common/member/context-sync-gate.ps1','member/.ai/context/context-sync-gate.ps1'),@('templates/common/central/tooling/context-lifecycle.ps1','central/tooling/context-lifecycle.ps1'),@('templates/common/central/tooling/context-continuity.ps1','central/tooling/context-continuity.ps1'))){
    $installedPath=Join-Path $runRoot $mapping[1]
    if(Test-Path -LiteralPath $installedPath -PathType Leaf){$installedHashes += [ordered]@{path=$installedPath;sourcePath=$mapping[0];sha256=(Get-FileHash -LiteralPath $installedPath -Algorithm SHA256).Hash}}
  }
  $summary=[ordered]@{suite='published-provenance-negative';startUtc=$started.ToString('o');endUtc=[DateTimeOffset]::UtcNow.ToString('o');host=$hostExe;powershell=$PSVersionTable.PSVersion.ToString();gitVersion=(& git.exe --version);sourceRepository=$toolkitRoot;sourceHead=(FixtureGit $toolkitRoot @('rev-parse','HEAD'));sourceBranch=(FixtureGit $toolkitRoot @('branch','--show-current'));sourceHashesAtStart=$sourceHashesAtStart;sourceHashes=$hashes;sourceStable=$sourceStable;installedSourceHashes=$installedHashes;passed=$passed;failed=$failed;executed=($passed+$failed);skipped=0;exitCode=$exitCode;fixtureRoot=$runRoot;results=@($results.ToArray())}
  WriteUtf8 (Join-Path $runRoot 'results.json') ($summary|ConvertTo-Json -Depth 12)
  Write-Output ('PUBLISHED_PROVENANCE executed='+($passed+$failed)+' passed='+$passed+' failed='+$failed+' skipped=0 exit='+$exitCode+' evidence='+$runRoot)
}
exit $exitCode
