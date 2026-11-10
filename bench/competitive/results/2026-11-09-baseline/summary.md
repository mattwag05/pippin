## Scores (0 to 4, rubric in methodology.md)

| Tool | Version | Apps scored | Coverage | Correctness | Reliability | Speed | Safety (input) | Dealbreaker |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| apple-events | 1.6.2 | 2 | 4 (10/10) | 4 (20/20) | 4 (20/20) | 1 | 4 (48/48) | none observed |
| apple-pim | 3.19.2 | 3 | 4 (15/15) | 3 (28/29) | 4 (30/30) | 1 | 4 (72/72) | none observed |
| imsg | 0.21.0 | 1 | 4 (3/3) | 2 (2/3) | 3 (9/10) | 1 | 4 (24/24) | none observed |
| mac-messages | 1.1.0 | 1 | 4 (3/3) | n/r | 3 (9/10) | 4 | 4 (24/24) | none observed |
| memo | 0.6.2 | 2 | 1 (3/13) | 4 (7/7) | 2 (9/11) | 2 | n/r | none observed |
| pippin | 0.41.1 | 5 | 4 (23/23) | 3 (43/46) | 4 (50/50) | 3 | 4 (120/120) | none observed |
| remindctl | 0.3.9 | 1 | 4 (5/5) | 4 (10/10) | 4 (10/10) | 1 | 4 (24/24) | none observed |
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
| calendar.calendars | 43.1 | 53.1 |  |  |  | **4.9** |  |  |  |
| calendar.events | 72.9 | 66.1 |  |  |  | **17.8** |  |  |  |
| calendar.search | 78.9 | 55.7 |  |  |  | **24.0** |  |  |  |
| contacts.groups |  | 65.1 |  |  |  | **38.8** |  |  |  |
| contacts.list |  | 122.3 |  |  |  | **49.7** |  |  |  |
| contacts.search |  | 162.1 |  |  |  | **3.3** |  |  |  |
| messages.chats |  |  | 103.2 | **1.1** |  | 38.7 |  |  |  |
| messages.history |  |  | 234.5 | **26.6** |  | 43.6 |  |  |  |
| messages.search |  |  | 154.2 | **25.9** |  | 40.3 |  |  |  |
| notes.folders |  |  |  |  | 263.0 | **217.4** |  |  | 363.8 |
| notes.list |  |  |  |  | 265.8 | 3266.6 |  |  | **149.7** |
| notes.search |  |  |  |  |  | 1100.3 |  |  | **182.8** |
| reminders.list | 64.0 | 51.5 |  |  | 2466.6 | **14.7** | 41.6 | 44.5 |  |
| reminders.lists | 44.0 | 45.8 |  |  |  | **6.5** | 41.1 | 40.5 |  |
| reminders.search | 65.2 | 63.0 |  |  |  | **9.8** | 40.2 |  |  |

## Cold latency, p50 in ms (N = 5, new process per call)

| Operation | apple-events | apple-pim | imsg | mac-messages | memo | pippin | remindctl | reminders-cli | sweetrb-notes |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| calendar.calendars | 151.0 | 149.2 |  |  |  | 24.3 |  |  |  |
| calendar.events | 199.5 | 160.6 |  |  |  | 36.1 |  |  |  |
| calendar.search | 174.9 | 142.5 |  |  |  | 43.6 |  |  |  |
| contacts.groups |  | 157.4 |  |  |  | 49.7 |  |  |  |
| contacts.list |  | 214.9 |  |  |  | 64.8 |  |  |  |
| contacts.search |  | 259.3 |  |  |  | 49.2 |  |  |  |
| messages.chats |  |  | 103.7 | 301.3 |  | 51.7 |  |  |  |
| messages.history |  |  | 240.3 | 370.4 |  | 60.2 |  |  |  |
| messages.search |  |  | 190.4 | 302.1 |  | 55.3 |  |  |  |
| notes.folders |  |  |  |  | 266.5 | 233.3 |  |  | 472.0 |
| notes.list |  |  |  |  | 263.8 | 3267.4 |  |  | 265.5 |
| notes.search |  |  |  |  |  | 1100.4 |  |  | 358.7 |
| reminders.list | 150.1 | 135.8 |  |  | 2474.6 | 35.1 | 38.2 | 44.1 |  |
| reminders.lists | 131.6 | 128.6 |  |  |  | 25.6 | 37.2 | 48.1 |  |
| reminders.search | 161.0 | 158.5 |  |  |  | 28.3 | 44.0 |  |  |

## Agent ergonomics (raw)

| Tool | Kind | Tools | Manifest tokens | Tools with behavior annotations | Structured errors on bad input |
| --- | --- | --- | --- | --- | --- |
| apple-events | mcp | 5 | 3694 | 0 | 0 of 2 |
| apple-pim | mcp | 5 | 7823 | 0 | 3 of 3 |
| imsg | cli | n/a | 389 | n/a | 0 of 1 |
| mac-messages | mcp | 11 | 3437 | 0 | 0 of 1 |
| memo | cli | n/a | 37 | n/a | 0 of 2 |
| pippin | mcp | 76 | 15645 | 0 | 5 of 5 |
| remindctl | cli | n/a | 109 | n/a | 0 of 1 |
| reminders-cli | cli | n/a | 102 | n/a | 0 of 1 |
| sweetrb-notes | mcp | 89 | 56023 | 46 | 1 of 1 |

## Failed checks

- apple-pim, correctness: reminders.list: 21 wrong instant
- imsg, correctness: messages.history: 1 missing
- imsg, reliability: messages.history bad input: reported success
- mac-messages, correctness: messages.history: reply is prose, not checked
- mac-messages, reliability: messages.history bad input: reported success
- memo, reliability: reminders.list x8: 8 ok, 2 distinct
- memo, reliability: reminders.list bad input: reported success
- memo, safety: no search operation to carry a hostile query
- pippin, correctness: messages.history: 1 missing
- pippin, correctness: messages.history: 17 outgoing sender wrong
- pippin, correctness: chat-a unread 3, expected 2
- reminders-cli, safety: no search operation to carry a hostile query
