# obsidian-memory

An upgrade to Claude Code's persistent memory: Claude creates and manages an Obsidian vault, and you can open it and read everything it remembers.

**No sync. No export. No MCP server. No background process.**

## The idea

Claude Code already writes memory as Obsidian-shaped markdown — YAML frontmatter, one fact per file, `[[wikilinks]]`, a `MEMORY.md` index. It just hides it in `~/.claude/projects/<slug>/memory/`, a separate folder per project, where nothing but Claude can read it.

This plugin creates one vault in Claude's own directory and points every project's memory folder at it with an **NTFS directory junction**:

```
~/.claude/memory-vault/            <- a real Obsidian vault, registered in Obsidian
  .obsidian/                       <- config; stays outside the junction
  README.md
  Memory/                          <- the pool
    MEMORY.md                      <- index, grouped by project
    Memory.base                    <- queryable views
    *.md                           <- one fact per file

~/.claude/projects/D--Foo/memory  ──┐
~/.claude/projects/D--Bar/memory  ──┴──> ~/.claude/memory-vault/Memory/
```

A junction is a redirect at the filesystem layer. When anything opens `...\D--Foo\memory\x.md`, the OS serves `...\memory-vault\Memory\x.md`. Claude never knows, and no code path changes.

Point every project at the same target and they share one pool and one index — so **memory persists across chats and across projects** as a side effect of the redirect, not as a feature anyone had to build.

## Requirements

- **Windows.** Junctions are NTFS. A macOS/Linux port needs `ln -s` and a shell rewrite — not done.
- Windows PowerShell 5.1 (ships with Windows). No admin rights: directory junctions do not require elevation.
- Obsidian, with [Bases](https://obsidian.md/help/bases) for the prebuilt query views.

## Install

```
/plugin marketplace add IPedrax/Obsidian
/plugin install obsidian-memory
```

Or drop `skills/obsidian-memory/` into `~/.claude/skills/` as a personal skill.

## Setup

One command, no arguments:

```powershell
& "$S\memory-vault.ps1" setup
```

It creates the vault, registers it in Obsidian's vault switcher, copies existing per-project memories into the pool, junctions the projects, installs a SessionStart hook so new projects join automatically, and writes the memory rules into `~/.claude/CLAUDE.md`.

Then restart Obsidian and open **`memory-vault`** from the vault list.

Flags: `-NoLink` (set up without junctioning), `-NoHook` (skip the hook), `-NoRules` (skip the CLAUDE.md block), `-Vault <path>` (use an existing vault instead of creating one), `-DryRun` on `adopt`/`link`.

### Why the rules go in CLAUDE.md

A skill only loads when it triggers. If Claude saves a memory in a session where this skill never fired, the file has no `project:` and lands as `unscoped` — and a shared pool that cannot tell what applies where stops being trustworthy. `CLAUDE.md` loads every session, so the non-negotiable part of the contract lives there.

The block is delimited by `<!-- obsidian-memory:begin -->` / `<!-- obsidian-memory:end -->`. Writing it is idempotent — re-running replaces the block instead of duplicating it — and everything else in your `CLAUDE.md` is preserved. `rules -Remove` strips it and leaves the rest byte-for-byte.

## Commands

| Command | What it does |
|---|---|
| `setup` | Everything below, in order. The only command most people need |
| `status` | Vault, pool size, hook state, what is linked vs still local |
| `init` | Create + register the vault only |
| `adopt -All` | Copy existing per-project memories into the pool, stamping `project:` |
| `link -All` | Back up each `memory/` dir, replace it with a junction |
| `autolink` | Adopt + link the current project only. What the hook runs |
| `hook` / `hook -Remove` | Install or uninstall the SessionStart hook |
| `rules` / `rules -Remove` | Write the always-on memory rules into `~/.claude/CLAUDE.md` |
| `index` | Rebuild `MEMORY.md` from the frontmatter actually on disk |
| `unlink -Project <slug>` | Remove one junction and stop auto-linking it |

## Safety

The destructive step is guarded by the additive one:

- `link` **refuses** any project whose files are not already in the pool. Running steps out of order cannot lose data.
- `link` moves the original directory to `~/.claude/memory-backups/` before junctioning.
- `adopt` is idempotent — running it twice adopts nothing the second time.
- Filename collisions across projects are renamed `Project__file.md`, never overwritten.
- A file with no frontmatter gets one synthesized rather than being skipped.
- `unlink` deletes the junction, not its target, and records the choice so the hook will not undo it.
- Registering the vault **merges** into Obsidian's vault list and never sets `open: true`, so it cannot hijack which vault opens or drop vaults you already had.
- Installing the hook **merges** into `settings.json` and preserves every existing key.

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

`project` decides reach. `global` applies everywhere; a project name applies only there. Since the pool is shared, memories from other projects surface — the skill instructs Claude to check `project:` and treat non-matching ones as context, not instruction. That is a prompt-level guardrail, not isolation. For hard separation, junction each project to `Memory/Projects/<name>` instead; the `project:` field already carries what that split needs.

## Known limits

- **One shared pool.** Every project loads the whole index. Fine at dozens of memories; reconsider past a few hundred.
- **Depends on an undocumented path.** `~/.claude/projects/<slug>/memory/` is Claude Code's internal layout, not a public contract. If it changes, junctions silently stop routing and memory quietly goes back to being siloed. `status` asserts the path and warns loudly — check after a Claude Code update.
- **The hook costs a subprocess per session start** and a footprint in `settings.json`. `hook -Remove` reverses it.
- Junctions are machine-local. Re-run `link -All` after moving to a new machine.

## Config

Vault path and the auto-link exclusion list live at `~/.claude/obsidian-memory.json`, deliberately **outside** the plugin directory so an update cannot wipe them and no local path is ever committed. A pre-1.0 `vault-path.txt` inside the skill folder is migrated automatically and deleted.

The hook points at a stable launcher in `~/.claude/obsidian-memory/`, not the versioned plugin path, so plugin updates do not break it.

## License

MIT
---

Built by [Pedro Medeiros](https://ipedrax.com.br). I build production LLM applications for companies too: multi-provider backends, the infrastructure under them, and the billing on top. Available for contract work, remote from Brazil on US hours. [pedro.medeiros@ipedrax.com.br](mailto:pedro.medeiros@ipedrax.com.br)
