# Pippin MailAIBridge — Design Spec

**Date:** 2026-03-25
**Status:** Approved (spec review passed, iteration 3)
**Pippin version:** v0.14.1

---

## Problem

Pippin's Apple Mail bridge exposes 12 subcommands for reading, searching, and composing email through JXA automation. It is a capable transport layer but has no intelligence. Email processing for AI agents benefits from four capabilities absent in current tooling:

1. **Semantic search** — finding relevant emails by meaning, not exact keyword matches
2. **Data extraction** — pulling structured facts (dates, amounts, action items) from email bodies automatically
3. **Prompt injection scanning** — detecting and neutralizing adversarial content in inbound email before passing it to an LLM
4. **Smart triage** — classifying and summarizing inbox state to reduce cognitive overhead

Commercial services (LobsterMail, AgentMail) offer these as SaaS APIs aimed at autonomous agent infrastructure. Pippin already integrates with a user's real Apple Mail accounts locally. The right solution is to build these capabilities directly into Pippin using its existing AI provider abstraction, so they work offline (Ollama) or via the cloud (Claude) without surrendering email content to a third-party service.

---

## Goals

- Add semantic search, data extraction, prompt injection scanning, and smart triage to Pippin
- Reuse the existing `AIProvider`/`AIProviderFactory` abstraction — user picks provider via `--provider` flag
- Keep all email data local by default (Ollama); Claude API is an explicit opt-in
- Follow Pippin's bridge-per-concern pattern — existing `MailBridge/` is untouched
- All new capabilities available in `text`, `json`, and `agent` output formats

## Non-Goals

- Provisioning new email addresses (that's LobsterMail/AgentMail's primary purpose)
- Real-time email webhooks or push notifications
- Cloud embedding providers (Voyage AI etc.) — Ollama-only for initial implementation
- Integration with non-Apple mail clients

---

## Architecture

### New `MailAIBridge/` Directory

A new bridge directory that **consumes** `MailBridge` output and adds AI processing on top. MailBridge remains the single source of truth for Apple Mail interaction.

```
pippin/
├── MailBridge/          (untouched)
│   ├── MailBridge.swift
│   ├── MailBridgeRunner.swift
│   ├── MailBridgeHelpers.swift
│   └── MailBridgeScripts.swift
└── MailAIBridge/        (new)
    ├── EmbeddingStore.swift
    ├── EmbeddingProvider.swift
    ├── SemanticSearch.swift
    ├── DataExtractor.swift
    ├── PromptInjectionScanner.swift
    ├── TriageEngine.swift
    └── MailAIPrompts.swift
```

### Command Surface Changes

**New subcommand added to MailCommand:**
- `mail index` — pre-populates the embedding store (see Feature 1)

**Modified flags on existing commands:**

| Command | New flag | Behavior |
|---------|----------|---------|
| `mail search` | `--semantic` | Use embedding similarity instead of JXA keyword matching |
| `mail show` | `--summarize` | Append AI summary to message output |
| `mail show` | `--sanitize` | Scan body for injection threats, return sanitized version |
| `mail list` | `--summarize` | Include one-liner summary per message |

**New subcommands:**

| Command | Description |
|---------|-------------|
| `mail index` | Pre-populate embedding store for semantic search |
| `mail extract <id>` | Extract structured data from a message |
| `mail sanitize <id>` | Full injection scan with detailed threat report |
| `mail triage` | Classify and summarize inbox state |

All new commands and modified commands accept `--provider`, `--model`, `--api-key` as `@Option` fields on the command struct itself (not in `OutputOptions`) plus `--format text|json|agent` via `@OptionGroup var output: OutputOptions`.

**Important:** All new subcommands must be declared as `AsyncParsableCommand` (not `ParsableCommand`) to match the existing `MailCommand` subcommand array type. The entire `MailCommand` tree uses `AsyncParsableCommand`.

---

## Feature Specifications

### Feature 1: Semantic Search + Indexing

**CLI:**
```
pippin mail index [--account X] [--mailbox INBOX] [--limit 500] [--provider ollama]
pippin mail search --semantic <query> [--provider ollama] [--limit N]
```

**`mail index` behavior:**
1. Fetch messages via `MailBridge.listMessages` (subject/sender/date only — no body)
2. For each message: call `MailBridge.readMessage` to get body, compute SHA256 hash, check `EmbeddingStore.needsReindex(compoundId: String, bodyHash: String) -> Bool` — returns `true` if (a) no row exists for the compound ID, or (b) a row exists but `body_hash` differs from the current hash
3. If unindexed or body changed: embed via `OllamaEmbeddingProvider`, upsert into `EmbeddingStore`
4. If `--provider` is not `"ollama"`, throw `MailAIError.unsupportedEmbeddingProvider(providerFlag)`
5. Print progress and total count indexed
6. Default `--limit 500` per run to cap indexing time (~2–5 min for 500 messages with Ollama)

**Swift 6 threading note:** `OllamaEmbeddingProvider.embed()` uses `sendSynchronousRequest()` (DispatchSemaphore-based blocking call). Calling this in a 500-iteration loop from `run() async throws` would block the Swift cooperative thread pool worker for the duration. Wrap each `embed()` call in `Task.detached(priority: .background) { try embed(text:) }` and `await` the result so the blocking work runs off the cooperative pool.

**`mail search --semantic` behavior:**
1. Embed the query string via `OllamaEmbeddingProvider`
2. Scan `EmbeddingStore` for nearest neighbors using brute-force cosine similarity
3. Fetch full `MailMessage` objects for top-N compound IDs via `MailBridge.readMessage`
4. Return messages ranked by similarity score
5. **No lazy indexing during search** — the index must be populated via `mail index` first. If the store is empty, print a clear error: `"Embedding index is empty. Run 'pippin mail index' first."`

**Embedding index schema** (`~/.config/pippin/mail-embeddings.db`):
```sql
CREATE TABLE IF NOT EXISTS email_embeddings (
    compound_id  TEXT PRIMARY KEY,
    embedding    BLOB NOT NULL,     -- [Float32] as raw little-endian bytes (768 floats = 3072 bytes)
    body_hash    TEXT NOT NULL,     -- SHA256 hex of body retrieved via readMessage (not listMessages)
    model        TEXT NOT NULL,     -- "nomic-embed-text"
    indexed_at   TEXT NOT NULL      -- ISO 8601
);
CREATE INDEX IF NOT EXISTS idx_embeddings_indexed_at ON email_embeddings(indexed_at);
```

Note: `body_hash` is computed from the body retrieved via `MailBridge.readMessage`. Messages fetched by `listMessages` do not include body content and cannot be hashed.

**Scale:** 10K emails × 768 float32 = ~30 MB. Brute-force cosine similarity is adequate. No vector extension required.

**Cosine similarity:** `dot(a, b) / (magnitude(a) * magnitude(b))`. Vectors stored as raw `Data` of little-endian `Float` values.

**Database location:** `~/.config/pippin/mail-embeddings.db` (parallel to existing `transcripts.db`)

### Feature 1a: EmbeddingProvider Protocol

`EmbeddingProvider` is a **separate protocol from `AIProvider`** because embeddings have a different return type (`[Float]` vs `String`) and a different HTTP endpoint:

```swift
public protocol EmbeddingProvider: Sendable {
    func embed(text: String) throws -> [Float]
}

public struct OllamaEmbeddingProvider: EmbeddingProvider {
    public let baseURL: String
    public let model: String

    public init(baseURL: String = "http://localhost:11434", model: String = "nomic-embed-text") {
        self.baseURL = baseURL
        self.model = model
    }

    public func embed(text: String) throws -> [Float]
    // POST /api/embed with {"model": model, "input": text}
    // Response: {"embeddings": [[Float]]}
    // Reuses sendSynchronousRequest() from AIProvider.swift
}
```

`EmbeddingProvider` is not wired through `AIProviderFactory` (that factory returns `AIProvider` for completion calls). The embedding provider is constructed directly in `SemanticSearch` and `mail index` based on the `--provider` flag value. For Phase 1, only `"ollama"` is supported; unknown values throw a clear error.

### Feature 2: Data Extraction

**CLI:** `pippin mail extract <compound-id> [--provider ollama] [--format json]`

**Behavior:**
1. Fetch full message via `MailBridge.readMessage`
2. Build prompt from `MailAIPrompts.extractionSystemPrompt` + message body
3. Call `AIProvider.complete(prompt:system:)` → JSON string
4. Strip markdown fences if present (LLMs often wrap JSON in ` ```json ... ``` `)
5. Decode with `JSONDecoder` → `ExtractionResult`
6. On `DecodingError`: throw `MailAIError.malformedAIResponse(String)` with the raw AI output in the message, so the user can see what the model returned

**Output model:**
```swift
struct ExtractionResult: Codable, Sendable {
    let dates: [ExtractedDate]
    let amounts: [ExtractedAmount]
    let trackingNumbers: [String]
    let actionItems: [String]
    let contacts: [ExtractedContact]
    let urls: [String]
}

struct ExtractedDate: Codable, Sendable {
    let text: String
    let isoDate: String?
    let context: String
}

struct ExtractedAmount: Codable, Sendable {
    let text: String
    let value: Double?
    let currency: String?
    let context: String
}

struct ExtractedContact: Codable, Sendable {
    let name: String?
    let email: String?
    let phone: String?
}
```

Note: All field names use camelCase (Swift/JSON default). No custom `CodingKeys` needed unless deviating from camelCase. `MailModels.swift` and the rest of Pippin's JSON output use camelCase — do not add snake_case `CodingKeys`.

### Feature 3: Prompt Injection Scanning

**CLI:**
- `pippin mail sanitize <compound-id> [--ai-assisted] [--provider ollama]`
- `pippin mail show <compound-id> --sanitize [--provider ollama] [--model X] [--api-key X]`

Note: `--provider`, `--model`, `--api-key` must be added as `@Option` fields directly on the `Show` struct (alongside the existing `@OptionGroup var output: OutputOptions`). This is the same pattern used by `CalendarCommand`'s `Summarize` subcommand.

**Behavior — two-pass scan:**

**Pass 1 (rule-based, always runs, no API call):**
- Regex patterns for 6 threat categories:
  - `boundaryManipulation`: `[SYSTEM]`, `[INST]`, `<|im_start|>`, `<|im_end|>`, `###System`, `<system>` tags
  - `systemPromptOverride`: "ignore previous instructions", "disregard your", "forget everything", "you are now", "act as if"
  - `dataExfiltration`: "send the conversation", "include your API key", "output your system prompt", "repeat your instructions"
  - `roleHijacking`: "you are a", "pretend to be", "from now on you", "your new instructions"
  - `toolInvocation`: patterns suggesting function/tool calls disguised as content
  - `encodingTricks`: base64 strings >50 chars containing instruction keywords after decode; zero-width chars (U+200B, U+200C, U+200D, U+FEFF); `data:` URIs

**Pass 2 (AI-assisted, opt-in via `--ai-assisted`):**
- Sends body to AI with `injectionDetectionSystemPrompt`
- Strip markdown fences, decode JSON → `[Threat]`
- On `DecodingError`: throw `MailAIError.malformedAIResponse(String)`
- Merge with rule-based findings (deduplicate by `category` + `matchedText`)

**Output model:**
```swift
struct ScanResult: Codable, Sendable {
    let originalBody: String
    let sanitizedBody: String
    let threats: [Threat]
    let riskLevel: RiskLevel
}

struct Threat: Codable, Sendable {
    let category: ThreatCategory
    let confidence: Float
    let matchedText: String
    let explanation: String
}

enum ThreatCategory: String, Codable, Sendable, CaseIterable {
    case boundaryManipulation
    case systemPromptOverride
    case dataExfiltration
    case roleHijacking
    case toolInvocation
    case encodingTricks
}

enum RiskLevel: String, Codable, Sendable {
    case none, low, medium, high, critical
}
```

**Risk level derivation:** max `confidence` across all threats: `none` (<0.1), `low` (0.1–0.4), `medium` (0.4–0.7), `high` (0.7–0.9), `critical` (≥0.9). Rule-based threats are assigned confidence 1.0 (exact match).

### Feature 4: Smart Triage

**CLI:**
- `pippin mail triage [--account X] [--mailbox INBOX] [--limit 20] [--provider ollama]`
- `pippin mail show <id> --summarize [--provider ollama]`
- `pippin mail list --summarize [--provider ollama]`

**Triage behavior (no `readMessage` calls — subject/sender/date only):**
1. Fetch messages via `MailBridge.listMessages` (subject + sender + date — no body)
2. Batch into groups of ≤10
3. For each batch: call AI with `triageSystemPrompt` (subject + sender + date per message) → strip markdown fences → decode JSON → `[TriagedMessage]` + per-batch `summary` + per-batch `actionItems`
4. On `DecodingError`: throw `MailAIError.malformedAIResponse(String)`
5. **Multi-batch merge (no additional AI call):** After all batches complete, assemble the final `TriageResult` as follows:
   - `messages`: concatenation of all batches' `[TriagedMessage]` arrays
   - `summary`: summary from the **last batch only** (it sees only its 10 messages — this is a known limitation for inboxes >10 messages; document in help text)
   - `actionItems`: union of all batches' `actionItems`, deduplicated by exact string match

**Performance:** `listMessages` is one JXA call. Zero `readMessage` calls. This is important — each `readMessage` triggers a full IMAP body download (~0.5–2s). 20 messages via `listMessages` takes ~1s total.

**`--summarize` on `show`:** Single message: call `MailBridge.readMessage` + `AIProvider.complete` with `singleSummarySystemPrompt`. Appended to the text output; in JSON/agent mode, added as a `"summary"` field.

**`--summarize` on `list`:** Use `TriageEngine` to batch the list results (≤10 per AI call) and return a `oneLiner` per message. This reuses the triage batching path rather than making N individual AI calls. Only the `oneLiner` field from each `TriagedMessage` is surfaced; the batch-level `summary` and `actionItems` are discarded. The `oneLiner` is appended to each message row in text output; added as `"summary"` in JSON/agent mode.

**Output model:**
```swift
struct TriageResult: Codable, Sendable {
    let messages: [TriagedMessage]
    let summary: String
    let actionItems: [String]
}

struct TriagedMessage: Codable, Sendable {
    let compoundId: String
    let subject: String
    let from: String
    let category: TriageCategory
    let urgency: Int
    let oneLiner: String
}

enum TriageCategory: String, Codable, Sendable, CaseIterable {
    case urgent
    case actionRequired
    case informational
    case promotional
    case automated
}
```

---

## Error Handling

A new `MailAIError` enum handles AI-specific failures:

```swift
enum MailAIError: LocalizedError, Sendable {
    case malformedAIResponse(String)   // raw AI output included for debugging
    case emptyEmbeddingIndex           // semantic search on unindexed store
    case embeddingFailed(String)       // Ollama embed call failed
    case unsupportedEmbeddingProvider(String)
}
```

**JSON parsing policy for all AI features:** Strip markdown code fences before decoding. On `DecodingError`, throw `MailAIError.malformedAIResponse` with the raw response string. Do not retry automatically — surface the error to the user so they can retry manually or switch providers.

---

## Prompt Templates

All prompts live in `MailAIPrompts.swift` as static `let` constants. Four prompts:

### `extractionSystemPrompt`
Instructs AI to return JSON with dates/amounts/tracking/action items/contacts/URLs. Specifies exact schema. Includes instruction to return empty arrays (not omit keys) for absent categories.

### `triageSystemPrompt`
Defines 5 categories and 1–5 urgency scale. Requests JSON with per-message classification **AND** overall summary and top action items in the same response (single AI call per batch).

### `singleSummarySystemPrompt`
"Summarize this email in 2–3 sentences. Focus on: who sent it, what they want, any deadlines or action items."

### `injectionDetectionSystemPrompt`
Security-focused prompt describing 6 injection categories. Instructs conservative flagging with confidence scores. Returns `{"threats": []}` for clean emails.

---

## Patterns and Conventions

| Pattern | Source to follow |
|---------|-----------------|
| GRDB store | `TranscriptCache.swift` — `final class`, `DatabaseQueue`, `migrate()` with `CREATE TABLE IF NOT EXISTS` |
| AI provider flags | `AIProviderFactory.make(providerFlag:modelFlag:apiKeyFlag:)` for completion calls |
| HTTP calls | `sendSynchronousRequest()` from `AIProvider.swift` for embedding HTTP call |
| Subcommand shape | `Mark`/`Move` structs in `MailCommand.swift` — all must be **`AsyncParsableCommand`** |
| Model structs | `MailModels.swift` — `Codable + Sendable`, **camelCase** field names (no snake_case CodingKeys unless overriding) |
| Bridge pattern | `enum` with `static` methods, no instances |
| Adding AI flags to existing commands | Add `@Option var provider: String?`, `@Option var model: String?`, `@Option var apiKey: String?` directly on the command struct (see `CalendarCommand.Summarize` for reference) |

---

## Implementation Phases

| Phase | Deliverables | Rationale |
|-------|-------------|-----------|
| 1 | `EmbeddingStore`, `EmbeddingProvider`, `mail index`, tests | Foundation for semantic search; `mail index` provides standalone value |
| 2 | `PromptInjectionScanner`, `MailAIError`, `Sanitize` subcommand, `--sanitize` on Show | Zero AI dependency — ships value immediately |
| 3 | `DataExtractor`, `Extract` subcommand, `MailAIPrompts` (extraction prompt) | Simplest AI feature — single message in, JSON out |
| 4 | `TriageEngine`, `Triage` subcommand, `--summarize` on Show/List, triage/summary prompts | Most complex (batching) — built on Phase 3 JSON parsing patterns |
| 5 | `SemanticSearch`, `--semantic` on Search | Requires Phase 1 infrastructure; intentionally last |

---

## Testing Strategy

- **`MailAIBridgeTests.swift`**: Unit tests for all bridge modules
  - `EmbeddingStore`: in-memory GRDB queue, CRUD round-trips, cosine similarity math, `needsReindex` on hash change
  - `OllamaEmbeddingProvider`: init defaults, vector BLOB serialization round-trip (Float array ↔ Data)
  - `PromptInjectionScanner`: each regex pattern individually, sanitization, risk level derivation, rule-based confidence = 1.0
  - `DataExtractor` + `TriageEngine`: `FakeAIProvider` with canned JSON; also test markdown-fence stripping; test `MailAIError.malformedAIResponse` thrown on bad JSON
  - `SemanticSearch`: test empty-index error path; test ranking order with known cosine scores
  - All result models: encode/decode round-trips
- **`MailAICommandTests.swift`**: ArgumentParser validation tests
  - New subcommands parse correctly (`Extract`, `Sanitize`, `Triage`, `Index`)
  - `Search --semantic` flag parses and routes to `SemanticSearch` branch (not JXA path)
  - `Show --sanitize` and `Show --summarize` flags parse correctly
  - `List --summarize` flag parses correctly
  - `Triage --limit` rejects values < 1
- Estimated: ~45–55 new tests

---

## Verification Checklist

- [ ] `make test` passes (914 existing + ~45–55 new tests)
- [ ] `make lint` passes (swiftformat)
- [ ] `make build` succeeds (Swift 6 strict concurrency, no warnings)
- [ ] `pippin mail index --limit 10 --provider ollama` indexes 10 messages
- [ ] `pippin mail sanitize "<id>"` returns threat assessment
- [ ] `pippin mail sanitize "<id>" --ai-assisted --provider ollama` adds AI findings
- [ ] `pippin mail extract "<id>" --provider ollama` returns structured JSON
- [ ] `pippin mail triage --limit 5 --provider ollama` classifies and summarizes (no readMessage calls)
- [ ] `pippin mail search --semantic "meeting notes" --provider ollama` returns meaning-based results
- [ ] `pippin mail search --semantic "X"` with empty index returns clear error message
- [ ] All new commands work with `--format json` and `--format agent`
