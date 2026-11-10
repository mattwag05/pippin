# Competitive field

Last verified: 2026-11-09. Committed together with [methodology.md](methodology.md), before any head-to-head result existed.

This is the set of open-source tools that let agents or scripts automate Apple's built-in apps on macOS, ranked by adoption. It was built by searching GitHub, npm, PyPI, Homebrew, the official MCP registry and Hacker News, not from a fixed list.

## Sources

- Stars, license, archive state, default-branch head commit and latest release: GitHub REST API (`repos/<owner>/<name>`, `/commits/<branch>`, `/releases/latest`), fetched 2026-11-09.
- npm downloads: `api.npmjs.org/downloads/point/last-month/<pkg>`, window 2026-10-10 to 2026-11-08.
- Release downloads: sum of `download_count` over all release assets from the GitHub REST API, fetched 2026-11-09. These totals include automated installs and are an upper bound on human use.
- PyPI downloads: pypistats.org, as returned on 2026-11-09 (not re-fetched in a second pass; marked "single fetch").
- App coverage: each project's README. This is the project's own claim until the harness probes it.
- Not available: Smithery, mcp.so, PulseMCP and Glama gave no usable counts (HTTP 403, 404 or no parseable listing). Reddit was not queried. Homebrew publishes no analytics for third-party taps.

## Seed candidates from the mission, verified

| Seed | Finding |
| --- | --- |
| supermemoryai/apple-mcp (was Dhravya/apple-mcp) | Exists. Archived. Last commit 2025-08-11. Excluded from the benchmarked set, kept in the table because it is still the most starred. |
| mattt/iMCP | Exists, active. Included. |
| steipete macOS tools | `steipete/macos-automator-mcp` is archived (last commit 2026-09-13). `imsg` and `Peekaboo` moved to the `openclaw` organization. `openclaw/imsg` is included. Peekaboo is screen and GUI control, not app data, so it is out of scope. |
| joshrutkowski/applescript-mcp | Exists, no commit since 2025-04-19, no releases. Excluded as unmaintained (more than 12 months). |
| Generic AppleScript MCP servers | `peakmojo/applescript-mcp` exists (467 stars, last commit 2026-02-22). It runs arbitrary AppleScript and has no app-level operations, so it is listed but not benchmarked per operation. |

## Ranked field

Sorted by stars. "Head" is the default-branch commit on 2026-11-09.

| # | Tool | Stars | License | Language | Last commit | Latest release | Head commit | Install signal | Apps (README claim) | Interface |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | [supermemoryai/apple-mcp](https://github.com/supermemoryai/apple-mcp) | 3112 | MIT | TypeScript | 2025-08-11 | 1.0.0 (2025-08-11) | `08e2c53` | npm `apple-mcp` 1,477 per month | Mail, Calendar, Contacts, Messages, Notes, Reminders | MCP. Archived |
| 2 | [mattt/iMCP](https://github.com/mattt/iMCP) | 1958 | MIT | Swift | 2026-11-05 | 1.8.3 (2026-11-04) | `c30e84c` | 55,168 release downloads | Mail, Calendar, Contacts, Messages, Notes, Reminders, Voice Memos | MCP through a GUI app |
| 3 | [openclaw/imsg](https://github.com/openclaw/imsg) | 1406 | MIT | Swift | 2026-11-05 | v0.21.0 (2026-11-05) | `1bc0679` | 424,354 release downloads | Messages | CLI |
| 4 | [keith/reminders-cli](https://github.com/keith/reminders-cli) | 930 | MIT | Swift | 2026-10-02 | 2.5.1 (2024-05-07) | `bdf0497` | 12,652 release downloads (single fetch) | Reminders | CLI |
| 5 | [steipete/macos-automator-mcp](https://github.com/steipete/macos-automator-mcp) | 882 | MIT | TypeScript | 2026-09-13 | v0.4.7 (2026-09-01) | `7f9074a` | npm 3,659 per month | Generic AppleScript and JXA | MCP. Archived |
| 6 | [viticci/remctl](https://github.com/viticci/remctl) | 654 | MIT | not re-verified | 2026-11-02 (single fetch) | not re-verified | not pinned | 1,144 release downloads (single fetch) | Reminders | CLI |
| 7 | [peakmojo/applescript-mcp](https://github.com/peakmojo/applescript-mcp) | 467 | MIT | Python | 2026-02-22 | none | `2efc108` | npm 654 per month (single fetch) | Generic AppleScript | MCP |
| 8 | [openclaw/remindctl](https://github.com/openclaw/remindctl) | 417 | MIT | Swift | 2026-11-05 | v0.3.9 (2026-10-21) | `b74c361` | 437,235 release downloads | Reminders | CLI |
| 9 | [joshrutkowski/applescript-mcp](https://github.com/joshrutkowski/applescript-mcp) | 396 | MIT | TypeScript | 2025-04-19 | none | `e6f4c2e` | none found | Calendar, Mail, Messages, Notes | MCP |
| 10 | [antoniorodr/memo](https://github.com/antoniorodr/memo) | 367 | Apache-2.0 | Python | 2026-10-28 | v0.6.2 (2026-10-21) | `1cf73cd` | 473,814 release downloads | Notes, Reminders | CLI |
| 11 | [carterlasalle/mac_messages_mcp](https://github.com/carterlasalle/mac_messages_mcp) | 344 | MIT | Python | 2026-11-05 | v1.1.0 (2026-09-01) | `8b0cef1` | PyPI 1,476 per month (single fetch) | Messages, contact lookup | MCP |
| 12 | [patrickfreyer/apple-mail-mcp](https://github.com/patrickfreyer/apple-mail-mcp) | 250 | MIT | Python | 2026-11-04 | v3.3.0 (2026-11-03) | `66b86a8` | PyPI 416 per month (single fetch) | Mail | MCP |
| 13 | [FradSer/mcp-server-apple-events](https://github.com/FradSer/mcp-server-apple-events) | 232 | MIT | TypeScript | 2026-11-08 | v1.6.2 (2026-10-22) | `0a477f6` | npm 7,035 per month | Reminders, Calendar | MCP |
| 14 | [sweetrb/apple-notes-mcp](https://github.com/sweetrb/apple-notes-mcp) | 183 | MIT | TypeScript | 2026-11-09 | v2.16.1 (2026-11-09) | `fb5ef5b` | npm 15,908 per month | Notes | MCP |
| 15 | [sweetrb/apple-mail-mcp](https://github.com/sweetrb/apple-mail-mcp) | 108 | MIT | JavaScript | 2026-11-04 | v2.20.55 (2026-11-04) | `c054b05` | npm 24,950 per month | Mail | MCP |
| 16 | [omarshahine/apple-pim](https://github.com/omarshahine/apple-pim) | 68 | MIT | Swift | 2026-11-01 | v3.19.2 (2026-10-25) | `c0b9eb5` | 728 release downloads (single fetch) | Calendar, Reminders, Contacts, Mail | CLI and MCP |

Rows 6 and the "single fetch" cells come from one research pass and were not fetched a second time. Everything else was fetched twice on 2026-11-09 with matching values.

Other tools found and ranked lower (RafalWilinski/mcp-apple-notes, Omar-V2/mcp-ical, RhetTbull/macnotesapp, BRO3886/ical, keith/contacts-cli, jwulff/apple-voice-memo-mcp) appear in the per-app lists below where relevant.

## Benchmarked set

Chosen before any measurement, by adoption, activity and app coverage. Each tool is pinned to the release shown.

| Tool | Pinned | Why it is in |
| --- | --- | --- |
| mattt/iMCP | 1.8.3 | The only popular active tool that claims all seven apps |
| openclaw/imsg | v0.21.0 | Most adopted Messages tool |
| openclaw/remindctl | v0.3.9 | Most installed Reminders CLI |
| keith/reminders-cli | 2.5.1 | Most starred Reminders CLI |
| antoniorodr/memo | v0.6.2 | Most installed Notes and Reminders CLI |
| sweetrb/apple-mail-mcp | v2.20.55 | Most installed Mail MCP server |
| patrickfreyer/apple-mail-mcp | v3.3.0 | Most starred active Mail MCP server |
| sweetrb/apple-notes-mcp | v2.16.1 | Most installed Notes MCP server |
| FradSer/mcp-server-apple-events | v1.6.2 | Most installed Calendar and Reminders MCP server |
| carterlasalle/mac_messages_mcp | v1.1.0 | Most starred Messages MCP server |
| omarshahine/apple-pim | v3.19.2 | Closest in design to Pippin (Swift CLI plus MCP), and the only active Contacts option besides iMCP |

Eleven tools, which is more than the eight the mission asks for, because the per-app top three add tools that are not in the overall top eight.

## Top three per app

| App | 1 | 2 | 3 | Note |
| --- | --- | --- | --- | --- |
| Mail | sweetrb/apple-mail-mcp | patrickfreyer/apple-mail-mcp | mattt/iMCP | apple-pim also covers Mail |
| Calendar | mattt/iMCP | FradSer/mcp-server-apple-events | omarshahine/apple-pim | Omar-V2/mcp-ical has more stars (333) but no commit since 2025-04-21 |
| Contacts | mattt/iMCP | omarshahine/apple-pim | none | keith/contacts-cli (67 stars) is read-only search. Fewer than three real options exist |
| Messages | openclaw/imsg | carterlasalle/mac_messages_mcp | mattt/iMCP | |
| Notes | sweetrb/apple-notes-mcp | antoniorodr/memo | mattt/iMCP | RhetTbull/macnotesapp (273 stars) is a close fourth |
| Reminders | openclaw/remindctl | keith/reminders-cli | FradSer/mcp-server-apple-events | viticci/remctl (654 stars) installs under `/Library` with an admin password, which the isolated-install rule forbids |
| Voice Memos | mattt/iMCP | none | none | The next options have fewer than 20 stars. Effectively one competitor |

## Exclusions

| Tool | Reason |
| --- | --- |
| supermemoryai/apple-mcp | Archived, no commit since 2025-08-11 |
| steipete/macos-automator-mcp | Archived |
| joshrutkowski/applescript-mcp | No commit in more than 12 months |
| peakmojo/applescript-mcp | Generic script runner with no app operations to compare |
| openclaw/Peekaboo and other screen-control tools | GUI and screen automation, not app data |
| viticci/remctl | Needs an admin install outside an isolated directory |
| RafalWilinski/mcp-apple-notes | No license, no commit since 2024-12 |
| ReagentX/imessage-exporter | Export only, not an agent interface |
| Shortcuts-based MCP servers | Depend on shortcuts the user writes, so there is no fixed capability to measure |
| iCloud IMAP or CalDAV servers | Need account credentials, and act on the cloud service, not the local apps |

## What each benchmarked tool needs

None needs account credentials. All need macOS privacy permissions granted to whatever process launches them.

| Tool | Runtime | Permissions | Isolation note |
| --- | --- | --- | --- |
| mattt/iMCP | macOS 15.3 or later, GUI app running | Per-service toggles and approval dialogs in the app | Cannot be confined to a directory. Needs a person to enable services |
| openclaw/imsg | Release binary, macOS 14 or later | Full Disk Access to read, Automation to send | Binary in the tools directory |
| openclaw/remindctl | Release binary, macOS 14 or later | Reminders | Binary in the tools directory |
| keith/reminders-cli | Release binary | Reminders | Binary in the tools directory |
| antoniorodr/memo | Python 3.13 or later, in a virtual environment | Automation for Notes and Reminders | Virtual environment in the tools directory |
| sweetrb/apple-mail-mcp | Node 20 or later | Automation for Mail | `npm install` into the tools directory |
| patrickfreyer/apple-mail-mcp | Python 3.10 or later | Automation for Mail | Virtual environment in the tools directory |
| sweetrb/apple-notes-mcp | Node 20 or later | Automation for Notes, Full Disk Access for database reads | `npm install` into the tools directory |
| FradSer/mcp-server-apple-events | Node 20 or later, ships a signed Swift helper | Reminders, Calendar | `npm install` into the tools directory |
| carterlasalle/mac_messages_mcp | Python 3.10 or later | Full Disk Access, Automation to send | Virtual environment in the tools directory |
| omarshahine/apple-pim | Swift 5.9 or later, Node 18 or later | Calendar, Reminders, Contacts, Automation for Mail | Built in the tools directory |

A tool whose required permission has not been granted on the benchmark machine is reported as "not run" for the affected operations, as the methodology states.
