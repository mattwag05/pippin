# Head-to-head harness

Reproduces the comparison published in [docs/competitive/results.md](../../docs/competitive/results.md). The rules it follows are in [docs/competitive/methodology.md](../../docs/competitive/methodology.md), and the tools and pinned versions are in [docs/competitive/field.md](../../docs/competitive/field.md) and `tools.lock.json`.

**Run it only inside a disposable macOS virtual machine.** It downloads and runs third-party code, seeds Apple apps with fixture data and replaces the Messages database with a synthetic one. `run.sh`, `fixtures/seed.sh` and `harness/checks.py` refuse to run when `kern.hv_vmm_present` is not 1.

## One command

Inside the VM, from a checkout of this repository:

```bash
bench/competitive/run.sh
```

It installs the pinned tools into `~/bench-tools`, builds Pippin from the checkout (set `PIPPIN_BIN` to test another binary), seeds and verifies the fixture, runs every stage, restores the fixture and writes `bench/competitive/results/<date>/` with one raw JSON file per tool and stage plus `summary.md`.

## The VM

The published results used [Tart](https://tart.run) with the Cirrus Labs `macos-tahoe-xcode` image (macOS 26.6.2, Xcode, Homebrew, System Integrity Protection off), reached over ssh.

```bash
tart clone ghcr.io/cirruslabs/macos-tahoe-xcode:latest pippin-bench
tart run --no-graphics pippin-bench
```

Needed in the VM: git, curl, node 20 or later, python3 3.13 or later, Swift 6. The image has them.

Privacy permissions are the one part that is specific to a VM with System Integrity Protection off: `vm/grant.sh` and `vm/grant_ae.sh` write the Calendar, Reminders, Contacts and Automation grants for a binary straight into the user's TCC database, and `vm/allow.sh` clicks "Allow" on first-run consent dialogs. Competitor tools started from an ssh session run under the ssh session's own grants. Never run these three scripts on a real Mac.

## Layout

| Path | Purpose |
| --- | --- |
| `run.sh` | The one command. |
| `install.sh`, `tools.lock.json` | Installs every tool at its pin, with checksums where the project publishes them. |
| `adapters/` | One thin module per tool: how to launch it, which call each canonical operation maps to, how to parse the reply. `OPS.md` defines the canonical operations. |
| `ops_args.json` | The arguments every tool gets. |
| `fixtures/` | Ground truth (`manifest.json`), seeding, teardown and an independent verifier. See its README. |
| `harness/run.py` | Manifest size, cold and warm latency, concurrency, bad-input probes, coverage. |
| `harness/checks.py` | Correctness against the manifest, hostile-input safety, create/read-back/delete probes. |
| `harness/proxy.py`, `harness/tasks.py` | Agent task runs behind the tripwire proxy. Needs an agent CLI on the machine that drives the VM. |
| `harness/report.py` | Turns a results directory into the tables. Arithmetic only. |
| `results/` | Raw results as committed. |

## What cannot be reproduced in the VM

- Mail: the VM has no mail account, so every tool is "not run" for Mail.
- Voice Memos: the VM has no recordings store, so every tool is "not run" for it.
- A tool that needs an interactive approval window per client (iMCP) is "not run".

## Agent task runs

From the machine that hosts the VM, with an ssh config that names the VM `bench`:

```bash
python3 bench/competitive/harness/tasks.py --ssh-config <ssh-config> --out bench/competitive/results/<date>/tasks
```
