# Pippin MailAIBridge — Design Spec

**Date:** 2026-03-25
**Status:** Approved
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
| `mail extract <id>` | Extract structured data from a message |
| `mail sanitize <id>` | Full injection scan with detailed threat report |
| `mail triage` | Classify and summarize inbox state |

All new commands accept `--provider`, `--model`, `--api-key` using `AIProviderFactory` and `--format text|json|agent` via `OutputOptions`.

---

## Feature Specifications

### Feature 1: Semantic Search

**CLI:** `pippin mail search --semantic <query> [--provider ollama] [--limit N]`

**Behavior:**
1. Embed the query string via `OllamaEmbeddingProvider` (`nomic-embed-text`, 768 dimensions)
2. Scan the local embedding index (`~/.config/pippin/mail-embeddings.db`) for nearest neighbors using brute-force cosine similarity
3. Fetch full `MailMessage` objects for the top-N compound IDs via `MailBridge.readMessage`
4. Return messages ranked by similarity score
5. Lazily embed any un-indexed messages encountered during result fetching

**Embedding index schema:**
```sql
CREATE TABLE IF NOT EXISTS email_embeddings (
    compound_id  TEXT PRIMARY KEY,
    embedding    BLOB NOT NULL,     -- [Float32] as raw little-endian bytes
    body_hash    TEXT NOT NULL,     -- SHA256 hex of body text (for change detection)
    model        TEXT NOT NULL,     -- "nomic-embed-text"
    indexed_at   TEXT NOT NULL      -- ISO 8601
);
CREATE INDEX IF NOT EXISTS idx_embeddings_indexed_at ON email_embeddings(indexed_at);
```

**Scale:** 10K emails × 768 float32 = ~30 MB. Brute-force cosine similarity is adequate at this scale. No vector extension required.

**Cosine similarity:** Implemented in Swift as `dot(a, b) / (magnitude(a) * magnitude(b))`. Vectors stored as raw `Data` containing little-endian `Float` values.

**Database location:** `~/.config/pippin/mail-embeddings.db` (parallel to existing `transcripts.db`)

### Feature 2: Data Extraction

**CLI:** `pippin mail extract <compound-id> [--provider ollama] [--format json]`

**Behavior:**
1. Fetch full message via `MailBridge.readMessage`
2. Build prompt from `MailAIPrompts.extractionSystemPrompt` + message body
3. Call `AIProvider.complete(prompt:system:)` → JSON string
4. Parse into `ExtractionResult`

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
    let isoDate: String?      // YYYY-MM-DD if parseable
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

### Feature 3: Prompt Injection Scanning

**CLI:**
- `pippin mail sanitize <compound-id> [--ai-assisted] [--provider ollama]`
- `pippin mail show <compound-id> --sanitize`

**Behavior — two-pass scan:**

**Pass 1 (rule-based, always runs, no API call):**
- Regex patterns for 6 threat categories:
  - `boundaryManipulation`: `[SYSTEM]`, `[INST]`, `<|im_start|>`, `<|im_end|>`, `###System`, `<system>` tags
  - `systemPromptOverride`: "ignore previous instructions", "disregard your", "forget everything", "you are now", "act as if"
  - `dataExfiltration`: "send the conversation", "include your API key", "output your system prompt", "repeat your instructions"
  - `roleHijacking`: "you are a", "pretend to be", "from now on you", "your new instructions"
  - `toolInvocation`: patterns suggesting function/tool calls disguised as content
  - `encodingTricks`: base64 strings > 50 chars containing instruction keywords after decode; zero-width chars (U+200B, U+200C, U+200D, U+FEFF); `data:` URIs

**Pass 2 (AI-assisted, opt-in via `--ai-assisted`):**
- Sends body to AI with `injectionDetectionSystemPrompt`
- AI identifies additional threats with confidence scores
- Merged with rule-based findings (deduplication by category + matched text)

**Output model:**
```swift
struct ScanResult: Codable, Sendable {
    let originalBody: String
    let sanitizedBody: String       // rule-based threats stripped/escaped
    let threats: [Threat]
    let riskLevel: RiskLevel        // derived from max threat confidence
}

struct Threat: Codable, Sendable {
    let category: ThreatCategory
    let confidence: Float           // 0.0–1.0
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

**Risk level derivation:** Based on max `confidence` across all threats: `none` (<0.1), `low` (0.1–0.4), `medium` (0.4–0.7), `high` (0.7–0.9), `critical` (≥0.9).

### Feature 4: Smart Triage

**CLI:**
- `pippin mail triage [--account X] [--mailbox INBOX] [--limit 20] [--provider ollama]`
- `pippin mail show <id> --summarize [--provider ollama]`
- `pippin mail list --summarize [--provider ollama]`

**Triage behavior:**
1. Fetch messages via `MailBridge.listMessages`
2. Batch into groups of ≤10 (subject + sender + date snippet per message)
3. For each batch: call AI with `triageSystemPrompt` → parse JSON classifications
4. Aggregate: generate overall summary + extract top action items

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
    let urgency: Int              // 1–5
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

## Prompt Templates

All prompts live in `MailAIPrompts.swift` as static `let` constants. Four prompts:

### `extractionSystemPrompt`
Instructs AI to return JSON with dates/amounts/tracking/action items/contacts/URLs. Specifies exact schema. Includes instruction to return empty arrays (not omit keys) for absent categories.

### `triageSystemPrompt`
Defines the 5 categories and 1–5 urgency scale. Requests JSON with per-message classification, overall summary, and top action items.

### `singleSummarySystemPrompt`
"Summarize this email in 2–3 sentences. Focus on: who sent it, what they want, any deadlines or action items."

### `injectionDetectionSystemPrompt`
Security-focused prompt describing 6 injection categories. Instructs conservative flagging with confidence scores. Returns `{"threats": []}` for clean emails.

---

## Patterns and Conventions

| Pattern | Source to follow |
|---------|-----------------|
| GRDB store | `TranscriptCache.swift` — `final class`, `DatabaseQueue`, `migrate()` with `CREATE TABLE IF NOT EXISTS` |
| AI provider flags | `AIProviderFactory.make(providerFlag:modelFlag:apiKeyFlag:)` |
| HTTP calls | `sendSynchronousRequest()` from `AIProvider.swift` |
| Subcommand shape | `Mark`/`Move` structs in `MailCommand.swift` — `@Argument`, `@OptionGroup var output: OutputOptions` |
| Model structs | `MailModels.swift` — `Codable + Sendable`, `CodingKeys` with snake_case |
| Bridge pattern | `enum` with `static` methods, no instances |

---

## Implementation Phases

| Phase | Deliverables | Rationale |
|-------|-------------|-----------|
| 1 | `EmbeddingStore`, `EmbeddingProvider`, tests | Foundation for semantic search |
| 2 | `PromptInjectionScanner`, `Sanitize` subcommand, `--sanitize` on Show | Zero AI dependency — ships value immediately |
| 3 | `DataExtractor`, `Extract` subcommand | Single-message in → structured JSON out — simplest AI feature |
| 4 | `TriageEngine`, `Triage` subcommand, `--summarize` on Show/List | Most complex (batching, aggregation) — benefits from Phase 3 patterns |
| 5 | `SemanticSearch`, `--semantic` on Search | Requires Phase 1 infrastructure to be stable |

---

## Testing Strategy

- **`MailAIBridgeTests.swift`**: Unit tests for all bridge modules
  - `EmbeddingStore`: in-memory GRDB queue, CRUD round-trips, cosine similarity math, hash change detection
  - `PromptInjectionScanner`: each regex pattern individually, sanitization, risk level derivation
  - `DataExtractor` + `TriageEngine`: `FakeAIProvider` (existing in test suite) with canned JSON responses
  - All result models: encode/decode round-trips
- **`MailAICommandTests.swift`**: ArgumentParser validation tests for new flags and subcommands
- Estimated: ~40–50 new tests

---

## Verification Checklist

- [ ] `make test` passes (914 existing + ~40–50 new tests)
- [ ] `make lint` passes (swiftformat)
- [ ] `make build` succeeds (Swift 6 strict concurrency, no warnings)
- [ ] `pippin mail sanitize "<id>"` returns threat assessment
- [ ] `pippin mail sanitize "<id>" --ai-assisted --provider ollama` adds AI findings
- [ ] `pippin mail extract "<id>" --provider ollama` returns structured JSON
- [ ] `pippin mail triage --limit 5 --provider ollama` classifies and summarizes
- [ ] `pippin mail search --semantic "meeting notes" --provider ollama` returns meaning-based results
- [ ] All new commands work with `--format json` and `--format agent`
