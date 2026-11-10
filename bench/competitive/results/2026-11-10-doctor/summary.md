# Clean machine checks, 2026-11-10

Machine: the disposable `pippin-bench` Tart VM (macOS 26.6.2), seeded with the benchmark fixture (`fixtures/seed.sh`, verified by `fixtures/verify.py`). No Mail account, no Voice Memos recordings, no Ollama, no mlx-audio. Pippin built from branch `claude/registry-generation` inside the VM and granted with `vm/grant.sh` and `vm/grant_ae.sh`.

## `pippin doctor`

[doctor.json](doctor.json): status `ok`, no warnings, exit 0. Every check is `ok` or `skip`. The skips are features this machine has not set up (Mail with no account, Voice Memos never used, Ollama, embeddings, mlx-audio, Playwright) and the ad-hoc code signature of a local build.

## Live schema conformance

`LiveConformanceTests.testEveryReadToolEmitsASchemaValidEnvelopeOnRealData`, run with `PIPPIN_LIVE_CONFORMANCE=1 PIPPIN_LIVE_BIN=<granted binary>`, passed:

```
LiveConformanceTests: error=16 ok=25 ok with data checked=24 refused before running=1
```

Every read tool's stdout was one envelope that fits `docs/schemas/v4/envelope.schema.json`. For the 24 `ok` results whose tool has an output schema, `data` fit that schema too. The 16 `error` results are tools with nothing to return on this machine (Mail has no account, Voice Memos has no database) or tools given a placeholder id that matches nothing; their error envelopes were checked. The first run of this test found that the doctor output schema marked `remediation.shell_command` required although remediations without a command leave it out; the schema generator now samples nested optional objects with their own optionals unset, and 13 output schemas dropped fields that were wrongly required.
