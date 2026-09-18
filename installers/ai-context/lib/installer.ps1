Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'

$Script:InstallerRoot = ([System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))).TrimEnd('\','/')
$Script:ToolkitRoot = ([System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))).TrimEnd('\','/')
$Script:InstallerId = 'installer.ai-context'
$Script:InstallerVersion = '1.2.8'
$Script:StatePath = '.qbit/toolkit/installed/ai-context.json'
$Script:BlockBegin = '<!-- qbit-toolkit:ai-context:start -->'
$Script:BlockEnd = '<!-- qbit-toolkit:ai-context:end -->'
$Script:GitignoreBegin = '# qbit-toolkit:ai-context:start'
$Script:GitignoreEnd = '# qbit-toolkit:ai-context:end'
$Script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function ConvertTo-CanonicalPath([string]$Path) {
  return ([System.IO.Path]::GetFullPath($Path)).TrimEnd([System.IO.Path]::DirectorySeparatorChar,[System.IO.Path]::AltDirectorySeparatorChar)
}

function Resolve-AiContextTarget([string]$InputPath) {
  if ([string]::IsNullOrWhiteSpace($InputPath)) { throw 'Target is required.' }
  $Resolved = ConvertTo-CanonicalPath $InputPath
  if (-not (Test-Path -LiteralPath $Resolved -PathType Container)) { throw "Target directory does not exist: $InputPath" }
  $RootPath = [System.IO.Path]::GetPathRoot($Resolved).TrimEnd('\','/')
  if ($Resolved.TrimEnd('\','/') -ieq $RootPath) { throw 'Refusing to target a filesystem root.' }
  if ($env:USERPROFILE -and ((ConvertTo-CanonicalPath $env:USERPROFILE) -ieq $Resolved)) { throw 'Refusing to target the user home root.' }
  if ($Resolved -ieq $Script:ToolkitRoot) { throw 'Refusing to install the AI Context asset into qbit-ai-toolkit itself.' }
  if (-not (Get-Command git -ErrorAction SilentlyContinue)) { throw 'Git is required.' }
  $Inside = @(& git -C $Resolved rev-parse --is-inside-work-tree 2>$null)
  if ($LASTEXITCODE -ne 0 -or (($Inside -join '').Trim() -ne 'true')) { throw 'Target must be a Git work tree.' }
  $GitTop = ConvertTo-CanonicalPath ((@(& git -C $Resolved rev-parse --show-toplevel) -join '').Trim())
  if ($GitTop -ine $Resolved) { throw "Target must be the Git work tree root. Git root is: $GitTop" }
  return $Resolved
}

function Assert-SafeId([string]$Value,[string]$Name) {
  if ([string]::IsNullOrWhiteSpace($Value) -or $Value.Length -gt 100 -or $Value -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') {
    throw "$Name must match ^[A-Za-z0-9][A-Za-z0-9._-]*$ and be at most 100 characters."
  }
  return $Value
}

function Assert-SafeDisplayName([string]$Value) {
  if ([string]::IsNullOrWhiteSpace($Value) -or $Value.Length -gt 160) { throw 'ProjectDisplayName is required and must be at most 160 characters.' }
  foreach ($Character in $Value.ToCharArray()) {
    if ([Globalization.CharUnicodeInfo]::GetUnicodeCategory($Character) -eq [Globalization.UnicodeCategory]::Control) {
      throw 'ProjectDisplayName must not contain control characters.'
    }
  }
  return $Value
}

function Assert-SafeBranch([string]$Value) {
  if ([string]::IsNullOrWhiteSpace($Value) -or $Value.Length -gt 200 -or $Value.StartsWith('-') -or $Value.Contains('..') -or $Value -notmatch '^[A-Za-z0-9][A-Za-z0-9._/-]*$') {
    throw 'ContextBranch is invalid.'
  }
  return $Value
}

function Assert-SafeRemote([string]$Value) {
  if ([string]::IsNullOrWhiteSpace($Value) -or $Value.Length -gt 2048 -or $Value.Contains("`r") -or $Value.Contains("`n")) { throw 'ContextRemote is invalid.' }
  if ($Value -match '^[a-zA-Z][a-zA-Z0-9+.-]*://') {
    $Uri = $null
    if (-not [Uri]::TryCreate($Value,[UriKind]::Absolute,[ref]$Uri)) { throw 'ContextRemote URL is invalid.' }
    if ($Uri.Scheme -notin @('http','https')) { throw 'ContextRemote URL must use http or https.' }
    if (-not [string]::IsNullOrEmpty($Uri.UserInfo)) { throw 'ContextRemote must not embed credentials.' }
  }
  return $Value
}

function Get-FileSha256([string]$Path) {
  $Bytes = [IO.File]::ReadAllBytes($Path)
  $Bom = $Bytes.Length -ge 3 -and $Bytes[0] -eq 0xEF -and $Bytes[1] -eq 0xBB -and $Bytes[2] -eq 0xBF
  $Offset = if ($Bom) { 3 } else { 0 }
  $Decoder = New-Object Text.UTF8Encoding($false,$true)
  try { $Text = $Decoder.GetString($Bytes,$Offset,$Bytes.Length-$Offset) }
  catch { throw "Managed text file is not valid UTF-8: $Path" }
  return Get-TextSha256 $Text
}

function Get-BytesSha256([byte[]]$Bytes) {
  $Sha = [Security.Cryptography.SHA256]::Create()
  try { return -join ($Sha.ComputeHash($Bytes) | ForEach-Object { $_.ToString('x2') }) }
  finally { $Sha.Dispose() }
}

function Get-TextSha256([string]$Text) {
  $Canonical = $Text.Replace("`r`n","`n").Replace("`r","`n")
  return Get-BytesSha256 ([Text.Encoding]::UTF8.GetBytes($Canonical))
}

function ConvertTo-JsonStringContent([string]$Value) {
  $Json = ConvertTo-Json -InputObject $Value -Compress
  return $Json.Substring(1,$Json.Length-2)
}

function ConvertTo-YamlSingleQuoted([string]$Value) {
  return "'" + $Value.Replace("'","''") + "'"
}

function Read-Template([string]$RelativePath) {
  $Path = Join-Path $Script:InstallerRoot $RelativePath
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Installer template is missing: $RelativePath" }
  return [IO.File]::ReadAllText($Path,[Text.Encoding]::UTF8).Replace("`r`n","`n").Replace("`r","`n")
}

function Render-Template([string]$RelativePath,[hashtable]$Variables) {
  $Text = Read-Template $RelativePath
  foreach ($Key in $Variables.Keys) { $Text = $Text.Replace('{{' + $Key + '}}',[string]$Variables[$Key]) }
  if ($Text -match '\{\{[A-Z0-9_]+\}\}') { throw "Unresolved template placeholder in ${RelativePath}: $($Matches[0])" }
  if (-not $Text.EndsWith("`n")) { $Text += "`n" }
  return $Text
}

function Write-Utf8File([string]$Path,[string]$Content) {
  $Parent = Split-Path -Parent $Path
  if (-not (Test-Path -LiteralPath $Parent)) { New-Item -ItemType Directory -Force -Path $Parent | Out-Null }
  $Normalized = $Content.Replace("`r`n","`n").Replace("`r","`n")
  [IO.File]::WriteAllText($Path,$Normalized,$Script:Utf8NoBom)
}

function Join-UnderRoot([string]$Root,[string]$RelativePath) {
  if ([IO.Path]::IsPathRooted($RelativePath) -or $RelativePath -match '(^|/)\.\.(/|$)' -or $RelativePath.Contains('\')) { throw "Unsafe relative path: $RelativePath" }
  if ($RelativePath -notmatch '^[A-Za-z0-9._/-]+$') { throw "Unsafe relative path: $RelativePath" }
  $Full = ConvertTo-CanonicalPath (Join-Path $Root $RelativePath)
  $Prefix = (ConvertTo-CanonicalPath $Root) + [IO.Path]::DirectorySeparatorChar
  if (-not ($Full + [IO.Path]::DirectorySeparatorChar).StartsWith($Prefix,[StringComparison]::OrdinalIgnoreCase)) { throw "Path escapes target root: $RelativePath" }
  return $Full
}

function Assert-NoReparseParents([string]$Root,[string]$RelativePath) {
  $Current = ConvertTo-CanonicalPath $Root
  foreach ($Segment in $RelativePath.Split('/')) {
    $Current = Join-Path $Current $Segment
    if (-not (Test-Path -LiteralPath $Current)) { continue }
    $Item = Get-Item -LiteralPath $Current -Force
    if (($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Unsafe reparse-point target path: $RelativePath" }
  }
}

function Get-TextDocument([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
  $Bytes = [IO.File]::ReadAllBytes($Path)
  $Bom = $Bytes.Length -ge 3 -and $Bytes[0] -eq 0xEF -and $Bytes[1] -eq 0xBB -and $Bytes[2] -eq 0xBF
  $Offset = if ($Bom) { 3 } else { 0 }
  $Decoder = New-Object Text.UTF8Encoding($false,$true)
  try { $Text = $Decoder.GetString($Bytes,$Offset,$Bytes.Length-$Offset) }
  catch { throw "Managed text file is not valid UTF-8: $Path" }
  $NewLine = if ($Text.Contains("`r`n")) { "`r`n" } else { "`n" }
  return [pscustomobject]@{ Text=$Text; NewLine=$NewLine; Bom=$Bom; Bytes=$Bytes }
}

function Write-TextDocument([string]$Path,[string]$Text,[string]$NewLine,[bool]$Bom) {
  $Parent = Split-Path -Parent $Path
  if (-not (Test-Path -LiteralPath $Parent)) { New-Item -ItemType Directory -Force -Path $Parent | Out-Null }
  $Normalized = $Text.Replace("`r`n","`n").Replace("`r","`n").Replace("`n",$NewLine)
  $Encoding = New-Object Text.UTF8Encoding($Bom)
  [IO.File]::WriteAllText($Path,$Normalized,$Encoding)
}

function Get-BlockInfo([string]$Path,[string]$Begin,[string]$End) {
  $Doc = Get-TextDocument $Path
  if ($null -eq $Doc) { return [pscustomobject]@{ Status='absent-file'; Hash=$null; Doc=$null } }
  $Start = $Doc.Text.IndexOf($Begin,[StringComparison]::Ordinal)
  $Finish = $Doc.Text.IndexOf($End,[StringComparison]::Ordinal)
  if ($Start -lt 0 -and $Finish -lt 0) { return [pscustomobject]@{ Status='absent-block'; Hash=$null; Doc=$Doc } }
  if ($Start -lt 0 -or $Finish -lt 0 -or $Finish -lt $Start -or $Doc.Text.IndexOf($Begin,$Start+$Begin.Length,[StringComparison]::Ordinal) -ge 0 -or $Doc.Text.IndexOf($End,$Finish+$End.Length,[StringComparison]::Ordinal) -ge 0) {
    return [pscustomobject]@{ Status='malformed'; Hash=$null; Doc=$Doc }
  }
  $InnerStart = $Start + $Begin.Length
  $Inner = $Doc.Text.Substring($InnerStart,$Finish-$InnerStart).Trim("`r","`n")
  return [pscustomobject]@{ Status='present'; Hash=(Get-TextSha256 $Inner); Doc=$Doc; Start=$Start; End=($Finish+$End.Length); Inner=$Inner }
}

function Set-ManagedBlock([string]$Path,[string]$Begin,[string]$End,[string]$Content) {
  $Info = Get-BlockInfo $Path $Begin $End
  if ($Info.Status -eq 'malformed') { throw "Managed block markers are malformed in $Path" }
  $NewLine = if ($null -eq $Info.Doc) { "`n" } else { $Info.Doc.NewLine }
  $Bom = if ($null -eq $Info.Doc) { $false } else { [bool]$Info.Doc.Bom }
  $Body = $Content.Replace("`r`n","`n").Replace("`r","`n").Trim("`n").Replace("`n",$NewLine)
  $Block = $Begin + $NewLine + $Body + $NewLine + $End
  if ($Info.Status -eq 'present') {
    $Text = $Info.Doc.Text.Substring(0,$Info.Start) + $Block + $Info.Doc.Text.Substring($Info.End)
  } elseif ($null -eq $Info.Doc) {
    $Text = $Block + $NewLine
  } else {
    $Text = $Info.Doc.Text
    if ($Text.Length -gt 0 -and -not ($Text.EndsWith("`n") -or $Text.EndsWith("`r"))) { $Text += $NewLine }
    if ($Text.Length -gt 0) { $Text += $NewLine }
    $Text += $Block + $NewLine
  }
  Write-TextDocument $Path $Text $NewLine $Bom
}

function Remove-ManagedBlock([string]$Path,[string]$Begin,[string]$End) {
  $Info = Get-BlockInfo $Path $Begin $End
  if ($Info.Status -eq 'absent-file' -or $Info.Status -eq 'absent-block') { return }
  if ($Info.Status -ne 'present') { throw "Managed block markers are malformed in $Path" }
  $Before = $Info.Doc.Text.Substring(0,$Info.Start).TrimEnd("`r","`n")
  $After = $Info.Doc.Text.Substring($Info.End).TrimStart("`r","`n")
  if ($Before.Length -eq 0 -and $After.Length -eq 0) { Remove-Item -LiteralPath $Path -Force; return }
  $Text = if ($Before.Length -eq 0) { $After } elseif ($After.Length -eq 0) { $Before + $Info.Doc.NewLine } else { $Before + $Info.Doc.NewLine + $Info.Doc.NewLine + $After }
  Write-TextDocument $Path $Text $Info.Doc.NewLine ([bool]$Info.Doc.Bom)
}

function Get-State([string]$Root) {
  $Path = Join-UnderRoot $Root $Script:StatePath
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
  try { $State = [IO.File]::ReadAllText($Path,[Text.Encoding]::UTF8) | ConvertFrom-Json }
  catch { throw 'AI Context ownership state is invalid JSON.' }
  foreach ($Name in @('schemaVersion','installerId','installerVersion','mode','projectId','repositoryId','contextRemote','contextBranch','managedFiles','managedBlocks','seededFiles','stateFile')) {
    if (-not ($State.PSObject.Properties.Name -contains $Name)) { throw "AI Context ownership state is missing $Name." }
  }
  if ([string]$State.schemaVersion -cne '1.0' -or [string]$State.installerId -cne $Script:InstallerId -or [string]$State.stateFile -cne $Script:StatePath) { throw 'AI Context ownership state identity is invalid.' }
  return $State
}

function Get-StateFileMap([object]$State) {
  $Map = @{}
  if ($null -eq $State) { return $Map }
  foreach ($Item in @($State.managedFiles)) { $Map[[string]$Item.path] = [string]$Item.sha256 }
  return $Map
}

function Get-StateBlockMap([object]$State) {
  $Map = @{}
  if ($null -eq $State) { return $Map }
  foreach ($Item in @($State.managedBlocks)) { $Map[[string]$Item.path] = [pscustomobject]@{ sha256=[string]$Item.sha256; begin=[string]$Item.begin; end=[string]$Item.end } }
  return $Map
}

function Get-Variables([string]$ProjectId,[string]$ProjectDisplayName,[string]$RepositoryId,[string]$ContextRepositoryId,[string]$ContextRemote,[string]$ContextBranch) {
  return @{
    PROJECT_ID=$ProjectId
    PROJECT_DISPLAY_NAME=$ProjectDisplayName
    REPOSITORY_ID=$RepositoryId
    CONTEXT_REPOSITORY_ID=$ContextRepositoryId
    CONTEXT_REMOTE=$ContextRemote
    CONTEXT_BRANCH=$ContextBranch
    PROJECT_ID_JSON=(ConvertTo-JsonStringContent $ProjectId)
    REPOSITORY_ID_JSON=(ConvertTo-JsonStringContent $RepositoryId)
    CONTEXT_REMOTE_JSON=(ConvertTo-JsonStringContent $ContextRemote)
    CONTEXT_BRANCH_JSON=(ConvertTo-JsonStringContent $ContextBranch)
    PROJECT_ID_YAML=(ConvertTo-YamlSingleQuoted $ProjectId)
    CONTEXT_REMOTE_YAML=(ConvertTo-YamlSingleQuoted $ContextRemote)
    BOOTSTRAP_DATE=(Get-Date).ToString('yyyy-MM-dd',[Globalization.CultureInfo]::InvariantCulture)
  }
}

function New-Spec([string]$Mode,[hashtable]$Variables) {
  $Files = @{}
  $Blocks = @{}
  $Seeds = @{}
  $LegacyFiles = @{}
  $LegacyBlocks = @{}
  $Blocks['.gitignore'] = [pscustomobject]@{ Begin=$Script:GitignoreBegin; End=$Script:GitignoreEnd; Content=".qbit-toolkit/ai-context/backups/`n.qbit-toolkit/ai-context/transactions/`n" }
  if ($Mode -eq 'member') {
    $Files['.ai/context/context.ps1'] = Read-Template 'templates/common/member/context.ps1'
    $Files['.ai/context/context.sh'] = Read-Template 'templates/common/member/context.sh'
    $Files['.ai/context/context.py'] = Read-Template 'templates/common/member/context.py'
    $Files['.ai/context/context-transfer.ps1'] = Read-Template 'templates/common/member/context-transfer.ps1'
    $Files['.ai/context/config.json'] = Render-Template 'templates/common/member/config.json.tpl' $Variables
    $Files['.ai/context/.gitignore'] = Read-Template 'templates/common/member/context.gitignore'
    $Blocks['AGENTS.md'] = [pscustomobject]@{ Begin=$Script:BlockBegin; End=$Script:BlockEnd; Content=(Render-Template 'templates/common/member/agents-block.md.tpl' $Variables) }
    $Blocks['AI_CONTEXT.md'] = [pscustomobject]@{ Begin=$Script:BlockBegin; End=$Script:BlockEnd; Content=(Render-Template 'templates/common/member/AI_CONTEXT.md.tpl' $Variables) }
    $Blocks['.ai-bridge/.gitignore'] = [pscustomobject]@{ Begin=$Script:GitignoreBegin; End=$Script:GitignoreEnd; Content=(Read-Template 'templates/common/member/bridge.gitignore') }
    $Seeds['AI_CONTEXT.md'] = Render-Template 'templates/common/member/AI_CONTEXT-header.md.tpl' $Variables
    $Seeds['.ai-bridge/README.md'] = Read-Template 'templates/common/member/bridge.README.md'
    $LegacyBlocks['AGENTS.md'] = Render-Template 'templates/common/member/legacy-agents-section.md.tpl' $Variables
    $LegacyBlocks['AI_CONTEXT.md'] = Render-Template 'templates/common/member/legacy-ai-context-tail.md.tpl' $Variables
    $LegacyBlocks['.ai-bridge/.gitignore'] = Read-Template 'templates/common/member/bridge.gitignore'
  } else {
    $Files['tooling/context-lifecycle.ps1'] = Read-Template 'templates/common/central/tooling/context-lifecycle.ps1'
    $Files['tooling/context-continuity.ps1'] = Read-Template 'templates/common/central/tooling/context-continuity.ps1'
    $Files['tooling/context-lifecycle.py'] = Read-Template 'templates/common/central/tooling/context-lifecycle.py'
    $Files['templates/member/context.ps1'] = Read-Template 'templates/common/member/context.ps1'
    $Files['templates/member/context.sh'] = Read-Template 'templates/common/member/context.sh'
    $Files['templates/member/context.py'] = Read-Template 'templates/common/member/context.py'
    $Files['templates/member/context-transfer.ps1'] = Read-Template 'templates/common/member/context-transfer.ps1'
    $Files['tests/context-lifecycle.tests.ps1'] = Read-Template 'templates/common/central/tests/context-lifecycle.tests.ps1'
    $Files['tests/context-lifecycle.tests.sh'] = Read-Template 'templates/common/central/tests/context-lifecycle.tests.sh'
    $Files['schemas/checkpoint.schema.json'] = Read-Template 'templates/common/central/schemas/checkpoint.schema.json'
    $Files['docs/context-automation.md'] = Render-Template 'templates/common/central/docs/context-automation.md.tpl' $Variables
    $Blocks['AGENTS.md'] = [pscustomobject]@{ Begin=$Script:BlockBegin; End=$Script:BlockEnd; Content=(Render-Template 'templates/common/central/agents-block.md.tpl' $Variables) }
    $SeedMap = @{
      'AI_CONTEXT.md'='templates/common/central/AI_CONTEXT.md.tpl'
      'README.md'='templates/common/central/README.md.tpl'
      'project/authority.md'='templates/common/central/project/authority.md.tpl'
      'project/overview.md'='templates/common/central/project/overview.md.tpl'
      'project/constraints.md'='templates/common/central/project/constraints.md.tpl'
      'project/terminology.md'='templates/common/central/project/terminology.md.tpl'
      'state/current.md'='templates/common/central/state/current.md.tpl'
      'state/next-action.md'='templates/common/central/state/next-action.md.tpl'
      'state/open-questions.md'='templates/common/central/state/open-questions.md.tpl'
      'state/pending-decisions.md'='templates/common/central/state/pending-decisions.md.tpl'
      'state/repositories/README.md'='templates/common/central/state/repositories/README.md.tpl'
      'handoffs/latest.md'='templates/common/central/handoffs/latest.md.tpl'
      'handoffs/repositories/README.md'='templates/common/central/handoffs/repositories/README.md.tpl'
      'manifests/repository-state.yaml'='templates/common/central/manifests/repository-state.yaml.tpl'
      'manifests/repositories/README.md'='templates/common/central/manifests/repositories/README.md.tpl'
      'repositories/repositories.yaml'='templates/common/central/repositories/repositories.yaml.tpl'
      'references/README.md'='templates/common/central/references/README.md.tpl'
      'sessions/README.md'='templates/common/central/sessions/README.md.tpl'
    }
    foreach ($Destination in $SeedMap.Keys) { $Seeds[$Destination] = Render-Template $SeedMap[$Destination] $Variables }
  }
  return [pscustomobject]@{ Files=$Files; Blocks=$Blocks; Seeds=$Seeds; LegacyFiles=$LegacyFiles; LegacyBlocks=$LegacyBlocks }
}

function Test-JsonEquivalent([object]$Left,[object]$Right) {
  if ($null -eq $Left -or $null -eq $Right) { return $null -eq $Left -and $null -eq $Right }
  $LeftIsObject = $Left -is [pscustomobject]
  $RightIsObject = $Right -is [pscustomobject]
  if ($LeftIsObject -or $RightIsObject) {
    if (-not ($LeftIsObject -and $RightIsObject)) { return $false }
    [string[]]$LeftNames = @($Left.PSObject.Properties.Name | Sort-Object)
    [string[]]$RightNames = @($Right.PSObject.Properties.Name | Sort-Object)
    if (($LeftNames -join "`n") -cne ($RightNames -join "`n")) { return $false }
    foreach ($Name in $LeftNames) {
      if (-not (Test-JsonEquivalent $Left.$Name $Right.$Name)) { return $false }
    }
    return $true
  }
  $LeftIsArray = $Left -is [System.Array]
  $RightIsArray = $Right -is [System.Array]
  if ($LeftIsArray -or $RightIsArray) {
    if (-not ($LeftIsArray -and $RightIsArray) -or $Left.Count -ne $Right.Count) { return $false }
    for ($Index=0; $Index -lt $Left.Count; $Index++) { if (-not (Test-JsonEquivalent $Left[$Index] $Right[$Index])) { return $false } }
    return $true
  }
  if ($Left.GetType() -ne $Right.GetType()) { return $false }
  return $Left -ceq $Right
}

function Test-JsonFileEquivalent([string]$Path,[string]$ExpectedContent) {
  try {
    $Current = [IO.File]::ReadAllText($Path,[Text.Encoding]::UTF8) | ConvertFrom-Json
    $Expected = $ExpectedContent | ConvertFrom-Json
    return Test-JsonEquivalent $Current $Expected
  } catch { return $false }
}

function Get-NormalizedFileText([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
  return [IO.File]::ReadAllText($Path,[Text.Encoding]::UTF8).Replace("`r`n","`n").Replace("`r","`n")
}

function Test-LegacyTrailingContent([string]$Path,[string]$LegacyContent) {
  $Text = Get-NormalizedFileText $Path
  if ($null -eq $Text) { return $false }
  $Needle = $LegacyContent.Replace("`r`n","`n").Replace("`r","`n").Trim("`n")
  $Trimmed = $Text.TrimEnd("`r","`n")
  return $Trimmed.EndsWith($Needle,[StringComparison]::Ordinal)
}

function Test-LegacyMarkerPresent([string]$Path,[string]$LegacyContent) {
  $Text = Get-NormalizedFileText $Path
  if ($null -eq $Text) { return $false }
  $FirstLine = ($LegacyContent.Replace("`r`n","`n").Replace("`r","`n") -split "`n")[0]
  return -not [string]::IsNullOrWhiteSpace($FirstLine) -and $Text.Contains($FirstLine)
}

function Remove-LegacyTrailingContent([string]$Path,[string]$LegacyContent) {
  $Doc = Get-TextDocument $Path
  if ($null -eq $Doc) { throw "Legacy migration target is missing: $Path" }
  $Normalized = $Doc.Text.Replace("`r`n","`n").Replace("`r","`n")
  $Needle = $LegacyContent.Replace("`r`n","`n").Replace("`r","`n").Trim("`n")
  $Trimmed = $Normalized.TrimEnd("`r","`n")
  if (-not $Trimmed.EndsWith($Needle,[StringComparison]::Ordinal)) { throw "Legacy migration content no longer matches: $Path" }
  $Prefix = $Trimmed.Substring(0,$Trimmed.Length-$Needle.Length).TrimEnd("`r","`n")
  $Result = if ([string]::IsNullOrEmpty($Prefix)) { '' } else { $Prefix + "`n" }
  Write-TextDocument $Path $Result $Doc.NewLine ([bool]$Doc.Bom)
}

function New-Plan([string]$Root,[object]$Spec,[object]$State,[string]$OwnedModified,[bool]$AdoptMatching,[bool]$MigrateLegacy) {
  $Actions = New-Object Collections.Generic.List[object]
  $Conflicts = New-Object Collections.Generic.List[string]
  $OldFiles = Get-StateFileMap $State
  $OldBlocks = Get-StateBlockMap $State

  foreach ($RelativePath in @($Spec.Files.Keys | Sort-Object)) {
    Assert-NoReparseParents $Root $RelativePath
    $Path = Join-UnderRoot $Root $RelativePath
    $Bytes = [Text.Encoding]::UTF8.GetBytes(([string]$Spec.Files[$RelativePath]).Replace("`r`n","`n").Replace("`r","`n"))
    $ExpectedHash = Get-BytesSha256 $Bytes
    $Exists = Test-Path -LiteralPath $Path -PathType Leaf
    $CurrentHash = if ($Exists) { Get-FileSha256 $Path } else { $null }
    $Owned = $OldFiles.ContainsKey($RelativePath)
    if (-not $Owned) {
      if (-not $Exists) { $Actions.Add([pscustomobject]@{Kind='file';Action='create';Path=$RelativePath;ExpectedHash=$ExpectedHash}) }
      elseif ($CurrentHash -ceq $ExpectedHash -and $AdoptMatching) { $Actions.Add([pscustomobject]@{Kind='file';Action='adopt';Path=$RelativePath;ExpectedHash=$ExpectedHash}) }
      elseif ($CurrentHash -ceq $ExpectedHash) { $Conflicts.Add("Matching unowned file requires -AdoptMatching: $RelativePath") }
      elseif ($MigrateLegacy -and $RelativePath -ceq '.ai/context/config.json' -and (Test-JsonFileEquivalent $Path ([string]$Spec.Files[$RelativePath]))) {
        $Actions.Add([pscustomobject]@{Kind='file';Action='migrate';Path=$RelativePath;ExpectedHash=$ExpectedHash})
      }
      elseif ($MigrateLegacy -and $Spec.LegacyFiles.ContainsKey($RelativePath) -and ((Get-NormalizedFileText $Path).TrimEnd("`r","`n") -ceq ([string]$Spec.LegacyFiles[$RelativePath]).TrimEnd("`r","`n"))) {
        $Actions.Add([pscustomobject]@{Kind='file';Action='migrate';Path=$RelativePath;ExpectedHash=$ExpectedHash})
      }
      else { $Conflicts.Add("Unowned file conflict at $RelativePath") }
      continue
    }
    $OldHash = [string]$OldFiles[$RelativePath]
    if (-not $Exists) { $Actions.Add([pscustomobject]@{Kind='file';Action='create';Path=$RelativePath;ExpectedHash=$ExpectedHash}) }
    elseif ($CurrentHash -ceq $ExpectedHash) { }
    elseif ($CurrentHash -ceq $OldHash) { $Actions.Add([pscustomobject]@{Kind='file';Action='update';Path=$RelativePath;ExpectedHash=$ExpectedHash}) }
    elseif ($OwnedModified -eq 'replace') { $Actions.Add([pscustomobject]@{Kind='file';Action='replace';Path=$RelativePath;ExpectedHash=$ExpectedHash}) }
    else { $Conflicts.Add("Installer-owned file was modified: $RelativePath") }
  }

  foreach ($RelativePath in @($Spec.Blocks.Keys | Sort-Object)) {
    Assert-NoReparseParents $Root $RelativePath
    $Path = Join-UnderRoot $Root $RelativePath
    $Block = $Spec.Blocks[$RelativePath]
    $ExpectedHash = Get-TextSha256 ([string]$Block.Content).Trim("`r","`n")
    $Info = Get-BlockInfo $Path $Block.Begin $Block.End
    $Owned = $OldBlocks.ContainsKey($RelativePath)
    if (-not $Owned) {
      if ($Info.Status -in @('absent-file','absent-block')) {
        if ($Spec.LegacyBlocks.ContainsKey($RelativePath) -and (Test-LegacyTrailingContent $Path ([string]$Spec.LegacyBlocks[$RelativePath]))) {
          if ($MigrateLegacy) { $Actions.Add([pscustomobject]@{Kind='block';Action='migrate';Path=$RelativePath;ExpectedHash=$ExpectedHash}) }
          else { $Conflicts.Add("Recognized legacy content requires -MigrateLegacy: $RelativePath") }
        }
        elseif ($Spec.LegacyBlocks.ContainsKey($RelativePath) -and (Test-LegacyMarkerPresent $Path ([string]$Spec.LegacyBlocks[$RelativePath]))) {
          $Conflicts.Add("Legacy-like content is modified or unrecognized at $RelativePath")
        }
        else { $Actions.Add([pscustomobject]@{Kind='block';Action='create';Path=$RelativePath;ExpectedHash=$ExpectedHash}) }
      }
      elseif ($Info.Status -eq 'present' -and $Info.Hash -ceq $ExpectedHash -and $AdoptMatching) { $Actions.Add([pscustomobject]@{Kind='block';Action='adopt';Path=$RelativePath;ExpectedHash=$ExpectedHash}) }
      elseif ($Info.Status -eq 'present' -and $Info.Hash -ceq $ExpectedHash) { $Conflicts.Add("Matching unowned managed block requires -AdoptMatching: $RelativePath") }
      elseif ($Info.Status -eq 'malformed') { $Conflicts.Add("Managed block markers are malformed in $RelativePath") }
      else { $Conflicts.Add("Unowned managed block conflict at $RelativePath") }
      continue
    }
    $Old = $OldBlocks[$RelativePath]
    if ($Info.Status -ne 'present') { $Conflicts.Add("Previously managed block is missing or malformed in $RelativePath"); continue }
    if ($Info.Hash -ceq $ExpectedHash) { }
    elseif ($Info.Hash -ceq [string]$Old.sha256) { $Actions.Add([pscustomobject]@{Kind='block';Action='update';Path=$RelativePath;ExpectedHash=$ExpectedHash}) }
    elseif ($OwnedModified -eq 'replace') { $Actions.Add([pscustomobject]@{Kind='block';Action='replace';Path=$RelativePath;ExpectedHash=$ExpectedHash}) }
    else { $Conflicts.Add("Installer-owned managed block was modified: $RelativePath") }
  }

  foreach ($RelativePath in @($Spec.Seeds.Keys | Sort-Object)) {
    Assert-NoReparseParents $Root $RelativePath
    $Path = Join-UnderRoot $Root $RelativePath
    if (-not (Test-Path -LiteralPath $Path)) { $Actions.Add([pscustomobject]@{Kind='seed';Action='create';Path=$RelativePath}) }
  }
  return [pscustomobject]@{ Actions=[object[]]$Actions; Conflicts=[string[]]$Conflicts }
}

function Save-Original([Collections.Generic.List[object]]$Snapshots,[string]$Path) {
  if (@($Snapshots | Where-Object Path -CEQ $Path).Count -gt 0) { return }
  if (Test-Path -LiteralPath $Path -PathType Leaf) { $Snapshots.Add([pscustomobject]@{Path=$Path;Existed=$true;Bytes=[IO.File]::ReadAllBytes($Path)}) }
  else { $Snapshots.Add([pscustomobject]@{Path=$Path;Existed=$false;Bytes=$null}) }
}

function Restore-Snapshots([Collections.Generic.List[object]]$Snapshots) {
  for ($Index=$Snapshots.Count-1;$Index -ge 0;$Index--) {
    $Item=$Snapshots[$Index]
    if ($Item.Existed) {
      $Parent=Split-Path -Parent $Item.Path
      if (-not (Test-Path -LiteralPath $Parent)) { New-Item -ItemType Directory -Force -Path $Parent | Out-Null }
      [IO.File]::WriteAllBytes($Item.Path,[byte[]]$Item.Bytes)
    } elseif (Test-Path -LiteralPath $Item.Path -PathType Leaf) { Remove-Item -LiteralPath $Item.Path -Force }
  }
}

function Backup-ModifiedPath([string]$Root,[string]$RelativePath) {
  $Source=Join-UnderRoot $Root $RelativePath
  if (-not (Test-Path -LiteralPath $Source -PathType Leaf)) { return }
  $Stamp=(Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssfffZ',[Globalization.CultureInfo]::InvariantCulture)
  $Backup=Join-UnderRoot $Root ('.qbit-toolkit/ai-context/backups/' + $Stamp + '/' + $RelativePath)
  $Parent=Split-Path -Parent $Backup
  if (-not (Test-Path -LiteralPath $Parent)) { New-Item -ItemType Directory -Force -Path $Parent | Out-Null }
  Copy-Item -LiteralPath $Source -Destination $Backup -Force
}

function New-StateObject([string]$Mode,[string]$ProjectId,[string]$RepositoryId,[string]$ContextRemote,[string]$ContextBranch,[object]$Spec,[string[]]$SeededFiles) {
  $FilePaths=[string[]]@($Spec.Files.Keys)
  [Array]::Sort($FilePaths,[StringComparer]::Ordinal)
  $ManagedFiles=@()
  foreach($Path in $FilePaths) {
    $Content=([string]$Spec.Files[$Path]).Replace("`r`n","`n").Replace("`r","`n")
    $ManagedFiles += [ordered]@{path=$Path;sha256=(Get-BytesSha256 ([Text.Encoding]::UTF8.GetBytes($Content)))}
  }
  $BlockPaths=[string[]]@($Spec.Blocks.Keys)
  [Array]::Sort($BlockPaths,[StringComparer]::Ordinal)
  $ManagedBlocks=@()
  foreach($Path in $BlockPaths) {
    $Block=$Spec.Blocks[$Path]
    $ManagedBlocks += [ordered]@{path=$Path;begin=[string]$Block.Begin;end=[string]$Block.End;sha256=(Get-TextSha256 ([string]$Block.Content).Trim("`r","`n"))}
  }
  $SeedPaths=[string[]]@($SeededFiles)
  [Array]::Sort($SeedPaths,[StringComparer]::Ordinal)
  return [ordered]@{
    schemaVersion='1.0';installerId=$Script:InstallerId;installerVersion=$Script:InstallerVersion;mode=$Mode;projectId=$ProjectId;repositoryId=$RepositoryId
    contextRemote=$ContextRemote;contextBranch=$ContextBranch;installedAtUtc=(Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ',[Globalization.CultureInfo]::InvariantCulture)
    managedFiles=$ManagedFiles;managedBlocks=$ManagedBlocks;seededFiles=$SeedPaths;stateFile=$Script:StatePath
  }
}

function Write-State([string]$Root,[object]$State) {
  $Path=Join-UnderRoot $Root $Script:StatePath
  $Json=$State|ConvertTo-Json -Depth 8
  if (-not $Json.EndsWith("`n")){$Json+="`n"}
  Write-Utf8File $Path $Json
}

function Invoke-AiContextMutation([string]$Root,[object]$Spec,[object]$State,[object]$Plan,[string]$Mode,[string]$ProjectId,[string]$RepositoryId,[string]$ContextRemote,[string]$ContextBranch) {
  if ($Plan.Conflicts.Count -gt 0) { throw ('Conflicts:`n - ' + ($Plan.Conflicts -join "`n - ")) }
  $Snapshots=New-Object 'Collections.Generic.List[object]'
  $Seeded=New-Object Collections.Generic.List[string]
  if ($null -ne $State) { foreach($Path in @($State.seededFiles)){ $Seeded.Add([string]$Path) } }
  try {
    $OrderedActions = @($Plan.Actions | Sort-Object @{Expression={ if ($_.Kind -eq 'seed') { 0 } elseif ($_.Kind -eq 'file') { 1 } else { 2 } }}, @{Expression={$_.Path}})
    foreach($Item in $OrderedActions) {
      $Relative=[string]$Item.Path
      $Path=Join-UnderRoot $Root $Relative
      if ($Item.Kind -eq 'file') {
        if ($Item.Action -eq 'adopt') { continue }
        Save-Original $Snapshots $Path
        if ($Item.Action -eq 'replace') { Backup-ModifiedPath $Root $Relative }
        Write-Utf8File $Path ([string]$Spec.Files[$Relative])
      } elseif ($Item.Kind -eq 'block') {
        if ($Item.Action -eq 'adopt') { continue }
        Save-Original $Snapshots $Path
        if ($Item.Action -eq 'replace') { Backup-ModifiedPath $Root $Relative }
        if ($Item.Action -eq 'migrate') { Remove-LegacyTrailingContent $Path ([string]$Spec.LegacyBlocks[$Relative]) }
        $Block=$Spec.Blocks[$Relative]
        Set-ManagedBlock $Path $Block.Begin $Block.End ([string]$Block.Content)
      } elseif ($Item.Kind -eq 'seed') {
        Save-Original $Snapshots $Path
        Write-Utf8File $Path ([string]$Spec.Seeds[$Relative])
        if (-not $Seeded.Contains($Relative)) { $Seeded.Add($Relative) }
      }
    }
    $StateFile=Join-UnderRoot $Root $Script:StatePath
    Save-Original $Snapshots $StateFile
    Write-State $Root (New-StateObject $Mode $ProjectId $RepositoryId $ContextRemote $ContextBranch $Spec @($Seeded))
  } catch {
    Restore-Snapshots $Snapshots
    throw
  }
}

function Test-AiContextInstallation([string]$Root) {
  $State=Get-State $Root
  if ($null -eq $State) { throw 'AI Context ownership state is missing.' }
  $Errors=New-Object Collections.Generic.List[string]
  foreach($Item in @($State.managedFiles)) {
    $Path=Join-UnderRoot $Root ([string]$Item.path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { $Errors.Add("Missing managed file: $($Item.path)") }
    elseif ((Get-FileSha256 $Path) -cne [string]$Item.sha256) { $Errors.Add("Managed file hash mismatch: $($Item.path)") }
  }
  foreach($Item in @($State.managedBlocks)) {
    $Path=Join-UnderRoot $Root ([string]$Item.path)
    $Info=Get-BlockInfo $Path ([string]$Item.begin) ([string]$Item.end)
    if ($Info.Status -ne 'present') { $Errors.Add("Missing or malformed managed block: $($Item.path)") }
    elseif ($Info.Hash -cne [string]$Item.sha256) { $Errors.Add("Managed block hash mismatch: $($Item.path)") }
  }
  if ($Errors.Count -gt 0) { throw ('AI Context verification failed:`n - ' + ($Errors -join "`n - ")) }
  return $State
}

function Invoke-AiContextUninstall([string]$Root,[string]$OwnedModified) {
  $State=Get-State $Root
  if ($null -eq $State) { throw 'AI Context ownership state is missing.' }
  $Conflicts=New-Object Collections.Generic.List[string]
  foreach($Item in @($State.managedFiles)) {
    $Path=Join-UnderRoot $Root ([string]$Item.path)
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
      $Hash=Get-FileSha256 $Path
      if ($Hash -cne [string]$Item.sha256 -and $OwnedModified -ne 'replace') { $Conflicts.Add("Modified managed file: $($Item.path)") }
    }
  }
  foreach($Item in @($State.managedBlocks)) {
    $Path=Join-UnderRoot $Root ([string]$Item.path)
    $Info=Get-BlockInfo $Path ([string]$Item.begin) ([string]$Item.end)
    if ($Info.Status -eq 'present' -and $Info.Hash -cne [string]$Item.sha256 -and $OwnedModified -ne 'replace') { $Conflicts.Add("Modified managed block: $($Item.path)") }
    elseif ($Info.Status -eq 'malformed' -and $OwnedModified -ne 'replace') { $Conflicts.Add("Malformed managed block: $($Item.path)") }
  }
  if ($Conflicts.Count -gt 0) { throw ('Uninstall conflicts:`n - ' + ($Conflicts -join "`n - ")) }
  $Snapshots=New-Object 'Collections.Generic.List[object]'
  try {
    foreach($Item in @($State.managedFiles)) {
      $Relative=[string]$Item.path;$Path=Join-UnderRoot $Root $Relative
      if (Test-Path -LiteralPath $Path -PathType Leaf) { Save-Original $Snapshots $Path;if((Get-FileSha256 $Path)-cne[string]$Item.sha256){Backup-ModifiedPath $Root $Relative};Remove-Item -LiteralPath $Path -Force }
    }
    foreach($Item in @($State.managedBlocks)) {
      $Relative=[string]$Item.path;$Path=Join-UnderRoot $Root $Relative
      if (Test-Path -LiteralPath $Path -PathType Leaf) { Save-Original $Snapshots $Path;$Info=Get-BlockInfo $Path ([string]$Item.begin) ([string]$Item.end);if($Info.Status -eq 'present' -and $Info.Hash -cne[string]$Item.sha256){Backup-ModifiedPath $Root $Relative};Remove-ManagedBlock $Path ([string]$Item.begin) ([string]$Item.end) }
    }
    $StateFile=Join-UnderRoot $Root $Script:StatePath
    Save-Original $Snapshots $StateFile
    Remove-Item -LiteralPath $StateFile -Force
  } catch { Restore-Snapshots $Snapshots; throw }
}
