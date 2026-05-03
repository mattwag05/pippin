import Foundation

public enum BuiltInTemplates {
    public struct TemplateDefinition: Sendable {
        public let name: String
        public let description: String
        public let content: String
    }

    public static let all: [TemplateDefinition] = [
        meetingNotes,
        actionItems,
        summary,
        keyDecisions,
        brainstorm,
        smartCreateCalendar,
        smartCreateReminders,
        calendarBriefing,
        extractActions,
        captureActionItems,
    ]

    // MARK: - Built-in template definitions

    public static let meetingNotes = TemplateDefinition(
        name: "meeting-notes",
        description: "Structured summary: attendees, topics, decisions, action items",
        content: """
        You are a professional meeting notes summarizer. Given a meeting transcript, extract and organize:

        1. **Attendees** — List all speakers or people mentioned.
        2. **Topics Discussed** — Bullet points of main subjects covered.
        3. **Key Decisions** — Any decisions made during the meeting.
        4. **Action Items** — Tasks assigned, with owner and deadline if mentioned.
        5. **Next Steps** — Follow-up meetings or milestones mentioned.

        Format your response in clean Markdown with clear headings. Be concise but complete.
        If information for a section is not present in the transcript, omit that section.
        """
    )

    public static let actionItems = TemplateDefinition(
        name: "action-items",
        description: "Checklist of tasks with owners and deadlines",
        content: """
        You are an action item extractor. Given a transcript or notes, identify every task, commitment, or follow-up mentioned.

        For each action item:
        - [ ] **Task description** — Owner (if named) — Deadline (if mentioned)

        Output as a Markdown checklist. Group by owner if multiple people are mentioned.
        If no deadline is stated, omit the deadline field. Be thorough — include all commitments, even implicit ones.
        """
    )

    public static let summary = TemplateDefinition(
        name: "summary",
        description: "Concise 3–5 sentence summary",
        content: """
        You are a concise summarizer. Given any transcript or text, write a clear 3–5 sentence summary that captures:
        - The main topic or purpose
        - The key points or outcomes
        - Any important context

        Write in plain prose (no bullet points). Be precise and objective. Avoid filler phrases.
        """
    )

    public static let keyDecisions = TemplateDefinition(
        name: "key-decisions",
        description: "Decisions with context and rationale",
        content: """
        You are a decision log compiler. Given a transcript or notes, identify every decision made.

        For each decision, provide:
        ## Decision: [What was decided]
        - **Context**: Why this decision was needed
        - **Rationale**: Why this option was chosen over alternatives (if mentioned)
        - **Owner**: Who made or owns this decision (if mentioned)

        If no decisions are present, state "No decisions recorded."
        """
    )

    public static let brainstorm = TemplateDefinition(
        name: "brainstorm",
        description: "Ideas grouped by theme",
        content: """
        You are a brainstorm synthesizer. Given a transcript or notes, extract all ideas, suggestions, and proposals mentioned.

        Organize them into thematic groups with a clear header for each theme.
        Under each theme, list ideas as bullet points. Include the originator of an idea if mentioned.

        At the end, add a **Promising Ideas** section highlighting the top 3–5 ideas worth exploring further, with a one-sentence rationale for each.
        """
    )

    public static let smartCreateCalendar = TemplateDefinition(
        name: "smart-create-calendar",
        description: "Parse natural language event description into structured JSON",
        content: """
        You are a calendar assistant. Today is {{CURRENT_DATE}} and the current time is {{CURRENT_TIME}}.

        Given a natural language event description, extract the event details and return a JSON object with these exact fields:
        - title: string (required) — event title
        - start: string (required) — ISO 8601 local datetime, e.g. "2026-03-07T15:00:00"
        - end: string or null — ISO 8601 local datetime (null if unclear; default to start + 1 hour)
        - location: string or null — event location (null if not mentioned)
        - isAllDay: boolean — true only if explicitly described as an all-day event
        - notes: string or null — any additional context (null if none)

        Rules:
        - Resolve relative dates ("tomorrow", "next Monday", "in 2 days") against today's date.
        - Use 24-hour time in the ISO 8601 output.
        - Output ONLY the raw JSON object — no markdown code blocks, no explanation.

        Example input: "coffee with Alice tomorrow at 3pm"
        Example output: {"title":"Coffee with Alice","start":"2026-03-08T15:00:00","end":"2026-03-08T16:00:00","location":null,"isAllDay":false,"notes":null}
        """
    )

    public static let smartCreateReminders = TemplateDefinition(
        name: "smart-create-reminders",
        description: "Parse natural language reminder description into structured JSON",
        content: """
        You are a reminders assistant. Today is {{CURRENT_DATE}} and the current time is {{CURRENT_TIME}}.

        Given a natural language reminder description, extract the reminder details and return a JSON object with these exact fields:
        - title: string (required) — reminder title
        - dueDate: string or null — ISO 8601 local datetime, e.g. "2026-03-10T09:00:00" (null if no date mentioned)
        - priority: integer — 1=high, 5=medium, 9=low, 0=none (use 0 if no priority mentioned)
        - notes: string or null — any additional context (null if none)
        - listTitle: string or null — the reminder list name if explicitly mentioned (null otherwise)

        Rules:
        - Resolve relative dates ("next Tuesday", "tomorrow", "in 2 hours") against today's date.
        - Use 24-hour time in the ISO 8601 output.
        - Output ONLY the raw JSON object — no markdown code blocks, no explanation.

        Example input: "remind me to call the dentist next Tuesday at 9am priority high"
        Example output: {"title":"Call the dentist","dueDate":"2026-03-10T09:00:00","priority":1,"notes":null,"listTitle":null}
        """
    )

    public static let extractActions = TemplateDefinition(
        name: "extract-actions",
        description: "Find unfulfilled commitments the user made in a batch of mail/note items",
        content: """
        You are an assistant that finds unfulfilled commitments the user made.

        Today is {{CURRENT_DATE}} and the current time is {{CURRENT_TIME}}.

        Input is a JSON array of items. Each item has these fields:
        - sourceIndex: integer index (use this in your output to identify which item the commitment came from)
        - kind: "mail" or "note"
        - title: optional subject or note title
        - text: the content the user wrote (email body or note text)

        For each first-person commitment the user made to a future action
        (phrases like "I'll send", "I'll draft", "I'll follow up",
        "will circle back", "I'll get you X by Friday"), emit one entry.

        Return ONLY a raw JSON object (no markdown code blocks, no prose) in this exact shape:
        {
          "actions": [
            {
              "sourceIndex": 0,
              "snippet": "<commitment sentence, verbatim from the item>",
              "proposedTitle": "<short reminder title>",
              "proposedDueDate": "<ISO 8601 local datetime or null>",
              "proposedPriority": 0,
              "confidence": 0.0
            }
          ]
        }

        Field rules:
        - sourceIndex: integer — 0-based index of the item in the input array
        - snippet: verbatim quote from the item — do not paraphrase
        - proposedTitle: short imperative reminder title ("Send Q3 numbers to Alex")
        - proposedDueDate: ISO 8601 local datetime like "2026-04-24T17:00:00" if a date is implied, otherwise null
        - proposedPriority: 1=high, 5=medium, 9=low, 0=none
        - confidence: number between 0.0 and 1.0 — how confident this is a real commitment

        Extraction rules:
        - Ignore past-tense acknowledgements ("I sent the draft yesterday").
        - Ignore speculative or conditional statements ("we might follow up").
        - Only include first-person commitments by the author of the item.
        - Resolve relative dates ("Friday", "next week", "tomorrow") against today's date.
        - If an item has no commitments, emit no entries for that sourceIndex.
        - If no items have commitments, return {"actions": []}.
        """
    )

    public static let captureActionItems = TemplateDefinition(
        name: "capture-action-items",
        description: "Extract high-confidence action items from a voice memo transcript as structured JSON for Reminders creation",
        content: """
        You extract action items from a voice memo transcript for Apple Reminders.

        Today is {{CURRENT_DATE}} and the current time is {{CURRENT_TIME}}.

        Prefer fewer, higher-confidence items over exhaustive extraction. Only emit
        items that clearly represent a task, commitment, or follow-up the speaker
        intends to do. Ignore idle thoughts, past-tense recaps, and speculative asides.

        Return ONLY a raw JSON object (no markdown code blocks, no prose) in this
        exact shape:
        {
          "items": [
            {
              "title": "<short imperative reminder title>",
"due_hint": "<YYYY-MM-DD or YYYY-MM-DDTHH:MM:SS (seconds required), or null>",
              "notes": "<verbatim snippet from the transcript, or null>"
            }
          ]
        }

        Field rules:
        - title: short imperative, max ~80 chars ("Email Junaid re: CAP IPA packet")
        - due_hint: resolve relative dates ("tomorrow", "Friday") against today.
Emit "YYYY-MM-DD" for date-only or "YYYY-MM-DDTHH:MM:SS" for
          datetime (seconds component is REQUIRED — "2026-04-25T10:00" will
          be silently dropped). Use null if no date is stated or implied.
        - notes: verbatim quote of the sentence that contains the commitment, or
          null if the title alone is sufficient.

        If the transcript contains no action items, return {"items": []}.
        """
    )

    public static let calendarBriefing = TemplateDefinition(
        name: "calendar-briefing",
        description: "AI-generated agenda briefing from calendar events",
        content: """
        You are a personal assistant providing a concise daily agenda briefing. Given a list of calendar events, generate a clear, conversational summary that:

        1. Opens with a one-sentence overview of the day or period
        2. Lists each event with key details: time, location (if present), any relevant notes
        3. Notes any busy periods, back-to-back events, or scheduling gaps
        4. Closes with a brief practical observation (e.g. "Light morning, packed afternoon")

        Be concise and practical. Write in second person ("You have..."). No markdown headers.
        If there are no events, say so briefly and positively.
        """
    )
}
