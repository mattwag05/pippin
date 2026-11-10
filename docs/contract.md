# The pippin contract

What an agent or script may rely on, how it is versioned, and which test holds each statement. The tests named here live in `Tests/PippinTests/Contract/` unless a path says otherwise. A statement with no test is listed under "Not enforced by a test" at the end.

## What is covered

- The JSON envelope every command writes to stdout: `docs/schemas/v4/envelope.schema.json`.
- The MCP tools: their names, arguments and effect. One file per tool, `docs/schemas/v4/tools/<tool>.input.schema.json`.
- The shape of `data` for the tools listed with an `output_schema` in `docs/schemas/v4/index.json`.
- Error codes (`error.code`) and process exit codes.

`docs/schemas/v4/index.json` lists every tool with its CLI command, effect, schemas, and which CLI argument each tool argument sets.

## One definition for the CLI and MCP

The ArgumentParser command structs under `pippin/Commands/` are the source. `pippin/MCP/ToolRegistry.swift` is written by hand, and `CLIMCPDriftTests` fails when it disagrees with the commands. The tests run every tool's `buildArgs` and read ArgumentParser's help dump (the data behind `--experimental-dump-help`).

| Statement | Test |
| --- | --- |
| Every tool runs a real CLI command. | `testEveryToolMapsToACLICommand` |
| The argv a tool builds parses with the real command, for the smallest call and for each argument in turn. | `testBuildArgsParsesWithTheRealCommands` |
| Every tool argument sets a CLI argument that the command defines. | `testEverySchemaPropertySetsACLIArgument` |
| A boolean argument sets a flag, an array a repeating argument, an integer or number an argument the parser refuses text for. | `testSchemaTypesMatchCLIArgumentKinds` |
| An argument the CLI requires is required in the tool schema. | `testRequiredCLIArgumentsAreRequiredInTheSchema` |
| An argument with a fixed set of CLI values lists the same set as its `enum`. | `testEnumsMatchCLIAllowedValues` |
| A CLI argument is either reachable from the tool or listed in `CLIMCPDriftTests.cliOnly` with a reason. | `testEveryCLIArgumentIsExposedOrAllowlisted` |
| The allowlists hold no entry that is no longer needed. | `testAllowlistHasNoStaleEntries` |

Two limits. The help dump carries no Swift types, so types are checked by asking the parser to refuse a wrong value, not by reading the declaration. Values the CLI checks in `validate()` (a `--span` of `this`, `future` or `all`) are not in the dump, so the tests cannot compare them with a schema `enum`.

## The envelope

Every command writes exactly one JSON document, the envelope, and a newline to stdout. On failure the envelope has `status: "error"` and the process exits non-zero.

| Statement | Test |
| --- | --- |
| A bad argument to any tool's command gives one schema-valid error envelope and a non-zero exit. Runs the built binary for all tools. | `ConformanceTests.testEveryToolAnswersABadArgumentWithOneErrorEnvelope` |
| A tool call refused before any command runs (a missing argument) gives a schema-valid error envelope. | `ConformanceTests.testEveryToolRefusesMissingArgumentsWithAValidEnvelope` |
| A successful call gives one schema-valid envelope, and `data` fits the tool's output schema. Runs the tools that need no Apple app: `job_list`, `job_run`, `job_wait`, `job_show`, `messages_exclude_list`, `batch`. | `ConformanceTests.testHermeticToolsSucceedWithOneValidEnvelope` |
| The schema accepts every envelope the encoders produce, with and without `warnings`, `partial`, `next_cursor`, `remediation` and each kind of `next_step`. | `SchemaGoldenTests.testEnvelopeSchemaAcceptsEveryEnvelopeShape` |
| The schema refuses a wrong `v`, a missing `data` or `next_step`, `partial: false`, an empty `warnings` and a code that is not snake_case. | `SchemaGoldenTests.testEnvelopeSchemaRejectsBrokenEnvelopes` |
| Exit codes map from error codes as `pippin agent-info` reports them. | `Tests/PippinTests/PippinExitCodeTests.swift` |

The envelope schema allows fields it does not name. Consumers must ignore fields they do not know.

## Schemas and the envelope version

`v` in the envelope is `AGENT_SCHEMA_VERSION` in `pippin/Formatting/AgentOutput.swift`. The schemas for version N live in `docs/schemas/vN/`. The test helpers read the directory name from the constant, so raising the constant fails every golden test until `docs/schemas/v<N+1>/` exists. `SchemaGoldenTests.testEnvelopeSchemaAcceptsEveryEnvelopeShape` also names the current version, as a reminder to keep the old directory as published.

| File | Source | Test |
| --- | --- | --- |
| `envelope.schema.json` | Written by hand. | the two envelope tests above |
| `tools/<tool>.input.schema.json` | Generated from `MCPToolRegistry`. | `SchemaGoldenTests.testInputSchemasMatchRegistry` |
| `tools/<tool>.output.schema.json` | Generated from the payload model: the real encoder's output for a value with every optional field set and one with none. | `SchemaGoldenTests.testOutputSchemasMatchModels`, `testRealEncoderOutputValidatesAgainstCheckedInSchemas` |
| `index.json` | Generated from the registry and the drift probe. | `SchemaGoldenTests.testIndexMatchesRegistry` |

`testEveryToolHasAnOutputSchemaOrAReason` requires each tool to have an output schema or a written reason for lacking one; the reason is in `index.json`. `testNoOrphanSchemaFiles` fails on a schema file whose tool is gone.

Reading an output schema:

- A property in `required` is always present. Any other property may be absent.
- Rows of a tool that takes `fields` have no `required` list. Those tools return a default subset of keys unless `fields` is `all`, and `fields` can drop any key.
- An enum-valued field is typed `string`; its values are not listed.
- A dictionary-valued field is typed `object` with no properties listed.

### Regenerating

```
PIPPIN_UPDATE_SCHEMAS=1 make test
make test
```

The first run rewrites the generated files, the second confirms they are stable. Commit the result with the change that caused it. `envelope.schema.json` is edited by hand.

## Semantic versioning

pippin follows semver for everything under "What is covered".

Breaking, so it needs a major release, and for the envelope a new `v` and schema directory:

- removing or renaming a tool, a tool argument, a CLI command or option that a tool uses, an envelope field, a `data` field that an output schema lists, or an error code;
- changing the JSON type of any of those, or the meaning of an existing value;
- making an optional argument required, or narrowing what an argument accepts (a smaller `enum`, a tighter range or format);
- removing a field from a tool's default row keys;
- changing a tool's effect from read to write;
- changing which exit code an error code maps to.

Additive, so a minor release:

- a new tool, a new optional argument, a new `enum` value for an argument;
- a new optional envelope field or `data` field;
- a new error code for a failure that had none, or that was `unknown_error`;
- a new entry in `warnings`.

Not part of the contract: the wording of `error.message`, `description` text, `warnings` text, `duration_ms` values, the order of object keys, and the content of opaque values (`next_cursor`, ids).

Every change of the first two kinds alters a file under `docs/schemas/`, and the golden tests fail until that file is regenerated. The diff under `docs/schemas/` in a change is therefore the complete list of contract changes it makes: a removed or retyped line is breaking, an added optional one is additive.

## Deprecation

1. Announce it in `CHANGELOG.md` under `Deprecated`, naming the replacement.
2. Mark it: put "Deprecated" and the replacement in the argument's description and set `"deprecated": true` in its schema. `SchemaGoldenTests.testDeprecatedPropertiesAreAnnotated` requires the two together.
3. Keep it working for at least one minor release after the release that announces it. Each call that uses it returns a `warnings` entry naming the replacement.
4. Remove it in a major release.

Nothing is deprecated today.

## Not enforced by a test

- The success path of the tools that need Mail, Messages, Notes, Calendar, Reminders, Contacts, Voice Memos or an AI provider. The tests never start those apps, so for these tools the envelope is checked on the error path only, and their output schemas are checked against the model's encoder, not against a live run.
- The 7 tools without an output schema (`output_schema: null` in `index.json`).
- The list of error codes. No test fails when a code is renamed.
- The deprecation warning in step 3. No argument is deprecated, so no code emits it yet; the first deprecation has to add the warning and a test for it.
- That a breaking change gets a major version. The tests make the change visible as a schema diff; the version number is a release decision.
