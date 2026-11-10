## Scores (0 to 4, rubric in methodology.md)

| Tool | Version | Apps scored | Coverage | Correctness | Reliability | Speed | Safety (input) | Dealbreaker |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| apple-events | 1.6.2 | 2 | 4 (10/10) | 4 (20/20) | 4 (20/20) | 1 | 4 (48/48) | none observed |
| apple-pim | 3.19.2 | 4 | 3 (19/20) | 3 (34/35) | 3 (41/42) | 2 | 4 (72/72) | none observed |
| imsg | 0.21.0 | 1 | 4 (3/3) | 2 (2/3) | 3 (9/10) | 1 | 4 (24/24) | none observed |
| mac-messages | 1.1.0 | 1 | 4 (3/3) | n/r | 3 (9/10) | 2 | 4 (24/24) | none observed |
| memo | 0.6.2 | 2 | 1 (3/13) | 4 (7/7) | 2 (9/11) | 1 | n/r | none observed |
| pf-mail | 3.3.0 | 1 | 4 (4/4) | 4 (6/6) | 4 (12/12) | 2 | n/r | none observed |
| pippin | pippin 1.0.0 (branch build 3ec767f) | 7 | 4 (28/28) | 4 (54/54) | 4 (65/65) | 4 | 4 (120/120) | none observed |
| remindctl | 0.3.9 | 1 | 4 (5/5) | 4 (10/10) | 4 (10/10) | 2 | 4 (24/24) | none observed |
| reminders-cli | 2.5.1 | 1 | 2 (4/5) | 4 (7/7) | 4 (7/7) | 1 | n/r | none observed |
| sweetrb-mail | 2.20.55 | 1 | 4 (4/4) | 2 (5/6) | 4 (12/12) | 2 | n/r | none observed |
| sweetrb-notes | 2.16.1 | 1 | 4 (5/5) | 4 (9/9) | 4 (10/10) | 3 | 4 (24/24) | none observed |
| imcp | 1.8.3 | n/r | n/r | n/r | n/r | n/r | n/r | not run: initialize exceeded 60s |

## Coverage by app (yes / probed cells)

| Tool | reminders | calendar | contacts | notes | messages | mail | memos |
| --- | --- | --- | --- | --- | --- | --- | --- |
| apple-events | 5/5 | 5/5 | out of scope | out of scope | out of scope | out of scope | out of scope |
| apple-pim | 5/5 | 5/5 | 5/5 | out of scope | out of scope | 4/5 | out of scope |
| imsg | out of scope | out of scope | out of scope | out of scope | 3/3 | out of scope | out of scope |
| mac-messages | out of scope | out of scope | out of scope | out of scope | 3/3 | out of scope | out of scope |
| memo | 1/7 | out of scope | out of scope | 2/6 | out of scope | out of scope | out of scope |
| pf-mail | out of scope | out of scope | out of scope | out of scope | out of scope | 4/4 | out of scope |
| pippin | 5/5 | 5/5 | 5/5 | 5/5 | 3/3 | 4/4 | 1/1 |
| remindctl | 5/5 | out of scope | out of scope | out of scope | out of scope | out of scope | out of scope |
| reminders-cli | 4/5 | out of scope | out of scope | out of scope | out of scope | out of scope | out of scope |
| sweetrb-mail | out of scope | out of scope | out of scope | out of scope | out of scope | 4/4 | out of scope |
| sweetrb-notes | out of scope | out of scope | out of scope | 5/5 | out of scope | out of scope | out of scope |

## Warm latency, p50 in ms (N = 30 after 3 warmups)

| Operation | apple-events | apple-pim | imsg | mac-messages | memo | pf-mail | pippin | remindctl | reminders-cli | sweetrb-mail | sweetrb-notes |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| calendar.calendars | 42.3 | 38.5 |  |  |  |  | **4.5** |  |  |  |  |
| calendar.events | 66.3 | 54.5 |  |  |  |  | **17.3** |  |  |  |  |
| calendar.search | 61.0 | 43.7 |  |  |  |  | **23.8** |  |  |  |  |
| contacts.groups |  | 60.5 |  |  |  |  | **35.1** |  |  |  |  |
| contacts.list |  | 113.1 |  |  |  |  | **40.6** |  |  |  |  |
| contacts.search |  | 147.9 |  |  |  |  | **3.0** |  |  |  |  |
| mail.accounts |  | 230.0 |  |  |  | 66.5 | 55.2 |  |  | **54.8** |  |
| mail.list |  | 8.5 |  |  |  | 2132.2 | **2.4** |  |  | 3251.8 |  |
| mail.mailboxes |  | 6.0 |  |  |  | 166.6 | **0.4** |  |  | 516.3 |  |
| mail.search |  | 7.7 |  |  |  | 866.5 | **1.6** |  |  | 1150.2 |  |
| memos.list |  |  |  |  |  |  | **9.3** |  |  |  |  |
| messages.chats |  |  | 95.6 | **1.2** |  |  | 1.8 |  |  |  |  |
| messages.history |  |  | 177.6 | 24.5 |  |  | **3.9** |  |  |  |  |
| messages.search |  |  | 131.7 | 24.1 |  |  | **2.9** |  |  |  |  |
| notes.folders |  |  |  |  | 265.9 |  | **84.7** |  |  |  | 369.6 |
| notes.list |  |  |  |  | 266.3 |  | 166.8 |  |  |  | **150.0** |
| notes.search |  |  |  |  |  |  | 183.2 |  |  |  | **183.2** |
| reminders.list | 36.1 | 46.2 |  |  | 2450.2 |  | **13.5** | 30.8 | 40.9 |  |  |
| reminders.lists | 29.3 | 36.8 |  |  |  |  | **5.3** | 31.1 | 35.9 |  |  |
| reminders.search | 35.9 | 41.4 |  |  |  |  | **10.5** | 31.1 |  |  |  |

## Cold latency, p50 in ms (N = 5, new process per call)

| Operation | apple-events | apple-pim | imsg | mac-messages | memo | pf-mail | pippin | remindctl | reminders-cli | sweetrb-mail | sweetrb-notes |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| calendar.calendars | 119.4 | 116.0 |  |  |  |  | 34.2 |  |  |  |  |
| calendar.events | 164.1 | 131.0 |  |  |  |  | 47.5 |  |  |  |  |
| calendar.search | 162.7 | 122.4 |  |  |  |  | 50.4 |  |  |  |  |
| contacts.groups |  | 139.1 |  |  |  |  | 57.5 |  |  |  |  |
| contacts.list |  | 191.3 |  |  |  |  | 63.1 |  |  |  |  |
| contacts.search |  | 224.3 |  |  |  |  | 51.9 |  |  |  |  |
| mail.accounts |  | 246.5 |  |  |  | 591.8 | 81.4 |  |  | 200.5 |  |
| mail.list |  | 86.9 |  |  |  | 2641.0 | 55.5 |  |  | 3415.5 |  |
| mail.mailboxes |  | 80.0 |  |  |  | 696.4 | 27.1 |  |  | 844.6 |  |
| mail.search |  | 83.0 |  |  |  | 1400.4 | 57.4 |  |  | 1300.5 |  |
| memos.list |  |  |  |  |  |  | 30.2 |  |  |  |  |
| messages.chats |  |  | 95.9 | 242.5 |  |  | 52.2 |  |  |  |  |
| messages.history |  |  | 178.8 | 275.6 |  |  | 51.8 |  |  |  |  |
| messages.search |  |  | 130.5 | 268.4 |  |  | 52.0 |  |  |  |  |
| notes.folders |  |  |  |  | 267.2 |  | 118.6 |  |  |  | 473.0 |
| notes.list |  |  |  |  | 267.1 |  | 184.4 |  |  |  | 250.4 |
| notes.search |  |  |  |  |  |  | 201.1 |  |  |  | 337.6 |
| reminders.list | 120.2 | 120.3 |  |  | 2463.6 |  | 44.8 | 31.3 | 40.4 |  |  |
| reminders.lists | 112.9 | 111.7 |  |  |  |  | 34.3 | 32.1 | 35.9 |  |  |
| reminders.search | 127.9 | 148.3 |  |  |  |  | 38.7 | 30.9 |  |  |  |

## Agent ergonomics (raw)

| Tool | Kind | Tools | Manifest tokens | Tools with behavior annotations | Structured errors on bad input |
| --- | --- | --- | --- | --- | --- |
| apple-events | mcp | 5 | 3694 | 0 | 0 of 2 |
| apple-pim | mcp | 5 | 7823 | 0 | 3 of 3 |
| imsg | cli | n/a | 389 | n/a | 0 of 1 |
| mac-messages | mcp | 11 | 3437 | 0 | 0 of 1 |
| memo | cli | n/a | 37 | n/a | 0 of 2 |
| pf-mail | mcp | 28 | 14334 | 0 | 0 of 0 |
| pippin | mcp | 79 | 22615 | 79 | 5 of 5 |
| remindctl | cli | n/a | 109 | n/a | 0 of 1 |
| reminders-cli | cli | n/a | 102 | n/a | 0 of 1 |
| sweetrb-mail | mcp | 52 | 32652 | 52 | 0 of 0 |
| sweetrb-notes | mcp | 89 | 56023 | 46 | 1 of 1 |

## Failed checks

- apple-pim, correctness: reminders.list: 21 wrong instant
- apple-pim, reliability: mail.search x8: 7 ok, 1 distinct
- imsg, correctness: messages.history: 1 missing
- imsg, reliability: messages.history bad input: reported success
- mac-messages, correctness: messages.history: reply is prose, not checked
- mac-messages, reliability: messages.history bad input: reported success
- memo, reliability: reminders.list x8: 8 ok, 2 distinct
- memo, reliability: reminders.list bad input: reported success
- memo, safety: no search operation to carry a hostile query
- pf-mail, safety: no search operation to carry a hostile query
- reminders-cli, safety: no search operation to carry a hostile query
- sweetrb-mail, correctness: mail.search: 4 missing
- sweetrb-mail, safety: no search operation to carry a hostile query
