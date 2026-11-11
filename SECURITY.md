# Security

## Reporting a vulnerability

Do not open a public issue with exploit details.

Use the repository's private vulnerability report (the "Security" tab on GitHub, or the equivalent private report on the Forgejo instance that hosts the canonical repository). If the repository does not offer one, open a public issue that says only "I have a security report" and ask for a private channel. Include the pippin version (`pippin --version`), your macOS version, and the steps to reproduce.

This project has no published security email address.

## Supported versions

Only the latest release gets security fixes. Upgrade before you report, if you can.

## Threat model

Pippin lets an AI agent read and change your Mail, Messages, Notes, Contacts, Calendar, Reminders and Voice Memos. The model below is about one case: an agent whose only route to that data is `pippin mcp-server`. The full list of controls, with the test behind each, is in [docs/safety-model.md](docs/safety-model.md).

### Assets

- Mail, messages, notes, contacts, calendar events, reminders and voice memo transcripts.
- The ability to send as you: email through Mail and messages through Messages.
- The action log, the policy file and the local caches (see "Data handling").

### Trust boundaries

| Party | Trust |
| --- | --- |
| You, the human user | Trusted. You write the policy file and approve sends and deletes. |
| The agent and the MCP client | Not trusted to act alone on writes. It may be confused, looping or manipulated. |
| Text read from apps (a mail body, a note, a message, an event title) | Untrusted. Anyone can put text there. |
| The local machine and your user account | Trusted. A process running as you can edit pippin's files. |

### Threats and controls

| Threat | Control | Held by |
| --- | --- | --- |
| Prompt injection through mail, notes, messages or events: the agent reads text that tells it to act. | Results that hold other people's text carry `content_trust: "untrusted"` and `untrusted_fields`. The `initialize` result tells the client to treat them as data. Under the default policy the actions an injection most wants (send, reply, forward, delete) still need a confirm token. See [safety model section 7](docs/safety-model.md#7-untrusted-content). | `UntrustedContentTests.testEveryToolIsClassified`, `UntrustedContentTests.testEveryToolThatReturnsExternalTextCarriesTheMarkerThroughTheDispatcher`, `UntrustedContentTests.testAnErrorIsNotMarkedAndTheServerSaysHowToTreatMarkedFields` |
| The agent sends or deletes without approval. | Every mutating tool goes through `SafetyGate.run`. Sends and deletes return `confirmation_required` and act only on a second call with a single-use token bound to the exact arguments. `messages_send` can only create a draft. See [sections 1 and 2](docs/safety-model.md#2-confirm-tokens). | `SafetyDispatcherTests.testMailSendUnderDefaultPolicyDoesNotActUntilAValidTokenIsPresented`, `SafetyDispatcherTests.testEveryDefaultConfirmToolIsHeldAtTheDispatcher`, `SafetyGateTests.testTokenIsSingleUse`, `SafetyGateTests.testTokenIsBoundToToolAndArguments`, `ToolRegistryTests.testMessagesSendAlwaysDraftAndRequiresToAndBody` |
| A tool the user wants off is called anyway. | `deny` rules in `~/.config/pippin/policy.json` refuse the tool before anything runs. A broken policy file refuses every write. `pippin mcp-server --apps` hides whole tool groups. | `SafetyGateTests.testDenyRefusesBeforeAnythingRuns`, `SafetyGateTests.testABrokenPolicyFileFailsClosedForEveryMutatingTool`, `AppFilterTests.testAHiddenToolCannotBeCalled` |
| A runaway loop sends or deletes in bulk. | Sliding-window rate limits that survive a restart: 10 per hour for each send tool, 30 per hour for each delete tool, set in the policy file. See [section 3](docs/safety-model.md#3-rate-limits). | `SafetyGateTests.testDefaultSendLimitIsTenPerHour`, `SafetyGateTests.testRateLimitIsASlidingWindowThatSurvivesARestart` |
| A write is replayed or duplicated (a retry, a client bug). | `idempotencyKey` returns the first result with `replayed: true` instead of acting again, for 24 hours. A token works once. See [section 6](docs/safety-model.md#6-idempotency-keys). | `SafetyGateTests.testSameKeyAndArgumentsReplaysWithoutActing`, `SafetyGateTests.testSameKeyWithDifferentArgumentsIsAnError`, `SafetyGateTests.testTokenIsSingleUse` |
| Argument injection: a crafted string breaks into a JXA script or the child process argv. | Every call is checked against the tool's input schema, and unknown or mistyped arguments are refused. The child runs through `posix_spawn` with an argv array, not a shell. A NUL in any argument is refused. Strings placed in JXA scripts are escaped, and the script goes to `osascript` on stdin, so its text (which can hold mail or note content) is not in any process listing. `batch` and `job_run` accept only commands that have an MCP tool, and refuse nested dispatch, `--autonomous` and any command the policy gates. | `NextStepTests.testToolsCallRejectsUnknownAndMistypedArguments`, `NULArgumentTests.testNULInAnyStringArgumentIsATypedErrorAndTheServerKeepsAnswering`, `NULArgumentTests.testRunChildRefusesNULInsteadOfTruncatingTheArgument`, `JXAScriptBuilderTests.testListScriptEscapesSpecialCharsInMailbox`, `NotesTests.testJsEscapeSingleQuote`, `BatchCommandTests.testMCPBatchRejectsNestedDispatch`, `BatchCommandTests.testMCPBatchRefusesACommandThePolicyGates` |
| A write whose outcome is unknown (a timeout, a crash). | A timed-out write returns `outcome_unknown`, not a retryable timeout, and points at a read tool. The action log records an intent with no outcome as `outcome_unknown`. A key whose first attempt is unknown is never run again. | `ToolEffectTests.testTimeoutOnMutatingToolIsOutcomeUnknownAndNotRetryable`, `ToolEffectTests.testTimeoutOnUnclassifiedToolFailsClosedAsOutcomeUnknown`, `SafetyGateTests.testAnIntentWithNoOutcomeReadsAsOutcomeUnknown`, `SafetyGateTests.testAKeyWhoseFirstAttemptIsUnknownIsNotRunAgain` |
| Tampering with the action log, or acting without a record. | The log is opened append-only and is mode 0600. The intent line is written before the action. If it cannot be written, the action does not run. Bodies and secrets are logged as a length and a hash. See [section 4](docs/safety-model.md#4-action-log). | `SafetyGateTests.testNoIntentLineNoAction`, `SafetyGateTests.testIntentIsWrittenBeforeTheActionAndOutcomeAfter`, `SafetyGateTests.testBodiesAndSecretsNeverReachTheLog` |

### What Pippin does not defend against

- **An agent with shell access.** Anything that can run `pippin` or `osascript` directly bypasses the MCP gate. The plain CLI has no policy file, no confirm tokens, no rate limits and no action log. It keeps only the gates it had before (`--confirm` on sends, `--force` on deletes, the Messages autonomous-send gate and the Messages audit log).
- **A confirm token is not proof of human approval.** The agent that receives a token can send it straight back. The token forces a preview and a second call. Whether a person is asked is up to the MCP client.
- **The action log is append-only by convention, not tamper-proof.** Nothing signs or chains its lines. A process running as you can edit or delete it, and can edit `policy.json`.
- **Prompt injection itself.** The untrusted marker is a label. Whether a model obeys it is outside pippin's control.
- **Rate limit races.** Two MCP servers acting at the same instant can each count one call and lose the other's.
- **Undo limits.** Sends, deletes and creates cannot be undone. The seven edit inverses have only been run against fakes, not live apps (see "Not verified live" in the safety model).
- **Other people's access to your machine.** Pippin does not encrypt its caches or protect your session. macOS permissions (Automation, Full Disk Access, Contacts, Calendars) are the boundary.

## Data handling

Everything runs on your machine. Pippin has no server and no account. The only network code in the Swift source is the AI provider and embedding clients (`pippin/AIProvider/`, `pippin/MailAIBridge/EmbeddingProvider.swift`), the `doctor` checks that probe the configured provider, and the experimental `browser fetch` command. Helper processes pippin starts are separate programs with their own behavior: `mlx-audio` may download model weights on first use, and the experimental browser runs Playwright.

### Files pippin writes

Paths are verified in the source; the file named in each row defines the location.

| Path | Holds |
| --- | --- |
| `~/.config/pippin/config.json` | Your settings, including AI provider settings and any API key you put there. You write it. |
| `~/.config/pippin/policy.json` | The safety policy. You write it. |
| `~/.config/pippin/mail-cache.db`, `mail-meta.db`, `mail-baseline.db`, `mail-embeddings.db`, `mail-accounts.json` | Mail bodies, message metadata, sender baselines, embeddings and the account list. |
| `~/.config/pippin/contact-index.db` | A contact index. |
| `~/.config/pippin/transcripts.db` | Voice memo transcripts. |
| `~/.config/pippin/triage-rules.json`, `templates/`, `session.json`, `notes-write.lock` | Your triage rules, your templates, REPL state and a Notes write lock. |
| `~/.cache/pippin/jobs/<id>/` | Background job status and stdout and stderr. |
| `~/Library/Caches/pippin/attachments/` | Mail attachments saved when `saveDir` is not given. |
| `~/.local/share/pippin/actions.jsonl`, `rate-limits.json`, `idempotency.json`, `undo/` | The action log, rate-limit counts, idempotency records (these can hold a tool's full result) and undo sidecars, mode 0600. `PIPPIN_STATE_DIR` moves them. |
| `~/.local/share/pippin/messages-audit.jsonl` | Messages reads and sends, with a hash of the body. |
| `~/.local/share/pippin/browser-session` | Browser session data, only with the experimental browser enabled. |

The caches hold private content. Pippin creates its directories mode 0700 and its config, session, cache database, account cache and job files mode 0600, and tightens looser ones from an older version when it opens them (`FileModeTests`). Saved attachments, templates and exported memos keep the default mode. Any process running as you can still read all of it.

Release and `make install` binaries are signed with the hardened runtime, which blocks library injection and debugger attach. They are not notarized. The action log keeps recipients, subjects, titles and ids as plain text.

### What can leave the machine

Features that call an AI provider send the text they work on to that provider. The provider comes from `ai.provider` in `config.json`, or `--provider`. The default is `ollama`.

| Provider | Where it sends data |
| --- | --- |
| `ollama` (default) | `http://localhost:11434` unless you set `ai.ollama.url`. |
| `claude` | `https://api.anthropic.com/v1/messages`. This one is remote. |
| `openai` or `openai-compatible` | The `ai.openai.baseURL` you set; it defaults to `http://localhost:11434/v1`. It is remote only if you point it at a remote host. |

Commands that take a provider include `memos summarize`, `memos capture`, `calendar smart-create`, `calendar agenda`, `reminders smart-create`, `actions extract`, `pippin do` and the mail AI commands (`mail triage`, `mail index`). Mail embeddings use `ollama` or `openai` only. Voice memo transcription uses `mlx-audio` by default, or `apple`, or an `openai`-compatible endpoint if you set `ai.transcription.provider` to it. Check your config before you use a remote provider on mail or messages.

The experimental `browser fetch` command (needs `PIPPIN_EXPERIMENTAL=1`) fetches the URL you give it.
