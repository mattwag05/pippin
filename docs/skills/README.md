# Skills (shipped, symlink locally)

Skills live here so they're version-controlled and reviewable. Claude Code discovers skills from `.claude/skills/`, which is gitignored — so each clone needs to symlink them into place once.

## One-time setup

```bash
make link-skills
```

(or manually: `mkdir -p .claude/skills && ln -sfn ../../docs/skills/release .claude/skills/release`)

## Available skills

| Skill | Trigger | Purpose |
|-------|---------|---------|
| [release](release/SKILL.md) | "release pippin", "ship vX.Y.Z", "bump pippin" | End-to-end release: bump version, tag, push, update Homebrew tap, verify. |

## Adding a new skill

1. Create `docs/skills/<name>/SKILL.md` with frontmatter (`name`, `description` — the description is what Claude uses to decide when to invoke).
2. Run `make link-skills` (or add a manual symlink line if the Makefile target needs extending).
3. Commit the skill directory; the symlink is local-only.
