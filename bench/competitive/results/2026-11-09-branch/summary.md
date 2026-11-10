## Scores (0 to 4, rubric in methodology.md)

| Tool | Version | Apps scored | Coverage | Correctness | Reliability | Speed | Safety (input) | Dealbreaker |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| apple-events | 1.6.2 | 2 | 4 (10/10) | 4 (20/20) | 4 (20/20) | 1 | 4 (48/48) | none observed |
| apple-pim | 3.19.2 | 3 | 4 (15/15) | 3 (28/29) | 4 (30/30) | 1 | 4 (72/72) | none observed |
| imsg | 0.21.0 | 1 | 4 (3/3) | 2 (2/3) | 3 (9/10) | 1 | 4 (24/24) | none observed |
| mac-messages | 1.1.0 | 1 | 4 (3/3) | n/r | 3 (9/10) | 4 | 4 (24/24) | none observed |
| memo | 0.6.2 | 2 | 1 (3/13) | 4 (7/7) | 2 (9/11) | 2 | n/r | none observed |
| pippin | pippin 0.41.1 (branch build 761148f+harness) | 5 | 4 (23/23) | 4 (45/45) | 4 (50/50) | 3 | 4 (120/120) | none observed |
| remindctl | 0.3.9 | 1 | 4 (5/5) | 4 (10/10) | 4 (10/10) | 2 | 4 (24/24) | none observed |
| reminders-cli | 2.5.1 | 1 | 2 (4/5) | 4 (7/7) | 4 (7/7) | 2 | n/r | none observed |
| sweetrb-notes | 2.16.1 | 1 | 4 (5/5) | 4 (9/9) | 4 (10/10) | 3 | 4 (24/24) | none observed |
| imcp | 1.8.3 | n/r | n/r | n/r | n/r | n/r | n/r | not run: initialize exceeded 60s |
| pf-mail | 3.3.0 | n/r | n/r | n/r | n/r | n/r | n/r | not run: Mail only, and the VM has no mail account |
| sweetrb-mail | 2.20.55 | n/r | n/r | n/r | n/r | n/r | n/r | not run: Mail only, and the VM has no mail account |

## Coverage by app (yes / probed cells)

| Tool | reminders | calendar | contacts | notes | messages |
| --- | --- | --- | --- | --- | --- |
| apple-events | 5/5 | 5/5 | out of scope | out of scope | out of scope |
| apple-pim | 5/5 | 5/5 | 5/5 | out of scope | out of scope |
| imsg | out of scope | out of scope | out of scope | out of scope | 3/3 |
| mac-messages | out of scope | out of scope | out of scope | out of scope | 3/3 |
| memo | 1/7 | out of scope | out of scope | 2/6 | out of scope |
| pippin | 5/5 | 5/5 | 5/5 | 5/5 | 3/3 |
| remindctl | 5/5 | out of scope | out of scope | out of scope | out of scope |
| reminders-cli | 4/5 | out of scope | out of scope | out of scope | out of scope |
| sweetrb-notes | out of scope | out of scope | out of scope | 5/5 | out of scope |

## Warm latency, p50 in ms (N = 30 after 3 warmups)

| Operation | apple-events | apple-pim | imsg | mac-messages | memo | pippin | remindctl | reminders-cli | sweetrb-notes |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| calendar.calendars | 32.0 | 42.2 |  |  |  | **6.7** |  |  |  |
| calendar.events | 64.9 | 64.1 |  |  |  | **18.7** |  |  |  |
| calendar.search | 85.3 | 46.2 |  |  |  | **26.7** |  |  |  |
| contacts.groups |  | 60.3 |  |  |  | **38.1** |  |  |  |
| contacts.list |  | 113.5 |  |  |  | **49.9** |  |  |  |
| contacts.search |  | 154.9 |  |  |  | **3.2** |  |  |  |
| messages.chats |  |  | 110.7 | **1.2** |  | 40.4 |  |  |  |
| messages.history |  |  | 196.5 | **28.0** |  | 40.4 |  |  |  |
| messages.search |  |  | 140.4 | **25.4** |  | 39.5 |  |  |  |
| notes.folders |  |  |  |  | 265.3 | **116.9** |  |  | 366.6 |
| notes.list |  |  |  |  | 264.5 | 233.3 |  |  | **150.2** |
| notes.search |  |  |  |  |  | 249.6 |  |  | **182.9** |
| reminders.list | 37.9 | 48.4 |  |  | 2464.8 | **14.9** | 32.4 | 41.6 |  |
| reminders.lists | 38.4 | 40.2 |  |  |  | **6.5** | 32.4 | 36.5 |  |
| reminders.search | 39.5 | 51.9 |  |  |  | **10.6** | 32.4 |  |  |

## Cold latency, p50 in ms (N = 5, new process per call)

| Operation | apple-events | apple-pim | imsg | mac-messages | memo | pippin | remindctl | reminders-cli | sweetrb-notes |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| calendar.calendars | 128.9 | 125.0 |  |  |  | 25.6 |  |  |  |
| calendar.events | 150.9 | 149.2 |  |  |  | 39.0 |  |  |  |
| calendar.search | 163.1 | 130.2 |  |  |  | 47.7 |  |  |  |
| contacts.groups |  | 141.0 |  |  |  | 54.4 |  |  |  |
| contacts.list |  | 196.5 |  |  |  | 63.4 |  |  |  |
| contacts.search |  | 227.8 |  |  |  | 49.7 |  |  |  |
| messages.chats |  |  | 104.2 | 260.9 |  | 54.6 |  |  |  |
| messages.history |  |  | 191.7 | 296.6 |  | 53.2 |  |  |  |
| messages.search |  |  | 142.3 | 306.8 |  | 53.2 |  |  |  |
| notes.folders |  |  |  |  | 268.6 | 133.5 |  |  | 462.3 |
| notes.list |  |  |  |  | 267.1 | 249.7 |  |  | 250.4 |
| notes.search |  |  |  |  |  | 266.6 |  |  | 349.4 |
| reminders.list | 154.7 | 137.5 |  |  | 2463.8 | 36.2 | 32.4 | 41.4 |  |
| reminders.lists | 146.7 | 178.6 |  |  |  | 26.4 | 32.7 | 36.3 |  |
| reminders.search | 132.4 | 122.5 |  |  |  | 31.5 | 31.9 |  |  |

## Agent ergonomics (raw)

| Tool | Kind | Tools | Manifest tokens | Tools with behavior annotations | Structured errors on bad input |
| --- | --- | --- | --- | --- | --- |
| apple-events | mcp | 5 | 3694 | 0 | 0 of 2 |
| apple-pim | mcp | 5 | 7823 | 0 | 3 of 3 |
| imsg | cli | n/a | 389 | n/a | 0 of 1 |
| mac-messages | mcp | 11 | 3437 | 0 | 0 of 1 |
| memo | cli | n/a | 37 | n/a | 0 of 2 |
| pippin | mcp | 79 | 22465 | 79 | 5 of 5 |
| remindctl | cli | n/a | 109 | n/a | 0 of 1 |
| reminders-cli | cli | n/a | 102 | n/a | 0 of 1 |
| sweetrb-notes | mcp | 89 | 56023 | 46 | 1 of 1 |

## Failed checks

- apple-pim, correctness: reminders.list: 21 wrong instant
- imsg, correctness: messages.history: 1 missing
- imsg, reliability: messages.history bad input: reported success
- mac-messages, correctness: messages.history: reply is prose, not checked
- mac-messages, reliability: messages.history bad input: reported success
- memo, reliability: reminders.list x8: 8 ok, 3 distinct
- memo, reliability: reminders.list bad input: reported success
- memo, safety: no search operation to carry a hostile query
- reminders-cli, safety: no search operation to carry a hostile query
