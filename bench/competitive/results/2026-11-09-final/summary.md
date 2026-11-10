## Scores (0 to 4, rubric in methodology.md)

| Tool | Version | Apps scored | Coverage | Correctness | Reliability | Speed | Safety (input) | Dealbreaker |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| apple-events | 1.6.2 | 2 | 4 (10/10) | 4 (20/20) | 4 (20/20) | 1 | 4 (48/48) | none observed |
| apple-pim | 3.19.2 | 3 | 4 (15/15) | 3 (28/29) | 4 (30/30) | 1 | 4 (72/72) | none observed |
| imsg | 0.21.0 | 1 | 4 (3/3) | 2 (2/3) | 3 (9/10) | 1 | 4 (24/24) | none observed |
| mac-messages | 1.1.0 | 1 | 4 (3/3) | n/r | 3 (9/10) | 2 | 4 (24/24) | none observed |
| memo | 0.6.2 | 2 | 1 (3/13) | 2 (6/7) | 3 (10/11) | 2 | n/r | none observed |
| pippin | pippin 0.41.1 (branch build d91a21a) | 5 | 4 (23/23) | 4 (45/45) | 4 (50/50) | 4 | 4 (120/120) | none observed |
| remindctl | 0.3.9 | 1 | 4 (5/5) | 4 (10/10) | 4 (10/10) | 2 | 4 (24/24) | none observed |
| reminders-cli | 2.5.1 | 1 | 2 (4/5) | 4 (7/7) | 4 (7/7) | 1 | n/r | none observed |
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
| calendar.calendars | 29.1 | 36.1 |  |  |  | **4.3** |  |  |  |
| calendar.events | 51.4 | 51.6 |  |  |  | **16.5** |  |  |  |
| calendar.search | 70.5 | 42.5 |  |  |  | **22.8** |  |  |  |
| contacts.groups |  | 56.7 |  |  |  | **31.1** |  |  |  |
| contacts.list |  | 109.4 |  |  |  | **38.7** |  |  |  |
| contacts.search |  | 142.0 |  |  |  | **2.9** |  |  |  |
| messages.chats |  |  | 94.5 | **1.2** |  | 1.7 |  |  |  |
| messages.history |  |  | 175.9 | 24.2 |  | **3.8** |  |  |  |
| messages.search |  |  | 128.8 | 23.7 |  | **2.9** |  |  |  |
| notes.folders |  |  |  |  | 266.1 | **116.0** |  |  | 367.5 |
| notes.list |  |  |  |  | 265.5 | 231.9 |  |  | **150.3** |
| notes.search |  |  |  |  |  | 249.6 |  |  | **183.2** |
| reminders.list | 47.8 | 41.8 |  |  | 2450.2 | **11.9** | 31.3 | 40.4 |  |
| reminders.lists | 29.7 | 36.7 |  |  |  | **4.7** | 31.2 | 35.6 |  |
| reminders.search | 34.6 | 40.5 |  |  |  | **8.4** | 31.3 |  |  |

## Cold latency, p50 in ms (N = 5, new process per call)

| Operation | apple-events | apple-pim | imsg | mac-messages | memo | pippin | remindctl | reminders-cli | sweetrb-notes |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| calendar.calendars | 115.7 | 111.5 |  |  |  | 19.1 |  |  |  |
| calendar.events | 152.6 | 128.1 |  |  |  | 32.9 |  |  |  |
| calendar.search | 150.3 | 119.1 |  |  |  | 39.5 |  |  |  |
| contacts.groups |  | 139.6 |  |  |  | 42.7 |  |  |  |
| contacts.list |  | 189.1 |  |  |  | 51.4 |  |  |  |
| contacts.search |  | 217.5 |  |  |  | 40.5 |  |  |  |
| messages.chats |  |  | 95.1 | 254.3 |  | 39.0 |  |  |  |
| messages.history |  |  | 175.5 | 281.9 |  | 40.1 |  |  |  |
| messages.search |  |  | 128.6 | 276.8 |  | 39.7 |  |  |  |
| notes.folders |  |  |  |  | 268.0 | 132.6 |  |  | 467.0 |
| notes.list |  |  |  |  | 267.5 | 231.8 |  |  | 252.9 |
| notes.search |  |  |  |  |  | 250.2 |  |  | 327.5 |
| reminders.list | 115.0 | 118.5 |  |  | 2450.6 | 27.0 | 31.3 | 42.0 |  |
| reminders.lists | 108.4 | 111.6 |  |  |  | 19.7 | 32.4 | 35.7 |  |
| reminders.search | 128.3 | 116.7 |  |  |  | 23.6 | 31.3 |  |  |

## Agent ergonomics (raw)

| Tool | Kind | Tools | Manifest tokens | Tools with behavior annotations | Structured errors on bad input |
| --- | --- | --- | --- | --- | --- |
| apple-events | mcp | 5 | 3694 | 0 | 0 of 2 |
| apple-pim | mcp | 5 | 7823 | 0 | 3 of 3 |
| imsg | cli | n/a | 389 | n/a | 0 of 1 |
| mac-messages | mcp | 11 | 3437 | 0 | 0 of 1 |
| memo | cli | n/a | 37 | n/a | 0 of 2 |
| pippin | mcp | 79 | 22615 | 79 | 5 of 5 |
| remindctl | cli | n/a | 109 | n/a | 0 of 1 |
| reminders-cli | cli | n/a | 102 | n/a | 0 of 1 |
| sweetrb-notes | mcp | 89 | 56023 | 46 | 1 of 1 |

## Failed checks

- apple-pim, correctness: reminders.list: 21 wrong instant
- imsg, correctness: messages.history: 1 missing
- imsg, reliability: messages.history bad input: reported success
- mac-messages, correctness: messages.history: reply is prose, not checked
- mac-messages, reliability: messages.history bad input: reported success
- memo, correctness: reminders.list: 1 wrong instant
- memo, reliability: reminders.list bad input: reported success
- memo, safety: no search operation to carry a hostile query
- reminders-cli, safety: no search operation to carry a hostile query
