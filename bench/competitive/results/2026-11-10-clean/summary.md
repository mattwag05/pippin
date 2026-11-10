## Scores (0 to 4, rubric in methodology.md)

| Tool | Version | Apps scored | Coverage | Correctness | Reliability | Speed | Safety (input) | Dealbreaker |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| apple-events | 1.6.2 | 2 | 4 (10/10) | 4 (20/20) | 4 (20/20) | 2 | 4 (48/48) | none observed |
| apple-pim | 3.19.2 | 4 | 3 (19/20) | 3 (34/35) | 4 (42/42) | 2 | 4 (72/72) | none observed |
| imsg | 0.21.0 | 1 | 4 (3/3) | 2 (2/3) | 3 (9/10) | 1 | 4 (24/24) | none observed |
| mac-messages | 1.1.0 | 1 | 4 (3/3) | n/r | 3 (9/10) | 2 | 4 (24/24) | none observed |
| memo | 0.6.2 | 2 | 1 (3/13) | 4 (7/7) | 2 (9/11) | 2 | n/r | none observed |
| pf-mail | 3.3.0 | 1 | 4 (4/4) | 4 (6/6) | 4 (12/12) | 2 | n/r | none observed |
| pippin | pippin 1.0.0 (branch build 09fbc84) | 7 | 4 (28/28) | 4 (54/54) | 3 (64/65) | 4 | 4 (120/120) | none observed |
| remindctl | 0.3.9 | 1 | 4 (5/5) | 4 (10/10) | 4 (10/10) | 1 | 4 (24/24) | none observed |
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
| calendar.calendars | 29.8 | 36.9 |  |  |  |  | **5.7** |  |  |  |  |
| calendar.events | 53.4 | 52.0 |  |  |  |  | **19.4** |  |  |  |  |
| calendar.search | 59.1 | 44.7 |  |  |  |  | **23.1** |  |  |  |  |
| contacts.groups |  | 59.0 |  |  |  |  | **42.6** |  |  |  |  |
| contacts.list |  | 117.4 |  |  |  |  | **46.7** |  |  |  |  |
| contacts.search |  | 151.4 |  |  |  |  | **3.7** |  |  |  |  |
| mail.accounts |  | 217.9 |  |  |  | 66.6 | 66.6 |  |  | **54.4** |  |
| mail.list |  | 8.3 |  |  |  | 2116.9 | **2.9** |  |  | 3250.1 |  |
| mail.mailboxes |  | 6.2 |  |  |  | 166.8 | **0.4** |  |  | 515.5 |  |
| mail.search |  | 7.2 |  |  |  | 850.0 | **1.9** |  |  | 1149.8 |  |
| memos.list |  |  |  |  |  |  | **11.2** |  |  |  |  |
| messages.chats |  |  | 116.7 | **1.3** |  |  | 2.9 |  |  |  |  |
| messages.history |  |  | 263.4 | 29.1 |  |  | **4.8** |  |  |  |  |
| messages.search |  |  | 148.8 | 30.2 |  |  | **5.1** |  |  |  |  |
| notes.folders |  |  |  |  | 266.2 |  | **99.9** |  |  |  | 368.6 |
| notes.list |  |  |  |  | 266.4 |  | 166.4 |  |  |  | **150.0** |
| notes.search |  |  |  |  |  |  | **183.3** |  |  |  | 183.3 |
| reminders.list | 37.5 | 43.6 |  |  | 2466.6 |  | **15.1** | 39.1 | 51.6 |  |  |
| reminders.lists | 31.2 | 42.8 |  |  |  |  | **5.9** | 39.5 | 44.9 |  |  |
| reminders.search | 37.0 | 41.4 |  |  |  |  | **10.9** | 40.1 |  |  |  |

## Cold latency, p50 in ms (N = 5, new process per call)

| Operation | apple-events | apple-pim | imsg | mac-messages | memo | pf-mail | pippin | remindctl | reminders-cli | sweetrb-mail | sweetrb-notes |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| calendar.calendars | 131.1 | 114.8 |  |  |  |  | 37.3 |  |  |  |  |
| calendar.events | 156.1 | 131.0 |  |  |  |  | 52.5 |  |  |  |  |
| calendar.search | 158.0 | 122.6 |  |  |  |  | 59.4 |  |  |  |  |
| contacts.groups |  | 137.8 |  |  |  |  | 70.0 |  |  |  |  |
| contacts.list |  | 202.6 |  |  |  |  | 70.3 |  |  |  |  |
| contacts.search |  | 229.3 |  |  |  |  | 63.4 |  |  |  |  |
| mail.accounts |  | 298.6 |  |  |  | 642.8 | 106.8 |  |  | 234.1 |  |
| mail.list |  | 88.2 |  |  |  | 2710.5 | 69.1 |  |  | 3403.5 |  |
| mail.mailboxes |  | 82.1 |  |  |  | 728.5 | 33.4 |  |  | 850.1 |  |
| mail.search |  | 85.0 |  |  |  | 1418.8 | 64.5 |  |  | 1301.9 |  |
| memos.list |  |  |  |  |  |  | 37.4 |  |  |  |  |
| messages.chats |  |  | 172.3 | 325.9 |  |  | 67.5 |  |  |  |  |
| messages.history |  |  | 237.9 | 376.9 |  |  | 69.1 |  |  |  |  |
| messages.search |  |  | 158.2 | 361.0 |  |  | 64.2 |  |  |  |  |
| notes.folders |  |  |  |  | 266.8 |  | 133.3 |  |  |  | 481.1 |
| notes.list |  |  |  |  | 266.0 |  | 200.1 |  |  |  | 260.3 |
| notes.search |  |  |  |  |  |  | 217.9 |  |  |  | 335.5 |
| reminders.list | 134.4 | 125.7 |  |  | 2486.3 |  | 46.4 | 39.0 | 48.6 |  |  |
| reminders.lists | 124.9 | 118.4 |  |  |  |  | 38.4 | 43.5 | 45.7 |  |  |
| reminders.search | 122.0 | 119.5 |  |  |  |  | 43.5 | 39.0 |  |  |  |

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
- imsg, correctness: messages.history: 1 missing
- imsg, reliability: messages.history bad input: reported success
- mac-messages, correctness: messages.history: reply is prose, not checked
- mac-messages, reliability: messages.history bad input: reported success
- memo, reliability: reminders.list x8: 8 ok, 2 distinct
- memo, reliability: reminders.list bad input: reported success
- memo, safety: no search operation to carry a hostile query
- pf-mail, safety: no search operation to carry a hostile query
- pippin, reliability: memos.list x8: 7 ok, 1 distinct
- reminders-cli, safety: no search operation to carry a hostile query
- sweetrb-mail, correctness: mail.search: 4 missing
- sweetrb-mail, safety: no search operation to carry a hostile query
