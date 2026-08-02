<#
  obsidian-memory plumbing.  Windows only.  v1.0.0

  The built-in Claude memory system already writes Obsidian-shaped markdown
  (YAML frontmatter + [[wikilinks]] + a MEMORY.md index). This script does not
  copy or sync anything at runtime -- it points every project's memory dir at
  one folder inside an Obsidian vault using an NTFS directory junction, so
  normal memory writes land in the vault with zero new code path.

  ponytail: junctions, not a sync daemon. Nothing runs in the background,
  nothing can drift. Upgrade path if you ever need per-project isolation:
  junction each project to Memory/Projects/<name> instead of the shared pool.
  The `project:` frontmatter field already carries the scoping that needs.

  Usage:
    .\memory-vault.ps1 status
    .\memory-vault.ps1 init    -Vault "C:\path\to\vault"
    .\memory-vault.ps1 adopt   [-Project D--Foo] [-All] [-DryRun]
    .\memory-vault.ps1 link    [-Project D--Foo] [-All] [-DryRun]
    .\memory-vault.ps1 index
    .\memory-vault.ps1 unlink  -Project D--Foo
#>

[CmdletBinding()]
param(
  [Parameter(Position = 0)]
  [ValidateSet('status', 'init', 'adopt', 'link', 'index', 'unlink')]
  [string]$Command = 'status',

  [string]$Vault,
  [string]$Project,
  [switch]$All,
  [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

$ClaudeRoot   = Join-Path $env:USERPROFILE '.claude'
$ProjectsRoot = Join-Path $ClaudeRoot 'projects'
$BackupRoot   = Join-Path $ClaudeRoot 'memory-backups'

# Config lives OUTSIDE the plugin directory on purpose: a plugin update
# replaces this folder, and a committed vault-path.txt would leak the author's
# local path (it contains a username) into the repo.
$ConfigPath   = Join-Path $ClaudeRoot 'obsidian-memory.json'
$LegacyConfig = Join-Path $PSScriptRoot 'vault-path.txt'

$Utf8NoBom = New-Object System.Text.UTF8Encoding $false
function Write-Utf8($Path, $Content) {
  [System.IO.File]::WriteAllText($Path, $Content, $Utf8NoBom)
}

# Keep this source file pure ASCII. PowerShell 5.1 decodes .ps1 as ANSI unless
# there is a BOM, and a literal em dash then lands as U+201D -- which PS treats
# as a string delimiter, so the whole script fails to parse.
$Dash = [char]0x2014

# The one external assumption this skill makes. It is Claude Code's on-disk
# layout, not a public contract -- if it ever moves, junctioning silently stops
# routing anything and memory quietly goes back to being siloed. Fail loud.
function Assert-Layout {
  if (Test-Path $ProjectsRoot) { return $true }
  Write-Warning "Claude project root not found: $ProjectsRoot"
  Write-Warning "obsidian-memory junctions <projects>\<slug>\memory and cannot work without it."
  Write-Warning "Claude Code may have changed its on-disk layout. Check for an update to this skill."
  return $false
}

function Get-VaultPath {
  if ($Vault) { return $Vault }
  if (Test-Path $ConfigPath) {
    $cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Json
    if ($cfg.vaultPath) { return $cfg.vaultPath }
  }
  if (Test-Path $LegacyConfig) {
    $v = (Get-Content $LegacyConfig -Raw).Trim()
    Write-Utf8 $ConfigPath (ConvertTo-Json @{ vaultPath = $v })
    Remove-Item $LegacyConfig -Force
    Write-Host "Migrated vault config out of the plugin dir -> $ConfigPath"
    return $v
  }
  throw "No vault configured. Run: memory-vault.ps1 init -Vault '<path to vault>'"
}

function Get-Pool {
  $v = Get-VaultPath
  if (-not (Test-Path $v)) { throw "Vault path does not exist: $v" }
  Join-Path $v 'Memory'
}

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

# Stamp `project:` into frontmatter so a shared pool stays scopeable.
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

# ---------------------------------------------------------------- init

function Invoke-Init {
  if (-not $Vault) { throw "init requires -Vault '<path to vault>'" }
  if (-not (Test-Path $Vault)) { throw "Vault path does not exist: $Vault" }
  $pool = Join-Path $Vault 'Memory'
  if (-not (Test-Path $pool)) { New-Item -ItemType Directory -Path $pool -Force | Out-Null }
  Write-Utf8 $ConfigPath (ConvertTo-Json @{ vaultPath = $Vault })

  $basePath = Join-Path $pool 'Memory.base'
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
    Write-Host "  created Memory.base"
  }
  Write-Host "Vault registered: $Vault"
  Write-Host "Config:           $ConfigPath"
  Write-Host "Pool:             $pool"
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
    if (Test-IsJunction $mem) { Write-Host "  = $($dir.Name) already linked"; continue }

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
      if ($already) { Write-Host "  = already adopted $($f.Name)"; $skipped++; continue }

      if (Test-Path $plain) { $dest = $prefixed } else { $dest = $plain }   # collision
      if (Test-Path $dest) { Write-Host "  ! skip dup $($f.Name)"; $skipped++; continue }

      if ($DryRun) {
        Write-Host "  + [dry] $short -> $(Split-Path $dest -Leaf)"
      } else {
        Copy-Item $f.FullName $dest
        Set-ProjectField $dest $short | Out-Null
        Write-Host "  + $short -> $(Split-Path $dest -Leaf)"
      }
      $copied++
    }
  }
  Write-Host ""
  Write-Host "Adopted $copied file(s), skipped $skipped."
  if (-not $DryRun) { Invoke-Index }
}

# --------------------------------------------------- link (junction swap)

function Invoke-Link {
  if (-not (Assert-Layout)) { return }
  $pool = Get-Pool
  if (-not (Test-Path $pool)) { throw "Pool missing. Run init first." }

  foreach ($dir in (Get-ProjectDirs)) {
    $mem = Join-Path $dir.FullName 'memory'

    if (Test-IsJunction $mem) { Write-Host "  = $($dir.Name) already linked"; continue }

    if (Test-Path $mem) {
      $live = @(Get-ChildItem $mem -File -Filter *.md | Where-Object { $_.Name -ne 'MEMORY.md' })
      # Refuse to destroy anything that was never copied into the pool.
      $short = $dir.Name -replace '^[A-Za-z]--', ''
      $unadopted = @($live | Where-Object {
        -not (Test-Path (Join-Path $pool $_.Name)) -and
        -not (Test-Path (Join-Path $pool ("{0}__{1}" -f $short, $_.Name)))
      })
      if ($unadopted.Count -gt 0) {
        Write-Host "  ! $($dir.Name): $($unadopted.Count) file(s) not in pool -- run 'adopt' first. SKIPPED."
        continue
      }
      if ($DryRun) { Write-Host "  ~ [dry] would back up + link $($dir.Name)"; continue }
      if (-not (Test-Path $BackupRoot)) { New-Item -ItemType Directory -Path $BackupRoot -Force | Out-Null }
      $bak = Join-Path $BackupRoot ("{0}__{1}" -f $dir.Name, (Get-Random))
      Move-Item $mem $bak
      Write-Host "  ~ backed up to $bak"
    } elseif ($DryRun) {
      Write-Host "  ~ [dry] would link $($dir.Name) (no existing memory)"; continue
    }

    New-Item -ItemType Junction -Path $mem -Target $pool | Out-Null
    Write-Host "  -> linked $($dir.Name)"
  }
}

function Invoke-Unlink {
  if (-not $Project) { throw "unlink requires -Project <slug>" }
  $mem = Join-Path (Join-Path $ProjectsRoot $Project) 'memory'
  if (-not (Test-IsJunction $mem)) { throw "$Project is not linked." }
  (Get-Item $mem -Force).Delete()          # removes the junction, not its target
  New-Item -ItemType Directory -Path $mem -Force | Out-Null
  Write-Host "Unlinked $Project. Pool untouched; $Project now has an empty local memory dir."
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
  Write-Host "Index rebuilt: $($rows.Count) memories across $(($rows | Group-Object Proj).Count) scope(s)."
}

# ------------------------------------------------------------- status

function Invoke-Status {
  $ok = Assert-Layout
  try { $pool = Get-Pool } catch { Write-Host $_.Exception.Message; return }
  Write-Host "Pool:   $pool"
  Write-Host "Config: $ConfigPath"
  if (Test-Path $pool) {
    $n = @(Get-ChildItem $pool -File -Filter *.md | Where-Object { $_.Name -ne 'MEMORY.md' }).Count
    Write-Host "Memories in pool: $n"
  } else { Write-Host "Pool does not exist yet -- run init." }
  if (-not $ok) { return }
  Write-Host ""

  $linked = 0; $loose = 0
  foreach ($dir in (Get-ChildItem $ProjectsRoot -Directory)) {
    $mem = Join-Path $dir.FullName 'memory'
    if (-not (Test-Path $mem)) { continue }
    $cnt = @(Get-ChildItem $mem -File -Filter *.md -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'MEMORY.md' }).Count
    if (Test-IsJunction $mem) { $linked++; "{0,-42} LINKED" -f $dir.Name }
    else { $loose++; "{0,-42} local ({1} files)" -f $dir.Name, $cnt }
  }
  Write-Host ""
  Write-Host "$linked linked, $loose still local."
}

switch ($Command) {
  'init'   { Invoke-Init }
  'adopt'  { Invoke-Adopt }
  'link'   { Invoke-Link }
  'index'  { Invoke-Index }
  'unlink' { Invoke-Unlink }
  default  { Invoke-Status }
}
