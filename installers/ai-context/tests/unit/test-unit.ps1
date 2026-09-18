Set-StrictMode -Version 2
$ErrorActionPreference='Stop'
$InstallerRoot=(Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
. (Join-Path $InstallerRoot 'lib/installer.ps1')
$Passed=0;$Failed=0
function Assert([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message}}
function ExpectFail([scriptblock]$Body,[string]$Text){$FailedAsExpected=$false;try{&$Body}catch{$FailedAsExpected=$_.Exception.Message -like "*$Text*"};Assert $FailedAsExpected "Expected failure containing '$Text'"}
function Test([string]$Name,[scriptblock]$Body){try{&$Body;$script:Passed++;Write-Host "PASS $Name"}catch{$script:Failed++;Write-Host "FAIL ${Name}: $($_.Exception.Message)"}}

Test 'safe identifiers accept repository slugs' { Assert ((Assert-SafeId 'qbit-console-api' 'RepositoryId') -eq 'qbit-console-api') 'valid id changed' }
Test 'identifiers reject traversal and whitespace' { ExpectFail { Assert-SafeId '../bad' 'RepositoryId' } 'must match';ExpectFail { Assert-SafeId 'bad id' 'RepositoryId' } 'must match' }
Test 'branches reject traversal-like ref names' { ExpectFail { Assert-SafeBranch 'feature/../main' } 'invalid';Assert ((Assert-SafeBranch 'feature/context-v2') -eq 'feature/context-v2') 'valid branch changed' }
Test 'remote rejects embedded URL credentials' { ExpectFail { Assert-SafeRemote 'https://user:password@example.com/context.git' } 'must not embed credentials' }
Test 'member templates render without unresolved placeholders' {
  $V=Get-Variables 'demo' 'Demo' 'demo-api' 'demo-ai-context' 'https://github.com/example/demo-ai-context.git' 'main';$S=New-Spec 'member' $V
  foreach($Text in @($S.Files.Values)+@($S.Blocks.Values|%{$_.Content})+@($S.Seeds.Values)){Assert (-not ([string]$Text -match '\{\{[A-Z0-9_]+\}\}')) 'unresolved member placeholder'}
}
Test 'central templates render without unresolved placeholders' {
  $V=Get-Variables 'demo' 'Demo' 'demo-ai-context' 'demo-ai-context' 'https://github.com/example/demo-ai-context.git' 'main';$S=New-Spec 'central' $V
  foreach($Text in @($S.Files.Values)+@($S.Blocks.Values|%{$_.Content})+@($S.Seeds.Values)){Assert (-not ([string]$Text -match '\{\{[A-Z0-9_]+\}\}')) 'unresolved central placeholder'}
}
Test 'central seeds and managed tooling are separated' {
  $V=Get-Variables 'demo' 'Demo' 'demo-ai-context' 'demo-ai-context' 'https://github.com/example/demo-ai-context.git' 'main';$S=New-Spec 'central' $V
  Assert ($S.Files.ContainsKey('tooling/context-lifecycle.ps1')) 'central tooling not managed';Assert ($S.Seeds.ContainsKey('state/current.md')) 'current state not seeded';Assert (-not $S.Files.ContainsKey('state/current.md')) 'current state incorrectly installer-managed'
}
Test 'managed file hash normalizes UTF-8 BOM and line endings' {
  $Root=Join-Path ([IO.Path]::GetTempPath()) ('ai-context-hash-' + [Guid]::NewGuid().ToString('N'));New-Item -ItemType Directory -Force -Path $Root|Out-Null
  try {
    $Lf=Join-Path $Root 'lf.txt';$Crlf=Join-Path $Root 'crlf.txt';$Bom=Join-Path $Root 'bom.txt'
    [IO.File]::WriteAllText($Lf,"alpha`nbeta`n",[Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($Crlf,"alpha`r`nbeta`r`n",[Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($Bom,"alpha`r`nbeta`r`n",[Text.UTF8Encoding]::new($true))
    $Expected=Get-TextSha256 "alpha`nbeta`n"
    Assert ((Get-FileSha256 $Lf) -eq $Expected) 'LF hash mismatch'
    Assert ((Get-FileSha256 $Crlf) -eq $Expected) 'CRLF hash was not normalized'
    Assert ((Get-FileSha256 $Bom) -eq $Expected) 'UTF-8 BOM was not normalized'
  } finally {Remove-Item -LiteralPath $Root -Recurse -Force -ErrorAction SilentlyContinue}
}
Test 'rendered lifecycle exposes audit and forbids automatic rebase' {
  $V=Get-Variables 'demo' 'Demo' 'demo-ai-context' 'demo-ai-context' 'https://github.com/example/demo-ai-context.git' 'main';$S=New-Spec 'central' $V
  $PowerShell=[string]$S.Files['tooling/context-lifecycle.ps1'];$Python=[string]$S.Files['tooling/context-lifecycle.py']
  Assert ($PowerShell.Contains("'audit'")) 'PowerShell lifecycle does not expose audit'
  Assert ($Python.Contains('"audit"')) 'Python lifecycle does not expose audit'
  Assert (-not $PowerShell.Contains("@('rebase'")) 'PowerShell lifecycle still contains automatic rebase command'
  Assert (-not $Python.Contains('["rebase",')) 'Python lifecycle still contains automatic rebase command'
}
Test 'PowerShell checkpoint secret scan treats JSON value types as leaves' {
  $V=Get-Variables 'demo' 'Demo' 'demo-ai-context' 'demo-ai-context' 'https://github.com/example/demo-ai-context.git' 'main';$S=New-Spec 'central' $V
  $PowerShell=[string]$S.Files['tooling/context-lifecycle.ps1']
  Assert ($PowerShell.Contains('if ($Node -is [System.ValueType]) { return }')) 'PowerShell lifecycle can recurse into DateTime/value-type properties during secret scanning'
}

if($Failed -gt 0){throw "$Failed unit test(s) failed; $Passed passed."}
Write-Host "PASS all $Passed AI Context installer unit tests"
