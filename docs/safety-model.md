# Safety model

What stands between an MCP client and a change to your mail, messages, calendar, reminders, notes and contacts. Each claim below names the test that proves it, as `File.testName`. The test files are in `Tests/PippinTests/Safety/` unless a path is given.

## Scope: MCP only

Every control on this page is enforced in one place: `SafetyGate.run`, which `MCPDispatcher.makeToolCallResponse` (`pippin/MCP/MCPServerRuntime.swift`) calls for any tool whose `effect` is not `.readOnly`. A tool nobody classified counts as mutating.

- Every mutating tool passes through it: `SafetyDispatcherTests.testEveryMutatingToolIsLoggedAtTheOneChokepoint`, `SafetyDispatcherTests.testAnUnclassifiedToolGoesThroughTheGate`.

The plain CLI does not pass through it. `pippin mail send --confirm` typed in a terminal is not checked against the policy, needs no token, is not rate limited and is not written to the action log. The CLI keeps the gates it already had (`--confirm` on sends, `--force` on deletes, the Messages autonomous-send gate and the Messages audit log). What the CLI adds here is read access and undo: `pippin policy show`, `pippin log`, `pippin undo`.

| Control | MCP tools | Plain CLI |
| --- | --- | --- |
| Policy file | yes | no |
| Confirm tokens | yes | no |
| Rate limits | yes | no |
| Action log | written | read only (`pippin log`) |
| Undo | yes (`undo`) | yes (`pippin undo`), for actions the MCP server logged |
| Idempotency keys | yes | no |

## What this does not protect against

- **An agent with a shell.** Anything that can run `pippin` directly, or `osascript`, bypasses every control here. These controls bound an agent whose only route to your data is the MCP server.
- **A token is not human approval.** The agent that receives a confirm token can send it straight back. The token forces a two-step commit, bound to the exact arguments and preceded by a preview, and it gives the host application a defined point at which to ask a person. Whether a person is asked is up to the host.
- **The policy file is not protected from the agent's user account.** It is a file in your home directory. A process running as you can edit it. The MCP server offers no tool that writes it.
- **The log is not tamper proof.** It is opened append-only and is mode 0600, so pippin never rewrites a line and other users cannot read it. A process running as you can still edit or delete the file. Nothing signs or chains the lines.
- **Prompt injection.** Mail bodies, message text and note bodies are returned as they are, with no marker that they are untrusted data (see "Untrusted content" below).
- **Rate limit races.** Two MCP servers acting in the same instant can each count one call and lose the other's. The limit is a brake, not an exact quota.

## 1. Policy file

`~/.config/pippin/policy.json` (`PIPPIN_POLICY` overrides the path).

```json
{
  "rules": { "mail_send": "confirm", "messages_*": "deny", "*": "allow" },
  "limits": { "mail_send": { "max": 5, "per_seconds": 3600 } }
}
```

A key is an MCP tool name, a prefix ending in `*`, or `*`. A rule is `allow`, `deny` or `confirm`.

- The most specific key wins: exact name, then the longest prefix, then `*`. `SafetyPolicyTests.testMostSpecificRuleWins`
- A tool no key matches keeps its built-in rule. `SafetyPolicyTests.testAToolNoRuleMatchesKeepsItsDefault`
- With no file, the built-in policy applies: reads allow; `mail_send`, `mail_reply`, `mail_forward`, `messages_send` and every `*_delete` tool confirm; other writes allow. `SafetyPolicyTests.testMissingFileIsTheBuiltInPolicy`
- `deny` returns `policy_denied`, not retryable, before anything runs. `SafetyGateTests.testDenyRefusesBeforeAnythingRuns`, `SafetyDispatcherTests.testDenyAndRateLimitEnvelopes`
- `deny` applies to read tools too. `confirm` on a read tool means `allow`. `SafetyPolicyTests.testConfirmOnAReadMeansAllowAndDenyStillDenies`, `SafetyGateTests.testDenyAppliesToReads`
- A file that exists but cannot be used (bad JSON, an unknown key, an unknown rule, a key that matches no tool, a bad limit) raises `invalid_policy`, and the message names the file. `SafetyPolicyTests.testAFileThatCannotBeUsedThrowsNamingTheFile`
- While the file is broken, every mutating tool is refused. Reads still work. `SafetyGateTests.testABrokenPolicyFileFailsClosedForEveryMutatingTool`
- `pippin policy show` and the `policy_show` tool report the rule and limit for every tool, and where each came from. `SafetyPolicyTests.testPolicyReportShowsTheEffectivePolicy`, `SafetyPolicyTests.testPolicyReportForABrokenFileDeniesEveryWrite`
- `pippin doctor` fails its "Policy file" check on a broken file. `SafetyPolicyTests.testDoctorReportsABrokenPolicyFile`

`batch` and `job_run` run a command without the dispatcher's gate. So under MCP they refuse, with `direct_call_required`, any command whose tool the policy denies, confirms or rate limits (unless the entry passes `--dry-run`), and they refuse `undo`. `BatchCommandTests.testMCPBatchRefusesACommandThePolicyGates` (`Tests/PippinTests/BatchCommandTests.swift`). A write the policy allows without a limit still runs inside a batch, and is logged only as one `batch` action.

## 2. Confirm tokens

For a tool whose rule is `confirm`:

1. The first call does not act. It runs the tool's own preview where one exists (`--dry-run`), and returns `confirmation_required` with `details.confirmToken`, `details.summary` (the tool and its arguments, bodies shown as lengths), `details.expires_at` (5 minutes) and `details.preview`.
2. The second call passes the same arguments plus `confirmToken`, and acts.

- Nothing but the preview runs until a valid token arrives. `SafetyDispatcherTests.testMailSendUnderDefaultPolicyDoesNotActUntilAValidTokenIsPresented`, `SafetyGateTests.testFirstCallPreviewsAndReturnsATokenSecondCallActs`
- Every tool that confirms by default is held. `SafetyDispatcherTests.testEveryDefaultConfirmToolIsHeldAtTheDispatcher`
- A token is bound to the tool name and a hash of the arguments. `SafetyGateTests.testTokenIsBoundToToolAndArguments`
- A token works once. `SafetyGateTests.testTokenIsSingleUse`
- A token expires after 5 minutes. `SafetyGateTests.testTokenExpiresAfterFiveMinutes`
- Tokens live in server memory only, are never written to disk, and do not survive a restart. `SafetyGateTests.testUnknownTokenAndRestartedServerAreRefused`
- A delete has no preview, and the token stands in for `confirm: true`. `SafetyGateTests.testDeleteNeedsATokenAndHasNoPreview`
- An explicit `dryRun: true` or `confirm: false` only previews, and needs no token. `SafetyGateTests.testAnExplicitDryRunOrConfirmFalseOnlyPreviews`
- `confirmToken` and `idempotencyKey` are in the schema of every mutating tool and of no read tool. `SafetyDispatcherTests.testToolsListAdvertisesReservedArgumentsOnMutatingToolsOnly`, `SafetyDispatcherTests.testReadsAreNotLoggedAndDoNotTakeReservedArguments`

Errors: `confirm_token_invalid`, `confirm_token_reused`, `confirm_token_expired`, `confirm_token_mismatch`.

The `confirm` argument is not part of the hash, so the second call may pass it or leave it out.

## 3. Rate limits

A sliding window per tool. Defaults: 10 per hour for each send tool, 30 per hour for each delete tool, none for anything else, never for reads. `limits` in the policy file overrides them, with the same key matching as rules.

- Defaults and overrides. `SafetyPolicyTests.testDefaultLimitsCoverSendsAndDeletesOnly`, `SafetyPolicyTests.testLimitFromFileOverridesDefaultAndReadsAreNeverLimited`, `SafetyGateTests.testDefaultSendLimitIsTenPerHour`
- The window slides, the count is read from `rate-limits.json` (mode 0600) so it survives a restart, and a dry run is not counted. `SafetyGateTests.testRateLimitIsASlidingWindowThatSurvivesARestart`
- Over the limit returns `rate_limited`, retryable, with `next_step.retry_after_seconds`. `SafetyDispatcherTests.testDenyAndRateLimitEnvelopes`
- The limit is checked before a token is issued. `SafetyGateTests.testTheRateLimitIsCheckedBeforeATokenIsIssued`

Only calls that reach the action count. A refused or previewed call does not.

## 4. Action log

`~/.local/share/pippin/actions.jsonl` (`PIPPIN_STATE_DIR` moves the directory). One JSON object per line, mode 0600, opened with `O_APPEND`. Each mutating tool call writes an `intent` line before anything runs and an `outcome` line after. Reads are not logged.

Fields: `ts` (ISO 8601), `id`, `phase`, `tool`, `args` (intent only), `rule`, `outcome`, `error_code`, `undo`, `idempotency_key`.

Outcomes: `success`, `failed`, `outcome_unknown`, `refused`, `dry_run`, `denied`, `confirmation_required`, `rate_limited`, `replayed`.

- The intent line is on disk while the action runs, the outcome follows, and every outcome carries `undo`. `SafetyGateTests.testIntentIsWrittenBeforeTheActionAndOutcomeAfter`
- If the intent line cannot be written the call is refused with `audit_log_unavailable` and nothing runs. `SafetyGateTests.testNoIntentLineNoAction`
- Bodies, free text and secrets are logged as a length and a SHA-256, never as text. So is any argument the tool's schema does not declare, any string over 256 characters, and anything after `--` in a `job_run` argv. `SafetyGateTests.testBodiesAndSecretsNeverReachTheLog`
- Every refusal is logged with its outcome and error code. `SafetyGateTests.testEveryRefusalIsLoggedWithItsOutcome`
- A timed out action is logged `outcome_unknown`. `SafetyGateTests.testATimeoutIsLoggedAsOutcomeUnknown`
- An intent with no outcome line (the server died, or the action is still running) reads as `outcome_unknown`. `SafetyGateTests.testAnIntentWithNoOutcomeReadsAsOutcomeUnknown`
- `pippin log` and the `action_log` tool list actions newest first, with `--limit`, `--since`, `--tool` and cursor paging. `SafetyGateTests.testLogEntriesMergeFilterAndPage`

Redaction goes by argument name: `body`, `text`, `notes`, `content`, `message`, `description`, `prompt`, and any name containing `body`, `apikey`, `token`, `secret`, `password` or `credential`. Recipients, subjects, titles, ids and mailbox names are logged as they are, so the log itself is private data.

### The Messages audit log

`~/.local/share/pippin/messages-audit.jsonl` is kept, side by side. It is written by the `pippin messages` commands themselves, so it also covers Messages reads and sends made from the plain CLI, which the action log never sees. An MCP `messages_send` appears in both. The two files share one writer (`AppendOnlyFile`), so their append and permission behavior cannot drift apart.

## 5. Undo

`pippin undo <action-id>` and the `undo` tool reverse one logged action. The `undo` tool is itself a mutating tool: gated by policy and logged. `UndoTests.testTheUndoToolIsItselfGatedAndLogged`

Every outcome line says `undo: {"supported": true}` or `{"supported": false, "reason": "..."}`. The inverse and the prior values are saved in `undo/<action-id>.json` beside the log, mode 0600, not in the log line.

| Tool | Inverse | Proof |
| --- | --- | --- |
| `mail_move` | Move back to the source mailbox. The message is found in the destination by its Message-ID, since Mail gives it a new row id | `UndoTests.testUndoMailMoveMovesBackFindingTheMessageByMessageID`, `MailMessageScriptBehaviorTests.testMoveCanLocateTheMessageByMessageID`, `MailMessageScriptBehaviorTests.testMoveReportsTheResolvedDestinationAndTheMessageID` |
| `mail_mark` | Restore the previous read state | `UndoTests.testUndoMailMarkRestoresThePreviousReadState`, `MailMessageScriptBehaviorTests.testMarkReportsThePreviousReadStateAndTheMessageID` |
| `reminders_complete` | Mark not completed (`reminders complete --incomplete`) | `UndoTests.testUndoRemindersCompleteUncompletes` |
| `reminders_edit` | Write back the prior value of each field the call set | `UndoTests.testUndoRemindersEditRestoresPriorFields` |
| `calendar_edit` | Write back prior title, start, end, calendar, location, notes, url | `UndoTests.testUndoCalendarEditRestoresPriorFields` |
| `notes_edit` | Write back the prior title and HTML body | `UndoTests.testUndoNotesEditRestoresThePriorBodyFromA0600Sidecar` |
| `contacts_edit` | Write back prior names, organization, job title, and a single email or phone | `UndoTests.testUndoContactsEditRestoresPriorFields` |

The script tests are in `Tests/PippinTests/MailMessageScriptBehaviorTests.swift`. All of the above run against fakes; see "Not verified live".

- Before running the inverse, undo reads the target again and compares a hash of the fields the action set with their hash right after the action. If they differ it refuses with `undo_target_changed`. `UndoTests.testUndoRefusesWhenTheTargetChangedSinceTheAction`. For mail the inverse carries `--expect-message-id`, so the script that writes also checks the message's identity; the read state itself is not compared.
- An action is undone at most once. `UndoTests.testUndoRemindersCompleteUncompletes`
- Sends, deletes, creates and tools with no defined inverse are labeled `supported: false` with a reason, and undo returns `undo_not_supported`. `UndoTests.testIrreversibleActionsSayWhy`
- Cases that are not undoable although the tool is: a call that changed nothing (`UndoTests.testCompletingAnAlreadyCompletedReminderIsNotUndoable`, `UndoTests.testAMarkThatChangedNothingIsNotUndoable`); a field that was empty and that pippin cannot clear, such as a due date or url (`UndoTests.testAFieldPippinCannotClearMakesTheEditNotUndoable`); a recurring event, or an edit that sets `span`, `occurrence`, `alert` or all-day (`UndoTests.testRecurringAndSeriesCalendarEditsAreNotUndoable`); a contact that had zero or several emails or phones, because `contacts edit` replaces them all with one (`UndoTests.testReplacingSeveralAddressesIsNotUndoable`); a message with no Message-ID (`UndoTests.testAMoveWithNoMessageIDIsNotUndoable`); a note body over 200,000 bytes (`UndoTests.testAVeryLargeNoteBodyIsNotUndoable`).
- An unknown id is `action_not_found`. A failed inverse is `undo_failed` and leaves the action undoable. `UndoTests.testUnknownActionIdIsATypedError`, `UndoTests.testAFailedInverseIsReportedAndTheActionStaysUndoable`
- An undo cannot itself be undone.

Capturing the prior state costs one extra read before and one after each undoable edit (reminders, calendar, contacts, notes). Mail captures it inside the same script that acts.

Known limits of the inverses: a restored contact email or phone gets the label `contacts edit` always writes (work, mobile), not its old label. A restored note body is the HTML Notes reported before the edit; Notes may normalize it when it is written back.

### Not verified live

No test may touch a real app, so every inverse above is proven against a fake: a stateful stand-in for the child `pippin`, and for Mail the generated JXA run in JavaScriptCore against a fake Mail. Each argv the dispatcher and undo produce is also parsed by the real CLI command it names. None of the seven inverses has been run against the real Mail, Reminders, Calendar, Notes or Contacts. In particular, unproven live: that Mail's `whose({messageId: ...})` finds a moved message in its destination mailbox, and how soon after an IMAP move; and that `notes show --html` followed by `notes edit --html` restores a formatted note faithfully.

## 6. Idempotency keys

Every mutating tool accepts an optional `idempotencyKey` (1 to 128 characters). Records are kept for 24 hours in `idempotency.json` beside the log, mode 0600.

- The same key with the same arguments returns the first result with `replayed: true` and does not act, also after a server restart. After 24 hours the key is forgotten. `SafetyGateTests.testSameKeyAndArgumentsReplaysWithoutActing`, `SafetyDispatcherTests.testIdempotentReplayThroughTheDispatcher`
- The same key with different arguments, or a different tool, is `idempotency_key_conflict`. `SafetyGateTests.testSameKeyWithDifferentArgumentsIsAnError`
- A key whose first attempt timed out, or was cut short, returns `outcome_unknown` saying so, and is not run again. `SafetyGateTests.testAKeyWhoseFirstAttemptIsUnknownIsNotRunAgain`
- A first attempt that failed cleanly frees the key. `SafetyGateTests.testACleanFailureFreesTheKey`

The stored result is the tool's full answer, so `idempotency.json` can hold whatever that tool returns.

## Untrusted content

Nothing pippin returns is marked as untrusted data today. Mail bodies, subjects and sender names, message text, note titles and bodies, calendar and reminder titles and notes, and contact notes all come back as plain fields beside pippin's own. There is no marker field on the envelope and no per-field annotation. The only related feature is `mail_sanitize`, which scans one message for injection patterns when asked.

Marking is not a small change at the envelope layer: results are typed per command, and the envelope does not know which fields hold third-party text. It is listed as follow-up work.
