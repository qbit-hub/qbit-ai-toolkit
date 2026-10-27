Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$tmpl=Join-Path $PSScriptRoot '../../templates/common/central/tooling/context-continuity.ps1'
$root=Join-Path ([IO.Path]::GetTempPath()) ('qbit-fingerprint-'+[guid]::NewGuid().ToString('N'))
function Invoke-Git {
  param([string]$WorkingDirectory,[string[]]$Arguments,[switch]$AllowFailure)
  $previous=$ErrorActionPreference
  $ErrorActionPreference='Continue'
  try{
    $response=@(& git -C $WorkingDirectory @Arguments 2>&1)
    $exit=$LASTEXITCODE
  } finally{$ErrorActionPreference=$previous}
  if($exit -ne 0 -and -not $AllowFailure){throw 'Git fixture failure'}
  return [pscustomobject]@{ExitCode=$exit;Output=($response -join [Environment]::NewLine).Trim()}
}
$passed=0
function Assert([bool]$condition,[string]$message) {
  if(-not $condition){throw "FAIL $message"}
  $script:passed++
}
function Write-Source([string]$name,[string]$content) {
  [IO.File]::WriteAllText((Join-Path $root $name),$content,[Text.UTF8Encoding]::new($false))
}
function Assert-Mutation([string]$name,[string]$content,[string]$message) {
  $before=Get-ContinuityFingerprint -Root $root
  Write-Source $name $content
  $after=Get-ContinuityFingerprint -Root $root
  Assert ($before -ne $after) $message
}
try {
  New-Item -ItemType Directory -Force $root|Out-Null
  & git -C $root init -q -b main
  & git -C $root config user.name Test
  & git -C $root config user.email test@example.invalid
  & git -C $root config core.quotePath true
  $unicodeName=([string][char]0x641+[char]0x627+[char]0x631+[char]0x633+[char]0x6cc)
  $trackedUnicode=$unicodeName+' tracked.txt'
  $untrackedUnicode=$unicodeName+' untracked.txt'
  [IO.File]::WriteAllText((Join-Path $root 'tracked.txt'),'v1')
  [IO.File]::WriteAllText((Join-Path $root 'deleted.txt'),'gone')
  Write-Source $trackedUnicode 'initial'
  & git -C $root add --all
  & git -C $root commit -q -m fixture
  . $tmpl
  # Regression: PowerShell 5.1 native pipelines inject a UTF-8 BOM. A
  # successful fingerprint comparison alone can mask a failed bulk hash because
  # the implementation falls back to individual Git processes.
  $clean=Get-ContinuityFingerprint -Root $root
  Assert ($clean -eq (Get-ContinuityFingerprint -Root $root)) 'unchanged source fingerprint is deterministic'
  Assert-Mutation 'tracked.txt' 'v2' 'tracked modification changes fingerprint'
  Assert-Mutation 'tracked.txt' 'v3' 'content mutation within existing dirty tracked file changes fingerprint'
  Write-Source 'tracked.txt' 'staged one'
  & git -C $root add tracked.txt
  Write-Source 'tracked.txt' 'same worktree'
  $indexBefore=Get-ContinuityFingerprint -Root $root
  Write-Source 'tracked.txt' 'staged two'
  & git -C $root add tracked.txt
  Write-Source 'tracked.txt' 'same worktree'
  Assert ($indexBefore -ne (Get-ContinuityFingerprint -Root $root)) 'index byte changes with unchanged worktree and porcelain change fingerprint'
  Assert-Mutation $trackedUnicode 'dirty one' 'Unicode tracked modification changes fingerprint'
  Assert-Mutation $trackedUnicode 'dirty two' 'Unicode tracked mutation with unchanged porcelain changes fingerprint'
  Assert-Mutation $untrackedUnicode 'one' 'Unicode untracked addition changes fingerprint'
  Assert-Mutation $untrackedUnicode 'two' 'Unicode untracked content mutation changes fingerprint'
  Assert-Mutation '  leading and trailing space .txt' 'one' 'space path addition changes fingerprint'
  Assert-Mutation '  leading and trailing space .txt' 'two' 'space path mutation changes fingerprint'
  $beforeDelete=Get-ContinuityFingerprint -Root $root
  Remove-Item -LiteralPath (Join-Path $root 'deleted.txt')
  Assert ($beforeDelete -ne (Get-ContinuityFingerprint -Root $root)) 'tracked deletion changes fingerprint'
  $probe=Invoke-ContinuityHashBatch -Root $root -Paths @('tracked.txt',$trackedUnicode,$untrackedUnicode)
  Assert ($probe.ExitCode -eq 0 -and @($probe.Hashes).Count -eq 3) 'no-BOM hash batch accepts Unicode names'
  $expected=(& git -C $root hash-object --no-filters -- $trackedUnicode).Trim()
  Assert ($probe.Hashes[1] -eq $expected) 'batch hash matches direct Git hash of Unicode bytes'
  $spaceProbe=Invoke-ContinuityHashBatch -Root $root -Paths @('  leading and trailing space .txt')
  Assert ($spaceProbe.ExitCode -eq 0 -and @($spaceProbe.Hashes).Count -eq 1) 'quoted stdin preserves path whitespace'
  # NTFS forbids newline and quote file names; do not pretend native coverage.
  for($i=0;$i -lt 3000;$i++) {
    $prefix=if($i % 2 -eq 0){$unicodeName}else{'file'}
    Write-Source ("$prefix $i.txt") ("fixture-$i")
  }
  $script:hashBatchCalls=0
  $script:hashBatchPaths=0
  $script:gitTextCalls=0
  $script:originalHashBatch=${function:Invoke-ContinuityHashBatch}
  $script:originalGitText=${function:Invoke-ContinuityGitText}
  function Invoke-ContinuityHashBatch {
    param([string]$Root,[string[]]$Paths)
    $script:hashBatchCalls++
    $script:hashBatchPaths=$Paths.Count
    & $script:originalHashBatch -Root $Root -Paths $Paths
  }
  function Invoke-ContinuityGitText {
    param([string]$Root,[string]$Arguments)
    $script:gitTextCalls++
    & $script:originalGitText -Root $Root -Arguments $Arguments
  }
  $watch=[Diagnostics.Stopwatch]::StartNew()
  $batched=Get-ContinuityFingerprint -Root $root
  $fast=$watch.ElapsedMilliseconds
  Assert ($script:hashBatchCalls -eq 1 -and $script:hashBatchPaths -ge 3000) 'thousands of ASCII/Unicode files use one batch'
  Assert ($script:gitTextCalls -eq 5) 'path and index discovery use bounded five Git processes'
  Assert ($batched -match '^[0-9a-f]{64}$') 'large-fixture fingerprint is SHA-256'
  function Invoke-ContinuityHashBatch {
    param([string]$Root,[string[]]$Paths)
    [pscustomobject]@{ExitCode=1;Hashes=@();ErrorText='simulated unreadable file'}
  }
  $rejected=$false
  try { Get-ContinuityFingerprint -Root $root | Out-Null } catch { $rejected=$true }
  Assert $rejected 'failed batch rejects capture without fallback or false state'
  Write-Output "PASS $passed/$passed fingerprint integration assertions; failed=0 skipped=0 files=3000 batchMs=$fast"
} finally {
  if(Test-Path -LiteralPath $root){
    $absolute=[IO.Path]::GetFullPath($root)
    $expectedPrefix=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\qbit-fingerprint-'
    if(-not $absolute.StartsWith($expectedPrefix,[StringComparison]::OrdinalIgnoreCase)){throw 'Unsafe fixture cleanup path'}
    Remove-Item -LiteralPath $absolute -Recurse -Force
  }
}
