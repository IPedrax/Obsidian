---
name: obsidian-memory
description: "Route Claude's persistent memory into an Obsidian vault so it is browsable, linkable and queryable, and shared across every chat and project instead of siloed per-project. Windows only (uses NTFS directory junctions). Use when the user asks to save memory to Obsidian, wants memory that persists across chats/projects/sessions, wants to see or query what Claude remembers, says memory is scattered or siloed, asks to remember something globally rather than for one project, or asks to repair/rebuild the memory index. Triggers: 'save memory to obsidian', 'memory vault', 'remember this everywhere', 'persistent memory across projects', 'what do you remember', 'rebuild memory index'."
---

# obsidian-memory

Claude's built-in memory already writes Obsidian-shaped markdown: YAML frontmatter, one fact per file, `[[wikilinks]]`, a `MEMORY.md` index. The only problems are that it lives in `~/.claude/projects/<slug>/memory/`, one silo per project, and nothing can read it but Claude.

**This skill does not sync, export or copy anything at runtime.** It replaces each project's `memory/` directory with an NTFS **directory junction** pointing at one folder inside an Obsidian vault. Normal memory writes then land in the vault directly. There is no pipeline to run, nothing to schedule, and nothing that can drift.

Because every project's `memory/` resolves to the same folder, every project loads the same `MEMORY.md`. Cross-project persistent memory falls out of the junction for free — no hook, no MCP server, no plugin.

```
~/.claude/projects/D--Portfolio/memory  ──┐
~/.claude/projects/D--OSINT/memory     ──┼──> <vault>/Memory/
~/.claude/projects/D--Council/memory   ──┘        MEMORY.md      (index, grouped by project)
                                                  Memory.base    (queryable views)
                                                  *.md           (one fact per file)
```

**Windows only.** Junctions are NTFS. A macOS/Linux port needs `ln -s` and a shell rewrite; it is not done.

## Setup

`$S` below is this skill's directory. Vault path is stored once in `~/.claude/obsidian-memory.json` — outside the plugin, so an update cannot wipe it.

```powershell
# 1. register the vault and create Memory/ + Memory.base
& "$S\memory-vault.ps1" init -Vault "C:\path\to\vault"

# 2. see what exists before touching anything
& "$S\memory-vault.ps1" status

# 3. copy existing memories into the pool (additive; nothing is moved or deleted)
& "$S\memory-vault.ps1" adopt -All -DryRun
& "$S\memory-vault.ps1" adopt -All

# 4. swap the dirs for junctions (backs up to ~/.claude/memory-backups first)
& "$S\memory-vault.ps1" link -All -DryRun
& "$S\memory-vault.ps1" link -All
```

Scope to one project with `-Project D--Foo` instead of `-All`. New projects need `link -Project <slug>` once — until then they keep a local memory dir, which is harmless.

`adopt` stamps a `project:` field into any file missing one and is idempotent. `link` **refuses any project whose files are not already in the pool**, so running the steps out of order cannot lose data.

## Rules for writing memory once this is set up

Same format as the built-in memory system, plus one required field.

```markdown
---
name: <short-kebab-case-slug>
description: <one line — this is what shows in the index and the Base>
type: user | feedback | project | reference
project: global | <ProjectName>
---

<the fact. for feedback/project, follow with **Why:** and **How to apply:** lines.>
Link related memories with [[their-name]].
```

- Keep `type:` **flat**, not nested under `metadata:`. Obsidian Bases can only filter flat properties.
- **`project:` decides reach.** `global` applies everywhere — who the user is, standing preferences, how they want you to work generally. A project name applies only there.
- Default to the project name. Promote to `global` only when the fact is genuinely portable; in a shared pool a wrongly-global memory misfires in every other project.
- **Read `project:` before acting on a recalled memory.** The pool is shared, so memories from other projects will surface. If `project:` is neither `global` nor the one you are in, it is context, not instruction.
- After adding or deleting files by hand, rebuild the index: `& "$S\memory-vault.ps1" index`

## Querying

The vault is the query layer — that is the point of putting it there.

| Want | Do |
|---|---|
| Browse everything | Open `Memory/MEMORY.md`, grouped by project |
| Filter/sort structurally | Open `Memory/Memory.base` — views for All, Global, feedback, unscoped |
| Full text | Obsidian search: `path:Memory "docker"` |
| One type | `Memory.base` → *How to work (feedback)* |
| What links to what | Open any memory note; use backlinks and the local graph |

From Claude, just read the files — markdown at a known path.

## Repair

`MEMORY.md` drifts when files are added or renamed outside the normal flow. `index` rebuilds it from the frontmatter actually on disk, so it cannot lie. Run it after any manual edit and after `adopt`.

## Undo

Junctions are not copies — deleting one never touches the pool.

```powershell
& "$S\memory-vault.ps1" unlink -Project D--Foo
```

Pre-link directories are kept under `~/.claude/memory-backups/`. Delete once satisfied.

## Limits

- **One shared pool.** Every project sees every memory in the index. That is the feature, but the index grows across all work; past a few hundred entries, consider junctioning projects to `Memory/Projects/<name>` instead. The `project:` field already carries the scoping that split needs.
- **Depends on an undocumented path.** `~/.claude/projects/<slug>/memory/` is Claude Code's layout, not a public contract. If it changes, junctions silently stop routing. `status` asserts the path and warns loudly if it is gone — check it after a Claude Code update.
- Junctions are Windows-local and do not survive being copied to another machine. Re-run `link -All` after a migration.
- If the vault is on cloud sync, a memory write and a sync conflict can collide. Rare; `~/.claude/memory-backups/` is the recovery path.
