---
name: pippin-output-validator
description: Build pippin and validate that a subcommand's JSON output matches its documented schema. Run after implementation changes to verify the external contract is intact.
---

Given the subcommand to validate (e.g., `mail list`, `mail read <id>`, `memos list`):

## Step 1: Build the Binary

```bash
BUILT_DIR=$(xcodebuild -scheme pippin -showBuildSettings 2>/dev/null | awk '/BUILT_PRODUCTS_DIR/{print $3}')
xcodebuild -scheme pippin build -quiet
BINARY="$BUILT_DIR/pippin"
echo "Binary: $BINARY"
$BINARY --help
```

If build fails, stop and report the errors. Do not attempt to validate against a stale binary.

## Step 2: Run the Subcommand

For **read operations**:
```bash
time $BINARY <subcommand> [args] 2>/tmp/pippin-stderr.txt
```

For **write operations** — always use `--dry-run`:
```bash
time $BINARY <subcommand> [args] --dry-run 2>/tmp/pippin-stderr.txt
```

Capture both stdout (expected JSON) and stderr (should be empty on success).

## Step 3: Validate JSON Structure

Parse the stdout as JSON and compare against the schema in CLAUDE.md:

**mail list / search** — array of:
```
{ id, account, mailbox, subject, from, to[], date (ISO8601), read }
```

**mail read** — single object:
```
{ id, account, mailbox, subject, from, to[], date (ISO8601), read, body }
```

**memos list** — array of:
```
{ id, title, duration_seconds, created_at (ISO8601), file_path, transcription }
```

Check:
- [ ] Output is valid JSON (not truncated, no trailing garbage)
- [ ] All required fields present in every object
- [ ] No extra fields (schema drift)
- [ ] `date` / `created_at` fields parse as ISO 8601
- [ ] `to` is an array, not a string
- [ ] Stderr is empty (no warnings leaking to stderr)

## Step 4: Performance Check

Report elapsed time from `time` output vs targets:
- `pippin mail *`: target `< 3 seconds`
- `pippin memos *`: target `< 2 seconds`

Flag if over target.

## Step 5: Report

```
Subcommand: pippin <subcommand>
Build: PASS / FAIL
JSON valid: ✅ / ❌
Schema match: ✅ EXACT / ⚠️ EXTRA FIELDS: [...] / ❌ MISSING: [...]
Stderr clean: ✅ / ❌ (content: ...)
Performance: Xs (target: Ys) ✅ / ⚠️ OVER TARGET
```
