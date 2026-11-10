## Scores (0 to 4, rubric in methodology.md)

| Tool | Version | Apps scored | Coverage | Correctness | Reliability | Speed | Safety (input) | Dealbreaker |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| apple-events | 1.6.2 | 2 | 4 (10/10) | 4 (20/20) | 4 (20/20) | 1 | 4 (48/48) | none observed |
| apple-pim | 3.19.2 | 4 | 3 (19/20) | 3 (34/35) | 4 (42/42) | 2 | 4 (72/72) | none observed |
| imsg | 0.21.0 | 1 | 4 (3/3) | 2 (2/3) | 3 (9/10) | 1 | 4 (24/24) | none observed |
| mac-messages | 1.1.0 | 1 | 4 (3/3) | n/r | 3 (9/10) | 2 | 4 (24/24) | none observed |
| memo | 0.6.2 | 2 | 1 (3/13) | 2 (6/7) | 2 (9/11) | 1 | n/r | none observed |
| pf-mail | 3.3.0 | 1 | 4 (4/4) | 4 (6/6) | 4 (12/12) | 2 | n/r | none observed |
| pippin | pippin 1.0.0 (pippin eb55292, harness 80ac5b9) | 7 | 4 (28/28) | 4 (54/54) | 4 (65/65) | 3 | 4 (120/120) | none observed |
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
| calendar.calendars | 50.3 | 40.4 |  |  |  |  | **5.4** |  |  |  |  |
| calendar.events | 61.0 | 56.6 |  |  |  |  | **17.6** |  |  |  |  |
| calendar.search | 66.7 | 47.3 |  |  |  |  | **23.7** |  |  |  |  |
| contacts.groups |  | 64.1 |  |  |  |  | **32.5** |  |  |  |  |
| contacts.list |  | 117.4 |  |  |  |  | **42.2** |  |  |  |  |
| contacts.search |  | 146.2 |  |  |  |  | **3.0** |  |  |  |  |
| mail.accounts |  | 230.7 |  |  |  | 67.1 | 117.0 |  |  | **53.8** |  |
| mail.list |  | **8.7** |  |  |  | 2132.5 | 42.6 |  |  | 3251.4 |  |
| mail.mailboxes |  | **6.5** |  |  |  | 166.5 | 11.8 |  |  | 516.7 |  |
| mail.search |  | **7.7** |  |  |  | 866.1 | 39.9 |  |  | 1153.1 |  |
| memos.list |  |  |  |  |  |  | **9.3** |  |  |  |  |
| messages.chats |  |  | 103.0 | **1.1** |  |  | 1.9 |  |  |  |  |
| messages.history |  |  | 192.9 | 25.8 |  |  | **4.1** |  |  |  |  |
| messages.search |  |  | 143.1 | 25.4 |  |  | **3.2** |  |  |  |  |
| notes.folders |  |  |  |  | 266.8 |  | **84.2** |  |  |  | 369.4 |
| notes.list |  |  |  |  | 265.6 |  | 166.7 |  |  |  | **153.8** |
| notes.search |  |  |  |  |  |  | 183.3 |  |  |  | **183.2** |
| reminders.list | 53.3 | 50.0 |  |  | 2464.9 |  | **12.9** | 33.6 | 44.2 |  |  |
| reminders.lists | 34.4 | 41.3 |  |  |  |  | **6.4** | 33.5 | 39.3 |  |  |
| reminders.search | 46.8 | 45.1 |  |  |  |  | **8.7** | 33.2 |  |  |  |

## Cold latency, p50 in ms (N = 5, new process per call)

| Operation | apple-events | apple-pim | imsg | mac-messages | memo | pf-mail | pippin | remindctl | reminders-cli | sweetrb-mail | sweetrb-notes |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| calendar.calendars | 132.8 | 115.6 |  |  |  |  | 34.1 |  |  |  |  |
| calendar.events | 163.1 | 139.3 |  |  |  |  | 50.6 |  |  |  |  |
| calendar.search | 179.7 | 123.2 |  |  |  |  | 56.2 |  |  |  |  |
| contacts.groups |  | 141.2 |  |  |  |  | 57.9 |  |  |  |  |
| contacts.list |  | 199.6 |  |  |  |  | 69.7 |  |  |  |  |
| contacts.search |  | 222.5 |  |  |  |  | 56.7 |  |  |  |  |
| mail.accounts |  | 315.0 |  |  |  | 616.1 | 134.8 |  |  | 200.8 |  |
| mail.list |  | 88.4 |  |  |  | 2653.2 | 64.3 |  |  | 3399.1 |  |
| mail.mailboxes |  | 82.8 |  |  |  | 720.0 | 34.9 |  |  | 1396.8 |  |
| mail.search |  | 84.2 |  |  |  | 1382.7 | 63.1 |  |  | 1308.1 |  |
| memos.list |  |  |  |  |  |  | 31.9 |  |  |  |  |
| messages.chats |  |  | 100.9 | 251.5 |  |  | 54.4 |  |  |  |  |
| messages.history |  |  | 213.2 | 277.1 |  |  | 55.3 |  |  |  |  |
| messages.search |  |  | 138.9 | 323.1 |  |  | 55.3 |  |  |  |  |
| notes.folders |  |  |  |  | 266.2 |  | 116.4 |  |  |  | 465.1 |
| notes.list |  |  |  |  | 264.0 |  | 186.4 |  |  |  | 285.1 |
| notes.search |  |  |  |  |  |  | 201.5 |  |  |  | 351.4 |
| reminders.list | 136.6 | 133.0 |  |  | 2461.2 |  | 45.3 | 33.2 | 43.9 |  |  |
| reminders.lists | 127.2 | 120.0 |  |  |  |  | 40.6 | 33.8 | 39.5 |  |  |
| reminders.search | 142.0 | 124.6 |  |  |  |  | 36.6 | 33.2 |  |  |  |

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
- memo, correctness: reminders.list: 1 wrong instant
- memo, reliability: reminders.list x8: 8 ok, 4 distinct
- memo, reliability: reminders.list bad input: reported success
- memo, safety: no search operation to carry a hostile query
- pf-mail, safety: no search operation to carry a hostile query
- reminders-cli, safety: no search operation to carry a hostile query
- sweetrb-mail, correctness: mail.search: 4 missing
- sweetrb-mail, safety: no search operation to carry a hostile query
