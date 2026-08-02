# obsidian-memory

Claude Code's persistent memory, routed into an Obsidian vault — browsable, linkable, queryable, and shared across every chat and project instead of siloed one folder per project.

**No sync. No export. No MCP server. No background process.**

## The idea

Claude Code already writes memory as Obsidian-shaped markdown — YAML frontmatter, one fact per file, `[[wikilinks]]`, a `MEMORY.md` index. It just stores it at `~/.claude/projects/<slug>/memory/`, a separate folder per project, where nothing but Claude can read it.

This plugin replaces each of those folders with an **NTFS directory junction** pointing at one folder inside your vault:

```
~/.claude/projects/D--Portfolio/memory  ──┐
~/.claude/projects/D--OSINT/memory     ──┼──> <vault>/Memory/
~/.claude/projects/D--Council/memory   ──┘        MEMORY.md      index, grouped by project
                                                  Memory.base    queryable views
                                                  *.md           one fact per file
```

A junction is a redirect at the filesystem layer. When anything opens `...\D--Foo\memory\x.md`, the OS serves `<vault>\Memory\x.md`. Claude never knows, and no code path changes.

Point every project at the same target and they share one pool and one index — so **memory persists across chats and across projects** as a side effect of the redirect, not as a feature anyone had to build. No hook, no server, no daemon.

## Requirements

- **Windows.** Junctions are NTFS. A macOS/Linux port needs `ln -s` and a shell rewrite — not done.
- Windows PowerShell 5.1 (ships with Windows). No admin rights needed; directory junctions do not require elevation.
- Obsidian, with [Bases](https://obsidian.md/help/bases) enabled if you want the prebuilt query views.

## Install

```
/plugin marketplace add IPedrax/Obsidian
/plugin install obsidian-memory
```

Or drop `skills/obsidian-memory/` into `~/.claude/skills/` to use it as a personal skill.

## Setup

`$S` is the skill directory. Under a plugin install that is `~/.claude/plugins/cache/obsidian-memory/obsidian-memory/<version>/skills/obsidian-memory`.

```powershell
# 1. register your vault, create Memory/ and Memory.base
& "$S\memory-vault.ps1" init -Vault "C:\path\to\your\vault"

# 2. look before you leap
& "$S\memory-vault.ps1" status

# 3. copy existing memories into the pool (additive: nothing moved, nothing deleted)
& "$S\memory-vault.ps1" adopt -All -DryRun
& "$S\memory-vault.ps1" adopt -All

# 4. swap the directories for junctions (backs up first)
& "$S\memory-vault.ps1" link -All -DryRun
& "$S\memory-vault.ps1" link -All
```

Use `-Project D--Foo` instead of `-All` to scope to one project. New projects need `link -Project <slug>` once.

## Commands

| Command | What it does |
|---|---|
| `status` | What is linked, what is still local, how many memories are pooled |
| `init -Vault <path>` | Register the vault, create `Memory/` and `Memory.base` |
| `adopt -All` | Copy existing per-project memories into the pool, stamping `project:` |
| `link -All` | Back up each `memory/` dir, replace it with a junction |
| `index` | Rebuild `MEMORY.md` from the frontmatter actually on disk |
| `unlink -Project <slug>` | Remove one junction. Never touches the pool |

`-DryRun` works on `adopt` and `link`.

## Safety

The destructive step is guarded by the additive one:

- `link` **refuses** any project whose files are not already in the pool. Running the steps out of order cannot lose data.
- `link` moves the original directory to `~/.claude/memory-backups/` before creating the junction.
- `adopt` is idempotent — running it twice adopts nothing the second time.
- Filename collisions across projects are renamed `Project__file.md`, never overwritten.
- A file with no frontmatter gets one synthesized rather than being skipped.
- `unlink` deletes the junction, not its target. The pool is untouched.

## Memory format

The built-in format plus one required field:

```markdown
---
name: prefers-short-answers
description: Keep responses terse; lead with the answer
type: feedback
project: global
---

Keep responses short and lead with the conclusion.

**Why:** Long preambles bury the answer.
**How to apply:** Answer first, then justify only if asked.
```

`type` is one of `user`, `feedback`, `project`, `reference` — kept **flat**, because Obsidian Bases can only filter flat properties.

`project` decides reach. `global` applies everywhere; a project name applies only there. Since the pool is shared, memories from other projects will surface — the skill instructs Claude to check `project:` and treat non-matching ones as context rather than instruction. That is a prompt-level guardrail, not isolation. If you need hard separation, junction each project to `Memory/Projects/<name>` instead; the `project:` field already carries what that split needs.

## Querying

| Want | Do |
|---|---|
| Browse everything | `Memory/MEMORY.md`, grouped by project |
| Filter and sort | `Memory/Memory.base` — All, Global, feedback, unscoped |
| Full text | Obsidian search: `path:Memory "docker"` |
| What links to what | Open any memory note; backlinks pane and local graph |

## Known limits

- **One shared pool.** Every project loads the whole index. Fine at dozens of memories; reconsider past a few hundred.
- **Depends on an undocumented path.** `~/.claude/projects/<slug>/memory/` is Claude Code's internal layout, not a public contract. If it changes, junctions silently stop routing and memory quietly goes back to being siloed. `status` asserts the path and warns loudly — check it after a Claude Code update.
- Junctions are machine-local. Re-run `link -All` after moving to a new machine.
- Vault on cloud sync: a memory write racing a sync conflict can collide. Rare; `~/.claude/memory-backups/` is the recovery path.

## Config

Vault path lives at `~/.claude/obsidian-memory.json`, deliberately **outside** the plugin directory so a plugin update cannot wipe it and no local path is ever committed. A pre-1.0 `vault-path.txt` inside the skill folder is migrated automatically and deleted.

## License

MIT
