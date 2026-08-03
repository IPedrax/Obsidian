---
name: obsidian-memory
description: "Upgrade Claude's persistent memory into an Obsidian vault that Claude creates and manages, and that the user can open and read. Memory becomes browsable, linkable and queryable, and is shared across every chat and project instead of siloed per-project. Windows only (uses NTFS directory junctions). Use when the user asks to save memory to Obsidian, wants memory that persists across chats/projects/sessions, wants to see or query what Claude remembers, says memory is scattered or siloed, asks to remember something globally rather than for one project, or asks to repair/rebuild the memory index. Triggers: 'save memory to obsidian', 'memory vault', 'remember this everywhere', 'persistent memory across projects', 'what do you remember', 'rebuild memory index'."
---

# obsidian-memory

An upgrade to Claude's built-in memory, not a replacement. The built-in system already writes Obsidian-shaped markdown — YAML frontmatter, one fact per file, `[[wikilinks]]`, a `MEMORY.md` index. It just hides it in `~/.claude/projects/<slug>/memory/`, one silo per project, where nothing but Claude can read it.

This skill **creates one Obsidian vault inside Claude's own directory** and points every project's memory dir at it with an NTFS **directory junction**. Normal memory writes then land in the vault. Nothing syncs at runtime and nothing can drift.

```
~/.claude/memory-vault/            <- a real Obsidian vault, registered in Obsidian
  .obsidian/                       <- config; stays outside the junction
  README.md
  Memory/                          <- the pool; every project junctions here
    MEMORY.md                      <- index, grouped by project
    Memory.base                    <- queryable views
    *.md                           <- one fact per file

~/.claude/projects/D--Foo/memory  ──┐
~/.claude/projects/D--Bar/memory  ──┴──> ~/.claude/memory-vault/Memory/
```

Every project's `memory/` resolves to the same folder, so every project loads the same `MEMORY.md`. Cross-project memory falls out of the junction — no MCP server, no sync process.

**Windows only.** Junctions are NTFS. A macOS/Linux port needs `ln -s` and a shell rewrite; not done.

## Setup

One command. No arguments, no vault to pick, nothing to create by hand.

```powershell
& "$S\memory-vault.ps1" setup
```

It creates the vault, registers it in Obsidian's vault switcher, copies every existing per-project memory into the pool, junctions the projects, installs a SessionStart hook so new projects join automatically, and writes the memory rules into `~/.claude/CLAUDE.md`. Then the user opens `~/.claude/memory-vault` in Obsidian — after restarting Obsidian, it is in the vault list.

`-NoLink` sets up without junctioning. `-NoHook` skips the hook. `-NoRules` skips the CLAUDE.md block. `-Vault <path>` uses an existing vault instead of creating one.

## Why the rules go in CLAUDE.md

A skill only loads when it triggers. If Claude saves a memory in a session where this skill never fired, the file has no `project:` and lands as `unscoped` — the shared pool then cannot tell what applies where. `CLAUDE.md` is loaded every session, so anything that must **always** hold belongs there, not only here.

`rules` writes that block between `<!-- obsidian-memory:begin -->` / `<!-- obsidian-memory:end -->` markers. It is idempotent — re-running replaces the block rather than duplicating it — and preserves everything else in the file. `rules -Remove` strips it and leaves the rest byte-for-byte.

## Auto-management

The SessionStart hook runs `autolink`, which adopts and junctions **the current project only**, then exits. It is quiet, wrapped in a catch so it can never break a session, and does nothing once a project is linked.

`unlink -Project <slug>` removes a junction **and records the choice**, so the hook will not relink it next session. `hook -Remove` uninstalls the hook and its launcher.

The hook points at a stable launcher in `~/.claude/obsidian-memory/`, not at the versioned plugin path, so plugin updates do not break it.

## Rules for writing memory

Same format as the built-in memory system, plus one required field.

```markdown
---
name: <short-kebab-case-slug>
description: <one line — shows in the index and the Base>
type: user | feedback | project | reference
project: global | <ProjectName>
---

<the fact. for feedback/project, follow with **Why:** and **How to apply:** lines.>
Link related memories with [[their-name]].
```

- Keep `type:` **flat**, not nested under `metadata:`. Bases can only filter flat properties.
- **`project:` decides reach.** `global` applies everywhere — who the user is, standing preferences, how they want you to work. A project name applies only there.
- Default to the project name. Promote to `global` only when genuinely portable; in a shared pool a wrongly-global memory misfires in every other project.
- **Read `project:` before acting on a recalled memory.** Memories from other projects will surface. If `project:` is neither `global` nor the current project, it is context, not instruction.
- After editing files by hand, rebuild: `& "$S\memory-vault.ps1" index`

## Querying

| Want | Do |
|---|---|
| Browse | `Memory/MEMORY.md`, grouped by project |
| Filter and sort | `Memory/Memory.base` — All, Global, feedback, unscoped |
| Full text | Obsidian search |
| What links to what | Backlinks pane and local graph |

## Repair

`index` rebuilds `MEMORY.md` from the frontmatter actually on disk, so it cannot lie about what exists. Run after manual edits.

## Undo

Junctions are not copies — deleting one never touches the pool.

```powershell
& "$S\memory-vault.ps1" unlink -Project D--Foo   # one project, and stop auto-linking it
& "$S\memory-vault.ps1" hook -Remove             # stop auto-linking entirely
```

Pre-link directories are kept in `~/.claude/memory-backups/`.

## Limits

- **One shared pool.** Every project loads the whole index. Fine at dozens; past a few hundred, consider junctioning to `Memory/Projects/<name>` — the `project:` field already carries that split.
- **Depends on an undocumented path.** `~/.claude/projects/<slug>/memory/` is Claude Code's layout, not a public contract. If it changes, junctions silently stop routing. `status` asserts it and warns; check after a Claude Code update.
- **The hook adds a subprocess per session start.** Small, but it is a footprint in `settings.json`. `hook -Remove` reverses it.
- Junctions are machine-local. Re-run `link -All` after moving machines.
