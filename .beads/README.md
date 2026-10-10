# Native Beads tracker

Project issues use Dolt `main` in `refs/dolt/data` on this project's canonical Git origin. Code branches do not select issue branches. Normal Git worktrees share the main checkout's embedded database; independent clones have independent replicas.

The October 10, 2026 adoption baseline is 189 issues, schema 66, project UUID `2946aef3-8983-4259-bd2b-635d525433c2`. Later issue counts may change. Beads 1.3.1 and standalone Dolt 2.4.2 qualified this setup. Keep auto-push disabled.

For a new clone, check `git ls-remote origin refs/dolt/data`, then run `bd bootstrap --non-interactive`. Verify `bd where`, the project UUID, native remote and canonical records before claiming work. An absent ref or empty fallback is not a successful adoption. Preserve the project's existing Git hooks.

Obtain an acknowledged publishing turn across the actual writers, sync before selecting or claiming work, inspect conflicts, sync updates, verify the remote, then hand off. Keep the turn while recovering from failure. This is cooperative serialization; it does not provide a distributed lock or atomic cross-machine claims. Backups provide recovery separately.

## Existing private replicas

This public lineage was built from a separately sanitized current snapshot. Its IDs and relationships are preserved; its older private native history belongs only in private backups. Stop writes, archive the entire old tracker outside the checkout, obtain the canonical bootstrap files, and rebootstrap the new public lineage before resuming. Verify the UUID and records. Never sync, merge, import or push an old private database/export into this public lineage. A UUID check does not prevent a deliberate old-history push.
