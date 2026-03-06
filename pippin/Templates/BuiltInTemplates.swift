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
}
