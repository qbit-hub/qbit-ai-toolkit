#requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$InstallerRoot=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$Installer=Join-Path $InstallerRoot 'install.ps1'
$HostPath=(Get-Command powershell.exe -ErrorAction Stop).Source
$TempRoot=Join-Path ([IO.Path]::GetTempPath()) ('context-upgrade-'+[Guid]::NewGuid().ToString('N'))
$Passed=0;$Failed=0
function Assert([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message}}
function WriteUtf8([string]$Path,[string]$Text){
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Path)|Out-Null
  [IO.File]::WriteAllText($Path,$Text,[Text.UTF8Encoding]::new($false))
}
function Canonical([string]$Text){return $Text.Replace("`r`n","`n").Replace("`r","`n")}
function ShaBytes([byte[]]$Bytes){
  $sha=[Security.Cryptography.SHA256]::Create()
  try{return -join($sha.ComputeHash($Bytes)|ForEach-Object{$_.ToString('x2')})}finally{$sha.Dispose()}
}
function ShaFile([string]$Path){return ShaBytes ([IO.File]::ReadAllBytes($Path))}
function Run([string[]]$Arguments,[string]$Entry=$Installer){
  $previous=$ErrorActionPreference;$ErrorActionPreference='Continue'
  try{$out=@(& $HostPath -NoProfile -ExecutionPolicy Bypass -File $Entry @Arguments -Format json 2>&1);$code=$LASTEXITCODE}
  finally{$ErrorActionPreference=$previous}
  $json=$null
  try{$json=($out -join "`n")|ConvertFrom-Json}catch{}
  return [pscustomobject]@{Code=$code;Json=$json;Text=($out -join "`n")}
}
function Fixture-Git([string]$Root,[string[]]$Arguments){
  $previous=$ErrorActionPreference;$ErrorActionPreference='Continue'
  try{$out=@(& git -c core.longpaths=true -C $Root @Arguments 2>&1);$code=$LASTEXITCODE}
  finally{$ErrorActionPreference=$previous}
  if($code -ne 0){throw "Fixture Git failed: $($Arguments -join ' ')"}
  return ($out -join "`n").Trim()
}
function NewRepo([string]$Name){
  $repo=Join-Path $TempRoot $Name
  New-Item -ItemType Directory -Force -Path $repo|Out-Null
  Fixture-Git $repo @('init','-q','-b','main')|Out-Null
  Fixture-Git $repo @('config','core.autocrlf','false')|Out-Null
  WriteUtf8 (Join-Path $repo 'source.txt') "committed source`n"
  WriteUtf8 (Join-Path $repo 'AGENTS.md') "# User rules`nretain this prefix`n"
  Fixture-Git $repo @('add','source.txt','AGENTS.md')|Out-Null
  Fixture-Git $repo @('-c','user.name=Fixture','-c','user.email=fixture@example.invalid','commit','-q','-m','fixture')|Out-Null
  return $repo
}
function InstallMember([string]$Repo){
  return Run @('-Operation','install','-Mode','member','-Target',$Repo,'-ProjectId','demo','-RepositoryId','demo-member','-ContextRemote','https://github.com/example/demo-ai-context.git')
}
function Test([string]$Name,[scriptblock]$Body){
  try{& $Body;$script:Passed++;Write-Output "PASS $Name"}
  catch{$script:Failed++;Write-Output "FAIL ${Name}: $($_.Exception.Message)"}
}
try{
  New-Item -ItemType Directory -Force -Path $TempRoot|Out-Null
  Test 'fresh current install includes byte-exact managed gate and valid state' {
    $repo=NewRepo 'fresh member with spaces'
    $result=InstallMember $repo
    Assert ($result.Code -eq 0 -and $result.Json.success) ("fresh install failed: "+$result.Text)
    $verify=Run @('-Operation','verify','-Target',$repo)
    Assert ($verify.Code -eq 0 -and $verify.Json.success) 'fresh verification failed'
    $expected=Canonical ([IO.File]::ReadAllText((Join-Path $InstallerRoot 'templates/common/member/context-sync-gate.ps1')))
    Assert ((ShaFile (Join-Path $repo '.ai/context/context-sync-gate.ps1')) -eq (ShaBytes ([Text.Encoding]::UTF8.GetBytes($expected)))) 'installed gate bytes differ from accepted template'
    $state=Get-Content (Join-Path $repo '.qbit/toolkit/installed/ai-context.json') -Raw|ConvertFrom-Json
    foreach($entry in $state.managedFiles){Assert ((ShaFile (Join-Path $repo $entry.path)) -eq $entry.sha256) ("managed byte hash mismatch: "+$entry.path)}
  }
  Test 'simulated supported prior ownership upgrades and repeats without changing user work' {
    $repo=NewRepo 'ownership-upgrade'
    Assert ((InstallMember $repo).Code -eq 0) 'initial install failed'
    $statePath=Join-Path $repo '.qbit/toolkit/installed/ai-context.json'
    $state=Get-Content $statePath -Raw|ConvertFrom-Json
    $state.installerVersion='1.2.8'
    $gate=Join-Path $repo '.ai/context/context-sync-gate.ps1'
    WriteUtf8 $gate "# simulated supported previous managed bytes`n"
    foreach($entry in $state.managedFiles){if($entry.path -eq '.ai/context/context-sync-gate.ps1'){$entry.sha256=ShaFile $gate}}
    WriteUtf8 $statePath ($state|ConvertTo-Json -Depth 10)
    $agents=Join-Path $repo 'AGENTS.md'
    [IO.File]::AppendAllText($agents,"`n# Dirty user suffix`nretain this suffix`n",[Text.UTF8Encoding]::new($false))
    WriteUtf8 (Join-Path $repo 'source.txt') "uncommitted user source`n"
    WriteUtf8 (Join-Path $repo 'unmanaged.txt') "untracked user file`n"
    $beforeAgents=ShaFile $agents;$beforeSource=ShaFile (Join-Path $repo 'source.txt');$beforeUnmanaged=ShaFile (Join-Path $repo 'unmanaged.txt')
    $head=Fixture-Git $repo @('rev-parse','HEAD')
    $update=Run @('-Operation','update','-Target',$repo)
    Assert ($update.Code -eq 0 -and $update.Json.success) ("supported ownership update failed: "+$update.Text)
    $updatedState=Get-Content $statePath -Raw|ConvertFrom-Json
    Assert ($updatedState.installerVersion -eq ([IO.File]::ReadAllText((Join-Path $InstallerRoot 'VERSION')).Trim())) 'upgrade retained old version'
    Assert ((ShaFile $agents) -eq $beforeAgents) 'upgrade changed unmanaged dirty AGENTS content'
    Assert ((ShaFile (Join-Path $repo 'source.txt')) -eq $beforeSource) 'upgrade changed dirty source'
    Assert ((ShaFile (Join-Path $repo 'unmanaged.txt')) -eq $beforeUnmanaged) 'upgrade changed untracked file'
    Assert ((Fixture-Git $repo @('rev-parse','HEAD')) -eq $head) 'upgrade changed Git history'
    $stateHash=ShaFile $statePath
    $again=Run @('-Operation','update','-Target',$repo)
    Assert ($again.Code -eq 0 -and @($again.Json.actions).Count -eq 0) 'repeated update was not idempotent'
    Assert ((ShaFile $statePath) -eq $stateHash) 'idempotent update rewrote ownership state'
    Assert ((Run @('-Operation','verify','-Target',$repo)).Code -eq 0) 'verify failed after upgrade'
  }
  Test 'relocated dirty linked worktree retains installation and relative configuration' {
    $source=NewRepo 'linked-source'
    $old=Join-Path $TempRoot 'linked old location'
    $new=Join-Path $TempRoot 'linked relocated location'
    Fixture-Git $source @('worktree','add','-q','-b','fixture/relocation',$old)|Out-Null
    Assert ((InstallMember $old).Code -eq 0) 'linked worktree install failed'
    WriteUtf8 (Join-Path $old 'source.txt') "preserved relocation dirty source`n"
    $sourceHash=ShaFile (Join-Path $old 'source.txt')
    $cfgHash=ShaFile (Join-Path $old '.ai/context/config.json')
    Fixture-Git $source @('worktree','move',$old,$new)|Out-Null
    Assert ((Run @('-Operation','verify','-Target',$new)).Code -eq 0) 'relocated linked worktree verify failed'
    Assert ((Run @('-Operation','update','-Target',$new)).Code -eq 0) 'relocated linked worktree update failed'
    Assert ((ShaFile (Join-Path $new 'source.txt')) -eq $sourceHash) 'relocation/update changed dirty source'
    Assert ((ShaFile (Join-Path $new '.ai/context/config.json')) -eq $cfgHash) 'relocation rewrote relative configuration'
  }
  Test 'managed tampering fails verify and update while preserving all bytes' {
    $repo=NewRepo 'managed-tamper'
    Assert ((InstallMember $repo).Code -eq 0) 'initial install failed'
    $gate=Join-Path $repo '.ai/context/context-sync-gate.ps1'
    [IO.File]::AppendAllText($gate,"`n# dirty managed modification`n")
    $before=ShaFile $gate
    Assert ((Run @('-Operation','verify','-Target',$repo)).Code -ne 0) 'verify accepted tampered managed file'
    Assert ((Run @('-Operation','update','-Target',$repo)).Code -ne 0) 'update silently replaced tampered managed file'
    Assert ((ShaFile $gate) -eq $before) 'failed update overwrote dirty managed bytes'
  }
  Test 'manifest and VERSION disagreement fails before target mutation' {
    $copy=Join-Path $TempRoot 'invalid-version-installer'
    Copy-Item -LiteralPath $InstallerRoot -Destination $copy -Recurse
    WriteUtf8 (Join-Path $copy 'VERSION') "9.9.9`n"
    $repo=NewRepo 'invalid-version-target'
    $before=Fixture-Git $repo @('status','--porcelain','--untracked-files=all')
    $bad=Run @('-Operation','install','-Mode','member','-Target',$repo,'-ProjectId','demo','-RepositoryId','demo-member','-ContextRemote','https://github.com/example/demo-ai-context.git') (Join-Path $copy 'install.ps1')
    Assert ($bad.Code -ne 0) 'mismatched installer VERSION was accepted'
    Assert (-not(Test-Path (Join-Path $repo '.qbit/toolkit/installed/ai-context.json'))) 'invalid version wrote ownership state'
    Assert ((Fixture-Git $repo @('status','--porcelain','--untracked-files=all')) -eq $before) 'invalid version mutated target'
  }
  Test 'malformed installer manifest fails before target mutation' {
    $copy=Join-Path $TempRoot 'invalid-manifest-installer'
    Copy-Item -LiteralPath $InstallerRoot -Destination $copy -Recurse
    WriteUtf8 (Join-Path $copy 'manifest.json') '{ malformed'
    $repo=NewRepo 'invalid-manifest-target'
    $before=Fixture-Git $repo @('status','--porcelain','--untracked-files=all')
    $bad=Run @('-Operation','install','-Mode','member','-Target',$repo,'-ProjectId','demo','-RepositoryId','demo-member','-ContextRemote','https://github.com/example/demo-ai-context.git') (Join-Path $copy 'install.ps1')
    Assert ($bad.Code -ne 0) 'malformed installer manifest was accepted'
    Assert ((Fixture-Git $repo @('status','--porcelain','--untracked-files=all')) -eq $before) 'invalid manifest mutated target'
  }
  Test 'missing Git in child process fails without target mutation' {
    $repo=NewRepo 'missing-git-target'
    $before=Fixture-Git $repo @('status','--porcelain','--untracked-files=all')
    $savedPath=$env:PATH
    try{$env:PATH=Join-Path $TempRoot 'empty-command-path';$bad=InstallMember $repo}
    finally{$env:PATH=$savedPath}
    Assert ($bad.Code -ne 0 -and $bad.Text -match 'Git is required') 'missing Git dependency did not fail clearly'
    Assert ((Fixture-Git $repo @('status','--porcelain','--untracked-files=all')) -eq $before) 'missing dependency mutated target'
  }
}finally{
  if(Test-Path -LiteralPath $TempRoot){
    $absolute=[IO.Path]::GetFullPath($TempRoot)
    $prefix=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\context-upgrade-'
    if(-not $absolute.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){throw 'Unsafe fixture cleanup target'}
    Remove-Item -LiteralPath $absolute -Recurse -Force
  }
}
Write-Output "RESULT executed=$($Passed+$Failed) passed=$Passed failed=$Failed skipped=0"
if($Failed -gt 0){exit 1}
exit 0
