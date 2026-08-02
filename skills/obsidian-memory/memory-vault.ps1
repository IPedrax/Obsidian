<#
  obsidian-memory plumbing.  Windows only.  v1.1.0

  An upgrade to Claude Code's built-in memory, not a replacement. The built-in
  system already writes Obsidian-shaped markdown (YAML frontmatter, one fact
  per file, [[wikilinks]], a MEMORY.md index) -- it just hides it in a separate
  folder per project where only Claude can read it.

  This creates ONE Obsidian vault inside Claude's own directory and points
  every project's memory dir at it with an NTFS directory junction. Normal
  memory writes then land in the vault. Nothing syncs, nothing can drift.

  ponytail: junctions, not a sync daemon. Upgrade path if per-project
  isolation is ever wanted: junction each project to Memory/Projects/<name>
  instead of the shared pool. The `project:` frontmatter already carries it.

  Usage:
    .\memory-vault.ps1 setup                 # zero-config: everything, one command
    .\memory-vault.ps1 status
    .\memory-vault.ps1 init    [-Vault <path>]
    .\memory-vault.ps1 adopt   [-Project D--Foo] [-All] [-DryRun]
    .\memory-vault.ps1 link    [-Project D--Foo] [-All] [-DryRun]
    .\memory-vault.ps1 autolink              # current project only; used by the hook
    .\memory-vault.ps1 hook    [-Remove]
    .\memory-vault.ps1 index
    .\memory-vault.ps1 unlink  -Project D--Foo
#>

[CmdletBinding()]
param(
  [Parameter(Position = 0)]
  [ValidateSet('setup','status','init','adopt','link','autolink','hook','index','unlink')]
  [string]$Command = 'status',

  [string]$Vault,
  [string]$Project,
  [switch]$All,
  [switch]$DryRun,
  [switch]$NoLink,
  [switch]$NoHook,
  [switch]$Remove,
  [switch]$Quiet
)

$ErrorActionPreference = 'Stop'

$ClaudeRoot   = Join-Path $env:USERPROFILE '.claude'
$ProjectsRoot = Join-Path $ClaudeRoot 'projects'
$BackupRoot   = Join-Path $ClaudeRoot 'memory-backups'
$SettingsPath = Join-Path $ClaudeRoot 'settings.json'
$LauncherDir  = Join-Path $ClaudeRoot 'obsidian-memory'

# The vault lives in Claude's own directory: this is a memory upgrade, not a
# second notes app. The user opens it in Obsidian; Claude manages the contents.
$DefaultVault = Join-Path $ClaudeRoot 'memory-vault'

# Config lives OUTSIDE the plugin dir on purpose: a plugin update replaces the
# plugin folder, and a committed config would leak a local path (and username).
$ConfigPath   = Join-Path $ClaudeRoot 'obsidian-memory.json'
$LegacyConfig = Join-Path $PSScriptRoot 'vault-path.txt'

$ObsidianReg  = Join-Path $env:APPDATA 'obsidian\obsidian.json'

$Utf8NoBom = New-Object System.Text.UTF8Encoding $false
function Write-Utf8($Path, $Content) {
  [System.IO.File]::WriteAllText($Path, $Content, $Utf8NoBom)
}
function Say($Msg) { if (-not $Quiet) { Write-Host $Msg } }

# Keep this source file pure ASCII. PowerShell 5.1 decodes .ps1 as ANSI unless
# there is a BOM, and a literal em dash then lands as U+201D -- which PS treats
# as a string delimiter, so the whole script fails to parse.
$Dash = [char]0x2014

# The one external assumption. Claude Code's on-disk layout is not a public
# contract; if it moves, junctioning silently stops routing and memory quietly
# goes back to being siloed. Fail loud rather than fail invisibly.
function Assert-Layout {
  if (Test-Path $ProjectsRoot) { return $true }
  Write-Warning "Claude project root not found: $ProjectsRoot"
  Write-Warning "obsidian-memory junctions <projects>\<slug>\memory and cannot work without it."
  Write-Warning "Claude Code may have changed its layout. Check for an update to this skill."
  return $false
}

# ------------------------------------------------------------- config

function Read-Config {
  if (Test-Path $ConfigPath) { return (Get-Content $ConfigPath -Raw | ConvertFrom-Json) }
  if (Test-Path $LegacyConfig) {
    $v = (Get-Content $LegacyConfig -Raw).Trim()
    $cfg = [pscustomobject]@{ vaultPath = $v; exclude = @() }
    Write-Utf8 $ConfigPath (ConvertTo-Json $cfg -Depth 4)
    Remove-Item $LegacyConfig -Force
    Say "Migrated vault config out of the plugin dir -> $ConfigPath"
    return $cfg
  }
  return $null
}

function Save-Config($Cfg) { Write-Utf8 $ConfigPath (ConvertTo-Json $Cfg -Depth 4) }

function Get-VaultPath {
  if ($Vault) { return $Vault }
  $cfg = Read-Config
  if ($cfg -and $cfg.vaultPath) { return $cfg.vaultPath }
  throw "Not set up yet. Run: memory-vault.ps1 setup"
}

function Get-Pool {
  $v = Get-VaultPath
  if (-not (Test-Path $v)) { throw "Vault path does not exist: $v" }
  Join-Path $v 'Memory'
}

function Get-Excluded {
  $cfg = Read-Config
  if ($cfg -and $cfg.exclude) { return @($cfg.exclude) }
  return @()
}

# Mirrors how Claude Code slugs a working directory into a project folder name:
# every non-alphanumeric character becomes a hyphen.  D:\Foo Bar -> D--Foo-Bar
function Get-SlugForPath($Path) { return ($Path -replace '[^A-Za-z0-9]', '-') }

function Test-IsJunction($Path) {
  if (-not (Test-Path $Path)) { return $false }
  $item = Get-Item $Path -Force
  return ($item.LinkType -eq 'Junction' -or $item.LinkType -eq 'SymbolicLink')
}

function Get-Frontmatter($Path) {
  $raw = [System.IO.File]::ReadAllText($Path)
  $fm = @{ name = ''; description = ''; type = ''; project = '' }
  if ($raw -match '(?s)\A---\r?\n(.*?)\r?\n---') {
    foreach ($line in ($Matches[1] -split "`r?`n")) {
      if ($line -match '^\s*(name|description|type|project)\s*:\s*(.*?)\s*$') {
        $fm[$Matches[1]] = $Matches[2].Trim('"').Trim("'")
      }
    }
  }
  if ($fm.name -eq '')    { $fm.name = [System.IO.Path]::GetFileNameWithoutExtension($Path) }
  if ($fm.type -eq '')    { $fm.type = 'project' }
  if ($fm.project -eq '') { $fm.project = 'unscoped' }
  return $fm
}

function Set-ProjectField($Path, $ProjectName) {
  $raw = [System.IO.File]::ReadAllText($Path)
  if ($raw -match '(?m)^\s*project\s*:') { return $false }
  if ($raw -match '(?s)\A(---\r?\n)(.*?)(\r?\n---)') {
    $new = $Matches[1] + $Matches[2] + "`nproject: $ProjectName" + $Matches[3] +
           $raw.Substring($Matches[0].Length)
  } else {
    $new = "---`nname: " + [System.IO.Path]::GetFileNameWithoutExtension($Path) +
           "`ntype: project`nproject: $ProjectName`n---`n`n" + $raw
  }
  if (-not $DryRun) { Write-Utf8 $Path $new }
  return $true
}

function Get-ProjectDirs {
  if ($Project) {
    $d = Join-Path $ProjectsRoot $Project
    if (-not (Test-Path $d)) { throw "No such project: $Project" }
    return @(Get-Item $d)
  }
  if ($All) { return @(Get-ChildItem $ProjectsRoot -Directory) }
  throw "Specify -Project <slug> or -All"
}

# ------------------------------------------- Obsidian vault registration

# Obsidian keeps its vault list in %APPDATA%\obsidian\obsidian.json. Adding an
# entry there is what makes the vault appear in Obsidian's vault switcher
# instead of the user having to browse for a folder.
function Register-WithObsidian($VaultPath) {
  if (-not (Test-Path $ObsidianReg)) {
    Say "  ! Obsidian config not found -- open the vault manually once: $VaultPath"
    return
  }
  $reg = Get-Content $ObsidianReg -Raw | ConvertFrom-Json
  if (-not $reg.vaults) { Add-Member -InputObject $reg -NotePropertyName vaults -NotePropertyValue ([pscustomobject]@{}) -Force }

  foreach ($p in $reg.vaults.PSObject.Properties) {
    if ($p.Value.path -eq $VaultPath) { Say "  = already registered with Obsidian"; return }
  }

  # 16 hex chars, same shape as Obsidian's own ids.
  $id = -join ((1..16) | ForEach-Object { '0123456789abcdef'[(Get-Random -Maximum 16)] })
  $ts = [long][math]::Floor((New-TimeSpan -Start (Get-Date '1970-01-01Z').ToUniversalTime() -End (Get-Date).ToUniversalTime()).TotalMilliseconds)

  # No "open": true -- registering must not hijack which vault Obsidian opens.
  Add-Member -InputObject $reg.vaults -NotePropertyName $id `
             -NotePropertyValue ([pscustomobject]@{ path = $VaultPath; ts = $ts }) -Force
  Write-Utf8 $ObsidianReg (ConvertTo-Json $reg -Depth 6 -Compress)
  Say "  registered with Obsidian (restart Obsidian to see it in the vault switcher)"
}

# ---------------------------------------------------------------- init

function New-VaultSkeleton($VaultPath) {
  foreach ($d in @($VaultPath, (Join-Path $VaultPath '.obsidian'), (Join-Path $VaultPath 'Memory'))) {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
  }

  $appJson = Join-Path $VaultPath '.obsidian\app.json'
  if (-not (Test-Path $appJson)) {
    Write-Utf8 $appJson '{"alwaysUpdateLinks":true,"newLinkFormat":"shortest","useMarkdownLinks":false,"readableLineLength":true}'
  }
  $graphJson = Join-Path $VaultPath '.obsidian\graph.json'
  if (-not (Test-Path $graphJson)) {
    Write-Utf8 $graphJson '{"showTags":true,"showOrphans":true,"colorGroups":[{"query":"[\"type\":\"feedback\"]","color":{"a":1,"rgb":14701138}},{"query":"[\"project\":\"global\"]","color":{"a":1,"rgb":5025616}}],"showArrow":true,"nodeSizeMultiplier":1.3}'
  }

  $basePath = Join-Path $VaultPath 'Memory\Memory.base'
  if (-not (Test-Path $basePath)) {
    Write-Utf8 $basePath @'
filters:
  and:
    - '!file.name.contains("MEMORY")'

properties:
  note.type:
    displayName: Type
  note.project:
    displayName: Project
  note.description:
    displayName: What it says
  file.mtime:
    displayName: Saved

views:
  - type: table
    name: All memory
    groupBy:
      property: note.project
      direction: ASC
    order:
      - file.name
      - note.type
      - note.description
      - file.mtime
    sort:
      - property: file.mtime
        direction: DESC

  - type: table
    name: Global
    filters:
      and:
        - 'project == "global"'
    order:
      - file.name
      - note.type
      - note.description

  - type: table
    name: How to work (feedback)
    filters:
      and:
        - 'type == "feedback"'
    order:
      - file.name
      - note.project
      - note.description

  - type: table
    name: Unscoped - needs a project
    filters:
      and:
        - or:
            - 'project == "unscoped"'
            - 'project.isEmpty()'
    order:
      - file.name
      - note.type
      - note.description
'@
  }

  $readme = Join-Path $VaultPath 'README.md'
  if (-not (Test-Path $readme)) {
    Write-Utf8 $readme @"
# Claude's memory

This vault is managed by the ``obsidian-memory`` skill. Everything Claude
remembers across chats and projects lands in ``Memory/``.

- **``Memory/MEMORY.md``** $Dash the index, grouped by project. Start here.
- **``Memory/Memory.base``** $Dash sortable, filterable views of every memory.

Each file is one fact. ``project: global`` applies everywhere; anything else
applies only inside that project.

You can read and edit these freely $Dash they are plain markdown. After editing
by hand, ask Claude to rebuild the index so it matches what is on disk.
"@
  }
}

function Invoke-Init {
  if ($Vault) { $v = $Vault } else { $v = $DefaultVault }
  New-VaultSkeleton $v

  $cfg = Read-Config
  if (-not $cfg) { $cfg = [pscustomobject]@{ vaultPath = $v; exclude = @() } }
  else {
    if ($cfg.PSObject.Properties['vaultPath']) { $cfg.vaultPath = $v }
    else { Add-Member -InputObject $cfg -NotePropertyName vaultPath -NotePropertyValue $v -Force }
    if (-not $cfg.PSObject.Properties['exclude']) { Add-Member -InputObject $cfg -NotePropertyName exclude -NotePropertyValue @() -Force }
  }
  Save-Config $cfg

  Register-WithObsidian $v
  Say "Vault:  $v"
  Say "Pool:   $(Join-Path $v 'Memory')"
  Say "Config: $ConfigPath"
}

# --------------------------------------------------------------- setup

function Invoke-Setup {
  Say "== creating vault"
  Invoke-Init
  if (-not (Assert-Layout)) { return }

  Say "`n== adopting existing memories"
  $script:All = $true
  Invoke-Adopt

  if (-not $NoLink) {
    Say "`n== linking projects"
    Invoke-Link
  } else { Say "`n== skipped linking (-NoLink)" }

  if (-not $NoHook) {
    Say "`n== installing session hook"
    Invoke-Hook
  } else { Say "`n== skipped hook (-NoHook)" }

  $v = Get-VaultPath
  Say "`nDone. Open this vault in Obsidian:"
  Say "  $v"
  Say "Restart Obsidian to see it in the vault switcher."
}

# ------------------------------------------------------- adopt (copy in)

function Invoke-Adopt {
  if (-not (Assert-Layout)) { return }
  $pool = Get-Pool
  if (-not (Test-Path $pool)) { New-Item -ItemType Directory -Path $pool -Force | Out-Null }
  $copied = 0; $skipped = 0

  foreach ($dir in (Get-ProjectDirs)) {
    $mem = Join-Path $dir.FullName 'memory'
    if (-not (Test-Path $mem)) { continue }
    if (Test-IsJunction $mem) { continue }

    $files = @(Get-ChildItem $mem -File -Filter *.md | Where-Object { $_.Name -ne 'MEMORY.md' })
    if ($files.Count -eq 0) { continue }

    $short = $dir.Name -replace '^[A-Za-z]--', ''
    foreach ($f in $files) {
      $plain    = Join-Path $pool $f.Name
      $prefixed = Join-Path $pool ("{0}__{1}" -f $short, $f.Name)

      # Idempotency: if either candidate exists AND is stamped with this
      # project, it came from here on an earlier run. Skip, do not re-copy.
      $already = $false
      foreach ($cand in @($plain, $prefixed)) {
        if (Test-Path $cand) {
          if ((Get-Frontmatter $cand).project -eq $short) { $already = $true; break }
        }
      }
      if ($already) { $skipped++; continue }

      if (Test-Path $plain) { $dest = $prefixed } else { $dest = $plain }   # collision
      if (Test-Path $dest) { Say "  ! skip dup $($f.Name)"; $skipped++; continue }

      if ($DryRun) {
        Say "  + [dry] $short -> $(Split-Path $dest -Leaf)"
      } else {
        Copy-Item $f.FullName $dest
        Set-ProjectField $dest $short | Out-Null
        Say "  + $short -> $(Split-Path $dest -Leaf)"
      }
      $copied++
    }
  }
  Say "Adopted $copied file(s), skipped $skipped already-pooled."
  if (-not $DryRun) { Invoke-Index }
}

# --------------------------------------------------- link (junction swap)

function Invoke-Link {
  if (-not (Assert-Layout)) { return }
  $pool = Get-Pool
  if (-not (Test-Path $pool)) { throw "Pool missing. Run setup first." }
  $excluded = Get-Excluded

  foreach ($dir in (Get-ProjectDirs)) {
    $mem = Join-Path $dir.FullName 'memory'
    if (Test-IsJunction $mem) { continue }
    if ($excluded -contains $dir.Name) { Say "  - $($dir.Name) excluded"; continue }

    if (Test-Path $mem) {
      $live = @(Get-ChildItem $mem -File -Filter *.md | Where-Object { $_.Name -ne 'MEMORY.md' })
      $short = $dir.Name -replace '^[A-Za-z]--', ''
      # Refuse to destroy anything that was never copied into the pool.
      $unadopted = @($live | Where-Object {
        -not (Test-Path (Join-Path $pool $_.Name)) -and
        -not (Test-Path (Join-Path $pool ("{0}__{1}" -f $short, $_.Name)))
      })
      if ($unadopted.Count -gt 0) {
        Say "  ! $($dir.Name): $($unadopted.Count) file(s) not in pool -- run 'adopt' first. SKIPPED."
        continue
      }
      if ($DryRun) { Say "  ~ [dry] would back up + link $($dir.Name)"; continue }
      if (-not (Test-Path $BackupRoot)) { New-Item -ItemType Directory -Path $BackupRoot -Force | Out-Null }
      Move-Item $mem (Join-Path $BackupRoot ("{0}__{1}" -f $dir.Name, (Get-Random)))
    } elseif ($DryRun) {
      Say "  ~ [dry] would link $($dir.Name)"; continue
    }

    New-Item -ItemType Junction -Path $mem -Target $pool | Out-Null
    Say "  -> linked $($dir.Name)"
  }
}

# Current project only. Run by the SessionStart hook, so it must be quiet,
# fast, and must never throw into the user's session.
function Invoke-AutoLink {
  try {
    $cfg = Read-Config
    if (-not $cfg -or -not $cfg.vaultPath) { return }
    if (-not (Test-Path $ProjectsRoot)) { return }

    $slug = Get-SlugForPath (Get-Location).Path
    if ((Get-Excluded) -contains $slug) { return }

    $dir = Join-Path $ProjectsRoot $slug
    if (-not (Test-Path $dir)) { return }
    $mem = Join-Path $dir 'memory'
    if (Test-IsJunction $mem) { return }

    $script:Project = $slug
    $script:Quiet = $true
    Invoke-Adopt
    Invoke-Link
  } catch { }   # a hook must never break the session
}

function Invoke-Unlink {
  if (-not $Project) { throw "unlink requires -Project <slug>" }
  $mem = Join-Path (Join-Path $ProjectsRoot $Project) 'memory'
  if (Test-IsJunction $mem) {
    (Get-Item $mem -Force).Delete()          # removes the junction, not its target
    New-Item -ItemType Directory -Path $mem -Force | Out-Null
  }
  # Remember the choice, or the SessionStart hook would relink it next session.
  $cfg = Read-Config
  if ($cfg) {
    $ex = @(Get-Excluded)
    if ($ex -notcontains $Project) { $ex += $Project }
    if ($cfg.PSObject.Properties['exclude']) { $cfg.exclude = $ex }
    else { Add-Member -InputObject $cfg -NotePropertyName exclude -NotePropertyValue $ex -Force }
    Save-Config $cfg
  }
  Say "Unlinked $Project and excluded it from auto-linking. Pool untouched."
}

# ---------------------------------------------------------------- hook

function Invoke-Hook {
  # A launcher at a stable path, because the plugin cache path contains a
  # version number and would break the hook on every update. The launcher
  # resolves the newest installed copy at run time.
  if (-not (Test-Path $LauncherDir)) { New-Item -ItemType Directory -Path $LauncherDir -Force | Out-Null }
  $launcher = Join-Path $LauncherDir 'autolink.ps1'
  Write-Utf8 $launcher @'
# Resolves the newest installed obsidian-memory and auto-links the current
# project. Written by `memory-vault.ps1 hook`; safe to delete.
$ErrorActionPreference = 'SilentlyContinue'
$c = @()
$c += Get-ChildItem "$env:USERPROFILE\.claude\plugins\cache\obsidian-memory\obsidian-memory\*\skills\obsidian-memory\memory-vault.ps1" -ErrorAction SilentlyContinue |
        Sort-Object { [version]($_.Directory.Parent.Parent.Name) } -ErrorAction SilentlyContinue
$c += Get-Item "$env:USERPROFILE\.claude\skills\obsidian-memory\memory-vault.ps1" -ErrorAction SilentlyContinue
$s = $c | Select-Object -Last 1
if ($s) { & $s.FullName autolink -Quiet }
'@

  $cmd = 'powershell -NoProfile -ExecutionPolicy Bypass -File "' + $launcher + '"'

  if (Test-Path $SettingsPath) { $settings = Get-Content $SettingsPath -Raw | ConvertFrom-Json }
  else { $settings = [pscustomobject]@{} }
  if (-not $settings.PSObject.Properties['hooks']) {
    Add-Member -InputObject $settings -NotePropertyName hooks -NotePropertyValue ([pscustomobject]@{}) -Force
  }
  $existing = @()
  if ($settings.hooks.PSObject.Properties['SessionStart']) { $existing = @($settings.hooks.SessionStart) }

  # Drop any previous entry of ours, then re-add (or leave out, if -Remove).
  $kept = @($existing | Where-Object {
    $json = ($_ | ConvertTo-Json -Depth 6 -Compress)
    $json -notlike '*obsidian-memory*'
  })

  if ($Remove) {
    if ($kept.Count -gt 0) { $settings.hooks.SessionStart = $kept }
    elseif ($settings.hooks.PSObject.Properties['SessionStart']) { $settings.hooks.PSObject.Properties.Remove('SessionStart') }
    Write-Utf8 $SettingsPath (ConvertTo-Json $settings -Depth 10)
    Remove-Item $launcher -Force -ErrorAction SilentlyContinue
    Say "  hook removed from $SettingsPath"
    return
  }

  $entry = [pscustomobject]@{
    hooks = @( [pscustomobject]@{ type = 'command'; command = $cmd } )
  }
  $new = @($kept) + @($entry)
  if ($settings.hooks.PSObject.Properties['SessionStart']) { $settings.hooks.SessionStart = $new }
  else { Add-Member -InputObject $settings.hooks -NotePropertyName SessionStart -NotePropertyValue $new -Force }

  Write-Utf8 $SettingsPath (ConvertTo-Json $settings -Depth 10)
  Say "  hook installed in $SettingsPath"
  Say "  new projects will join the pool automatically at session start"
}

# ------------------------------------------------------------- index

function Invoke-Index {
  $pool = Get-Pool
  $files = @(Get-ChildItem $pool -File -Filter *.md | Where-Object { $_.Name -ne 'MEMORY.md' } | Sort-Object Name)

  $rows = foreach ($f in $files) {
    $fm = Get-Frontmatter $f.FullName
    [pscustomobject]@{ File = $f.Name; Name = $fm.name; Desc = $fm.description; Type = $fm.type; Proj = $fm.project }
  }

  $sb = New-Object System.Text.StringBuilder
  [void]$sb.AppendLine('# Memory Index')
  [void]$sb.AppendLine()
  [void]$sb.AppendLine("$($rows.Count) memories. Entries under **Global** apply everywhere; the rest apply only in their own project -- check the project before acting on one.")
  [void]$sb.AppendLine()

  $global = @($rows | Where-Object { $_.Proj -eq 'global' })
  if ($global.Count -gt 0) {
    [void]$sb.AppendLine('## Global')
    [void]$sb.AppendLine()
    foreach ($r in $global) { [void]$sb.AppendLine("- [$($r.Name)]($($r.File)) $Dash $($r.Desc)") }
    [void]$sb.AppendLine()
  }

  foreach ($g in ($rows | Where-Object { $_.Proj -ne 'global' } | Group-Object Proj | Sort-Object Name)) {
    [void]$sb.AppendLine("## $($g.Name)")
    [void]$sb.AppendLine()
    foreach ($r in ($g.Group | Sort-Object Name)) { [void]$sb.AppendLine("- [$($r.Name)]($($r.File)) $Dash $($r.Desc)") }
    [void]$sb.AppendLine()
  }

  Write-Utf8 (Join-Path $pool 'MEMORY.md') $sb.ToString()
  Say "Index rebuilt: $($rows.Count) memories across $(($rows | Group-Object Proj).Count) scope(s)."
}

# ------------------------------------------------------------- status

function Invoke-Status {
  $cfg = Read-Config
  if (-not $cfg -or -not $cfg.vaultPath) { Write-Host "Not set up yet. Run: memory-vault.ps1 setup"; return }
  $ok = Assert-Layout
  Write-Host "Vault:  $($cfg.vaultPath)"
  Write-Host "Config: $ConfigPath"
  $pool = Join-Path $cfg.vaultPath 'Memory'
  if (Test-Path $pool) {
    $n = @(Get-ChildItem $pool -File -Filter *.md | Where-Object { $_.Name -ne 'MEMORY.md' }).Count
    Write-Host "Pooled memories: $n"
  } else { Write-Host "Pool missing -- run setup." }

  $hookOn = $false
  if (Test-Path $SettingsPath) {
    $hookOn = ((Get-Content $SettingsPath -Raw) -like '*obsidian-memory*')
  }
  Write-Host ("Auto-link hook: " + $(if ($hookOn) { "on" } else { "off" }))
  if (-not $ok) { return }
  Write-Host ""

  $linked = 0; $loose = 0
  foreach ($dir in (Get-ChildItem $ProjectsRoot -Directory)) {
    $mem = Join-Path $dir.FullName 'memory'
    if (-not (Test-Path $mem)) { continue }
    if (Test-IsJunction $mem) { $linked++ }
    else {
      $loose++
      $cnt = @(Get-ChildItem $mem -File -Filter *.md -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'MEMORY.md' }).Count
      "{0,-42} local ({1} files)" -f $dir.Name, $cnt
    }
  }
  Write-Host ""
  Write-Host "$linked linked, $loose still local."
}

switch ($Command) {
  'setup'    { Invoke-Setup }
  'init'     { Invoke-Init }
  'adopt'    { Invoke-Adopt }
  'link'     { Invoke-Link }
  'autolink' { Invoke-AutoLink }
  'hook'     { Invoke-Hook }
  'index'    { Invoke-Index }
  'unlink'   { Invoke-Unlink }
  default    { Invoke-Status }
}
