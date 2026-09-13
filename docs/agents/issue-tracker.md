# Issue tracker

This project uses Beads as its custom tracker for Matt Pocock's skills. Do not create a second issue store.

- Inspect available work with `bd ready` and details with `bd show <id>`.
- Claim with `bd update <id> --claim`.
- Record discovered work with `bd create`; read `bd create --help` for supported fields.
- Close with `bd close <id>` only after acceptance.
- Read `bd prime` for the installed CLI's current commands. Dolt sync and Git publication follow the active user's authority separately.

Use existing labels for needs-triage, needs-info, ready-for-agent, ready-for-human, and wontfix when appropriate. These classification labels never grant the separate background workflow's publication approval.
