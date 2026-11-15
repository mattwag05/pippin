# Workflow bindings

Follow the core loop at `~/.agents/core/LOOP.md` when available. Contributor-specific server addresses belong in local instructions. Otherwise follow this repository's contribution, verification, and publication rules.

- Default branch: `main`. Fetch and verify its ref before creating a worktree; preserve the current branch and existing worktrees.
- Canonical remote: `origin`. Confirm its configured URL before publication; do not push a mirror.
- Issue tracker: Beads. Read `docs/agents/issue-tracker.md`.
- Verification: make ci; make e2e for changed Apple-app behavior, subject to the existing signing and TCC requirements in CLAUDE.md.
- Durable documentation: README.md; CHANGELOG.md; docs/gotchas/

Read the core skill the task needs (`~/.agents/skills/<name>/SKILL.md`). Apply `unslop` to authored prose and use `closeout` to finish. Preserve existing secret checks. Missing tools or unavailable verification are open gates, not successful checks.

Background coding remains opt-in. These bindings alone do not enable it or authorize pushes, PR changes, merges, or deployments. Follow the current user's publication authority. Historical specs under directories named for older skills retain their design evidence; they do not select the current workflow.
