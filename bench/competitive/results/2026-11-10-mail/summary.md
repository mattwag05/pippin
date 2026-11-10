# Mail re-run, 2026-11-10

A targeted re-run of the Mail speed stage after pippin-k177, with the same harness, fixture and method as [2026-11-10-amend4](../2026-11-10-amend4/summary.md): `harness/run.py --only pippin,apple-pim,sweetrb-mail,pf-mail --stages manifest,speed`, then `harness/checks.py --only pippin --stages correctness`. Pippin built from commit `402816c` inside the `pippin-bench` VM (macOS 26.6.2, [environment.json](environment.json)). The fixture was reseeded and checked by `fixtures/verify.py` (24 messages) before the run. Only the four Mail tools were run; the other operations' results stand as published.

## Warm p50, ms (30 runs each)

| Operation | Pippin before | Pippin now | Fastest other | Verdict under the tie rule (10 percent or 20 ms) |
| --- | --- | --- | --- | --- |
| mail.accounts | 117.0 | 57.2 | 55.8 (sweetrb-mail) | tie (1.4 ms) |
| mail.mailboxes | 11.8 | 0.4 | 6.5 (apple-pim) | Pippin leads |
| mail.list | 42.6 | 2.5 | 10.0 (apple-pim) | Pippin leads |
| mail.search | 39.9 | 1.7 | 9.1 (apple-pim) | Pippin leads |

Cold p50 (new process per call): accounts 79.9 against 200.8 for sweetrb-mail, mailboxes 29.8 against 89.7, list 63.6 against 91.2, search 58.2 against 94.2 for apple-pim; Pippin is fastest on all four. Every run of every tool returned `ok` (30 of 30 per operation). Raw: [pippin.json](pippin.json), [apple-pim.json](apple-pim.json), [sweetrb-mail.json](sweetrb-mail.json), [pf-mail.json](pf-mail.json).

## Correctness

[pippin.checks.json](pippin.checks.json): all 13 checked operations `ok`, Mail list and search included, with nothing missing, unexpected or duplicated.

## Score

`harness/report.py` over the amend4 run with these four tools' Mail speed entries replaced gives Pippin a Speed score of 4 (it was 3) and leaves every other tool's Speed score unchanged; sweetrb-notes stays at 3. The other axes are unchanged because only the speed stage ran.

## What changed

- `mail_list`, `mail_search`, `mail_mailboxes` and `mail_accounts` run inside the MCP server instead of a `pippin` child. Calls that ask for bodies, semantic search or previews still go to the child (`InProcessToolsTests.testSlowMailReadsDeclineTheInProcessPath`).
- `mail accounts` asks Mail for the names only (one Apple Event; each extra event costs about 15 ms in this VM) and takes email and id from the account cache when Mail reports exactly the cached names and the cache is under an hour old; otherwise it runs the full read and refreshes the cache (`MailAccountsCacheTests.testCachedAccountsOnlyWhenMailReportsTheSameNames`). Known limit: an email address changed without a name change shows the old address for up to an hour.
- The full accounts read makes 3 Apple Events instead of 4: the readiness poll runs only when the first names read comes back empty (`MailAccountsScriptBehaviorTests.testBulkReadReturnsEveryAccountInThreeEvents`).
- Tried and dropped: one `properties()` read for all accounts, which Mail rejects (error -1728).
- Fixture: `make_mail.py` now restarts Dovecot around a reseed. A session left open across the index delete kept serving the old index, and Mail then showed an empty inbox.
